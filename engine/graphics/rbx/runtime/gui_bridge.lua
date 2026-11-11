-- gui->framework element bridge: surfacegui nodes get real elements, canvas fill draws that tree
-- writes go facade -> proxy -> element, one route. default draw_self matches legacy pixel-for-pixel

local SURFACE_GUI_TEXT_PADDING = 0 -- textlabels have no intrinsic padding
local SURFACE_GUI_TEXT_STROKE_OFFSETS = {
    { -1, 0 },
    { 1, 0 },
    { 0, -1 },
    { 0, 1 },
    { -1, -1 },
    { 1, -1 },
    { -1, 1 },
    { 1, 1 },
}

-- host Text layout keeps the legacy font path. the custom draw/measurement
-- path below delegates optional authored faces to the RBX renderer
local ROBLOX_FONT_DEFAULT_PATH = "NotoSansJP-Regular.otf"
local ROBLOX_FONT_MAP = setmetatable({}, {
    __index = function()
        return ROBLOX_FONT_DEFAULT_PATH
    end,
})

function RBX._gui_bridge_is_active()
    return true
end

-- bridge-owned element keys, registered so writes mark dirty like native keys
local RBX_PROPERTY_KEYS = {
    "rbx_background_color",
    "rbx_background_alpha",
    "rbx_border_color",
    "rbx_border_size",
    "rbx_image_alpha",
    "rbx_text_alpha",
    "rbx_text_stroke_color",
    "rbx_text_stroke_alpha",
    "rbx_text_wrapped",
    "rbx_rich_text",
    "rbx_font_family",
    "rbx_font_asset",
    "rbx_font_face",
}
local RBX_VISUAL_KEYS = {
    "rbx_background_color",
    "rbx_background_alpha",
    "rbx_border_color",
    "rbx_image_alpha",
    "rbx_text_alpha",
    "rbx_text_stroke_color",
    "rbx_text_stroke_alpha",
}
for index = 1, #RBX_PROPERTY_KEYS do
    Element._property_dirty[RBX_PROPERTY_KEYS[index]] = true
end
for index = 1, #RBX_VISUAL_KEYS do
    Element._visual_dirty_keys[RBX_VISUAL_KEYS[index]] = true
end

-- one write = element invalidation + owner content flag
local function rbx_gui_mark_dirty(self, key)
    Element.mark_dirty(self, key)
    local owner = rawget(self, "_rbx_gui_owner")
    if owner ~= nil then
        RBX._mark_surface_gui_dirty(owner, "content")
    end
end

RbxGuiFrame = Element:extend()
RbxGuiImage = Image:extend()
RbxGuiText = Text:extend()

RbxGuiFrame.mark_dirty = rbx_gui_mark_dirty
RbxGuiImage.mark_dirty = rbx_gui_mark_dirty
RbxGuiText.mark_dirty = rbx_gui_mark_dirty

-- Image/Text have their own draw pipelines, but bridge draws everything in draw_self
local apply_node_layout

-- a constrained Size follows the parent's other axis, and layout constraints
-- depend on the parent's pixel size, so the native layout is refreshed
-- whenever the parent's size (or the node's own Size) changes
local function sync_size_constraint(self, parent_rect)
    local node = rawget(self, "_rbx_node")
    if not node then return end
    local size = parent_rect and parent_rect.size
    if node.layout_constraints then
        if not size or size.x <= 0 or size.y <= 0 then return end
        local own = node.size or {}
        local ox, oy = own.x or {}, own.y or {}
        local key = rawget(self, "_rbx_constraint_key")
        if not key then key = {}; rawset(self, "_rbx_constraint_key", key) end
        if key.pw == size.x and key.ph == size.y and key.size == own and key.sxs == ox.scale and key.sxo == ox.offset
            and key.sys == oy.scale and key.syo == oy.offset and key.count == #node.layout_constraints
            and key.mode == node.size_constraint then
            return
        end
        key.pw, key.ph, key.size, key.count, key.mode = size.x, size.y, own, #node.layout_constraints, node.size_constraint
        key.sxs, key.sxo, key.sys, key.syo = ox.scale, ox.offset, oy.scale, oy.offset
        local w, h = RBX._gui_constrained_pixel_size(node, size.x, size.y)
        rawset(self, "_rbx_constrained_scale", { x = w / size.x, y = h / size.y })
        apply_node_layout(self, node)
        return
    end
    local constraint = node.size_constraint
    if constraint ~= "RelativeYY" and constraint ~= "RelativeXX" then return end
    if not size or size.x <= 0 or size.y <= 0 then return end
    local ratio = constraint == "RelativeYY" and size.y / size.x or size.x / size.y
    if rawget(self, "_rbx_constraint_ratio") ~= ratio then
        rawset(self, "_rbx_constraint_ratio", ratio)
        apply_node_layout(self, node)
    end
end

local function rbx_gui_draw(self, parent_rect, content_only)
    sync_size_constraint(self, parent_rect)
    local rect = Element.get_screen_rect(self, parent_rect)
    -- legacy skips zero/negative rects, including children
    local d=rawget(self,'__data');local node=rawget(self,'_rbx_node')
    local fixed_text=node and(node.class_name=='TextLabel'or node.class_name=='TextButton'or node.class_name=='TextBox')and d.textScaled~=true
    if (rect.size.x<=0 or rect.size.y<=0)and not fixed_text then return end
    return Element.draw(self,parent_rect,content_only)
end

RbxGuiFrame.draw = rbx_gui_draw
RbxGuiImage.draw = rbx_gui_draw
RbxGuiText.draw = rbx_gui_draw

-- 1x1 stand-in so Image:init never re-filters a shared renderer texture, real one applied post-init
local BRIDGE_DUMMY_TEXTURE = nil
local function get_bridge_dummy_texture()
    if not BRIDGE_DUMMY_TEXTURE then
        local data = love.image.newImageData(1, 1)
        data:setPixel(0, 0, 1, 1, 1, 1)
        BRIDGE_DUMMY_TEXTURE = love.graphics.newImage(data)
    end
    return BRIDGE_DUMMY_TEXTURE
end

function RbxGuiImage:init(args)
    args = args or {}
    args.source = get_bridge_dummy_texture()
    args.resample_mode = "linear"
    RbxGuiImage.super.init(self, args)
end

-- classic.lua super is class-relative, so Text:init recurses forever on a subclass
function RbxGuiText:init(args)
    rawset(self, "super", Text.super)
    Text.init(self, args)
    rawset(self, "super", nil)
end

