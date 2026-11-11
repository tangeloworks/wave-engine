---@class Element: Object
---@overload fun(args?: ElementArgs): Element
Element = Object:extend()
local Surface = require("engine/graphics/surface")

local ROOT_PARENT_RECT = {
    position = vec2(),
    size = vec2(G.resolution.x, G.resolution.y)
}

local _stretch_setting_ref = nil
local _ratio_setting_ref = nil
local _root_last_w, _root_last_h = nil, nil
local _root_last_stretch, _root_last_ratio = nil, nil
local _layout_mode_cached_frame = nil
local _layout_mode_cached_stretch = false
local _layout_mode_cached_ratio = false

local function _ensure_layout_settings_refs()
    if not _stretch_setting_ref then
        _stretch_setting_ref = CFG:getSetting('stretch')
    end
    if not _ratio_setting_ref then
        _ratio_setting_ref = CFG:getSetting('ratio4by3')
    end
end

local function _read_layout_modes()
    local frame_id = G.frame_id or 0
    if _layout_mode_cached_frame == frame_id then
        return _layout_mode_cached_stretch, _layout_mode_cached_ratio
    end

    if not _stretch_setting_ref or not _ratio_setting_ref then
        _ensure_layout_settings_refs()
    end

    _layout_mode_cached_stretch = (_stretch_setting_ref and _stretch_setting_ref.value) or false
    _layout_mode_cached_ratio = (_ratio_setting_ref and _ratio_setting_ref.value) or false
    _layout_mode_cached_frame = frame_id
    return _layout_mode_cached_stretch, _layout_mode_cached_ratio
end

local function _get_stretch_enabled()
    local stretch = _stretch_setting_ref
    if not stretch then
        _ensure_layout_settings_refs()
        stretch = _stretch_setting_ref
    end
    return (stretch and stretch.value) or false
end

local function _get_ratio_mode_enabled()
    local ratio = _ratio_setting_ref
    if not ratio then
        _ensure_layout_settings_refs()
        ratio = _ratio_setting_ref
    end
    return (ratio and ratio.value) or false
end

AllElements = {}

local ZSEQ_COUNTER = 0
local INSTANCE_MT_CACHE = setmetatable({}, { __mode = "k" })

local AUTO_CACHE_CHILD_THRESHOLD = 24
local AUTO_CACHE_STABLE_FRAMES = 8
local RENDER_BATCH_MIN_ITEMS = 4

Element.compiled_render_enabled = false
Element.compiled_render_batches = true

function Element.set_compiled_render_enabled(enabled)
    Element.compiled_render_enabled = enabled == true
end

function Element.set_render_batching_enabled(enabled)
    Element.compiled_render_batches = enabled ~= false
end

local function _mark_render_compile_dirty(element, include_ancestors)
    if not element then return end
    -- Until the first compiled render list exists, every element already
    -- starts compile-dirty and there is no cached command data to invalidate
    -- avoid version churn and ancestor walks in the default live renderer
    -- once compilation is used this flag stays set, preserving invalidation
    -- if the feature is later toggled off and back on
    if not rawget(Element, "_compiled_render_ever_used") then return end
    rawset(element, "_render_version", (rawget(element, "_render_version") or 0) + 1)
    rawset(element, "_render_subtree_version", (rawget(element, "_render_subtree_version") or 0) + 1)
    rawset(element, "_render_compile_dirty", true)
    if include_ancestors then
        local rt = rawget(element, "__rt")
        local d = (not rt) and rawget(element, "__data")
        local p = (rt and rt.linked) or (d and d.linked)
        while p do
            rawset(p, "_render_subtree_version", (rawget(p, "_render_subtree_version") or 0) + 1)
            rawset(p, "_render_compile_dirty", true)
            local prt = rawget(p, "__rt")
            local pd = (not prt) and rawget(p, "__data")
            p = (prt and prt.linked) or (pd and pd.linked)
        end
    end
end

local function Udim2Preset(given)
    given = given or {}
    return {
        scale = given.scale and given.scale:clone() or vec2(),
        offset = given.offset and given.offset:clone() or vec2()
    }
end

local function compute_so(spec, parent_size)
    if spec then
        return parent_size * (spec.scale or vec2()) + (spec.offset or vec2())
    end
    return vec2()
end

local function update_root_parent_rect()
    local w, h = G.resolution.x, G.resolution.y

    local stretch, ratio_mode = _read_layout_modes()
    local rr = ROOT_PARENT_RECT

    if rr._v
        and _root_last_w == w
        and _root_last_h == h
        and _root_last_stretch == stretch
        and _root_last_ratio == ratio_mode then
        return
    end
    _root_last_w, _root_last_h = w, h
    _root_last_stretch, _root_last_ratio = stretch, ratio_mode

    local px, py, sx, sy

    if ratio_mode then
        local design = G:get_ratio_resolution()
        local bw, bh = design.x, design.y
        local s = math.min(w / bw, h / bh)
        sx, sy = bw * s, bh * s
        px, py = (w - sx) * 0.5, (h - sy) * 0.5
    else
        px, py, sx, sy = 0, 0, w, h
    end

    local changed = rr.position.x ~= px or rr.position.y ~= py or rr.size.x ~= sx or rr.size.y ~= sy
    if not changed then
        if not rr._v then rr._v = 1 end
        return
    end

    rr.position.x = px
    rr.position.y = py
    rr.size.x = sx
    rr.size.y = sy
    rr._v = (rr._v or 0) + 1

    input_mgr.mouse.update_display_offsets()

    Element._root_layout_version = (Element._root_layout_version or 0) + 1
end

local function _sync_udim_runtime(rt, key, ud)
    ud = ud or {}
    local scale = ud.scale
    local offset = ud.offset
    local sx = (scale and scale.x) or 0
    local sy = (scale and scale.y) or 0
    local ox = (offset and offset.x) or 0
    local oy = (offset and offset.y) or 0

    if key == "position" then
        rt.position = ud
        rt.psx, rt.psy, rt.pox, rt.poy = sx, sy, ox, oy
    elseif key == "size" then
        rt.size = ud
        rt.ssx, rt.ssy, rt.sox, rt.soy = sx, sy, ox, oy
    elseif key == "anchor" then
        rt.anchor = ud
        rt.asx, rt.asy, rt.aox, rt.aoy = sx, sy, ox, oy
    end
end

local function _sync_runtime_key(obj, key, d, rt)
    d = d or rawget(obj, "__data")
    if not d then return nil end
    rt = rt or rawget(obj, "__rt")
    if not rt then
        rt = {}
        rawset(obj, "__rt", rt)
    end

    if key == nil then
        rt.data = d
        _sync_udim_runtime(rt, "position", d.position)
        _sync_udim_runtime(rt, "size", d.size)
        _sync_udim_runtime(rt, "anchor", d.anchor)
        rt.children = d.children
        rt.linked = d.linked
        rt.rotation = d.rotation or 0
        rt.z = d.zindex or 0
        rt.visible = d.visible ~= false
        rt.opacity = d.opacity or 1
        rt.destretch = d.destretch == true
        rt.destretch_clip = d.destretch_clip == true
        rt.destretch_size = d.destretch_size == true
        rt.destretch_isolate_children = d.destretch_isolate_children == true
        rt.noBoundRotate = d.noBoundRotate == true
        rt.scissor = d.scissor
        rt.clip = d.scissor ~= nil and d.scissor ~= false
        rt.clip_mode = d.clip_mode or d.clipMode or "auto"
        rt.cache_children = d.cache_children == true
        rt.canvas_cache = d.canvas_cache == true
        rt.render_to_canvas = d.render_to_canvas == true
        rt.force_canvas = d.force_canvas == true
        rt.cache_threshold = d.cache_threshold or d.cacheThreshold or AUTO_CACHE_CHILD_THRESHOLD
        rt.scroll = d.scroll
        rt.shader = d.shader
        rt.shaderUniforms = d.shaderUniforms
        rt.on_draw = d.on_draw
        rt.fill_color = d.fill_color
        rt.outline_color = d.outline_color
        rt.outline_thickness = d.outline_thickness or 0
        rt.show_fill = d.show_fill == true
        rt.show_outline = d.show_outline == true
        rt.mousecheck = d.mousecheck == true
        rt.selectable = d.selectable == true
        rt.editable = d.editable == true
        rt.focusable = d.focusable == true
        rt.image = d.image
        rt.quad = d.quad
        rt.color = d.color
        rt.scale_type = d.scale_type or d.scaleType
        rt.tile_size = d.tile_size
        rt.flip_x = d.flip_x == true
        rt.flip_y = d.flip_y == true
        rt.shaderParams = d.shaderParams
        rt.quad_pad = d.quad_pad or 0
        rt.text = d.text
        rt.font = d.font
        rt.fontSize = d.fontSize
        return rt
    end

    if key == "position" or key == "size" or key == "anchor" then
        _sync_udim_runtime(rt, key, d[key])
    elseif key == "children" then
        rt.children = d.children
    elseif key == "linked" then
        rt.linked = d.linked
    elseif key == "rotation" then
        rt.rotation = d.rotation or 0
    elseif key == "zindex" then
        rt.z = d.zindex or 0
    elseif key == "visible" then
        rt.visible = d.visible ~= false
    elseif key == "opacity" then
        rt.opacity = d.opacity or 1
    elseif key == "destretch" or key == "destretch_clip" or key == "destretch_size" or key == "destretch_isolate_children" then
        rt.destretch = d.destretch == true
        rt.destretch_clip = d.destretch_clip == true
        rt.destretch_size = d.destretch_size == true
        rt.destretch_isolate_children = d.destretch_isolate_children == true
    elseif key == "noBoundRotate" then
        rt.noBoundRotate = d.noBoundRotate == true
    elseif key == "scissor" then
        rt.scissor = d.scissor
        rt.clip = d.scissor ~= nil and d.scissor ~= false
    elseif key == "clip_mode" or key == "clipMode" then
        rt.clip_mode = d.clip_mode or d.clipMode or "auto"
    elseif key == "cache_children" then
        rt.cache_children = d.cache_children == true
    elseif key == "canvas_cache" then
        rt.canvas_cache = d.canvas_cache == true
    elseif key == "render_to_canvas" then
        rt.render_to_canvas = d.render_to_canvas == true
    elseif key == "force_canvas" then
        rt.force_canvas = d.force_canvas == true
    elseif key == "cache_threshold" or key == "cacheThreshold" then
        rt.cache_threshold = d.cache_threshold or d.cacheThreshold or AUTO_CACHE_CHILD_THRESHOLD
    elseif key == "scroll" then
        rt.scroll = d.scroll
    elseif key == "shader" then
        rt.shader = d.shader
    elseif key == "shaderUniforms" then
        rt.shaderUniforms = d.shaderUniforms
    elseif key == "on_draw" then
        rt.on_draw = d.on_draw
    elseif key == "fill_color" then
        rt.fill_color = d.fill_color
    elseif key == "outline_color" then
        rt.outline_color = d.outline_color
    elseif key == "outline_thickness" then
        rt.outline_thickness = d.outline_thickness or 0
    elseif key == "show_fill" then
        rt.show_fill = d.show_fill == true
    elseif key == "show_outline" then
        rt.show_outline = d.show_outline == true
    elseif key == "mousecheck" then
        rt.mousecheck = d.mousecheck == true
    elseif key == "selectable" then
        rt.selectable = d.selectable == true
    elseif key == "editable" then
        rt.editable = d.editable == true
    elseif key == "focusable" then
        rt.focusable = d.focusable == true
    elseif key == "image" then
        rt.image = d.image
    elseif key == "quad" then
        rt.quad = d.quad
    elseif key == "color" then
        rt.color = d.color
    elseif key == "scale_type" or key == "scaleType" then
        rt.scale_type = d.scale_type or d.scaleType
    elseif key == "tile_size" then
        rt.tile_size = d.tile_size
    elseif key == "flip_x" then
        rt.flip_x = d.flip_x == true
    elseif key == "flip_y" then
        rt.flip_y = d.flip_y == true
    elseif key == "shaderParams" then
        rt.shaderParams = d.shaderParams
    elseif key == "quad_pad" then
        rt.quad_pad = d.quad_pad or 0
    elseif key == "text" then
        rt.text = d.text
    elseif key == "font" then
        rt.font = d.font
    elseif key == "fontSize" then
        rt.fontSize = d.fontSize
    end

    return rt
end

local function _store_runtime_rect(rt, r)
    if not rt or not r then return end
    rt.x = r.position.x
    rt.y = r.position.y
    rt.width = r.size.x
    rt.height = r.size.y
    rt.screen_rotation = r.rotation or 0
end

function Element._sync_runtime_key(obj, key)
    return _sync_runtime_key(obj, key)
end

function Element._sync_runtime_all(obj)
    return _sync_runtime_key(obj, nil)
end

function Element.get_root_parent_rect()
    update_root_parent_rect()
    return ROOT_PARENT_RECT
end

local function _scissorPixels(x, y, w, h)
    -- a direct screen presentation may retain authored canvas units
    -- under a viewport transform. the mapping is opt-in and scoped by that
    -- presenter, ordinary Element layouts keep their existing coordinates
    local transform = rawget(Element, "_clip_coordinate_transform")
    if transform then
        local x1, y1 = transform:transformPoint(x + w, y + h)
        x, y = transform:transformPoint(x, y)
        w, h = x1 - x, y1 - y
    end
    -- setScissor already applies target DPI in LÖVE 11.x
    return Surface.scissor(x, y, w, h)
end

local function _setScissorRaw(x, y, w, h)
    love.graphics.setScissor(x, y, w, h)
end

local function _pushScissorPixels(x, y, w, h)
    local stack = rawget(Element, "_clip_scissor_stack")
    if not stack then
        stack = {}
        rawset(Element, "_clip_scissor_stack", stack)
    end
    local n = (rawget(Element, "_clip_scissor_depth") or 0) + 1
    rawset(Element, "_clip_scissor_depth", n)
    local sx, sy, sw, sh = love.graphics.getScissor()
    local slot = stack[n] or {}
    stack[n] = slot
    slot.x, slot.y, slot.w, slot.h = sx, sy, sw, sh
    slot.set = sx ~= nil

    local px, py, pw, ph = _scissorPixels(x, y, math.max(0, w), math.max(0, h))
    if sx then
        love.graphics.intersectScissor(px, py, pw, ph)
        return
    end

    if sx then
        local ix1 = math.max(px, sx)
        local iy1 = math.max(py, sy)
        local ix2 = math.min(px + pw, sx + sw)
        local iy2 = math.min(py + ph, sy + sh)
        px, py = ix1, iy1
        pw, ph = math.max(0, ix2 - ix1), math.max(0, iy2 - iy1)
    end
    _setScissorRaw(px, py, pw, ph)
end

local function _popScissorPixels()
    local stack = rawget(Element, "_clip_scissor_stack")
    local n = rawget(Element, "_clip_scissor_depth") or 0
    if n == 0 then
        _setScissorRaw()
        return
    end
    local slot = stack[n]
    -- retain the slot for the next frame. Scissor depth is generally stable,
    -- so this turns one table allocation per clipped element per frame into a
    -- small high-water pool
    rawset(Element, "_clip_scissor_depth", n - 1)
    if slot.set then
        _setScissorRaw(slot.x, slot.y, slot.w, slot.h)
    else
        _setScissorRaw()
    end
end

local function _newCanvas(w, h, ...)
    return Surface.new_canvas(w, h, ...)
end

--[[ cached-canvas content is PREMULTIPLIED (alpha-blended onto transparent);
compositing it with plain alphamultiply re-multiplies alpha, dimming every
semi-transparent pixel, cached_canvas and scissor clip modes rendered
translucent content differently ]]
local function _draw_cached_canvas(canvas, x, y)
    local bm, am = love.graphics.getBlendMode()
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, x, y)
    love.graphics.setBlendMode(bm, am)
end

function Element._draw_cached_canvas(canvas, x, y)
    return _draw_cached_canvas(canvas, x, y)
end

--[[ mark every scroll/scissor ancestor's cached canvas for a redraw (they
composite this element). reset_stability additionally kicks them out of
cached-canvas mode, right when the content will keep changing every frame
(animation, pending deferred builds), wrong for one-shot changes (a single
redraw is cheaper than 8 live frames + re-cache) ]]
function Element._refresh_ancestor_canvases(el, reset_stability)
    local rt = rawget(el, "__rt") or Element._sync_runtime_all(el)
    local p = rt and rt.linked
    while p do
        local prt = rawget(p, "__rt") or Element._sync_runtime_all(p)
        local pscroll = prt and prt.scroll
        if prt and ((pscroll and pscroll.enabled) or prt.scissor) then
            if reset_stability then
                rawset(p, "_clip_static_frames", 0)
                rawset(p, "_clip_cache_dirty", true)
            end
            --[[ no early-out on an already-dirty ancestor: _canvas_dirty is
            set in several places without upward propagation, so a dirty inner
            canvas can sit inside a clean outer canvas that would never redraw
            it. the walk is bounded by tree depth, always mark to the root ]]
            rawset(p, "_canvas_dirty", true)
        end
        p = prt and prt.linked
    end
end

function Element._new_canvas(w, h, ...)
    return _newCanvas(w, h, ...)
end

function Element._push_clip_scissor(x, y, w, h)
    return _pushScissorPixels(x, y, w, h)
end

function Element._pop_clip_scissor()
    return _popScissorPixels()
end

local function _is_editor_active()
    local now = love.timer.getTime()
    return (G._ui_editor_active_until or 0) > now
end

local function _canvas_forced(rt, rotation)
    return (rt.force_canvas or rt.render_to_canvas or rt.canvas_cache or rt.cache_children or rt.shader
        or math.abs(rotation or 0) > 1e-6)
end

