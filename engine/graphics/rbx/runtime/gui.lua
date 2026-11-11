local authored_color3_to_gpu = runtime_require("coords.lua").color3_to_gpu

local SURFACE_GUI_FIXED_WIDTH = 800
local SURFACE_GUI_FIXED_HEIGHT = 600
local SURFACE_GUI_MIN_CANVAS_DIMENSION = 16
local SURFACE_GUI_DEFAULT_PIXELS_PER_STUD = 50
local SURFACE_GUI_VALIDATION_INTERVAL_FRAMES = 8
local SURFACE_GUI_MAX_VALIDATIONS_PER_FRAME = 32
-- Hidden/offscreen canvases are rendered lazily on first visible use. keeping
-- a non-zero rotating background scan here makes a settled scene pay forever,
-- even after every eligible canvas has already been considered
local SURFACE_GUI_BACKGROUND_PRELOAD_BUDGET = 0
local SURFACE_GUI_CONTENT_RESCAN_INTERVAL_FRAMES = 24
local SURFACE_GUI_TEXT_PADDING = 0 -- textlabels have no intrinsic padding
local SURFACE_GUI_SIGNATURE_MOD = 2147483647
local SURFACE_GUI_SIGNATURE_MULTIPLIER = 131
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

local function release_gui_resource(resource)
    if resource and type(resource.release) == "function" then
        pcall(resource.release, resource)
    end
end

local SURFACE_GUI_CLASSES = {
    SurfaceGui = true,
    SurfaceBoard = true,
}

local BILLBOARD_GUI_CLASSES = {
    BillboardGui = true,
}

-- billboard canvas: Scale=50px/stud, Offset=px 1:1
local BILLBOARD_GUI_PIXELS_PER_STUD = 50
local BILLBOARD_GUI_MAX_CANVAS_DIMENSION = 1024

local SURFACE_GUI_NODE_CLASSES = {
    Frame = true,
    TextLabel = true,
    TextButton = true,
    ImageLabel = true,
    ImageButton = true,
    TextBox = true,
    UIStroke = true,
}

local GUI_TEXT_X_ALIGNMENT = {
    Left = "left",
    Center = "center",
    Right = "right",
}

local GUI_TEXT_Y_ALIGNMENT = {
    Top = "top",
    Center = "center",
    Bottom = "bottom",
}

local GUI_FONT_SIZE_CACHE = {}
local SURFACE_GUI_MOTION_BUDGETS = {
    steady = {
        validation = 8,
        background = 6,
    },
    moving = {
        validation = 0,
        background = 2,
    },
    settling = {
        validation = 6,
        background = 4,
    },
}
-- NormalId: Front=-Z, Back=+Z, Top/Bottom canvas dims are (z, x)
local SURFACE_GUI_FACE_AXES = {
    Right = { nx = 1, ny = 0, nz = 0, su = "z", sv = "y" },
    Left = { nx = -1, ny = 0, nz = 0, su = "z", sv = "y" },
    Top = { nx = 0, ny = 1, nz = 0, su = "z", sv = "x" },
    Bottom = { nx = 0, ny = -1, nz = 0, su = "z", sv = "x" },
    Front = { nx = 0, ny = 0, nz = -1, su = "x", sv = "y" },
    Back = { nx = 0, ny = 0, nz = 1, su = "x", sv = "y" },
}

local SURFACE_GUI_LAYOUT_FIELDS = {
    class_name = true,
    name = true,
    face = true,
    sizing_mode = true,
    pixels_per_stud = true,
    canvas_size = true,
    enabled = true,
    always_on_top = true,
    zindex_behavior = true,
    light_influence = true,
    brightness = true,
    max_distance = true,
    clips_descendants = true,
    adornee = true,
    z_offset = true,
    -- size drives canvas, offset/order are transform-only
    size = true,
    studs_offset = true,
    studs_offset_world_space = true,
    extents_offset = true,
    extents_offset_world_space = true,
    size_offset = true,
    display_order = true,
    billboard = true,
}

local SURFACE_GUI_ROOT_TABLE_FIELDS = {
    canvas_size = true,
    size = true,
    studs_offset = true,
    studs_offset_world_space = true,
    extents_offset = true,
    extents_offset_world_space = true,
    size_offset = true,
}

local SURFACE_GUI_NODE_TABLE_FIELDS = {
    position = true,
    size = true,
    anchor = true,
    anchor_point = true,
    background_color = true,
    border_color = true,
    image_color = true,
    image_rect_offset = true,
    image_rect_size = true,
    tile_size = true,
    slice_center = true,
    text_color = true,
    text_stroke_color = true,
    stroke_color = true,
}

local surface_gui_proxy_mt
local surface_gui_node_proxy_mt
local surface_gui_property_proxy_mt

local function normalize_gui_face(value)
    if type(value)=='table'then return normalize_gui_face(value.Name or value.name or value.Value or value.value)end
    if type(value) == "number" then
        return RBX.FACE_ENUM[math.floor(value + 0.5)] or "Front"
    end
    if type(value) == "string" then
        local trimmed = trim(value)
        if trimmed:find("^Enum%.NormalId%.") then
            trimmed = trimmed:gsub("^Enum%.NormalId%.", "")
        elseif trimmed:find("^Enum%.Face%.") then
            trimmed = trimmed:gsub("^Enum%.Face%.", "")
        end
        return RBX.FACE_ENUM.aliases[safe_lower(trimmed)] or trimmed or "Front"
    end
    return "Front"
end

local function normalize_surface_gui_sizing_mode(value)
    if type(value)=='table'then return normalize_surface_gui_sizing_mode(value.Name or value.name or value.Value or value.value)end
    if type(value) == "number" then
        return value == 1 and "PixelsPerStud" or "FixedSize"
    end
    if type(value) == "string" then
        local trimmed = trim(value)
        trimmed = trimmed:gsub("^Enum%.SurfaceGuiSizingMode%.", "")
        local lowered = safe_lower(trimmed)
        if lowered == "pixelsperstud" then
            return "PixelsPerStud"
        end
        if lowered == "fixedsize" then
            return "FixedSize"
        end
    end
    return "FixedSize"
end

local function normalize_gui_vector2(value, default_x, default_y)
    local out = { x = default_x or 0, y = default_y or 0 }
    if type(value) ~= "table" then
        return out
    end

    out.x = tonumber(value.X or value.x or value[1]) or out.x
    out.y = tonumber(value.Y or value.y or value[2]) or out.y
    return out
end

local function normalize_gui_vector3(value, default_x, default_y, default_z)
    local out = { x = default_x or 0, y = default_y or 0, z = default_z or 0 }
    if type(value) ~= "table" then
        return out
    end

    out.x = tonumber(value.X or value.x or value[1]) or out.x
    out.y = tonumber(value.Y or value.y or value[2]) or out.y
    out.z = tonumber(value.Z or value.z or value[3]) or out.z
    return out
end

local function normalize_gui_udim(value, default_scale, default_offset)
    local out = {
        scale = default_scale or 0,
        offset = default_offset or 0,
    }
    if type(value) ~= "table" then
        return out
    end

    out.scale = tonumber(value.Scale or value.scale or value.S or value.s or value[1]) or out.scale
    out.offset = tonumber(value.Offset or value.offset or value.O or value.o or value[2]) or out.offset
    return out
end

local function normalize_gui_udim2(value)
    if type(value) ~= "table" then
        return {
            x = normalize_gui_udim(nil, 0, 0),
            y = normalize_gui_udim(nil, 0, 0),
        }
    end

    if value.scale or value.Scale or value.offset or value.Offset then
        local scale = normalize_gui_vector2(value.scale or value.Scale, 0, 0)
        local offset = normalize_gui_vector2(value.offset or value.Offset, 0, 0)
        return {
            x = normalize_gui_udim({
                Scale = scale.x,
                Offset = offset.x,
            }, 0, 0),
            y = normalize_gui_udim({
                Scale = scale.y,
                Offset = offset.y,
            }, 0, 0),
        }
    end

    return {
        x = normalize_gui_udim(value.X or value.x, 0, 0),
        y = normalize_gui_udim(value.Y or value.y, 0, 0),
    }
end

local function normalize_gui_anchor(value, fallback_x, fallback_y)
    if type(value) == "table" then
        if value.X or value.x or value.Y or value.y then
            local point = normalize_gui_vector2(value, fallback_x or 0, fallback_y or 0)
            return {
                x = normalize_gui_udim({
                    Scale = point.x,
                    Offset = 0,
                }, 0, 0),
                y = normalize_gui_udim({
                    Scale = point.y,
                    Offset = 0,
                }, 0, 0),
            }
        end
        return normalize_gui_udim2(value)
    end
    return {
        x = normalize_gui_udim({
            Scale = fallback_x or 0,
            Offset = 0,
        }, 0, 0),
        y = normalize_gui_udim({
            Scale = fallback_y or 0,
            Offset = 0,
        }, 0, 0),
    }
end

local function normalize_gui_color3(value, default_r, default_g, default_b)
    local r, g, b = color3_to_rgb255(value, default_r or 1, default_g or 1, default_b or 1)
    return {
        r = clamp((tonumber(r) or 255) / 255, 0, 1),
        g = clamp((tonumber(g) or 255) / 255, 0, 1),
        b = clamp((tonumber(b) or 255) / 255, 0, 1),
    }
end

local function normalize_gui_bool(value, default_value)
    if value == nil then
        return default_value == true
    end
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        local lowered = safe_lower(trim(value))
        return lowered == "true" or lowered == "1"
    end
    return default_value == true
end

local function normalize_gui_text_alignment(value, axis)
    if type(value)=='table'then return normalize_gui_text_alignment(value.Name or value.name or value.Value or value.value,axis)end
    if type(value) == "number" then
        if axis == "x" then
            return GUI_TEXT_X_ALIGNMENT[RBX.TEXT_X_ALIGNMENT_ENUM and RBX.TEXT_X_ALIGNMENT_ENUM[math.floor(value + 0.5)]]
                or "center"
        end
        return GUI_TEXT_Y_ALIGNMENT[RBX.TEXT_Y_ALIGNMENT_ENUM and RBX.TEXT_Y_ALIGNMENT_ENUM[math.floor(value + 0.5)]] or
            "center"
    end

    if type(value) == "string" then
        local trimmed = trim(value)
        if axis == "x" then
            trimmed = trimmed:gsub("^Enum%.TextXAlignment%.", "")
            return GUI_TEXT_X_ALIGNMENT[trimmed] or GUI_TEXT_X_ALIGNMENT[trimmed:gsub("^%l", string.upper)] or "center"
        end
        trimmed = trimmed:gsub("^Enum%.TextYAlignment%.", "")
        return GUI_TEXT_Y_ALIGNMENT[trimmed] or GUI_TEXT_Y_ALIGNMENT[trimmed:gsub("^%l", string.upper)] or "center"
    end

    return "center"
end

-- referents: xml strings or binary ids
local function normalize_gui_referent(value)
    if type(value) == "number" then
        return value >= 0 and value or nil
    end
    if type(value) == "string" then
        local trimmed = trim(value)
        return trimmed ~= "" and trimmed or nil
    end
    return nil
end

local GUI_SCALE_TYPE_ENUM = {
    [0] = "stretch",
    [1] = "slice",
    [2] = "tile",
    [3] = "fit",
    [4] = "crop",
}

local function normalize_gui_scale_type(value)
    if type(value) == "number" then
        return GUI_SCALE_TYPE_ENUM[math.floor(value + 0.5)] or "stretch"
    end
    if type(value) == "table" then
        return normalize_gui_scale_type(value.Value or value.value or value.Name or value.name)
    end
    if type(value) == "string" then
        local trimmed = trim(value):gsub("^Enum%.ScaleType%.", "")
        local lowered = safe_lower(trimmed)
        for _, name in pairs(GUI_SCALE_TYPE_ENUM) do
            if name == lowered then
                return name
            end
        end
    end
    return "stretch"
end

-- SizeConstraint: which parent axis each Size scale is measured against
local GUI_SIZE_CONSTRAINT_ENUM = { [0] = "RelativeXY", [1] = "RelativeXX", [2] = "RelativeYY" }

local function normalize_gui_size_constraint(value)
    if type(value) == "number" then
        return GUI_SIZE_CONSTRAINT_ENUM[math.floor(value + 0.5)] or "RelativeXY"
    end
    if type(value) == "table" then
        return normalize_gui_size_constraint(value.Value or value.value or value.Name or value.name)
    end
    if type(value) == "string" then
        local name = trim(value):gsub("^Enum%.SizeConstraint%.", "")
        if name == "RelativeXX" or name == "RelativeYY" then return name end
    end
    return "RelativeXY"
end

-- the parent lengths that a node's Size scales multiply, per SizeConstraint
local function gui_size_scale_bases(node, parent_w, parent_h)
    local constraint = node.size_constraint
    if constraint == "RelativeYY" then return parent_h, parent_h end
    if constraint == "RelativeXX" then return parent_w, parent_w end
    return parent_w, parent_h
end

-- SliceCenter Rect -> pixel edges
local function normalize_gui_rect(value)
    if type(value) ~= "table" then
        return nil
    end
    local min = normalize_gui_vector2(value.Min or value.min, 0, 0)
    local max = normalize_gui_vector2(value.Max or value.max, 0, 0)
    return { x0 = min.x, y0 = min.y, x1 = max.x, y1 = max.y }
end

local function normalize_gui_font_name(value)
    if type(value) == "table" then
        local family = value.family or value.Family or value.Name or value.name
        if type(family) == "string" and family ~= "" then
            return family
        end
        local value_name = value.value or value.Value
        if type(value_name) == "string" and value_name ~= "" then
            return value_name
        end
    elseif type(value) == "string" then
        local trimmed = trim(value)
        trimmed = trimmed:gsub("^Enum%.Font%.", "")
        if trimmed ~= "" then
            return trimmed
        end
    end
    return "Legacy"
end

-- FontFace stores the selected weight/style's actual file separately from the
-- family JSON. preserve it without changing the legacy Font facade value
local function normalize_gui_font_asset(value)
    if type(value) ~= "table" then return "" end
    local reference = value.cachedFaceId or value.CachedFaceId or value.cached_face_id
    return type(reference) == "string" and trim(reference) or ""
end

local function hash_surface_gui_value(value)
    local text = tostring(value or "")
    local hash = 0
    for index = 1, #text do
        hash = (hash * 131 + text:byte(index)) % 2147483647
    end
    return hash
end

local function mix_surface_gui_signature(hash, value)
    return ((hash * SURFACE_GUI_SIGNATURE_MULTIPLIER) + (tonumber(value) or 0)) % SURFACE_GUI_SIGNATURE_MOD
end

local function mix_surface_gui_signature_bool(hash, value)
    return mix_surface_gui_signature(hash, value and 1 or 0)
end

local function mix_surface_gui_signature_number(hash, value, scale)
    local numeric = tonumber(value) or 0
    local precision = tonumber(scale) or 1024
    if numeric >= 0 then
        numeric = math.floor(numeric * precision + 0.5)
    else
        numeric = -math.floor((-numeric) * precision + 0.5)
    end
    return mix_surface_gui_signature(hash, numeric)
end

