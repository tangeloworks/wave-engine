local Surface = require("engine/graphics/surface")

function pad_image_transparent(imgOrPath, pad)
    local img
    if type(imgOrPath) == "string" then
        local ok, data = pcall(love.image.newImageData, imgOrPath)
        if ok then
            img = data
        else
            local resolved
            if Image and Image._resolve_path then
                resolved = Image._resolve_path(imgOrPath)
            end
            if resolved then
                img = love.image.newImageData(resolved)
            else
                error("Invalid image or path passed to pad_image_transparent: " .. tostring(imgOrPath))
            end
        end
    elseif type(imgOrPath) == "userdata" and imgOrPath:typeOf("Image") then
        img = imgOrPath:newImageData()
    elseif type(imgOrPath) == "userdata" and imgOrPath:typeOf("ImageData") then
        img = imgOrPath
    else
        error("Invalid image or path passed to pad_image_transparent")
    end

    local w, h = img:getWidth(), img:getHeight()
    local paddedW, paddedH = w + pad * 2, h + pad * 2

    local padded = love.image.newImageData(paddedW, paddedH)

    padded:paste(img, pad, pad, 0, 0, w, h)

    return love.graphics.newImage(padded)
end

---@class Image: Element
---@overload fun(args?: ImageArgs): Image
---@type Image
Image = Element:extend()

local cache = {}

--[[ slice_center drives the 9-slice scale type below, register it so writes
mark dirty like the other image keys (it is paint-only: rect/layout unchanged) ]]
Element._property_dirty.slice_center = true
Element._visual_dirty_keys.slice_center = true

local function _basename(p)
    if type(p) ~= 'string' then return p end
    return p:match("[^/\\]+$") or p
end

local function _fs_exists(path)
    if type(path) ~= 'string' then return false end
    local info = love.filesystem.getInfo(path, 'file')
    return info ~= nil
end

-- Paths are explicit by default. Projects can register a small ordered list of
-- asset roots, but this module never walks a shared asset tree by basename
local RESOLVE_CACHE = {}
local ASSET_ROOTS = {}

local function normalize_root(path)
    assert(type(path) == "string" and path ~= "", "image asset root must be a non-empty virtual path")
    path = path:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
    assert(path ~= "", "image asset root must be a non-empty virtual path")
    assert(not path:match("^/") and not path:match("^%a:[/]"),
        "image asset root must be a LÖVE virtual path")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "..", "image asset root must not escape the project")
    end
    return path
end

function Image.set_asset_roots(roots)
    assert(type(roots) == "table", "image asset roots must be an array")
    ASSET_ROOTS = {}
    RESOLVE_CACHE = {}
    for _, root in ipairs(roots) do
        Image.add_asset_root(root)
    end
    return Image
end