function Element._choose_clip_mode(element, rt, child_count, force_canvas)
    local mode = (rt and rt.clip_mode) or "auto"
    if mode == "canvas" then mode = "cached_canvas" end
    -- a screen-aligned scissor cannot represent a rotated viewport. Geometry
    -- owns this choice even when the caller prefers the cheaper clip mode
    if force_canvas then return "cached_canvas" end
    if mode == "scissor" then
        rawset(element, "_clip_static_frames", 0)
        return "scissor"
    end
    if mode == "cached_canvas" or force_canvas then
        return "cached_canvas"
    end

    if _is_editor_active() or Element._has_dynamic_descendants(element) then
        rawset(element, "_clip_static_frames", 0)
        return "scissor"
    end

    local threshold = (rt and rt.cache_threshold) or AUTO_CACHE_CHILD_THRESHOLD
    if (child_count or 0) < threshold then
        rawset(element, "_clip_static_frames", 0)
        return "scissor"
    end

    local stable = (rawget(element, "_clip_static_frames") or 0) + 1
    rawset(element, "_clip_static_frames", stable)
    if stable >= AUTO_CACHE_STABLE_FRAMES then
        return "cached_canvas"
    end
    return "scissor"
end

Element._property_dirty = {
    position = true,
    size = true,
    anchor = true,
    rotation = true,
    destretch = true,
    destretch_clip = true,
    destretch_size = true,
    destretch_isolate_children = true,
    zindex = true,
    fill_color = true,
    outline_color = true,
    outline_thickness = true,
    show_fill = true,
    show_outline = true,
    visible = true,
    opacity = true,
    shader = true,
    shaderUniforms = true,
    scissor = true,
    clip_mode = true,
    clipMode = true,
    cache_children = true,
    canvas_cache = true,
    render_to_canvas = true,
    force_canvas = true,
    cache_threshold = true,
    cacheThreshold = true,
    scroll = true,
    mousecheck = true,
    selectable = true,
    editable = true,
    doubleClickEditable = true,
    focusable = true,
    layoutId = true,
    properties = true,
    linked = true,
    text = true,
    fontSize = true,
    font = true,
    fontPath = true,
    textAlignX = true,
    textAlignY = true,
    textScaled = true,
    textFits = true,
    clayWrap = true,
    clayPadding = true,
    textScale = true,
    lineHeight = true,
    letterSpacing = true,
    wrapMode = true,
    maxWidth = true,
    textColor = true,
    fastText = true,
    richText = true,
    excerpt = true,
    deferFont = true,
    loadFontInDraw = true,
    scaleQuantize = true,
    scaleBakeThreshold = true,
    italic = true,
    bold = true,
    weight = true,
    stretchX = true,
    stretchY = true,
    outlineColor = true,
    outlineThickness = true,
    image = true,
    path = true,
    source = true,
    resample_mode = true,
    resampleMode = true,
    scale_type = true,
    scaleType = true,
    tile_size = true,
    flip_x = true,
    flip_y = true,
    color = true,
    quad = true,
    shaderParams = true,
    on_draw = true
}

Element._wrap_keys = {
    position = true, size = true, anchor = true, shaderUniforms = true
}

-- keys that change geometry and require recomputing screen rect
Element._geom_dirty_keys = {
    position = true,
    size = true,
    anchor = true,
    rotation = true,
    destretch = true,
    destretch_clip = true,
    destretch_size = true,
    destretch_isolate_children = true,
    scissor = true,
    clip_mode = true,
    clipMode = true,
    linked = true,
    parent_update = true
}

-- keys that imply children need updates when they change on this element
Element._cascade_children_keys = {
    position = true,
    size = true,
    anchor = true,
    rotation = true,
    destretch = true,
    destretch_clip = true,
    destretch_size = true,
    destretch_isolate_children = true,
    scissor = true,
    clip_mode = true,
    clipMode = true,
    linked = true,
    parent_update = true
}

--[[ paint-only keys: the element rect, child layout, clip-mode stability and
scroll auto-size are all unaffected, the change needs a runtime-key sync, a
render-compile invalidation, and ONE refresh of any ancestor cached canvas
that composites this element. everything else (geometry stamps, clip-stability
resets, self canvas redraws) is wasted work for these, and the clip resets
actively fight _choose_clip_mode: a color tween used to kick its cached-canvas
ancestors back to live scissor redraws for 8 frames per change
box fill/outline draw OUTSIDE the element's own child canvas, so the element's
own _canvas stays valid. ambiguous keys (opacity: compiled-path eligibility;
outline_thickness: draws past rect bounds) stay in the conservative path ]]
Element._visual_dirty_keys = {
    fill_color = true,
    outline_color = true,
    show_fill = true,
    show_outline = true,
    color = true, -- image tint
    flip_x = true,
    flip_y = true,
    imageRect = true, -- image quad viewport (position/size of the rect stay put)
}

Element._sort_children_cmp = function(a, b)
    if a.z ~= b.z then return a.z < b.z end
    if a.seq ~= b.seq then return a.seq < b.seq end
    return a.idx < b.idx
end

local function wrap_autodirty(owner, t, reason)
    local mt = getmetatable(t)
    if mt and mt.__owner == owner then return t end
    return setmetatable(t or {}, {
        __owner = owner,
        __newindex = function(tab, kk, vv)
            local prev = rawget(tab, kk)
            if prev == vv then return end
            rawset(tab, kk, vv)
            _sync_runtime_key(owner, reason)
            if not rawget(owner, "__suspend_dirty") then
                local mark_dirty = rawget(owner, "_mark_dirty_fn") or Element.mark_dirty
                mark_dirty(owner, reason)
            end
        end
    })
end

function Element.__make_instance_mt(cls)
    local cached = INSTANCE_MT_CACHE[cls]
    if cached then return cached end

    local on_prop_changed = cls.on_property_changed
    local mark_dirty = cls.mark_dirty or Element.mark_dirty
    local mt = {
        __class = cls,
        __index = function(obj, k)
            local rv = rawget(obj, k)
            if rv ~= nil then return rv end
            local d = rawget(obj, "__data")
            local v = d and d[k]
            if v ~= nil then return v end
            local cv = cls[k]
            if cv ~= nil then return cv end
            if type(k) == "string" then
                if k:byte(1) == 95 then return nil end
                local neg = rawget(obj, "__neg_child_key")
                if neg and neg[k] then return nil end
                local map = rawget(obj, "__child_name_map")
                local child
                if map then
                    child = map[k]
                    if child then
                        local cd = rawget(child, "__data")
                        if not cd or cd.linked ~= obj then
                            child = nil
                            rawset(obj, "__child_name_map", nil)
                            rawset(obj, "__neg_child_key", nil)
                        end
                    end
                end

                if not child then
                    local nd = d
                    local ch = nd and nd.children
                    if ch then
                        map = {}
                        for i = 1, #ch do
                            local c = ch[i]
                            if c then
                                local cd = rawget(c, "__data")
                                local nm = cd and cd.name
                                if nm and not map[nm] and cd and cd.linked == obj then
                                    map[nm] = c
                                end
                            end
                        end
                        rawset(obj, "__child_name_map", map)
                        child = map[k]
                    end
                end

                if child ~= nil then return child end
                local negset = rawget(obj, "__neg_child_key")
                if not negset then
                    negset = {}
                    rawset(obj, "__neg_child_key", negset)
                end
                negset[k] = true
            end

            return nil
        end,
        __newindex = function(obj, k, v)
            if type(k) == "string" and (k == "isdrawn" or k:byte(1) == 95) then
                rawset(obj, k, v)
                return
            end

            local d = rawget(obj, "__data")
            if not d then return end
            local suspend_dirty = rawget(obj, "__suspend_dirty")

            if (k == "position" or k == "size" or k == "anchor") and type(v) == "table" and type(d[k]) == "table" then
                local existing = d[k]
                if existing.scale or existing.offset then
                    local changed = false
                    if v.scale ~= nil and existing.scale ~= v.scale then
                        rawset(existing, "scale", v.scale)
                        changed = true
                    end
                    if v.offset ~= nil and existing.offset ~= v.offset then
                        rawset(existing, "offset", v.offset)
                        changed = true
                    end
                    if changed and not suspend_dirty then
                        _sync_runtime_key(obj, k, d)
                        mark_dirty(obj, k)
                    elseif changed then
                        _sync_runtime_key(obj, k, d)
                    end
                    return
                end
            end

            if Element._wrap_keys[k] and type(v) == "table" then
                v = wrap_autodirty(obj, v, k)
            end

            local old = d[k]
            if old == v then return end
            d[k] = v
            if k == "clipMode" then
                d.clip_mode = v
            elseif k == "clip_mode" then
                d.clipMode = v
            elseif k == "cacheThreshold" then
                d.cache_threshold = v
            elseif k == "cache_threshold" then
                d.cacheThreshold = v
            elseif k == "scaleType" then
                d.scale_type = v
            elseif k == "scale_type" then
                d.scaleType = v
            elseif k == "resampleMode" then
                d.resample_mode = v
            elseif k == "resample_mode" then
                d.resampleMode = v
            end
            _sync_runtime_key(obj, k, d)

            if k == "draw" then
                if type(v) == "function" then
                    rawset(obj, "_draw_fn", v)
                else
                    rawset(obj, "_draw_fn", cls.draw or Element.draw)
                end
            elseif k == "draw_self" then
                local draw_self_fn = (type(v) == "function") and v or (cls.draw_self or Element.draw_self)
                rawset(obj, "_draw_self_fn", draw_self_fn)
                rawset(obj, "_has_custom_draw", (draw_self_fn ~= Element.draw_self))
            elseif k == "on_draw" then
                local on_draw_fn = (type(v) == "function") and v or nil
                rawset(obj, "_on_draw_fn", on_draw_fn)
                rawset(obj, "_has_on_draw", on_draw_fn ~= nil)
            end

            if on_prop_changed then
                on_prop_changed(obj, k, old, v)
            end

            if k == 'name' then
                local parent = d.linked
                if parent then
                    rawset(parent, "__child_name_map", nil)
                    rawset(parent, "__neg_child_key", nil)
                end
            elseif k == 'linked' then
                if old then
                    rawset(old, "__child_name_map", nil)
                    rawset(old, "__neg_child_key", nil)
                    rawset(old, "_child_order_dirty", true)
                    rawset(old, "_layout_order_dirty", true)
                    rawset(old, "_layout_dirty", true)
                end
                if v then
                    rawset(v, "__child_name_map", nil)
                    rawset(v, "__neg_child_key", nil)
                    rawset(v, "_child_order_dirty", true)
                    rawset(v, "_layout_order_dirty", true)
                    rawset(v, "_layout_dirty", true)
                end
            end

            if k == 'zindex' then
                ZSEQ_COUNTER = ZSEQ_COUNTER + 1
                rawset(obj, "_zseq", ZSEQ_COUNTER)
                local parent = d.linked
                if parent then
                    rawset(parent, "_child_order_dirty", true)
                end
            end

            if k == 'layoutId' then
                local parent = d.linked
                if parent then
                    rawset(parent, "_layout_order_dirty", true)
                    rawset(parent, "_layout_dirty", true)
                end
            elseif k == 'size' then
                -- a resized box reflows its own layout and its parent's
                rawset(obj, "_layout_dirty", true)
                local parent = d.linked
                if parent then
                    rawset(parent, "_layout_dirty", true)
                end
            end

            if k == 'fill_color' and obj.originalColors and type(v) == 'table' then
                obj.originalColors.fill = { unpack(v) }
            elseif k == 'outline_color' and obj.originalColors and type(v) == 'table' then
                obj.originalColors.outline = { unpack(v) }
            elseif k == 'outline_thickness' and obj.originalColors then
                obj.originalColors.thickness = v
            end

            if k == 'visible' and v == false and not suspend_dirty then
                if obj.state then
                    obj.state.hovered = false
                    obj.state.pressed = false
                    if obj.state.selected then obj:setSelected(false) end
                    if obj.state.focused then obj:set_focused(false) end
                end
                obj:updateVisualState()
            elseif k == 'mousecheck' and v == false and not suspend_dirty then
                if obj.state then
                    obj.state.hovered = false
                    obj.state.pressed = false
                end
                obj:updateVisualState()
            elseif k == 'selectable' and v == false and not suspend_dirty then
                if obj.state and obj.state.selected then
                    obj:setSelected(false)
                end
            elseif k == 'editable' and v == false and not suspend_dirty then
                if obj.state and obj.state.focused then
                    obj:set_focused(false)
                end
            end

            if Element._property_dirty[k] and not suspend_dirty then
                mark_dirty(obj, k)
            end
        end,
        __pairs = function(obj)
            return next, rawget(obj, "__data"), nil
        end
    }
    INSTANCE_MT_CACHE[cls] = mt
    return mt
end

function Element.get_sorted_children(children)
    if type(children) == "table" and rawget(children, "__data") then
        return Element._get_sorted_children_cached(children)
    end

    local list = children or {}
    local n = #list
    if n == 0 then return {} end
    if n == 1 then return { list[1] } end

    local tmp = {}
    for i = 1, n do
        local c = list[i]
        local rt = c and rawget(c, "__rt")
        local cd = (not rt) and c and rawget(c, "__data")
        tmp[i] = {
            child = c,
            idx = i,
            z = (rt and rt.z) or (cd and cd.zindex) or 0,
            seq = (c and rawget(c, "_zseq")) or
                0
        }
    end

    table.sort(tmp, Element._sort_children_cmp)
    local out = {}
    for i = 1, #tmp do out[i] = tmp[i].child end
    return out
end

function Element._draw_child(child, parent_rect)
    local draw_fn = rawget(child, "_draw_fn")
    if draw_fn then
        return draw_fn(child, parent_rect)
    end
    return child:draw(parent_rect)
end

---@param args? ElementArgs
function Element:init(args)
    args = args or {}
    local cls = getmetatable(self) or Element

    local d = {}
    rawset(self, "__data", d)
    rawset(self, "__rt", {})
    rawset(self, "__suspend_dirty", true)
    setmetatable(self, Element.__make_instance_mt(cls))
    rawset(self, "_mark_dirty_fn", cls.mark_dirty or Element.mark_dirty)
    rawset(self, "_draw_fn", cls.draw or Element.draw)
    rawset(self, "_draw_self_fn", cls.draw_self or Element.draw_self)
    rawset(self, "_has_custom_draw", (cls.draw_self ~= Element.draw_self))
    rawset(self, "_on_draw_fn", type(args.on_draw) == "function" and args.on_draw or nil)
    rawset(self, "_has_on_draw", type(args.on_draw) == "function")

    local resScale = G.resScaleFactor or 1

    d.name = args.name or "NULL"
    d.linked = args.linked
    d.position = wrap_autodirty(self, Udim2Preset(args.position), 'position')
    d.size = wrap_autodirty(self, Udim2Preset(args.size or { offset = vec2(100, 100) }), 'size')
    d.anchor = wrap_autodirty(self, Udim2Preset(args.anchor), 'anchor')
    d.rotation = args.rotation or 0
    d.zindex = args.zindex or 0
    d.destretch = args.destretch or false
    d.destretch_clip = args.destretch_clip or false
    d.destretch_size = args.destretch_size or false
    d.destretch_isolate_children = args.destretch_isolate_children or false
    d.children = {}
    d.outline_color = args.outline_color or { 1, .3, .1, 1 }
    d.outline_thickness = (args.outline_thickness or 2) * resScale
    d.fill_color = args.fill_color or { .1, .3, .9, .3 }
    d.show_outline = args.show_outline or false
    d.show_fill = args.show_fill or false
    d.visible = args.visible ~= false
    d.properties = args.properties or {}
    d.layoutId = args.layoutId
    d.scissor = args.scissor
    d.clip_mode = args.clip_mode or args.clipMode or "auto"
    d.clipMode = d.clip_mode
    d.cache_children = args.cache_children or false
    d.canvas_cache = args.canvas_cache or false
    d.render_to_canvas = args.render_to_canvas or false
    d.force_canvas = args.force_canvas or false
    d.cache_threshold = args.cache_threshold or args.cacheThreshold
    d.cacheThreshold = d.cache_threshold
    rawset(self, "_screen_rect", { position = vec2(), size = vec2(), rotation = 0, _ax = 0, _ay = 0 })
    rawset(self, "_needs_update", true)
    rawset(self, "_cache_geom_version", 0)
    rawset(self, "_geom_version", 0)
    rawset(self, "_children_geom_version", 0)
    rawset(self, "_child_order_dirty", true)
    rawset(self, "_layout_order_dirty", true)
    rawset(self, "_canvas_dirty", true)
    rawset(self, "_render_version", 1)
    rawset(self, "_render_subtree_version", 1)
    rawset(self, "_render_compile_dirty", true)
    rawset(self, "_scroll_auto_size_dirty", true)
    d.shader = args.shader
    d.shaderUniforms = wrap_autodirty(self, args.shaderUniforms or {}, 'shaderUniforms')
    d.on_draw = args.on_draw

    d.no_hover = args.no_hover
    d.mousecheck = args.mousecheck
    d.selectable = args.selectable
    d.editable = args.editable
    d.focusable = args.focusable

    d.state = {
        hovered = false,
        selected = false,
        pressed = false,
        focused = false
    }
    rawset(self, "isdrawn", false)

    d.on_text_changed = args.on_text_changed
    d.on_mouse_enter = args.on_mouse_enter
    d.on_mouse_leave = args.on_mouse_leave
    d.on_mouse_click = args.on_mouse_click
    d.on_mouse_release = args.on_mouse_release
    d.on_mouse_clicked = args.on_mouse_clicked
    d.on_mouse_move = args.on_mouse_move
    d.on_touch_press = args.on_touch_press
    d.on_touch_move = args.on_touch_move
    d.on_touch_release = args.on_touch_release
    d.on_selected = args.on_selected
    d.on_deselected = args.on_deselected
    d.onFocus = args.onFocus
    d.onBlur = args.onBlur
    d.onKeyPress = args.onKeyPress
    d.onKeyRelease = args.onKeyRelease
    d.onTextInput = args.onTextInput
    d.on_key_press = args.on_key_press
    d.on_key_release = args.on_key_release
    d.on_text_input = args.on_text_input

    if d.mousecheck == nil then
        if d.on_mouse_click or d.on_mouse_clicked or d.on_mouse_enter or d.on_mouse_leave
            or args.on_mouse_move or d.on_touch_press or d.on_touch_move or d.on_touch_release then
            d.mousecheck = true
        end
    end

    Element.updateShaders(self)

    local initial_scroll_pos = args.scroll and (args.scroll.canvasPosition or vec2()) or vec2()
    local initial_scroll_target = args.scroll and (args.scroll.canvasTarget or args.scroll.targetPosition) or nil
    d.scroll = args.scroll and {
        enabled = args.scroll.enabled,
        canvasSize = args.scroll.canvasSize,
        canvasPosition = initial_scroll_pos,
        _targetPosition = vec2(
            (initial_scroll_target and initial_scroll_target.x) or initial_scroll_pos.x or 0,
            (initial_scroll_target and initial_scroll_target.y) or initial_scroll_pos.y or 0
        ),
        padding = args.scroll.padding or vec2(),
        vertical = args.scroll.vertical,
        horizontal = args.scroll.horizontal,
        smooth = (args.scroll.smooth == nil) and true or args.scroll.smooth,
        smoothSpeed = args.scroll.smoothSpeed or args.scroll.lerpSpeed or args.scroll.lerp_speed or 24,
        smoothEpsilon = args.scroll.smoothEpsilon or args.scroll.snapEpsilon or 0.1,
        barThickness = (args.scroll.barThickness or 6) * resScale,
        externalScrollbar = args.scroll.externalScrollbar == true,
        barInset = (args.scroll.barInset or 2) * resScale,
        barColor = args.scroll.barColor or { 1, 1, 1, .9 },
        barBgColor = args.scroll.barBgColor or { 0, 0, 0, .3 }
    } or nil

    _sync_runtime_key(self, nil, d, rawget(self, "__rt"))

    if not d.linked then
        local exists = false
        for _, e in ipairs(AllElements) do
            if e == self then
                exists = true
                break
            end
        end
        if not exists then table.insert(AllElements, self) end
    end

    if d.linked then
        Element.set_linked(self, d.linked)
    end

    setmetatable(d.children, {
        __newindex = function(t, k, v)
            rawset(t, k, v)
            if type(v) == "table" and rawget(v, "__data") then
                Element.set_linked(v, self)
            end
            rawset(self, "__child_name_map", nil)
            rawset(self, "__neg_child_key", nil)
            rawset(self, "_child_order_dirty", true)
            rawset(self, "_layout_order_dirty", true)
            rawset(self, "_layout_dirty", true)
            rawset(self, "_dynamic_tree_dirty", true)
            Element.mark_dirty(self, 'linked')
        end
    })

    rawset(self, "__suspend_dirty", false)