local function mix_surface_gui_signature_string(hash, value)
    local text = tostring(value or "")
    hash = mix_surface_gui_signature(hash, #text)
    for index = 1, #text do
        hash = mix_surface_gui_signature(hash, text:byte(index))
    end
    return hash
end

local function get_surface_gui_validation_phase(surface_gui, state, validation_interval)
    validation_interval = math.max(1, validation_interval or 1)
    local phase = tonumber(state.validation_phase)
    if phase == nil then
        phase = hash_surface_gui_value(surface_gui and surface_gui.runtime_id) % validation_interval
    else
        phase = math.floor(phase) % validation_interval
    end
    state.validation_phase = phase
    return phase
end

local function get_surface_gui_next_validation_frame(surface_gui, state, frame_id, validation_interval)
    validation_interval = math.max(1, validation_interval or 1)
    local phase = get_surface_gui_validation_phase(surface_gui, state, validation_interval)
    local frame_mod = frame_id % validation_interval
    local delta = phase - frame_mod
    if delta <= 0 then
        delta = delta + validation_interval
    end
    return frame_id + delta
end

local function get_surface_gui_validation_interval(renderer)
    local validation_interval = math.max(
        1,
        math.floor(tonumber(renderer and renderer.surface_gui_validation_interval_frames) or
            SURFACE_GUI_VALIDATION_INTERVAL_FRAMES)
    )
    local active_surface_gui_count = math.max(
        tonumber(renderer and renderer.surface_gui_count) or 0,
        tonumber(renderer and renderer._surface_gui_stats and renderer._surface_gui_stats.visible_batch_count) or 0
    )
    if active_surface_gui_count >= 256 then
        return math.max(validation_interval, 24)
    end
    if active_surface_gui_count >= 128 then
        return math.max(validation_interval, 18)
    end
    return validation_interval
end

local function get_surface_gui_motion_state(renderer)
    local state = renderer and renderer._camera_motion_state or nil
    if state == "moving" or state == "settling" then
        return state
    end
    return "steady"
end

local function get_surface_gui_budget(renderer, budget_key, fallback)
    local budgets = SURFACE_GUI_MOTION_BUDGETS[get_surface_gui_motion_state(renderer)] or SURFACE_GUI_MOTION_BUDGETS.steady
    return budgets[budget_key] or fallback or 0
end

local function mark_surface_gui_dirty(surface_gui, dirty_kind)
    if type(surface_gui) ~= "table" then
        return
    end

    rawset(surface_gui, "_content_dirty", true)
    rawset(surface_gui, "_surface_gui_content_version", (tonumber(rawget(surface_gui, "_surface_gui_content_version")) or 0) + 1)
    if dirty_kind == "layout" then
        rawset(surface_gui, "_layout_dirty", true)
        rawset(surface_gui, "_surface_gui_layout_version", (tonumber(rawget(surface_gui, "_surface_gui_layout_version")) or 0) + 1)
    end
end

local function proxy_surface_gui_index(proxy, key)
    if type(key) == "string" and key:sub(1, 1) == "_" then
        return rawget(proxy, key)
    end
    local data = rawget(proxy, "_surface_gui_data")
    if data == nil then
        return nil
    end
    -- no "or nil" collapse: stored false must read back false
    return data[key]
end

local function wrap_surface_gui_property_value(value, owner, dirty_kind)
    if type(value) ~= "table" then
        return value
    end
    local existing_kind = rawget(value, "_surface_gui_proxy_kind")
    if existing_kind == "surface_gui_property" then
        rawset(value, "_surface_gui_owner", owner)
        rawset(value, "_surface_gui_dirty_kind", dirty_kind or "content")
        return value
    end

    local proxy = {}
    local data = {}
    rawset(proxy, "_surface_gui_proxy_kind", "surface_gui_property")
    rawset(proxy, "_surface_gui_owner", owner)
    rawset(proxy, "_surface_gui_dirty_kind", dirty_kind or "content")
    rawset(proxy, "_surface_gui_data", data)
    setmetatable(proxy, surface_gui_property_proxy_mt)

    for key, item in pairs(value) do
        if type(item) == "table" then
            data[key] = wrap_surface_gui_property_value(item, owner, dirty_kind)
        else
            data[key] = item
        end
    end

    return proxy
end

local function wrap_surface_gui_node(node, owner)
    if type(node) ~= "table" then
        return node
    end
    local existing_kind = rawget(node, "_surface_gui_proxy_kind")
    if existing_kind == "surface_gui_node" then
        rawset(node, "_surface_gui_owner", owner)
        return node
    end

    local proxy = {}
    local data = {}
    rawset(proxy, "_surface_gui_proxy_kind", "surface_gui_node")
    rawset(proxy, "_surface_gui_owner", owner)
    rawset(proxy, "_surface_gui_data", data)
    setmetatable(proxy, surface_gui_node_proxy_mt)

    for key, item in pairs(node) do
        if key == "children" then
            local children = {}
            for index = 1, #(item or {}) do
                children[index] = wrap_surface_gui_node(item[index], owner)
            end
            data[key] = children
        elseif SURFACE_GUI_NODE_TABLE_FIELDS[key] and type(item) == "table" then
            data[key] = wrap_surface_gui_property_value(item, owner, "content")
        else
            data[key] = item
        end
    end

    return proxy
end

local function wrap_surface_gui_node_list(nodes, owner)
    if type(nodes) ~= "table" then
        return {}
    end
    local wrapped = {}
    for index = 1, #nodes do
        wrapped[index] = wrap_surface_gui_node(nodes[index], owner)
    end
    return wrapped
end

local function wrap_surface_gui_runtime(surface_gui)
    if type(surface_gui) ~= "table" then
        return surface_gui
    end
    local existing_kind = rawget(surface_gui, "_surface_gui_proxy_kind")
    if existing_kind == "surface_gui" then
        return surface_gui
    end

    local proxy = {}
    local data = {}
    rawset(proxy, "_surface_gui_proxy_kind", "surface_gui")
    rawset(proxy, "_surface_gui_data", data)
    rawset(proxy, "_surface_gui_event_wrapped", true)
    rawset(proxy, "_surface_gui_content_version", tonumber(rawget(surface_gui, "_surface_gui_content_version")) or 1)
    rawset(proxy, "_surface_gui_layout_version", tonumber(rawget(surface_gui, "_surface_gui_layout_version")) or 1)
    rawset(proxy, "_content_dirty", rawget(surface_gui, "_content_dirty") ~= false)
    rawset(proxy, "_layout_dirty", rawget(surface_gui, "_layout_dirty") ~= false)
    rawset(proxy, "_runtime_state", rawget(surface_gui, "_runtime_state"))
    setmetatable(proxy, surface_gui_proxy_mt)

    for key, item in pairs(surface_gui) do
        if key ~= "_runtime_state"
            and not (type(key) == "string" and key:sub(1, 1) == "_") then
            if key == "nodes" then
                data[key] = wrap_surface_gui_node_list(item, proxy)
            elseif SURFACE_GUI_ROOT_TABLE_FIELDS[key] and type(item) == "table" then
                data[key] = wrap_surface_gui_property_value(item, proxy, SURFACE_GUI_LAYOUT_FIELDS[key] and "layout" or "content")
            else
                data[key] = item
            end
        end
    end

    return proxy
end

surface_gui_property_proxy_mt = {
    __index = proxy_surface_gui_index,
    __newindex = function(proxy, key, value)
        if type(key) == "string" and key:sub(1, 1) == "_" then
            rawset(proxy, key, value)
            return
        end
        local owner = rawget(proxy, "_surface_gui_owner")
        local dirty_kind = rawget(proxy, "_surface_gui_dirty_kind") or "content"
        local data = rawget(proxy, "_surface_gui_data")
        if type(value) == "table" then
            value = wrap_surface_gui_property_value(value, owner, dirty_kind)
        end
        data[key] = value
        mark_surface_gui_dirty(owner, dirty_kind)
    end,
}

surface_gui_node_proxy_mt = {
    __index = proxy_surface_gui_index,
    __newindex = function(proxy, key, value)
        if type(key) == "string" and key:sub(1, 1) == "_" then
            rawset(proxy, key, value)
            return
        end
        local owner = rawget(proxy, "_surface_gui_owner")
        local data = rawget(proxy, "_surface_gui_data")
        if key == "children" then
            value = wrap_surface_gui_node_list(value, owner)
        elseif SURFACE_GUI_NODE_TABLE_FIELDS[key] and type(value) == "table" then
            value = wrap_surface_gui_property_value(value, owner, "content")
        end
        data[key] = value
        mark_surface_gui_dirty(owner, "content")
        -- one write = one element update + one dirty flag
        local element = rawget(proxy, "_bridge_element")
        if element ~= nil and RBX._gui_bridge_sync_node_key then
            RBX._gui_bridge_sync_node_key(proxy, element, key)
        end
    end,
}

surface_gui_proxy_mt = {
    __index = proxy_surface_gui_index,
    __newindex = function(proxy, key, value)
        if type(key) == "string" and key:sub(1, 1) == "_" then
            rawset(proxy, key, value)
            return
        end
        local data = rawget(proxy, "_surface_gui_data")
        local dirty_kind = SURFACE_GUI_LAYOUT_FIELDS[key] and "layout" or "content"
        if key == "nodes" then
            value = wrap_surface_gui_node_list(value, proxy)
        elseif SURFACE_GUI_ROOT_TABLE_FIELDS[key] and type(value) == "table" then
            value = wrap_surface_gui_property_value(value, proxy, dirty_kind)
        end
        data[key] = value
        mark_surface_gui_dirty(proxy, dirty_kind)
    end,
}

-- Enum values may arrive as numbers, names ("Enum.AspectType.X") or EnumItems
local function gui_enum_name(value, names)
    if type(value) == "table" then value = value.Name or value.name or value.Value or value.value end
    if type(value) == "number" then return names[math.floor(value) + 1] end
    if type(value) == "string" then
        local name = value:match("([%w_]+)$")
        for _, candidate in ipairs(names) do if candidate == name then return name end end
    end
    return names[1]
end

-- UIAspectRatioConstraint and UISizeConstraint shape their parent's size;
-- they become `layout_constraints` on that node, never drawable nodes
local function normalize_gui_layout_constraint(instance, class_name, order_seed)
    local node = { class_name = class_name, layout_constraint = true, children = {}, order = order_seed or 0,
        name = instance.Name or instance.name or class_name }
    if class_name == "UIAspectRatioConstraint" then
        node.aspect_ratio = math.max(0, tonumber(instance.AspectRatio or instance.aspectratio) or 1)
        node.aspect_type = gui_enum_name(instance.AspectType or instance.aspecttype, { "FitWithinMaxSize", "ScaleWithParentSize" })
        node.dominant_axis = gui_enum_name(instance.DominantAxis or instance.dominantaxis, { "Width", "Height" })
    else
        node.min_size = normalize_gui_vector2(instance.MinSize or instance.minsize, 0, 0)
        node.max_size = normalize_gui_vector2(instance.MaxSize or instance.maxsize, math.huge, math.huge)
    end
    return node
end

-- the pixel size of `node` inside a parent of pw x ph after SizeConstraint
-- and its UIAspectRatioConstraint/UISizeConstraint children, in order
-- AspectType/DominantAxis follow the Robot port's native_ui.lua
function RBX._gui_constrained_pixel_size(node, pw, ph)
    local size = node.size or {}
    local sx, sy = size.x or {}, size.y or {}
    local rx, ry = pw, ph
    if node.size_constraint == "RelativeXX" then ry = pw elseif node.size_constraint == "RelativeYY" then rx = ph end
    local w = (sx.scale or 0) * rx + (sx.offset or 0)
    local h = (sy.scale or 0) * ry + (sy.offset or 0)
    for _, c in ipairs(node.layout_constraints or {}) do
        if c.class_name == "UIAspectRatioConstraint" and (c.aspect_ratio or 0) > 0 then
            local ratio = c.aspect_ratio
            if c.aspect_type == "ScaleWithParentSize" then
                if c.dominant_axis == "Height" then h = math.min(h, ph, pw / ratio); w = h * ratio
                else w = math.min(w, pw, ph * ratio); h = w / ratio end
            elseif w > h * ratio then w = h * ratio else h = w / ratio end
        elseif c.class_name == "UISizeConstraint" then
            local low, high = c.min_size or {}, c.max_size or {}
            w = math.max(low.x or 0, math.min(high.x or math.huge, w))
            h = math.max(low.y or 0, math.min(high.y or math.huge, h))
        end
    end
    return math.max(0, w), math.max(0, h)
end

local function normalize_gui_node(instance, order_seed)
    if type(instance) ~= "table" then
        return nil
    end

    local class_name = instance.ClassName or instance.className or instance.class_name
    if class_name == "UIAspectRatioConstraint" or class_name == "UISizeConstraint" then
        return normalize_gui_layout_constraint(instance, class_name, order_seed), order_seed
    end
    if class_name=='UIStroke'then
        local enabled=instance.Enabled;if enabled==nil then enabled=instance.enabled end
        local mode=instance.ApplyStrokeMode or instance.applystrokemode
        if type(mode)=='table'then mode=mode.Name or mode.name or mode.Value or mode.value end
        return{class_name='UIStroke',name=instance.Name or instance.name or'UIStroke',order=order_seed or 0,
            referent=normalize_gui_referent(instance.Referent or instance.referent),children={},
            enabled=normalize_gui_bool(enabled,true),stroke_color=normalize_gui_color3(instance.Color or instance.color,0,0,0),
            stroke_transparency=clamp(tonumber(instance.Transparency or instance.transparency)or 0,0,1),
            stroke_thickness=math.max(0,tonumber(instance.Thickness or instance.thickness)or 1),
            stroke_apply_mode=(mode==1 or tostring(mode):match('Border$'))and'Border'or'Contextual'},order_seed
    end
    local children = {}
    local layout_constraints
    local source_children = instance.Children or instance.children or {}
    local next_order = order_seed or 0
    for index = 1, #source_children do
        local child = source_children[index]
        local parsed_child, updated_order = normalize_gui_node(child, next_order + 1)
        next_order = updated_order or next_order
        if parsed_child and parsed_child.layout_constraint then
            layout_constraints = layout_constraints or {}
            layout_constraints[#layout_constraints + 1] = parsed_child
        elseif parsed_child then
            children[#children + 1] = parsed_child
        end
    end

    if not SURFACE_GUI_NODE_CLASSES[class_name] then
        return nil, next_order
    end

    local anchor_point = normalize_gui_vector2(instance.AnchorPoint or instance.anchorpoint, 0, 0)
    local visible_value = instance.Visible
    if visible_value == nil then
        visible_value = instance.visible
    end
    local clips_descendants_value = instance.ClipsDescendants
    if clips_descendants_value == nil then
        clips_descendants_value = instance.clipsdescendants
    end
    local node = {
        class_name = class_name,
        name = instance.Name or instance.name or class_name,
        visible = normalize_gui_bool(visible_value, true),
        zindex = math.floor(tonumber(instance.ZIndex or instance.zindex) or 1),
        order = next_order,
        position = normalize_gui_udim2(instance.Position or instance.position),
        size = normalize_gui_udim2(instance.Size or instance.size),
        anchor = normalize_gui_anchor(instance.Anchor or instance.anchor, anchor_point.x, anchor_point.y),
        anchor_point = anchor_point,
        rotation = tonumber(instance.Rotation or instance.rotation) or 0,
        background_color = normalize_gui_color3(instance.BackgroundColor3 or instance.BackgroundColor or
            instance.backgroundcolor3 or instance.backgroundcolor, 1, 1, 1),
        background_transparency = clamp(
            tonumber(instance.BackgroundTransparency or instance.backgroundtransparency) or 0,
            0,
            1
        ),
        border_color = normalize_gui_color3(instance.BorderColor3 or instance.BorderColor or instance.bordercolor3 or
            instance.bordercolor, 0, 0, 0),
        border_size = math.max(0, tonumber(instance.BorderSizePixel or instance.bordersizepixel) or 0),
        clips_descendants = normalize_gui_bool(clips_descendants_value, false),
        image = normalize_asset_reference(instance.Image or instance.image),
        image_color = normalize_gui_color3(instance.ImageColor3 or instance.ImageColor or instance.imagecolor3 or
            instance.imagecolor, 1, 1, 1),
        image_transparency = clamp(tonumber(instance.ImageTransparency or instance.imagetransparency) or 0, 0, 1),
        image_rect_offset = normalize_gui_vector2(instance.ImageRectOffset or instance.imagerectoffset, 0, 0),
        image_rect_size = normalize_gui_vector2(instance.ImageRectSize or instance.imagerectsize, 0, 0),
        scale_type = normalize_gui_scale_type(instance.ScaleType or instance.scaletype),
        size_constraint = normalize_gui_size_constraint(instance.SizeConstraint or instance.sizeconstraint),
        slice_center = normalize_gui_rect(instance.SliceCenter or instance.slicecenter),
        slice_scale = math.max(0, tonumber(instance.SliceScale or instance.slicescale) or 1),
        tile_size = (instance.TileSize or instance.tilesize) ~= nil
            and normalize_gui_udim2(instance.TileSize or instance.tilesize) or nil,
        rich_text = normalize_gui_bool(instance.RichText or instance.richtext, false),
        referent = normalize_gui_referent(instance.Referent or instance.referent),
        text = tostring(instance.Text or instance.text or ""),
        text_color = normalize_gui_color3(instance.TextColor3 or instance.TextColor or instance.textcolor3 or
            instance.textcolor, 0, 0, 0),
        text_transparency = clamp(tonumber(instance.TextTransparency or instance.texttransparency) or 0, 0, 1),
        text_stroke_color = normalize_gui_color3(
            instance.TextStrokeColor3 or instance.TextStrokeColor or instance.textstrokecolor3 or
            instance.textstrokecolor,
            0,
            0,
            0
        ),
        text_stroke_transparency = clamp(
            tonumber(instance.TextStrokeTransparency or instance.textstroketransparency) or 1,
            0,
            1
        ),
        text_size = math.max(4, tonumber(instance.TextSize or instance.textsize) or 14),
        text_scaled = normalize_gui_bool(instance.TextScaled or instance.textscaled, false),
        text_wrapped = normalize_gui_bool(instance.TextWrapped or instance.textwrapped, false),
        text_x_alignment = normalize_gui_text_alignment(
            instance.TextXAlignment or instance.textxalignment,
            "x"
        ),
        text_y_alignment = normalize_gui_text_alignment(
            instance.TextYAlignment or instance.textyalignment,
            "y"
        ),
        font = normalize_gui_font_name(instance.FontFace or instance.Font or instance.fontface or instance.font),
        font_asset = normalize_gui_font_asset(instance.FontFace or instance.fontface),
        font_face = type(instance.FontFace or instance.fontface) == "table"
            and copy_runtime_value(instance.FontFace or instance.fontface) or nil,
        children = children,
        layout_constraints = layout_constraints,
    }

    node.anchor_point = {
        x = node.anchor.x.scale or anchor_point.x or 0,
        y = node.anchor.y.scale or anchor_point.y or 0,
    }

    table.sort(node.children, function(a, b)
        if (a.zindex or 0) ~= (b.zindex or 0) then
            return (a.zindex or 0) < (b.zindex or 0)
        end
        return (a.order or 0) < (b.order or 0)
    end)

    return node, next_order
end

-- shared w/ gui_bridge.lua: facade writes reuse these normalizers
RBX._mark_surface_gui_dirty = mark_surface_gui_dirty
RBX._gui_normalizers = {
    udim2 = normalize_gui_udim2,
    anchor = normalize_gui_anchor,
    vector2 = normalize_gui_vector2,
    vector3 = normalize_gui_vector3,
    color3 = normalize_gui_color3,
    bool = normalize_gui_bool,
    text_alignment = normalize_gui_text_alignment,
    font_name = normalize_gui_font_name,
    font_asset = normalize_gui_font_asset,
    face = normalize_gui_face,
    sizing_mode = normalize_surface_gui_sizing_mode,
    scale_type = normalize_gui_scale_type,
    size_constraint = normalize_gui_size_constraint,
    rect = normalize_gui_rect,
    referent = normalize_gui_referent,
}

function RBX._clone_surface_gui_list(surface_guis)
    local cloned = {}
    for index = 1, #(surface_guis or {}) do
        cloned[index] = wrap_surface_gui_runtime(copy_runtime_value(surface_guis[index]))
    end
    return cloned
end

function RBX._wrap_surface_gui_runtime(surface_gui)
    return wrap_surface_gui_runtime(surface_gui)
end

function RBX._is_surface_gui_class(class_name)
    return SURFACE_GUI_CLASSES[class_name] == true
end

function RBX._is_billboard_gui_class(class_name)
    return BILLBOARD_GUI_CLASSES[class_name] == true
end

function RBX._is_screen_gui_class(class_name)
    return class_name == "ScreenGui"
end

function RBX._parse_surface_gui_instance(instance, part_index, order_seed)
    if type(instance) ~= "table" then
        return nil
    end

    local class_name = instance.ClassName or instance.className or instance.class_name
    if not RBX._is_surface_gui_class(class_name) then
        return nil
    end

    local nodes = {}
    local next_order = order_seed or 0
    local children = instance.Children or instance.children or {}
    for index = 1, #children do
        local child_node, updated_order = normalize_gui_node(children[index], next_order + 1)
        next_order = updated_order or next_order
        if child_node and not child_node.layout_constraint then
            nodes[#nodes + 1] = child_node
        end
    end

    table.sort(nodes, function(a, b)
        if (a.zindex or 0) ~= (b.zindex or 0) then
            return (a.zindex or 0) < (b.zindex or 0)
        end
        return (a.order or 0) < (b.order or 0)
    end)

    local enabled_value = instance.Enabled
    if enabled_value == nil then
        enabled_value = instance.enabled
    end
    local always_on_top_value = instance.AlwaysOnTop
    if always_on_top_value == nil then
        always_on_top_value = instance.alwaysontop
    end
    local clips_descendants_value = instance.ClipsDescendants
    if clips_descendants_value == nil then
        clips_descendants_value = instance.clipsdescendants
    end

    return {
        class_name = class_name,
        name = instance.Name or instance.name or class_name,
        face = normalize_gui_face(instance.Face or instance.face),
        sizing_mode = normalize_surface_gui_sizing_mode(instance.SizingMode or instance.sizingmode),
        pixels_per_stud = math.max(
            1,
            tonumber(instance.PixelsPerStud or instance.pixelsperstud) or SURFACE_GUI_DEFAULT_PIXELS_PER_STUD
        ),
        canvas_size = normalize_gui_vector2(instance.CanvasSize or instance.canvassize, SURFACE_GUI_FIXED_WIDTH,
            SURFACE_GUI_FIXED_HEIGHT),
        enabled = normalize_gui_bool(enabled_value, true),
        zindex_behavior=(tonumber(instance.ZIndexBehavior)==0 or tostring(instance.ZIndexBehavior):match('Global$'))and'Global'or'Sibling',
        always_on_top = normalize_gui_bool(always_on_top_value, false),
        light_influence = clamp(tonumber(instance.LightInfluence or instance.lightinfluence) or 0, 0, 1),
        brightness = math.max(0, tonumber(instance.Brightness or instance.brightness) or 1),
        max_distance = math.max(0, tonumber(instance.MaxDistance or instance.maxdistance) or 0),
        clips_descendants = normalize_gui_bool(clips_descendants_value, true),
        z_offset = tonumber(instance.ZOffset or instance.zoffset) or 0,
        adornee = instance.Adornee or instance.adornee,
        referent = normalize_gui_referent(instance.Referent or instance.referent),
        nodes = nodes,
        -- order_seed keeps same-named guis on one part distinct, else shared cache key
        runtime_id = string.format("%s|%s|%d|%d", class_name, tostring(instance.Name or instance.name or class_name),
            tonumber(part_index) or 0, tonumber(order_seed) or 0),
    }
end

local function parse_gui_root_nodes(instance, order_seed)
    local nodes = {}
    local next_order = order_seed or 0
    local children = instance.Children or instance.children or {}
    for index = 1, #children do
        local child_node, updated_order = normalize_gui_node(children[index], next_order + 1)
        next_order = updated_order or next_order
        if child_node and not child_node.layout_constraint then
            nodes[#nodes + 1] = child_node
        end
    end

    table.sort(nodes, function(a, b)
        if (a.zindex or 0) ~= (b.zindex or 0) then
            return (a.zindex or 0) < (b.zindex or 0)
        end
        return (a.order or 0) < (b.order or 0)
    end)
    return nodes
end

function RBX._parse_billboard_gui_instance(instance, part_index, order_seed)
    if type(instance) ~= "table" then
        return nil
    end

    local class_name = instance.ClassName or instance.className or instance.class_name
    if not RBX._is_billboard_gui_class(class_name) then
        return nil
    end

    local enabled_value = instance.Enabled
    if enabled_value == nil then
        enabled_value = instance.enabled
    end
    local always_on_top_value = instance.AlwaysOnTop
    if always_on_top_value == nil then
        always_on_top_value = instance.alwaysontop
    end
    local name = tostring(instance.Name or instance.name or class_name)

    return {
        class_name = class_name,
        billboard = true,
        name = name,
        -- Size: Scale=studs, Offset=screen px
        size = normalize_gui_udim2(instance.Size or instance.size),
        studs_offset = normalize_gui_vector3(instance.StudsOffset or instance.studsoffset, 0, 0, 0),
        studs_offset_world_space = normalize_gui_vector3(
            instance.StudsOffsetWorldSpace or instance.studsoffsetworldspace, 0, 0, 0),
        extents_offset = normalize_gui_vector3(instance.ExtentsOffset or instance.extentsoffset,0,0,0),
        extents_offset_world_space = normalize_gui_vector3(instance.ExtentsOffsetWorldSpace or instance.extentsoffsetworldspace,0,0,0),
        size_offset = normalize_gui_vector2(instance.SizeOffset or instance.sizeoffset,0,0),
        enabled = normalize_gui_bool(enabled_value, true),
        zindex_behavior=(tonumber(instance.ZIndexBehavior)==0 or tostring(instance.ZIndexBehavior):match('Global$'))and'Global'or'Sibling',
        always_on_top = normalize_gui_bool(always_on_top_value, false),
        light_influence = clamp(tonumber(instance.LightInfluence or instance.lightinfluence) or 0, 0, 1),
        brightness = math.max(0, tonumber(instance.Brightness or instance.brightness) or 1),
        -- 0 = unlimited (INF in xml -> nil -> 0)
        max_distance = math.max(0, tonumber(instance.MaxDistance or instance.maxdistance) or 0),
        clips_descendants = normalize_gui_bool(instance.ClipsDescendants or instance.clipsdescendants, false),
        adornee = instance.Adornee or instance.adornee,
        referent = normalize_gui_referent(instance.Referent or instance.referent),
        nodes = parse_gui_root_nodes(instance, 0),
        runtime_id = string.format("%s|%s|%d|%d", class_name, name,
            tonumber(part_index) or 0, tonumber(order_seed) or 0),
    }
end

function RBX._parse_screen_gui_instance(instance, order_seed)
    if type(instance) ~= "table" then
        return nil
    end

    local class_name = instance.ClassName or instance.className or instance.class_name
    if not RBX._is_screen_gui_class(class_name) then
        return nil
    end

    local enabled_value = instance.Enabled
    if enabled_value == nil then
        enabled_value = instance.enabled
    end
    local name = tostring(instance.Name or instance.name or class_name)

    return {
        class_name = class_name,
        screen = true,
        name = name,
        enabled = normalize_gui_bool(enabled_value, true),
        zindex_behavior=(tonumber(instance.ZIndexBehavior)==0 or tostring(instance.ZIndexBehavior):match('Global$'))and'Global'or'Sibling',
        display_order = math.floor(tonumber(instance.DisplayOrder or instance.displayorder) or 0),
        -- DisplayOrder ties draw in parse order
        order = tonumber(order_seed) or 0,
        referent = normalize_gui_referent(instance.Referent or instance.referent),
        nodes = parse_gui_root_nodes(instance, 0),
        runtime_id = string.format("%s|%s|%d", class_name, name, tonumber(order_seed) or 0),
    }
end

local function get_surface_gui_face_dimensions(part, face_name)
    local size = type(part) == "table" and part.Size or nil
    local sx = math.abs(tonumber(size and size.x) or 4)
    local sy = math.abs(tonumber(size and size.y) or 1)
    local sz = math.abs(tonumber(size and size.z) or 2)

    if type(part) == "table" and type(part.BlockMeshScale) == "table" then
        sx = sx * math.abs(tonumber(part.BlockMeshScale.x) or 1)
        sy = sy * math.abs(tonumber(part.BlockMeshScale.y) or 1)
        sz = sz * math.abs(tonumber(part.BlockMeshScale.z) or 1)
    end

    if face_name == "Left" or face_name == "Right" then
        return sz, sy
    end
    if face_name == "Top" or face_name == "Bottom" then
        -- Top/Bottom canvas is (z, x) not (x, z), rotated 90deg vs decal frame
        return sz, sx
    end
    return sx, sy
end

function RBX._get_surface_gui_canvas_size(surface_gui, part)
    if surface_gui and surface_gui.billboard == true then
        -- distance-independent canvas so billboard never redraws on cam motion
        local size = surface_gui.size or {}
        local sx = size.x or {}
        local sy = size.y or {}
        local width = (tonumber(sx.scale) or 0) * BILLBOARD_GUI_PIXELS_PER_STUD + (tonumber(sx.offset) or 0)
        local height = (tonumber(sy.scale) or 0) * BILLBOARD_GUI_PIXELS_PER_STUD + (tonumber(sy.offset) or 0)
        return clamp(round_dimension(width) or 0, SURFACE_GUI_MIN_CANVAS_DIMENSION, BILLBOARD_GUI_MAX_CANVAS_DIMENSION),
            clamp(round_dimension(height) or 0, SURFACE_GUI_MIN_CANVAS_DIMENSION, BILLBOARD_GUI_MAX_CANVAS_DIMENSION)
    end
    local sizing_mode = normalize_surface_gui_sizing_mode(surface_gui and surface_gui.sizing_mode)
    if sizing_mode == "PixelsPerStud" then
        local face_width, face_height = get_surface_gui_face_dimensions(part, surface_gui and surface_gui.face)
        local pixels_per_stud = math.max(
            1,
            tonumber(surface_gui and surface_gui.pixels_per_stud) or SURFACE_GUI_DEFAULT_PIXELS_PER_STUD
        )
        return math.max(SURFACE_GUI_MIN_CANVAS_DIMENSION, round_dimension(face_width * pixels_per_stud) or 0),
            math.max(SURFACE_GUI_MIN_CANVAS_DIMENSION, round_dimension(face_height * pixels_per_stud) or 0)
    end

    local canvas_size = normalize_gui_vector2(surface_gui and surface_gui.canvas_size, SURFACE_GUI_FIXED_WIDTH,
        SURFACE_GUI_FIXED_HEIGHT)
    return math.max(SURFACE_GUI_MIN_CANVAS_DIMENSION, round_dimension(canvas_size.x) or 0),
        math.max(SURFACE_GUI_MIN_CANVAS_DIMENSION, round_dimension(canvas_size.y) or 0)
end

function RBX:_get_surface_gui_layout_signature(surface_gui, part)
    local width, height = RBX._get_surface_gui_canvas_size(surface_gui, part)
    local hash = 17
    hash = mix_surface_gui_signature_string(hash, surface_gui and surface_gui.face or "Front")
    hash = mix_surface_gui_signature_string(hash, surface_gui and surface_gui.sizing_mode or "FixedSize")
    hash = mix_surface_gui_signature(hash, width)
    hash = mix_surface_gui_signature(hash, height)
    hash = mix_surface_gui_signature_bool(hash, surface_gui and surface_gui.always_on_top == true)
    -- Positive infinity is an authored unlimited distance, like zero. keep the
    -- descriptor/public value intact, only the cache signature needs a finite key
    local max_distance = surface_gui and surface_gui.max_distance
    if max_distance == math.huge then max_distance = 0 end
    hash = mix_surface_gui_signature_number(hash, max_distance, 1000)
    return hash
end

function RBX:_get_surface_gui_descriptor_signature(surface_gui, part)
    local hash = self:_get_surface_gui_layout_signature(surface_gui, part)
    hash = mix_surface_gui_signature_number(hash, clamp(tonumber(surface_gui and surface_gui.light_influence) or 0, 0, 1), 1000)
    hash = mix_surface_gui_signature_number(hash, math.max(0, tonumber(surface_gui and surface_gui.brightness) or 1), 1000)
    hash = mix_surface_gui_signature_number(hash, tonumber(surface_gui and surface_gui.z_offset) or 0, 1000)
    local raster=surface_gui and surface_gui._runtime_state and surface_gui._runtime_state.raster_bounds
    if raster then
        for _,key in ipairs{'x','y','w','h'}do hash=mix_surface_gui_signature_number(hash,raster[key],1)end
    end
    return hash
end

local function mix_surface_gui_udim2_signature(hash, value)
    local x = value and value.x or nil
    local y = value and value.y or nil
    hash = mix_surface_gui_signature_number(hash, x and x.scale or 0, 1000)
    hash = mix_surface_gui_signature_number(hash, x and x.offset or 0, 1000)
    hash = mix_surface_gui_signature_number(hash, y and y.scale or 0, 1000)
    hash = mix_surface_gui_signature_number(hash, y and y.offset or 0, 1000)
    return hash
end

local function mix_surface_gui_color_signature(hash, value)
    hash = mix_surface_gui_signature_number(hash, value and value.r or 0, 4096)
    hash = mix_surface_gui_signature_number(hash, value and value.g or 0, 4096)
    hash = mix_surface_gui_signature_number(hash, value and value.b or 0, 4096)
    return hash
end

local function mix_surface_gui_node_signature(hash, node)
    hash = mix_surface_gui_signature_string(hash, node and node.class_name or "")
    if node and node.class_name=='UIStroke'then
        hash=mix_surface_gui_signature_bool(hash,node.enabled~=false)
        hash=mix_surface_gui_color_signature(hash,node.stroke_color)
        hash=mix_surface_gui_signature_number(hash,node.stroke_transparency,4096)
        hash=mix_surface_gui_signature_number(hash,node.stroke_thickness,256)
        return mix_surface_gui_signature_string(hash,node.stroke_apply_mode)
    end
    hash = mix_surface_gui_signature_bool(hash, node and node.visible == true)
    hash = mix_surface_gui_signature(hash, node and node.zindex or 0)
    hash = mix_surface_gui_signature(hash, node and node.order or 0)
    hash = mix_surface_gui_udim2_signature(hash, node and node.position)
    hash = mix_surface_gui_udim2_signature(hash, node and node.size)
    hash = mix_surface_gui_udim2_signature(hash, node and node.anchor)
    hash = mix_surface_gui_signature_number(hash, node and node.rotation or 0, 1000)
    hash = mix_surface_gui_color_signature(hash, node and node.background_color)
    hash = mix_surface_gui_signature_number(hash, node and node.background_transparency or 0, 4096)
    hash = mix_surface_gui_color_signature(hash, node and node.border_color)
    hash = mix_surface_gui_signature_number(hash, node and node.border_size or 0, 256)
    hash = mix_surface_gui_signature_bool(hash, node and node.clips_descendants == true)
    hash = mix_surface_gui_signature_string(hash, node and node.image or "")
    hash = mix_surface_gui_color_signature(hash, node and node.image_color)
    hash = mix_surface_gui_signature_number(hash, node and node.image_transparency or 0, 4096)
    hash = mix_surface_gui_signature_string(hash, node and node.scale_type or "stretch")
    hash = mix_surface_gui_signature_string(hash, node and node.size_constraint or "RelativeXY")
    hash = mix_surface_gui_signature_number(hash, node and node.slice_scale or 1, 4096)
    hash = mix_surface_gui_udim2_signature(hash, node and node.tile_size)
    for _, key in ipairs({"image_rect_offset", "image_rect_size"}) do
        local value = node and node[key] or {}
        hash = mix_surface_gui_signature_number(hash, value.x or 0, 256)
        hash = mix_surface_gui_signature_number(hash, value.y or 0, 256)
    end
    local slice = node and node.slice_center or {}
    for _, key in ipairs({"x0", "y0", "x1", "y1"}) do
        hash = mix_surface_gui_signature_number(hash, slice[key] or 0, 256)
    end
    hash = mix_surface_gui_signature_string(hash, node and node.text or "")
    hash = mix_surface_gui_color_signature(hash, node and node.text_color)
    hash = mix_surface_gui_signature_number(hash, node and node.text_transparency or 0, 4096)
    hash = mix_surface_gui_color_signature(hash, node and node.text_stroke_color)
    hash = mix_surface_gui_signature_number(hash, node and node.text_stroke_transparency or 0, 4096)
    hash = mix_surface_gui_signature_number(hash, node and node.text_size or 0, 256)
    hash = mix_surface_gui_signature_bool(hash, node and node.text_scaled == true)
    hash = mix_surface_gui_signature_bool(hash, node and node.text_wrapped == true)
    hash = mix_surface_gui_signature_string(hash, node and node.text_x_alignment or "")
    hash = mix_surface_gui_signature_string(hash, node and node.text_y_alignment or "")
    hash = mix_surface_gui_signature_string(hash, node and node.font or "")
    hash = mix_surface_gui_signature_string(hash, node and node.font_asset or "")
    local face = node and node.font_face or {}
    hash = mix_surface_gui_signature_string(hash, face.weight or face.Weight or 400)
    hash = mix_surface_gui_signature_string(hash, face.style or face.Style or 0)

    local children = node and node.children or {}
    hash = mix_surface_gui_signature(hash, #children)
    for index = 1, #children do
        hash = mix_surface_gui_node_signature(hash, children[index])
    end
    return hash
end

function RBX:_get_surface_gui_content_signature(surface_gui)
    if surface_gui and rawget(surface_gui, "_surface_gui_event_wrapped") == true then
        local nodes = surface_gui.nodes or {}
        local hash = tonumber(rawget(surface_gui, "_surface_gui_content_version")) or 0
        hash = mix_surface_gui_signature(hash, #nodes)
        return hash
    end
    local hash = 23
    hash = mix_surface_gui_signature_bool(hash, surface_gui and surface_gui.enabled ~= false)
    hash = mix_surface_gui_signature_bool(hash, surface_gui and surface_gui.clips_descendants == true)
    hash = mix_surface_gui_signature_string(hash, surface_gui and surface_gui.name or "")
    hash = mix_surface_gui_signature_string(hash, surface_gui and surface_gui.class_name or "")
    hash = mix_surface_gui_signature_string(hash, surface_gui and surface_gui.runtime_id or "")
    local nodes = surface_gui and surface_gui.nodes or {}
    hash = mix_surface_gui_signature(hash, #nodes)
    for index = 1, #nodes do
        hash = mix_surface_gui_node_signature(hash, nodes[index])
    end
    return hash
end

local function should_refresh_surface_gui_content_signature(surface_gui, state, frame_id)
    if surface_gui and rawget(surface_gui, "_surface_gui_event_wrapped") == true then
        return state.content_signature == nil
    end
    if state.content_signature == nil then
        return true
    end
    if surface_gui and surface_gui._content_dirty == true then
        return true
    end
    local nodes = surface_gui and surface_gui.nodes or nil
    if state.content_signature_nodes ~= nodes then
        return true
    end
    if state.content_signature_node_count ~= #(nodes or {}) then
        return true
    end
    return frame_id >= (state.next_content_signature_frame or 0)
end

local function get_surface_gui_texture_key(surface_gui)
    return "surface_gui|" .. tostring(surface_gui and surface_gui.runtime_id or "anonymous")
end

-- the broad-script fallback face when a checkout provides it, otherwise the
-- LÖVE default font (see engine/graphics/font_manager.lua)
local GUI_LEGACY_FONT_PATH = "NotoSansJP-Regular.otf"

local function warn_gui_font(renderer, reference, reason)
    reference = tostring(reference or "unknown")
    renderer._gui_font_warnings = renderer._gui_font_warnings or {}
    if renderer._gui_font_warnings[reference] then return end
    renderer._gui_font_warnings[reference] = reason
    print(string.format("[rbx] authored font '%s' %s; using the fallback font", reference, reason))
end

-- some places store a font family without cachedFaceId
-- use the local family file to find the requested weight and style
local function resolve_authored_gui_font(renderer, font_asset, family, face)
    face = type(face) == "table" and face or {}
    local weight = tonumber(face.weight or face.Weight) or 400
    local style = face.style or face.Style or 0
    style = (style == 1 or style == "Italic" or style == "italic") and "italic" or "normal"
    local key = table.concat({ renderer._map_build_path or renderer.map_path or "",
        renderer.asset_root or "", font_asset or "", family or "", weight, style }, "\0")
    renderer._gui_font_paths = renderer._gui_font_paths or {}
    local cached = renderer._gui_font_paths[key]
    if cached ~= nil then return cached or nil end

    local path
    if type(font_asset) == "string" and font_asset ~= "" then
        path = renderer:_resolve_asset_path(font_asset, "font")
    end
    if not path and type(family) == "string" and family:match("%.json$") then
        local family_path = renderer:_resolve_asset_path(family, "font")
        local data = family_path and love.filesystem.read(family_path)
        if data then
            local json = require("engine/services/oss/menori/modules/libs/json")
            local ok, definition = pcall(json.decode, data)
            if ok and type(definition) == "table" and type(definition.faces) == "table" then
                for _, candidate in ipairs(definition.faces) do
                    if type(candidate) == "table" and candidate.weight == weight and candidate.style == style then
                        path = renderer:_resolve_asset_path(candidate.assetId, "font")
                        break
                    end
                end
            end
        end
    end
    renderer._gui_font_paths[key] = path or false
    if not path and ((font_asset and font_asset ~= "") or (family and family ~= "Legacy")) then
        warn_gui_font(renderer, font_asset ~= "" and font_asset or family, "was not found locally")
    end
    return path
end

-- use the same face axes as textured geometry. Canvas Y points down, the
-- geometric face V axis points up, and the texture shader flips V once
-- the inverse below also supplies depth so callers can reject another plane
local function surface_gui_mapping(surface_gui,part)
    local adornee=surface_gui and surface_gui.adornee
    if type(adornee)=='table'then part=rawget(adornee,'_core_handle')or(adornee.Size and adornee.CFrame and adornee)or part end
    assert(type(part)=='table'and not part._destroyed,'Live SurfaceGui adornee required')
    local face=surface_gui and surface_gui.face or'Front'
    local axes=assert(SURFACE_GUI_CANVAS_FACE_AXES,'SurfaceGui geometry axes are unavailable')
    local a=axes[face]or axes.Front
    local px,py,pz,rx,ry,rz,ux,uy,uz,bx,by,bz,sx,sy,sz=get_runtime_part_render_basis(part)
    local sizes={x=math.abs(sx),y=math.abs(sy),z=math.abs(sz)}
    local width,height=sizes[a.su],sizes[a.sv]
    local cx,cy,cz=a.nx*sizes.x*.5,a.ny*sizes.y*.5,a.nz*sizes.z*.5
    local center=Vector3.new(px+rx*cx+ux*cy+bx*cz,py+ry*cx+uy*cy+by*cz,pz+rz*cx+uz*cy+bz*cz)
    local u=Vector3.new(rx*a.ux+ux*a.uy+bx*a.uz,ry*a.ux+uy*a.uy+by*a.uz,rz*a.ux+uz*a.uy+bz*a.uz)
    local v=Vector3.new(rx*a.vx+ux*a.vy+bx*a.vz,ry*a.vx+uy*a.vy+by*a.vz,rz*a.vx+uz*a.vy+bz*a.vz)
    local normal=Vector3.new(rx*a.nx+ux*a.ny+bx*a.nz,ry*a.nx+uy*a.ny+by*a.nz,rz*a.nx+uz*a.ny+bz*a.nz)
    local canvas_w,canvas_h=RBX._get_surface_gui_canvas_size(surface_gui,part)
    return center,u,v,normal,width,height,canvas_w,canvas_h
end
function RBX._surface_gui_canvas_to_world(surface_gui,part,x,y)
    local center,u,v,normal,width,height,cw,ch=surface_gui_mapping(surface_gui,part)
    assert(width>0 and height>0,'Nonzero SurfaceGui face required')
    return center+u*((x/cw-.5)*width)+v*((.5-y/ch)*height),normal
end
function RBX._surface_gui_world_to_canvas(surface_gui,part,point)
    local center,u,v,normal,width,height,cw,ch=surface_gui_mapping(surface_gui,part)
    assert(width>0 and height>0,'Nonzero SurfaceGui face required')
    local delta=point-center;local x=(delta:Dot(u)/width+.5)*cw;local y=(.5-delta:Dot(v)/height)*ch
    return x,y,delta:Dot(normal),x>=0 and y>=0 and x<=cw and y<=ch
end

function RBX:_get_surface_gui_font(size, font_asset, family, face)
    size = math.max(4, round_dimension(size) or 14)
    local path = GUI_LEGACY_FONT_PATH
    if self.use_authored_gui_fonts then
        path = resolve_authored_gui_font(self, font_asset, family, face) or path
    end
    local key = path == GUI_LEGACY_FONT_PATH and size or (path .. "|" .. size)
    local cached = GUI_FONT_SIZE_CACHE[key]
    if cached then
        return cached
    end

    local file = path == GUI_LEGACY_FONT_PATH
        and require("engine/graphics/font_manager").resolve_path(path) or path
    local ok, font = false, nil
    if file then ok, font = pcall(love.graphics.newFont, file, size) end
    if (not ok or not font) and path ~= GUI_LEGACY_FONT_PATH then
        warn_gui_font(self, path, "could not be decoded: " .. tostring(font))
        local fallback = self:_get_surface_gui_font(size)
        GUI_FONT_SIZE_CACHE[key] = fallback
        return fallback
    end
    if not ok or not font then
        font = RBX._get_debug_font(size)
    end
    if font and font.setFilter then
        pcall(font.setFilter, font, "linear", "linear")
    end
    GUI_FONT_SIZE_CACHE[key] = font
    return font
end

-- TextScaled: biggest size (cap 100) that fits, unwrapped scales linearly from ref, wrapped binary-searches
local TEXT_SCALED_MAX = 100
local TEXT_SCALED_MIN = 6
local TEXT_SCALED_REF = 32

function RBX._fit_surface_gui_text_size(renderer, text, w, h, wrapped, font_asset, family, face)
    if w <= 0 or h <= 0 then
        return TEXT_SCALED_MIN
    end
    if not wrapped then
        local ref = renderer:_get_surface_gui_font(TEXT_SCALED_REF, font_asset, family, face)
        if not ref then
            return math.max(TEXT_SCALED_MIN, math.min(h * 0.68, w * 0.22))
        end
        local ref_w = math.max(1, ref:getWidth(text))
        local _,newlines=text:gsub("\n","")
        local ref_h = math.max(1,(newlines+1)*ref:getHeight())
        local size = math.min(
            TEXT_SCALED_REF * (w / ref_w),
            TEXT_SCALED_REF * (h / ref_h)
        )
        return clamp(math.floor(size), TEXT_SCALED_MIN, TEXT_SCALED_MAX)
    end
    local function measure_height(size)
        local font = renderer:_get_surface_gui_font(size, font_asset, family, face)
        if not font then return false end
        local _, lines = font:getWrap(text, w)
        return math.max(1, #lines) * font:getHeight() <= h, font, lines
    end
    local function fits_width(font, lines)
        -- getWrap can retain trailing spaces whose width exceeds w. its full
        -- width predicate has holes across font sizes, so do not binary-search it
        for i = 1, math.max(1, #lines) do
            if font:getWidth(lines[i]) > w then return false end
        end
        return true
    end
    local lo, hi = TEXT_SCALED_MIN, TEXT_SCALED_MAX
    local height_ok, best_font, best_lines = measure_height(lo)
    if not height_ok then return lo end
    -- Bound by wrapped height first, font height and wrapped line count grow
    -- with size. retain the selected measurement for the full-width check
    while lo < hi do
        local mid = math.floor((lo + hi + 1) * 0.5)
        local ok, font, lines = measure_height(mid)
        if ok then
            lo, best_font, best_lines = mid, font, lines
        else
            hi = mid - 1
        end
    end
    if fits_width(best_font, best_lines) then return lo end
    -- Descend across any width holes, preserving the original full-fit checks
    -- and minimum/cap instead of trimming spaces or accepting clipped words
    for size = lo - 1, TEXT_SCALED_MIN, -1 do
        local ok, font, lines = measure_height(size)
        if ok and fits_width(font, lines) then return size end
    end
    return TEXT_SCALED_MIN
end

local function intersect_clip_rect(a, b)
    if not a then
        return b
    end
    if not b then
        return a
    end

    local x1 = math.max(a.x, b.x)
    local y1 = math.max(a.y, b.y)
    local x2 = math.min(a.x + a.w, b.x + b.w)
    local y2 = math.min(a.y + a.h, b.y + b.h)
    if x2 <= x1 or y2 <= y1 then
        return { x = 0, y = 0, w = 0, h = 0 }
    end
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

local function apply_gui_clip(clip_rect)
    if not clip_rect then
        love.graphics.setScissor()
        return
    end

    love.graphics.setScissor(
        math.floor(clip_rect.x + 0.5),
        math.floor(clip_rect.y + 0.5),
        math.max(0, math.floor(clip_rect.w + 0.5)),
        math.max(0, math.floor(clip_rect.h + 0.5))
    )
end

local function resolve_gui_rect(parent_rect, node)
    local base_w, base_h = gui_size_scale_bases(node, parent_rect.w, parent_rect.h)
    local width = math.max(0, base_w * (node.size.x.scale or 0) + (node.size.x.offset or 0))
    local height = math.max(0, base_h * (node.size.y.scale or 0) + (node.size.y.offset or 0))
    local x = parent_rect.x + parent_rect.w * (node.position.x.scale or 0) + (node.position.x.offset or 0)
    local y = parent_rect.y + parent_rect.h * (node.position.y.scale or 0) + (node.position.y.offset or 0)
    local anchor = node.anchor or {}
    local anchor_x = width * ((anchor.x and anchor.x.scale) or 0) + ((anchor.x and anchor.x.offset) or 0)
    local anchor_y = height * ((anchor.y and anchor.y.scale) or 0) + ((anchor.y and anchor.y.offset) or 0)
    x = x - anchor_x
    y = y - anchor_y

    return {
        x = x,
        y = y,
        w = width,
        h = height,
        ax = anchor_x,
        ay = anchor_y,
    }
end

local function is_text_gui(node)
    return node and(node.class_name=='TextLabel'or node.class_name=='TextButton'or node.class_name=='TextBox')
end
local function stroke_admitted(stroke)
    return stroke.class_name=='UIStroke'and stroke.enabled~=false and(stroke.stroke_transparency or 0)<1
        and(stroke.stroke_thickness or 1)>0
end
function RBX._gui_has_contextual_stroke(node)
    if not is_text_gui(node)then return false end
    for _,stroke in ipairs(node.children or{})do
        if stroke_admitted(stroke)and stroke.stroke_apply_mode~='Border'then return true end
    end
    return false
end
function RBX._draw_gui_contextual_strokes(node,draw_text,x,y)
    if not is_text_gui(node)then return end
    for _,stroke in ipairs(node.children or{})do
        if stroke_admitted(stroke)and stroke.stroke_apply_mode~='Border'then
            local color=stroke.stroke_color or{r=0,g=0,b=0};local thickness=stroke.stroke_thickness or 1
            love.graphics.setColor(color.r,color.g,color.b,1-(stroke.stroke_transparency or 0))
            for _,offset in ipairs(SURFACE_GUI_TEXT_STROKE_OFFSETS)do draw_text(x+offset[1]*thickness,y+offset[2]*thickness)end
        end
    end
end
function RBX._draw_gui_border_strokes(node,w,h)
    for _,stroke in ipairs(node and node.children or{})do
        if stroke_admitted(stroke)and(not is_text_gui(node)or stroke.stroke_apply_mode=='Border')then
            local color=stroke.stroke_color or{r=0,g=0,b=0}
            local old_width=love.graphics.getLineWidth()
            love.graphics.setColor(color.r,color.g,color.b,1-(stroke.stroke_transparency or 0))
            love.graphics.setLineWidth(stroke.stroke_thickness or 1)
            love.graphics.rectangle('line',0,0,w,h)
            love.graphics.setLineWidth(old_width)
        end
    end
end

local function draw_gui_text(renderer, node, rect)
    local text = tostring(node.text or "")
    if text == "" or rect.w <= 0 or rect.h <= 0 then
        return
    end

    local desired_size = node.text_scaled
        and RBX._fit_surface_gui_text_size(renderer, text, rect.w, rect.h, node.text_wrapped == true,
            node.font_asset, node.font, node.font_face)
        or node.text_size or 14
    local font = renderer:_get_surface_gui_font(desired_size, node.font_asset, node.font, node.font_face)
    if not font then
        return
    end

    local alpha = clamp(1 - (node.text_transparency or 0), 0, 1)
    if alpha <= 0 and not RBX._gui_has_contextual_stroke(node)then
        return
    end

    local available_width = math.max(1, rect.w - SURFACE_GUI_TEXT_PADDING * 2)
    local wrapped = node.text_wrapped == true
    local wrapped_lines = nil
    if wrapped then
        _, wrapped_lines = font:getWrap(text, available_width)
    else
        wrapped_lines = { text }
    end
    local _,newlines=text:gsub("\n","")
    local text_height=math.max(font:getHeight(),(wrapped and #wrapped_lines or newlines+1)*font:getHeight())
    local text_y = SURFACE_GUI_TEXT_PADDING
    if node.text_y_alignment == "center" then
        text_y = (rect.h - text_height) * 0.5
    elseif node.text_y_alignment == "bottom" then
        text_y = rect.h - text_height - SURFACE_GUI_TEXT_PADDING
    end

    love.graphics.setFont(font)
    local align = node.text_x_alignment or "center"
    local text_x = SURFACE_GUI_TEXT_PADDING
    local text_width = font:getWidth(text)
    if align == "center" then
        text_x = (rect.w - text_width) * 0.5
    elseif align == "right" then
        text_x = rect.w - text_width - SURFACE_GUI_TEXT_PADDING
    end

    local function draw_text_block(draw_x, draw_y)
        if wrapped then
            love.graphics.printf(text, draw_x, draw_y, available_width, align)
        else
            love.graphics.print(text, draw_x, draw_y)
        end
    end

    local stroke_alpha = clamp(1 - (node.text_stroke_transparency or 1), 0, 1) * alpha
    if stroke_alpha > 0 then
        local stroke_color = node.text_stroke_color or { r = 0, g = 0, b = 0 }
        love.graphics.setColor(stroke_color.r, stroke_color.g, stroke_color.b, stroke_alpha)
        local base_x = wrapped and SURFACE_GUI_TEXT_PADDING or text_x
        for index = 1, #SURFACE_GUI_TEXT_STROKE_OFFSETS do
            local offset = SURFACE_GUI_TEXT_STROKE_OFFSETS[index]
            draw_text_block(base_x + offset[1], text_y + offset[2])
        end
    end

    RBX._draw_gui_contextual_strokes(node,draw_text_block,wrapped and SURFACE_GUI_TEXT_PADDING or text_x,text_y)
    love.graphics.setColor(node.text_color.r, node.text_color.g, node.text_color.b, alpha)
    draw_text_block(wrapped and SURFACE_GUI_TEXT_PADDING or text_x, text_y)
end

local function refresh_remote_legacy_gui_image(
    renderer, node, texture, resource_key, handle, record)
    if node.image ~= record.expected_asset_path then return true end
    rawset(node, "_remote_texture_handle", handle)
    rawset(node, "_remote_texture_asset_path", record.expected_asset_path)
    rawset(node, "_remote_texture_texture", texture)
    rawset(node, "_remote_texture_resource_key", resource_key)
    local owner = rawget(node, "_surface_gui_owner")
    if owner then
        mark_surface_gui_dirty(owner, "content")
        local state = owner._runtime_state
        if type(state) == "table" then state.rendered = false end
    end

    return true
end

-- GuiObject hierarchy edits under an existing canvas publish before hierarchy
-- signals. Storage templates remain passive until attached to a bound GUI
local dynamic_gui_sequence = 0
local function gui_root_source(instance,by_referent,prefix,sequence)
    sequence=sequence or{value=0};sequence.value=sequence.value+1
    local referent=prefix..sequence.value
    local source={ClassName=rawget(instance,'_class_name'),Name=instance.Name,Referent=referent,Children={}}
    for key,value in pairs(rawget(instance,'_properties')or{})do source[key]=value end
    by_referent[referent]=instance
    for i,child in ipairs(rawget(instance,'_children')or{})do source.Children[i]=gui_root_source(child,by_referent,prefix,sequence)end
    return source
end
local function gui_part(instance)
    if type(instance)~='table'then return nil end
    local part=rawget(instance,'_core_handle')
    return part and not part._destroyed and part or nil
end
local function gui_root_parent_admitted(parent)
    if gui_part(parent)then return true end
    while parent do
        local service=rawget(parent,'_service_name');local class=rawget(parent,'_class_name')
        if service=='Workspace'or class=='PlayerGui'then return true end
        if service=='ReplicatedFirst'or service=='ReplicatedStorage'or service=='StarterGui'or service=='ServerStorage'then return false end
        parent=rawget(parent,'_parent')
    end
    return false
end
-- Binding an imported or cloned descriptor does not necessarily change its
-- carrier. Observe the GUI's own destruction once at either binding boundary
function RBX._observe_surface_gui_lifetime(instance,gui)
    if not (SURFACE_GUI_CLASSES[rawget(instance,'_class_name')] or BILLBOARD_GUI_CLASSES[rawget(instance,'_class_name')])or not gui then return false end
    if rawget(instance,'_surface_gui_destroy_connection')then return true end
    if not instance.Destroying then return false end
    rawset(instance,'_surface_gui_destroy_connection',instance.Destroying:Connect(function()
        local owned=rawget(instance,'_gui_node')or gui
        RBX._rebind_surface_gui(instance,rawget(instance,'_parent'),nil)
        local state=rawget(owned,'_runtime_state')
        if state then
            release_gui_resource(state.canvas);state.canvas=nil;state.last_bound_texture=nil
        end
        local bridge=rawget(owned,'_bridge_root')
        if bridge then bridge:remove();rawset(owned,'_bridge_root',nil)end
        local data=rawget(owned,'_surface_gui_data')or owned
        data.texture=nil;data.texture_object=nil;data.texture_key=nil
        rawset(instance,'_surface_gui_destroy_connection',nil)
    end))
    return true
end
-- SurfaceGui ownership changes are rare hierarchy/property events. Descriptor
-- identity and cached canvas remain owned by the GUI, only the carrier changes
-- this never scans the world or polls Adornee each presentation frame
function RBX._rebind_surface_gui(instance,old_parent,new_parent,adornee,has_override)
    local billboard=BILLBOARD_GUI_CLASSES[rawget(instance,'_class_name')]
    if not (SURFACE_GUI_CLASSES[rawget(instance,'_class_name')]or billboard)then return false end
    local field=billboard and 'BillboardGuis'or 'SurfaceGuis'
    local function carrier(node)
        while billboard and type(node)=='table' and node.ClassName=='Attachment'do node=node.Parent end
        return gui_part(node)
    end
    if new_parent and rawget(new_parent,'_suppress_face_texture_dirty')then return false end
    local datamodel=rawget(instance,'_datamodel');local core=datamodel and rawget(datamodel,'_core')
    if not core then return false end
    local gui=rawget(instance,'_gui_node');local old_part=gui and rawget(gui,'_surface_gui_part_owner')
    if not old_part and gui then
        for _,parent in pairs({old=old_parent,new=new_parent})do
            local part=carrier(parent)
            if part then for _,entry in ipairs(part[field] or{})do if entry==gui then old_part=part;break end end end
            if old_part then break end
        end
    end
    if not has_override then adornee=(rawget(instance,'_properties')or{}).Adornee end
    local target
    if gui_root_parent_admitted(new_parent)then
        -- parsed Ref=-1 is the serialized null reference. Embedding adapters
        -- can publish the remaining refs later, a number is never a facade
        if adornee~=nil and adornee~=-1 then target=carrier(adornee)else target=carrier(new_parent)end
    end
    if not gui and target then
        dynamic_gui_sequence=dynamic_gui_sequence+1
        local by_referent={};local source=gui_root_source(instance,by_referent,'runtime_root|'..dynamic_gui_sequence..'|')
        if has_override then source.Adornee=adornee end
        local parse=billboard and RBX._parse_billboard_gui_instance or RBX._parse_surface_gui_instance
        gui=wrap_surface_gui_runtime(parse(source,target._id,dynamic_gui_sequence))
        RBX._bind_cloned_gui_nodes({gui},by_referent)
    end
    if not gui then return false end
    RBX._observe_surface_gui_lifetime(instance,gui)
    if has_override then gui.adornee=adornee end
    -- new runtime SurfaceGui carriers own mutable overlays that cannot be
    -- released from an untracked static bake. choose the existing retained
    -- geometry route before first publication, so later poses update only
    -- this carrier. Authored loaded-map statics keep their existing ownership
    if target and not billboard and not target._loaded_from_map
        and not target._scene_chunk_key and core._retain_dynamic_part_geometry then
        core:_retain_dynamic_part_geometry(target)
    end
    if old_part==target then rawset(gui,'_surface_gui_part_owner',target);return true end
    if old_part then
        for i=#(old_part[field] or{}),1,-1 do if old_part[field][i]==gui then table.remove(old_part[field],i)end end
        if not billboard then core:_mark_runtime_part_face_textures_dirty(old_part)end
    end
    if target then
        target[field]=target[field] or{};target[field][#target[field]+1]=gui
        if not billboard then core:_mark_runtime_part_face_textures_dirty(target)end
    end
    rawset(gui,'_surface_gui_part_owner',target)
    -- existing runtime GUI enumeration is rebuilt at this rare membership
    -- boundary, steady content writes continue to invalidate only the canvas
    mark_parts_dirty(core)
    return true
end
function RBX._gui_root_facade_write(instance,key,value)
    if key~='Adornee'or not (SURFACE_GUI_CLASSES[rawget(instance,'_class_name')]or BILLBOARD_GUI_CLASSES[rawget(instance,'_class_name')])then return false end
    local parent=rawget(instance,'_parent')
    return RBX._rebind_surface_gui(instance,parent,parent,value,true)
end
function RBX._reparent_gui_node(instance, old_parent, new_parent)
    if SURFACE_GUI_CLASSES[rawget(instance,'_class_name')]or BILLBOARD_GUI_CLASSES[rawget(instance,'_class_name')]then
        RBX._rebind_surface_gui(instance,old_parent,new_parent);return
    end
    if not SURFACE_GUI_NODE_CLASSES[rawget(instance, "_class_name")] then return end
    local old_node = rawget(instance, "_gui_node")
    local old_parent_node = old_parent and rawget(old_parent, "_gui_node")
    if old_node and old_parent_node then
        local siblings = old_parent_node.nodes or old_parent_node.children or {}
        for index = #siblings, 1, -1 do
            if siblings[index] == old_node then table.remove(siblings, index); break end
        end
        local owner = rawget(old_node, "_surface_gui_owner")
        if RBX._gui_bridge_detach_node then RBX._gui_bridge_detach_node(old_node) end
        mark_surface_gui_dirty(owner, "content")
    end
    local function clear(node)
        rawset(node, "_gui_node", nil); rawset(node, "_gui_element", nil)
        for _, child in ipairs(rawget(node, "_children") or {}) do clear(child) end
    end
    clear(instance)
    local parent_node = new_parent and rawget(new_parent, "_gui_node")
    local owner = parent_node and (rawget(parent_node, "_surface_gui_owner")
        or (rawget(parent_node, "_surface_gui_proxy_kind") == "surface_gui" and parent_node))
    if not owner then return end
    dynamic_gui_sequence = dynamic_gui_sequence + 1
    local prefix = "runtime_gui|" .. dynamic_gui_sequence .. "|"
    local by_referent, sequence = {}, 0
    local function source(node)
        sequence = sequence + 1
        local referent = prefix .. sequence
        local result = {}
        for key, value in pairs(rawget(node, "_properties") or {}) do result[key] = value end
        result.Name, result.ClassName, result.Referent = node.Name, node.ClassName, referent
        result.Children = {}; by_referent[referent] = node
        for index, child in ipairs(rawget(node, "_children") or {}) do result.Children[index] = source(child) end
        return result
    end
    local siblings = parent_node.nodes or parent_node.children
    local order = 0
    for _, sibling in ipairs(siblings) do order = math.max(order, sibling.order or 0) end
    local parsed = normalize_gui_node(source(instance), order + 1)
    if parsed and parsed.layout_constraint then
        local constraints = parent_node.layout_constraints or {}
        constraints[#constraints + 1] = parsed
        parent_node.layout_constraints = constraints
        mark_surface_gui_dirty(owner, "content")
        return
    end
    local node = wrap_surface_gui_node(parsed, owner)
    siblings[#siblings + 1] = node
    table.sort(siblings, function(a, b)
        if a.zindex ~= b.zindex then return a.zindex < b.zindex end
        return a.order < b.order
    end)
    if RBX._gui_bridge_attach_node then
        RBX._gui_bridge_attach_node(rawget(instance, "_core"), owner, parent_node, node)
    end
    local function bind(gui_node)
        local facade = by_referent[gui_node.referent]
        if facade then
            rawset(facade, "_gui_node", gui_node)
            rawset(facade, "_gui_element", rawget(gui_node, "_bridge_element"))
        end
        for _, child in ipairs(gui_node.children or {}) do bind(child) end
    end
    bind(node)
    mark_surface_gui_dirty(owner, "content")
end
RBX._refresh_remote_legacy_gui_image =
    refresh_remote_legacy_gui_image

RBX._draw_gui_image_content = runtime_require("gui_image.lua").draw
local function draw_gui_image(renderer, node, rect)
    if type(node.image) ~= "string" or node.image == "" or rect.w <= 0 or rect.h <= 0 then
        return
    end

    local handle = rawget(node, "_remote_texture_handle")
    local texture, texture_key
    if handle and rawget(node, "_remote_texture_asset_path") == node.image then
        texture = handle.texture or rawget(node, "_remote_texture_texture")
        texture_key = handle.resource_key
            or rawget(node, "_remote_texture_resource_key")
    else
        texture, texture_key, handle = renderer:_get_or_load_texture(node.image, {
            wrap_mode = "clamp",
            remote_pending_placeholder = "transparent",
            defer_remote_gpu_upload = true,
        })
        if handle then
            rawset(node, "_remote_texture_handle", handle)
            rawset(node, "_remote_texture_asset_path", node.image)
            renderer:_bind_remote_texture_consumer(handle, node, {
                role = "legacy_gui_image",
                scene_bound = false,
                revision_field = false,
                expected_asset_path = node.image,
                callback = refresh_remote_legacy_gui_image,
            })
        end
    end
    if not texture or texture_key == "__white" then
        return
    end

    local alpha = clamp(1 - (node.image_transparency or 0), 0, 1)
    if alpha <= 0 then
        return
    end

    local width = texture:getWidth()
    local height = texture:getHeight()
    if width <= 0 or height <= 0 then
        return
    end

    love.graphics.setColor(node.image_color.r, node.image_color.g, node.image_color.b, alpha)
    RBX._draw_gui_image_content(node, texture, rect.w, rect.h)
end

local function draw_gui_node(renderer, node, parent_rect, inherited_clip)
    if type(node) ~= "table" or node.visible == false or node.class_name=='UIStroke'then
        return
    end

    local rect = resolve_gui_rect(parent_rect, node)
    if rect.w <= 0 or rect.h <= 0 then
        return
    end

    local clip_rect = inherited_clip
    if node.clips_descendants then
        clip_rect = intersect_clip_rect(clip_rect, rect)
    end

    love.graphics.push("all")
    apply_gui_clip(clip_rect)
    love.graphics.translate(rect.x + rect.w*.5, rect.y + rect.h*.5)
    if node.rotation and node.rotation ~= 0 then
        love.graphics.rotate(math.rad(node.rotation))
    end
    love.graphics.translate(-rect.w*.5, -rect.h*.5)

    local background_alpha = clamp(1 - (node.background_transparency or 0), 0, 1)
    if background_alpha > 0 then
        love.graphics.setColor(
            node.background_color.r,
            node.background_color.g,
            node.background_color.b,
            background_alpha
        )
        love.graphics.rectangle("fill", 0, 0, rect.w, rect.h)
    end

    draw_gui_image(renderer, node, rect)
    draw_gui_text(renderer, node, rect)
    RBX._draw_gui_border_strokes(node,rect.w,rect.h)

    local border_size = math.max(0, tonumber(node.border_size) or 0)
    if border_size > 0 and background_alpha > 0 then
        -- borders sit outside the gui rect
        love.graphics.setColor(node.border_color.r, node.border_color.g, node.border_color.b, background_alpha)
        love.graphics.setLineWidth(border_size)
        love.graphics.rectangle("line", -border_size * 0.5, -border_size * 0.5,
            rect.w + border_size, rect.h + border_size)
    end

    love.graphics.pop()

    for index = 1, #(node.children or {}) do
        draw_gui_node(renderer, node.children[index], rect, clip_rect)
    end
end

function RBX:_render_surface_gui_to_canvas(surface_gui, part, canvas)
    if not canvas then
        return
    end

    local previous_canvas = love.graphics.getCanvas()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    -- SurfaceGui textures have a documented premultiplied storage contract
    -- do not inherit a 3D pass shader/blend mode from the call site: GUI
    -- primitives and images enter this canvas as straight-alpha sources
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.setDepthMode()
    love.graphics.setStencilTest()
    love.graphics.setScissor()
    if love.graphics.setMeshCullMode then love.graphics.setMeshCullMode('none')end
    love.graphics.setColor(1, 1, 1, 1)

    local raster=surface_gui._runtime_state and surface_gui._runtime_state.raster_bounds
    local root_rect = {
        x = 0,
        y = 0,
        w = raster and raster.logical_w or canvas:getWidth(),
        h = raster and raster.logical_h or canvas:getHeight(),
    }
    local prior_mapping=rawget(Element,'_clip_coordinate_transform')
    if raster and(raster.x~=0 or raster.y~=0)then
        local mapping=love.math.newTransform(-raster.x,-raster.y)
        love.graphics.applyTransform(mapping)
        rawset(Element,'_clip_coordinate_transform',mapping)
    end

    -- false = fall back to the legacy node loop
    local bridge_drawn = RBX._gui_bridge_draw_canvas
        and RBX._gui_bridge_draw_canvas(self, surface_gui, root_rect.w, root_rect.h)
    if not bridge_drawn then
        local root_clip = surface_gui and surface_gui.clips_descendants and {
            x = 0,
            y = 0,
            w = root_rect.w,
            h = root_rect.h,
        } or nil

        for index = 1, #((surface_gui and surface_gui.nodes) or {}) do
            draw_gui_node(self, surface_gui.nodes[index], root_rect, root_clip)
        end
    end

    rawset(Element,'_clip_coordinate_transform',prior_mapping)
    if previous_canvas then
        love.graphics.setCanvas(previous_canvas)
    else
        love.graphics.setCanvas()
    end
    love.graphics.pop()
end

-- publish renderer outputs through the existing read backing store, rather
-- than treating internal cache binding as an authored input write. explicit
-- writes through the public proxy still follow its ordinary dirty/version trap
local function publish_surface_gui_runtime_texture(surface_gui, texture, texture_key)
    local data = rawget(surface_gui, "_surface_gui_data")
    if rawget(surface_gui, "_surface_gui_proxy_kind") == "surface_gui" and type(data) == "table" then
        data.texture_object = texture
        data.texture_key = texture_key
    else
        surface_gui.texture_object = texture
        surface_gui.texture_key = texture_key
    end
end

function RBX:_ensure_surface_gui_runtime_texture(surface_gui, part)
    if type(surface_gui) ~= "table" then
        return nil, nil, false
    end

    local state = surface_gui._runtime_state or {}
    local frame_id = self._surface_gui_frame_id or 0
    local validation_interval = get_surface_gui_validation_interval(self)
    local texture_key = get_surface_gui_texture_key(surface_gui)
    local redrawn = false
    local canvas = state.canvas
    local event_wrapped = surface_gui and rawget(surface_gui, "_surface_gui_event_wrapped") == true
    local event_dirty = event_wrapped
        and (rawget(surface_gui, "_content_dirty") == true or rawget(surface_gui, "_layout_dirty") == true)
    if canvas and state.rendered == true and type(state.next_validation_frame) == "number" and
        not event_dirty and
        frame_id < state.next_validation_frame then
        self:_note_load_cache_stat("surfacegui_cache_hits")
        state.last_bound_texture = state.last_bound_texture or canvas
        surface_gui._runtime_state = state
        publish_surface_gui_runtime_texture(surface_gui, canvas, texture_key)
        return canvas, texture_key, false
    end

    local width, height = RBX._get_surface_gui_canvas_size(surface_gui, part)
    surface_gui._runtime_state=state
    state.raster_bounds=RBX._gui_bridge_canvas_bounds and RBX._gui_bridge_canvas_bounds(self,surface_gui,width,height)
        or {x=0,y=0,w=width,h=height,logical_w=width,logical_h=height}
    local raster=state.raster_bounds
    local layout_signature = self:_get_surface_gui_layout_signature(surface_gui, part)
    local descriptor_signature = self:_get_surface_gui_descriptor_signature(surface_gui, part)
    if not canvas or canvas:getWidth() ~= raster.w or canvas:getHeight() ~= raster.h then
        self:_note_load_cache_stat("surfacegui_cache_misses")
        local canvas_start = love.timer.getTime()
        local previous_canvas = canvas
        canvas = love.graphics.newCanvas(raster.w, raster.h)
        self:_add_load_stage_time("surfacegui_canvas_creation", love.timer.getTime() - canvas_start)
        if canvas and canvas.setFilter then
            canvas:setFilter("linear", "linear")
        end
        state.canvas = canvas
        state.last_bound_texture = canvas
        state.layout_signature = nil
        if previous_canvas ~= canvas then
            release_gui_resource(previous_canvas)
        end
    end
    local content_signature
    if event_wrapped then
        local nodes = surface_gui and surface_gui.nodes or {}
        content_signature = self:_get_surface_gui_content_signature(surface_gui)
        state.content_signature_nodes = nodes
        state.content_signature_node_count = #nodes
        state.next_content_signature_frame = nil
    else
        local nodes = surface_gui and surface_gui.nodes or {}
        content_signature = state.content_signature
        if should_refresh_surface_gui_content_signature(surface_gui, state, frame_id) then
            content_signature = self:_get_surface_gui_content_signature(surface_gui)
            state.content_signature = content_signature
            state.content_signature_nodes = nodes
            state.content_signature_node_count = #nodes
            state.next_content_signature_frame = frame_id + SURFACE_GUI_CONTENT_RESCAN_INTERVAL_FRAMES
            if surface_gui then
                surface_gui._content_dirty = nil
            end
        end
    end
    if state.descriptor_signature and state.descriptor_signature ~= descriptor_signature then
        self._parts_dirty = true
    end
    local needs_redraw = canvas ~= nil and (
        state.layout_signature ~= layout_signature
        or state.content_signature ~= content_signature
        or state.rendered ~= true
    )

    state.layout_signature = layout_signature
    state.descriptor_signature = descriptor_signature
    state.content_signature = content_signature
    state.next_validation_frame = get_surface_gui_next_validation_frame(surface_gui, state, frame_id, validation_interval)
    state.last_bound_texture = state.last_bound_texture or canvas or self._transparent_texture or self._white_texture
    surface_gui._runtime_state = state
    publish_surface_gui_runtime_texture(surface_gui, canvas, texture_key)

    if needs_redraw then
        local bridge_before = rawget(surface_gui, "_bridge_root")
        local layout_start = love.timer.getTime()
        self:_render_surface_gui_to_canvas(surface_gui, part, canvas)
        self:_add_load_stage_time("surfacegui_layout_build", love.timer.getTime() - layout_start)
        if bridge_before == nil and rawget(surface_gui, "_bridge_root") ~= nil
            and rawget(surface_gui, "_surface_gui_event_wrapped") == true then
            -- Lazy Element construction imports every current input before drawing
            -- and marks their owner dirty. cache the inputs actually rendered,
            -- rather than the pre-import version that would force a second bake
            local nodes = surface_gui.nodes or {}
            state.layout_signature = self:_get_surface_gui_layout_signature(surface_gui, part)
            state.descriptor_signature = self:_get_surface_gui_descriptor_signature(surface_gui, part)
            state.content_signature = self:_get_surface_gui_content_signature(surface_gui)
            state.content_signature_nodes = nodes
            state.content_signature_node_count = #nodes
            state.next_content_signature_frame = nil
        end
        state.rendered = true
        state.last_bound_texture = canvas or self._transparent_texture or self._white_texture
        if event_wrapped then
            rawset(surface_gui, "_content_dirty", false)
            rawset(surface_gui, "_layout_dirty", false)
        end
        redrawn = true
    else
        self:_note_load_cache_stat("surfacegui_cache_hits")
    end

    return canvas, texture_key, redrawn
end

function RBX:_preload_surface_gui_canvases()
    local entries = self._surface_gui_entries or {}
    local entry_count = #entries
    if entry_count <= 0 then
        self._surface_gui_stats = self._surface_gui_stats or {}
        self._surface_gui_stats.preloaded_batch_count = 0
        return 0
    end

    local budget = math.max(0, math.floor(tonumber(self.surface_gui_background_preload_budget_per_update) or
        get_surface_gui_budget(self, "background", SURFACE_GUI_BACKGROUND_PRELOAD_BUDGET)))
    if budget <= 0 then
        self._surface_gui_stats = self._surface_gui_stats or {}
        self._surface_gui_stats.preloaded_batch_count = 0
        return 0
    end

    local cursor = self._surface_gui_preload_cursor or 0
    local updated_count = 0
    local processed = 0
    while processed < budget and processed < entry_count do
        cursor = (cursor % entry_count) + 1
        local entry = entries[cursor]
        local surface_gui = entry and entry.surface_gui
        local part = entry and entry.part
        -- no {} fallback: it leaked a table/frame forever, guards below handle nil
        local state = type(surface_gui) == "table" and surface_gui._runtime_state or nil
        if type(surface_gui) == "table"
            and type(part) == "table"
            and not part._destroyed
            and surface_gui.enabled ~= false
            and not (state and state.visible_recently == true)
            and (not state or state.rendered ~= true or not state.canvas) then
            local _, _, redrawn = self:_ensure_surface_gui_runtime_texture(surface_gui, part)
            if redrawn then
                updated_count = updated_count + 1
            end
        end
        processed = processed + 1
    end

    self._surface_gui_preload_cursor = cursor
    self._surface_gui_stats = self._surface_gui_stats or {}
    self._surface_gui_stats.preloaded_batch_count = updated_count
    return updated_count
end

local function get_surface_gui_face_center_offset(part, face_name)
    local size = type(part) == "table" and part.Size or nil
    local sx = math.abs(tonumber(size and size.x) or 4)
    local sy = math.abs(tonumber(size and size.y) or 1)
    local sz = math.abs(tonumber(size and size.z) or 2)
    local axis = SURFACE_GUI_FACE_AXES[face_name] or SURFACE_GUI_FACE_AXES.Front

    if math.abs(axis.nx) > 0 then
        return axis.nx * sx * 0.5, 0, 0
    end
    if math.abs(axis.ny) > 0 then
        return 0, axis.ny * sy * 0.5, 0
    end

    return 0, 0, axis.nz * sz * 0.5
end

function RBX:_surface_gui_should_render(surface_gui, part)
    if type(surface_gui) ~= "table" or type(part) ~= "table" or part._destroyed then
        return false
    end
    local state = surface_gui._runtime_state or {}
    local frame_id = self._surface_gui_frame_id or 0
    if state.visibility_frame == frame_id then
        return state.visibility_result == true
    end
    if surface_gui.enabled == false then
        state.visibility_frame = frame_id
        state.visibility_result = false
        surface_gui._runtime_state = state
        return false
    end
    if not (type(self) == "table" and type(self.camera) == "table" and self.camera.cframe) then
        state.visibility_frame = frame_id
        state.visibility_result = true
        surface_gui._runtime_state = state
        return true
    end

    local camera = self.camera.cframe
    local max_distance = tonumber(surface_gui.max_distance) or 0
    if max_distance > 0 then
        local dx = (part.CFrame.x or 0) - (camera.x or 0)
        local dy = (part.CFrame.y or 0) - (camera.y or 0)
        local dz = (part.CFrame.z or 0) - (camera.z or 0)
        if (dx * dx + dy * dy + dz * dz) > (max_distance * max_distance) then
            state.visibility_frame = frame_id
            state.visibility_result = false
            surface_gui._runtime_state = state
            return false
        end
    end

    local face_name = surface_gui.face or "Front"
    local cframe = part.CFrame or {}
    local size = part.Size or {}
    local blockmesh_scale = part.BlockMeshScale or {}
    -- compare by value: CFrame/Size tables get recreated per move, identity compare = miss every frame
    if state.cached_face_name ~= face_name
        or state.cached_cf_x ~= cframe.x or state.cached_cf_y ~= cframe.y or state.cached_cf_z ~= cframe.z
        or state.cached_cf_r00 ~= cframe.r00 or state.cached_cf_r01 ~= cframe.r01 or state.cached_cf_r02 ~= cframe.r02
        or state.cached_cf_r10 ~= cframe.r10 or state.cached_cf_r11 ~= cframe.r11 or state.cached_cf_r12 ~= cframe.r12
        or state.cached_cf_r20 ~= cframe.r20 or state.cached_cf_r21 ~= cframe.r21 or state.cached_cf_r22 ~= cframe.r22
        or state.cached_size_x ~= size.x or state.cached_size_y ~= size.y or state.cached_size_z ~= size.z
        or state.cached_bms_x ~= blockmesh_scale.x
        or state.cached_bms_y ~= blockmesh_scale.y
        or state.cached_bms_z ~= blockmesh_scale.z
        or state.face_world_x == nil
        or state.face_normal_x == nil then
        local axis = SURFACE_GUI_FACE_AXES[face_name] or SURFACE_GUI_FACE_AXES.Front
        local px, py, pz,
        rx, ry, rz,
        ux, uy, uz,
        bx, by, bz = get_runtime_part_render_basis(part)
        local local_x, local_y, local_z = get_surface_gui_face_center_offset(part, face_name)
        state.face_world_x, state.face_world_y, state.face_world_z = transform_local_point(
            px, py, pz,
            rx, ry, rz,
            ux, uy, uz,
            bx, by, bz,
            local_x, local_y, local_z
        )
        state.face_normal_x, state.face_normal_y, state.face_normal_z = transform_local_normal(
            rx, ry, rz,
            ux, uy, uz,
            bx, by, bz,
            axis.nx, axis.ny, axis.nz
        )
        state.cached_face_name = face_name
        state.cached_cf_x, state.cached_cf_y, state.cached_cf_z = cframe.x, cframe.y, cframe.z
        state.cached_cf_r00, state.cached_cf_r01, state.cached_cf_r02 = cframe.r00, cframe.r01, cframe.r02
        state.cached_cf_r10, state.cached_cf_r11, state.cached_cf_r12 = cframe.r10, cframe.r11, cframe.r12
        state.cached_cf_r20, state.cached_cf_r21, state.cached_cf_r22 = cframe.r20, cframe.r21, cframe.r22
        state.cached_size_x, state.cached_size_y, state.cached_size_z = size.x, size.y, size.z
        state.cached_bms_x, state.cached_bms_y, state.cached_bms_z =
            blockmesh_scale.x, blockmesh_scale.y, blockmesh_scale.z
    end

    local to_camera_x = (camera.x or 0) - (state.face_world_x or 0)
    local to_camera_y = (camera.y or 0) - (state.face_world_y or 0)
    local to_camera_z = (camera.z or 0) - (state.face_world_z or 0)
    local visible = dot(
        state.face_normal_x or 0,
        state.face_normal_y or 0,
        state.face_normal_z or 0,
        to_camera_x,
        to_camera_y,
        to_camera_z
    ) > 1e-4
    state.visibility_frame = frame_id
    state.visibility_result = visible
    surface_gui._runtime_state = state
    return visible
end

-- cull-reason counters, snapshotted+zeroed each frame for get_stats
local function note_sgui_cull(renderer, reason)
    local counters = renderer._sgui_cull_counters
    if not counters then
        counters = { disabled = 0, distance = 0, screen_size = 0, backface = 0, passed = 0 }
        renderer._sgui_cull_counters = counters
    end
    counters[reason] = (counters[reason] or 0) + 1
end

function RBX:_surface_gui_batch_is_visible(batch)
    if type(batch) ~= "table" or batch.source_kind ~= "SurfaceGui" then
        return true
    end
    local surface_gui = batch.surface_gui_ref
    if type(surface_gui) == "table" and surface_gui.enabled == false then
        note_sgui_cull(self, "disabled")
        return false
    end
    local camera = type(self) == "table" and type(self.camera) == "table" and self.camera.cframe or nil
    if camera and batch.surface_gui_face_world_x ~= nil and batch.surface_gui_face_normal_x ~= nil then
        local max_distance = batch.surface_gui_max_distance or tonumber(surface_gui and surface_gui.max_distance) or 0
        if max_distance > 0 then
            local dx = batch.surface_gui_face_world_x - (camera.x or 0)
            local dy = batch.surface_gui_face_world_y - (camera.y or 0)
            local dz = batch.surface_gui_face_world_z - (camera.z or 0)
            if (dx * dx + dy * dy + dz * dz) > (max_distance * max_distance) then
                note_sgui_cull(self, "distance")
                return false
            end
        end
        local min_projected_pixels = tonumber(self.surface_gui_min_projected_pixels) or 0
        local bounds = batch.bounds
        if min_projected_pixels > 0 and type(bounds) == "table" then
            local dx = (bounds.center_x or batch.surface_gui_face_world_x or 0) - (camera.x or 0)
            local dy = (bounds.center_y or batch.surface_gui_face_world_y or 0) - (camera.y or 0)
            local dz = (bounds.center_z or batch.surface_gui_face_world_z or 0) - (camera.z or 0)
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if distance > 1e-3 then
                local radius = math.max(
                    math.abs((bounds.max_x or 0) - (bounds.min_x or 0)),
                    math.abs((bounds.max_y or 0) - (bounds.min_y or 0)),
                    math.abs((bounds.max_z or 0) - (bounds.min_z or 0))
                ) * 0.5
                local fov = self.camera and self.camera.fov or math.rad(70)
                local target_height = self._last_render_target_height or self._last_height or love.graphics.getHeight()
                local projected_pixels = (radius / distance) * (target_height / math.max(1e-3, math.tan(fov * 0.5)))
                if projected_pixels < min_projected_pixels then
                    note_sgui_cull(self, "screen_size")
                    return false
                end
            end
        end
        local facing = dot(
            batch.surface_gui_face_normal_x or 0,
            batch.surface_gui_face_normal_y or 0,
            batch.surface_gui_face_normal_z or 0,
            (camera.x or 0) - (batch.surface_gui_face_world_x or 0),
            (camera.y or 0) - (batch.surface_gui_face_world_y or 0),
            (camera.z or 0) - (batch.surface_gui_face_world_z or 0)
        ) > 1e-4
        note_sgui_cull(self, facing and "passed" or "backface")
        return facing
    end
    return self:_surface_gui_should_render(surface_gui, batch.surface_gui_part_ref)
end

function RBX:_set_surface_gui_batch_texture(batch, texture)
    if type(batch) ~= "table" or not batch.mesh or not batch.mesh.setTexture then
        return
    end
    local resolved_texture = texture or self._transparent_texture or self._white_texture
    if batch.texture ~= resolved_texture then
        batch.texture = resolved_texture
        batch.mesh:setTexture(resolved_texture)
    end
end

function RBX:_update_surface_gui_canvases(surface_gui_batches)
    -- snapshot+reset cull counters, this fn runs once/frame
    do
        -- only overwrite when a pass actually ran, else stats show 0 on cache hits
        local counters = self._sgui_cull_counters
        if counters then
            local evaluated = (counters.disabled or 0) + (counters.distance or 0)
                + (counters.screen_size or 0) + (counters.backface or 0)
                + (counters.passed or 0)
            if evaluated > 0 then
                local snapshot = self._sgui_cull_last or {}
                snapshot.disabled = counters.disabled or 0
                snapshot.distance = counters.distance or 0
                snapshot.screen_size = counters.screen_size or 0
                snapshot.backface = counters.backface or 0
                snapshot.passed = counters.passed or 0
                self._sgui_cull_last = snapshot
                counters.disabled = 0
                counters.distance = 0
                counters.screen_size = 0
                counters.backface = 0
                counters.passed = 0
            end
        end
    end
    local visit_mark = (self._surface_gui_visit_mark or 0) + 1
    local frame_id = self._surface_gui_frame_id or 0
    local visible_count = 0
    local updated_count = 0
    local deferred_count = 0
    local catchup_count = 0
    local dirty_count = 0
    local validation_count = 0
    local marks = self._surface_gui_marks or {}
    local unique_entries = self._surface_gui_visible_entries or {}
    local new_visible_queue = self._surface_gui_new_visible_queue or {}
    local dirty_visible_queue = self._surface_gui_dirty_visible_queue or {}
    local validation_candidates = self._surface_gui_validation_candidates or {}
    local motion_state = get_surface_gui_motion_state(self)
    local validation_budget = get_surface_gui_budget(self, "validation", SURFACE_GUI_MAX_VALIDATIONS_PER_FRAME)
    local batches = surface_gui_batches or self._visible_surface_gui_batches or {}
    self._surface_gui_visit_mark = visit_mark
    self._surface_gui_marks = marks

    local visible_signature_sum = #batches % SURFACE_GUI_SIGNATURE_MOD
    local visible_signature_weighted = (#batches * 1315423911) % SURFACE_GUI_SIGNATURE_MOD
    local signature_valid = true
    for index = 1, #batches do
        local batch = batches[index]
        if type(batch) == "table" then
            local surface_gui = batch.surface_gui_ref
            local part = batch.surface_gui_part_ref
            if type(surface_gui) == "table" and type(part) == "table" then
                local runtime_id = batch.surface_gui_runtime_id or surface_gui.runtime_id or batch.key or batch
                local id_hash = hash_surface_gui_value(runtime_id)
                visible_signature_sum = (visible_signature_sum + id_hash) % SURFACE_GUI_SIGNATURE_MOD
                visible_signature_weighted = (visible_signature_weighted +
                    (id_hash * ((id_hash % 8191) + 1)) % SURFACE_GUI_SIGNATURE_MOD) % SURFACE_GUI_SIGNATURE_MOD
            else
                signature_valid = false
            end
        else
            signature_valid = false
        end
    end
    local visible_signature = (visible_signature_sum * SURFACE_GUI_SIGNATURE_MULTIPLIER + visible_signature_weighted) %
        SURFACE_GUI_SIGNATURE_MOD
    if #batches <= 0 then
        self._surface_gui_fast_signature = visible_signature
        self._surface_gui_stats = self._surface_gui_stats or {}
        self._surface_gui_stats.visible_batch_count = 0
        self._surface_gui_stats.updated_batch_count = 0
        self._surface_gui_stats.deferred_batch_count = 0
        self._surface_gui_stats.catchup_batch_count = 0
        self._surface_gui_stats.dirty_count = 0
        self._surface_gui_stats.validation_batch_count = 0
        self._surface_gui_stats.fast_path_count = 0
        return
    end
    local fast_visible_count = 0
    local fast_path_ok = signature_valid
    if fast_path_ok then
        for index = 1, #batches do
            local batch = batches[index]
            local surface_gui = batch and batch.surface_gui_ref
            local state = surface_gui and surface_gui._runtime_state or nil
            local runtime_id = batch and (batch.surface_gui_runtime_id or surface_gui.runtime_id or batch.key or batch)
            local texture = state and (state.last_bound_texture or state.canvas) or nil
            local event_dirty = surface_gui and (rawget(surface_gui, "_content_dirty") == true or
                rawget(surface_gui, "_layout_dirty") == true)
            if type(state) ~= "table"
                or state.rendered ~= true
                or not state.canvas
                or not texture
                or event_dirty then
                fast_path_ok = false
                break
            end
        end
    end
    if fast_path_ok then
        for index = 1, #batches do
            local batch = batches[index]
            local surface_gui = batch and batch.surface_gui_ref
            local state = surface_gui and surface_gui._runtime_state or nil
            local runtime_id = batch and (batch.surface_gui_runtime_id or surface_gui.runtime_id or batch.key or batch)
            if type(state) == "table" then
                state.visible_recently = true
                state.last_visible_frame = frame_id
                self:_set_surface_gui_batch_texture(batch, state.last_bound_texture or state.canvas)
            end
            if marks[runtime_id] ~= visit_mark then
                marks[runtime_id] = visit_mark
                fast_visible_count = fast_visible_count + 1
            end
        end
        self._surface_gui_stats = self._surface_gui_stats or {}
        self._surface_gui_stats.visible_batch_count = fast_visible_count
        self._surface_gui_stats.updated_batch_count = 0
        self._surface_gui_stats.deferred_batch_count = 0
        self._surface_gui_stats.catchup_batch_count = 0
        self._surface_gui_stats.dirty_count = 0
        self._surface_gui_stats.validation_batch_count = 0
        self._surface_gui_stats.fast_path_count = (self._surface_gui_stats.fast_path_count or 0) + 1
        return
    end
    self._surface_gui_fast_signature = visible_signature

    for index = #unique_entries, 1, -1 do
        unique_entries[index] = nil
    end
    for index = #new_visible_queue, 1, -1 do
        new_visible_queue[index] = nil
    end
    for index = #dirty_visible_queue, 1, -1 do
        dirty_visible_queue[index] = nil
    end
    for index = #validation_candidates, 1, -1 do
        validation_candidates[index] = nil
    end

    for index = 1, #batches do
        local batch = batches[index]
        if type(batch) == "table" then
            local surface_gui = batch.surface_gui_ref
            local part = batch.surface_gui_part_ref
            if type(surface_gui) == "table" and type(part) == "table" then
                local runtime_id = batch.surface_gui_runtime_id or surface_gui.runtime_id or batch.key or batch
                if marks[runtime_id] ~= visit_mark then
                    marks[runtime_id] = visit_mark
                    visible_count = visible_count + 1
                    unique_entries[#unique_entries + 1] = {
                        surface_gui = surface_gui,
                        part = part,
                        runtime_id = runtime_id,
                    }
                end
            end
        end
    end

    for index = 1, #unique_entries do
        local entry = unique_entries[index]
        local surface_gui = entry.surface_gui
        local part = entry.part
        local state = surface_gui._runtime_state or {}
        state.visible_recently = true
        state.last_visible_frame = frame_id
        if state.rendered ~= true or not state.canvas or not state.last_bound_texture then
            new_visible_queue[#new_visible_queue + 1] = entry
            state.last_bound_texture = state.last_bound_texture
                or state.canvas
                or self._transparent_texture
                or self._white_texture
            surface_gui._runtime_state = state
            dirty_count = dirty_count + 1
        elseif surface_gui and (rawget(surface_gui, "_content_dirty") == true or rawget(surface_gui, "_layout_dirty") == true) then
            dirty_visible_queue[#dirty_visible_queue + 1] = entry
            dirty_count = dirty_count + 1
        elseif type(state.next_validation_frame) == "number" and frame_id < state.next_validation_frame then
            state.last_bound_texture = state.last_bound_texture
                or state.canvas
                or self._transparent_texture
                or self._white_texture
            surface_gui._runtime_state = state
        elseif surface_gui and rawget(surface_gui, "_surface_gui_event_wrapped") == true then
            state.last_bound_texture = state.last_bound_texture
                or state.canvas
                or self._transparent_texture
                or self._white_texture
            surface_gui._runtime_state = state
        else
            validation_candidates[#validation_candidates + 1] = entry
        end
    end

    local function process_queue(queue, budget)
        local processed = 0
        for index = 1, math.min(#queue, math.max(0, budget)) do
            local entry = queue[index]
            local texture, _, redrawn = self:_ensure_surface_gui_runtime_texture(entry.surface_gui, entry.part)
            local state = entry.surface_gui._runtime_state or {}
            state.last_bound_texture = texture or self._transparent_texture or self._white_texture
            entry.surface_gui._runtime_state = state
            if state.deferred_visible then
                catchup_count = catchup_count + 1
                state.deferred_visible = false
            end
            if redrawn then
                updated_count = updated_count + 1
            end
            processed = processed + 1
        end
        for index = processed + 1, #queue do
            local entry = queue[index]
            local state = entry.surface_gui._runtime_state or {}
            state.deferred_visible = motion_state ~= "steady" or state.deferred_visible == true
            entry.surface_gui._runtime_state = state
            deferred_count = deferred_count + 1
        end
        return processed
    end

    -- visible publication is a draw prerequisite. Camera pacing previously
    -- bound transparent placeholders for new canvases and froze authored
    -- changes for the entire moving state (dirty budget zero). Deduplicate
    -- above and retain unchanged canvases, but publish current visible content
    -- before submitting it. only speculative validation stays budgeted
    process_queue(new_visible_queue, #new_visible_queue)
    process_queue(dirty_visible_queue, #dirty_visible_queue)

    if validation_budget > 0 and #validation_candidates > 0 then
        local cursor = self._surface_gui_validation_cursor or 0
        local processed = math.min(validation_budget, #validation_candidates)
        for step = 1, processed do
            cursor = (cursor % #validation_candidates) + 1
            local entry = validation_candidates[cursor]
            local texture, _, redrawn = self:_ensure_surface_gui_runtime_texture(entry.surface_gui, entry.part)
            local state = entry.surface_gui._runtime_state or {}
            state.last_bound_texture = texture or self._transparent_texture or self._white_texture
            entry.surface_gui._runtime_state = state
            if state.deferred_visible then
                catchup_count = catchup_count + 1
                state.deferred_visible = false
            end
            if redrawn then
                updated_count = updated_count + 1
            end
        end
        validation_count = processed
        self._surface_gui_validation_cursor = cursor
    else
        self._surface_gui_validation_cursor = 0
    end

    for index = 1, #batches do
        local batch = batches[index]
        if type(batch) == "table" and type(batch.surface_gui_ref) == "table" then
            self:_set_surface_gui_batch_texture(batch, batch.surface_gui_ref._runtime_state and batch.surface_gui_ref._runtime_state.last_bound_texture)
        end
    end

    local entries = self._surface_gui_entries or {}
    for index = 1, #entries do
        local entry = entries[index]
        local state = entry and entry.surface_gui and entry.surface_gui._runtime_state
        if type(state) == "table" and state.last_visible_frame ~= frame_id then
            state.visible_recently = false
        end
    end

    self._surface_gui_stats = self._surface_gui_stats or {}
    self._surface_gui_stats.visible_batch_count = visible_count
    self._surface_gui_stats.updated_batch_count = updated_count
    self._surface_gui_stats.deferred_batch_count = deferred_count
    self._surface_gui_stats.catchup_batch_count = catchup_count
    self._surface_gui_stats.dirty_count = dirty_count
    self._surface_gui_stats.validation_batch_count = validation_count
end

-- SurfaceGui.Brightness is inactive at full environmental lighting and when
-- AlwaysOnTop is enabled. preserve serialized values, only derive draw state
-- Creator reference: Roblox/creator-docs SurfaceGui.yaml, Brightness
function RBX._surface_gui_lighting(surface_gui)
    local influence = clamp(tonumber(surface_gui.light_influence) or 0, 0, 1)
    if surface_gui.always_on_top == true then return 0, 1 end
    if influence == 1 then return 1, 1 end
    return influence, math.max(0, tonumber(surface_gui.brightness) or 1)
end

function RBX._build_surface_gui_face_texture_layers(self, part)
    if type(part) ~= "table" then
        return nil
    end

    local surface_guis = part.SurfaceGuis or {}
    local layers = {}
    for index = 1, #surface_guis do
        local surface_gui = RBX._wrap_surface_gui_runtime(surface_guis[index])
        surface_guis[index] = surface_gui
        if type(surface_gui) == "table" and surface_gui.enabled ~= false then
            local light_influence, brightness = RBX._surface_gui_lighting(surface_gui)
            local state = surface_gui._runtime_state or {}
            local face_name = surface_gui.face or "Front"
            local axis = SURFACE_GUI_FACE_AXES[face_name] or SURFACE_GUI_FACE_AXES.Front
            local px, py, pz,
            rx, ry, rz,
            ux, uy, uz,
            bx, by, bz = get_runtime_part_render_basis(part)
            local local_x, local_y, local_z = get_surface_gui_face_center_offset(part, face_name)
            local face_world_x, face_world_y, face_world_z = transform_local_point(
                px, py, pz,
                rx, ry, rz,
                ux, uy, uz,
                bx, by, bz,
                local_x, local_y, local_z
            )
            local face_normal_x, face_normal_y, face_normal_z = transform_local_normal(
                rx, ry, rz,
                ux, uy, uz,
                bx, by, bz,
                axis.nx, axis.ny, axis.nz
            )
            layers[#layers + 1] = {
                face = face_name,
                texture_object = state.canvas or self._transparent_texture or self._white_texture,
                texture_key = surface_gui.texture_key or get_surface_gui_texture_key(surface_gui),
                transparency = 0,
                class_name = surface_gui.class_name or "SurfaceGui",
                render_priority = surface_gui.always_on_top and 6 or 4,
                light_influence = light_influence,
                brightness = brightness,
                texture_premultiplied = true,
                vertex_color_premultiplied = false,
                use_textured_lighting = true,
                source_kind = "SurfaceGui",
                depth_compare = surface_gui.always_on_top and "always" or "lequal",
                surface_offset_scale = 1.2,
                depth_bias_scale = 1.1,
                surface_gui_ref = surface_gui,
                surface_gui_part_ref = part,
                surface_gui_runtime_id = surface_gui.runtime_id,
                surface_gui_face = face_name,
                surface_gui_z_offset = tonumber(surface_gui.z_offset)or 0,
                surface_gui_order = index,
                surface_gui_max_distance = math.max(0, tonumber(surface_gui.max_distance) or 0),
                surface_gui_face_world_x = face_world_x,
                surface_gui_face_world_y = face_world_y,
                surface_gui_face_world_z = face_world_z,
                surface_gui_face_normal_x = face_normal_x,
                surface_gui_face_normal_y = face_normal_y,
                surface_gui_face_normal_z = face_normal_z,
            }
        end
    end

    return #layers > 0 and layers or nil
end

-- billboardgui = surfacegui canvas pipeline + world-space quad
-- world_w = Size.X.Scale + Size.X.Offset * (2*d*tan(fov/2)/target_h)
local BILLBOARD_VERTEX_UV = {
    { 0, 0 }, { 1, 0 }, { 1, 1 },
    { 0, 0 }, { 1, 1 }, { 0, 1 },
}
-- corner per vertex: 1=TL 2=TR 3=BR 4=BL
local BILLBOARD_VERTEX_CORNER = { 1, 2, 3, 1, 3, 4 }

local function make_billboard_vertex()
    return { 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 0 }
end

-- module-level: a per-frame closure here was pure gc churn
local function billboard_items_back_to_front(a, b)
    return (a.billboard_distance or 0) > (b.billboard_distance or 0)
end

-- Bounds are the adorned Part's authored box, independent of its visual mesh
-- Scale/Offset. Attachments are point adornees in their composed world frame
local BILLBOARD_AXIS_NAMES={'x','y','z'}
function RBX._billboard_gui_anchor(gui,part,camera,mirror_x)
    local target=gui.adornee
    local owner=rawget(gui,'_gui_instance')
    if target==nil and owner then target=owner.Parent end
    local attachment=type(target)=='table' and target.ClassName=='Attachment'
    local point_adornee=attachment
    local local_frame
    while attachment do
        local frame=cframe_from_value(target.CFrame,CFrame.new())
        local_frame=local_frame and frame*local_frame or frame
        target=target.Parent;attachment=target and target.ClassName=='Attachment'
    end
    local supplied=type(target)=='table' and rawget(target,'_core_handle')
    part=supplied or part
    if not part or part._destroyed or part._workspace_active==false then return end
    local cf=part.CFrame
    local frame=local_frame and cf*local_frame or cf
    local px,py,pz=frame.x,frame.y,frame.z
    local size=part.Size
    local hx,hy,hz=math.abs(size.x)*.5,math.abs(size.y)*.5,math.abs(size.z)*.5
    if point_adornee then hx,hy,hz=0,0,0 end
    local ex,ey,ez=0,0,0
    local extent=gui.extents_offset or{}
    for axis=0,2 do
        local cx,cy,cz=camera['r0'..axis],camera['r1'..axis],camera['r2'..axis]
        local half=math.abs(cx*cf.r00+cy*cf.r10+cz*cf.r20)*hx
            +math.abs(cx*cf.r01+cy*cf.r11+cz*cf.r21)*hy
            +math.abs(cx*cf.r02+cy*cf.r12+cz*cf.r22)*hz
        local offset=((gui.studs_offset or{})[BILLBOARD_AXIS_NAMES[axis+1]]or 0)
            +(extent[BILLBOARD_AXIS_NAMES[axis+1]]or 0)*half
        ex,ey,ez=ex+cx*offset,ey+cy*offset,ez+cz*offset
    end
    local world=gui.studs_offset_world_space or{}
    local extworld=gui.extents_offset_world_space or{}
    px=px+ex+((world.x or 0)+(extworld.x or 0)*(math.abs(cf.r00)*hx+math.abs(cf.r01)*hy+math.abs(cf.r02)*hz))*(mirror_x or 1)
    py=py+ey+(world.y or 0)+(extworld.y or 0)*(math.abs(cf.r10)*hx+math.abs(cf.r11)*hy+math.abs(cf.r12)*hz)
    pz=pz+ez+(world.z or 0)+(extworld.z or 0)*(math.abs(cf.r20)*hx+math.abs(cf.r21)*hy+math.abs(cf.r22)*hz)
    return px,py,pz,part
end

local function ensure_billboard_item(renderer, entry)
    local item = entry.item
    if item then
        return item
    end
    local vertices = {}
    for index = 1, 6 do
        vertices[index] = make_billboard_vertex()
    end
    local mesh = love.graphics.newMesh(renderer._textured_vertex_format, 6, "triangles", "stream")
    local id = tostring(entry.gui and entry.gui.runtime_id or entry.runtime_id)
    item = {
        mesh = mesh,
        vertex_count = 6,
        key = "billboard|" .. id,
        uniform_state_key = "billboard|" .. id,
        texture = nil,
        -- same overlay shader + premultiplied blend as face layers
        source_kind = "SurfaceGui",
        billboard_item = true,
        billboard_runtime_id = id,
        legacy_textured = true,
        use_material_maps = false,
        use_textured_lighting = true,
        use_normal_map = false,
        ignore_texture_alpha = false,
        flip_u = false,
        flip_v = false,
        light_influence = 0,
        brightness = 1,
        texture_premultiplied = true,
        vertex_color_premultiplied = false,
        depth_bias = 0,
        cull_mode = "none",
        resolved_cull_mode = "none",
        mirror_cull_swap = false,
        force_cull = false,
        bounds = {
            min_x = 0, min_y = 0, min_z = 0,
            max_x = 0, max_y = 0, max_z = 0,
        },
        _billboard_vertices = vertices,
    }
    renderer:_select_textured_shader_for_batch(item, false)
    entry.item = item
    return item
end

function RBX:_update_billboard_quads()
    local entries = self._billboard_entries or {}
    local items = self._billboard_draw_items or {}
    self._billboard_draw_items = items
    for index = #items, 1, -1 do
        items[index] = nil
    end
    local stats = self._billboard_stats or {}
    self._billboard_stats = stats
    stats.parsed = #entries
    stats.visible = 0
    stats.culled_distance = 0
    stats.culled_disabled = 0
    stats.culled_frustum = 0
    if #entries == 0 then
        return items
    end
    local camera = type(self.camera) == "table" and self.camera.cframe or nil
    if not camera then
        return items
    end

    local cam_x = camera.x or 0
    local cam_y = camera.y or 0
    local cam_z = camera.z or 0
    local fov = (self.camera and self.camera.fov) or math.rad(70)
    local target_height = self._last_render_target_height or self._last_height or love.graphics.getHeight()
    local px_to_studs_per_dist = 2 * math.tan(fov * 0.5) / math.max(1, target_height)
    local mirror_x = self.flip_loaded_map_horizontally ~= false and -1 or 1
    local frustum_planes = self._frame_frustum_planes

    for index = 1, #entries do
        local entry = entries[index]
        local gui = entry.gui
        local part = entry.part
        if type(gui) == "table" and type(part) == "table" and not part._destroyed then
            if gui.enabled == false then
                stats.culled_disabled = stats.culled_disabled + 1
            else
                local ax,ay,az=RBX._billboard_gui_anchor(gui,part,camera,mirror_x)
                if ax then
                local dx = cam_x - ax
                local dy = cam_y - ay
                local dz = cam_z - az
                local distance_sq = dx * dx + dy * dy + dz * dz
                local max_distance = tonumber(gui.max_distance) or 0
                if max_distance > 0 and distance_sq > max_distance * max_distance then
                    stats.culled_distance = stats.culled_distance + 1
                else
                    local distance = math.sqrt(distance_sq)

                    local size = gui.size or {}
                    local size_x = size.x or {}
                    local size_y = size.y or {}
                    local depth=dx*camera.r02+dy*camera.r12+dz*camera.r22
                    local px_to_studs = math.max(0,depth) * px_to_studs_per_dist
                    local world_w = (tonumber(size_x.scale) or 0) + (tonumber(size_x.offset) or 0) * px_to_studs
                    local world_h = (tonumber(size_y.scale) or 0) + (tonumber(size_y.offset) or 0) * px_to_studs

                    local offset=gui.size_offset or{}
                    ax=ax+camera.r00*(offset.x or 0)*world_w+camera.r01*(offset.y or 0)*world_h
                    ay=ay+camera.r10*(offset.x or 0)*world_w+camera.r11*(offset.y or 0)*world_h
                    az=az+camera.r20*(offset.x or 0)*world_w+camera.r21*(offset.y or 0)*world_h
                    if depth<=0 then world_w=0;world_h=0 end

                    -- frustum cull before quad math, quad ~ sphere of half diagonal
                    local frustum_culled = false
                    if world_w > 0 and world_h > 0 and frustum_planes then
                        local radius = 0.5 * math.sqrt(world_w * world_w + world_h * world_h)
                        for plane_index = 1, 6 do
                            local plane = frustum_planes[plane_index]
                            if plane.a * ax + plane.b * ay + plane.c * az + plane.d < -radius then
                                frustum_culled = true
                                break
                            end
                        end
                    end
                    if frustum_culled then
                        stats.culled_frustum = (stats.culled_frustum or 0) + 1
                        world_w = 0 -- fall through the size gate below
                    end

                    if world_w > 0 and world_h > 0 then
                        local nx,ny,nz=camera.r02,camera.r12,camera.r22
                        local rx,ry,rz=camera.r00,camera.r10,camera.r20
                        local ux,uy,uz=camera.r01,camera.r11,camera.r21
                        -- transform-only: canvas redraws via element/proxy dirty flags
                        local canvas = self:_ensure_surface_gui_runtime_texture(gui, part)
                        local item = ensure_billboard_item(self, entry)
                        local resolved_texture = canvas or self._transparent_texture or self._white_texture
                        if item.texture ~= resolved_texture then
                            item.texture = resolved_texture
                            item.mesh:setTexture(resolved_texture)
                        end

                        local half_w = world_w * 0.5
                        local half_h = world_h * 0.5
                        local corners = item._billboard_corners or { {}, {}, {}, {} }
                        item._billboard_corners = corners
                        -- 1=TL 2=TR 3=BR 4=BL, canvas v=0 row = world-up edge
                        corners[1][1] = ax - rx * half_w + ux * half_h
                        corners[1][2] = ay - ry * half_w + uy * half_h
                        corners[1][3] = az - rz * half_w + uz * half_h
                        corners[2][1] = ax + rx * half_w + ux * half_h
                        corners[2][2] = ay + ry * half_w + uy * half_h
                        corners[2][3] = az + rz * half_w + uz * half_h
                        corners[3][1] = ax + rx * half_w - ux * half_h
                        corners[3][2] = ay + ry * half_w - uy * half_h
                        corners[3][3] = az + rz * half_w - uz * half_h
                        corners[4][1] = ax - rx * half_w - ux * half_h
                        corners[4][2] = ay - ry * half_w - uy * half_h
                        corners[4][3] = az - rz * half_w - uz * half_h

                        local vertices = item._billboard_vertices
                        for vertex_index = 1, 6 do
                            local vertex = vertices[vertex_index]
                            local corner = corners[BILLBOARD_VERTEX_CORNER[vertex_index]]
                            local uv = BILLBOARD_VERTEX_UV[vertex_index]
                            vertex[1], vertex[2], vertex[3] = corner[1], corner[2], corner[3]
                            vertex[4], vertex[5], vertex[6] = nx, ny, nz
                            vertex[7], vertex[8] = uv[1], uv[2]
                            vertex[14], vertex[15], vertex[16] = rx, ry, rz
                            vertex[17], vertex[18], vertex[19] = -ux, -uy, -uz
                        end
                        item.mesh:setVertices(vertices)

                        local bounds = item.bounds
                        bounds.min_x, bounds.max_x = math.huge, -math.huge
                        bounds.min_y, bounds.max_y = math.huge, -math.huge
                        bounds.min_z, bounds.max_z = math.huge, -math.huge
                        for corner_index = 1, 4 do
                            local corner = corners[corner_index]
                            bounds.min_x = math.min(bounds.min_x, corner[1])
                            bounds.max_x = math.max(bounds.max_x, corner[1])
                            bounds.min_y = math.min(bounds.min_y, corner[2])
                            bounds.max_y = math.max(bounds.max_y, corner[2])
                            bounds.min_z = math.min(bounds.min_z, corner[3])
                            bounds.max_z = math.max(bounds.max_z, corner[3])
                        end
                        finalize_bounds(bounds)

                        local always_on_top = gui.always_on_top == true
                        item.render_priority = always_on_top and 6 or 4
                        item.depth_compare = always_on_top and "always" or "lequal"
                        local light_influence = clamp(tonumber(gui.light_influence) or 0, 0, 1)
                        local brightness = math.max(0, tonumber(gui.brightness) or 1)
                        if item.light_influence ~= light_influence or item.brightness ~= brightness then
                            item.light_influence = light_influence
                            item.brightness = brightness
                            -- uniform sends cached by state key, bump it so writes reach the shader
                            item.uniform_state_key = string.format("billboard|%s|%.3f|%.3f",
                                item.billboard_runtime_id, light_influence, brightness)
                        end

                        -- probe-readable diagnostics
                        item.billboard_anchor_x, item.billboard_anchor_y, item.billboard_anchor_z = ax, ay, az
                        item.billboard_normal_x, item.billboard_normal_y, item.billboard_normal_z = nx, ny, nz
                        item.billboard_world_w, item.billboard_world_h = world_w, world_h
                        item.billboard_distance = distance

                        items[#items + 1] = item
                        stats.visible = stats.visible + 1
                    end
                end
                end -- live adornee
            end
        end
    end

    if #items > 1 then
        table.sort(items, billboard_items_back_to_front)
    end
    return items
end

-- like BillboardGui but no canvas: raw spritesheet + live UV sub-rect (changes too often to bake)

-- transparent pass blends premultiplied alpha, straight-alpha PNG halos, so premultiply once at load
function RBX:_ensure_sprite_premultiply_shader()
    local shader = self._sprite_premultiply_shader
    if shader then
        return shader
    end
    shader = love.graphics.newShader([[
        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
            vec4 c = Texel(tex, uv);
            return vec4(c.rgb * c.a, c.a) * color;
        }
    ]])
    self._sprite_premultiply_shader = shader
    return shader
end

local function repaint_sprite_sheet(renderer, sheet)
    if not (sheet and sheet.texture and sheet.source_image) then return false end
    love.graphics.push("all")
    love.graphics.setCanvas(sheet.texture)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setShader(renderer:_ensure_sprite_premultiply_shader())
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(sheet.source_image, 0, 0)
    love.graphics.pop()
    return true
end

-- load+premultiply spritesheet, cached per path
function RBX:load_sprite_sheet(path)
    path = tostring(path or "")
    if path == "" then
        return nil
    end
    self._sprite_sheets = self._sprite_sheets or {}
    local cached = self._sprite_sheets[path]
    if cached then
        return cached
    end

    local ok, image = pcall(love.graphics.newImage, path)
    if not ok or not image then
        return nil
    end
    image:setFilter("linear", "linear")
    local width, height = image:getDimensions()

    local canvas = love.graphics.newCanvas(width, height)
    canvas:setFilter("linear", "linear")
    local sheet = { texture = canvas, source_image = image, width = width, height = height, path = path }
    repaint_sprite_sheet(self, sheet)
    self._sprite_sheets[path] = sheet
    return sheet
end

-- Window mode changes clear Canvas contents even though the Canvas objects stay
-- alive. restore cached sprite atlases and invalidate other resolution/context
-- dependent targets without rebuilding the map or billboard handles
function RBX:on_display_resized(width, height, graphics_reset)
    self._camera_viewport_size_cache = nil
    if self.camera then self.camera.viewport_size = nil end
    self._last_width, self._last_height = nil, nil
    local previous_render_canvas = self._render_canvas
    local previous_depth_canvas = self._render_depth_canvas
    self._render_canvas = nil
    self._render_depth_canvas = nil
    self._render_canvas_filter = nil
    release_gui_resource(previous_depth_canvas)
    release_gui_resource(previous_render_canvas)
    if self._dbg_static_overlay then
        local previous_debug_canvas = self._dbg_static_overlay.canvas
        self._dbg_static_overlay.canvas = nil
        release_gui_resource(previous_debug_canvas)
    end

    if not graphics_reset then return end

    for _, sheet in pairs(self._sprite_sheets or {}) do
        local ok, err = pcall(repaint_sprite_sheet, self, sheet)
        if not ok then print("[rbx] sprite-sheet restore failed: " .. tostring(err)) end
    end
    if self._restore_mesh_texture_atlas then
        local ok, err = pcall(self._restore_mesh_texture_atlas, self)
        if not ok then print("[rbx] mesh-atlas restore failed: " .. tostring(err)) end
    end
    if self._rebuild_skybox_atlas then
        local ok, err = pcall(self._rebuild_skybox_atlas, self)
        if not ok then print("[rbx] skybox-atlas restore failed: " .. tostring(err)) end
    end

    -- SurfaceGui canvases are also content-bearing render targets. Force their
    -- normal lazy path to allocate and redraw them on the next visible frame
    for i = 1, #(self._surface_gui_entries or {}) do
        local gui = self._surface_gui_entries[i] and self._surface_gui_entries[i].surface_gui
        local state = gui and gui._runtime_state
        if state then
            local previous_canvas = state.canvas
            state.canvas = nil
            state.last_bound_texture = nil
            state.rendered = false
            state.next_validation_frame = nil
            release_gui_resource(previous_canvas)
        end
        if gui then
            publish_surface_gui_runtime_texture(gui, nil, gui.texture_key)
            gui._content_dirty = true
        end
    end
    self._surface_gui_fast_signature = nil
    self._surface_gui_preload_cursor = 0
end

-- caller mutates handle fields (enabled/rect/offset/normal/color) per frame
function RBX:create_sprite_billboard(part, sheet, opts)
    if type(part) ~= "table" then
        return nil
    end
    -- facade nodes keep the core part in _core_handle, a raw core part has neither
    local runtime_part = rawget(part, "_core_handle") or rawget(part, "_runtime_part") or part
    opts = type(opts) == "table" and opts or {}
    self._sprite_billboards = self._sprite_billboards or {}
    self._sprite_billboard_seq = (self._sprite_billboard_seq or 0) + 1
    local handle = {
        _sprite_billboard = true,
        runtime_id = "sprite_bb|" .. self._sprite_billboard_seq,
        part = runtime_part,
        sheet = sheet,
        enabled = opts.enabled ~= false,
        rect = opts.rect or { x = 0, y = 0, width = 0, height = 0 },
        flip_h = opts.flip_h or false,
        width = tonumber(opts.width) or 4,
        height = tonumber(opts.height) or 4,
        width_offset = tonumber(opts.width_offset) or 0,
        height_offset = tonumber(opts.height_offset) or 0,
        offset = opts.offset or { x = 0, y = 0, z = 0 },
        -- optional world-space normal pins the quad to a surface. without one,
        -- it keeps the normal spherical camera-facing billboard behavior
        normal = opts.normal,
        -- quad-space shift along right/up axes (screen axes for camera-facing billboards)
        offset_right = tonumber(opts.offset_right) or 0,
        offset_up = tonumber(opts.offset_up) or 0,
        layer = tonumber(opts.layer) or 0,
        color = opts.color or { r = 1, g = 1, b = 1 },
        transparency = tonumber(opts.transparency) or 0,
        light_influence = tonumber(opts.light_influence) or 0,
        brightness = tonumber(opts.brightness) or 1,
        max_distance = tonumber(opts.max_distance) or 0,
        always_on_top = opts.always_on_top or false,
    }
    self._sprite_billboards[#self._sprite_billboards + 1] = handle
    return handle
end

function RBX:set_sprite_billboard_sheet(handle, sheet)
    if type(handle) == "table" then
        handle.sheet = sheet
    end
end

function RBX:remove_sprite_billboard(handle)
    local list = self._sprite_billboards
    if not list or type(handle) ~= "table" then
        return
    end
    for index = #list, 1, -1 do
        if list[index] == handle then
            table.remove(list, index)
            break
        end
    end
end

local function resolve_sprite_billboard_basis(handle, dx, dy, dz, distance, mirror_x)
    local nx, ny, nz = 0, 0, 1
    if distance > 1e-4 then
        nx, ny, nz = dx / distance, dy / distance, dz / distance
    end

    local surface_normal = handle and handle.normal
    if type(surface_normal) == "table" then
        local snx = tonumber(surface_normal.x or surface_normal.X or surface_normal[1]) or 0
        local sny = tonumber(surface_normal.y or surface_normal.Y or surface_normal[2]) or 0
        local snz = tonumber(surface_normal.z or surface_normal.Z or surface_normal[3]) or 0
        -- public/game-space X is mirrored into renderer space just like sprite offsets
        snx = snx * mirror_x
        local fixed_x, fixed_y, fixed_z, fixed_len = normalize(snx, sny, snz)
        if fixed_len > 1e-4 then
            nx, ny, nz = fixed_x, fixed_y, fixed_z
        end
    end

    local rx, ry, rz = cross(0, 1, 0, nx, ny, nz)
    local right_len = math.sqrt(rx * rx + ry * ry + rz * rz)
    if right_len <= 1e-4 then
        rx, ry, rz = cross(0, 0, 1, nx, ny, nz)
        right_len = math.sqrt(rx * rx + ry * ry + rz * rz)
    end
    rx, ry, rz = rx / right_len, ry / right_len, rz / right_len
    local ux, uy, uz = cross(nx, ny, nz, rx, ry, rz)
    return nx, ny, nz, rx, ry, rz, ux, uy, uz
end

-- pass-1 anchor fast path: a char's 2-4 layers share one part, so cache the
-- position per part per pass. plain parts (no special/block mesh) read the
-- cframe directly and skip the shape normalization billboards never use;
-- mesh-offset parts keep the full basis call (offset-adjusted anchor)
local sb_pos_pass = 0
local function get_sprite_anchor_position(part)
    if part._sb_pos_pass == sb_pos_pass then
        return part._sb_px, part._sb_py, part._sb_pz
    end
    local px, py, pz
    if part.MeshOwner == nil and part.BlockMeshOffset == nil then
        local cframe = part.CFrame
        px = rawget(cframe, "_x")
        if px ~= nil then
            py, pz = rawget(cframe, "_y"), rawget(cframe, "_z")
        else
            px, py, pz = cframe.x, cframe.y, cframe.z
        end
    else
        px, py, pz = get_runtime_part_render_basis(part)
    end
    part._sb_pos_pass = sb_pos_pass
    part._sb_px, part._sb_py, part._sb_pz = px, py, pz
    return px, py, pz
end

-- batches same-state sprite quads into ONE stream mesh via FFI (100 4-layer chars: ~400 draws -> 1)
-- vertex order = paint order (back-to-front + layer tiebreak), no depth write
local sprite_ffi_ok, sprite_ffi = pcall(require, "ffi")
if not sprite_ffi_ok or type(sprite_ffi) ~= "table" then
    sprite_ffi = nil
end
if sprite_ffi and not (love.data and love.data.newByteData) then
    sprite_ffi = nil
end

local SPRITE_VERTEX_FLOATS = 20 -- must match renderer._textured_vertex_format
local SPRITE_VERTEX_BYTES = SPRITE_VERTEX_FLOATS * 4

-- keep both loops small + dont merge them: luajit blacklists a big body and runs it
-- interpreted = ~80x slower, silently. jit.opt knobs dont help, only a smaller body does
-- phase A parks 29 doubles/quad in scratch, phase B streams scratch -> vertices
local SB_SCRATCH_STRIDE = 32 -- 29 used, padded to a power of two
local sb_scratch, sb_scratch_cap = nil, 0
local function ensure_sb_scratch(quad_count)
    if sb_scratch_cap >= quad_count then
        return
    end
    local capacity = sb_scratch_cap > 0 and sb_scratch_cap or 128
    while capacity < quad_count do
        capacity = capacity * 2
    end
    sb_scratch = sprite_ffi.new("double[?]", capacity * SB_SCRATCH_STRIDE)
    sb_scratch_cap = capacity
end

-- back-to-front, then layer ascending (body under clothes/face/hat)
local function sprite_handles_back_to_front(a, b)
    local da = a._sb_distance or 0
    local db = b._sb_distance or 0
    if math.abs(da - db) > 1e-6 then
        return da > db
    end
    return (a.layer or 0) < (b.layer or 0)
end

--[[ Depth-bucket counting sort for crowds. table.sort's Lua comparator is a
C->Lua transition per compare (never JIT-traced): negligible at the shipped
~200-quad scale (which keeps the exact epsilon sort below the threshold),
~0.6-1.5ms at 1200-2000 visible. Quarter-stud shells, farthest shell first,
insertion order kept inside a shell: a char's layers are created body->hat so
the layer tiebreak is preserved (all its layers share one anchor = one shell),
and cross-sprite order within 0.25 studs is the same near-equal-depth window
the 1e-6 epsilon already treats as unordered -- not visually resolvable for
alpha-blended sprites that close in depth. output feeds the same run-length
batching, so batch semantics are untouched ]]
local SB_BUCKET_SORT_MIN = 400
local SB_BUCKET_INV_WIDTH = 4 -- quarter-stud shells
local SB_BUCKET_COUNT = 2048 -- covers 512 studs, farther quads share the last shell
local sb_sort_keys = {}
local sb_sort_counts = {}
local sb_sort_out = {}
local function sort_sprite_handles_bucketed(visible, visible_n)
    local keys, counts, out = sb_sort_keys, sb_sort_counts, sb_sort_out
    for k = 1, SB_BUCKET_COUNT do
        counts[k] = 0
    end
    local min_key, max_key = SB_BUCKET_COUNT, 1
    for i = 1, visible_n do
        local key = math.floor((visible[i]._sb_distance or 0) * SB_BUCKET_INV_WIDTH) + 1
        if key < 1 then
            key = 1
        elseif key > SB_BUCKET_COUNT then
            key = SB_BUCKET_COUNT
        end
        keys[i] = key
        counts[key] = counts[key] + 1
        if key < min_key then min_key = key end
        if key > max_key then max_key = key end
    end
    -- farthest shell writes first = back-to-front paint order
    local pos = 1
    for k = max_key, min_key, -1 do
        local n = counts[k]
        counts[k] = pos
        pos = pos + n
    end
    for i = 1, visible_n do
        local key = keys[i]
        local p = counts[key]
        counts[key] = p + 1
        out[p] = visible[i]
    end
    for i = 1, visible_n do
        visible[i] = out[i]
        out[i] = false -- drop the handle ref, keep the slot allocated
    end
end

-- grows batch ByteData/mesh to fit quad_count, no-ffi fallback streams via a table instead
local function ensure_sprite_batch_capacity(renderer, batch, quad_count)
    if batch.capacity >= quad_count then
        return
    end
    local capacity = batch.capacity > 0 and batch.capacity or 64
    while capacity < quad_count do
        capacity = capacity * 2
    end
    if sprite_ffi then
        local bytedata = love.data.newByteData(capacity * 6 * SPRITE_VERTEX_BYTES)
        local ptr = sprite_ffi.cast("float*", bytedata:getFFIPointer())
        if batch.ptr ~= nil and batch.capacity > 0 then
            sprite_ffi.copy(ptr, batch.ptr, batch.capacity * 6 * SPRITE_VERTEX_BYTES)
        end
        batch.bytedata = bytedata
        batch.ptr = ptr
    else
        batch.verts = batch.verts or {}
    end
    if batch.mesh then
        batch.mesh:release()
    end
    batch.mesh = love.graphics.newMesh(renderer._textured_vertex_format, capacity * 6, "triangles", "stream")
    batch.capacity = capacity
    local item = batch.item
    if item then
        item.mesh = batch.mesh
        if item.texture then
            batch.mesh:setTexture(item.texture)
        end
    end
end

local function ensure_sprite_batch_item(renderer, batch, batch_index)
    local item = batch.item
    if item then
        return item
    end
    item = {
        mesh = batch.mesh,
        vertex_count = 0,
        key = "spritebatch|" .. batch_index,
        uniform_state_key = "spritebatch|" .. batch_index,
        texture = nil,
        source_kind = "SurfaceGui",
        billboard_item = true,
        billboard_runtime_id = "spritebatch|" .. batch_index,
        legacy_textured = true,
        use_material_maps = false,
        use_textured_lighting = true,
        use_normal_map = false,
        ignore_texture_alpha = false,
        flip_u = false,
        flip_v = false,
        light_influence = 0,
        brightness = 1,
        texture_premultiplied = true,
        vertex_color_premultiplied = true,
        depth_bias = 0,
        cull_mode = "none",
        resolved_cull_mode = "none",
        mirror_cull_swap = false,
        force_cull = false,
        bounds = {
            min_x = 0, min_y = 0, min_z = 0,
            max_x = 0, max_y = 0, max_z = 0,
        },
    }
    renderer:_select_textured_shader_for_batch(item, false)
    batch.item = item
    return item
end

-- pre-claims batch slot 1 (the shared char atlas in practice) at the expected
-- crowd ceiling so a horde ramp never pays the grow staircase mid-gameplay
-- (each doubling step = newByteData + copy + newMesh, ~6 steps 64->2048)
-- never shrinks, call behind a loading cover with crowd_cap * layers + margin
function RBX:prewarm_sprite_batches(quad_count)
    quad_count = math.floor(tonumber(quad_count) or 0)
    if quad_count < 1 or not self._textured_vertex_format then
        return
    end
    local batches = self._sprite_batches
    if not batches then
        batches = {}
        self._sprite_batches = batches
    end
    local batch = batches[1]
    if not batch then
        batch = { capacity = 0, used = 0, quad_list = {} }
        batches[1] = batch
    end
    ensure_sprite_batch_capacity(self, batch, quad_count)
    if sprite_ffi then
        ensure_sb_scratch(quad_count)
    end
end

function RBX:_update_sprite_billboard_quads()
    local handles = self._sprite_billboards
    local items = self._sprite_billboard_draw_items or {}
    self._sprite_billboard_draw_items = items
    for index = #items, 1, -1 do
        items[index] = nil
    end
    if not handles or #handles == 0 then
        return items
    end
    local camera = type(self.camera) == "table" and self.camera.cframe or nil
    if not camera then
        return items
    end

    local cam_x = camera.x or 0
    local cam_y = camera.y or 0
    local cam_z = camera.z or 0
    local fov = (self.camera and self.camera.fov) or math.rad(70)
    local target_height = self._last_render_target_height or self._last_height or love.graphics.getHeight()
    local px_to_studs_per_dist = 2 * math.tan(fov * 0.5) / math.max(1, target_height)
    local mirror_x = self.flip_loaded_map_horizontally ~= false and -1 or 1
    local frustum_planes = self._frame_frustum_planes

    local stats = self._sprite_billboard_stats or {}
    self._sprite_billboard_stats = stats
    stats.total = #handles
    stats.visible = 0
    stats.culled = 0

    -- pass 1: visibility+anchor/size math, cached on handle (_sb_*) so pass 2 skips it
    sb_pos_pass = sb_pos_pass + 1
    local visible = self._sprite_visible_scratch or {}
    self._sprite_visible_scratch = visible
    local visible_n = 0
    for handle_index = 1, #handles do
        local handle = handles[handle_index]
        local part = handle.part
        local sheet = handle.sheet
        local texture = sheet and sheet.texture
        local rect = handle.rect
        if handle.enabled ~= false and texture and type(part) == "table" and not part._destroyed
            and rect and (tonumber(rect.width) or 0) > 0 and (tonumber(rect.height) or 0) > 0 then
            local px, py, pz = get_sprite_anchor_position(part)
            local off = handle.offset
            local ax = px + (off and (tonumber(off.x) or 0) or 0) * mirror_x
            local ay = py + (off and (tonumber(off.y) or 0) or 0)
            local az = pz + (off and (tonumber(off.z) or 0) or 0)

            local dx = cam_x - ax
            local dy = cam_y - ay
            local dz = cam_z - az
            local distance_sq = dx * dx + dy * dy + dz * dz
            local max_distance = tonumber(handle.max_distance) or 0
            if not (max_distance > 0 and distance_sq > max_distance * max_distance) then
                local distance = math.sqrt(distance_sq)
                local px_to_studs = distance * px_to_studs_per_dist
                local world_w = (tonumber(handle.width) or 0) + (tonumber(handle.width_offset) or 0) * px_to_studs
                local world_h = (tonumber(handle.height) or 0) + (tonumber(handle.height_offset) or 0) * px_to_studs
                if world_w > 0 and world_h > 0 then
                    local visible_here = true
                    if frustum_planes then
                        -- conservative sphere: half quad diagonal + pass-2 anchor slide
                        local off_r = tonumber(handle.offset_right) or 0
                        local off_u = tonumber(handle.offset_up) or 0
                        local radius = 0.5 * math.sqrt(world_w * world_w + world_h * world_h)
                            + math.abs(off_r) + math.abs(off_u)
                        for plane_index = 1, 6 do
                            local plane = frustum_planes[plane_index]
                            if plane.a * ax + plane.b * ay + plane.c * az + plane.d < -radius then
                                visible_here = false
                                break
                            end
                        end
                    end
                    if visible_here then
                        handle._sb_ax, handle._sb_ay, handle._sb_az = ax, ay, az
                        handle._sb_dx, handle._sb_dy, handle._sb_dz = dx, dy, dz
                        handle._sb_distance = distance
                        handle._sb_w, handle._sb_h = world_w, world_h
                        visible_n = visible_n + 1
                        visible[visible_n] = handle
                    else
                        stats.culled = stats.culled + 1
                    end
                end
            else
                stats.culled = stats.culled + 1
            end
        end
    end
    for index = #visible, visible_n + 1, -1 do
        visible[index] = nil
    end
    stats.visible = visible_n
    if visible_n == 0 then
        return items
    end

    if visible_n > 1 then
        if visible_n <= SB_BUCKET_SORT_MIN then
            table.sort(visible, sprite_handles_back_to_front)
        else
            sort_sprite_handles_bucketed(visible, visible_n)
        end
    end

    -- pass 2: stream quads into per-state batches (usually just one)
    local batches = self._sprite_batches
    if not batches then
        batches = {}
        self._sprite_batches = batches
    end
    for i = 1, #batches do
        batches[i].used = 0
        batches[i].quad_list = batches[i].quad_list or {}
    end

    if sprite_ffi then
        ensure_sb_scratch(visible_n)
    end
    local quad_n = 0
    local batch_n = 0 -- batches claimed THIS frame, run-length, so this is also paint order
    for i = 1, visible_n do
        local handle = visible[i]
        local sheet = handle.sheet
        local texture = sheet.texture
        local always_on_top = handle.always_on_top == true
        local light_influence = clamp(tonumber(handle.light_influence) or 0, 0, 1)
        local brightness = math.max(0, tonumber(handle.brightness) or 1)

        --[[ only merge with the last batch so overlapping UI keeps its paint order ]]
        local batch = batch_n > 0 and batches[batch_n] or nil
        if not (batch
                and batch.texture == texture
                and batch.always_on_top == always_on_top
                and batch.light_influence == light_influence
                and batch.brightness == brightness) then
            batch_n = batch_n + 1
            batch = batches[batch_n]
            if not batch then
                batch = {
                    capacity = 0,
                    used = 0,
                    quad_list = {}, -- scratch indices, in paint order
                }
                batches[batch_n] = batch
            end
            -- reused slots can hold last frame's key, re-stamp rather than inherit
            batch.texture = texture
            batch.always_on_top = always_on_top
            batch.light_influence = light_influence
            batch.brightness = brightness
            batch.used = 0
        end

        local used = batch.used
        ensure_sprite_batch_capacity(self, batch, used + 1)

        local ax, ay, az = handle._sb_ax, handle._sb_ay, handle._sb_az
        local dx, dy, dz = handle._sb_dx, handle._sb_dy, handle._sb_dz
        local distance = handle._sb_distance
        local world_w, world_h = handle._sb_w, handle._sb_h

        -- Spherical facing is the default. a supplied world-space normal turns
        -- the sprite into a surface-aligned quad (used by impact decals)
        local nx, ny, nz, rx, ry, rz, ux, uy, uz =
            resolve_sprite_billboard_basis(handle, dx, dy, dz, distance, mirror_x)

        -- slide anchor along on-screen right/up axes
        local off_r = tonumber(handle.offset_right) or 0
        local off_u = tonumber(handle.offset_up) or 0
        if off_r ~= 0 or off_u ~= 0 then
            ax = ax + rx * off_r + ux * off_u
            ay = ay + ry * off_r + uy * off_u
            az = az + rz * off_r + uz * off_u
        end

        -- sub-rect UVs from the raw sheet, flip_h swaps u0/u1
        local rect = handle.rect
        local tw = sheet.width or texture:getWidth()
        local th = sheet.height or texture:getHeight()
        local u0 = (tonumber(rect.x) or 0) / tw
        local v0 = (tonumber(rect.y) or 0) / th
        local u1 = u0 + (tonumber(rect.width) or 0) / tw
        local v1 = v0 + (tonumber(rect.height) or 0) / th
        if handle.flip_h then
            u0, u1 = u1, u0
        end

        -- premultiplied vertex color: tint * (1 - transparency)
        local alpha = 1 - clamp(tonumber(handle.transparency) or 0, 0, 1)
        local col = handle.color
        local cr, cg, cb = authored_color3_to_gpu(
            clamp(col and (tonumber(col.r) or 1) or 1, 0, 1),
            clamp(col and (tonumber(col.g) or 1) or 1, 0, 1),
            clamp(col and (tonumber(col.b) or 1) or 1, 0, 1)
        )
        cr, cg, cb = cr * alpha, cg * alpha, cb * alpha

        local half_w = world_w * 0.5
        local half_h = world_h * 0.5
        -- corners: 1=TL 2=TR 3=BR 4=BL
        local rxw, ryw, rzw = rx * half_w, ry * half_w, rz * half_w
        local uxh, uyh, uzh = ux * half_h, uy * half_h, uz * half_h

        -- batch bounds accumulate over every quad, feeds lighting
        if used == 0 then
            batch.min_x, batch.min_y, batch.min_z = math.huge, math.huge, math.huge
            batch.max_x, batch.max_y, batch.max_z = -math.huge, -math.huge, -math.huge
        end
        -- anchor + half-diagonal AABB: 6 compares not 24. over-estimating is safe (lighting
        -- only) and keeps this body small enough for the JIT (see note above)
        local qr = math.sqrt(half_w * half_w + half_h * half_h)
        local bminx, bminy, bminz = batch.min_x, batch.min_y, batch.min_z
        local bmaxx, bmaxy, bmaxz = batch.max_x, batch.max_y, batch.max_z
        if ax - qr < bminx then bminx = ax - qr end
        if ax + qr > bmaxx then bmaxx = ax + qr end
        if ay - qr < bminy then bminy = ay - qr end
        if ay + qr > bmaxy then bmaxy = ay + qr end
        if az - qr < bminz then bminz = az - qr end
        if az + qr > bmaxz then bmaxz = az + qr end
        batch.min_x, batch.min_y, batch.min_z = bminx, bminy, bminz
        batch.max_x, batch.max_y, batch.max_z = bmaxx, bmaxy, bmaxz

        local ptr = batch.ptr
        local bux, buy, buz = -ux, -uy, -uz
        -- FFI path: park params in scratch, phase B writes the vertices
        if ptr and sb_scratch then
            local s = quad_n * SB_SCRATCH_STRIDE
            local sc = sb_scratch
            sc[s] = ax - rxw + uxh; sc[s + 1] = ay - ryw + uyh; sc[s + 2] = az - rzw + uzh
            sc[s + 3] = ax + rxw + uxh; sc[s + 4] = ay + ryw + uyh; sc[s + 5] = az + rzw + uzh
            sc[s + 6] = ax + rxw - uxh; sc[s + 7] = ay + ryw - uyh; sc[s + 8] = az + rzw - uzh
            sc[s + 9] = ax - rxw - uxh; sc[s + 10] = ay - ryw - uyh; sc[s + 11] = az - rzw - uzh
            sc[s + 12] = nx; sc[s + 13] = ny; sc[s + 14] = nz
            sc[s + 15] = rx; sc[s + 16] = ry; sc[s + 17] = rz
            sc[s + 18] = bux; sc[s + 19] = buy; sc[s + 20] = buz
            sc[s + 21] = cr; sc[s + 22] = cg; sc[s + 23] = cb; sc[s + 24] = alpha
            sc[s + 25] = u0; sc[s + 26] = v0; sc[s + 27] = u1; sc[s + 28] = v1
            local ql = batch.quad_list
            ql[used + 1] = quad_n
            quad_n = quad_n + 1
            batch.used = used + 1
            goto continue_sprite_handle
        end
        local c1x, c1y, c1z = ax - rxw + uxh, ay - ryw + uyh, az - rzw + uzh
        local c2x, c2y, c2z = ax + rxw + uxh, ay + ryw + uyh, az + rzw + uzh
        local c3x, c3y, c3z = ax + rxw - uxh, ay + ryw - uyh, az + rzw - uzh
        local c4x, c4y, c4z = ax - rxw - uxh, ay - ryw - uyh, az - rzw - uzh
        -- 6 verts (2 tris) x 20 floats: pos3 normal3 uv2 color4 reflectance1 tangent3 bitangent3 ao1
        if not ptr then
            -- no-ffi fallback: reused vertex tables, uploaded as a slice
            local verts = batch.verts
            local vbase = used * 6
            local cxs = { c1x, c2x, c3x, c4x }
            local cys = { c1y, c2y, c3y, c4y }
            local czs = { c1z, c2z, c3z, c4z }
            local cus = { u0, u1, u1, u0 }
            local cvs = { v0, v0, v1, v1 }
            for vi = 1, 6 do
                local ci = BILLBOARD_VERTEX_CORNER[vi]
                local v = verts[vbase + vi]
                if not v then
                    v = make_billboard_vertex()
                    verts[vbase + vi] = v
                end
                v[1], v[2], v[3] = cxs[ci], cys[ci], czs[ci]
                v[4], v[5], v[6] = nx, ny, nz
                v[7], v[8] = cus[ci], cvs[ci]
                v[9], v[10], v[11], v[12] = cr, cg, cb, alpha
                v[13] = 0
                v[14], v[15], v[16] = rx, ry, rz
                v[17], v[18], v[19] = bux, buy, buz
                v[20] = 0
            end
            batch.used = used + 1
            goto continue_sprite_handle
        end
        local o = used * 6 * SPRITE_VERTEX_FLOATS
        ptr[o] = c1x; ptr[o + 1] = c1y; ptr[o + 2] = c1z
        ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
        ptr[o + 6] = u0; ptr[o + 7] = v0
        ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
        ptr[o + 12] = 0
        ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
        ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
        ptr[o + 19] = 0
        o = o + SPRITE_VERTEX_FLOATS
        ptr[o] = c2x; ptr[o + 1] = c2y; ptr[o + 2] = c2z
        ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
        ptr[o + 6] = u1; ptr[o + 7] = v0
        ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
        ptr[o + 12] = 0
        ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
        ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
        ptr[o + 19] = 0
        o = o + SPRITE_VERTEX_FLOATS
        ptr[o] = c3x; ptr[o + 1] = c3y; ptr[o + 2] = c3z
        ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
        ptr[o + 6] = u1; ptr[o + 7] = v1
        ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
        ptr[o + 12] = 0
        ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
        ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
        ptr[o + 19] = 0
        o = o + SPRITE_VERTEX_FLOATS
        ptr[o] = c1x; ptr[o + 1] = c1y; ptr[o + 2] = c1z
        ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
        ptr[o + 6] = u0; ptr[o + 7] = v0
        ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
        ptr[o + 12] = 0
        ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
        ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
        ptr[o + 19] = 0
        o = o + SPRITE_VERTEX_FLOATS
        ptr[o] = c3x; ptr[o + 1] = c3y; ptr[o + 2] = c3z
        ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
        ptr[o + 6] = u1; ptr[o + 7] = v1
        ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
        ptr[o + 12] = 0
        ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
        ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
        ptr[o + 19] = 0
        o = o + SPRITE_VERTEX_FLOATS
        ptr[o] = c4x; ptr[o + 1] = c4y; ptr[o + 2] = c4z
        ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
        ptr[o + 6] = u0; ptr[o + 7] = v1
        ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
        ptr[o + 12] = 0
        ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
        ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
        ptr[o + 19] = 0

        batch.used = used + 1
        ::continue_sprite_handle::
    end

    -- phase B: scratch -> vertices. keep tiny (ptr hoisted, no lookups/calls) or the JIT
    -- blacklists it. corners 1,2,3,1,3,4 = two tris
    if sb_scratch then
        local sc = sb_scratch
        for bi = 1, #batches do
            local batch = batches[bi]
            local ptr, used = batch.ptr, batch.used
            if ptr and used > 0 then
                local ql = batch.quad_list
                for k = 1, used do
                    local s = ql[k] * SB_SCRATCH_STRIDE
                    local c1x, c1y, c1z = sc[s], sc[s + 1], sc[s + 2]
                    local c2x, c2y, c2z = sc[s + 3], sc[s + 4], sc[s + 5]
                    local c3x, c3y, c3z = sc[s + 6], sc[s + 7], sc[s + 8]
                    local c4x, c4y, c4z = sc[s + 9], sc[s + 10], sc[s + 11]
                    local nx, ny, nz = sc[s + 12], sc[s + 13], sc[s + 14]
                    local rx, ry, rz = sc[s + 15], sc[s + 16], sc[s + 17]
                    local bux, buy, buz = sc[s + 18], sc[s + 19], sc[s + 20]
                    local cr, cg, cb, alpha = sc[s + 21], sc[s + 22], sc[s + 23], sc[s + 24]
                    local u0, v0, u1, v1 = sc[s + 25], sc[s + 26], sc[s + 27], sc[s + 28]
                    local o = (k - 1) * 6 * SPRITE_VERTEX_FLOATS
                    ptr[o] = c1x; ptr[o + 1] = c1y; ptr[o + 2] = c1z
                    ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
                    ptr[o + 6] = u0; ptr[o + 7] = v0
                    ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
                    ptr[o + 12] = 0
                    ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
                    ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
                    ptr[o + 19] = 0
                    o = o + SPRITE_VERTEX_FLOATS
                    ptr[o] = c2x; ptr[o + 1] = c2y; ptr[o + 2] = c2z
                    ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
                    ptr[o + 6] = u1; ptr[o + 7] = v0
                    ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
                    ptr[o + 12] = 0
                    ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
                    ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
                    ptr[o + 19] = 0
                    o = o + SPRITE_VERTEX_FLOATS
                    ptr[o] = c3x; ptr[o + 1] = c3y; ptr[o + 2] = c3z
                    ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
                    ptr[o + 6] = u1; ptr[o + 7] = v1
                    ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
                    ptr[o + 12] = 0
                    ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
                    ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
                    ptr[o + 19] = 0
                    o = o + SPRITE_VERTEX_FLOATS
                    ptr[o] = c1x; ptr[o + 1] = c1y; ptr[o + 2] = c1z
                    ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
                    ptr[o + 6] = u0; ptr[o + 7] = v0
                    ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
                    ptr[o + 12] = 0
                    ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
                    ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
                    ptr[o + 19] = 0
                    o = o + SPRITE_VERTEX_FLOATS
                    ptr[o] = c3x; ptr[o + 1] = c3y; ptr[o + 2] = c3z
                    ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
                    ptr[o + 6] = u1; ptr[o + 7] = v1
                    ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
                    ptr[o + 12] = 0
                    ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
                    ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
                    ptr[o + 19] = 0
                    o = o + SPRITE_VERTEX_FLOATS
                    ptr[o] = c4x; ptr[o + 1] = c4y; ptr[o + 2] = c4z
                    ptr[o + 3] = nx; ptr[o + 4] = ny; ptr[o + 5] = nz
                    ptr[o + 6] = u0; ptr[o + 7] = v1
                    ptr[o + 8] = cr; ptr[o + 9] = cg; ptr[o + 10] = cb; ptr[o + 11] = alpha
                    ptr[o + 12] = 0
                    ptr[o + 13] = rx; ptr[o + 14] = ry; ptr[o + 15] = rz
                    ptr[o + 16] = bux; ptr[o + 17] = buy; ptr[o + 18] = buz
                    ptr[o + 19] = 0
                end
            end
        end
    end

    --[[ emit one draw item per non-empty batch, in run order (= back-to-front) ]]
    for bi = 1, batch_n do
        local batch = batches[bi]
        local used = batch.used
        if used > 0 then
            local item = ensure_sprite_batch_item(self, batch, bi)
            if batch.ptr then
                -- upload `used` quads, not the whole ByteData. capacity doubles from a
                -- 64-quad floor and never shrinks, so uploading the full buffer streams the
                -- high-water mark to the GPU every frame no matter how few sprites are live
                -- (setDrawRange below only bounds what's DRAWN, not what's uploaded)
                if not batch._setvertices_count_unsupported then
                    local ok = pcall(batch.mesh.setVertices, batch.mesh, batch.bytedata, 1, used * 6)
                    if not ok then
                        -- older LOVE without the (data, start, count) overload: upload it all
                        batch._setvertices_count_unsupported = true
                        batch.mesh:setVertices(batch.bytedata)
                    end
                else
                    batch.mesh:setVertices(batch.bytedata)
                end
            else
                local verts = batch.verts
                for vi = #verts, used * 6 + 1, -1 do verts[vi] = nil end
                batch.mesh:setVertices(verts)
            end
            batch.mesh:setDrawRange(1, used * 6)
            item.mesh = batch.mesh
            item.vertex_count = used * 6
            if item.texture ~= batch.texture then
                item.texture = batch.texture
                batch.mesh:setTexture(batch.texture)
            end
            local bounds = item.bounds
            bounds.min_x, bounds.min_y, bounds.min_z = batch.min_x, batch.min_y, batch.min_z
            bounds.max_x, bounds.max_y, bounds.max_z = batch.max_x, batch.max_y, batch.max_z
            finalize_bounds(bounds)
            item.render_priority = batch.always_on_top and 6 or 4
            item.depth_compare = batch.always_on_top and "always" or "lequal"
            if item.light_influence ~= batch.light_influence or item.brightness ~= batch.brightness then
                item.light_influence = batch.light_influence
                item.brightness = batch.brightness
                item.uniform_state_key = string.format("spritebatch|%d|%.3f|%.3f",
                    bi, batch.light_influence, batch.brightness)
            end
            items[#items + 1] = item
        end
    end
    return items
end