-- legacy paint order bg->image->text->border, inside draw_box's transform, (0,0) = rect top-left
local function rbx_gui_draw_self(self, rect)
    local d = rawget(self, "__data")
    if not d then
        return
    end
    local w, h = rect.size.x, rect.size.y

    local bg_alpha = d.rbx_background_alpha or 0
    if bg_alpha > 0 then
        local bg = d.rbx_background_color
        love.graphics.setColor(bg and bg.r or 1, bg and bg.g or 1, bg and bg.b or 1, bg_alpha)
        love.graphics.rectangle("fill", 0, 0, w, h)
    end

    if rawget(self, "_rbx_has_image") and d.image then
        local image_alpha = d.rbx_image_alpha
        if image_alpha == nil then
            image_alpha = 1
        end
        if image_alpha > 0 then
            local tint = d.color
            love.graphics.setColor(
                tint and tint[1] or 1,
                tint and tint[2] or 1,
                tint and tint[3] or 1,
                image_alpha
            )
            local image_node = rawget(self, "_rbx_node")
            local scale_type = d.scale_type
            if image_node then
                RBX._draw_gui_image_content(image_node, d.image, w, h)
            elseif scale_type == "tile" then
                local tile_spec = rawget(self, "_rbx_tile_size_udim2")
                local tile = d.tile_size
                if tile then
                    if tile_spec then
                        tile.x = math.max(1, w * (tile_spec.x.scale or 0) + (tile_spec.x.offset or 0))
                        tile.y = math.max(1, h * (tile_spec.y.scale or 0) + (tile_spec.y.offset or 0))
                    else
                        tile.x = math.max(1, rawget(self, "_srcW") or 1)
                        tile.y = math.max(1, rawget(self, "_srcH") or 1)
                    end
                end
                Image._drawTiled(self, rect.size, d, 0, 0)
            elseif scale_type == "slice" and d.slice_center then
                Image._drawSliced(self, rect.size, d, 0, 0)
            else
                Image._drawScaled(self, rect.size, d, 0, 0)
            end
        end
    end

    local text = d.text
    if text ~= nil and text ~= "" then
        text = tostring(text)
        local renderer = rawget(self, "_rbx_renderer")
        local alpha = d.rbx_text_alpha
        if alpha == nil then
            alpha = 1
        end
        local source_node=rawget(self,'_rbx_node')
        if renderer and(alpha>0 or RBX._gui_has_contextual_stroke(source_node))and text~=''then
            -- Direct overlays redraw each frame. measure stable label inputs once;
            -- public GUI writes/signals and the ordinary canvas bridge stay intact
            local owner = rawget(self, "_rbx_gui_owner")
            local cache_enabled = owner and rawget(owner, "_overlay_text_metrics_cache") == true
            local cached = cache_enabled and rawget(self, "_rbx_text_metrics_cache") or nil
            local align_x, align_y = d.textAlignX or "center", d.textAlignY or "center"
            if cached and (cached._rbx_renderer ~= renderer or cached.text ~= text or cached.w ~= w or cached.h ~= h
                or cached.wrapped ~= (d.rbx_text_wrapped == true) or cached.scaled ~= d.textScaled
                or cached.font_size ~= d.fontSize or cached.font_asset ~= d.rbx_font_asset
                or cached.font_family ~= d.rbx_font_family or cached.font_face ~= d.rbx_font_face or cached.authored ~= renderer.use_authored_gui_fonts
                or cached.font_provider ~= renderer._get_surface_gui_font
                or cached.align_x ~= align_x or cached.align_y ~= align_y) then cached = nil end
            local desired_size = cached and cached.desired_size or (d.textScaled
                and RBX._fit_surface_gui_text_size(renderer, text, w, h, d.rbx_text_wrapped == true,
                    d.rbx_font_asset, d.rbx_font_family, d.rbx_font_face)
                or d.fontSize or 14)
            local font = cached and cached.font or renderer:_get_surface_gui_font(desired_size, d.rbx_font_asset, d.rbx_font_family, d.rbx_font_face)
            if font then
                local available_width = math.max(1, w - SURFACE_GUI_TEXT_PADDING * 2)
                local wrapped = d.rbx_text_wrapped == true
                local text_y, text_x
                local align = align_x
                if cached then
                    text_y, text_x = cached.text_y, cached.text_x
                else
                    local _,newlines=text:gsub("\n","");local line_count=newlines+1
                    if wrapped then
                        local _, wrapped_lines = font:getWrap(text, available_width)
                        line_count = math.max(1, #wrapped_lines)
                    end
                    local text_height = line_count * font:getHeight()
                    text_y = SURFACE_GUI_TEXT_PADDING
                    if align_y == "center" then
                        text_y = (h - text_height) * 0.5
                    elseif align_y == "bottom" then
                        text_y = h - text_height - SURFACE_GUI_TEXT_PADDING
                    end
                    text_x = SURFACE_GUI_TEXT_PADDING
                    if align == "center" then
                        local text_width = font:getWidth(text)
                        text_x = (w - text_width) * 0.5
                    elseif align == "right" then
                        local text_width = font:getWidth(text)
                        text_x = w - text_width - SURFACE_GUI_TEXT_PADDING
                    end
                    if cache_enabled then
                        -- one bounded entry per label, no multi-size/font history
                        rawset(self, "_rbx_text_metrics_cache", {_rbx_renderer=renderer,text=text,w=w,h=h,wrapped=wrapped,
                            scaled=d.textScaled,font_size=d.fontSize,font_asset=d.rbx_font_asset,font_family=d.rbx_font_family,font_face=d.rbx_font_face,
                            authored=renderer.use_authored_gui_fonts,font_provider=renderer._get_surface_gui_font,
                            align_x=align_x,align_y=align_y,desired_size=desired_size,font=font,text_x=text_x,text_y=text_y})
                    end
                end
                love.graphics.setFont(font)

                local stroke_alpha = (d.rbx_text_stroke_alpha or 0) * alpha
                if stroke_alpha > 0 then
                    local stroke_color = d.rbx_text_stroke_color
                    love.graphics.setColor(
                        stroke_color and stroke_color.r or 0,
                        stroke_color and stroke_color.g or 0,
                        stroke_color and stroke_color.b or 0,
                        stroke_alpha
                    )
                    local base_x = wrapped and SURFACE_GUI_TEXT_PADDING or text_x
                    for index = 1, #SURFACE_GUI_TEXT_STROKE_OFFSETS do
                        local offset = SURFACE_GUI_TEXT_STROKE_OFFSETS[index]
                        if wrapped then
                            love.graphics.printf(text, base_x + offset[1], text_y + offset[2], available_width, align)
                        else
                            love.graphics.print(text, base_x + offset[1], text_y + offset[2])
                        end
                    end
                end

                if source_node then RBX._draw_gui_contextual_strokes(source_node,function(x,y)
                    if wrapped then love.graphics.printf(text,x,y,available_width,align)else love.graphics.print(text,x,y)end
                end,wrapped and SURFACE_GUI_TEXT_PADDING or text_x,text_y)end

                local text_color = d.textColor
                love.graphics.setColor(
                    text_color and text_color[1] or 0,
                    text_color and text_color[2] or 0,
                    text_color and text_color[3] or 0,
                    alpha
                )
                if wrapped then
                    love.graphics.printf(text, SURFACE_GUI_TEXT_PADDING, text_y, available_width, align)
                else
                    love.graphics.print(text, text_x, text_y)
                end
            end
        end
    end

    local source_node=rawget(self,'_rbx_node')
    if source_node then RBX._draw_gui_border_strokes(source_node,w,h)end

    local border_size = d.rbx_border_size or 0
    local border_alpha = d.rbx_background_alpha or 0
    if border_size > 0 and border_alpha > 0 then
        -- borders sit outside the gui rect, inset drawing shrinks the content
        local border_color = d.rbx_border_color
        love.graphics.setColor(
            border_color and border_color.r or 0,
            border_color and border_color.g or 0,
            border_color and border_color.b or 0,
            border_alpha
        )
        love.graphics.setLineWidth(border_size)
        love.graphics.rectangle(
            "line",
            -border_size * 0.5,
            -border_size * 0.5,
            w + border_size,
            h + border_size
        )
    end
end

RbxGuiFrame.draw_self = rbx_gui_draw_self
RbxGuiImage.draw_self = rbx_gui_draw_self
RbxGuiText.draw_self = rbx_gui_draw_self

-- gui roots all map to the invisible root frame
GUI_BRIDGE_CLASS_MAP = {
    Frame = RbxGuiFrame,
    ImageLabel = RbxGuiImage,
    ImageButton = RbxGuiImage,
    TextLabel = RbxGuiText,
    TextButton = RbxGuiText,
    TextBox = RbxGuiText,
    SurfaceGui = RbxGuiFrame,
    SurfaceBoard = RbxGuiFrame,
    BillboardGui = RbxGuiFrame,
    ScreenGui = RbxGuiFrame,
}

local function remove_from_all_elements(element)
    for index = #AllElements, 1, -1 do
        if AllElements[index] == element then
            table.remove(AllElements, index)
        end
    end
end

-- resolve against the stored canvas parent rect, not the screen root
local function resolve_canvas_rect(element)
    local d = rawget(element, "__data")
    local linked = d and d.linked
    if linked == nil then
        local parent_rect = rawget(element, "_rbx_canvas_parent_rect")
        return Element.get_screen_rect(element, parent_rect)
    end
    return Element.get_screen_rect(element, resolve_canvas_rect(linked))
end

-- writes convert delta into pixel offsets so scales survive
local RBX_ELEMENT_GETTERS = {
    x = function(element)
        return resolve_canvas_rect(element).position.x
    end,
    y = function(element)
        return resolve_canvas_rect(element).position.y
    end,
    width = function(element)
        return resolve_canvas_rect(element).size.x
    end,
    height = function(element)
        return resolve_canvas_rect(element).size.y
    end,
    spriteSheetData = function(element)
        return rawget(element, "_rbx_sprite_sheet_data")
    end,
}

local function shift_udim2_offset(element, key, dx, dy)
    local d = rawget(element, "__data")
    local spec = d and d[key]
    local offset = spec and spec.offset or vec2()
    element[key] = { offset = vec2(offset.x + dx, offset.y + dy) }
end

local RBX_ELEMENT_SETTERS = {
    x = function(element, value)
        shift_udim2_offset(element, "position", (tonumber(value) or 0) - resolve_canvas_rect(element).position.x, 0)
    end,
    y = function(element, value)
        shift_udim2_offset(element, "position", 0, (tonumber(value) or 0) - resolve_canvas_rect(element).position.y)
    end,
    width = function(element, value)
        shift_udim2_offset(element, "size", (tonumber(value) or 0) - resolve_canvas_rect(element).size.x, 0)
    end,
    height = function(element, value)
        shift_udim2_offset(element, "size", 0, (tonumber(value) or 0) - resolve_canvas_rect(element).size.y)
    end,
    spriteSheetData = function(element, value)
        rawset(element, "_rbx_sprite_sheet_data", value)
    end,
}

-- setImageRect assigns imageRectOffset/Size itself, so the setters below recurse without this
local IN_SET_IMAGE_RECT = false
local function call_set_image_rect(element, offset, size)
    IN_SET_IMAGE_RECT = true
    local ok, err = pcall(element.setImageRect, element, offset, size)
    IN_SET_IMAGE_RECT = false
    if not ok then
        error(err, 0)
    end
end

RBX_ELEMENT_SETTERS.imageRectOffset = function(element, value)
    local d = rawget(element, "__data")
    if IN_SET_IMAGE_RECT or not element.setImageRect or not d.image then
        d.imageRectOffset = value
        return
    end
    call_set_image_rect(element,
        vec2(value.x or value.X or 0, value.y or value.Y or 0),
        d.imageRectSize or vec2())
end

RBX_ELEMENT_SETTERS.imageRectSize = function(element, value)
    local d = rawget(element, "__data")
    if IN_SET_IMAGE_RECT or not element.setImageRect or not d.image then
        d.imageRectSize = value
        return
    end
    call_set_image_rect(element,
        d.imageRectOffset or vec2(),
        vec2(value.x or value.X or 0, value.y or value.Y or 0))
end

-- base Element mt has no computed-property hook, so bridged elements get a thin wrapper
local ACCESSOR_MT_CACHE = {}
local function install_accessors(element)
    local base = getmetatable(element)
    local wrapped = ACCESSOR_MT_CACHE[base]
    if not wrapped then
        local base_index = base.__index
        local base_newindex = base.__newindex
        wrapped = {}
        for key, value in pairs(base) do
            wrapped[key] = value
        end
        wrapped.__index = function(obj, key)
            local getter = RBX_ELEMENT_GETTERS[key]
            if getter then
                return getter(obj)
            end
            return base_index(obj, key)
        end
        wrapped.__newindex = function(obj, key, value)
            local setter = RBX_ELEMENT_SETTERS[key]
            if setter then
                return setter(obj, value)
            end
            return base_newindex(obj, key, value)
        end
        ACCESSOR_MT_CACHE[base] = wrapped
    end
    setmetatable(element, wrapped)
end

-- plain file refs only. asset ids/rbxasset keep the legacy silent-skip so old maps dont grow checkers
local function is_local_image_path(image_ref)
    local lowered = safe_lower(trim(image_ref))
    if lowered == "" then
        return false
    end
    if lowered:find("^rbxasset") or lowered:find("^rbxgameasset") or lowered:find("^rbxthumb")
        or lowered:find("^http") or lowered:find("^%d+$") then
        return false
    end
    return true
end

local function apply_image_rect(element, node)
    if not element.setImageRect or not rawget(element, "__data").image then
        return
    end
    local offset = node.image_rect_offset
    local size = node.image_rect_size
    if size and (size.x or 0) > 0 and (size.y or 0) > 0 then
        call_set_image_rect(element,
            vec2(offset and offset.x or 0, offset and offset.y or 0),
            vec2(size.x, size.y))
    else
        local d = rawget(element, "__data")
        local image = d.image
        d.quad = nil
        if image then
            rawset(element, "_srcW", image:getWidth())
            rawset(element, "_srcH", image:getHeight())
            d.imageRectOffset = vec2(0, 0)
            d.imageRectSize = vec2(image:getWidth(), image:getHeight())
        end
        element:mark_dirty("imageRect")
    end
end

local function apply_scale_type(element, node)
    element.scale_type = node.scale_type or "stretch"
    rawset(element, "_rbx_tile_size_udim2", node.tile_size)
    if element.scale_type == "tile" and rawget(element, "__data").tile_size == nil then
        element.tile_size = vec2(64, 64)
    end
end

local function refresh_remote_bridge_image(
    renderer, element, texture, resource_key, handle, record)
    if rawget(element, "_rbx_renderer") ~= renderer then return true end
    local node = rawget(element, "_rbx_node")
    if type(node) ~= "table" or node.image ~= record.expected_asset_path
        or rawget(node, "_bridge_element") ~= element then
        return true
    end
    rawset(element, "_rbx_remote_texture_handle", handle)
    rawset(element, "_rbx_has_image", true)
    rawset(element, "_rbx_image_placeholder", nil)
    element.image = texture
    rawset(element, "_srcW", texture:getWidth())
    rawset(element, "_srcH", texture:getHeight())
    rawset(element, "_scaled_draw_cache", nil)
    rawset(element, "_quad_cache", nil)
    apply_image_rect(element, node)
    element:mark_dirty("image")
    local owner = rawget(element, "_rbx_gui_owner")
    if owner then
        if type(RBX._mark_surface_gui_dirty) == "function" then
            RBX._mark_surface_gui_dirty(owner, "content")
        end
        local state = owner._runtime_state
        if type(state) == "table" then state.rendered = false end
    end
    return true
end

local function apply_image(element, node)
    local renderer = rawget(element, "_rbx_renderer")
    local image_ref = node.image
    local texture, texture_key, remote_texture_handle = nil, nil, nil
    if type(image_ref) == "string" and image_ref ~= "" and renderer then
        texture, texture_key, remote_texture_handle = renderer:_get_or_load_texture(image_ref, {
            wrap_mode = "clamp",
            gui_placeholder = is_local_image_path(image_ref) or nil,
            remote_pending_placeholder = "transparent",
            defer_remote_gpu_upload = true,
        })
        if remote_texture_handle then
            rawset(element, "_rbx_remote_texture_handle", remote_texture_handle)
            renderer:_bind_remote_texture_consumer(
                remote_texture_handle, element, {
                    role = "gui_bridge_image",
                    scene_bound = false,
                    revision_field = false,
                    expected_asset_path = image_ref,
                    callback = refresh_remote_bridge_image,
                })
        end
    end
    local has_image = texture ~= nil and texture_key ~= "__white"
    rawset(element, "_rbx_has_image", has_image)
    rawset(element, "_rbx_image_placeholder", texture_key == "__gui_placeholder" or nil)
    if has_image then
        element.image = texture
        rawset(element, "_srcW", texture:getWidth())
        rawset(element, "_srcH", texture:getHeight())
        rawset(element, "_scaled_draw_cache", nil)
        rawset(element, "_quad_cache", nil)
        apply_image_rect(element, node)
    else
        element:mark_dirty("image")
    end
end

local NODE_FIELD_APPLIERS
-- Position and AnchorPoint locate a Roblox rectangle, Rotation pivots about
-- its center regardless of AnchorPoint. preserve the exact rectangle while
-- giving native Element the equivalent center anchor and position
-- `ratio` moves a SizeConstraint's size scale onto the native axis (parent
-- height over width for RelativeYY, the inverse for RelativeXX)
-- `constrained`, when given, is the final size as parent-relative scales
-- (layout constraints resolved against the parent's pixel size)
function RBX._gui_bridge_layout_specs(node,ratio,constrained)
    local position,size,anchor=node.position or{},node.size or{},node.anchor or{}
    local constraint=node.size_constraint
    local p,s={},{}
    for _,axis in ipairs({'x','y'})do
        local pa,sa,aa=position[axis]or{},size[axis]or{},anchor[axis]or{}
        local size_scale,size_offset=sa.scale or 0,sa.offset or 0
        if constrained then
            size_scale,size_offset=constrained[axis] or 0,0
        elseif ratio and ((constraint=='RelativeYY' and axis=='x') or (constraint=='RelativeXX' and axis=='y')) then
            size_scale=size_scale*ratio
        end
        local shift=.5-(aa.scale or 0)
        p[axis]={scale=(pa.scale or 0)+shift*size_scale,
            offset=(pa.offset or 0)+shift*size_offset-(aa.offset or 0)}
        s[axis]={scale=size_scale,offset=size_offset}
    end
    return p,s
end
apply_node_layout=function(element,node)
    local p,s=RBX._gui_bridge_layout_specs(node,rawget(element,'_rbx_constraint_ratio'),
        node.layout_constraints and rawget(element,'_rbx_constrained_scale') or nil)
    element.position={scale=vec2(p.x.scale,p.y.scale),offset=vec2(p.x.offset,p.y.offset)}
    element.size={scale=vec2(s.x.scale,s.y.scale),offset=vec2(s.x.offset,s.y.offset)}
    element.anchor={scale=vec2(.5,.5),offset=vec2(0,0)}
end
NODE_FIELD_APPLIERS = {
    position = apply_node_layout,
    size = apply_node_layout,
    anchor = apply_node_layout,
    size_constraint = apply_node_layout,
    rotation = function(element, node)
        element.rotation = math.rad(tonumber(node.rotation) or 0)
    end,
    visible = function(element, node)
        element.visible = node.visible ~= false
    end,
    zindex = function(element, node)
        element.zindex = math.floor(tonumber(node.zindex) or 0)
    end,
    clips_descendants = function(element, node)
        element.scissor = node.clips_descendants == true
    end,
    background_color = function(element, node)
        local color = node.background_color or { r = 1, g = 1, b = 1 }
        element.rbx_background_color = { r = color.r or 1, g = color.g or 1, b = color.b or 1 }
    end,
    background_transparency = function(element, node)
        element.rbx_background_alpha = clamp(1 - (tonumber(node.background_transparency) or 0), 0, 1)
    end,
    border_color = function(element, node)
        local color = node.border_color or { r = 0, g = 0, b = 0 }
        element.rbx_border_color = { r = color.r or 0, g = color.g or 0, b = color.b or 0 }
    end,
    border_size = function(element, node)
        element.rbx_border_size = math.max(0, tonumber(node.border_size) or 0)
    end,
    image = apply_image,
    image_color = function(element, node)
        local color = node.image_color or { r = 1, g = 1, b = 1 }
        element.color = { color.r or 1, color.g or 1, color.b or 1, 1 }
    end,
    image_transparency = function(element, node)
        element.rbx_image_alpha = clamp(1 - (tonumber(node.image_transparency) or 0), 0, 1)
    end,
    image_rect_offset = apply_image_rect,
    image_rect_size = apply_image_rect,
    scale_type = apply_scale_type,
    tile_size = apply_scale_type,
    slice_center = function(element, node)
        local slice = node.slice_center
        element.slice_center = slice and { x0 = slice.x0, y0 = slice.y0, x1 = slice.x1, y1 = slice.y1 } or nil
    end,
    text = function(element, node)
        element.text = tostring(node.text or "")
    end,
    text_color = function(element, node)
        local color = node.text_color or { r = 0, g = 0, b = 0 }
        element.textColor = { color.r or 0, color.g or 0, color.b or 0, 1 }
    end,
    text_transparency = function(element, node)
        element.rbx_text_alpha = clamp(1 - (tonumber(node.text_transparency) or 0), 0, 1)
    end,
    text_stroke_color = function(element, node)
        local color = node.text_stroke_color or { r = 0, g = 0, b = 0 }
        element.rbx_text_stroke_color = { r = color.r or 0, g = color.g or 0, b = color.b or 0 }
    end,
    text_stroke_transparency = function(element, node)
        element.rbx_text_stroke_alpha = clamp(1 - (tonumber(node.text_stroke_transparency) or 1), 0, 1)
    end,
    text_size = function(element, node)
        element.fontSize = math.max(4, tonumber(node.text_size) or 14)
    end,
    text_scaled = function(element, node)
        element.textScaled = node.text_scaled == true
    end,
    text_wrapped = function(element, node)
        element.rbx_text_wrapped = node.text_wrapped == true
    end,
    text_x_alignment = function(element, node)
        element.textAlignX = node.text_x_alignment or "center"
    end,
    text_y_alignment = function(element, node)
        element.textAlignY = node.text_y_alignment or "center"
    end,
    font = function(element, node)
        local family = node.font or "Legacy"
        element.rbx_font_family = family
        element.fontPath = ROBLOX_FONT_MAP[family]
    end,
    font_asset = function(element, node)
        element.rbx_font_asset = node.font_asset or ""
    end,
    font_face = function(element, node)
        element.rbx_font_face = node.font_face
    end,
    rich_text = function(element, node)
        element.rbx_rich_text = node.rich_text == true
    end,
}
NODE_FIELD_APPLIERS.anchor_point = NODE_FIELD_APPLIERS.anchor

-- called from the node proxy __newindex trap after the write
function RBX._gui_bridge_sync_node_key(node, element, key)
    local applier = NODE_FIELD_APPLIERS[key]
    if applier then
        applier(element, node)
    end
end

local NODE_BUILD_FIELDS = {
    "position", "size", "anchor", "rotation", "visible", "clips_descendants",
    "background_color", "background_transparency", "border_color", "border_size",
    "image_color", "image_transparency", "scale_type", "slice_center", "image",
    "text", "text_color", "text_transparency", "text_stroke_color",
    "text_stroke_transparency", "text_size", "text_scaled", "text_wrapped",
    "text_x_alignment", "text_y_alignment", "font", "font_asset", "font_face", "rich_text",
}

local function build_node_element(renderer, owner, node, progress, parent)
    local ctor = GUI_BRIDGE_CLASS_MAP[node.class_name] or RbxGuiFrame
    local element = ctor({
        name = tostring(node.name or node.class_name or "GuiObject"),
        clip_mode = "scissor",
        zindex = math.floor(tonumber(node.zindex) or 0),
    })
    remove_from_all_elements(element)
    -- the private pending root owns every child before property application or
    -- a loading yield can fail. Final hierarchy and child order are unchanged
    if parent then parent:add(element) end
    rawset(element, "_rbx_gui_owner", owner)
    rawset(element, "_rbx_renderer", renderer)
    rawset(element, "_rbx_node", node)
    rawset(node, "_bridge_element", element)
    for index = 1, #NODE_BUILD_FIELDS do
        NODE_FIELD_APPLIERS[NODE_BUILD_FIELDS[index]](element, node)
    end
    install_accessors(element)
    if progress then progress:step('datamodel:gui-build')end

    local children = node.children or {}
    for index = 1, #children do
        if children[index].class_name~='UIStroke'then build_node_element(renderer, owner, children[index], progress, element)end
    end
    return element
end

function RBX._gui_bridge_attach_node(renderer, owner, parent_node, node)
    if node.class_name=='UIStroke'then return end
    local parent = rawget(parent_node, "_bridge_element") or rawget(parent_node, "_bridge_root")
    if parent then parent:add(build_node_element(renderer, owner, node)) end
end

function RBX._gui_bridge_detach_node(node)
    local element = rawget(node, "_bridge_element")
    if element then element:remove() end
    local function clear(child)
        rawset(child, "_bridge_element", nil)
        for _, descendant in ipairs(child.children or {}) do clear(descendant) end
    end
    clear(node)
end

function RBX._gui_bridge_build_surface_gui(renderer, surface_gui, progress)
    if type(surface_gui) ~= "table" then
        return nil
    end
    local existing = rawget(surface_gui, "_bridge_root")
    if existing ~= nil then
        return existing
    end
    if rawget(surface_gui, "_bridge_failed") then
        return nil
    end

    local pending_root
    local ok, root_or_err = pcall(function()
        local root = RbxGuiFrame({
            name = tostring(surface_gui.name or "SurfaceGui"),
            size = { scale = vec2(1, 1) },
            clip_mode = "scissor",
        })
        remove_from_all_elements(root)
        pending_root=root
        rawset(root, "_rbx_gui_owner", surface_gui)
        rawset(root, "_rbx_renderer", renderer)
        root.rbx_background_alpha = 0
        install_accessors(root)

        local nodes = surface_gui.nodes or {}
        for index = 1, #nodes do
            build_node_element(renderer, surface_gui, nodes[index], progress, root)
        end
        return root
    end)
    if not ok then
        if pending_root then pending_root:remove()end
        local function clear_pending(node)
            rawset(node, "_bridge_element", nil)
            for _, child in ipairs(node.children or {})do clear_pending(child)end
        end
        for _, node in ipairs(surface_gui.nodes or {})do clear_pending(node)end
        if progress and progress.failed then error(progress.failed,0)end
        rawset(surface_gui, "_bridge_failed", true)
        print(string.format("[rbx ui] element build failed for %s: %s",
            tostring(surface_gui.runtime_id), tostring(root_or_err)))
        return nil
    end

    rawset(surface_gui, "_bridge_root", root_or_err)
    rawset(root_or_err, "_rbx_canvas_parent_rect", { position = vec2(0, 0), size = vec2(0, 0), _v = 1 })
    rawset(surface_gui, "_bridge_parent_rect", rawget(root_or_err, "_rbx_canvas_parent_rect"))
    if type(renderer) == "table" then
        renderer._gui_bridge_built_guis = (tonumber(renderer._gui_bridge_built_guis) or 0) + 1
    end
    return root_or_err
end

-- canvas already bound w/ origin() applied. false = fall back to the legacy loop
local function canvas_parent_rect(surface_gui, width, height)
    local parent_rect = rawget(surface_gui, "_bridge_parent_rect")
    if parent_rect.size.x ~= width or parent_rect.size.y ~= height then
        parent_rect.size.x = width
        parent_rect.size.y = height
        parent_rect._v = (parent_rect._v or 0) + 1
    end
    return parent_rect
end

-- Raster bounds are separate from the authored canvas-unit layout. a fixed
-- text label can paint outside its rectangle when descendant clipping is off
-- measure the same Element transforms/fonts used by drawing, only on rebakes
function RBX._gui_bridge_canvas_bounds(renderer, surface_gui, width, height)
    local bounds = {x=0,y=0,w=width,h=height,logical_w=width,logical_h=height}
    local root = RBX._gui_bridge_build_surface_gui(renderer, surface_gui)
    if not root or surface_gui.clips_descendants == true then return bounds end
    local parent_rect = canvas_parent_rect(surface_gui,width,height)
    local left,top,right,bottom=0,0,width,height
    local function aabb(rect,x0,y0,x1,y1)
        local angle=rect.rotation or 0;local cs,sn=math.cos(angle),math.sin(angle)
        local cx,cy=rect._ax or rect.size.x*.5,rect._ay or rect.size.y*.5
        local l,t,r,b=math.huge,math.huge,-math.huge,-math.huge
        for _,p in ipairs{{x0,y0},{x1,y0},{x1,y1},{x0,y1}}do
            local x=rect.position.x+cx+cs*(p[1]-cx)-sn*(p[2]-cy)
            local y=rect.position.y+cy+sn*(p[1]-cx)+cs*(p[2]-cy)
            l,t,r,b=math.min(l,x),math.min(t,y),math.max(r,x),math.max(b,y)
        end
        return {l,t,r,b}
    end
    local function visit(element,parent,clip)
        local d=rawget(element,'__data');if not d or d.visible==false then return end
        local rect=Element.get_screen_rect(element,parent);local w,h=rect.size.x,rect.size.y
        local box=aabb(rect,0,0,w,h)
        local x0,y0,x1,y1=0,0,w,h
        local text=d.text
        if text and text~='' and ((d.rbx_text_alpha or 1)>0 or RBX._gui_has_contextual_stroke(rawget(element,'_rbx_node')))then
            text=tostring(text)
            local size=d.textScaled and RBX._fit_surface_gui_text_size(renderer,text,w,h,d.rbx_text_wrapped==true,d.rbx_font_asset,d.rbx_font_family,d.rbx_font_face)or d.fontSize or 14
            local font=renderer:_get_surface_gui_font(size,d.rbx_font_asset,d.rbx_font_family,d.rbx_font_face)
            if font then
                local tw,lines=font:getWidth(text),select(2,text:gsub('\n',''))+1
                if d.rbx_text_wrapped then
                    local wrapped;tw,wrapped=font:getWrap(text,math.max(1,w));lines=math.max(1,#wrapped)
                end
                local th=lines*font:getHeight()
                local tx=d.textAlignX=='right' and w-tw or d.textAlignX=='left' and 0 or (w-tw)*.5
                local ty=d.textAlignY=='bottom' and h-th or d.textAlignY=='top' and 0 or (h-th)*.5
                local padding=(d.rbx_text_stroke_alpha or 0)>0 and 1 or 0
                local node=rawget(element,'_rbx_node')
                for _,stroke in ipairs(node and node.children or {})do
                    if stroke.class_name=='UIStroke' and stroke.enabled~=false and (stroke.stroke_transparency or 0)<1 then
                        padding=math.max(padding,stroke.stroke_thickness or 1)
                    end
                end
                x0,y0,x1,y1=math.min(x0,tx-padding),math.min(y0,ty-padding),math.max(x1,tx+tw+padding),math.max(y1,ty+th+padding)
            end
        end
        local paint=aabb(rect,x0,y0,x1,y1)
        if clip then paint={math.max(paint[1],clip[1]),math.max(paint[2],clip[2]),math.min(paint[3],clip[3]),math.min(paint[4],clip[4])}end
        if paint[3]>paint[1] and paint[4]>paint[2]then
            left,top,right,bottom=math.min(left,paint[1]),math.min(top,paint[2]),math.max(right,paint[3]),math.max(bottom,paint[4])
        end
        local child_clip=clip
        if d.scissor then
            child_clip=clip and {math.max(box[1],clip[1]),math.max(box[2],clip[2]),math.min(box[3],clip[3]),math.min(box[4],clip[4])}or box
        end
        for _,child in ipairs(d.children or {})do visit(child,rect,child_clip)end
    end
    for _,element in ipairs(rawget(root,'__data').children or {})do visit(element,parent_rect)end
    bounds.x,bounds.y=math.floor(left),math.floor(top)
    bounds.w,bounds.h=math.ceil(right)-bounds.x,math.ceil(bottom)-bounds.y
    return bounds
end

function RBX._gui_bridge_draw_canvas(renderer, surface_gui, width, height)
    local root = RBX._gui_bridge_build_surface_gui(renderer, surface_gui)
    if root == nil then
        return false
    end
    root.scissor=surface_gui.clips_descendants==true
    local parent_rect = canvas_parent_rect(surface_gui,width,height)
    local ok,err
    if surface_gui.zindex_behavior=='Global'then ok,err=pcall(root.draw_global,root,parent_rect)
    else ok,err=pcall(Element._draw_child,root,parent_rect)end
    if not ok then
        rawset(surface_gui, "_bridge_failed", true)
        rawset(surface_gui, "_bridge_root", nil)
        print(string.format("[rbx ui] draw failed for %s: %s",
            tostring(surface_gui.runtime_id), tostring(err)))
        return false
    end
    return true
end

-- Camera-attached project menus can present the authored Element tree
-- directly in screen space. they retain canvas-unit layout and crop bounds,
-- without baking a SurfaceGui texture or maintaining a moving GUI carrier
function RBX:_draw_gui_overlay(surface_gui, canvas_width, canvas_height, rect)
    if canvas_width <= 0 or canvas_height <= 0 or rect.w <= 0 or rect.h <= 0 then return false end
    local prior_metric_cache = rawget(surface_gui, "_overlay_text_metrics_cache")
    rawset(surface_gui, "_overlay_text_metrics_cache", true)
    local transform = rawget(surface_gui, "_overlay_transform")
    if not transform then
        transform = love.math.newTransform()
        rawset(surface_gui, "_overlay_transform", transform)
    end
    transform:setTransformation(rect.x, rect.y, 0, rect.w / canvas_width, rect.h / canvas_height)
    local prior_mapping = rawget(Element, "_clip_coordinate_transform")
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setDepthMode("always", false)
    love.graphics.setMeshCullMode("none")
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.applyTransform(transform)
    -- a SurfaceGui's canvas boundary clips even when its root does not
    -- request descendant clipping. keep that same boundary in screen space
    love.graphics.intersectScissor(rect.x, rect.y, rect.w, rect.h)
    rawset(Element, "_clip_coordinate_transform", transform)
    local ok, result = pcall(RBX._gui_bridge_draw_canvas, self, surface_gui, canvas_width, canvas_height)
    rawset(surface_gui, "_overlay_text_metrics_cache", prior_metric_cache)
    rawset(Element, "_clip_coordinate_transform", prior_mapping)
    love.graphics.pop()
    if not ok then error(result, 0) end
    return result
end

local function link_instance(by_referent, referent, node, element)
    if referent == nil then
        return 0
    end
    local instance = by_referent[referent]
    if type(instance) ~= "table" then
        return 0
    end
    rawset(instance, "_gui_element", element)
    rawset(instance, "_gui_node", node)
    rawset(node, "_gui_instance", instance)
    if RBX._observe_surface_gui_lifetime then RBX._observe_surface_gui_lifetime(instance, node) end
    rawset(element, "rbx_instance", instance)
    return 1
end

local function count_element_tree_size(element)
    local total = 1
    local d = rawget(element, "__data")
    local children = d and d.children or {}
    for index = 1, #children do
        total = total + count_element_tree_size(children[index])
    end
    return total
end

local function link_node_tree(by_referent, node, progress)
    local element = rawget(node, "_bridge_element")
    if element == nil then
        return 0
    end
    local count = link_instance(by_referent, node.referent, node, element)
    if progress then progress:step('datamodel:gui-link')end
    local children = node.children or {}
    for index = 1, #children do
        count = count + link_node_tree(by_referent, children[index], progress)
    end
    return count
end

-- post-load: builds every gui's element tree + wires facades by referent
function RBX:_gui_bridge_link_datamodel(datamodel, progress)
    local by_referent = datamodel and rawget(datamodel, "_instance_by_referent")
    if type(by_referent) ~= "table" then
        return
    end
    local linked = 0
    local renderer = self

    local function link_gui(gui, canvas_w, canvas_h)
        local root = RBX._gui_bridge_build_surface_gui(renderer, gui, progress)
        if not root then
            return
        end
        -- seed canvas parent rect so element.x/width read real values before first render
        local parent_rect = rawget(gui, "_bridge_parent_rect")
        if parent_rect and canvas_w and canvas_h
            and (parent_rect.size.x ~= canvas_w or parent_rect.size.y ~= canvas_h) then
            parent_rect.size.x = canvas_w
            parent_rect.size.y = canvas_h
            parent_rect._v = (parent_rect._v or 0) + 1
        end
        linked = linked + link_instance(by_referent, gui.referent, gui, root)
        local nodes = gui.nodes or {}
        for node_index = 1, #nodes do
            linked = linked + link_node_tree(by_referent, nodes[node_index], progress)
        end
    end

    local function link_gui_list(guis, part)
        if type(guis) ~= "table" then
            return
        end
        for gui_index = 1, #guis do
            local gui = guis[gui_index]
            if type(gui) == "table" then
                link_gui(gui, RBX._get_surface_gui_canvas_size(gui, part))
            end
        end
    end

    local parts = self.parts or {}
    for part_index = 1, #parts do
        if progress and part_index%64==0 then progress:mark('datamodel:gui-parts',part_index,#parts)end
        local part = parts[part_index]
        if type(part) == "table" and not part._destroyed then
            link_gui_list(part.SurfaceGuis, part)
            link_gui_list(part.BillboardGuis, part)
        end
    end

    local screen_guis = self._screen_guis
    if type(screen_guis) == "table" then
        local screen_w = self._last_render_target_width or love.graphics.getWidth()
        local screen_h = self._last_render_target_height or love.graphics.getHeight()
        for gui_index = 1, #screen_guis do
            local gui = screen_guis[gui_index]
            if type(gui) == "table" then
                link_gui(gui, screen_w, screen_h)
            end
        end
    end
    self._gui_bridge_linked_instances = linked
end

local function screen_gui_order_less(a, b)
    local order_a = tonumber(a.display_order) or 0
    local order_b = tonumber(b.display_order) or 0
    if order_a ~= order_b then
        return order_a < order_b
    end
    return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
end

-- screengui draw: straight to the 2d target post-scene, sorted by DisplayOrder then load order
function RBX:_draw_screen_guis(width, height)
    local collect_stats = self.collect_hotspot_stats == true or self.collect_detailed_draw_stats == true
    local stats = nil
    if collect_stats then
        stats = self._screen_gui_draw_stats or { order = {} }
        self._screen_gui_draw_stats = stats
        stats.drawn_count = 0
        stats.element_count = 0
        stats.disabled_count = 0
        for index = #stats.order, 1, -1 do
            stats.order[index] = nil
        end
    end
    local screen_guis = self._screen_guis
    if type(screen_guis) ~= "table" or #screen_guis == 0 then
        return
    end

    local sorted = self._screen_gui_sorted_buffer or {}
    self._screen_gui_sorted_buffer = sorted
    local sort_state = self._screen_gui_sort_state
    if not sort_state then
        sort_state = { refs = {}, display = {}, order = {}, count = 0 }
        self._screen_gui_sort_state = sort_state
    end
    local count = #screen_guis
    local sort_dirty = sort_state.count ~= count
    for index = 1, count do
        local gui = screen_guis[index]
        local display_order = tonumber(gui and gui.display_order) or 0
        local load_order = tonumber(gui and gui.order) or 0
        if sort_state.refs[index] ~= gui
            or sort_state.display[index] ~= display_order
            or sort_state.order[index] ~= load_order then
            sort_dirty = true
        end
    end
    if sort_dirty then
        for index = 1, count do
            local gui = screen_guis[index]
            sorted[index] = gui
            sort_state.refs[index] = gui
            sort_state.display[index] = tonumber(gui and gui.display_order) or 0
            sort_state.order[index] = tonumber(gui and gui.order) or 0
        end
        for index = count + 1, sort_state.count do
            sorted[index] = nil
            sort_state.refs[index] = nil
            sort_state.display[index] = nil
            sort_state.order[index] = nil
        end
        sort_state.count = count
        table.sort(sorted, screen_gui_order_less)
    end

    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setDepthMode("always", false)
    love.graphics.setMeshCullMode("none")
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.setColor(1, 1, 1, 1)
    for index = 1, #sorted do
        local gui = sorted[index]
        if gui.enabled ~= false then
            local root = RBX._gui_bridge_build_surface_gui(self, gui)
            if root then
                local parent_rect = rawget(gui, "_bridge_parent_rect")
                if parent_rect.size.x ~= width or parent_rect.size.y ~= height then
                    parent_rect.size.x = width
                    parent_rect.size.y = height
                    parent_rect._v = (parent_rect._v or 0) + 1
                end
                local ok, err
                if gui.zindex_behavior == "Global" then ok, err = pcall(root.draw_global, root, parent_rect)
                else ok, err = pcall(Element._draw_child, root, parent_rect) end
                if ok then
                    if stats then
                        stats.drawn_count = stats.drawn_count + 1
                        stats.element_count = stats.element_count + count_element_tree_size(root)
                        stats.order[#stats.order + 1] = tostring(gui.runtime_id)
                    end
                else
                    rawset(gui, "_bridge_failed", true)
                    rawset(gui, "_bridge_root", nil)
                    print(string.format("[rbx ui] screengui draw failed for %s: %s",
                        tostring(gui.runtime_id), tostring(err)))
                end
            end
        elseif stats then
            stats.disabled_count = stats.disabled_count + 1
        end
    end
    love.graphics.pop()
end

-- facade writes land on the node proxy, whose trap marks gui dirty + resyncs the element
local N = RBX._gui_normalizers

local FACADE_NODE_PROPS = {
    Position = { "position", N.udim2 },
    Size = { "size", N.udim2 },
    SizeConstraint = { "size_constraint", N.size_constraint },
    Rotation = { "rotation", function(v) return tonumber(v) or 0 end },
    Visible = { "visible", function(v) return N.bool(v, true) end },
    ZIndex = { "zindex", function(v) return math.floor(tonumber(v) or 1) end },
    ClipsDescendants = { "clips_descendants", function(v) return N.bool(v, false) end },
    BackgroundColor3 = { "background_color", function(v) return N.color3(v, 1, 1, 1) end },
    BackgroundTransparency = { "background_transparency", function(v) return clamp(tonumber(v) or 0, 0, 1) end },
    BorderColor3 = { "border_color", function(v) return N.color3(v, 0, 0, 0) end },
    BorderSizePixel = { "border_size", function(v) return math.max(0, tonumber(v) or 0) end },
    Image = { "image", function(v) return normalize_asset_reference(v) end },
    ImageColor3 = { "image_color", function(v) return N.color3(v, 1, 1, 1) end },
    ImageTransparency = { "image_transparency", function(v) return clamp(tonumber(v) or 0, 0, 1) end },
    ImageRectOffset = { "image_rect_offset", function(v) return N.vector2(v, 0, 0) end },
    ImageRectSize = { "image_rect_size", function(v) return N.vector2(v, 0, 0) end },
    ScaleType = { "scale_type", N.scale_type },
    SliceCenter = { "slice_center", N.rect },
    SliceScale = { "slice_scale", function(v) return math.max(0, tonumber(v) or 1) end },
    TileSize = { "tile_size", N.udim2 },
    Text = { "text", function(v) return tostring(v or "") end },
    TextColor3 = { "text_color", function(v) return N.color3(v, 0, 0, 0) end },
    TextTransparency = { "text_transparency", function(v) return clamp(tonumber(v) or 0, 0, 1) end },
    TextStrokeColor3 = { "text_stroke_color", function(v) return N.color3(v, 0, 0, 0) end },
    TextStrokeTransparency = { "text_stroke_transparency", function(v) return clamp(tonumber(v) or 1, 0, 1) end },
    TextSize = { "text_size", function(v) return math.max(4, tonumber(v) or 14) end },
    TextScaled = { "text_scaled", function(v) return N.bool(v, false) end },
    TextWrapped = { "text_wrapped", function(v) return N.bool(v, false) end },
    TextXAlignment = { "text_x_alignment", function(v) return N.text_alignment(v, "x") end },
    TextYAlignment = { "text_y_alignment", function(v) return N.text_alignment(v, "y") end },
    Font = { "font", N.font_name },
    FontFace = { "font", N.font_name },
    RichText = { "rich_text", function(v) return N.bool(v, false) end },
}

local FACADE_ROOT_PROPS = {
    Enabled = { "enabled", function(v) return N.bool(v, true) end },
    Face = { "face", N.face },
    ZIndexBehavior = { "zindex_behavior", function(v) if type(v)=='table'then v=v.Name or v.name or v.Value or v.value end;return (tonumber(v)==0 or tostring(v):match('Global$'))and'Global'or'Sibling'end },
    AlwaysOnTop = { "always_on_top", function(v) return N.bool(v, false) end },
    Brightness = { "brightness", function(v) return math.max(0, tonumber(v) or 1) end },
    LightInfluence = { "light_influence", function(v) return clamp(tonumber(v) or 0, 0, 1) end },
    MaxDistance = { "max_distance", function(v) return math.max(0, tonumber(v) or 0) end },
    PixelsPerStud = { "pixels_per_stud", function(v) return math.max(1, tonumber(v) or 50) end },
    SizingMode = { "sizing_mode", N.sizing_mode },
    CanvasSize = { "canvas_size", function(v) return N.vector2(v, 800, 600) end },
    ZOffset = { "z_offset", function(v) return tonumber(v) or 0 end },
    ClipsDescendants = { "clips_descendants", function(v) return N.bool(v, false) end },
    Adornee = { "adornee", function(v) return v end },
    -- billboard/screen root properties
    Size = { "size", N.udim2 },
    StudsOffset = { "studs_offset", function(v) return N.vector3(v, 0, 0, 0) end },
    StudsOffsetWorldSpace = { "studs_offset_world_space", function(v) return N.vector3(v, 0, 0, 0) end },
    ExtentsOffset = { "extents_offset", function(v) return N.vector3(v,0,0,0) end },
    ExtentsOffsetWorldSpace = { "extents_offset_world_space", function(v) return N.vector3(v,0,0,0) end },
    SizeOffset = { "size_offset", function(v) return N.vector2(v,0,0) end },
    DisplayOrder = { "display_order", function(v) return math.floor(tonumber(v) or 0) end },
}

function RBX._gui_bridge_apply_facade_write(instance, node, key, value)
    if type(node) ~= "table" then
        return false
    end
    if node.class_name=='UIStroke'then
        if key=='Enabled'then node.enabled=N.bool(value,true)
        elseif key=='Color'then node.stroke_color=N.color3(value,0,0,0)
        elseif key=='Transparency'then node.stroke_transparency=clamp(tonumber(value)or 0,0,1)
        elseif key=='Thickness'then node.stroke_thickness=math.max(0,tonumber(value)or 1)
        elseif key=='ApplyStrokeMode'then
            if type(value)=='table'then value=value.Name or value.name or value.Value or value.value end
            node.stroke_apply_mode=(value==1 or tostring(value):match('Border$'))and'Border'or'Contextual'
        else return false end
        return true
    end
    if rawget(node, "_surface_gui_proxy_kind") == "surface_gui" then
        local map = FACADE_ROOT_PROPS[key]
        if not map then
            return false
        end
        local normalized=map[2](value)
        local changed=node[map[1]]~=normalized
        node[map[1]] = normalized
        -- Root draw/face properties are captured by the retained face batch
        -- Canvas dirtiness alone leaves its depth/material state stale
        if changed and rawget(instance,'_class_name')=='SurfaceGui'
            and (key=='AlwaysOnTop' or key=='Face' or key=='LightInfluence'
                or key=='Brightness' or key=='ZOffset' or key=='MaxDistance')then
            local part=rawget(node,'_surface_gui_part_owner')
            local dm=rawget(instance,'_datamodel');local core=dm and rawget(dm,'_core')
            if part and core then core:_mark_runtime_part_face_textures_dirty(part)end
        end
        return true
    end
    local map = FACADE_NODE_PROPS[key]
    if not map then
        return false
    end
    node[map[1]] = map[2](value)
    if key == "FontFace" then
        node.font_asset = N.font_asset(value)
        node.font_face = type(value) == "table" and copy_runtime_value(value) or nil
    elseif key == "Font" then
        node.font_asset = ""
        node.font_face = nil
    end
    if key == "AnchorPoint" then
        node.anchor_point = N.vector2(value, 0, 0)
    end
    return true
end

-- AnchorPoint routes through the anchor normalizer: vector -> udim2
FACADE_NODE_PROPS.AnchorPoint = { "anchor", function(v) return N.anchor(v, 0, 0) end }