end

function Element.isElement(obj)
    if type(obj) ~= "table" then return false end

    local mt = getmetatable(obj)
    if type(mt) == "table" and mt.__class then
        local cls = mt.__class
        while type(cls) == "table" do
            if cls == Element then return true end
            cls = rawget(cls, "super") or getmetatable(cls)
        end
    end

    local cls = obj
    while type(cls) == "table" do
        if cls == Element then return true end
        cls = rawget(cls, "super") or getmetatable(cls)
    end

    return false
end

function Element:updateShaders(newt)
    local d = rawget(self, "__data")
    if newt then
        self.shaderUniforms = newt
        d = rawget(self, "__data")
    end
    local rt = rawget(self, "__rt")
    if not rt or rt.data ~= d then
        rt = _sync_runtime_key(self, nil, d, rt)
    end
    local shader = rt and rt.shader
    local uniforms = (rt and rt.shaderUniforms) or (d and d.shaderUniforms)
    if shader and uniforms then
        for k, v in pairs(uniforms) do
            if k ~= "t" then
                shader:send(k, v)
            end
        end
    end
end

function Element:set_linked(new_linked)
    local d = rawget(self, "__data")
    local old_linked = d and d.linked or self.linked
    if old_linked == new_linked then return end

    local was_root = not old_linked
    self.linked = new_linked

    if was_root then
        for i = #AllElements, 1, -1 do
            if AllElements[i] == self then
                table.remove(AllElements, i)
            end
        end
    elseif not new_linked then
        local exists = false
        for _, e in ipairs(AllElements) do
            if e == self then
                exists = true
                break
            end
        end
        if not exists then
            table.insert(AllElements, self)
        end
    end

    if old_linked then
        old_linked._child_order_dirty = true
        old_linked._layout_order_dirty = true
        old_linked._layout_dirty = true
    end
    if new_linked then
        new_linked._child_order_dirty = true
        new_linked._layout_order_dirty = true
        new_linked._layout_dirty = true
    end
    _mark_render_compile_dirty(self, true)
    if old_linked then _mark_render_compile_dirty(old_linked, true) end
    if new_linked then _mark_render_compile_dirty(new_linked, true) end
end

local function _rect_intersect(a, bx, by, bw, bh, out)
    if type(bx) == "table" then
        local b = bx
        out = by
        bx, by, bw, bh = b.x, b.y, b.w, b.h
    end
    if type(bx) ~= "number" or type(by) ~= "number" or type(bw) ~= "number" or type(bh) ~= "number" then
        return nil
    end
    local x1 = math.max(a.x, bx)
    local y1 = math.max(a.y, by)
    local x2 = math.min(a.x + a.w, bx + bw)
    local y2 = math.min(a.y + a.h, by + bh)

    if x2 <= x1 or y2 <= y1 then return nil end
    local o = out or a
    o.x = x1
    o.y = y1
    o.w = x2 - x1
    o.h = y2 - y1
    return o
end

-- Layout resolves in parent-local axes. Carry the child pivot with its
-- parent's world rotation, then apply the child's own local rotation. Canvas
-- parents have no rotation, their final blit remains the single owner
local function compose_parent_rotation(rect, parent)
    local angle = parent and parent.rotation or 0
    if angle == 0 then return end
    local px = parent.position.x + (parent._ax or parent.size.x * .5)
    local py = parent.position.y + (parent._ay or parent.size.y * .5)
    local ax, ay = rect._ax or 0, rect._ay or 0
    local dx, dy = rect.position.x + ax - px, rect.position.y + ay - py
    local c, s = math.cos(angle), math.sin(angle)
    rect.position.x = px + c * dx - s * dy - ax
    rect.position.y = py + s * dx + c * dy - ay
    rect.rotation = angle + rect.rotation
end

function Element._rect_local_point(rect, px, py)
    local ax, ay = rect._ax or rect.size.x * .5, rect._ay or rect.size.y * .5
    local dx, dy = px - rect.position.x - ax, py - rect.position.y - ay
    local angle = rect.rotation or 0
    local c, s = math.cos(angle), math.sin(angle)
    local x, y = c * dx + s * dy + ax, -s * dx + c * dy + ay
    return x,y
end

function Element._point_in_rect(rect, px, py)
    local x,y=Element._rect_local_point(rect,px,py)
    return x >= 0 and x <= rect.size.x and y >= 0 and y <= rect.size.y
end

function Element._rect_corners(rect)
    local ax, ay = rect._ax or rect.size.x * .5, rect._ay or rect.size.y * .5
    local c, s = math.cos(rect.rotation or 0), math.sin(rect.rotation or 0)
    local px, py = rect.position.x + ax, rect.position.y + ay
    local function q(x, y) return px+c*(x-ax)-s*(y-ay), py+s*(x-ax)+c*(y-ay) end
    local x1,y1=q(0,0);local x2,y2=q(rect.size.x,0)
    local x3,y3=q(rect.size.x,rect.size.y);local x4,y4=q(0,rect.size.y)
    return x1,y1,x2,y2,x3,y3,x4,y4
end

function Element._rect_bounds(rect)
    if (rect.rotation or 0)==0 then return rect.position.x,rect.position.y,rect.size.x,rect.size.y end
    local x1,y1,x2,y2,x3,y3,x4,y4=Element._rect_corners(rect)
    local x,y=math.min(x1,x2,x3,x4),math.min(y1,y2,y3,y4)
    return x,y,math.max(x1,x2,x3,x4)-x,math.max(y1,y2,y3,y4)-y
end

function Element:get_screen_rect(parent_rect, opts)
    local mode = (opts and opts.mode) or "visual"
    local ignore_destretch = (opts and opts.ignore_destretch_size) and true or false

    local d_self = rawget(self, "__data")
    local rt = rawget(self, "__rt")
    if not rt or rt.data ~= d_self then
        rt = _sync_runtime_key(self, nil, d_self, rt)
    end
    if parent_rect and opts == nil and d_self
        and not (rt.destretch or rt.destretch_clip or rt.destretch_size) then
        local parent_version = parent_rect._v or 0
        local parent_owner = parent_rect._owner
        local parent_child_version = parent_owner and (rawget(parent_owner, "_children_geom_version") or 0) or 0
        local needs_update = rawget(self, "_needs_update")
        local cache_parent_rect = rawget(self, "_cache_parent_rect")
        local cache_parent_version = rawget(self, "_cache_parent_version")
        local cache_parent_child_version = rawget(self, "_cache_parent_child_version")
        local cache_geom_version = rawget(self, "_cache_geom_version")
        local geom_version = rawget(self, "_geom_version")
        local screen_rect = rawget(self, "_screen_rect")
        if not needs_update
            and (cache_geom_version or 0) == (geom_version or 0)
            and cache_parent_rect == parent_rect
            and (cache_parent_version or 0) == parent_version
            and (cache_parent_child_version or 0) == parent_child_version
            and rawget(self, "_cache_mode") == "visual"
            and rawget(self, "_cache_ignore_destretch_size") ~= true
            and (rawget(self, "_cache_scroll_x") or 0) == 0
            and (rawget(self, "_cache_scroll_y") or 0) == 0 then
            return screen_rect
        end

        local ppos, psz = parent_rect.position, parent_rect.size
        local abs_w = psz.x * rt.ssx + rt.sox
        local abs_h = psz.y * rt.ssy + rt.soy
        local shift_x = abs_w * rt.asx + rt.aox
        local shift_y = abs_h * rt.asy + rt.aoy

        local r = screen_rect
        r.position.x = ppos.x + psz.x * rt.psx + rt.pox - shift_x
        r.position.y = ppos.y + psz.y * rt.psy + rt.poy - shift_y
        r.size.x = abs_w
        r.size.y = abs_h
        r.rotation = (rt.noBoundRotate and 0) or rt.rotation
        r._ax = shift_x
        r._ay = shift_y
        compose_parent_rotation(r, parent_rect)
        r._clip = nil

        rawset(self, "_needs_update", false)
        r._v = (r._v or 0) + 1
        r._owner = self
        _store_runtime_rect(rt, r)
        rawset(self, "_cache_parent_rect", parent_rect)
        rawset(self, "_cache_parent_version", parent_version)
        rawset(self, "_cache_parent_child_version", parent_child_version)
        rawset(self, "_cache_mode", "visual")
        rawset(self, "_cache_ignore_destretch_size", false)
        rawset(self, "_cache_scroll_x", 0)
        rawset(self, "_cache_scroll_y", 0)
        rawset(self, "_cache_geom_version", geom_version or 0)
        return r
    end

    local linked = rt and rt.linked
    local p_rect = parent_rect
    local scroll_off_x, scroll_off_y = 0, 0
    local stretch, ratio_mode = false, false
    local layout_modes_loaded = false
    if not p_rect then
        stretch, ratio_mode = _read_layout_modes()
        layout_modes_loaded = true
        if linked then
            local linked_rt = rawget(linked, "__rt") or Element._sync_runtime_all(linked)
            local pass_opts = opts
            if linked_rt and linked_rt.destretch_isolate_children then
                local tmp = rawget(self, "_tmp_pass_opts") or {}
                tmp.mode = mode
                tmp.ignore_destretch_size = true
                pass_opts = tmp
                rawset(self, "_tmp_pass_opts", tmp)
            end

            local linked_scroll = linked_rt and linked_rt.scroll
            if linked_scroll and linked_scroll.enabled and mode == "visual" then
                local tmpc = rawget(self, "_tmp_pass_opts_canvas") or {}
                tmpc.mode = "canvas"
                tmpc.ignore_destretch_size = (pass_opts and pass_opts.ignore_destretch_size) and true or false
                p_rect = Element.get_screen_rect(linked, nil, tmpc)
                rawset(self, "_tmp_pass_opts_canvas", tmpc)
                scroll_off_x = (linked_scroll.canvasPosition and linked_scroll.canvasPosition.x) or 0
                scroll_off_y = (linked_scroll.canvasPosition and linked_scroll.canvasPosition.y) or 0
            else
                p_rect = Element.get_screen_rect(linked, nil, pass_opts)
            end
        else
            local w, h = G.resolution.x, G.resolution.y
            local rr = ROOT_PARENT_RECT
            if (not rr._v)
                or _root_last_w ~= w
                or _root_last_h ~= h
                or _root_last_stretch ~= stretch
                or _root_last_ratio ~= ratio_mode then
                update_root_parent_rect()
            end
            p_rect = rr
        end
    end

    local parent_version = p_rect and (p_rect._v or 0) or 0
    local parent_owner = p_rect and p_rect._owner
    local parent_child_version = parent_owner and (rawget(parent_owner, "_children_geom_version") or 0) or 0
    local needs_update = rawget(self, "_needs_update")
    local cache_parent_rect = rawget(self, "_cache_parent_rect")
    local cache_parent_version = rawget(self, "_cache_parent_version")
    local cache_parent_child_version = rawget(self, "_cache_parent_child_version")
    local cache_mode = rawget(self, "_cache_mode")
    local cache_ignore_destretch_size = rawget(self, "_cache_ignore_destretch_size")
    local cache_scroll_x = rawget(self, "_cache_scroll_x")
    local cache_scroll_y = rawget(self, "_cache_scroll_y")
    local cache_geom_version = rawget(self, "_cache_geom_version")
    local geom_version = rawget(self, "_geom_version")
    local screen_rect = rawget(self, "_screen_rect")
    if not needs_update
        and (cache_geom_version or 0) == (geom_version or 0)
        and cache_parent_rect == p_rect
        and (cache_parent_version or 0) == parent_version
        and (cache_parent_child_version or 0) == parent_child_version
        and cache_mode == mode
        and (cache_ignore_destretch_size or false) == ignore_destretch
        and (cache_scroll_x or 0) == scroll_off_x
        and (cache_scroll_y or 0) == scroll_off_y then
        return screen_rect
    end

    local ppos, psz = p_rect.position, p_rect.size
    if not layout_modes_loaded and (rt.destretch or rt.destretch_clip or rt.destretch_size) then
        stretch, ratio_mode = _read_layout_modes()
    end

    local destretch_clip_active = (((rt.destretch or rt.destretch_clip)) and (not stretch) and (not ratio_mode)) or
        false
    local destretch_size_active = (((rt.destretch or rt.destretch_size)) and (not stretch) and (not ratio_mode)) or
        false
    if ignore_destretch then
        destretch_size_active = false
    end

    local ref_w, ref_h = psz.x, psz.y
    if destretch_size_active then
        ref_w, ref_h = G.resolution.x, G.resolution.y
    end

    local abs_w = ref_w * rt.ssx + rt.sox
    local abs_h = ref_h * rt.ssy + rt.soy
    local abs_x = ppos.x + psz.x * rt.psx + rt.pox
    local abs_y = ppos.y + psz.y * rt.psy + rt.poy
    if destretch_size_active then
        abs_x = abs_x - ppos.x
        abs_y = abs_y - ppos.y
    end

    local shift_x = abs_w * rt.asx + rt.aox
    local shift_y = abs_h * rt.asy + rt.aoy

    local r = screen_rect
    r.position.x = abs_x - shift_x - scroll_off_x
    r.position.y = abs_y - shift_y - scroll_off_y
    r.size.x = abs_w
    r.size.y = abs_h
    r.rotation = (rt.noBoundRotate and 0) or rt.rotation
    r._ax = shift_x
    r._ay = shift_y
    compose_parent_rotation(r, p_rect)

    if mode == "visual" and not parent_rect then
        local clip = screen_rect._clip
        local stretch2 = stretch
        local ratio_mode2 = ratio_mode
        if destretch_clip_active then
            clip = clip or {}
            clip.x, clip.y, clip.w, clip.h = 0, 0, G.resolution.x, G.resolution.y
        else
            if not stretch2 and not ratio_mode2 then
                local rr = ROOT_PARENT_RECT
                clip = clip or {}
                clip.x, clip.y, clip.w, clip.h = rr.position.x, rr.position.y, rr.size.x, rr.size.y
            else
                clip = clip or {}
                clip.x, clip.y, clip.w, clip.h = 0, 0, G.resolution.x, G.resolution.y
            end
        end
        local a = rt.linked
        local clip_opts = rawget(self, "_tmp_clip_visual_opts")
        if not clip_opts then
            clip_opts = { mode = "visual", ignore_destretch_size = false }
            rawset(self, "_tmp_clip_visual_opts", clip_opts)
        end

        while a and clip do
            local art = rawget(a, "__rt") or Element._sync_runtime_all(a)
            if art and ((art.scroll and art.scroll.enabled) or art.scissor) then
                clip_opts.ignore_destretch_size = art.destretch_isolate_children and true or false
                local ar = Element.get_screen_rect(a, nil, clip_opts)
                local x,y,w,h=Element._rect_bounds(ar)
                clip = _rect_intersect(clip, x,y,w,h, clip)
            end
            a = art and art.linked
        end

        r._clip = clip
    else
        r._clip = nil
    end

    rawset(self, "_needs_update", false)
    r._v = (r._v or 0) + 1
    r._owner = self
    _store_runtime_rect(rt, r)
    rawset(self, "_cache_parent_rect", p_rect)
    rawset(self, "_cache_parent_version", parent_version)
    rawset(self, "_cache_parent_child_version", parent_child_version)
    rawset(self, "_cache_mode", mode)
    rawset(self, "_cache_ignore_destretch_size", ignore_destretch)
    rawset(self, "_cache_scroll_x", scroll_off_x)
    rawset(self, "_cache_scroll_y", scroll_off_y)
    rawset(self, "_cache_geom_version", geom_version or 0)
    return r