function Image.add_asset_root(root, prepend)
    root = normalize_root(root)
    for _, current in ipairs(ASSET_ROOTS) do
        if current == root then return Image end
    end
    if prepend then
        table.insert(ASSET_ROOTS, 1, root)
    else
        ASSET_ROOTS[#ASSET_ROOTS + 1] = root
    end
    RESOLVE_CACHE = {}
    return Image
end

function Image.get_asset_roots()
    local roots = {}
    for index, root in ipairs(ASSET_ROOTS) do roots[index] = root end
    return roots
end

Image.configure_asset_roots = Image.set_asset_roots

function Image._resolve_path(user_input)
    if type(user_input) ~= 'string' or user_input == '' then return nil end

    local cached = RESOLVE_CACHE[user_input]
    if cached ~= nil then
        if cached == false then return nil end
        --[[ re-validate cheaply: files can disappear between runs of a
        long-lived session, a stale hit falls through to a fresh resolve ]]
        if _fs_exists(cached) then return cached end
        RESOLVE_CACHE[user_input] = nil
    end

    if _fs_exists(user_input) then
        RESOLVE_CACHE[user_input] = user_input
        return user_input
    end

    local function remember(found)
        RESOLVE_CACHE[user_input] = found or false
        return found
    end

    local relative = user_input:gsub("^%./", "")
    for _, root in ipairs(ASSET_ROOTS) do
        local candidate = root .. "/" .. relative
        if _fs_exists(candidate) then return remember(candidate) end
    end

    remember(nil)
    return nil
end

function Image:_apply_path(user_input, pad)
    local data = rawget(self, "__data")
    if data then data.source = user_input end
    local resolved = Image._resolve_path(user_input) or user_input
    if resolved and _fs_exists(resolved) then
        self.image = Image._obtainImage(resolved, pad or 0)
        self._srcW, self._srcH = self.image:getDimensions()
        self.quad = nil
        rawset(self, "_quad_cache", nil)
        self._resolved_source = resolved
        self.imageRectOffset = vec2(0, 0)
        self.imageRectSize = vec2(self._srcW, self._srcH)
        if self.resample_mode then
            self:setFilter(self.resample_mode)
        end
    else

    end
end

---@param args? ImageArgs
function Image:init(args)
    Element.init(self, args)

    args                 = args or {}
    local givenSrc       = args.path or args.source
    --[[ informational only, write into __data directly: a metatable write
    here would fire on_property_changed('path') -> _apply_path(basename) and
    re-resolve/re-apply the image this very init is about to apply ]]
    do
        local d_self = rawget(self, "__data")
        local base = type(givenSrc) == "string" and _basename(givenSrc) or nil
        if d_self then
            d_self.path = base
            d_self.source = type(givenSrc) == "string" and givenSrc or nil
        else
            self.path = base
            self.source = type(givenSrc) == "string" and givenSrc or nil
        end
    end
    --[[ deferred loading (opt-in: args.deferred or Image.deferred_loading_enabled):
    already-cached textures always bind immediately (deferral would only add a
    placeholder flash), uncached paths get the shared transparent placeholder
    and load through the budgeted pump ]]
    local want_defer = (args.deferred == true or (args.deferred == nil and Image.deferred_loading_enabled))
        and type(givenSrc) == "string"
        and not cache[givenSrc]
    if type(givenSrc) ~= "string" or givenSrc == "" then
        self.image = Image._placeholder_texture()
    elseif want_defer then
        self.image = Image._placeholder_texture()
        rawset(self, "_deferred_src", givenSrc)
        rawset(self, "_deferred_pad", args.pad)
        Image._enqueue_load(self, args.load_priority or 2)
    else
        local resolved = Image._resolve_path(givenSrc) or givenSrc
        self.image = Image._obtainImage(resolved, args.pad)
    end
    self.resample_mode   = args.resample_mode or args.resampleMode or "nearest" -- or linear
    self.resampleMode    = self.resample_mode
    self.scale_type      = args.scale_type or args.scaleType or "stretch"
    self.scaleType       = self.scale_type
    self.tile_size       = (args.tile_size and args.tile_size:clone()) or vec2(64, 64)
    self.flip_x          = (args.flip_x ~= nil) and args.flip_x or false
    self.flip_y          = (args.flip_y ~= nil) and args.flip_y or false
    self.color           = args.color or { 1, 1, 1, 1 }
    self.opacity         = args.opacity or 1
    self.visible         = args.visible == nil and true or args.visible
    self.currentFlipbook = nil
    if args.imageRectOffset or args.imageRectSize then
        local imgW, imgH       = self.image:getDimensions()
        local off              = args.imageRectOffset or vec2()
        local sz               = args.imageRectSize or vec2(imgW, imgH)
        self.quad              = love.graphics.newQuad(
            off.x, off.y, sz.x, sz.y, imgW, imgH)
        self._srcW, self._srcH = sz.x, sz.y
        self.imageRectOffset   = off:clone()
        self.imageRectSize     = sz:clone()
    else
        self.quad              = nil
        self._srcW, self._srcH = self.image:getDimensions()
        self.imageRectOffset   = vec2(0, 0)
        self.imageRectSize     = vec2(self._srcW, self._srcH)
    end
    self.shader            = args.shader

    self.shaderParams      = args.shaderParams or {}
    self._shaderCanvas     = nil
    self._shaderCanvasSize = vec2()
    self.quad_pad          = args.quad_pad or 1

    self.image:setFilter(self.resample_mode)

    self._canvas_dirty = true
    self.isdrawn = false
end

--[[ deferred image loading ]]

Image.deferred_loading_enabled = false
local IMAGE_LOAD_BUDGET_SECONDS = 0.002
local IMAGE_LOAD_MAX_PER_FRAME = 4
local LOAD_QUEUE = { {}, {} } --[[ tier 1 = visible/priority, tier 2 = rest ]]
local LOAD_QUEUE_SIZE = 0
local LOAD_STATS = { completed = 0, total_ms = 0, queue_peak = 0 }
local PLACEHOLDER = nil
local PUMP_REGISTERED = false

function Image._placeholder_texture()
    if not PLACEHOLDER then
        local data = love.image.newImageData(1, 1)
        data:setPixel(0, 0, 0, 0, 0, 0)
        PLACEHOLDER = love.graphics.newImage(data)
    end
    return PLACEHOLDER
end

local function _complete_load(el)
    local src = rawget(el, "_deferred_src")
    if not src then return end
    local t0 = love.timer.getTime()
    local resolved = Image._resolve_path(src) or src
    local image = Image._obtainImage(resolved, rawget(el, "_deferred_pad"))
    LOAD_STATS.total_ms = LOAD_STATS.total_ms + (love.timer.getTime() - t0) * 1000
    LOAD_STATS.completed = LOAD_STATS.completed + 1
    rawset(el, "_deferred_src", nil)
    rawset(el, "_deferred_pad", nil)
    el.image = image
    el._srcW, el._srcH = image:getDimensions()
    el.quad = nil
    rawset(el, "_quad_cache", nil)
    el._resolved_source = resolved
    el.imageRectOffset = vec2(0, 0)
    el.imageRectSize = vec2(el._srcW, el._srcH)
    if el.resample_mode then
        el:setFilter(el.resample_mode)
    end
    el:mark_dirty("imageRect")
    --[[ the fresh texture must reach any cached-canvas ancestor that baked
    the placeholder ]]
    Element._refresh_ancestor_canvases(el, false)
end

function Image.pump_load_queue(budget_seconds)
    LOAD_STATS.pump_calls = (LOAD_STATS.pump_calls or 0) + 1
    if LOAD_QUEUE_SIZE == 0 then return end
    local budget = budget_seconds or IMAGE_LOAD_BUDGET_SECONDS
    local t0 = love.timer.getTime()
    local loaded = 0
    for tier = 1, 2 do
        local q = LOAD_QUEUE[tier]
        while #q > 0 do
            local el = table.remove(q, 1)
            LOAD_QUEUE_SIZE = LOAD_QUEUE_SIZE - 1
            if rawget(el, "_deferred_src") then
                _complete_load(el)
                loaded = loaded + 1
                if loaded >= IMAGE_LOAD_MAX_PER_FRAME
                    or (love.timer.getTime() - t0) >= budget then
                    return
                end
            end
        end
    end
end

function Image._enqueue_load(el, priority)
    local tier = priority == 1 and 1 or 2
    local q = LOAD_QUEUE[tier]
    q[#q + 1] = el
    LOAD_QUEUE_SIZE = LOAD_QUEUE_SIZE + 1
    if LOAD_QUEUE_SIZE > LOAD_STATS.queue_peak then
        LOAD_STATS.queue_peak = LOAD_QUEUE_SIZE
    end
    if not PUMP_REGISTERED and G and G.pipeline then
        PUMP_REGISTERED = true
        G.pipeline:register("update", "image_load_pump", function()
            Image.pump_load_queue()
        end, { priority = 3, after = "INIT" })
    end
end

--[[ synchronously warm the texture cache within a time budget (load screens);
returns how many paths were actually loaded ]]
function Image.prewarm(paths, budget_seconds)
    local t0 = love.timer.getTime()
    local loaded = 0
    for i = 1, #paths do
        local src = paths[i]
        if type(src) == "string" and not cache[src] then
            local resolved = Image._resolve_path(src) or src
            Image._obtainImage(resolved, 0)
            loaded = loaded + 1
            if budget_seconds and (love.timer.getTime() - t0) >= budget_seconds then
                break
            end
        end
    end
    return loaded
end

function Image.load_stats()
    return {
        queue_size = LOAD_QUEUE_SIZE,
        queue_peak = LOAD_STATS.queue_peak,
        completed = LOAD_STATS.completed,
        load_ms = LOAD_STATS.total_ms,
        pump_calls = LOAD_STATS.pump_calls or 0,
    }
end

function Image._obtainImage(src, pad)
    if type(src) == "userdata" then return src end
    if not src then error("Image: source not provided") end
    if cache[src] then
        return cache[src]
    end

    local resolved = src
    if type(src) == "string" and (not love.filesystem.getInfo(src, 'file')) then
        if Image._resolve_path then
            resolved = Image._resolve_path(src) or src
        end
    end

    cache[src] = pad_image_transparent(resolved, pad or 0)
    return cache[src]
end

function Image:setFilter(mode)
    self.resample_mode = mode
    self.image:setFilter(mode, mode)
end

function Image:on_property_changed(k, old, v)
    if k == 'path' or k == 'source' then
        local apply_path = Image._apply_path or rawget(self, "_apply_path")
        if apply_path then
            apply_path(self, v, self.quad_pad or 0)
        end
    elseif k == 'resample_mode' or k == 'resampleMode' then
        if type(v) == 'string' then
            local m = v:lower()
            if m == 'nearest' or m == 'linear' then
                self:setFilter(m)
            elseif m == 'bilinear' then
                self:setFilter('linear')
            else
                self:setFilter('nearest')
            end
        end
    elseif k == 'scale_type' or k == 'scaleType' then
        self:mark_dirty('scale_type')
    elseif k == 'image' and type(v) == 'userdata' and v.typeOf and v:typeOf('Image') then
        self._srcW, self._srcH = v:getDimensions()
        self.quad = nil
    end
end

function Image:setFlip(flipX, flipY)
    local changed = self.flip_x ~= flipX or self.flip_y ~= flipY
    if changed then
        self.__suspend_dirty = true
        self.flip_x = flipX
        self.flip_y = flipY
        self.__suspend_dirty = false
        self:mark_dirty("flip")
    end
end

function Image:setImageRect(offset, size)
    local imgW, imgH = self.image:getDimensions()
    -- per-instance quad cache: flipbooks reuse their source rectangles
    -- the cache is invalidated when the image changes
    local qcache = rawget(self, "_quad_cache")
    if not qcache then
        qcache = {}
        rawset(self, "_quad_cache", qcache)
    end
    local qkey = offset.x .. ":" .. offset.y .. ":" .. size.x .. ":" .. size.y
    local quad = qcache[qkey]
    if not quad then
        quad = love.graphics.newQuad(offset.x, offset.y, size.x, size.y, imgW, imgH)
        qcache[qkey] = quad
    end
    self.quad = quad
    self._srcW, self._srcH = size.x, size.y
    self.imageRectOffset = offset:clone()
    self.imageRectSize = size:clone()
    --[[ a quad viewport change is paint-only: rect, layout and clip state are
    untouched (classified visual by the element dirty split) ]]
    self:mark_dirty("imageRect")
end

function Image:setFlipbook(config)
    if self.currentFlipbook then
        if self.currentFlipbook[2] == config then return end
        self.currentFlipbook[1]:destroy()
        self.currentFlipbook = nil
    end
    self:setImageRect(config.poses[config.order[1]].offset, config.poses[config.order[1]].size)
    self.currentFlipbook = { timers.new(config.pausable,
        {
            type = 'multiple',
            time = config.wait,
            countNum = #config.order,
            execute = function(t)
                self:setImageRect(config.poses[config.order[t]].offset, config.poses[config.order[t]].size)
            end,
            completed = function()
                self:setImageRect(config.poses[config.order[1]].offset, config.poses[config.order[1]].size)
            end
        }), config
    }
end

function Image:draw(parent_rect, content_only)
    local d = rawget(self, "__data")
    local rt = rawget(self, "__rt")
    if not rt then
        rt = Element._sync_runtime_all(self)
    end
    local image = (rt and rt.image) or (d and d.image)
    local opacity = (rt and rt.opacity) or (d and d.opacity) or 1
    if not (rt and rt.visible ~= false) or not image or opacity == 0 then
        return
    end
    rawset(self, "isdrawn", true)

    local rect              = Element.get_screen_rect(self, parent_rect)
    local child_parent_rect = rect
    if rt.destretch_isolate_children then
        local tmp = rawget(self, "_tmp_child_rect_opts") or {}
        tmp.ignore_destretch_size = true
        child_parent_rect = Element.get_screen_rect(self, parent_rect, tmp)
        rawset(self, "_tmp_child_rect_opts", tmp)
    end
    Element.draw_box(self, rect, rt, d)

    local size = rect.size
    local ax   = rect._ax or (size.x * rt.asx + rt.aox)
    local ay   = rect._ay or (size.y * rt.asy + rt.aoy)
    local rotation = (rt and rt.screen_rotation) or rect.rotation or 0
    local draw_x = (rt and rt.x) or rect.position.x
    local draw_y = (rt and rt.y) or rect.position.y

    local color = rt.color or d.color
    local r, g, b, a = color[1], color[2], color[3], color[4] * opacity
    local shader = rt.shader
    local shaderParams = rt.shaderParams
    local draw_data = rt

    if rotation == 0 then
        if shader then
            local pad = rt.quad_pad or 0
            Image._renderFrameToCanvas(self, size, draw_data)

            for pname, pval in pairs(shaderParams or {}) do
                if pname ~= 'time' then
                    shader:send(pname, pval)
                end
            end
            if shaderParams and shaderParams.time then
                shader:send("t", love.timer.getTime())
            end

            love.graphics.push("all")
            love.graphics.setBlendMode("alpha", "premultiplied")
            love.graphics.setShader(shader)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(rawget(self, "_shaderCanvas"), draw_x - pad, draw_y - pad)
            love.graphics.pop()
        else
            love.graphics.setColor(r, g, b, a)
            if rt.scale_type == "tile" then
                Image._drawTiled(self, size, draw_data, draw_x, draw_y)
            elseif rt.scale_type == "slice" then
                Image._drawSliced(self, size, draw_data, draw_x, draw_y)
            else
                Image._drawScaled(self, size, draw_data, draw_x, draw_y)
            end
        end
    else
        love.graphics.push()

        love.graphics.translate(rect.position.x + ax, rect.position.y + ay)
        love.graphics.rotate(rotation)
        love.graphics.translate(-ax, -ay)

        if shader then
            local pad = rt.quad_pad or 0
            Image._renderFrameToCanvas(self, size, draw_data)

            for pname, pval in pairs(shaderParams or {}) do
                if pname ~= 'time' then
                    shader:send(pname, pval)
                end
            end
            if shaderParams and shaderParams.time then
                shader:send("t", love.timer.getTime())
            end

            love.graphics.push("all")
            love.graphics.setBlendMode("alpha", "premultiplied")
            love.graphics.setShader(shader)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(rawget(self, "_shaderCanvas"), -pad, -pad)
            love.graphics.pop()
        else
            love.graphics.setColor(r, g, b, a)
            if rt.scale_type == "tile" then
                Image._drawTiled(self, size, draw_data)
            elseif rt.scale_type == "slice" then
                Image._drawSliced(self, size, draw_data)
            else
                Image._drawScaled(self, size, draw_data)
            end
        end

        love.graphics.pop()
    end

    local ch = rt.children or {}
    if not content_only and #ch > 0 then
        if rt.scissor then
            local force_canvas = rt.force_canvas or rt.render_to_canvas or rt.canvas_cache or rt.cache_children or
                math.abs(rotation or 0) > 1e-6
            local clip_mode = Element._choose_clip_mode(self, rt, #ch, force_canvas)
            if clip_mode == "cached_canvas" then
                Image._drawChildrenWithCanvas(self, child_parent_rect,
                    rt.destretch_isolate_children and child_parent_rect.size or size, ax, ay)
            else
                local clip_pos = rt.destretch_isolate_children and child_parent_rect.position or rect.position
                local clip_size = rt.destretch_isolate_children and child_parent_rect.size or size
                Element._push_clip_scissor(clip_pos.x, clip_pos.y, clip_size.x, clip_size.y)
                local sorted = Element._get_sorted_children_cached(self)
                for i = 1, #sorted do Element._draw_child(sorted[i], child_parent_rect) end
                Element._pop_clip_scissor()
            end
        else
            local sorted = Element._get_sorted_children_cached(self)
            for i = 1, #sorted do Element._draw_child(sorted[i], child_parent_rect) end
        end
    end
end

function Image:_ensureShaderCanvas(size, pad)
    local w = math.max(1, math.floor(size.x + 0.5) + pad * 2)
    local h = math.max(1, math.floor(size.y + 0.5) + pad * 2)
    local shader_canvas = rawget(self, "_shaderCanvas")
    local shader_canvas_size = rawget(self, "_shaderCanvasSize")
    if not Surface.matches(shader_canvas, w, h)
        or shader_canvas_size.x ~= w
        or shader_canvas_size.y ~= h then
        rawset(self, "_shaderCanvas", Element._new_canvas and Element._new_canvas(w, h) or love.graphics.newCanvas(w, h))
        rawset(self, "_shaderCanvasSize", vec2(w, h))
    end
end

function Image:_renderFrameToCanvas(size, d)
    local pad = (d and d.quad_pad) or 0
    self:_ensureShaderCanvas(size, pad)

    if Element._bump_canvas_redraw then Element._bump_canvas_redraw() end
    local oldColor = { love.graphics.getColor() }
    local sx, sy, sw, sh = love.graphics.getScissor()
    love.graphics.push("all")
    love.graphics.origin()
    local prevCanvas = Surface.capture_render_target()
    love.graphics.setCanvas(rawget(self, "_shaderCanvas"))
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.setScissor()
    love.graphics.clear(0, 0, 0, 0)

    love.graphics.translate(pad, pad)

    local r, g, b, a = d.color[1], d.color[2], d.color[3], d.color[4] * (d.opacity or 1)
    love.graphics.setColor(r, g, b, a)

    if d.scale_type == "tile" then
        Image._drawTiled(self, size, d)
    elseif d.scale_type == "slice" then
        Image._drawSliced(self, size, d)
    else
        Image._drawScaled(self, size, d)
    end

    Surface.restore_render_target(prevCanvas)
    if sx then love.graphics.setScissor(sx, sy, sw, sh) else love.graphics.setScissor() end
    love.graphics.pop()
    love.graphics.setColor(oldColor)
end

function Image:_drawScaled(size, d, dx, dy)
    d = d or rawget(self, "__data")
    dx = dx or 0
    dy = dy or 0
    local iw = rawget(self, "_srcW")
    local ih = rawget(self, "_srcH")
    if not iw or not ih or iw == 0 or ih == 0 then return end

    local mode = d.scale_type
    if mode == "crop" then
        return Image._drawCropped(self, size, d, dx, dy)
    end
    local flip_x = d.flip_x
    local flip_y = d.flip_y
    local quad = d.quad
    local image = d.image

    local w = size.x
    local h = size.y
    local cache = rawget(self, "_scaled_draw_cache")
    local sx, sy, ox, oy
    if cache
        and cache.w == w and cache.h == h
        and cache.iw == iw and cache.ih == ih
        and cache.mode == mode
        and cache.flip_x == flip_x and cache.flip_y == flip_y
        and cache.quad == quad then
        sx, sy, ox, oy = cache.sx, cache.sy, cache.ox, cache.oy
    else
        local rx, ry = w / iw, h / ih
        if mode == "stretch" then
            sx, sy = rx, ry
        elseif mode == "fit" then
            sx = math.min(rx, ry)
            sy = sx
        elseif mode == "fill" then
            sx = math.max(rx, ry)
            sy = sx
        else
            sx, sy = rx, ry
        end

        ox = flip_x and iw or 0
        oy = flip_y and ih or 0
        if flip_x then sx = -sx end
        if flip_y then sy = -sy end

        cache = cache or {}
        cache.w, cache.h = w, h
        cache.iw, cache.ih = iw, ih
        cache.mode = mode
        cache.flip_x = flip_x
        cache.flip_y = flip_y
        cache.quad = quad
        cache.sx = sx
        cache.sy = sy
        cache.ox = ox
        cache.oy = oy
        rawset(self, "_scaled_draw_cache", cache)
    end

    if quad then
        love.graphics.draw(image, quad, dx, dy, 0, sx, sy, ox, oy)
    else
        love.graphics.draw(image, dx, dy, 0, sx, sy, ox, oy)
    end
end

--[[ scale_type "crop": fill the rect at uniform max scale and window the
source so the overflow is cut by sampling, not scissor. honors an active
imageRect quad by offsetting the window inside it ]]
function Image:_drawCropped(size, d, dx, dy)
    d = d or rawget(self, "__data")
    dx = dx or 0
    dy = dy or 0
    local iw = rawget(self, "_srcW")
    local ih = rawget(self, "_srcH")
    if not iw or not ih or iw == 0 or ih == 0 then return end
    local w, h = size.x, size.y
    if w <= 0 or h <= 0 then return end

    local image = d.image
    local base_x, base_y = 0, 0
    if d.quad then
        base_x, base_y = d.quad:getViewport()
    end

    local scale = math.max(w / iw, h / ih)
    local window_w = w / scale
    local window_h = h / scale
    local window_x = base_x + (iw - window_w) * 0.5
    local window_y = base_y + (ih - window_h) * 0.5

    local key = window_x .. ":" .. window_y .. ":" .. window_w .. ":" .. window_h
    local quad = rawget(self, "_crop_quad")
    if not quad or rawget(self, "_crop_quad_key") ~= key then
        local img_w, img_h = image:getDimensions()
        quad = love.graphics.newQuad(window_x, window_y, window_w, window_h, img_w, img_h)
        rawset(self, "_crop_quad", quad)
        rawset(self, "_crop_quad_key", key)
    end

    local ox = d.flip_x and window_w or 0
    local oy = d.flip_y and window_h or 0
    love.graphics.draw(image, quad, dx, dy, 0,
        d.flip_x and -scale or scale,
        d.flip_y and -scale or scale,
        ox, oy)
end

--[[ scale_type "slice": 9-slice via d.slice_center {x0,y0,x1,y1} in source
pixels (relative to the imageRect window when one is set). corners stay at
native size (uniformly shrunk when the rect is smaller than the borders),
edges stretch along one axis, the center stretches both. flip is ignored ]]
function Image:_drawSliced(size, d, dx, dy)
    d = d or rawget(self, "__data")
    dx = dx or 0
    dy = dy or 0
    local slice = d.slice_center or (rawget(self, "__data") or {}).slice_center
    local iw = rawget(self, "_srcW")
    local ih = rawget(self, "_srcH")
    if not slice or not iw or not ih or iw == 0 or ih == 0 then
        return Image._drawScaled(self, size, d, dx, dy)
    end
    local w, h = size.x, size.y
    if w <= 0 or h <= 0 then return end

    local image = d.image
    local img_w, img_h = image:getDimensions()
    local base_x, base_y = 0, 0
    if d.quad then
        base_x, base_y = d.quad:getViewport()
    end

    local left = math.max(0, math.min(slice.x0 or 0, iw))
    local top = math.max(0, math.min(slice.y0 or 0, ih))
    local right = math.max(0, iw - math.max(left, math.min(slice.x1 or iw, iw)))
    local bottom = math.max(0, ih - math.max(top, math.min(slice.y1 or ih, ih)))
    local mid_w = math.max(0, iw - left - right)
    local mid_h = math.max(0, ih - top - bottom)

    --[[ shrink borders uniformly when the destination is smaller than them ]]
    local shrink = math.min(1,
        (left + right) > 0 and w / (left + right) or 1,
        (top + bottom) > 0 and h / (top + bottom) or 1)
    local dst_l = left * shrink
    local dst_r = right * shrink
    local dst_t = top * shrink
    local dst_b = bottom * shrink
    local dst_mid_w = math.max(0, w - dst_l - dst_r)
    local dst_mid_h = math.max(0, h - dst_t - dst_b)

    local key = base_x .. ":" .. base_y .. ":" .. left .. ":" .. top .. ":" .. right .. ":" .. bottom
        .. ":" .. iw .. ":" .. ih
    local quads = rawget(self, "_slice_quads")
    if not quads or rawget(self, "_slice_quads_key") ~= key then
        local src_x = { base_x, base_x + left, base_x + left + mid_w }
        local src_y = { base_y, base_y + top, base_y + top + mid_h }
        local src_w = { left, mid_w, right }
        local src_h = { top, mid_h, bottom }
        quads = {}
        for row = 1, 3 do
            for col = 1, 3 do
                if src_w[col] > 0 and src_h[row] > 0 then
                    quads[(row - 1) * 3 + col] = love.graphics.newQuad(
                        src_x[col], src_y[row], src_w[col], src_h[row], img_w, img_h)
                end
            end
        end
        rawset(self, "_slice_quads", quads)
        rawset(self, "_slice_quads_key", key)
    end

    local dst_x = { dx, dx + dst_l, dx + dst_l + dst_mid_w }
    local dst_y = { dy, dy + dst_t, dy + dst_t + dst_mid_h }
    local dst_w = { dst_l, dst_mid_w, dst_r }
    local dst_h = { dst_t, dst_mid_h, dst_b }
    local src_w = { left, mid_w, right }
    local src_h = { top, mid_h, bottom }
    for row = 1, 3 do
        for col = 1, 3 do
            local quad = quads[(row - 1) * 3 + col]
            if quad and dst_w[col] > 0 and dst_h[row] > 0 then
                love.graphics.draw(image, quad, dst_x[col], dst_y[row], 0,
                    dst_w[col] / src_w[col], dst_h[row] / src_h[row])
            end
        end
    end
end

function Image:_drawTiled(size, d, dx, dy)
    d = d or rawget(self, "__data")
    dx = dx or 0
    dy = dy or 0
    local image = d.image
    local quad = d.quad
    local flip_x = d.flip_x
    local flip_y = d.flip_y

    local canRepeat = image:getWrap() ~= "clamp" and not quad and not flip_x and not flip_y
    if canRepeat then
        image:setWrap("repeat", "repeat")
        local iw, ih = image:getDimensions()
        local tw = math.max(1, math.floor(size.x + 0.5))
        local th = math.max(1, math.floor(size.y + 0.5))
        local q = rawget(self, "_tile_quad")
        if not q or rawget(self, "_tile_quad_w") ~= tw or rawget(self, "_tile_quad_h") ~= th then
            q = love.graphics.newQuad(0, 0, tw, th, iw, ih)
            rawset(self, "_tile_quad", q)
            rawset(self, "_tile_quad_w", tw)
            rawset(self, "_tile_quad_h", th)
        end
        love.graphics.draw(image, q, dx, dy)
        return
    end

    local tile_size = d.tile_size
    local tilesX = math.ceil(size.x / tile_size.x)
    local tilesY = math.ceil(size.y / tile_size.y)

    local ox, oy = 0, 0
    if flip_x then
        ox = rawget(self, "_srcW")
    end
    if flip_y then
        oy = rawget(self, "_srcH")
    end

    local sx = tile_size.x / rawget(self, "_srcW") * (flip_x and -1 or 1)
    local sy = tile_size.y / rawget(self, "_srcH") * (flip_y and -1 or 1)

    if quad then
        for ix = 0, tilesX - 1 do
            for iy = 0, tilesY - 1 do
                love.graphics.draw(image, quad,
                    dx + ix * tile_size.x,
                    dy + iy * tile_size.y,
                    0, sx, sy, ox, oy)
            end
        end
    else
        for ix = 0, tilesX - 1 do
            for iy = 0, tilesY - 1 do
                love.graphics.draw(image,
                    dx + ix * tile_size.x,
                    dy + iy * tile_size.y,
                    0, sx, sy, ox, oy)
            end
        end
    end
end

function Image:_drawChildrenWithCanvas(rect, size, ax, ay)
    local w = math.max(1, math.floor(size.x + 0.5))
    local h = math.max(1, math.floor(size.y + 0.5))
    local canvas = rawget(self, "_canvas")
    if not Surface.matches(canvas, w, h) then
        canvas = Element._new_canvas and Element._new_canvas(w, h) or love.graphics.newCanvas(w, h)
        rawset(self, "_canvas", canvas)
        rawset(self, "_canvas_dirty", true)
    end

    if rawget(self, "_canvas_dirty") then
        rawset(self, "_canvas_dirty", false)
        if Element._bump_canvas_redraw then Element._bump_canvas_redraw() end
        local cp = rawget(self, "_canvas_parent")
        if not cp then
            cp = { position = vec2(), size = size:clone(), _v = 1, _w = size.x, _h = size.y }
            rawset(self, "_canvas_parent", cp)
        else
            cp.size = size
            if cp._w ~= size.x or cp._h ~= size.y then
                cp._w = size.x
                cp._h = size.y
                cp._v = (cp._v or 0) + 1
            end
        end

        local oldColor = { love.graphics.getColor() }
        local sx, sy, sw, sh = love.graphics.getScissor()
        love.graphics.push("all")
        love.graphics.origin()
        local prevCanvas = Surface.capture_render_target()
        love.graphics.setCanvas(canvas)
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha", "alphamultiply")
        love.graphics.setScissor()
        love.graphics.clear(0, 0, 0, 0)
        local sorted = Element._get_sorted_children_cached(self)
        for i = 1, #sorted do Element._draw_child(sorted[i], cp) end
        Surface.restore_render_target(prevCanvas)
        if sx then love.graphics.setScissor(sx, sy, sw, sh) else love.graphics.setScissor() end
        love.graphics.pop()
        love.graphics.setColor(oldColor)
    end

    love.graphics.push("all")
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, rect.position.x + ax, rect.position.y + ay,
        rect.rotation, 1, 1, ax, ay)
    love.graphics.pop()
end

function Image:invalidate_graphics_reset()
    rawset(self, "_shaderCanvas", nil)
    rawset(self, "_shaderCanvasSize", nil)
    Element.invalidate_graphics_reset(self)
end
