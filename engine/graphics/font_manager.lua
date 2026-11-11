--[[ Text labels share fonts and fallbacks here
the cache key includes the font source, size, filtering and raster density ]]

local FontManager = {}
local _font_filedata
local grid_profiles = {}
local GridProfile = require("engine/graphics/font_grid_profile")

local function _file_exists(path)
    return type(path) == "string" and love.filesystem.getInfo(path, "file") ~= nil
end

local resolved_paths = {}
local font_roots = {}

local function normalize_root(path)
    assert(type(path) == "string" and path ~= "", "font asset root must be a non-empty virtual path")
    path = path:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
    assert(not path:match("^/") and not path:match("^%a:[/]"),
        "font asset root must be a LÖVE virtual path")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "..", "font asset root must not escape its project")
    end
    return path
end

---search project roots first, then the engine font directory
---labels without their own font use the project default when one is set
function FontManager.set_asset_roots(roots, default_font)
    assert(type(roots) == "table", "font asset roots must be an array")
    font_roots, resolved_paths = {}, {}
    for _, root in ipairs(roots) do
        root = normalize_root(root)
        local duplicate = false
        for _, current in ipairs(font_roots) do
            if current == root then duplicate = true; break end
        end
        if not duplicate then font_roots[#font_roots + 1] = root end
    end
    FontManager.default_path = default_font and assert(FontManager.resolve_path(default_font),
        "could not find project default font: " .. tostring(default_font)) or nil
    return FontManager
end

function FontManager.get_asset_roots()
    local roots = {}
    for index, root in ipairs(font_roots) do roots[index] = root end
    return roots
end

---resolve an explicit virtual path or a filename beneath a configured root
function FontManager.resolve_path(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("\\", "/")
    if resolved_paths[path] then return resolved_paths[path] end
    -- a project can always supply an explicit virtual path
    if _file_exists(path) then
        resolved_paths[path] = path
        return path
    end
    local relative = path
    local lower = relative:lower()
    local extensions = { "" }
    if not lower:match("%.ttf$") and not lower:match("%.otf$") and not lower:match("%.ttc$") then
        extensions = { ".ttf", ".otf", ".ttc" }
    end
    for _, root in ipairs(font_roots) do
        for _, extension in ipairs(extensions) do
            local candidate = root .. "/" .. relative .. extension
            if _file_exists(candidate) then
                resolved_paths[path] = candidate
                return candidate
            end
        end
    end
    return nil
end

-- ImageFonts have no typographic ascender/descender. some LÖVE 11.x builds
-- expose an uninitialized ascent for them, getHeight is still reliable
-- keep real outline-font metrics, but reject impossible/uninitialized values
function FontManager.metrics(font)
    local height = font:getHeight()
    local ascent, descent = math.abs(font:getAscent()), math.abs(font:getDescent())
    if ascent ~= ascent or descent ~= descent or ascent + descent > height * 4
        or ascent + descent == 0 then
        return height, 0
    end
    return ascent, descent
end

FontManager.PRIORITY_VISIBLE = 1
FontManager.PRIORITY_NEAR = 2
FontManager.PRIORITY_OFFSCREEN = 3

FontManager.FALLBACK_ARABIC = "NotoSansArabic-Regular.ttf"
FontManager.FALLBACK_BROAD = "NotoSansJP-Regular.otf"
FontManager.FALLBACK_LATIN = "OpenSansPX.ttf"

local FILEDATA_CAP_BYTES = 32 * 1024 * 1024

local FONT_CACHE = {}
local FALLBACKS_CACHE = {}
local FONT_INFO = setmetatable({}, { __mode = "k" })
local FONT_CHAIN = setmetatable({}, { __mode = "k" })
local FONT_USERS = setmetatable({}, { __mode = "k" })
local FONT_CREATION = setmetatable({}, { __mode = "k" })

-- Opt-in diagnostics join the object returned by get() to the raster selected
-- by remediation. no logging or per-request record allocation in normal use
function FontManager.describe(font)
    local info = FONT_INFO[font] or {}
    local creation = FONT_CREATION[font] or {}
    return {identity=tostring(font), dpi=font:getDPIScale(), filter={font:getFilter()},
        height=font:getHeight(), requested_size=info.requested_size, size=info.size,
        key=info.key, stripe_verdict=info.stripe_verdict, stripe_holes=info.stripe_holes,
        candidate_size=info.candidate_size, candidate_dpi=info.candidate_dpi,
        raster_size=creation.size, raster_hinting=creation.hinting, raster_dpi=creation.dpi,
        probe=creation.probe}
end

local function trace_get(font, path, size, pixel, dpi, hit, requestedPixel)
    if not FontManager.trace then return end
    local record=FontManager.describe(font)
    record.request={path=type(path)=="userdata" and tostring(path) or path,
        size=size,pixel=requestedPixel==nil and "auto" or requestedPixel,resolved_pixel=pixel,
        hinting=FontManager.hinting_mode(path,pixel) or "normal",dpi=dpi,
        filter=pixel and "nearest/nearest" or "linear/linear"}
    record.cache_hit=hit
    FontManager.trace(record)
end

-- Weak subscriptions invalidate baked pixels at fallback ownership changes,
-- including ancestors which can otherwise prevent a Text's draw from running
function FontManager.watch(font, owner, changed)
    local users = FONT_USERS[font]
    if not users then
        users = setmetatable({}, {__mode = "k"})
        FONT_USERS[font] = users
    end
    users[owner] = changed
end

-- Sampling is explicit: unknown fonts are smooth. Hinting profiles remain
-- separate from filtering and source-raster remediation
local FONT_RENDER_PROFILE = {
    -- these bundled outline fonts render cleanly at their requested size
    -- Decorative-font stripe heuristics misclassify them at display sizes
    -- and can choose a 0.34-DPI raster, visibly blurring ordinary headings
    ["poppins-regular.ttf"] = { pixel = false, remediate = false },
    ["poppins-black.ttf"] = { pixel = false, remediate = false },
    ["notosansarabic-regular.ttf"] = { pixel = false, remediate = false },
    -- retain the profile for projects that provide this optional font
    ["opensanspx.ttf"] = { pixel = false, remediate = false },
    ["pixel_promise.ttf"] = { pixel = true },
    ["pixel_promise_monospaced.ttf"] = { pixel = true },
    ["pixel_promise_cutout.ttf"] = { pixel = true },
    ["pixel_promise_nospace_cutout.ttf"] = { pixel = true },
}

--[[ lru + request-queue + stats state. the lru cap is off by default: eviction
only drops FONT_CACHE entries (live Texts hold strong refs to their fonts, so
an evicted font stays alive until its last user lets go) ]]
local lru_cap = nil
local lru_stamp = 0
local lru_stamps = {}
local owner_caches = {}
local cache_owners = {}
local loaded_count = 0
local stat_hits = 0
local stat_misses = 0

local queue = { {}, {}, {} }
local queue_heads = { 1, 1, 1 }
local queued_keys = {}
local queued_count = 0

local filedata_cache = {}
local filedata_bytes = 0
local filedata_stamp = 0

--[[ ---------- render profiles / filename heuristics ---------- ]]

local function _render_profile(path)
    if type(path) ~= "string" then return nil end
    path = FontManager.resolve_path(path)
    if not path then return nil end
    local lower = path:lower()
    local explicit=FONT_RENDER_PROFILE[lower:match("([^/\\]+)$") or lower]
    if explicit then return explicit end
    if grid_profiles[path]~=nil then return grid_profiles[path] or nil end
    local data=_font_filedata(path)
    local profile=data and GridProfile.inspect(data:getString())
    grid_profiles[path]=profile or false
    return profile
end

function FontManager.set_render_profile(basename, profile)
    if type(basename) ~= "string" then return end
    FONT_RENDER_PROFILE[basename:lower()] = profile
end

function FontManager.get_render_profile(basename)
    if type(basename) ~= "string" then return nil end
    return _render_profile(basename)
end

function FontManager.looks_like_pixel_font(path)
    local profile = _render_profile(path)
    if profile and profile.pixel ~= nil then
        return profile.pixel
    end
    -- Names are not raster policy. Unknown TrueType/OpenType fonts are smooth;
    -- pixel art opts in via pixelFont or an explicit render profile
    return false
end

function FontManager.hinting_mode(path, pixelFont)
    local profile = _render_profile(path)
    if profile and profile.hinting then
        return profile.hinting
    end
    if pixelFont == true then
        return "none"
    end
    local lower = (type(path) == "string") and path:lower() or ""
    if lower:find("cutout", 1, true)
        or lower:find("border", 1, true)
        or lower:find("monospaced", 1, true)
        or lower:find("monospace", 1, true)
        or lower:find("nospace", 1, true) then
        return "none"
    end
    --[[ keep the default hinting unless a font has an explicit profile
mono hinting can leave stripes or fail on cutout fonts, even when their names suggest pixel art ]]
    return nil
end

--[[ ---------- filedata cache ---------- ]]

--[[ love.graphics.newFont re-reads the ttf from disk for every size, caching
the FileData per path makes a multi-size load pay the disk read once. capped
by bytes, oldest-touch evicted first ]]
_font_filedata = function(path)
    local entry = filedata_cache[path]
    if entry then
        filedata_stamp = filedata_stamp + 1
        entry.stamp = filedata_stamp
        return entry.data
    end
    local ok, data = pcall(love.filesystem.newFileData, path)
    if not ok or not data then return nil end
    local size = data:getSize()
    filedata_stamp = filedata_stamp + 1
    filedata_cache[path] = { data = data, size = size, stamp = filedata_stamp }
    filedata_bytes = filedata_bytes + size
    while filedata_bytes > FILEDATA_CAP_BYTES do
        local oldest_path, oldest_stamp = nil, nil
        for p, e in pairs(filedata_cache) do
            if p ~= path and (oldest_stamp == nil or e.stamp < oldest_stamp) then
                oldest_path, oldest_stamp = p, e.stamp
            end
        end
        if not oldest_path then break end
        filedata_bytes = filedata_bytes - filedata_cache[oldest_path].size
        filedata_cache[oldest_path] = nil
    end
    return data
end

local function _new_font_with_fallback(path, size, hinting, dpiscale)
    local dpi = dpiscale or 1
    local function try_new(...)
        local ok, f = pcall(love.graphics.newFont, ...)
        if ok and f then
            FONT_CREATION[f]={size=size,hinting=select(select('#',...)-1,...),dpi=dpi}
            return f
        end
        return nil
    end

    if path and path ~= "" then
        local source = _font_filedata(path) or path
        local f
        if hinting then
            f = try_new(source, size, hinting, dpi)
        else
            f = try_new(source, size, "normal", dpi)
        end
        f = f or try_new(source, size, "normal", dpi)
        --[[ filedata rejected by newFont (unexpected): retry from the path ]]
        if not f and source ~= path then
            if hinting then
                f = try_new(path, size, hinting, dpi)
            else
                f = try_new(path, size, "normal", dpi)
            end
            f = f or try_new(path, size, "normal", dpi)
        end
        if f then return f end
        return nil
    end

    return try_new(size, hinting or "normal", dpi)
end

--[[ newFont succeeding does NOT mean the font can rasterize: FreeType raises
"FT_Glyph_To_Bitmap failed (0x14)" for some decorative fonts at some
size+hinting combos only when a glyph is first rendered, which used to
hard-crash the app from inside Text layout/draw. force a raster now (also
prewarms the atlas) and, on failure, walk a hinting ladder before giving up ]]
local VALIDATE_STRING = "HIMNLEBbdklt1078mM@"
local VALIDATE_LADDER = { "light", "normal", "none" }

local function _validated_font(path,size,hinting,dpiscale,fallbacks)
    local f = _new_font_with_fallback(path, size, hinting, dpiscale)
    if not f then return f end
    -- LÖVE permanently caches a missing glyph's .notdef raster once drawn
    -- explicit variants must attach their fallback before raster validation
    if fallbacks and #fallbacks>0 then f:setFallbacks((table.unpack or unpack)(fallbacks)) end
    if pcall(love.graphics.newText, f, VALIDATE_STRING) then return f end
    for _, h in ipairs(VALIDATE_LADDER) do
        if h ~= hinting then
            local g = _new_font_with_fallback(path, size, h, dpiscale)
            if g and fallbacks and #fallbacks>0 then g:setFallbacks((table.unpack or unpack)(fallbacks)) end
            if g and pcall(love.graphics.newText, g, VALIDATE_STRING) then
                return g
            end
        end
    end
    return nil
end

-- a gap can be part of a glyph’s design, so compare raster sizes before replacing a font
local REMEDIATE_MAX_SIZE = 90

local StripeProbe = require("engine/graphics/font_stripe_probe")

local function _probe_stripes(font, size)
    return StripeProbe.probe(font, size)
end

--[[ hinting variants tried (in order) when the policy raster is holed, nil =
LOVE default. mono is deliberately absent (stripes 90% of fonts, FT-crashes
cutout fonts) ]]
local REMEDIATE_HINTINGS = { "light", "none", false }

local function _hint_key(h) return h == nil and "default" or tostring(h) end

--[[ returns (font, actualSize, verdict, residual_holes), verdict is one of
"clean" (requested raster passed), "remediated" (a clean variant replaced it),
"reduced" (best variant taken, still holed), "exhausted" (nothing better
found, design-inherent or unfixable within the search space), "skipped"
(remediation not applicable) ]]
local function _remediated_font(path,size,hinting,font,filter_pixel,dpiscale,fallbacks)
    local density = dpiscale or 1
    if not font or type(size) ~= "number"
        or size > REMEDIATE_MAX_SIZE or size < 6 then
        return font, size, "skipped", nil
    end
    local profile = _render_profile(path)
    if profile and profile.remediate == false then
        return font, size, profile.kind=="shared-cell-outlines" and "grid-profile" or "skipped", nil
    end
    --[[ every probe must measure the raster under the filter the font will
    actually ship with: the boot-time default filter is nearest, which hides
    the half-texel smear dips that linear sampling produces at fractional
    glyph advances, exactly what users then see ]]
    local pf = filter_pixel and "nearest" or "linear"
    local function probe_final(f, s)
        pcall(f.setFilter, f, pf, pf)
        local holes=_probe_stripes(f, s)
        local creation=FONT_CREATION[f]
        if creation then creation.probe={identity=tostring(f),size=s,holes=holes,dpi=f:getDPIScale(),filter={f:getFilter()}} end
        return holes
    end
    local holes = probe_final(font, size)
    --[[ a single marginal dip is rasterization noise (visually negligible);
    the user-visible bands measure 7-23 ]]
    if not holes or holes <= 1 then return font, size, "clean", holes end

    local best_font, best_size, best_holes = nil, nil, holes

    --[[ 1) other hinting modes at the requested size ]]
    for _, h in ipairs(REMEDIATE_HINTINGS) do
        local hv = h or nil
        if _hint_key(hv) ~= _hint_key(hinting) then
            local cand = _validated_font(path,size,hv,density,fallbacks)
            if cand then
                local ch = probe_final(cand, size)
                if ch and ch == 0 then
                    return cand, size, "remediated", 0
                end
                if ch and ch < best_holes then
                    best_font, best_size, best_holes = cand, size, ch
                end
            end
        end
    end

    --[[ 2) supersample at the REQUESTED size: dpiscale=2 rasterizes at double
    ppem and love draws every consumer at half scale automatically, the
    hairline gaps of quad-composed decorative outlines (Company_Contract,
    Everyday at display sizes) average into the strokes on the linear
    downsample. probing the candidate measures the final composite because
    love applies the dpi scale inside print. only for linear-filtered fonts
    (nearest sampling would undo the averaging) ]]
    if not filter_pixel then
        for _, h in ipairs({ hinting or false, false }) do
            local hv = h or nil
            if _ == 1 or _hint_key(hv) ~= _hint_key(hinting) then
                local cand = _validated_font(path,size,hv,2*density,fallbacks)
                if cand then
                    pcall(cand.setFilter, cand, "linear", "linear")
                    local ch = probe_final(cand, size)
                    if ch and ch == 0 then
                        return cand, size, "supersampled", 0
                    end
                    if ch and ch < best_holes then
                        best_font, best_size, best_holes = cand, size, ch
                    end
                end
            end
        end
    end

    --[[ 3) nearby sizes (policy hinting, then the LOVE default, false = nil
    sentinel so the array keeps its length) ]]
    local maxd = math.max(2, math.floor(size * 0.25))
    local hint_set = { hinting or false }
    if _hint_key(hinting) ~= "default" then hint_set[#hint_set + 1] = false end
    for d = 1, maxd do
        for _, c in ipairs({ size - d, size + d }) do
            if c >= 6 then
                for hi = 1, #hint_set do
                    local hv = hint_set[hi] or nil
                    local cand = _validated_font(path,c,hv,density,fallbacks)
                    if cand then
                        local ch = probe_final(cand, c)
                        if ch and ch == 0 then
                            return cand, c, "remediated", 0
                        end
                        if ch and ch < best_holes then
                            best_font, best_size, best_holes = cand, c, ch
                        end
                    end
                end
            end
        end
    end

    --[[ 4) upscale-from-clean (display sizes only): decorative quad-composed
    outlines (Company_Contract, Everyday) resolve their PROPORTIONAL design
    gaps into hard grid lines at big ppem while rendering smooth and solid at
    small sizes. rasterize at a fraction of the ppem (where the gaps merge)
    and let love draw the raster scaled up with linear filtering, soft edges,
    but solid strokes that match the font's small-size look ]]
    --[[ only at display sizes (>=48): there the design gaps are >=2px hard
    grid lines and softness is the lesser evil, below that the native raster's
    sub-pixel hairlines read as font texture and crispness wins (a 3x-upscaled
    small raster looks washed out) ]]
    if not filter_pixel and size >= 48 then
        for _, dpi in ipairs({ 0.5, 0.34 }) do
            local cand = _validated_font(path,size,hinting,dpi*density,fallbacks)
            if cand then
                pcall(cand.setFilter, cand, "linear", "linear")
                local ch = probe_final(cand, size)
                if ch and ch <= 1 then
                    return cand, size, "upscaled", ch
                end
                if ch and ch < best_holes then
                    best_font, best_size, best_holes = cand, size, ch
                end
            end
        end
    end

    --[[ no perfect variant: take the best found when it at least halves the
    holes (never keep a 20-band raster because no neighbour probed exactly 0);
    otherwise the gaps are the font's design, keep as requested ]]
    if best_font and best_holes * 2 <= holes then
        return best_font, best_size, "reduced", best_holes
    end
    return font, size, "exhausted", holes
end

--[[ ---------- fallback attachment ---------- ]]

local function _fallbacks_for(size, filterMode, filter, minFilter, magFilter, dpi, owner)
    local fbKey = tostring(size) .. ":" .. tostring(filterMode) .. ":dpi=" .. tostring(dpi or 1)
    -- Owned chains retain their fallback set through the primary Font only
    -- they must not grow the legacy process-wide fallback pool across DPIs
    local fallbacks
    if not owner then fallbacks=FALLBACKS_CACHE[fbKey] end
    if fallbacks ~= nil then return fallbacks end

    fallbacks = {}
    local function loadFallback(path)
        if not _file_exists(path) then return end
        local hinting = FontManager.hinting_mode(path, filter)
        local f = _new_font_with_fallback(path, size, hinting, dpi)
        if f then
            f:setFilter(minFilter, magFilter)
            FONT_INFO[f] = {
                path = path,
                fontRef = nil,
                sourceKey = path,
                size = size,
                requested_size = size,
                dpi = dpi or 1,
                pixel = filter,
                owner = owner,
            }
            table.insert(fallbacks, f)
        end
    end

    -- keep this list intentionally short to avoid VRAM explosions
    local staticCandidates = {
        FontManager.FALLBACK_ARABIC,
        FontManager.FALLBACK_BROAD,
        FontManager.FALLBACK_LATIN,
    }
    for _, p in ipairs(staticCandidates) do loadFallback(p) end

    if not owner then FALLBACKS_CACHE[fbKey] = fallbacks end
    return fallbacks
end

local unpack_fn = table.unpack or unpack

local function _store_chain(font,chain)
    if not chain then FONT_CHAIN[font]=nil; return end
    if FONT_INFO[font] and FONT_INFO[font].owner then
        -- LuaJIT's Lua 5.1 weak keys do not collect a font -> {font,...} cycle
        -- Substitute only the primary's self-references, keep public order
        local owned={owned=true,length=#chain}
        for i=1,#chain do
            if chain[i]==font then owned[i]=false else owned[i]=chain[i] end
        end
        FONT_CHAIN[font]=owned
    else FONT_CHAIN[font]=chain end
end

local function _attach_fallbacks(font, meta)
    local minFilter = meta.pixel and "nearest" or "linear"
    local magFilter = meta.pixel and "nearest" or "linear"
    local filterMode = minFilter .. "/" .. magFilter
    local fallbacks = _fallbacks_for(meta.size, filterMode, meta.pixel, minFilter, magFilter, meta.dpi,meta.owner)
    if #fallbacks > 0 then
        font:setFallbacks(unpack_fn(fallbacks))
        local chain = { font }
        for i = 1, #fallbacks do
            chain[#chain + 1] = fallbacks[i]
        end
        _store_chain(font,chain)
    else
        _store_chain(font,{font})
    end
    meta.fallbacks_attached = true
end

--[[ attach the shared fallback set to a font that was created without one
(lazy mode). returns true only when the attach happened NOW, callers use that
to re-run hasGlyphs, since love's hasGlyphs consults attached fallbacks ]]
-- LÖVE 11.5 setFallbacks does not move existing glyphs. Native Text handles
-- atlas growth itself. our generation describes fallback CONTENT changes,
-- which baked Canvases and our glyph-resolution cache cannot observe
local FONT_GENERATION = setmetatable({}, { __mode = "k" })

function FontManager.generation(font)
    return (font and FONT_GENERATION[font]) or 0
end

function FontManager.ensure_fallbacks(font)
    if not font then return false end
    local meta = FONT_INFO[font]
    if not meta or meta.fallbacks_attached then return false end
    if not font.setFallbacks then
        meta.fallbacks_attached = true
        return false
    end
    _attach_fallbacks(font, meta)
    FONT_GENERATION[font] = (FONT_GENERATION[font] or 0) + 1
    for owner, changed in pairs(FONT_USERS[font] or {}) do changed(owner, font) end
    return true
end

--[[ ---------- lru ---------- ]]

local function _touch(key)
    lru_stamp = lru_stamp + 1
    lru_stamps[key] = lru_stamp
    local owner=cache_owners[key]
    if owner then owner_caches[owner].keys[key]=lru_stamp end
end

local function _drop_cache_key(key)
    if not FONT_CACHE[key] then return false end
    FONT_CACHE[key],lru_stamps[key]=nil,nil
    loaded_count=loaded_count-1
    local owner=cache_owners[key]
    if owner then
        local record=owner_caches[owner]
        record.keys[key],record.count=nil,record.count-1
        cache_owners[key]=nil
    end
    return true
end

local function _owner_record(owner,limit)
    local record=owner_caches[owner]
    if not record then record={keys={},count=0,limit=128}; owner_caches[owner]=record end
    if type(limit)=='number' and limit==limit and limit<math.huge and limit>=1 then record.limit=math.floor(limit) end
    return record
end

local function _evict_owner(record)
    while record.count>record.limit do
        local oldest,stamp
        for key,value in pairs(record.keys) do
            if not stamp or value<stamp then oldest,stamp=key,value end
        end
        if not oldest then break end
        _drop_cache_key(oldest)
    end
end

local function _evict_if_over_cap()
    if not lru_cap then return end
    while loaded_count > lru_cap do
        local oldest_key, oldest_stamp = nil, nil
        for key in pairs(FONT_CACHE) do
            local stamp = lru_stamps[key] or 0
            if oldest_stamp == nil or stamp < oldest_stamp then
                oldest_key, oldest_stamp = key, stamp
            end
        end
        if not oldest_key then break end
        _drop_cache_key(oldest_key)
    end
end

function FontManager.owner_stats(owner)
    local record=owner_caches[owner]
    return {loaded=record and record.count or 0,limit=record and record.limit or nil}
end

-- remove cache ownership, never release a Font still held by a Text/caller
function FontManager.release_owner(owner)
    local record=owner_caches[owner]
    if not record then return 0 end
    local removed=record.count
    for key in pairs(record.keys) do _drop_cache_key(key) end
    owner_caches[owner]=nil
    return removed
end

function FontManager.set_lru_cap(n)
    lru_cap = (type(n) == "number" and n >= 1) and math.floor(n) or nil
    _evict_if_over_cap()
end

--[[ ---------- core lookup ---------- ]]

--[[ path/filter normalization shared by get() and request(), mirrors the old
Text:obtainFont keying exactly ]]
local function _resolve_request(font, size, pixel)
    if font == nil then font = FontManager.default_path end
    local resolvedPath = FontManager.resolve_path(font)
    if type(font) == "string" and font ~= "" then
        font = resolvedPath
    end

    local filter = pixel
    if filter == nil then
        filter = FontManager.looks_like_pixel_font(resolvedPath)
    end
    if filter == nil then filter = false end
    local minFilter = filter and "nearest" or "linear"
    local magFilter = filter and "nearest" or "linear"
    local filterMode = minFilter .. "/" .. magFilter

    local pathKey
    if type(font) == "userdata" then
        pathKey = "__userdata__:" .. tostring(font)
    else
        pathKey = resolvedPath or "__default__"
    end
    local requestedKey = pathKey .. ":" .. tostring(size) .. ":" .. tostring(filterMode)
    local profile=_render_profile(resolvedPath)
    requestedKey=requestedKey..":hint="..(FontManager.hinting_mode(resolvedPath,filter) or "normal")
        ..":policy="..(profile and (profile.kind or tostring(profile.remediate)) or "default")
    return font, resolvedPath, filter, minFilter, magFilter, filterMode, pathKey, requestedKey
end

---returns (font, meta). font objects are shared process-wide per (path, size, filter, DPI)
function FontManager.get(font,size,pixel,dpiscale,options)
    local dpi = dpiscale or 1
    local fontArg, resolvedPath, filter, minFilter, magFilter, filterMode, pathKey, requestedKey =
        _resolve_request(font, size, pixel)
    if dpi ~= 1 then requestedKey = requestedKey .. ":dpi=" .. tostring(dpi) end
    local variant = type(options)=="table" and options.variant
    if type(variant)=="string" and variant~="" then requestedKey=requestedKey..":variant="..variant else variant=nil end
    font = fontArg
    local explicit_fallbacks=variant and type(options.fallbacks)=="table" and options.fallbacks or nil
    local owner=type(options)=='table' and options.owner
    if type(owner)~='string' or owner=='' then owner=nil end
    local owned=owner and _owner_record(owner,options.limit)
    if owner then requestedKey=requestedKey..':owner='..#owner..':'..owner end
    -- Opt-in, default-off: a caller that rasterizes ordinary outline faces at
    -- exact device-pixel sizes can keep the requested raster. the stripe
    -- remediation ladder may otherwise swap hinting, ppem or density
    -- (including a linear-upscaled 0.34x raster at display sizes)
    local native_raster=type(options)=='table' and options.remediate==false
    if native_raster then requestedKey=requestedKey..':raster=native' end

    local cached = FONT_CACHE[requestedKey]
    if cached then
        stat_hits = stat_hits + 1
        _touch(requestedKey)
        if owned then _evict_owner(owned) end
        local meta = FONT_INFO[cached]
        if not meta then
            meta = {
                path = resolvedPath,
                fontRef = (type(font) == "userdata") and font or nil,
                sourceKey = pathKey,
                size = size,
                pixel = filter,
                key = requestedKey,
                owner = owner,
            }
            FONT_INFO[cached] = meta
        end
        trace_get(cached,resolvedPath or font,size,filter,dpi,true,pixel)
        return cached, meta
    end

    stat_misses = stat_misses + 1
    local newFont
    local actualSize = size
    local candidateSize, candidateDPI
    local stripeVerdict, stripeHoles
    if type(font) == "userdata" then
        newFont = font
    elseif resolvedPath then
        local hinting = FontManager.hinting_mode(resolvedPath, filter)
        newFont = _validated_font(resolvedPath,size,hinting,dpi,explicit_fallbacks)
        if newFont and native_raster then
            stripeVerdict = "native"
        elseif newFont then
            newFont, actualSize, stripeVerdict, stripeHoles =
                _remediated_font(resolvedPath,size,hinting,newFont,filter,dpi,explicit_fallbacks)
        else
            --[[ the requested file cannot load at all (e.g. a missing or invalid
            font asset), the default-font substitute is not remediable ]]
            newFont = _new_font_with_fallback(nil, size, hinting, dpi)
            stripeVerdict = "skipped"
        end
    else
        newFont = _new_font_with_fallback(nil, size, FontManager.hinting_mode(nil, filter), dpi)
    end

    if not newFont then
        newFont = love.graphics.newFont(size, "normal", dpi)
    end

    -- a nearby-ppem workaround must not resize every consumer (including raw
    -- love.graphics.print). preserve its physical raster while exposing the
    -- requested logical size through Font DPI. _fontForRender can then use
    -- requested layout metrics, rather than scaling an already size-shifted font
    if resolvedPath and actualSize~=size then
        candidateSize,candidateDPI=actualSize,newFont:getDPIScale()
        local creation=FONT_CREATION[newFont] or {}
        local normalized=_validated_font(resolvedPath,size,creation.hinting,candidateDPI*actualSize/size,explicit_fallbacks)
        if normalized then
            newFont,actualSize=normalized,size
            newFont:setFilter(minFilter,magFilter)
            stripeHoles=_probe_stripes(newFont,size)
            local c=FONT_CREATION[newFont]
            if c then c.probe={identity=tostring(newFont),size=size,holes=stripeHoles,
                dpi=newFont:getDPIScale(),filter={newFont:getFilter()}} end
        end
    end

    newFont:setFilter(minFilter, magFilter)

    local meta = {
        path = resolvedPath,
        fontRef = (type(font) == "userdata") and font or nil,
        sourceKey = pathKey,
        size = actualSize,
        requested_size = size,
        candidate_size = candidateSize,
        candidate_dpi = candidateDPI,
        dpi = dpi,
        stripe_verdict = stripeVerdict,
        stripe_holes = stripeHoles,
        pixel = filter,
        key = requestedKey,
        owner = owner,
    }
    FONT_INFO[newFont] = meta

    --[[ no fallback fonts yet: the chain is just the font itself
    ensure_fallbacks() attaches on first non-ascii need (addSegment /
    _resolveFontForGlyph), always at parse time, never mid-draw ]]
    local chain={newFont}
    -- explicit opt-in fallback variants own a distinct Font object/cache key
    -- this lets a project choose its actual Latin face without changing other
    -- engine consumers of the same primary file or the legacy fallback order
    if variant and type(options.fallbacks)=="table" and #options.fallbacks>0 then
        newFont:setFallbacks(unpack_fn(options.fallbacks))
        meta.fallbacks_attached,meta.fallback_variant = true,variant
        for _,fallback in ipairs(options.fallbacks) do chain[#chain+1]=fallback end
    end
    _store_chain(newFont,chain)

    FONT_CACHE[requestedKey] = newFont
    loaded_count = loaded_count + 1
    if owned then cache_owners[requestedKey]=owner; owned.count=owned.count+1 end
    _touch(requestedKey)
    if owned then _evict_owner(owned) end
    _evict_if_over_cap()
    trace_get(newFont,resolvedPath or font,size,filter,dpi,false,pixel)
    return newFont, meta
end

function FontManager.get_info(font)
    return font and FONT_INFO[font] or nil
end

function FontManager.get_chain(font)
    local stored=font and FONT_CHAIN[font]
    if not stored or not stored.owned then return stored end
    local chain={}
    for i=1,stored.length do chain[i]=stored[i]==false and font or stored[i] end
    return chain
end

function FontManager.set_chain(font, chain)
    if font then _store_chain(font,chain) end
end

--[[ ---------- async request queue ---------- ]]

--[[ queue a font load for the update() pump. re-requesting at a more urgent
priority re-queues the key, the stale lower-priority entry is skipped when
popped. returns true when the font is already loaded ]]
function FontManager.request(path, size, pixel, priority)
    local _, _, _, _, _, _, _, requestedKey = _resolve_request(path, size, pixel)
    if FONT_CACHE[requestedKey] then return true end

    priority = priority or FontManager.PRIORITY_OFFSCREEN
    if priority < 1 then priority = 1 end
    if priority > 3 then priority = 3 end

    local existing = queued_keys[requestedKey]
    if existing and existing.priority <= priority then return false end
    if not existing then
        queued_count = queued_count + 1
    end
    local entry = { key = requestedKey, path = path, size = size, pixel = pixel, priority = priority }
    queued_keys[requestedKey] = entry
    local list = queue[priority]
    list[#list + 1] = entry
    return false
end

--[[ main-thread pump: loads queued fonts most-urgent-first until the time
budget runs out (always at least one when anything is queued). the caller's
update hook owns registration, the manager never hooks the pipeline itself ]]
function FontManager.update(budget_seconds)
    if queued_count == 0 then return 0 end
    budget_seconds = budget_seconds or 0.002
    local t0 = love.timer.getTime()
    local processed = 0
    for priority = 1, 3 do
        local list = queue[priority]
        while queue_heads[priority] <= #list do
            local entry = list[queue_heads[priority]]
            list[queue_heads[priority]] = false
            queue_heads[priority] = queue_heads[priority] + 1
            --[[ stale = re-queued at another priority or already loaded ]]
            if entry and queued_keys[entry.key] == entry then
                queued_keys[entry.key] = nil
                queued_count = queued_count - 1
                if not FONT_CACHE[entry.key] then
                    FontManager.get(entry.path, entry.size, entry.pixel)
                end
                processed = processed + 1
                if love.timer.getTime() - t0 >= budget_seconds then
                    return processed
                end
            end
        end
        --[[ list fully drained: reset so it does not grow unbounded ]]
        queue[priority] = {}
        queue_heads[priority] = 1
    end
    return processed
end

function FontManager.stats()
    return {
        loaded = loaded_count,
        queued = queued_count,
        hits = stat_hits,
        misses = stat_misses,
        filedata_mb = filedata_bytes / (1024 * 1024),
    }
end

return FontManager