end

function Element:get_absolute_rect()
    local opts = rawget(self, "_tmp_visual_opts")
    if not opts then
        opts = { mode = "visual" }
        rawset(self, "_tmp_visual_opts", opts)
    end
    local r = Element.get_screen_rect(self, nil, opts)
    return r.position, r.size
end

function Element:get_drawn_rect()
    local opts = rawget(self, "_tmp_visual_opts")
    if not opts then
        opts = { mode = "visual" }
        rawset(self, "_tmp_visual_opts", opts)
    end
    local r = Element.get_screen_rect(self, nil, opts)
    local x, y, w, h = r.position.x, r.position.y, r.size.x, r.size.y
    local clip = r._clip
    if clip then
        local x1 = math.max(x, clip.x)
        local y1 = math.max(y, clip.y)
        local x2 = math.min(x + w, clip.x + clip.w)
        local y2 = math.min(y + h, clip.y + clip.h)
        local cw = math.max(0, x2 - x1)
        local ch = math.max(0, y2 - y1)
        return { position = vec2(x1, y1), size = vec2(cw, ch), rotation = r.rotation }
    end

    return { position = r.position:clone(), size = r.size:clone(), rotation = r.rotation }
end

---adds a child element and returns the same child with its exact inferred type
---this makes calls like `local label = root:add(Text { ... })` keep the `Text` interface
---@generic T
---@param child T
---@return T
function Element:add(child)
    local d = rawget(self, "__data")
    local children = d and d.children or self.children
    local n = #children + 1
    rawset(children, n, child)

    if type(child) == "table" and rawget(child, "__data") then
        Element.set_linked(child, self)
    end

    rawset(self, "__child_name_map", nil)
    rawset(self, "__neg_child_key", nil)
    rawset(self, "_child_order_dirty", true)
    rawset(self, "_layout_order_dirty", true)
    rawset(self, "_layout_dirty", true)
    rawset(self, "_dynamic_tree_dirty", true)
    Element.mark_dirty(self, 'linked')
    return child
end

---@return Element|nil
function Element:get_parent()
    return self.linked
end

---@return Element[]
function Element:get_children()
    local ch = self.children or {}
    local out = {}
    for i = 1, #ch do
        out[i] = ch[i]
    end
    return out
end

---@return Element[]
function Element:get_descendants()
    local out = {}

    local function scan(node)
        local ch = node.children or {}
        for i = 1, #ch do
            local child = ch[i]
            if Element.isElement(child) then
                out[#out + 1] = child
                scan(child)
            end
        end
    end

    scan(self)
    return out
end

---@return Element[]
function Element:get_ancestors()
    local out = {}
    local parent = self:get_parent()
    while parent do
        out[#out + 1] = parent
        parent = parent:get_parent()
    end
    return out
end

---@return Element
function Element:get_root()
    local root = self
    local parent = self:get_parent()
    while parent do
        root = parent
        parent = parent:get_parent()
    end
    return root
end

---@param possible_parent Element
---@return boolean
function Element:is_descendant_of(possible_parent)
    local parent = self:get_parent()
    while parent do
        if parent == possible_parent then
            return true
        end
        parent = parent:get_parent()
    end
    return false
end

---@param possible_child Element
---@return boolean
function Element:has_child(possible_child)
    local ch = self.children or {}
    for i = 1, #ch do
        if ch[i] == possible_child then
            return true
        end
    end
    return false
end

---@param name string
---@return Element|nil
function Element:get_child_by_name(name)
    if not name then return nil end
    local map = rawget(self, "__child_name_map")
    local child = map and map[name]
    if child then
        local cd = rawget(child, "__data")
        if cd and cd.linked == self then return child end
        rawset(self, "__child_name_map", nil)
        map, child = nil, nil
    end

    if not child then
        local d = rawget(self, "__data")
        local ch = d and d.children
        if ch then
            map = {}
            for i = 1, #ch do
                local c = ch[i]
                if c then
                    local cd = rawget(c, "__data")
                    local nm = cd and cd.name
                    if nm and not map[nm] and cd and cd.linked == self then
                        map[nm] = c
                    end
                end
            end
            rawset(self, "__child_name_map", map)
            child = map[name]
        end
    end

    return child or nil
end

---@param name string
---@return Element|nil
function Element:find_by_name(name)
    if not name then return nil end
    local direct = self:get_child_by_name(name)
    if direct then return direct end
    local ch = self.children or {}
    for i = 1, #ch do
        local c = ch[i]
        if Element.isElement(c) then
            local found = c:find_by_name(name)
            if found then return found end
        end
    end
    return nil
end

function Element:draw(parent_rect, content_only)
    if not content_only and Element._should_use_compiled_render and Element._should_use_compiled_render(self, parent_rect) then
        return Element.draw_compiled(self, parent_rect)
    end

    local d = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, d)
    if rt and rt.visible == false then return end

    if rawget(self, "_layout_active") and rawget(self, "_layout_dirty") then
        Element.apply_layout(self)
    end

    -- Global GUI paint order keeps the real tree for layout/input, and asks
    -- each retained widget to paint only its own content. default draw is
    -- unchanged, descendants and their ancestor clips are owned by that pass
    if content_only then
        rawset(self,"isdrawn",true)
        local rect=Element.get_screen_rect(self,parent_rect)
        Element.draw_box(self,rect,rt,d)
        if rt.scroll and rt.scroll.enabled and Element._draw_content_scrollbars then
            Element._draw_content_scrollbars(self,rect,rt)
        end
        return
    end

    --[[ childless leaf fast path: no children means the scroll/scissor clip
    machinery, destretch child-rect variant and sorted-children fetch are all
    dead branches, rect + draw_box is the whole job (draw_box handles
    on_draw/custom draw_self itself) ]]
    if (not d or not d.children or #d.children == 0)
        and not rt.scissor
        and not (rt.scroll and rt.scroll.enabled) then
        rawset(self, "isdrawn", true)
        return Element.draw_box(self, Element.get_screen_rect(self, parent_rect), rt, d)
    end

    rawset(self, "isdrawn", true)
    local rect = Element.get_screen_rect(self, parent_rect)
    local child_parent_rect = rect
    if rt and rt.destretch_isolate_children then
        local tmp = rawget(self, "_tmp_child_rect_opts") or {}
        tmp.ignore_destretch_size = true
        child_parent_rect = Element.get_screen_rect(self, parent_rect, tmp)
        rawset(self, "_tmp_child_rect_opts", tmp)
    end
    Element.draw_box(self, rect, rt, d)

    local sc = rt and rt.scroll
    if sc and sc.enabled then
        Element._updateCanvasSize(self)
        local cvs = (sc.canvasSize or sc._autoSize).offset
        local size = (rt and rt.destretch_isolate_children) and child_parent_rect.size or rect.size
        local scissor_pos = (rt and rt.destretch_isolate_children) and child_parent_rect.position or rect.position
        local sorted = Element._get_sorted_children_cached(self)
        local clip_mode = Element._choose_clip_mode(self, rt, #sorted, _canvas_forced(rt, rect.rotation))

        if clip_mode == "cached_canvas" then
            local rotated = math.abs(rect.rotation or 0) > 1e-6
            local cw = math.max(1, math.floor((rotated and size.x or cvs.x) + 0.5))
            local chh = math.max(1, math.floor((rotated and size.y or cvs.y) + 0.5))
            local canvas = rawget(self, "_canvas")
            if not Surface.matches(canvas, cw, chh) then
                canvas = _newCanvas(cw, chh)
                rawset(self, "_canvas", canvas)
                rawset(self, "_canvas_dirty", true)
            end

            if rawget(self, "_canvas_dirty") then
                --[[ clear BEFORE drawing children (like the scissor-clip cached
                path): a child that finishes deferred work mid-redraw re-marks
                this canvas dirty, and clearing afterwards would wipe that mark
                and latch the stale bake forever ]]
                rawset(self, "_canvas_dirty", false)
                rawset(self, "_clip_cache_dirty", false)
                local oldColor = { love.graphics.getColor() }
                local oldCanvas = Surface.capture_render_target()
                local sx, sy, sw, sh = love.graphics.getScissor()
                love.graphics.push("all")
                love.graphics.origin()
                love.graphics.setCanvas(canvas)
                love.graphics.setShader()
                love.graphics.setStencilTest()
                love.graphics.setDepthMode("always", false)
                love.graphics.setMeshCullMode("none")
                love.graphics.setBlendMode("alpha", "alphamultiply")
                _setScissorRaw()
                love.graphics.clear(0, 0, 0, 0)

                local subParent = rawget(self, "_scroll_canvas_parent")
                local px = rotated and -sc.canvasPosition.x or 0
                local py = rotated and -sc.canvasPosition.y or 0
                if not subParent then
                    subParent = { position = vec2(px, py), size = size:clone(), _v = 1, _x=px, _y=py, _w = size.x, _h = size.y }
                    rawset(self, "_scroll_canvas_parent", subParent)
                else
                    subParent.position.x = px
                    subParent.position.y = py
                    subParent.size = size
                    if subParent._w ~= size.x or subParent._h ~= size.y or subParent._x ~= px or subParent._y ~= py then
                        subParent._x,subParent._y=px,py
                        subParent._w = size.x
                        subParent._h = size.y
                        subParent._v = (subParent._v or 0) + 1
                    end
                end
                for i = 1, #sorted do
                    Element._draw_child(sorted[i], subParent)
                end

                Surface.restore_render_target(oldCanvas)
                if sx then _setScissorRaw(sx, sy, sw, sh) else _setScissorRaw() end
                love.graphics.pop()
                love.graphics.setColor(oldColor)
            end

            if rotated then
                love.graphics.push()
                love.graphics.translate(rect.position.x+rect._ax,rect.position.y+rect._ay)
                love.graphics.rotate(rect.rotation)
                love.graphics.translate(-rect._ax,-rect._ay)
                _draw_cached_canvas(canvas,0,0)
                love.graphics.pop()
            else
                _pushScissorPixels(scissor_pos.x, scissor_pos.y, size.x, size.y)
                local draw_x = math.floor(((rt.x or rect.position.x) - sc.canvasPosition.x) + 0.5)
                local draw_y = math.floor(((rt.y or rect.position.y) - sc.canvasPosition.y) + 0.5)
                _draw_cached_canvas(canvas, draw_x, draw_y)
                _popScissorPixels()
            end
            if Element._has_dynamic_descendants(self) then
                rawset(self, "_canvas_dirty", true)
            end
        else
            local subParent = rawget(self, "_scroll_canvas_parent")
            local px = scissor_pos.x - ((sc.canvasPosition and sc.canvasPosition.x) or 0)
            local py = scissor_pos.y - ((sc.canvasPosition and sc.canvasPosition.y) or 0)
            if not subParent then
                subParent = {
                    position = vec2(px, py),
                    size = size:clone(),
                    _v = 1,
                    _x = px,
                    _y = py,
                    _w = size.x,
                    _h =
                        size.y
                }
                rawset(self, "_scroll_canvas_parent", subParent)
            else
                subParent.position.x = px
                subParent.position.y = py
                subParent.size = size
                if subParent._x ~= px or subParent._y ~= py or subParent._w ~= size.x or subParent._h ~= size.y then
                    subParent._x = px
                    subParent._y = py
                    subParent._w = size.x
                    subParent._h = size.y
                    subParent._v = (subParent._v or 0) + 1
                end
            end
            _pushScissorPixels(scissor_pos.x, scissor_pos.y, size.x, size.y)
            for i = 1, #sorted do
                Element._draw_child(sorted[i], subParent)
            end
            _popScissorPixels()
        end

        local rotated_bars=math.abs(rect.rotation or 0)>1e-6
        if rotated_bars then
            love.graphics.push()
            love.graphics.translate(rect.position.x+rect._ax,rect.position.y+rect._ay)
            love.graphics.rotate(rect.rotation);love.graphics.translate(-rect._ax,-rect._ay)
            rect={position=vec2(0,0),size=rect.size}
        end
        local bx, by, bw = sc.barInset, sc.barInset, sc.barThickness

        if not sc.externalScrollbar and sc.vertical and cvs.y > size.y then
            local trackH = size.y - 2 * by
            local barLen = math.max(bw, trackH * (size.y / cvs.y))
            local maxScroll = cvs.y - size.y
            local ratio = (maxScroll == 0) and 0 or (sc.canvasPosition.y / maxScroll)
            local barY = rect.position.y + by + ratio * (trackH - barLen)

            local isHoverTrack = sc._hover_vert == 'track'
            local isHoverBar = sc._hover_vert == 'bar' or (sc._dragging and sc._dragging.vert)
            local trackColor = sc.barBgColor
            if isHoverTrack then
                love.graphics.setColor(0.5, 0.5, 0.5, (trackColor and trackColor[4]) or 0.3)
            else
                love.graphics.setColor(trackColor)
            end
            love.graphics.rectangle("fill", rect.position.x + size.x - bw - bx, rect.position.y + by, bw, trackH)
            local barColor = sc.barColor
            if isHoverBar then
                love.graphics.setColor(0.7, 0.7, 0.7, (barColor and barColor[4]) or 0.9)
            else
                love.graphics.setColor(barColor)
            end
            love.graphics.rectangle("fill", rect.position.x + size.x - bw - bx, barY, bw, barLen)
        end

        if not sc.externalScrollbar and sc.horizontal and cvs.x > size.x then
            local trackW = size.x - 2 * bx
            local barLen = math.max(bw, trackW * (size.x / cvs.x))
            local maxScroll = cvs.x - size.x
            local ratio = (maxScroll == 0) and 0 or (sc.canvasPosition.x / maxScroll)
            local barX = rect.position.x + bx + ratio * (trackW - barLen)

            local isHoverTrack = sc._hover_horz == 'track'
            local isHoverBar = sc._hover_horz == 'bar' or (sc._dragging and sc._dragging.horz)
            local trackColor = sc.barBgColor
            if isHoverTrack then
                love.graphics.setColor(0.5, 0.5, 0.5, (trackColor and trackColor[4]) or 0.3)
            else
                love.graphics.setColor(trackColor)
            end
            love.graphics.rectangle("fill", rect.position.x + bx, rect.position.y + size.y - bw - by, trackW, bw)
            local barColor = sc.barColor
            if isHoverBar then
                love.graphics.setColor(0.7, 0.7, 0.7, (barColor and barColor[4]) or 0.9)
            else
                love.graphics.setColor(barColor)
            end
            love.graphics.rectangle("fill", barX, rect.position.y + size.y - bw - by, barLen, bw)
        end

        if rotated_bars then love.graphics.pop()end
        return
    end

    if rt and rt.scissor then
        local size = rect.size
        local sorted = Element._get_sorted_children_cached(self)
        local clip_mode = Element._choose_clip_mode(self, rt, #sorted, _canvas_forced(rt, rect.rotation))
        if clip_mode == "cached_canvas" then
            local w = math.max(1, math.floor(size.x + 0.5))
            local h = math.max(1, math.floor(size.y + 0.5))
            local canvas = rawget(self, "_canvas")
            if not Surface.matches(canvas, w, h) then
                canvas = _newCanvas(w, h)
                rawset(self, "_canvas", canvas)
                rawset(self, "_canvas_dirty", true)
            end

            if rawget(self, "_canvas_dirty") then
                rawset(self, "_canvas_dirty", false)

                local cp = rawget(self, "_canvas_parent")
                if not cp then
                    cp = { position = vec2(), size = size:clone(), _v = 1, _w = size.x, _h = size.y }
                    rawset(self, "_canvas_parent", cp)
                else
                    cp.position.x = 0
                    cp.position.y = 0
                    cp.size = size
                    if cp._w ~= size.x or cp._h ~= size.y then
                        cp._w = size.x
                        cp._h = size.y
                        cp._v = (cp._v or 0) + 1
                    end
                end

                local oldColor = { love.graphics.getColor() }
                local oldCanvas = Surface.capture_render_target()
                local sx, sy, sw, sh = love.graphics.getScissor()
                love.graphics.push("all")
                love.graphics.origin()
                love.graphics.setCanvas(canvas)
                love.graphics.setShader()
                love.graphics.setStencilTest()
                love.graphics.setDepthMode("always", false)
                love.graphics.setMeshCullMode("none")
                love.graphics.setBlendMode("alpha", "alphamultiply")
                _setScissorRaw()
                love.graphics.clear(0, 0, 0, 0)

                for i = 1, #sorted do
                    Element._draw_child(sorted[i], cp)
                end

                Surface.restore_render_target(oldCanvas)
                if sx then _setScissorRaw(sx, sy, sw, sh) else _setScissorRaw() end
                love.graphics.pop()
                love.graphics.setColor(oldColor)
                rawset(self, "_clip_cache_dirty", false)
            end

            if Element._has_dynamic_descendants(self) then
                rawset(self, "_canvas_dirty", true)
            end

            love.graphics.push()
            local ax = rect._ax or (size.x * rt.asx + rt.aox)
            local ay = rect._ay or (size.y * rt.asy + rt.aoy)
            love.graphics.translate(rect.position.x + ax, rect.position.y + ay)
            if rect.rotation ~= 0 then love.graphics.rotate(rect.rotation) end
            love.graphics.translate(-ax, -ay)
            _draw_cached_canvas(canvas, 0, 0)
            love.graphics.pop()
        else
            _pushScissorPixels(rect.position.x, rect.position.y, size.x, size.y)
            for i = 1, #sorted do
                Element._draw_child(sorted[i], child_parent_rect)
            end
            _popScissorPixels()
        end
    else
        local sorted = Element._get_sorted_children_cached(self)
        for i = 1, #sorted do
            Element._draw_child(sorted[i], child_parent_rect)
        end
    end
end

function Element:draw_self(rect) end

function Element:draw_box(rect, rt, d)
    d = d or rawget(self, "__data")
    rt = rt or rawget(self, "__rt") or _sync_runtime_key(self, nil, d)
    local size = rect.size

    local hasFill = rt and rt.show_fill
    local hasOutline = rt and rt.show_outline
    local on_draw = rt and rt.on_draw
    local hasOnDraw = type(on_draw) == "function"
    local hasCustomDraw = rawget(self, "_has_custom_draw")
    local draw_self_fn = rawget(self, "_draw_self_fn")
    if hasCustomDraw == nil then
        hasCustomDraw = self.draw_self ~= Element.draw_self
        draw_self_fn = self.draw_self
    end
    if not hasFill and not hasOutline and not hasOnDraw and not hasCustomDraw then
        return
    end

    if rect.rotation == 0 and not hasOnDraw and not hasCustomDraw then
        if hasFill then
            love.graphics.setColor(rt.fill_color)
            love.graphics.rectangle("fill", rect.position.x, rect.position.y, size.x, size.y)
        end
        if hasOutline then
            love.graphics.setColor(rt.outline_color)
            love.graphics.setLineWidth(rt.outline_thickness)
            love.graphics.rectangle("line", rect.position.x, rect.position.y, size.x, size.y)
        end
        return
    end

    local ax = rect._ax or (size.x * ((rt and rt.asx) or 0) + ((rt and rt.aox) or 0))
    local ay = rect._ay or (size.y * ((rt and rt.asy) or 0) + ((rt and rt.aoy) or 0))

    local oldColor, oldLineWidth
    local needsFullState = hasOnDraw or hasCustomDraw
    if needsFullState then
        love.graphics.push("all")
    else
        oldColor = { love.graphics.getColor() }
        oldLineWidth = love.graphics.getLineWidth()
        love.graphics.push()
    end
    love.graphics.translate(rect.position.x + ax, rect.position.y + ay)
    if rect.rotation ~= 0 then
        love.graphics.rotate(rect.rotation)
    end
    love.graphics.translate(-ax, -ay)

    if hasFill then
        love.graphics.setColor(rt.fill_color)
        love.graphics.rectangle("fill", 0, 0, size.x, size.y)
    end

    if hasOutline then
        love.graphics.setColor(rt.outline_color)
        love.graphics.setLineWidth(rt.outline_thickness)
        love.graphics.rectangle("line", 0, 0, size.x, size.y)
    end

    if hasOnDraw then
        on_draw(self, size)
    end

    if hasCustomDraw and draw_self_fn then
        draw_self_fn(self, rect)
    end

    love.graphics.pop()
    if not needsFullState then
        if oldColor then love.graphics.setColor(oldColor) end
        love.graphics.setLineWidth(oldLineWidth)
    end
end

local function _render_compiled_enabled()
    return Element.compiled_render_enabled == true or G.graphics_compiled_render == true
end

function Element._should_use_compiled_render(_, parent_rect)
    return _render_compiled_enabled()
        and parent_rect == nil
        and not rawget(Element, "_compiled_render_active")
        and (rawget(Element, "_compiled_fallback_depth") or 0) == 0
end

local function _compiled_batches_enabled()
    if G.graphics_render_batches == false then return false end
    return Element.compiled_render_batches ~= false
end

local function _append_render_list(out, list)
    if not out or not list then return end
    local n = #out
    for i = 1, #list do
        out[n + i] = list[i]
    end
end

local function _render_instance_of(obj, cls)
    if not obj or not cls then return false end
    local mt = getmetatable(obj)
    local c = mt and (mt.__class or mt)
    while c do
        if c == cls then return true end
        c = getmetatable(c)
    end
    return false
end

local function _render_has_custom_draw(element, rt)
    if rt and type(rt.on_draw) == "function" then return true end
    local custom = rawget(element, "_has_custom_draw")
    if custom == nil then
        custom = element.draw_self ~= Element.draw_self
    end
    return custom == true
end

local function _render_copy_color(color, opacity)
    color = type(color) == "table" and color or { 1, 1, 1, 1 }
    return {
        color[1] or 1,
        color[2] or 1,
        color[3] or 1,
        (color[4] or 1) * (opacity or 1)
    }
end

local function _render_emit_visit(list, element)
    list[#list + 1] = { op = "visit", element = element }
end

local function _render_emit_box(list, rect, rt)
    if rt.show_fill then
        list[#list + 1] = {
            op = "fill",
            x = rect.position.x,
            y = rect.position.y,
            w = rect.size.x,
            h = rect.size.y,
            rotation = rect.rotation or 0,
            ax = rect._ax or 0,
            ay = rect._ay or 0,
            color = rt.fill_color
        }
    end
    if rt.show_outline then
        list[#list + 1] = {
            op = "outline",
            x = rect.position.x,
            y = rect.position.y,
            w = rect.size.x,
            h = rect.size.y,
            rotation = rect.rotation or 0,
            ax = rect._ax or 0,
            ay = rect._ay or 0,
            color = rt.outline_color,
            lineWidth = rt.outline_thickness or 1
        }
    end
end

local function _render_emit_passthrough(list, element, parent_rect)
    list[#list + 1] = { op = "passthrough", element = element, parent_rect = parent_rect }
end

local function _render_image_command(element, rect, rt, d)
    local image = (rt and rt.image) or (d and d.image)
    if not image or rt.shader or rt.scale_type == "tile" then return nil end

    local iw = rawget(element, "_srcW")
    local ih = rawget(element, "_srcH")
    if (not iw) or (not ih) or iw == 0 or ih == 0 then
        if image.getDimensions then
            iw, ih = image:getDimensions()
        end
    end
    if (not iw) or (not ih) or iw == 0 or ih == 0 then return nil end

    local w, h = rect.size.x, rect.size.y
    local sx, sy = w / iw, h / ih
    local mode = rt.scale_type or "stretch"
    if mode == "fit" then
        sx = math.min(w / iw, h / ih)
        sy = sx
    elseif mode == "fill" then
        sx = math.max(w / iw, h / ih)
        sy = sx
    end

    local ox = rt.flip_x and iw or 0
    local oy = rt.flip_y and ih or 0
    if rt.flip_x then sx = -sx end
    if rt.flip_y then sy = -sy end

    local rotation = (rt and rt.screen_rotation) or rect.rotation or 0
    local color = _render_copy_color(rt.color or d.color, rt.opacity or d.opacity or 1)
    local cmd = {
        op = "image",
        element = element,
        image = image,
        quad = rt.quad or d.quad,
        x = (rt.x or rect.position.x),
        y = (rt.y or rect.position.y),
        w = w,
        h = h,
        sx = sx,
        sy = sy,
        ox = ox,
        oy = oy,
        rotation = rotation,
        ax = rect._ax or 0,
        ay = rect._ay or 0,
        rectX = rect.position.x,
        rectY = rect.position.y,
        color = color
    }
    cmd.batchable = math.abs(rotation or 0) < 1e-6
    return cmd
end

--[[ B2: paint-only changes on a childless element patch its cached compiled
commands in place (ancestor lists hold the same command tables by reference,
so every cached list sees the update), no recompilation, no version bumps
show_fill/show_outline change list STRUCTURE and fall back to a recompile
PATCH_SERIAL invalidates baked mesh/spritebatch ops, which snapshot command
data ]]
local RENDER_PATCH_SERIAL = 0

function Element._render_try_patch_visual(element, rt, d, key)
    local children = d and d.children
    if children and #children > 0 then return false end
    if rawget(element, "_render_compile_dirty") then return false end
    local cache = rawget(element, "_render_list_cache")
    local list = cache and cache.list
    if not list or #list == 0 then return false end

    if key == "show_fill" or key == "show_outline" then return false end

    --[[ passthrough leaves replay their live draw each frame, nothing baked
    to patch, the recompile can be skipped outright ]]
    if list[1].op == "passthrough" then
        return true
    end

    if key == "fill_color" or key == "outline_color" then
        local op_name = key == "fill_color" and "fill" or "outline"
        for i = 1, #list do
            local cmd = list[i]
            if cmd.op == op_name then
                cmd.color = rt[key]
                break
            end
        end
        RENDER_PATCH_SERIAL = RENDER_PATCH_SERIAL + 1
        return true
    end

    if key == "color" or key == "flip_x" or key == "flip_y" or key == "imageRect" then
        for i = 1, #list do
            local cmd = list[i]
            if cmd.op == "image" and cmd.element == element then
                local rect = rawget(element, "_screen_rect")
                if not rect then return false end
                local fresh = _render_image_command(element, rect, rt, d)
                if not fresh then return false end
                for k, v in pairs(fresh) do cmd[k] = v end
                RENDER_PATCH_SERIAL = RENDER_PATCH_SERIAL + 1
                return true
            end
        end
        --[[ no image command cached (plain element): tint/flip have no baked
        representation to fix up ]]
        return true
    end

    return false
end

local function _render_compile_children(element, parent_rect, list)
    local sorted = Element._get_sorted_children_cached(element)
    for i = 1, #sorted do
        Element._compile_render_subtree(sorted[i], parent_rect, list)
    end
end

local function _render_emit_scrollbars(list, rect, size, sc)
    local start=#list
    local cvs = (sc.canvasSize or sc._autoSize).offset
    local bx, by, bw = sc.barInset, sc.barInset, sc.barThickness
    if not sc.externalScrollbar and sc.vertical and cvs.y > size.y then
        local trackH = size.y - 2 * by
        local barLen = math.max(bw, trackH * (size.y / cvs.y))
        local maxScroll = cvs.y - size.y
        local ratio = (maxScroll == 0) and 0 or (sc.canvasPosition.y / maxScroll)
        local barY = rect.position.y + by + ratio * (trackH - barLen)
        list[#list + 1] = {
            op = "fill",
            x = rect.position.x + size.x - bw - bx,
            y = rect.position.y + by,
            w = bw,
            h = trackH,
            rotation = 0,
            ax = 0,
            ay = 0,
            color = sc.barBgColor
        }
        list[#list + 1] = {
            op = "fill",
            x = rect.position.x + size.x - bw - bx,
            y = barY,
            w = bw,
            h = barLen,
            rotation = 0,
            ax = 0,
            ay = 0,
            color = sc.barColor
        }
    end
    if not sc.externalScrollbar and sc.horizontal and cvs.x > size.x then
        local trackW = size.x - 2 * bx
        local barLen = math.max(bw, trackW * (size.x / cvs.x))
        local maxScroll = cvs.x - size.x
        local ratio = (maxScroll == 0) and 0 or (sc.canvasPosition.x / maxScroll)
        local barX = rect.position.x + bx + ratio * (trackW - barLen)
        list[#list + 1] = {
            op = "fill",
            x = rect.position.x + bx,
            y = rect.position.y + size.y - bw - by,
            w = trackW,
            h = bw,
            rotation = 0,
            ax = 0,
            ay = 0,
            color = sc.barBgColor
        }
        list[#list + 1] = {
            op = "fill",
            x = barX,
            y = rect.position.y + size.y - bw - by,
            w = barLen,
            h = bw,
            rotation = 0,
            ax = 0,
            ay = 0,
            color = sc.barColor
        }
    end
    if math.abs(rect.rotation or 0)>1e-6 then
        for i=start+1,#list do
            local cmd=list[i]
            cmd.rotation=rect.rotation
            cmd.ax=(rect._ax or size.x*.5)-(cmd.x-rect.position.x)
            cmd.ay=(rect._ay or size.y*.5)-(cmd.y-rect.position.y)
        end
    end
end

local function _render_cache_key_matches(element, parent_rect, rt)
    local cache = rawget(element, "_render_list_cache")
    if not cache or rawget(element, "_render_compile_dirty") then return false end

    local parent_version = parent_rect and (parent_rect._v or 0) or 0
    local sc = rt and rt.scroll
    local sx, sy = 0, 0
    if sc and sc.enabled and sc.canvasPosition then
        sx, sy = sc.canvasPosition.x or 0, sc.canvasPosition.y or 0
    end

    return cache.parent_rect == parent_rect
        and (cache.parent_version or 0) == parent_version
        and (cache.render_version or 0) == (rawget(element, "_render_version") or 0)
        and (cache.subtree_version or 0) == (rawget(element, "_render_subtree_version") or 0)
        and (cache.root_layout_version or 0) == (Element._root_layout_version or 0)
        and cache.dpi == Surface.density()
        and (cache.scroll_x or 0) == sx
        and (cache.scroll_y or 0) == sy
end

local function _render_store_cache(element, parent_rect, rt, list)
    rawset(Element, "_compiled_render_ever_used", true)
    local sc = rt and rt.scroll
    local sx, sy = 0, 0
    if sc and sc.enabled and sc.canvasPosition then
        sx, sy = sc.canvasPosition.x or 0, sc.canvasPosition.y or 0
    end
    rawset(element, "_render_list_cache", {
        list = list,
        parent_rect = parent_rect,
        parent_version = parent_rect and (parent_rect._v or 0) or 0,
        render_version = rawget(element, "_render_version") or 0,
        subtree_version = rawget(element, "_render_subtree_version") or 0,
        root_layout_version = Element._root_layout_version or 0,
        dpi = Surface.density(),
        scroll_x = sx,
        scroll_y = sy
    })
    rawset(element, "_render_compile_dirty", false)
end

local function _render_compile_element_uncached(element, parent_rect, list)
    local d = rawget(element, "__data")
    local rt = rawget(element, "__rt") or _sync_runtime_key(element, nil, d)
    if not rt or rt.visible == false then return end

    if _render_has_custom_draw(element, rt) then
        _render_emit_passthrough(list, element, parent_rect)
        return
    end

    local TextClass = rawget(_G, "Text")
    if TextClass and _render_instance_of(element, TextClass) then
        if not (TextClass._buildFastLabelCommand and TextClass._canUseFastLabel and TextClass._canUseFastLabel(element, d)) then
            _render_emit_passthrough(list, element, parent_rect)
            return
        end
    end

    local rect = Element.get_screen_rect(element, parent_rect)
    local child_parent_rect = rect
    if rt.destretch_isolate_children then
        local tmp = rawget(element, "_tmp_child_rect_opts") or {}
        tmp.ignore_destretch_size = true
        child_parent_rect = Element.get_screen_rect(element, parent_rect, tmp)
        rawset(element, "_tmp_child_rect_opts", tmp)
    end

    local ImageClass = rawget(_G, "Image")
    local self_cmd = nil
    if ImageClass and _render_instance_of(element, ImageClass) then
        self_cmd = _render_image_command(element, rect, rt, d)
        if not self_cmd then
            _render_emit_passthrough(list, element, parent_rect)
            return
        end
    elseif TextClass and _render_instance_of(element, TextClass) then
        self_cmd = TextClass._buildFastLabelCommand(element, rect, rt, d)
        if not self_cmd then
            _render_emit_passthrough(list, element, parent_rect)
            return
        end
    end

    local compiled_start = #list
    _render_emit_visit(list, element)
    _render_emit_box(list, rect, rt)
    if self_cmd then list[#list + 1] = self_cmd end

    local sc = rt.scroll
    if sc and sc.enabled then
        Element._updateCanvasSize(element)
        local sorted = Element._get_sorted_children_cached(element)
        local clip_mode = Element._choose_clip_mode(element, rt, #sorted, _canvas_forced(rt, rect.rotation))
        if clip_mode == "cached_canvas" then
            for i = #list, compiled_start + 1, -1 do list[i] = nil end
            _render_emit_passthrough(list, element, parent_rect)
            return
        end

        local cvs = (sc.canvasSize or sc._autoSize).offset
        local size = rt.destretch_isolate_children and child_parent_rect.size or rect.size
        local scissor_pos = rt.destretch_isolate_children and child_parent_rect.position or rect.position
        local subParent = rawget(element, "_render_scroll_parent")
        local px = scissor_pos.x - ((sc.canvasPosition and sc.canvasPosition.x) or 0)
        local py = scissor_pos.y - ((sc.canvasPosition and sc.canvasPosition.y) or 0)
        if not subParent then
            subParent = {
                position = vec2(px, py),
                size = size:clone(),
                _v = 1,
                _x = px,
                _y = py,
                _w = size.x,
                _h = size
                    .y
            }
            rawset(element, "_render_scroll_parent", subParent)
        else
            subParent.position.x = px
            subParent.position.y = py
            subParent.size = size
            if subParent._x ~= px or subParent._y ~= py or subParent._w ~= size.x or subParent._h ~= size.y then
                subParent._x, subParent._y, subParent._w, subParent._h = px, py, size.x, size.y
                subParent._v = (subParent._v or 0) + 1
            end
        end
        list[#list + 1] = { op = "push_clip", x = scissor_pos.x, y = scissor_pos.y, w = size.x, h = size.y }
        for i = 1, #sorted do
            Element._compile_render_subtree(sorted[i], subParent, list)
        end
        list[#list + 1] = { op = "pop_clip" }
        _render_emit_scrollbars(list, rect, size, sc)
        return
    end

    if rt.scissor then
        local sorted = Element._get_sorted_children_cached(element)
        local clip_mode = Element._choose_clip_mode(element, rt, #sorted, _canvas_forced(rt, rect.rotation))
        if clip_mode == "cached_canvas" then
            for i = #list, compiled_start + 1, -1 do list[i] = nil end
            _render_emit_passthrough(list, element, parent_rect)
            return
        end
        list[#list + 1] = { op = "push_clip", x = rect.position.x, y = rect.position.y, w = rect.size.x, h = rect.size.y }
        for i = 1, #sorted do
            Element._compile_render_subtree(sorted[i], child_parent_rect, list)
        end
        list[#list + 1] = { op = "pop_clip" }
    else
        _render_compile_children(element, child_parent_rect, list)
    end
end

function Element._compile_render_subtree(element, parent_rect, out)
    if not Element.isElement(element) then return nil end
    local d = rawget(element, "__data")
    local rt = rawget(element, "__rt") or _sync_runtime_key(element, nil, d)
    if not rt or rt.visible == false then return nil end

    if _render_cache_key_matches(element, parent_rect, rt) then
        local cached = rawget(element, "_render_list_cache")
        if out then _append_render_list(out, cached.list) end
        return cached.list
    end

    local list = {}
    _render_compile_element_uncached(element, parent_rect, list)
    _render_store_cache(element, parent_rect, rt, list)
    if out then _append_render_list(out, list) end
    return list
end

function Element.compile_render_list(root, parent_rect)
    return Element._compile_render_subtree(root, parent_rect)
end

local function _draw_fill_command(cmd)
    local color = cmd.color or { 1, 1, 1, 1 }
    love.graphics.setColor(color)
    if math.abs(cmd.rotation or 0) < 1e-6 then
        love.graphics.rectangle("fill", cmd.x, cmd.y, cmd.w, cmd.h)
    else
        love.graphics.push()
        love.graphics.translate(cmd.x + cmd.ax, cmd.y + cmd.ay)
        love.graphics.rotate(cmd.rotation)
        love.graphics.translate(-cmd.ax, -cmd.ay)
        love.graphics.rectangle("fill", 0, 0, cmd.w, cmd.h)
        love.graphics.pop()
    end
end

local function _draw_outline_command(cmd)
    local color = cmd.color or { 1, 1, 1, 1 }
    love.graphics.setColor(color)
    love.graphics.setLineWidth(cmd.lineWidth or 1)
    if math.abs(cmd.rotation or 0) < 1e-6 then
        love.graphics.rectangle("line", cmd.x, cmd.y, cmd.w, cmd.h)
    else
        love.graphics.push()
        love.graphics.translate(cmd.x + cmd.ax, cmd.y + cmd.ay)
        love.graphics.rotate(cmd.rotation)
        love.graphics.translate(-cmd.ax, -cmd.ay)
        love.graphics.rectangle("line", 0, 0, cmd.w, cmd.h)
        love.graphics.pop()
    end
end

local function _draw_image_command(cmd)
    love.graphics.setColor(cmd.color)
    if math.abs(cmd.rotation or 0) < 1e-6 then
        if cmd.quad then
            love.graphics.draw(cmd.image, cmd.quad, cmd.x, cmd.y, 0, cmd.sx, cmd.sy, cmd.ox, cmd.oy)
        else
            love.graphics.draw(cmd.image, cmd.x, cmd.y, 0, cmd.sx, cmd.sy, cmd.ox, cmd.oy)
        end
    else
        love.graphics.push()
        love.graphics.translate(cmd.rectX + cmd.ax, cmd.rectY + cmd.ay)
        love.graphics.rotate(cmd.rotation)
        love.graphics.translate(-cmd.ax, -cmd.ay)
        if cmd.quad then
            love.graphics.draw(cmd.image, cmd.quad, 0, 0, 0, cmd.sx, cmd.sy, cmd.ox, cmd.oy)
        else
            love.graphics.draw(cmd.image, 0, 0, 0, cmd.sx, cmd.sy, cmd.ox, cmd.oy)
        end
        love.graphics.pop()
    end
end

local function _make_fill_mesh(commands, first, last)
    local vertices = {}
    local n = 0
    for i = first, last do
        local c = commands[i]
        local col = c.color or { 1, 1, 1, 1 }
        local r, g, b, a = col[1] or 1, col[2] or 1, col[3] or 1, col[4] or 1
        local x, y, w, h = c.x, c.y, c.w, c.h
        n = n + 1; vertices[n] = { x, y, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x + w, y, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x + w, y + h, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x, y, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x + w, y + h, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x, y + h, 0, 0, r, g, b, a }
    end
    local ok, mesh = pcall(love.graphics.newMesh, vertices, "triangles", "static")
    if ok then return mesh end
    return nil
end

local function _make_image_spritebatch(commands, first, last)
    local image = commands[first].image
    local ok, batch = pcall(love.graphics.newSpriteBatch, image, last - first + 1, "static")
    if not ok or not batch then return nil end
    for i = first, last do
        local c = commands[i]
        local col = c.color or { 1, 1, 1, 1 }
        if batch.setColor then batch:setColor(col[1] or 1, col[2] or 1, col[3] or 1, col[4] or 1) end
        if c.quad then
            batch:add(c.quad, c.x, c.y, 0, c.sx, c.sy, c.ox, c.oy)
        else
            batch:add(c.x, c.y, 0, c.sx, c.sy, c.ox, c.oy)
        end
    end
    if batch.setColor then batch:setColor(1, 1, 1, 1) end
    return batch
end

--[[ indexed variants: batch runs skip interleaved visit ops, so the member
commands are an index list rather than a contiguous range ]]
local function _make_fill_mesh_indexed(commands, indices)
    local vertices = {}
    local n = 0
    for idx = 1, #indices do
        local c = commands[indices[idx]]
        local col = c.color or { 1, 1, 1, 1 }
        local r, g, b, a = col[1] or 1, col[2] or 1, col[3] or 1, col[4] or 1
        local x, y, w, h = c.x, c.y, c.w, c.h
        n = n + 1; vertices[n] = { x, y, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x + w, y, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x + w, y + h, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x, y, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x + w, y + h, 0, 0, r, g, b, a }
        n = n + 1; vertices[n] = { x, y + h, 0, 0, r, g, b, a }
    end
    local ok, mesh = pcall(love.graphics.newMesh, vertices, "triangles", "static")
    if ok then return mesh end
    return nil
end

local function _make_image_spritebatch_indexed(commands, indices)
    local image = commands[indices[1]].image
    local ok, batch = pcall(love.graphics.newSpriteBatch, image, #indices, "static")
    if not ok or not batch then return nil end
    for idx = 1, #indices do
        local c = commands[indices[idx]]
        local col = c.color or { 1, 1, 1, 1 }
        if batch.setColor then batch:setColor(col[1] or 1, col[2] or 1, col[3] or 1, col[4] or 1) end
        if c.quad then
            batch:add(c.quad, c.x, c.y, 0, c.sx, c.sy, c.ox, c.oy)
        else
            batch:add(c.x, c.y, 0, c.sx, c.sy, c.ox, c.oy)
        end
    end
    if batch.setColor then batch:setColor(1, 1, 1, 1) end
    return batch
end

local function _prepare_render_ops(list)
    if not _compiled_batches_enabled() then return list end
    local serial = RENDER_PATCH_SERIAL

    --[[ bake meshes/spritebatches only for lists that live longer than one
    frame: a first-time list replays raw commands and marks a pending bake for
    its SECOND prepare. per-frame-recompiled lists (geometry animation) are
    fresh objects every frame and therefore never pay a bake, in-place patches
    flip a baked list back to raw replay, with an opportunistic re-bake after
    a patch-quiet period ]]
    if not (list._render_ops and list._render_ops_len == #list) then
        list._render_ops = list
        list._render_ops_len = #list
        list._render_ops_serial = serial
        list._render_ops_unbatched = true
        list._render_ops_bake_pending = true
        list._render_ops_quiet = 0
        return list
    end

    if list._render_ops_serial ~= serial then
        list._render_ops = list
        list._render_ops_serial = serial
        list._render_ops_unbatched = true
        list._render_ops_bake_pending = false
        list._render_ops_quiet = 0
        return list
    end

    if not list._render_ops_unbatched then
        return list._render_ops
    end

    if not list._render_ops_bake_pending then
        local quiet = (list._render_ops_quiet or 0) + 1
        list._render_ops_quiet = quiet
        if quiet <= 60 then
            return list._render_ops
        end
    end

    list._render_ops_unbatched = false
    list._render_ops_bake_pending = false
    list._render_ops_quiet = 0

    local ops = {}
    local i = 1
    while i <= #list do
        local cmd = list[i]
        --[[ "visit" ops only set isdrawn bookkeeping, they are TRANSPARENT to
        batch runs (every element emits one between its draw commands, which
        otherwise caps every run at length 1 and disables batching entirely)
        visits inside a run are hoisted ahead of the batched op ]]
        if cmd.op == "fill" and math.abs(cmd.rotation or 0) < 1e-6 then
            local fills = { i }
            local j = i + 1
            while j <= #list do
                local nxt = list[j]
                if nxt.op == "fill" and math.abs(nxt.rotation or 0) < 1e-6 then
                    fills[#fills + 1] = j
                elseif nxt.op ~= "visit" then
                    break
                end
                j = j + 1
            end
            local count = #fills
            if count >= RENDER_BATCH_MIN_ITEMS then
                local mesh = _make_fill_mesh_indexed(list, fills)
                if mesh then
                    for k = i, j - 1 do
                        if list[k].op == "visit" then ops[#ops + 1] = list[k] end
                    end
                    ops[#ops + 1] = { op = "fill_mesh", mesh = mesh, count = count }
                else
                    for k = i, j - 1 do ops[#ops + 1] = list[k] end
                end
            else
                for k = i, j - 1 do ops[#ops + 1] = list[k] end
            end
            i = j
        elseif cmd.op == "image" and cmd.batchable and cmd.image then
            local image = cmd.image
            local images = { i }
            local j = i + 1
            while j <= #list do
                local nxt = list[j]
                if nxt.op == "image" and nxt.batchable and nxt.image == image then
                    images[#images + 1] = j
                elseif nxt.op ~= "visit" then
                    break
                end
                j = j + 1
            end
            local count = #images
            if count >= RENDER_BATCH_MIN_ITEMS then
                local batch = _make_image_spritebatch_indexed(list, images)
                if batch then
                    for k = i, j - 1 do
                        if list[k].op == "visit" then ops[#ops + 1] = list[k] end
                    end
                    ops[#ops + 1] = { op = "image_batch", batch = batch, count = count }
                else
                    for k = i, j - 1 do ops[#ops + 1] = list[k] end
                end
            else
                for k = i, j - 1 do ops[#ops + 1] = list[k] end
            end
            i = j
        else
            ops[#ops + 1] = cmd
            i = i + 1
        end
    end

    list._render_ops = ops
    list._render_ops_len = #list
    list._render_ops_serial = RENDER_PATCH_SERIAL
    return ops
end

function Element.draw_render_list(list)
    if not list then return end
    local ops = _prepare_render_ops(list)
    local TextClass = rawget(_G, "Text")
    for i = 1, #ops do
        local cmd = ops[i]
        if cmd.op == "visit" then
            rawset(cmd.element, "isdrawn", true)
        elseif cmd.op == "fill" then
            _draw_fill_command(cmd)
        elseif cmd.op == "outline" then
            _draw_outline_command(cmd)
        elseif cmd.op == "image" then
            _draw_image_command(cmd)
        elseif cmd.op == "text" and TextClass and TextClass._drawFastLabelCommand then
            TextClass._drawFastLabelCommand(cmd)
        elseif cmd.op == "push_clip" then
            Element._push_clip_scissor(cmd.x, cmd.y, cmd.w, cmd.h)
        elseif cmd.op == "pop_clip" then
            Element._pop_clip_scissor()
        elseif cmd.op == "fill_mesh" then
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(cmd.mesh)
        elseif cmd.op == "image_batch" then
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(cmd.batch)
        elseif cmd.op == "passthrough" and cmd.element then
            local depth = (rawget(Element, "_compiled_fallback_depth") or 0) + 1
            rawset(Element, "_compiled_fallback_depth", depth)
            local ok, err = pcall(cmd.element.draw, cmd.element, cmd.parent_rect)
            depth = (rawget(Element, "_compiled_fallback_depth") or 1) - 1
            rawset(Element, "_compiled_fallback_depth", depth > 0 and depth or nil)
            if not ok then error(err, 0) end
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function Element._draw_content_scrollbars(element,rect,rt)
    Element._updateCanvasSize(element)
    local list={}
    _render_emit_scrollbars(list,rect,rect.size,rt.scroll)
    Element.draw_render_list(list)
end

-- explicit opt-in: callers with Global source ordering keep descendant
-- layout and hit testing, while sibling/default rendering remains unchanged
function Element:draw_global(parent_rect,excluded)
    local painter=require('engine/graphics/global_order')
    local state=painter.draw(self,parent_rect,rawget(self,'_global_paint_state'),excluded)
    rawset(self,'_global_paint_state',state)
end

function Element.draw_compiled(root, parent_rect)
    rawset(Element, "_compiled_render_active", true)
    local ok, err = pcall(function()
        local list = Element.compile_render_list(root, parent_rect)
        Element.draw_render_list(list)
    end)
    rawset(Element, "_compiled_render_active", nil)
    if not ok then error(err, 0) end
end

local function _ensure_scroll_target(sc)
    local target = sc._targetPosition
    if not target then
        local cp = sc.canvasPosition or vec2()
        target = vec2(cp.x or 0, cp.y or 0)
        sc._targetPosition = target
    end
    return target
end

local function _clamp_scroll_value(v, maxv)
    if v < 0 then return 0 end
    if v > maxv then return maxv end
    return v
end

function Element:update(dt)
    local d = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, d)
    local sc = rt and rt.scroll
    if sc and sc.enabled then
        local scrollMoved = false
        if rawget(self, "_scroll_auto_size_dirty") or (not sc._autoSize and not sc.canvasSize) then
            Element._updateCanvasSize(self)
        end

        local vis = Element.get_screen_rect(self).size
        local cvs = (sc.canvasSize or sc._autoSize or { offset = vis }).offset
        local maxX = sc.horizontal and math.max(0, cvs.x - vis.x) or 0
        local maxY = sc.vertical and math.max(0, cvs.y - vis.y) or 0

        local target = _ensure_scroll_target(sc)
        target.x = sc.horizontal and _clamp_scroll_value(target.x, maxX) or 0
        target.y = sc.vertical and _clamp_scroll_value(target.y, maxY) or 0

        local isDragging = sc._dragging and (sc._dragging.vert or sc._dragging.horz)
        if sc.smooth == false or isDragging then
            local cx = sc.horizontal and target.x or 0
            local cy = sc.vertical and target.y or 0
            if sc.canvasPosition.x ~= cx then
                sc.canvasPosition.x = cx; scrollMoved = true
            end
            if sc.canvasPosition.y ~= cy then
                sc.canvasPosition.y = cy; scrollMoved = true
            end
        else
            local speed = sc.smoothSpeed or 24
            if speed < 1 then speed = 1 end
            local alpha = 1 - math.exp(-speed * dt)
            local epsilon = sc.smoothEpsilon or 0.1

            local cx, cy = sc.canvasPosition.x or 0, sc.canvasPosition.y or 0
            local tx, ty = target.x, target.y
            local nx = cx + (tx - cx) * alpha
            local ny = cy + (ty - cy) * alpha
            if math.abs(tx - nx) <= epsilon then nx = tx end
            if math.abs(ty - ny) <= epsilon then ny = ty end
            if sc.canvasPosition.x ~= nx then
                sc.canvasPosition.x = nx; scrollMoved = true
            end
            if sc.canvasPosition.y ~= ny then
                sc.canvasPosition.y = ny; scrollMoved = true
            end
        end
        if scrollMoved then
            _mark_render_compile_dirty(self, true)
            --[[ a scroll container nested inside a cached-canvas ancestor was
            invisible to that ancestor (scroll movement marked only the
            render-compile caches), so its animation FROZE inside the cached
            composite. refresh ancestor canvases with a stability reset:
            while scrolling animates every frame, live scissor drawing is
            cheaper than a per-frame canvas redraw ]]
            Element._refresh_ancestor_canvases(self, true)
        end
    end

    local ch = (rt and rt.children) or (d and d.children) or {}
    for i = 1, #ch do
        ch[i]:update(dt)
    end
end

function Element:_in_visible_viewports(px, py)
    local dself = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, dself)
    local p = rt and rt.linked
    local opts = rawget(self, "_tmp_viewport_opts")
    if not opts then
        opts = { mode = "drawing", ignore_destretch_size = false }
        rawset(self, "_tmp_viewport_opts", opts)
    end
    while p do
        local prt = rawget(p, "__rt") or Element._sync_runtime_all(p)
        local pscroll = prt and prt.scroll
        if prt and ((pscroll and pscroll.enabled) or prt.scissor) then
            opts.ignore_destretch_size = prt.destretch_isolate_children and true or false
            local r = Element.get_screen_rect(p, nil, opts)
            if not Element._point_in_rect(r,px,py) then
                return false
            end
        end
        p = prt and prt.linked
    end
    return true
end

function Element:hit_test_deep(px, py)
    local d = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, d)
    if rt and rt.visible == false then return nil end

    local sorted = Element._get_sorted_children_cached(self)
    for i = #sorted, 1, -1 do
        local target = sorted[i]:hit_test_deep(px, py)
        if target then return target end
    end

    if rt and rt.mousecheck and Element.point_in(self, px, py) and Element._in_visible_viewports(self, px, py) then
        return self
    end

    return nil
end

function Element.hitTestAt(px, py)
    local sortedRoots = Element.get_sorted_children(AllElements)
    for i = #sortedRoots, 1, -1 do
        local e = sortedRoots[i]
        local target = e:hit_test_deep(px, py)
        if target then return target end
    end
    return nil
end

--[[ layout ordering and anchoring take reference from hanker by Kyle McLamb
(Alloyed), https://gitlab.com/Alloyed/hanker (MIT): children order by an
explicit layoutId first and otherwise by declaration order (hanker's
call-order rule), positions are written as offsets relative to the parent's
origin (hanker's relative anchors) instead of being baked into scale
fractions of the current size, and layouts re-resolve lazily through dirty
flags rather than every frame. sibling DRAW order stays zindex-based. ]]

local function layout_order_cmp(a, b)
    if a.lid ~= b.lid then return a.lid < b.lid end
    return a.idx < b.idx
end

function Element:_get_layout_order()
    local cache = rawget(self, "_layout_order_cache")
    if cache and not rawget(self, "_layout_order_dirty") then
        return cache
    end

    local children = self.children
    local n = #children
    local tmp = rawget(self, "_layout_order_tmp")
    if not tmp then
        tmp = {}
        rawset(self, "_layout_order_tmp", tmp)
    end
    for i = 1, n do
        local slot = tmp[i]
        if not slot then
            slot = {}
            tmp[i] = slot
        end
        slot.child = children[i]
        slot.idx = i
        slot.lid = children[i].layoutId or math.huge
    end
    for i = #tmp, n + 1, -1 do tmp[i] = nil end
    table.sort(tmp, layout_order_cmp)

    if not cache then
        cache = {}
        rawset(self, "_layout_order_cache", cache)
    end
    for i = 1, n do cache[i] = tmp[i].child end
    for i = #cache, n + 1, -1 do cache[i] = nil end
    rawset(self, "_layout_order_dirty", false)
    return cache
end

function Element:apply_layout()
    local p = self.properties
    if p then
        if p.grid then
            self:layout_grid(p.grid)
        elseif p.list then
            self:layout_list(p.list)
        elseif p.table then
            self:layout_table(p.table)
        elseif p.custom then
            self:layout_custom(p.custom)
        end
    end
    rawset(self, "_layout_dirty", false)
end

function Element:layout_grid(opts)
    opts = opts or {}
    local pr = self:get_screen_rect()
    local psz = pr.size
    local ncol = opts.columns or 1
    local pad = compute_so(opts.cellPadding, psz)
    local csz = compute_so(opts.cellSize, psz)
    local origin = compute_so(opts.start, psz)

    local order = self:_get_layout_order()
    for idx = 1, #order do
        local child = order[idx]
        local row = math.floor((idx - 1) / ncol)
        local col = (idx - 1) % ncol
        child.position = Udim2Preset({
            offset = vec2(origin.x + col * (csz.x + pad.x), origin.y + row * (csz.y + pad.y)),
        })
        child.size = Udim2Preset({ offset = csz:clone() })
    end
end

function Element:layout_list(opts)
    opts = opts or {}
    local pr = self:get_screen_rect()
    local psz = pr.size
    local horiz = (opts.direction or "vertical") == "horizontal"
    local spacing = compute_so(opts.spacing, psz)
    local start = compute_so(opts.start, psz)
    local align = opts.align or "start"

    local order = self:_get_layout_order()
    local cursor = horiz and start.x or start.y

    for i = 1, #order do
        local child = order[i]
        local csz = compute_so(child.size, psz)
        local pos = vec2()

        --[[ flow along the axis by each child's own size (hanker chains
        list cells off the previous edge, so mixed sizes pack correctly
        instead of assuming every cell matches the current one) ]]
        if horiz then
            pos.x = cursor
            cursor = cursor + csz.x + spacing.x
            if align == "center" then
                pos.y = start.y + (psz.y - csz.y) / 2
            elseif align == "bottom" then
                pos.y = start.y + psz.y - csz.y
            else
                pos.y = start.y
            end
        else
            pos.y = cursor
            cursor = cursor + csz.y + spacing.y
            if align == "center" then
                pos.x = start.x + (psz.x - csz.x) / 2
            elseif align == "right" then
                pos.x = start.x + psz.x - csz.x
            else
                pos.x = start.x
            end
        end

        child.position = Udim2Preset({ offset = pos })
    end
end

function Element:layout_table(opts)
    opts = opts or {}
    local pr = self:get_screen_rect()
    local psz = pr.size
    local order = self:_get_layout_order()
    for i = 1, #order do
        local child = order[i]
        local cell = opts.cells and opts.cells[i] or {}
        child.position = Udim2Preset({ offset = compute_so(cell.position, psz) })
        child.size = Udim2Preset({ offset = compute_so(cell.size, psz) })
    end
end

function Element:layout_custom(func)
    if type(func) == "function" then
        func(self, self.children)
        local ch = self.children
        for i = 1, #ch do
            if Element.isElement(ch[i]) then
                ch[i]:mark_dirty()
            end
        end
        self:mark_dirty()
    end
end

function Element:refresh_layout_recursive()
    self:apply_layout()
    local ch = self.children
    for i = 1, #ch do
        if Element.isElement(ch[i]) then
            ch[i]:refresh_layout_recursive()
        end
    end
    self:mark_dirty()
end

--[[ layouts activated through set_properties re-resolve lazily whenever
membership, layoutId or sizes change (see the dirty hooks), constructor
properties stay inert until set_properties is called, preserving existing
hand-positioned lists ]]
function Element:set_properties(props)
    self.properties = props or {}
    local p = self.properties
    rawset(self, "_layout_active",
        (p.grid or p.list or p.table or p.custom) and true or false)
    self:refresh_layout_recursive()
end

function Element:point_in(px, py)
    local opts = rawget(self, "_tmp_visual_opts")
    if not opts then
        opts = { mode = "visual" }
        rawset(self, "_tmp_visual_opts", opts)
    end
    local r = Element.get_screen_rect(self, nil, opts)
    local rt = rawget(self, "__rt")
    local clip = r._clip
    if clip then
        if px < clip.x or px > clip.x + clip.w or py < clip.y or py > clip.y + clip.h then
            return false
        end
    end

    local rw = (rt and rt.width) or r.size.x
    local rh = (rt and rt.height) or r.size.y
    local rx = (rt and rt.x) or r.position.x
    local ry = (rt and rt.y) or r.position.y
    local rotation = (rt and rt.screen_rotation) or r.rotation or 0
    local ax, ay = r._ax or rw * .5, r._ay or rh * .5
    local cx = rx + ax
    local cy = ry + ay
    local dx, dy = px - cx, py - cy
    local c, s = math.cos(-rotation), math.sin(-rotation)
    local lx = dx * c - dy * s + ax
    local ly = dx * s + dy * c + ay

    return lx >= 0 and lx <= rw and ly >= 0 and ly <= rh
        and Element._in_visible_viewports(self,px,py)
end

function Element:get_input_rect(parent_rect)
    local r = self:get_screen_rect(parent_rect)
    return {
        position = vec2(r.position.x, r.position.y),
        size = vec2(r.size.x, r.size.y),
        rotation = r.rotation or 0
    }
end

function Element:hit_scrollbar(px, py)
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, rawget(self, "__data"))
    local sc = rt and rt.scroll
    if not sc or not sc.enabled or sc.externalScrollbar then return false end

    self:_updateCanvasSize()

    local rect
    if rt and rt.destretch_isolate_children then
        rect = self:get_screen_rect(nil, { ignore_destretch_size = true })
    else
        rect = self:get_screen_rect()
    end
    local size = rect.size
    local bx, by, bw = sc.barInset or 2, sc.barInset or 2, sc.barThickness or 6
    local rx, ry = rect.position.x, rect.position.y
    local lx,ly=Element._rect_local_point(rect,px,py)
    px,py=rx+lx,ry+ly

    local function in_rect(mx, my, r)
        return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
    end

    local cvs = (sc.canvasSize or sc._autoSize or { offset = size }).offset
    local hitPad = math.max(2, math.floor(bw * 0.4))

    if not sc.externalScrollbar and sc.vertical and cvs.y > size.y then
        local trackH = size.y - 2 * by
        local barLen = math.max(bw, trackH * (size.y / (cvs.y > 0 and cvs.y or 1)))
        local maxScroll = math.max(0, cvs.y - size.y)
        local ratio = (maxScroll == 0) and 0 or ((sc.canvasPosition and sc.canvasPosition.y) or 0) / maxScroll
        local track = { x = rx + size.x - bw - bx, y = ry + by, w = bw, h = trackH }
        local barY = track.y + ratio * (trackH - barLen)
        local bar = { x = track.x, y = barY, w = bw, h = barLen }
        local hitBar = { x = bar.x - hitPad, y = bar.y - hitPad, w = bar.w + hitPad * 2, h = bar.h + hitPad * 2 }
        local hitTrack = { x = track.x - hitPad, y = track.y - hitPad, w = track.w + hitPad * 2, h = track.h + hitPad * 2 }
        if in_rect(px, py, hitBar) or in_rect(px, py, hitTrack) then return true end
    end

    if not sc.externalScrollbar and sc.horizontal and cvs.x > size.x then
        local trackW = size.x - 2 * bx
        local barLen = math.max(bw, trackW * (size.x / (cvs.x > 0 and cvs.x or 1)))
        local maxScroll = math.max(0, cvs.x - size.x)
        local ratio = (maxScroll == 0) and 0 or ((sc.canvasPosition and sc.canvasPosition.x) or 0) / maxScroll
        local track = { x = rx + bx, y = ry + size.y - bw - by, w = trackW, h = bw }
        local barX = track.x + ratio * (trackW - barLen)
        local bar = { x = barX, y = track.y, w = barLen, h = bw }
        local hitBar = { x = bar.x - hitPad, y = bar.y - hitPad, w = bar.w + hitPad * 2, h = bar.h + hitPad * 2 }
        local hitTrack = { x = track.x - hitPad, y = track.y - hitPad, w = track.w + hitPad * 2, h = track.h + hitPad * 2 }
        if in_rect(px, py, hitBar) or in_rect(px, py, hitTrack) then return true end
    end

    return false
end

function Element:remove()
    local paint=rawget(self,'_global_paint_state')
    if paint and paint.clip_canvas then paint.clip_canvas:release();paint.clip_canvas=nil end
    if paint and paint.clip_stencil then paint.clip_stencil:release();paint.clip_stencil=nil end
    rawset(self,'_global_paint_state',nil)
    -- Child removal unlinks itself from the parent. Detach the owned list
    -- before traversing so that sibling shifts cannot skip a live child
    local children = self.children
    self.children = {}
    for i, v in ipairs(children) do
        v:remove()
    end

    local parent = self.linked
    if parent and parent.children then
        for i, v in ipairs(parent.children) do
            if parent.children[i] == self then
                table.remove(parent.children, i)
                rawset(parent, "__child_name_map", nil)
                rawset(parent, "__neg_child_key", nil)
                parent._child_order_dirty = true
                parent._layout_order_dirty = true
                parent._layout_dirty = true
                break
            end
        end
    end

    for i, v in ipairs(AllElements) do
        if AllElements[i] == self then
            table.remove(AllElements, i)
            break
        end
    end

    self.linked = nil
    self.visible = false
    self.mousecheck = false
    self.selectable = false
    self.editable = false
    self.focusable = false
end

function Element:begin_dirty_batch()
    rawset(self, "_dirty_batch_depth", (rawget(self, "_dirty_batch_depth") or 0) + 1)
end

function Element:end_dirty_batch()
    local depth = (rawget(self, "_dirty_batch_depth") or 0) - 1
    if depth > 0 then
        rawset(self, "_dirty_batch_depth", depth)
        return
    end

    rawset(self, "_dirty_batch_depth", 0)
    if rawget(self, "_dirty_batch_pending") then
        local key = rawget(self, "_dirty_batch_key")
        local keys = rawget(self, "_dirty_batch_keys")
        rawset(self, "_dirty_batch_pending", false)
        rawset(self, "_dirty_batch_key", nil)
        if keys and #keys > 0 then
            --[[ a small set of distinct keys applies targeted invalidation per
            key instead of degrading to a full sync + full invalidation ]]
            for i = 1, #keys do
                Element._apply_dirty(self, keys[i])
                keys[i] = nil
            end
        else
            Element._apply_dirty(self, key)
        end
    end
end

function Element.with_dirty_batch(target, fn, ...)
    if type(fn) ~= "function" then return end
    if not target then return fn(...) end
    Element.begin_dirty_batch(target)
    local ok, a, b, c, d = pcall(fn, ...)
    Element.end_dirty_batch(target)
    if not ok then error(a, 0) end
    return a, b, c, d
end

Element.batch_mutations = Element.with_dirty_batch
Element.begin_mutation = Element.begin_dirty_batch
Element.end_mutation = Element.end_dirty_batch
Element.suspend_dirty = Element.begin_dirty_batch
Element.resume_dirty = Element.end_dirty_batch
Element.begin_mutation_batch = Element.begin_dirty_batch
Element.end_mutation_batch = Element.end_dirty_batch

function Element:_apply_dirty(key)
    rawset(self, "isdrawn", false)
    local dself = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, dself)
    if key == nil then
        _sync_runtime_key(self, nil, dself, rt)
    else
        _sync_runtime_key(self, key, dself, rt)
    end

    --[[ paint-only fast path: refresh ancestor composited canvases once,
    leave geometry stamps / clip stability / own canvas untouched. if the
    compiled command cache can be patched in place (B2), even the
    render-compile invalidation is skipped ]]
    if key ~= nil and Element._visual_dirty_keys[key] then
        if not Element._render_try_patch_visual(self, rt, dself, key) then
            _mark_render_compile_dirty(self, true)
        end
        Element._refresh_ancestor_canvases(self, false)
        return
    end

    _mark_render_compile_dirty(self, true)

    local geom = (key == nil) or Element._geom_dirty_keys[key]
    local cascade_children = (key == nil) or Element._cascade_children_keys[key]
    local affects_canvas_target = (key == "scissor" or key == "scroll")
    local canvas_dirty = rawget(self, "_canvas_dirty")
    local needs_update = rawget(self, "_needs_update")
    rawset(self, "_clip_static_frames", 0)
    rawset(self, "_clip_cache_dirty", true)
    if geom then
        rawset(self, "_scroll_auto_size_dirty", true)
    end

    if affects_canvas_target then
        rawset(self, "_canvas", nil)
    end

    if cascade_children then
        local d = rawget(self, "__data")
        local children = d and d.children or {}
        if #children > 0 then
            rawset(self, "_children_geom_version", (rawget(self, "_children_geom_version") or 0) + 1)
        end
    end

    local p = rt and rt.linked
    while p do
        local prt = rawget(p, "__rt") or Element._sync_runtime_all(p)
        local pscroll = prt and prt.scroll
        if prt and ((pscroll and pscroll.enabled) or prt.scissor) then
            if geom and pscroll and pscroll.enabled and not pscroll.canvasSize then
                rawset(p, "_scroll_auto_size_dirty", true)
            end
            rawset(p, "_clip_static_frames", 0)
            rawset(p, "_clip_cache_dirty", true)
            if rawget(p, "_canvas_dirty") then break end
            rawset(p, "_canvas_dirty", true)
        end
        p = prt and prt.linked
    end

    if canvas_dirty and ((not geom) or needs_update) then
        return
    end

    if geom and not needs_update then
        rawset(self, "_needs_update", true)
        rawset(self, "_geom_version", (rawget(self, "_geom_version") or 0) + 1)
    end

    if not canvas_dirty then
        rawset(self, "_canvas_dirty", true)
    end
end

function Element:mark_dirty(key)
    if (rawget(self, "_dirty_batch_depth") or 0) > 0 then
        if rawget(self, "_dirty_batch_pending") then
            if rawget(self, "_dirty_batch_key") ~= key then
                --[[ accumulate up to 4 distinct keys, nil key or overflow
                degrades to the full-invalidate sentinel like before ]]
                local keys = rawget(self, "_dirty_batch_keys")
                local first = rawget(self, "_dirty_batch_key")
                if key ~= nil and first ~= nil then
                    if not keys then
                        keys = { first }
                        rawset(self, "_dirty_batch_keys", keys)
                    elseif #keys == 0 then
                        --[[ reused (cleared) array from an earlier batch: the
                        batch's first key still needs seeding, dropping it
                        here silently un-applied `position` on every drag
                        frame after the first ]]
                        keys[1] = first
                    end
                    local known = false
                    for i = 1, #keys do
                        if keys[i] == key then
                            known = true
                            break
                        end
                    end
                    if not known then
                        if #keys < 4 then
                            keys[#keys + 1] = key
                        else
                            for i = 1, #keys do keys[i] = nil end
                            rawset(self, "_dirty_batch_key", nil)
                        end
                    end
                else
                    if keys then
                        for i = 1, #keys do keys[i] = nil end
                    end
                    rawset(self, "_dirty_batch_key", nil)
                end
            end
        else
            rawset(self, "_dirty_batch_pending", true)
            rawset(self, "_dirty_batch_key", key)
            local keys = rawget(self, "_dirty_batch_keys")
            if keys then
                for i = 1, #keys do keys[i] = nil end
            end
        end
        return
    end
    Element._apply_dirty(self, key)
end

function Element:_updateCanvasSize()
    local dself = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, dself)
    local sc = rt and rt.scroll
    if not sc or sc.canvasSize then return end
    if (not rawget(self, "_scroll_auto_size_dirty")) and sc._autoSize then
        return
    end

    local minx, miny, maxx, maxy = 1 / 0, 1 / 0, -1 / 0, -1 / 0

    local parent_for_children = (rt and rt.destretch_isolate_children) and
        Element.get_screen_rect(self, nil, { ignore_destretch_size = true }) or Element.get_screen_rect(self)
    local children = (rt and rt.children) or (dself and dself.children) or {}
    if #children == 0 then
        minx, miny, maxx, maxy = 0, 0, 0, 0
    else
        for _, c in ipairs(children) do
            local r = Element.get_screen_rect(c, parent_for_children)
            minx, miny = math.min(minx, r.position.x), math.min(miny, r.position.y)
            maxx = math.max(maxx, r.position.x + r.size.x)
            maxy = math.max(maxy, r.position.y + r.size.y)
        end
    end

    local pad = sc.padding
    local newW = maxx - minx + pad.x * 2
    local newH = maxy - miny + pad.y * 2

    local old = sc._autoSize and sc._autoSize.offset
    if not old or old.x ~= newW or old.y ~= newH then
        sc._autoSize = Udim2Preset({ offset = vec2(newW, newH) })
        rawset(self, "_canvas_dirty", true)
    end
    rawset(self, "_scroll_auto_size_dirty", false)
end

function Element:_get_sorted_children_cached()
    local child_order_dirty = rawget(self, "_child_order_dirty")
    local sorted_children_cache = rawget(self, "_sorted_children_cache")
    if not child_order_dirty and sorted_children_cache then
        return sorted_children_cache
    end
    local d = rawget(self, "__data")
    local list = (d and d.children) or {}
    local n = #list
    if n == 0 then
        local empty = sorted_children_cache or {}
        for i = 1, #empty do empty[i] = nil end
        rawset(self, "_sorted_children_cache", empty)
        rawset(self, "_child_order_dirty", false)
        return empty
    end
    if n == 1 then
        local single = sorted_children_cache or {}
        single[1] = list[1]
        for i = 2, #single do single[i] = nil end
        rawset(self, "_sorted_children_cache", single)
        rawset(self, "_child_order_dirty", false)
        return single
    end
    local tmp = rawget(self, "_sorted_children_tmp") or {}
    for i = 1, n do
        local c = list[i]
        local rt = c and rawget(c, "__rt")
        local cd = (not rt) and c and rawget(c, "__data")
        local t = tmp[i]
        if not t then
            t = {}
            tmp[i] = t
        end
        t.child = c
        t.idx = i
        t.z = (rt and rt.z) or (cd and cd.zindex) or 0
        t.seq = (c and rawget(c, "_zseq")) or 0
    end
    for i = n + 1, #tmp do tmp[i] = nil end
    rawset(self, "_sorted_children_tmp", tmp)

    table.sort(tmp, Element._sort_children_cmp)
    local out = sorted_children_cache or {}
    for i = 1, n do out[i] = tmp[i].child end
    for i = n + 1, #out do out[i] = nil end
    rawset(self, "_sorted_children_cache", out)
    rawset(self, "_child_order_dirty", false)
    return out
end

function Element:_has_dynamic_descendants()
    if (not rawget(self, "_dynamic_tree_dirty")) and rawget(self, "_has_dynamic_cache") ~= nil then
        return rawget(self, "_has_dynamic_cache")
    end

    local any = false
    local d = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, d)
    local ch = (rt and rt.children) or (d and d.children) or {}
    for i = 1, #ch do
        local c = ch[i]
        if Element.isElement(c) then
            local crt = rawget(c, "__rt") or Element._sync_runtime_all(c)
            if crt and (crt.shader or crt.on_draw) then
                any = true
                break
            end
            if Element._has_dynamic_descendants(c) then
                any = true
                break
            end
        end
    end

    rawset(self, "_has_dynamic_cache", any)
    rawset(self, "_dynamic_tree_dirty", false)
    return any
end

function Element:scrollBy(dx, dy, immediate)
    local d = rawget(self, "__data")
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, d)
    local sc = rt and rt.scroll
    if not sc or not sc.enabled then return end

    local vis = Element.get_screen_rect(self).size
    local cvs = (sc.canvasSize or sc._autoSize or { offset = vis }).offset

    local target = _ensure_scroll_target(sc)
    local changed = false
    if sc.horizontal then
        local maxX = cvs.x - vis.x
        local nx = _clamp_scroll_value((target.x or 0) + dx, maxX)
        if nx ~= target.x then
            target.x = nx
            changed = true
        end
    end
    if sc.vertical then
        local maxY = cvs.y - vis.y
        local ny = _clamp_scroll_value((target.y or 0) + dy, maxY)
        if ny ~= target.y then
            target.y = ny
            changed = true
        end
    end

    if changed and (sc.smooth == false or immediate == true) then
        local cx = sc.horizontal and target.x or 0
        local cy = sc.vertical and target.y or 0
        if sc.canvasPosition.x ~= cx then sc.canvasPosition.x = cx end
        if sc.canvasPosition.y ~= cy then sc.canvasPosition.y = cy end
    end
end

function Element:invalidateTree()
    rawset(self, "_needs_update", true)
    rawset(self, "_canvas_dirty", true)
    rawset(self, "_scroll_auto_size_dirty", true)

    local d = rawget(self, "__data")
    local sc = d and d.scroll
    if sc then
        sc._autoSize = nil
    end

    local children = d and d.children or {}
    for _, c in ipairs(children) do
        if Element.isElement(c) then
            c:invalidateTree()
        end
    end
end

-- Deep graphics-reset invalidator. love.window.updateMode (display-mode / resolution changes)
-- WIPES the GPU contents of every Canvas, so marking dirty is not enough -- the cached element
-- canvas must be DROPPED so it is reallocated blank and repainted, not re-baked into the wiped
-- canvas (the re-bake path only reallocates on nil-or-size-mismatch). Unlike invalidateTree
-- (which nils only the ROOT canvas) this recurses the whole tree, Text overrides it to also
-- drop its separate baked glyph/static canvases. refresh-gated in love.resize, so normal
-- drag-resizes (no GPU wipe) keep the cheap path
function Element:invalidate_graphics_reset()
    rawset(self, "_canvas", nil)
    rawset(self, "_canvas_dirty", true)
    rawset(self, "_needs_update", true)
    local d = rawget(self, "__data")
    local children = d and d.children or {}
    for _, c in ipairs(children) do
        if Element.isElement(c) then
            c:invalidate_graphics_reset()
        end
    end
end

function Element:updateVisualState()
    if not self.originalColors then return end

    local colors = self.originalColors
    if self.state.selected then
        colors = self.selectedColors
    elseif self.state.hovered then
        colors = self.hoverColors
    end

    if colors.fill then
        self.fill_color = { unpack(colors.fill) }
    end
    if colors.outline then
        self.outline_color = { unpack(colors.outline) }
        self.outline_thickness = colors.thickness or self.outline_thickness
    end
end

function Element:setSelected(selected)
    if self.state.selected == selected then return end

    self.state.selected = selected
    self.is_selected = selected
    self:updateVisualState()

    if selected and self.on_selected then
        self:on_selected()
    elseif not selected and self.on_deselected then
        self:on_deselected()
    end
end

function Element:set_selected(selected)
    return self:setSelected(selected)
end

function Element:set_focused(focused)
    if self.state.focused == focused then return end

    self.state.focused = focused
    self.is_focused = focused

    if focused and self.onFocus then
        self:onFocus()
    elseif not focused and self.onBlur then
        self:onBlur()
    end
end

local function handle_scroll_interaction(self, inputType, ...)
    local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, rawget(self, "__data"))
    local sc = rt and rt.scroll
    if not sc or not sc.enabled or sc.externalScrollbar then return false end

    local rect = self:get_screen_rect()
    local size = rect.size
    local bx, by, bw = sc.barInset or 2, sc.barInset or 2, sc.barThickness or 6
    local rx, ry = rect.position.x, rect.position.y

    local function v_geo()
        local cvs = (sc.canvasSize or sc._autoSize or { offset = size }).offset
        local trackH = size.y - 2 * by
        local barLen = math.max(bw, trackH * (size.y / (cvs.y > 0 and cvs.y or 1)))
        local maxScroll = math.max(0, cvs.y - size.y)
        local ratio = (maxScroll == 0) and 0 or (sc.canvasPosition.y / maxScroll)
        local trackX = size.x - bw - bx
        local trackY = by
        local barY = trackY + ratio * (trackH - barLen)
        return {
            track = { x = rx + trackX, y = ry + trackY, w = bw, h = trackH },
            bar = { x = rx + trackX, y = ry + barY, w = bw, h = barLen },
            maxScroll = maxScroll,
            trackH = trackH,
            barLen = barLen
        }
    end

    local function h_geo()
        local cvs = (sc.canvasSize or sc._autoSize or { offset = size }).offset
        local trackW = size.x - 2 * bx
        local barLen = math.max(bw, trackW * (size.x / (cvs.x > 0 and cvs.x or 1)))
        local maxScroll = math.max(0, cvs.x - size.x)
        local ratio = (maxScroll == 0) and 0 or (sc.canvasPosition.x / maxScroll)
        local trackX = bx
        local trackY = size.y - bw - by
        local barX = trackX + ratio * (trackW - barLen)
        return {
            track = { x = rx + trackX, y = ry + trackY, w = trackW, h = bw },
            bar = { x = rx + barX, y = ry + trackY, w = barLen, h = bw },
            maxScroll = maxScroll,
            trackW = trackW,
            barLen = barLen
        }
    end

    local function in_rect(mx, my, r)
        return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
    end

    if inputType == 'mouseclick' then
        local btn, mx, my = select(1, ...), select(2, ...), select(3, ...)
        local lx,ly=Element._rect_local_point(rect,mx,my);mx,my=rx+lx,ry+ly
        if btn ~= 1 then return false end

        self:_updateCanvasSize()

        if sc.vertical then
            local g = v_geo()
            local hitPad = math.max(2, math.floor(bw * 0.4))
            local hitBar = {
                x = g.bar.x - hitPad,
                y = g.bar.y - hitPad,
                w = g.bar.w + hitPad * 2,
                h = g.bar.h + hitPad * 2
            }
            local hitTrack = {
                x = g.track.x - hitPad,
                y = g.track.y - hitPad,
                w = g.track.w + hitPad * 2,
                h = g.track.h + hitPad * 2
            }

            if in_rect(mx, my, hitBar) then
                sc._dragging = sc._dragging or {}
                sc._dragging.vert = { grab = my - g.bar.y, geom = g }
                if not self.on_mouse_move then
                    sc._dragging.addedMoveStub = true
                    self.on_mouse_move = function() end
                end
                return true
            elseif in_rect(mx, my, hitTrack) then
                local newBarY = math.max(g.track.y, math.min(g.track.y + g.trackH - g.barLen, my - g.barLen * 0.5))
                local ratio = (g.trackH - g.barLen) > 0 and (newBarY - g.track.y) / (g.trackH - g.barLen) or 0
                local ny = ratio * g.maxScroll
                local target = _ensure_scroll_target(sc)
                target.y = ny
                sc.canvasPosition.y = ny
                sc._dragging = sc._dragging or {}
                sc._dragging.vert = { grab = my - newBarY, geom = g }
                if not self.on_mouse_move then
                    sc._dragging.addedMoveStub = true
                    self.on_mouse_move = function() end
                end
                return true
            end
        end

        if sc.horizontal then
            local g = h_geo()
            local hitPad = math.max(2, math.floor(bw * 0.4))
            local hitBar = {
                x = g.bar.x - hitPad,
                y = g.bar.y - hitPad,
                w = g.bar.w + hitPad * 2,
                h = g.bar.h + hitPad * 2
            }
            local hitTrack = {
                x = g.track.x - hitPad,
                y = g.track.y - hitPad,
                w = g.track.w + hitPad * 2,
                h = g.track.h + hitPad * 2
            }

            if in_rect(mx, my, hitBar) then
                sc._dragging = sc._dragging or {}
                sc._dragging.horz = { grab = mx - g.bar.x, geom = g }
                if not self.on_mouse_move then
                    sc._dragging.addedMoveStub = true
                    self.on_mouse_move = function() end
                end
                return true
            elseif in_rect(mx, my, hitTrack) then
                local newBarX = math.max(g.track.x, math.min(g.track.x + g.trackW - g.barLen, mx - g.barLen * 0.5))
                local ratio = (g.trackW - g.barLen) > 0 and (newBarX - g.track.x) / (g.trackW - g.barLen) or 0
                local nx = ratio * g.maxScroll
                local target = _ensure_scroll_target(sc)
                target.x = nx
                sc.canvasPosition.x = nx
                sc._dragging = sc._dragging or {}
                sc._dragging.horz = { grab = mx - newBarX, geom = g }
                if not self.on_mouse_move then
                    sc._dragging.addedMoveStub = true
                    self.on_mouse_move = function() end
                end
                return true
            end
        end
    elseif inputType == 'mousemove' then
        local mx, my = select(1, ...), select(2, ...)
        local lx,ly=Element._rect_local_point(rect,mx,my);mx,my=rx+lx,ry+ly
        local dragging = sc._dragging

        if dragging and dragging.vert then
            local g = dragging.vert.geom or v_geo()
            local newBarY = math.max(g.track.y, math.min(g.track.y + g.trackH - g.barLen, my - (dragging.vert.grab or 0)))
            local ratio = (g.trackH - g.barLen) > 0 and (newBarY - g.track.y) / (g.trackH - g.barLen) or 0
            local ny = ratio * g.maxScroll
            local target = _ensure_scroll_target(sc)
            target.y = ny
            sc.canvasPosition.y = ny
            return true
        end

        if dragging and dragging.horz then
            local g = dragging.horz.geom or h_geo()
            local newBarX = math.max(g.track.x, math.min(g.track.x + g.trackW - g.barLen, mx - (dragging.horz.grab or 0)))
            local ratio = (g.trackW - g.barLen) > 0 and (newBarX - g.track.x) / (g.trackW - g.barLen) or 0
            local nx = ratio * g.maxScroll
            local target = _ensure_scroll_target(sc)
            target.x = nx
            sc.canvasPosition.x = nx
            return true
        end

        local changed = false

        if sc.vertical then
            local g = v_geo()
            local hitPad = math.max(2, math.floor(bw * 0.4))
            local hitBar = {
                x = g.bar.x - hitPad,
                y = g.bar.y - hitPad,
                w = g.bar.w + hitPad * 2,
                h = g.bar.h + hitPad * 2
            }
            local hitTrack = {
                x = g.track.x - hitPad,
                y = g.track.y - hitPad,
                w = g.track.w + hitPad * 2,
                h = g.track.h + hitPad * 2
            }

            local old = sc._hover_vert
            if in_rect(mx, my, hitBar) then
                sc._hover_vert = 'bar'
            elseif in_rect(mx, my, hitTrack) then
                sc._hover_vert = 'track'
            else
                sc._hover_vert = nil
            end
            if sc._hover_vert ~= old then changed = true end
        end

        if sc.horizontal then
            local g = h_geo()
            local hitPad = math.max(2, math.floor(bw * 0.4))
            local hitBar = {
                x = g.bar.x - hitPad,
                y = g.bar.y - hitPad,
                w = g.bar.w + hitPad * 2,
                h = g.bar.h + hitPad * 2
            }
            local hitTrack = {
                x = g.track.x - hitPad,
                y = g.track.y - hitPad,
                w = g.track.w + hitPad * 2,
                h = g.track.h + hitPad * 2
            }

            local old = sc._hover_horz
            if in_rect(mx, my, hitBar) then
                sc._hover_horz = 'bar'
            elseif in_rect(mx, my, hitTrack) then
                sc._hover_horz = 'track'
            else
                sc._hover_horz = nil
            end
            if sc._hover_horz ~= old then changed = true end
        end

        if changed then self:mark_dirty() end
    elseif inputType == 'mouserelease' then
        if sc._dragging then
            local dragging = sc._dragging
            dragging.vert = nil
            dragging.horz = nil
            if dragging.addedMoveStub then
                self.on_mouse_move = nil
            end
            dragging.addedMoveStub = nil
            sc._dragging = nil
        end

        if sc._hover_vert or sc._hover_horz then
            self:mark_dirty()
        end
    end

    return false
end

function Element:handleInput(inputType, ...)
    if inputType == 'mouseclick' or inputType == 'mousemove' or inputType == 'mouserelease' then
        local handled = handle_scroll_interaction(self, inputType, ...)
        if handled then return end
    end

    if inputType == "mouseenter" then
        self.state.hovered = true
        self:updateVisualState()
        if self.on_mouse_enter then self:on_mouse_enter(...) end
    elseif inputType == "mouseleave" then
        self.state.hovered = false
        self:updateVisualState()
        local rt = rawget(self, "__rt") or _sync_runtime_key(self, nil, rawget(self, "__data"))
        local sc = rt and rt.scroll
        if sc and sc.enabled then
            if sc._hover_vert or sc._hover_horz then
                sc._hover_vert = nil
                sc._hover_horz = nil
                self:mark_dirty()
            end
        end
        if self.on_mouse_leave then self:on_mouse_leave(...) end
    elseif inputType == "mouseclick" then
        self.state.pressed = true
        self:updateVisualState()
        if self.on_mouse_click then self:on_mouse_click(...) end
    elseif inputType == "mouserelease" then
        self.state.pressed = false
        self:updateVisualState()
        if self.on_mouse_release then self:on_mouse_release(...) end
    elseif inputType == "mousemove" then
        if self.on_mouse_move then self:on_mouse_move(...) end
    elseif inputType == "mouseclicked" then
        if self.on_mouse_clicked then self:on_mouse_clicked(...) end

        local button = select(1, ...)
        if self.selectable and button == 1 then
            self:setSelected(not self.state.selected)
        end
    elseif inputType == "touchpress" then
        self.state.pressed = true
        self:updateVisualState()
        if self.on_touch_press then self:on_touch_press(...) end
    elseif inputType == "touchmove" then
        if self.on_touch_move then self:on_touch_move(...) end
    elseif inputType == "touchrelease" then
        self.state.pressed = false
        self:updateVisualState()
        if self.on_touch_release then self:on_touch_release(...) end

        if self.selectable then
            self:setSelected(not self.state.selected)
        end
    elseif inputType == "keypress" then
        if self.onKeyPress then self:onKeyPress(...) end
        if self.on_key_press then self:on_key_press(...) end
    elseif inputType == "keyrelease" then
        if self.onKeyRelease then self:onKeyRelease(...) end
        if self.on_key_release then self:on_key_release(...) end
    elseif inputType == "textinput" then
        if self.onTextInput then self:onTextInput(...) end
        if self.on_text_input then self:on_text_input(...) end
    end
end
