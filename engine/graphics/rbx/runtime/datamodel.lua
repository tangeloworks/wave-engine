local ROPE = runtime_require("physics/rope.lua")
local PHYSICS_SERVICE = runtime_require("physics/service.lua")
local RUNTIME_WELD = runtime_require("physics/runtime_weld.lua")
local DataModel = {}
local InstanceMethods = {}
local ServiceProviderMethods = {}
local DataModelMethods = {}
local instance_mt = {}
local datamodel_mt = {}

local INTEGRATION_METHODS = {
    "load_map",
    "is_map_loading",
    "get_map_load_status",
    "update",
    "draw",
    "create_world_mesh",
    "get_physics_alpha",
    "wake_parts_in_bounds",
    "get_stats",
    "get_debug_report",
    "needs_redraw",
    "set_camera_cframe",
    "get_camera_cframe",
    "render_to_canvas",
    "draw_to_rect",
    "capture_frame",
    "get_script_errors",
    "set_virtual_resolution",
    "set_internal_resolution_scale",
    "set_far_clip",
    "set_max_local_lights",
    "set_letterbox_resolution",
    "on_display_resized",
    "set_damage_fx",
    "warm_damage_fx",
    "part_is_supported",
    "part_wall_normal",
    "_park_runtime_part",
    "_unpark_runtime_part",
    "_set_runtime_part_rotation_locked",
}

local SERVICE_CLASSES = {
    Workspace = true,
    Lighting = true,
    RunService = true,
    PhysicsService = true,
}

local INSTANCE_SIGNAL_NAMES = {
    ChildAdded = true,
    ChildRemoved = true,
    DescendantAdded = true,
    AncestryChanged = true,
    Destroying = true,
    Changed = true,
}

local GENERIC_INSTANCE_CLASSES = {
    Folder = true,
    Model = true,
    Camera = true,
    WorldModel = true,
    Atmosphere = true,
    SurfaceAppearance = true,
    Decal = true,
    Texture = true,
    SpecialMesh = true,
    BlockMesh = true,
    CylinderMesh = true,
    Attachment = true,
    RopeConstraint = true,
    RodConstraint = true,
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
}

local PUBLIC_ASYNC_MAP_LOAD_OPTIONS = {
    on_complete = true,
}

-- public Light facades own renderer entries, but never scene geometry.  keep
-- the complete bridge behind one local table: this module sits close to
-- LuaJIT's chunk-local limit and light lifecycle operations need to remain a
-- single, auditable transaction (facade values -> binding -> grid revision)
local LOCAL_LIGHT = {
    classes = {
        PointLight = true,
        SpotLight = true,
        SurfaceLight = true,
    },
    schema = {
        Enabled = "boolean",
        Brightness = "number(0..40)",
        Color = "Color3",
        Range = "number(0..60)",
        Shadows = "boolean",
        Angle = "number(0..180; SpotLight/SurfaceLight)",
        Face = "NormalId(SpotLight/SurfaceLight)",
    },
}

-- keep the complete FaceInstance bridge behind one top-level local. LuaJIT's
-- chunk-local limit is tight in this module, table methods also make the
-- descriptor/facade/owner responsibilities explicit without another cluster
-- of unrelated globals
local FACE_TEXTURE = {
    classes = { Decal = true, Texture = true },
    content_properties = {
        Texture = true,
        TextureContent = true,
        ColorMap = true,
        ColorMapContent = true,
        Content = true,
    },
    legacy_mesh = {
        classes = {
            SpecialMesh = true,
            BlockMesh = true,
            CylinderMesh = true,
        },
        mesh_content_properties = {
            MeshId = true,
            MeshID = true,
            MeshContent = true,
        },
        texture_content_properties = {
            TextureId = true,
            TextureID = true,
            TextureContent = true,
        },
        base_schema = {
            Scale = "Vector3",
            Offset = "Vector3",
            VertexColor = "Vector3",
        },
        special_schema = {
            Scale = "Vector3",
            Offset = "Vector3",
            VertexColor = "Vector3",
            MeshType = "MeshType",
            MeshId = "ContentId",
            MeshContent = "Content",
            TextureId = "ContentId",
            TextureContent = "Content",
        },
    },
    surface_appearance = {
        semantics = runtime_require("surface_appearance.lua"),
        alpha_names = {
            [0] = "Overlay",
            [1] = "Transparency",
            [2] = "TintMask",
            [3] = "Opaque",
        },
        resample_names = {
            [0] = "Default",
            [1] = "Pixelated",
        },
        map_properties = {
            ColorMap = {
                resolved = "color_map",
                content = "color_map_content",
                legacy = "legacy_color_map",
                content_property = "ColorMapContent",
            },
            NormalMap = {
                resolved = "normal_map",
                content = "normal_map_content",
                legacy = "legacy_normal_map",
                content_property = "NormalMapContent",
            },
            RoughnessMap = {
                resolved = "roughness_map",
                content = "roughness_map_content",
                legacy = "legacy_roughness_map",
                content_property = "RoughnessMapContent",
            },
            MetalnessMap = {
                resolved = "metalness_map",
                content = "metalness_map_content",
                legacy = "legacy_metalness_map",
                content_property = "MetalnessMapContent",
            },
        },
        schema = {
            AlphaMode = "AlphaMode",
            Color = "Color3",
            ColorMap = "ContentId",
            ColorMapContent = "Content",
            EmissiveMaskContent = "Content",
            EmissiveStrength = "number",
            EmissiveTint = "Color3",
            MetalnessMap = "ContentId",
            MetalnessMapContent = "Content",
            NormalMap = "ContentId",
            NormalMapContent = "Content",
            ResampleMode = "ResamplerMode",
            RoughnessMap = "ContentId",
            RoughnessMapContent = "Content",
        },
    },
}

local ATMOSPHERE_NUMBER_RANGES = {
    Density = { 0, 1 },
    Offset = { -1, 1 },
    Haze = { 0, 10 },
    Glare = { 0, 10 },
}

local ATMOSPHERE_COLOR_PROPERTIES = {
    Color = true,
    Decay = true,
}

local sync_effective_lighting_children
local LIGHTING_CHILD_FIELDS = {
    ColorCorrectionEffect = { "color_correction", "Enabled", "Brightness", "Contrast", "Saturation", "TintColor" },
    BloomEffect = { "bloom", "Enabled", "Intensity", "Size", "Threshold" },
    BlurEffect = { "blur", "Enabled", "Size" },
    SunRaysEffect = { "sun_rays", "Enabled", "Intensity", "Spread" },
    DepthOfFieldEffect = { "depth_of_field", "Enabled", "FarIntensity", "FocusDistance", "InFocusRadius", "NearIntensity" },
    Sky = { "sky", "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp", "SunTextureId", "MoonTextureId", "SunAngularSize", "MoonAngularSize", "StarCount", "CelestialBodiesShown", "SkyboxOrientation" },
}
local sync_effective_atmosphere

local function finite_component(value, fallback, minimum, maximum)
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric
        or numeric == math.huge or numeric == -math.huge then
        return nil
    end
    return clamp(numeric, minimum, maximum)
end

local function atmosphere_number(value, fallback, minimum, maximum, property_name)
    local numeric = finite_component(value, fallback, minimum, maximum)
    if numeric == nil then
        error("Atmosphere." .. property_name .. " must be numeric", 3)
    end
    return numeric
end

local function atmosphere_color(value, fallback, property_name)
    if type(value) ~= "table" then
        error("Atmosphere." .. property_name .. " must be a Color3-like value", 3)
    end
    fallback = fallback or { 1, 1, 1 }
    local r = finite_component(value.r or value.R or value[1], fallback[1], 0, 1)
    local g = finite_component(value.g or value.G or value[2], fallback[2], 0, 1)
    local b = finite_component(value.b or value.B or value[3], fallback[3], 0, 1)
    if r == nil or g == nil or b == nil then
        error("Atmosphere." .. property_name .. " must be a Color3-like value", 3)
    end
    return Color3.new(r, g, b)
end

local function atmosphere_color_equal(a, b)
    return type(a) == "table" and type(b) == "table"
        and (a.r or a.R or a[1]) == (b.r or b.R or b[1])
        and (a.g or a.G or a[2]) == (b.g or b.G or b[2])
        and (a.b or a.B or a[3]) == (b.b or b.B or b[3])
end

local function initialize_atmosphere_instance(instance, source_properties)
    if type(instance) ~= "table" or rawget(instance, "_class_name") ~= "Atmosphere" then
        return instance
    end
    local props = rawget(instance, "_properties")
    local source = type(source_properties) == "table" and source_properties or props

    for property_name, range in pairs(ATMOSPHERE_NUMBER_RANGES) do
        local fallback = RBX._ATMOSPHERE_DEFAULTS[property_name]
        local value = source[property_name]
        if value == nil then value = source[property_name:lower()] end
        if value == nil then value = fallback end
        props[property_name] = atmosphere_number(
            value, fallback, range[1], range[2], property_name)
        props[property_name:lower()] = nil
    end
    for property_name in pairs(ATMOSPHERE_COLOR_PROPERTIES) do
        local fallback = RBX._ATMOSPHERE_DEFAULTS[property_name]
        local value = source[property_name]
        if value == nil then value = source[property_name:lower()] end
        if value == nil then value = fallback end
        props[property_name] = atmosphere_color(value, fallback, property_name)
        props[property_name:lower()] = nil
    end
    return instance
end

local function new_signal(owner, name)
    return new_rbx_script_signal(owner, name)
end

local function signals_suppressed(instance)
    local datamodel = instance and rawget(instance, "_datamodel") or nil
    return not instance or rawget(instance, "_suppress_signals") or (datamodel and rawget(datamodel, "_suppress_signals"))
end

local function fire_signal(instance, name, ...)
    if signals_suppressed(instance) then
        return
    end
    local signals = rawget(instance, "_signals")
    local signal = signals and signals[name]
    if signal then
        fire_rbx_script_signal(signal, ...)
    end
end

local function get_signal(instance, name)
    instance._signals = instance._signals or {}
    local signal = instance._signals[name]
    if not signal then
        signal = new_signal(instance, name)
        instance._signals[name] = signal
    end
    return signal
end

local function get_property_signal(instance, property_name)
    instance._property_signals = instance._property_signals or {}
    property_name = tostring(property_name or "")
    local signal = instance._property_signals[property_name]
    if not signal then
        signal = new_signal(instance, tostring(property_name) .. "Changed")
        instance._property_signals[property_name] = signal
    end
    return signal
end

local function fire_property_changed(instance, property_name)
    if signals_suppressed(instance) then
        return
    end
    property_name = tostring(property_name or "")
    local property_signals = rawget(instance, "_property_signals")
    local property_signal = property_signals and property_signals[property_name]
    if property_signal then
        fire_rbx_script_signal(property_signal)
    end
    fire_signal(instance, "Changed", property_name)
end

local function cleanup_instance_signals(instance)
    if not instance then
        return
    end
    cleanup_rbx_script_signal_bucket(rawget(instance, "_signals"))
    cleanup_rbx_script_signal_bucket(rawget(instance, "_property_signals"))
    instance._signals = {}
    instance._property_signals = {}
end

function FACE_TEXTURE.is_instance(instance)
    return type(instance) == "table"
        and FACE_TEXTURE.classes[rawget(instance, "_class_name")] == true
end

function FACE_TEXTURE.is_descriptor_renderable(descriptor)
    return type(descriptor) == "table"
        and not RBX._is_empty_asset_reference(descriptor.texture)
        and (tonumber(descriptor.transparency) or 0) < 1
end

function FACE_TEXTURE.number(value, class_name, property_name,
        minimum, maximum, integer)
    local numeric = finite_component(value, nil, minimum, maximum)
    if numeric == nil then
        error(class_name .. "."
            .. tostring(property_name) .. " must be a finite number", 3)
    end
    if integer then numeric = math.floor(numeric) end
    return numeric
end

function FACE_TEXTURE.color(value, class_name, property_name)
    if type(value) ~= "table" then
        error(class_name .. "." .. property_name
            .. " must be a Color3-like value", 3)
    end
    local r = finite_component(value.r or value.R or value[1], nil, 0, 1)
    local g = finite_component(value.g or value.G or value[2], nil, 0, 1)
    local b = finite_component(value.b or value.B or value[3], nil, 0, 1)
    if r == nil or g == nil or b == nil then
        error(class_name .. "." .. property_name
            .. " must be a finite Color3-like value", 3)
    end
    return { r, g, b }
end

function FACE_TEXTURE.vector2(value, class_name, property_name)
    if type(value) ~= "table" then
        error(class_name .. "." .. property_name
            .. " must be a Vector2-like value", 3)
    end
    local x = finite_component(value.X or value.x or value[1], nil,
        -1000000, 1000000)
    local y = finite_component(value.Y or value.y or value[2], nil,
        -1000000, 1000000)
    if x == nil or y == nil then
        error(class_name .. "." .. property_name
            .. " must be a finite Vector2-like value", 3)
    end
    return x, y
end

function FACE_TEXTURE.face_name(value, class_name)
    if type(value) == "table" then
        value = value.Name or value.name or value.EnumItem
            or value.Value or value.value
    end
    local numeric = tonumber(value)
    if numeric ~= nil then
        numeric = math.floor(numeric)
        if numeric == tonumber(value) and RBX.FACE_ENUM[numeric] then
            return RBX.FACE_ENUM[numeric]
        end
    elseif type(value) == "string" then
        local tail = trim(value):match("([%a_]+)$")
        local resolved = tail
            and RBX.FACE_ENUM.aliases[string.lower(tail)] or nil
        if resolved then return resolved end
    end
    error(class_name .. ".Face must be a valid NormalId", 3)
end

function FACE_TEXTURE.content(value, class_name, property_name)
    if type(value) == "number"
        and (value ~= value or value == math.huge or value == -math.huge) then
        error(class_name .. "." .. property_name
            .. " must be a content reference", 3)
    end
    local normalized = normalize_asset_reference(value)
    if normalized ~= nil then return normalized end
    local empty = value == nil
        or (type(value) == "string" and trim(value) == "")
        or (type(value) == "number" and value <= 0)
        or (type(value) == "table" and next(value) == nil)
    if empty then return nil end
    error(class_name .. "." .. property_name
        .. " must be a content reference", 3)
end

function FACE_TEXTURE.sync_properties(instance)
    local descriptor = rawget(instance, "_face_texture_descriptor")
    if type(descriptor) ~= "table" then return end
    local props = rawget(instance, "_properties")
    props.Texture = descriptor.texture or ""
    props.Face = descriptor.face
    props.Color3 = {
        descriptor.color[1], descriptor.color[2], descriptor.color[3],
    }
    props.Transparency = descriptor.transparency
    props.ZIndex = descriptor.zindex
    props.Rotation = descriptor.rotation
    props.UVOffset = {
        X = descriptor.uv_offset_u, Y = descriptor.uv_offset_v,
    }
    props.UVScale = {
        X = descriptor.uv_scale_u, Y = descriptor.uv_scale_v,
    }
    if rawget(instance, "_class_name") == "Texture" then
        props.StudsPerTileU = descriptor.studs_per_tile_u
        props.StudsPerTileV = descriptor.studs_per_tile_v
        props.OffsetStudsU = descriptor.offset_studs_u
        props.OffsetStudsV = descriptor.offset_studs_v
    end
end

function FACE_TEXTURE.initialize(instance, source, authored_index)
    if not FACE_TEXTURE.is_instance(instance) then return instance end
    source = type(source) == "table" and source
        or rawget(instance, "_properties") or {}
    local descriptor = RBX._normalize_face_texture_descriptor(
        source, rawget(instance, "_class_name"), {
            name = rawget(instance, "_name"),
            referent = rawget(instance, "_referent") or nil,
            authored_index = authored_index,
        })
    descriptor.name = rawget(instance, "_name") or descriptor.name
    descriptor.referent = rawget(instance, "_referent")
        or descriptor.referent
    rawset(instance, "_face_texture_descriptor", descriptor)
    rawset(instance, "_face_texture_owner", false)
    FACE_TEXTURE.sync_properties(instance)
    return instance
end

function FACE_TEXTURE.public_value(instance, key)
    if not FACE_TEXTURE.is_instance(instance) then return false, nil end
    local descriptor = rawget(instance, "_face_texture_descriptor")
    if type(descriptor) ~= "table" then
        FACE_TEXTURE.initialize(instance)
        descriptor = rawget(instance, "_face_texture_descriptor")
    end
    if FACE_TEXTURE.content_properties[key] then
        return true, descriptor.texture or ""
    elseif key == "Face" then
        local enum = RBX.Enum and RBX.Enum.NormalId
        return true, enum and enum[descriptor.face] or descriptor.face
    elseif key == "Color3" or key == "Color" then
        return true, Color3.new(
            descriptor.color[1], descriptor.color[2], descriptor.color[3])
    elseif key == "Transparency" then
        return true, descriptor.transparency
    elseif key == "ZIndex" then
        return true, descriptor.zindex
    elseif key == "Rotation" then
        return true, descriptor.rotation
    elseif key == "UVOffset" then
        return true, { X = descriptor.uv_offset_u, Y = descriptor.uv_offset_v }
    elseif key == "UVScale" then
        return true, { X = descriptor.uv_scale_u, Y = descriptor.uv_scale_v }
    elseif rawget(instance, "_class_name") == "Texture" then
        if key == "StudsPerTileU" then
            return true, descriptor.studs_per_tile_u
        elseif key == "StudsPerTileV" then
            return true, descriptor.studs_per_tile_v
        elseif key == "StudsPerTile" then
            return true, descriptor.studs_per_tile_u
        elseif key == "OffsetStudsU" then
            return true, descriptor.offset_studs_u
        elseif key == "OffsetStudsV" then
            return true, descriptor.offset_studs_v
        end
    end
    return false, nil
end

function FACE_TEXTURE.mark_part(core, owner, texture_layer_descriptor)
    if owner and core
        and type(core._mark_runtime_part_face_textures_dirty) == "function" then
        core:_mark_runtime_part_face_textures_dirty(
            owner, texture_layer_descriptor)
    end
end

function FACE_TEXTURE.mark_owner(instance, texture_layer_descriptor)
    FACE_TEXTURE.mark_part(
        rawget(instance, "_core"),
        rawget(instance, "_face_texture_owner"),
        texture_layer_descriptor)
end

function FACE_TEXTURE.apply_write(instance, key, value)
    if not FACE_TEXTURE.is_instance(instance) then return false end
    local descriptor = rawget(instance, "_face_texture_descriptor")
    if type(descriptor) ~= "table" then
        FACE_TEXTURE.initialize(instance)
        descriptor = rawget(instance, "_face_texture_descriptor")
    end
    local class_name = rawget(instance, "_class_name")
    local was_renderable = FACE_TEXTURE.is_descriptor_renderable(descriptor)
    local changed = false

    if FACE_TEXTURE.content_properties[key] then
        local normalized = FACE_TEXTURE.content(value, class_name, key)
        if descriptor.texture ~= normalized then
            descriptor.texture = normalized
            changed = true
        end
    elseif key == "Face" then
        local normalized = FACE_TEXTURE.face_name(value, class_name)
        if descriptor.face ~= normalized then
            descriptor.face = normalized
            changed = true
        end
    elseif key == "Color3" or key == "Color" then
        local normalized = FACE_TEXTURE.color(value, class_name, key)
        local color = descriptor.color
        if color[1] ~= normalized[1] or color[2] ~= normalized[2]
            or color[3] ~= normalized[3] then
            descriptor.color = normalized
            changed = true
        end
    elseif key == "Transparency" then
        local normalized = FACE_TEXTURE.number(
            value, class_name, key, 0, 1)
        if descriptor.transparency ~= normalized then
            descriptor.transparency = normalized
            changed = true
        end
    elseif key == "ZIndex" then
        local normalized = FACE_TEXTURE.number(
            value, class_name, key, -10000, 10000, true)
        if descriptor.zindex ~= normalized then
            descriptor.zindex = normalized
            changed = true
        end
    elseif key == "Rotation" then
        local normalized = FACE_TEXTURE.number(
            value, class_name, key, -1000000, 1000000)
        if descriptor.rotation ~= normalized then
            descriptor.rotation = normalized
            changed = true
        end
    elseif key == "UVOffset" or key == "UVScale" then
        local x, y = FACE_TEXTURE.vector2(
            value, class_name, key)
        local field_u = key == "UVScale" and "uv_scale_u" or "uv_offset_u"
        local field_v = key == "UVScale" and "uv_scale_v" or "uv_offset_v"
        if descriptor[field_u] ~= x or descriptor[field_v] ~= y then
            descriptor[field_u], descriptor[field_v] = x, y
            changed = true
        end
    elseif class_name == "Texture" then
        if key == "StudsPerTileU" or key == "StudsPerTileV" then
            local normalized = FACE_TEXTURE.number(
                value, class_name, key, 0.001, 1000000)
            local field = key == "StudsPerTileU"
                and "studs_per_tile_u" or "studs_per_tile_v"
            if descriptor[field] ~= normalized then
                descriptor[field] = normalized
                changed = true
            end
        elseif key == "StudsPerTile" then
            local normalized = FACE_TEXTURE.number(
                value, class_name, key, 0.001, 1000000)
            if descriptor.studs_per_tile_u ~= normalized
                or descriptor.studs_per_tile_v ~= normalized then
                descriptor.studs_per_tile_u = normalized
                descriptor.studs_per_tile_v = normalized
                changed = true
            end
        elseif key == "OffsetStudsU" or key == "OffsetStudsV" then
            local normalized = FACE_TEXTURE.number(
                value, class_name, key, -1000000, 1000000)
            local field = key == "OffsetStudsU"
                and "offset_studs_u" or "offset_studs_v"
            if descriptor[field] ~= normalized then
                descriptor[field] = normalized
                changed = true
            end
        else
            return false
        end
    else
        return false
    end

    if not changed then return true end
    FACE_TEXTURE.sync_properties(instance)
    fire_property_changed(instance, key)
    if was_renderable or FACE_TEXTURE.is_descriptor_renderable(descriptor) then
        FACE_TEXTURE.mark_owner(instance,
            FACE_TEXTURE.content_properties[key] and descriptor or nil)
    end
    return true
end

function FACE_TEXTURE.detach(instance, suppress_dirty)
    local descriptor = rawget(instance, "_face_texture_descriptor")
    local owner = rawget(instance, "_face_texture_owner")
    if not owner or type(descriptor) ~= "table" then
        rawset(instance, "_face_texture_owner", false)
        return false
    end
    local list = owner.FaceTextures
    if type(list) == "table" then
        for index = #list, 1, -1 do
            if list[index] == descriptor then
                table.remove(list, index)
                break
            end
        end
    end
    if descriptor._facade_instance == instance then
        descriptor._facade_instance = nil
    end
    if descriptor._owner_part == owner then
        descriptor._owner_part = nil
    end
    rawset(instance, "_face_texture_owner", false)
    if not suppress_dirty and FACE_TEXTURE.is_descriptor_renderable(descriptor) then
        FACE_TEXTURE.mark_part(rawget(instance, "_core"), owner)
    end
    return true
end

function FACE_TEXTURE.bind(instance, owner, descriptor)
    rawset(instance, "_face_texture_descriptor", descriptor)
    rawset(instance, "_face_texture_owner", owner or false)
    descriptor._facade_instance = instance
    descriptor._owner_part = owner
    descriptor.name = rawget(instance, "_name") or descriptor.name
    descriptor.referent = rawget(instance, "_referent")
        or descriptor.referent
    FACE_TEXTURE.sync_properties(instance)
end

function FACE_TEXTURE.attach(instance, parent, suppress_dirty)
    local owner = parent and rawget(parent, "_core_handle") or nil
    if not owner or owner._destroyed then return false end
    local descriptor = rawget(instance, "_face_texture_descriptor")
    if type(descriptor) ~= "table" then
        FACE_TEXTURE.initialize(instance)
        descriptor = rawget(instance, "_face_texture_descriptor")
    end
    if rawget(instance, "_face_texture_owner") == owner then return false end
    if rawget(instance, "_face_texture_owner") then
        FACE_TEXTURE.detach(instance, suppress_dirty)
    end
    owner.FaceTextures = owner.FaceTextures or {}
    owner.FaceTextures[#owner.FaceTextures + 1] = descriptor
    FACE_TEXTURE.bind(instance, owner, descriptor)
    if not suppress_dirty and FACE_TEXTURE.is_descriptor_renderable(descriptor) then
        FACE_TEXTURE.mark_owner(instance)
    end
    return true
end

function FACE_TEXTURE.reparent(instance, new_parent)
    if not FACE_TEXTURE.is_instance(instance) then return end
    FACE_TEXTURE.detach(instance, false)
    FACE_TEXTURE.attach(instance, new_parent,
        new_parent and rawget(new_parent,
            "_suppress_face_texture_dirty") == true)
end

function FACE_TEXTURE.find_unbound_descriptor(owner, wanted, fallback_index)
    local list = owner and owner.FaceTextures or {}
    local wanted_referent = wanted and wanted.referent
    if wanted_referent ~= nil then
        for index = 1, #list do
            local descriptor = list[index]
            if descriptor and descriptor.referent == wanted_referent
                and descriptor._facade_instance == nil then
                return descriptor
            end
        end
    end
    local wanted_index = wanted and wanted.authored_index or fallback_index
    if wanted_index ~= nil then
        for index = 1, #list do
            local descriptor = list[index]
            if descriptor and descriptor.authored_index == wanted_index
                and descriptor._facade_instance == nil then
                return descriptor
            end
        end
    end
    for index = 1, #list do
        local descriptor = list[index]
        if descriptor and descriptor._facade_instance == nil
            and descriptor.class_name == wanted.class_name then
            return descriptor
        end
    end
    return nil
end

function FACE_TEXTURE.bind_promoted_children(parent)
    local owner = parent and rawget(parent, "_core_handle") or nil
    if not owner or owner._destroyed then return end
    for child_index = 1, #(rawget(parent, "_children") or {}) do
        local child = parent._children[child_index]
        if FACE_TEXTURE.is_instance(child) then
            local wanted = rawget(child, "_face_texture_descriptor")
            local descriptor = FACE_TEXTURE.find_unbound_descriptor(
                owner, wanted, child_index)
            if descriptor then
                FACE_TEXTURE.bind(child, owner, descriptor)
            else
                FACE_TEXTURE.attach(child, parent, true)
                if FACE_TEXTURE.is_descriptor_renderable(wanted) then
                    local datamodel = rawget(parent, "_datamodel")
                    datamodel._face_texture_promotion_dirty_parts =
                        datamodel._face_texture_promotion_dirty_parts or {}
                    datamodel._face_texture_promotion_dirty_parts[owner] = true
                end
            end
        end
    end
end

function FACE_TEXTURE.flush_promotion_dirty(datamodel)
    local dirty = rawget(datamodel, "_face_texture_promotion_dirty_parts")
    rawset(datamodel, "_face_texture_promotion_dirty_parts", nil)
    local core = rawget(datamodel, "_core")
    if not dirty or not core
        or type(core._mark_runtime_part_face_textures_dirty) ~= "function" then
        return
    end
    for owner in pairs(dirty) do
        core:_mark_runtime_part_face_textures_dirty(owner)
    end
end

-- SurfaceAppearance is a real direct MeshPart child in the public tree, while
-- the renderer consumes one value-owned descriptor flattened onto the core
-- part. Malformed files may contain duplicates, native/parser order makes the
-- first direct child authoritative and leaves every later child dormant
function FACE_TEXTURE.surface_appearance.is_instance(instance)
    return type(instance) == "table"
        and rawget(instance, "_class_name") == "SurfaceAppearance"
end

function FACE_TEXTURE.surface_appearance.source_value(source, key)
    if type(source) ~= "table" then return nil end
    local value = source[key]
    if value == nil and type(source.properties) == "table" then
        value = source.properties[key]
    end
    return value
end

function FACE_TEXTURE.surface_appearance.refresh_map(descriptor, name, definition)
    local semantics = FACE_TEXTURE.surface_appearance.semantics
    local properties = descriptor.properties
    local content = semantics.normalize_asset_reference(
        descriptor[definition.content]
            or properties[definition.content_property])
    local legacy = semantics.normalize_asset_reference(
        descriptor[definition.legacy] or properties[name])
    if content == nil and legacy == nil then
        -- Normalized semantic descriptors do not retain the source property
        -- treat their sole effective reference as the legacy/public map value
        legacy = semantics.normalize_asset_reference(
            descriptor[definition.resolved])
    end
    descriptor[definition.content] = content
    descriptor[definition.legacy] = legacy
    descriptor[definition.resolved] = content or legacy
    properties[definition.content_property] = content
    properties[name] = legacy
end

function FACE_TEXTURE.surface_appearance.canonical_descriptor(
        source, instance, authored_index)
    source = type(source) == "table" and source or {}
    local descriptor
    if source.class_name == "SurfaceAppearance"
        or source._surface_semantics_version ~= nil
        or source.color_map ~= nil
        or source.color_map_content ~= nil
        or source.legacy_color_map ~= nil then
        descriptor = RBX._clone_surface_appearance_descriptor(source)
    elseif type(RBX._build_surface_appearance_descriptor) == "function" then
        descriptor = RBX._build_surface_appearance_descriptor(
            source, authored_index)
    end
    descriptor = type(descriptor) == "table" and descriptor or {}
    descriptor.properties = type(descriptor.properties) == "table"
        and descriptor.properties or {}
    descriptor.class_name = "SurfaceAppearance"
    descriptor.name = rawget(instance, "_name")
        or descriptor.name or source.Name or "SurfaceAppearance"
    descriptor.referent = rawget(instance, "_referent")
        or descriptor.referent or source.Referent
    descriptor.source_index = descriptor.source_index
        or (authored_index and math.max(1, math.floor(
            tonumber(authored_index) or 1)))

    for name, definition in pairs(
            FACE_TEXTURE.surface_appearance.map_properties) do
        FACE_TEXTURE.surface_appearance.refresh_map(
            descriptor, name, definition)
    end

    local semantics = FACE_TEXTURE.surface_appearance.semantics
    local normalized = semantics.normalize_descriptor(descriptor)
    local properties = descriptor.properties
    descriptor.alpha_mode = normalized.alpha_mode
    descriptor.raw_alpha_mode = descriptor.raw_alpha_mode
        or properties.AlphaMode or normalized.alpha_mode
    properties.AlphaMode = descriptor.raw_alpha_mode
    descriptor.color = {
        normalized.color[1], normalized.color[2], normalized.color[3],
    }
    properties.Color = {
        descriptor.color[1], descriptor.color[2], descriptor.color[3],
    }
    descriptor.emissive_mask_content = semantics.normalize_asset_reference(
        descriptor.emissive_mask_content
            or properties.EmissiveMaskContent
            or descriptor.emissive_mask)
    descriptor.emissive_mask = descriptor.emissive_mask_content
    properties.EmissiveMaskContent = descriptor.emissive_mask_content
    descriptor.emissive_strength = normalized.emissive_strength
    properties.EmissiveStrength = descriptor.emissive_strength
    descriptor.emissive_tint = {
        normalized.emissive_tint[1], normalized.emissive_tint[2],
        normalized.emissive_tint[3],
    }
    properties.EmissiveTint = {
        descriptor.emissive_tint[1], descriptor.emissive_tint[2],
        descriptor.emissive_tint[3],
    }
    descriptor.resample_mode = normalized.resample_mode
    properties.ResampleMode = descriptor.resample_mode

    descriptor.texture_pack_content = semantics.normalize_asset_reference(
        descriptor.texture_pack_content or properties.TexturePackContent)
    descriptor.legacy_texture_pack = semantics.normalize_asset_reference(
        descriptor.legacy_texture_pack or properties.TexturePack)
    if descriptor.texture_pack_content == nil
        and descriptor.legacy_texture_pack == nil then
        descriptor.legacy_texture_pack = semantics.normalize_asset_reference(
            descriptor.texture_pack)
    end
    descriptor.texture_pack = descriptor.texture_pack_content
        or descriptor.legacy_texture_pack
    properties.TexturePackContent = descriptor.texture_pack_content
    properties.TexturePack = descriptor.legacy_texture_pack
    descriptor.texture_pack_metadata = descriptor.texture_pack_metadata
        or properties.TexturePackMetadata
    if descriptor.texture_pack_metadata ~= nil then
        descriptor.texture_pack_metadata = tostring(
            descriptor.texture_pack_metadata)
    end
    properties.TexturePackMetadata = descriptor.texture_pack_metadata
    return descriptor
end

function FACE_TEXTURE.surface_appearance.sync_properties(instance)
    local descriptor = rawget(instance, "_surface_appearance_descriptor")
    if type(descriptor) ~= "table" then return end
    local props = rawget(instance, "_properties")
    for name, definition in pairs(
            FACE_TEXTURE.surface_appearance.map_properties) do
        props[name] = descriptor[definition.legacy] or ""
        props[definition.content_property] =
            descriptor[definition.content] or ""
    end
    props.AlphaMode = descriptor.alpha_mode
    props.Color = {
        descriptor.color[1], descriptor.color[2], descriptor.color[3],
    }
    props.EmissiveMaskContent = descriptor.emissive_mask_content or ""
    props.EmissiveStrength = descriptor.emissive_strength
    props.EmissiveTint = {
        descriptor.emissive_tint[1], descriptor.emissive_tint[2],
        descriptor.emissive_tint[3],
    }
    props.ResampleMode = descriptor.resample_mode
    props.TexturePack = descriptor.legacy_texture_pack or ""
    props.TexturePackContent = descriptor.texture_pack_content or ""
    props.TexturePackMetadata = descriptor.texture_pack_metadata or ""
end

function FACE_TEXTURE.surface_appearance.initialize(
        instance, source, authored_index)
    if not FACE_TEXTURE.surface_appearance.is_instance(instance) then
        return instance
    end
    source = type(source) == "table" and source
        or rawget(instance, "_properties") or {}
    rawset(instance, "_surface_appearance_descriptor",
        FACE_TEXTURE.surface_appearance.canonical_descriptor(
            source, instance, authored_index))
    rawset(instance, "_surface_appearance_owner", false)
    FACE_TEXTURE.surface_appearance.sync_properties(instance)
    return instance
end

function FACE_TEXTURE.surface_appearance.enum_value(
        value, enum_name, names, class_name)
    local seen = nil
    while type(value) == "table" do
        seen = seen or {}
        if seen[value] then break end
        seen[value] = true
        value = value.Value or value.value or value.Name or value.name
            or value.EnumItem or value.enum_item
    end
    local numeric = tonumber(value)
    if numeric ~= nil and numeric == math.floor(numeric)
        and names[numeric] ~= nil then
        return numeric
    end
    if type(value) == "string" then
        local tail = trim(value):match("([%a_]+)$")
        tail = tail and tail:gsub("_", ""):lower() or nil
        for candidate, name in pairs(names) do
            if tail == name:lower() then return candidate end
        end
    end
    error(class_name .. "." .. enum_name
        .. " must be a valid " .. enum_name, 3)
end

function FACE_TEXTURE.surface_appearance.normalized_equal(a, b)
    if a == nil or b == nil then return a == b end
    for _, key in ipairs({
        "alpha_mode", "color_map", "normal_map", "roughness_map",
        "metalness_map", "emissive_mask", "emissive_strength",
        "resample_mode", "texture_pack", "texture_pack_metadata",
    }) do
        if a[key] ~= b[key] then return false end
    end
    for _, key in ipairs({ "color", "emissive_tint" }) do
        local av, bv = a[key] or {}, b[key] or {}
        if av[1] ~= bv[1] or av[2] ~= bv[2] or av[3] ~= bv[3] then
            return false
        end
    end
    return true
end

function FACE_TEXTURE.surface_appearance.renderer_equal(a, b)
    if a == nil or b == nil then return a == b end
    local semantics = FACE_TEXTURE.surface_appearance.semantics
    return FACE_TEXTURE.surface_appearance.normalized_equal(
        semantics.normalize_descriptor(a),
        semantics.normalize_descriptor(b))
end

function FACE_TEXTURE.surface_appearance.public_value(instance, key)
    if not FACE_TEXTURE.surface_appearance.is_instance(instance) then
        return false, nil
    end
    local descriptor = rawget(instance, "_surface_appearance_descriptor")
    if type(descriptor) ~= "table" then
        FACE_TEXTURE.surface_appearance.initialize(instance)
        descriptor = rawget(instance, "_surface_appearance_descriptor")
    end
    for name, definition in pairs(
            FACE_TEXTURE.surface_appearance.map_properties) do
        if key == name then
            return true, descriptor[definition.legacy] or ""
        elseif key == definition.content_property then
            return true, descriptor[definition.content] or ""
        end
    end
    if key == "AlphaMode" then
        local name = FACE_TEXTURE.surface_appearance.alpha_names[
            descriptor.alpha_mode]
        local enum = RBX.Enum and RBX.Enum.AlphaMode
        return true, enum and enum[name] or descriptor.alpha_mode
    elseif key == "Color" or key == "Color3" then
        return true, Color3.new(
            descriptor.color[1], descriptor.color[2], descriptor.color[3])
    elseif key == "EmissiveMaskContent" or key == "EmissiveMask" then
        return true, descriptor.emissive_mask_content or ""
    elseif key == "EmissiveStrength" then
        return true, descriptor.emissive_strength
    elseif key == "EmissiveTint" then
        return true, Color3.new(descriptor.emissive_tint[1],
            descriptor.emissive_tint[2], descriptor.emissive_tint[3])
    elseif key == "ResampleMode" then
        local name = FACE_TEXTURE.surface_appearance.resample_names[
            descriptor.resample_mode]
        local enum = RBX.Enum and RBX.Enum.ResamplerMode
        return true, enum and enum[name] or descriptor.resample_mode
    elseif key == "TexturePack" then
        return true, descriptor.legacy_texture_pack or ""
    elseif key == "TexturePackContent" then
        return true, descriptor.texture_pack_content or ""
    elseif key == "TexturePackMetadata" then
        return true, descriptor.texture_pack_metadata or ""
    end
    return false, nil
end

function FACE_TEXTURE.surface_appearance.mark_part(core, owner)
    if owner and core
        and type(core._mark_runtime_part_surface_appearance_dirty)
            == "function" then
        core:_mark_runtime_part_surface_appearance_dirty(owner)
    end
end

function FACE_TEXTURE.surface_appearance.mark_owner(instance)
    FACE_TEXTURE.surface_appearance.mark_part(
        rawget(instance, "_core"),
        rawget(instance, "_surface_appearance_owner"))
end

function FACE_TEXTURE.surface_appearance.apply_write(instance, key, value)
    if not FACE_TEXTURE.surface_appearance.is_instance(instance) then
        return false
    end
    local descriptor = rawget(instance, "_surface_appearance_descriptor")
    if type(descriptor) ~= "table" then
        FACE_TEXTURE.surface_appearance.initialize(instance)
        descriptor = rawget(instance, "_surface_appearance_descriptor")
    end
    local semantics = FACE_TEXTURE.surface_appearance.semantics
    local before = semantics.normalize_descriptor(descriptor)
    local changed = false

    for name, definition in pairs(
            FACE_TEXTURE.surface_appearance.map_properties) do
        local field
        if key == name then
            field = definition.legacy
        elseif key == definition.content_property then
            field = definition.content
        end
        if field then
            local normalized = FACE_TEXTURE.content(
                value, "SurfaceAppearance", key)
            if descriptor[field] ~= normalized then
                descriptor[field] = normalized
                descriptor.properties[key] = normalized
                changed = true
            end
            FACE_TEXTURE.surface_appearance.refresh_map(
                descriptor, name, definition)
            break
        end
    end

    if key == "AlphaMode" then
        local normalized = FACE_TEXTURE.surface_appearance.enum_value(
            value, key, FACE_TEXTURE.surface_appearance.alpha_names,
            "SurfaceAppearance")
        if descriptor.alpha_mode ~= normalized then
            descriptor.alpha_mode = normalized
            descriptor.raw_alpha_mode = normalized
            descriptor.properties.AlphaMode = normalized
            changed = true
        end
    elseif key == "Color" or key == "Color3" then
        local normalized = FACE_TEXTURE.color(
            value, "SurfaceAppearance", key)
        local old = descriptor.color
        if old[1] ~= normalized[1] or old[2] ~= normalized[2]
            or old[3] ~= normalized[3] then
            descriptor.color = normalized
            descriptor.properties.Color = {
                normalized[1], normalized[2], normalized[3],
            }
            changed = true
        end
    elseif key == "EmissiveMaskContent" or key == "EmissiveMask" then
        local normalized = FACE_TEXTURE.content(
            value, "SurfaceAppearance", key)
        if descriptor.emissive_mask_content ~= normalized then
            descriptor.emissive_mask_content = normalized
            descriptor.emissive_mask = normalized
            descriptor.properties.EmissiveMaskContent = normalized
            changed = true
        end
    elseif key == "EmissiveStrength" then
        local normalized = FACE_TEXTURE.number(
            value, "SurfaceAppearance", key, 0, math.huge)
        if descriptor.emissive_strength ~= normalized then
            descriptor.emissive_strength = normalized
            descriptor.properties.EmissiveStrength = normalized
            changed = true
        end
    elseif key == "EmissiveTint" then
        local normalized = FACE_TEXTURE.color(
            value, "SurfaceAppearance", key)
        local old = descriptor.emissive_tint
        if old[1] ~= normalized[1] or old[2] ~= normalized[2]
            or old[3] ~= normalized[3] then
            descriptor.emissive_tint = normalized
            descriptor.properties.EmissiveTint = {
                normalized[1], normalized[2], normalized[3],
            }
            changed = true
        end
    elseif key == "ResampleMode" then
        local normalized = FACE_TEXTURE.surface_appearance.enum_value(
            value, key, FACE_TEXTURE.surface_appearance.resample_names,
            "SurfaceAppearance")
        if descriptor.resample_mode ~= normalized then
            descriptor.resample_mode = normalized
            descriptor.properties.ResampleMode = normalized
            changed = true
        end
    elseif key == "TexturePack" or key == "TexturePackContent" then
        local field = key == "TexturePackContent"
            and "texture_pack_content" or "legacy_texture_pack"
        local normalized = FACE_TEXTURE.content(
            value, "SurfaceAppearance", key)
        if descriptor[field] ~= normalized then
            descriptor[field] = normalized
            descriptor.texture_pack = descriptor.texture_pack_content
                or descriptor.legacy_texture_pack
            descriptor.properties[key] = normalized
            changed = true
        end
    elseif key == "TexturePackMetadata" then
        local normalized = value == nil and nil or tostring(value)
        if normalized == "" then normalized = nil end
        if descriptor.texture_pack_metadata ~= normalized then
            descriptor.texture_pack_metadata = normalized
            descriptor.properties.TexturePackMetadata = normalized
            changed = true
        end
    end

    if not changed then
        -- a recognized map property can be an equal write. Unknown properties
        -- continue through the generic Instance storage path below
        for name, definition in pairs(
                FACE_TEXTURE.surface_appearance.map_properties) do
            if key == name or key == definition.content_property then
                return true
            end
        end
        if key == "AlphaMode" or key == "Color" or key == "Color3"
            or key == "EmissiveMaskContent" or key == "EmissiveMask"
            or key == "EmissiveStrength" or key == "EmissiveTint"
            or key == "ResampleMode" or key == "TexturePack"
            or key == "TexturePackContent"
            or key == "TexturePackMetadata" then
            return true
        end
        return false
    end

    FACE_TEXTURE.surface_appearance.sync_properties(instance)
    fire_property_changed(instance, key)
    local after = semantics.normalize_descriptor(descriptor)
    if not FACE_TEXTURE.surface_appearance.normalized_equal(before, after) then
        FACE_TEXTURE.surface_appearance.mark_owner(instance)
    end
    return true
end

function FACE_TEXTURE.surface_appearance.accepts_parent(parent)
    local owner = parent and rawget(parent, "_core_handle") or nil
    if type(owner) == "table" and not owner._destroyed
        and owner.ClassName == "MeshPart" then
        return owner
    end
    return nil
end

function FACE_TEXTURE.surface_appearance.apply_effective(parent, suppress_dirty)
    local owner = FACE_TEXTURE.surface_appearance.accepts_parent(parent)
    if not owner then return false, nil end
    local children = rawget(parent, "_children") or {}
    local selected = nil
    for index = 1, #children do
        local child = children[index]
        if FACE_TEXTURE.surface_appearance.is_instance(child)
            and rawget(child, "_destroyed") ~= true then
            if selected == nil then selected = child end
            if rawget(child, "_surface_appearance_owner") == owner then
                rawset(child, "_surface_appearance_owner", false)
            end
        end
    end

    local previous = owner.SurfaceAppearance
    local descriptor = nil
    if selected then
        descriptor = rawget(selected, "_surface_appearance_descriptor")
        if type(descriptor) ~= "table" then
            FACE_TEXTURE.surface_appearance.initialize(selected)
            descriptor = rawget(selected,
                "_surface_appearance_descriptor")
        end
        local previous_facade = owner._surface_appearance_facade
        local same_referent = type(previous) == "table"
            and previous.referent ~= nil
            and previous.referent == descriptor.referent
        if type(previous) == "table"
            and (previous_facade == selected
                or (previous_facade == nil and suppress_dirty
                    and (same_referent
                        or FACE_TEXTURE.surface_appearance.renderer_equal(
                            previous, descriptor)))) then
            descriptor = previous
            rawset(selected, "_surface_appearance_descriptor", descriptor)
            FACE_TEXTURE.surface_appearance.sync_properties(selected)
        end
        rawset(selected, "_surface_appearance_owner", owner)
    end
    owner.SurfaceAppearance = descriptor
    owner._surface_appearance_facade = selected
    local changed = not FACE_TEXTURE.surface_appearance.renderer_equal(
        previous, descriptor)
    if changed and not suppress_dirty then
        FACE_TEXTURE.surface_appearance.mark_part(
            rawget(parent, "_core"), owner)
    end
    return changed, owner
end

function FACE_TEXTURE.surface_appearance.reparent(
        instance, old_parent, new_parent)
    if not FACE_TEXTURE.surface_appearance.is_instance(instance) then return end
    rawset(instance, "_surface_appearance_owner", false)
    if old_parent then
        FACE_TEXTURE.surface_appearance.apply_effective(old_parent,
            rawget(old_parent,
                "_suppress_surface_appearance_dirty") == true)
    end
    if new_parent then
        FACE_TEXTURE.surface_appearance.apply_effective(new_parent,
            rawget(new_parent,
                "_suppress_surface_appearance_dirty") == true)
    end
end

function FACE_TEXTURE.surface_appearance.detach(instance)
    if not FACE_TEXTURE.surface_appearance.is_instance(instance) then
        return false
    end
    local owner = rawget(instance, "_surface_appearance_owner")
    rawset(instance, "_surface_appearance_owner", false)
    if owner and owner._surface_appearance_facade == instance then
        owner._surface_appearance_facade = nil
    end
    return owner and true or false
end

function FACE_TEXTURE.surface_appearance.bind_promoted_children(parent)
    local changed, owner =
        FACE_TEXTURE.surface_appearance.apply_effective(parent, true)
    if changed and owner then
        local datamodel = rawget(parent, "_datamodel")
        datamodel._surface_appearance_promotion_dirty_parts =
            datamodel._surface_appearance_promotion_dirty_parts or {}
        datamodel._surface_appearance_promotion_dirty_parts[owner] = true
    end
end

function FACE_TEXTURE.surface_appearance.flush_promotion_dirty(datamodel)
    local dirty = rawget(datamodel,
        "_surface_appearance_promotion_dirty_parts")
    rawset(datamodel, "_surface_appearance_promotion_dirty_parts", nil)
    local core = rawget(datamodel, "_core")
    if not dirty or not core
        or type(core._mark_runtime_part_surface_appearance_dirty)
            ~= "function" then
        return
    end
    for owner in pairs(dirty) do
        core:_mark_runtime_part_surface_appearance_dirty(owner)
    end
end

-- DataModelMesh children are real public Instances, while the render core keeps
-- their effective state flattened on the direct BasePart.  this bridge owns the
-- conversion in both directions so runtime edits cannot leave a visually inert
-- SpecialMesh/BlockMesh/CylinderMesh facade behind
function FACE_TEXTURE.legacy_mesh.is_instance(instance)
    return type(instance) == "table"
        and FACE_TEXTURE.legacy_mesh.classes[
            rawget(instance, "_class_name")] == true
end

function FACE_TEXTURE.legacy_mesh.vector3(value, class_name, property_name,
        default_x, default_y, default_z)
    if value == nil then
        return Vector3.new(default_x, default_y, default_z)
    end
    if type(value) ~= "table" then
        error(class_name .. "." .. property_name
            .. " must be a Vector3-like value", 3)
    end
    local function component(primary, secondary, ordinal)
        local raw = value[primary]
        if raw == nil then raw = value[secondary] end
        if raw == nil then raw = value[ordinal] end
        local numeric = tonumber(raw)
        if numeric == nil or numeric ~= numeric
            or numeric == math.huge or numeric == -math.huge then
            error(class_name .. "." .. property_name
                .. " must be a finite Vector3-like value", 4)
        end
        return numeric
    end
    return Vector3.new(
        component("X", "x", 1),
        component("Y", "y", 2),
        component("Z", "z", 3))
end

function FACE_TEXTURE.legacy_mesh.vector_equal(a, b)
    if a == nil or b == nil then return a == b end
    return type(a) == "table" and type(b) == "table"
        and (a.x or a.X or a.r or a.R or a[1])
            == (b.x or b.X or b.r or b.R or b[1])
        and (a.y or a.Y or a.g or a.G or a[2])
            == (b.y or b.Y or b.g or b.G or b[2])
        and (a.z or a.Z or a.b or a.B or a[3])
            == (b.z or b.Z or b.b or b.B or b[3])
end

function FACE_TEXTURE.legacy_mesh.plain_vector(value)
    return value and {
        x = value.x or value.X or value[1] or 0,
        y = value.y or value.Y or value[2] or 0,
        z = value.z or value.Z or value[3] or 0,
    } or nil
end

function FACE_TEXTURE.legacy_mesh.render_color(value)
    if not value then return nil end
    local x = tonumber(value.x or value.X or value[1]) or 1
    local y = tonumber(value.y or value.Y or value[2]) or 1
    local z = tonumber(value.z or value.Z or value[3]) or 1
    -- VertexColor is a Vector3/Color3-component multiplier. preserve the
    -- renderer's saturating display behavior for overbright authored values;
    -- they are not legacy 0..255 byte colors
    return { r = clamp(x, 0, 1), g = clamp(y, 0, 1), b = clamp(z, 0, 1) }
end

function FACE_TEXTURE.legacy_mesh.color_is_white(value)
    return type(value) ~= "table"
        or ((value.r or value.R or value.x or value.X or value[1] or 1) == 1
            and (value.g or value.G or value.y or value.Y or value[2] or 1) == 1
            and (value.b or value.B or value.z or value.Z or value[3] or 1) == 1)
end

function FACE_TEXTURE.legacy_mesh.content(value, class_name, property_name)
    return FACE_TEXTURE.content(value, class_name, property_name)
end

function FACE_TEXTURE.legacy_mesh.mesh_type(value, class_name)
    if type(value) == "table" then
        value = value.Value or value.value or value.Name or value.name
            or value.EnumItem or value.enumItem or value.Id or value.id
    end
    if type(value) == "string" then
        value = trim(value):gsub("^Enum%.MeshType%.", "")
    end
    local numeric = tonumber(value)
    if numeric ~= nil and numeric ~= math.floor(numeric) then
        error(class_name .. ".MeshType must be a valid MeshType", 3)
    end
    local normalized = normalize_special_mesh_type(value, nil)
    if normalized == nil then
        error(class_name .. ".MeshType must be a valid MeshType", 3)
    end
    return normalized
end

function FACE_TEXTURE.legacy_mesh.mesh_type_value(name)
    local enum = RBX.Enum and RBX.Enum.MeshType
    return enum and enum[name] or name
end

function FACE_TEXTURE.legacy_mesh.initialize(instance, source,
        coerce_serialized_mesh_type)
    if not FACE_TEXTURE.legacy_mesh.is_instance(instance) then
        return instance
    end
    source = type(source) == "table" and source
        or rawget(instance, "_properties") or {}
    local props = rawget(instance, "_properties")
    local class_name = rawget(instance, "_class_name")
    local scale = source.Scale
    if scale == nil then scale = source.scale end
    local offset = source.Offset
    if offset == nil then offset = source.offset end
    local vertex_color = source.VertexColor
    if vertex_color == nil then vertex_color = source.vertexcolor end
    props.Scale = FACE_TEXTURE.legacy_mesh.vector3(
        scale, class_name, "Scale", 1, 1, 1)
    props.Offset = FACE_TEXTURE.legacy_mesh.vector3(
        offset, class_name, "Offset", 0, 0, 0)
    props.VertexColor = FACE_TEXTURE.legacy_mesh.vector3(
        vertex_color, class_name, "VertexColor", 1, 1, 1)
    props.scale, props.offset, props.vertexcolor = nil, nil, nil

    if class_name == "SpecialMesh" then
        local mesh_type = source.MeshType
        if mesh_type == nil then mesh_type = source.meshtype end
        if mesh_type == nil then
            props.MeshType = "Head"
        elseif coerce_serialized_mesh_type
            and normalize_special_mesh_type(mesh_type, nil) == nil then
            -- Roblox's deserializer coerces malformed/out-of-range serialized
            -- MeshType values to SpecialMesh's native Head default. keep the
            -- public property setter strict, this flag is used only while
            -- promoting already-decoded place-file source nodes
            props.MeshType = "Head"
        else
            props.MeshType = FACE_TEXTURE.legacy_mesh.mesh_type(
                mesh_type, class_name)
        end
        local mesh_id = source.MeshContent or source.MeshId
            or source.MeshID or source.meshcontent or source.meshid
        local texture_id = source.TextureContent or source.TextureId
            or source.TextureID or source.texturecontent or source.textureid
        props.MeshId = FACE_TEXTURE.legacy_mesh.content(
            mesh_id, class_name, "MeshId") or ""
        props.TextureId = FACE_TEXTURE.legacy_mesh.content(
            texture_id, class_name, "TextureId") or ""
        props.MeshID, props.MeshContent, props.meshid, props.meshcontent =
            nil, nil, nil, nil
        props.TextureID, props.TextureContent, props.textureid,
            props.texturecontent = nil, nil, nil, nil
    end
    rawset(instance, "_legacy_mesh_owner", false)
    return instance
end

function FACE_TEXTURE.legacy_mesh.public_value(instance, key)
    if not FACE_TEXTURE.legacy_mesh.is_instance(instance) then
        return false, nil
    end
    local props = rawget(instance, "_properties")
    if key == "Scale" or key == "Offset" or key == "VertexColor" then
        return true, props[key]
    end
    local class_name = rawget(instance, "_class_name")
    if class_name == "SpecialMesh" then
        if key == "MeshType" then
            return true, FACE_TEXTURE.legacy_mesh.mesh_type_value(props.MeshType)
        elseif FACE_TEXTURE.legacy_mesh.mesh_content_properties[key] then
            return true, props.MeshId or ""
        elseif FACE_TEXTURE.legacy_mesh.texture_content_properties[key] then
            return true, props.TextureId or ""
        end
    end
    return false, nil
end

function FACE_TEXTURE.legacy_mesh.accepts_parent(parent)
    local owner = parent and rawget(parent, "_core_handle") or nil
    if not owner or owner._destroyed then return nil end
    local class_name = owner.ClassName
    if class_name == "MeshPart" or class_name == "UnionOperation"
        or class_name == "PartOperation" or class_name == "NegateOperation" then
        return nil
    end
    return owner
end

function FACE_TEXTURE.legacy_mesh.effective_children(parent)
    local selected
    local owner = FACE_TEXTURE.legacy_mesh.accepts_parent(parent)
    for index = 1, #(parent and rawget(parent, "_children") or {}) do
        local child = parent._children[index]
        local class_name = rawget(child, "_class_name")
        if FACE_TEXTURE.legacy_mesh.classes[class_name] then
            rawset(child, "_legacy_mesh_owner", owner or false)
            -- Studio resolves malformed multiple-child Parts by authored order,
            -- not by a concrete-class priority: the last DataModelMesh child owns
            -- the visual. keep inactive children as facades so reparenting or
            -- destruction can immediately promote the new last child
            selected = child
        end
    end
    return owner, selected
end

function FACE_TEXTURE.legacy_mesh.apply_effective(parent, suppress_dirty)
    local owner, selected = FACE_TEXTURE.legacy_mesh.effective_children(parent)
    if not owner then return false end
    local selected_props = selected and rawget(selected, "_properties") or nil
    local selected_class = selected and rawget(selected, "_class_name") or nil
    local special = selected_class == "SpecialMesh"
    local cylinder = selected_class == "CylinderMesh"
    local block = selected_class == "BlockMesh"
    local mesh_owner = selected_class
    local mesh_id = special and selected_props.MeshId ~= ""
        and selected_props.MeshId or nil
    local texture_id = special and selected_props.TextureId ~= ""
        and selected_props.TextureId or nil
    local special_type = special and selected_props.MeshType
        or cylinder and "Cylinder" or nil
    local special_scale = (special or cylinder)
        and FACE_TEXTURE.legacy_mesh.plain_vector(selected_props.Scale) or nil
    local special_offset = (special or cylinder)
        and FACE_TEXTURE.legacy_mesh.plain_vector(selected_props.Offset) or nil
    local special_color = (special or cylinder)
        and FACE_TEXTURE.legacy_mesh.render_color(selected_props.VertexColor) or nil
    local block_scale = block
        and FACE_TEXTURE.legacy_mesh.plain_vector(selected_props.Scale) or nil
    local block_offset = block
        and FACE_TEXTURE.legacy_mesh.plain_vector(selected_props.Offset) or nil
    local block_color = block
        and FACE_TEXTURE.legacy_mesh.render_color(selected_props.VertexColor) or nil
    if FACE_TEXTURE.legacy_mesh.color_is_white(block_color) then
        block_color = nil
    end

    local source_changed = owner.MeshOwner ~= mesh_owner
        or owner.MeshId ~= mesh_id
        or owner.SpecialMeshType ~= special_type
    local changed = source_changed
        or owner.TextureId ~= texture_id
        or owner.TextureContent ~= texture_id
        or not FACE_TEXTURE.legacy_mesh.vector_equal(
            owner.SpecialMeshScale, special_scale)
        or not FACE_TEXTURE.legacy_mesh.vector_equal(
            owner.SpecialMeshOffset, special_offset)
        or not FACE_TEXTURE.legacy_mesh.vector_equal(
            owner.SpecialMeshVertexColor, special_color)
        or not FACE_TEXTURE.legacy_mesh.vector_equal(
            owner.BlockMeshScale, block_scale)
        or not FACE_TEXTURE.legacy_mesh.vector_equal(
            owner.BlockMeshOffset, block_offset)
        or not FACE_TEXTURE.legacy_mesh.vector_equal(
            owner.MeshVertexColor, block_color)
    if not changed then return false end

    -- only scale/offset writes can reuse a retained FileMesh's immutable UVs
    -- and appearance. all other edits retain the normal property invalidation
    local affine_only = special and not source_changed
        and owner.TextureId == texture_id and owner.TextureContent == texture_id
        and FACE_TEXTURE.legacy_mesh.vector_equal(owner.SpecialMeshVertexColor, special_color)
        and FACE_TEXTURE.legacy_mesh.vector_equal(owner.BlockMeshScale, block_scale)
        and FACE_TEXTURE.legacy_mesh.vector_equal(owner.BlockMeshOffset, block_offset)
        and FACE_TEXTURE.legacy_mesh.vector_equal(owner.MeshVertexColor, block_color)

    owner.MeshOwner = mesh_owner
    owner.MeshId = mesh_id
    owner.TextureId = texture_id
    owner.TextureContent = texture_id
    owner.SpecialMeshType = special_type
    owner.SpecialMeshScale = special_scale
    owner.SpecialMeshOffset = special_offset
    owner.SpecialMeshVertexColor = special_color
    owner.BlockMeshScale = block_scale
    owner.BlockMeshOffset = block_offset
    owner.MeshVertexColor = block_color
    owner._value_cache = nil
    if not suppress_dirty then
        local core = rawget(parent, "_core")
        if core and type(core._mark_runtime_part_legacy_mesh_dirty) == "function" then
            core:_mark_runtime_part_legacy_mesh_dirty(owner, source_changed, affine_only)
        end
    end
    return true, source_changed
end

function FACE_TEXTURE.legacy_mesh.reparent(instance, old_parent, new_parent)
    if not FACE_TEXTURE.legacy_mesh.is_instance(instance) then return end
    rawset(instance, "_legacy_mesh_owner", false)
    if old_parent then
        FACE_TEXTURE.legacy_mesh.apply_effective(old_parent,
            rawget(old_parent, "_suppress_legacy_mesh_dirty") == true)
    end
    if new_parent and new_parent ~= old_parent then
        FACE_TEXTURE.legacy_mesh.apply_effective(new_parent,
            rawget(new_parent, "_suppress_legacy_mesh_dirty") == true)
    end
end

function FACE_TEXTURE.legacy_mesh.mark_owner(instance)
    local owner = rawget(instance, "_legacy_mesh_owner")
    local parent = rawget(instance, "_parent")
    if owner and parent then
        FACE_TEXTURE.legacy_mesh.apply_effective(parent,
            rawget(parent, "_suppress_legacy_mesh_dirty") == true)
    end
end

function FACE_TEXTURE.legacy_mesh.apply_write(instance, key, value)
    if not FACE_TEXTURE.legacy_mesh.is_instance(instance) then return false end
    local class_name = rawget(instance, "_class_name")
    local props = rawget(instance, "_properties")
    local canonical, normalized
    if key == "Scale" or key == "Offset" or key == "VertexColor" then
        canonical = key
        local default = key == "Offset" and 0 or 1
        normalized = FACE_TEXTURE.legacy_mesh.vector3(
            value, class_name, key, default, default, default)
    elseif key == "MeshType" then
        if class_name ~= "SpecialMesh" then
            error(class_name .. ".MeshType is not a valid property", 3)
        end
        canonical = "MeshType"
        normalized = FACE_TEXTURE.legacy_mesh.mesh_type(value, class_name)
    elseif FACE_TEXTURE.legacy_mesh.mesh_content_properties[key] then
        if class_name ~= "SpecialMesh" then
            error(class_name .. "." .. key .. " is not a valid property", 3)
        end
        canonical = "MeshId"
        normalized = FACE_TEXTURE.legacy_mesh.content(
            value, class_name, key) or ""
    elseif FACE_TEXTURE.legacy_mesh.texture_content_properties[key] then
        if class_name ~= "SpecialMesh" then
            error(class_name .. "." .. key .. " is not a valid property", 3)
        end
        canonical = "TextureId"
        normalized = FACE_TEXTURE.legacy_mesh.content(
            value, class_name, key) or ""
    else
        return false
    end

    local unchanged
    if canonical == "Scale" or canonical == "Offset"
        or canonical == "VertexColor" then
        unchanged = FACE_TEXTURE.legacy_mesh.vector_equal(
            props[canonical], normalized)
    else
        unchanged = props[canonical] == normalized
    end
    if unchanged then return true end
    props[canonical] = normalized
    fire_property_changed(instance, canonical)
    FACE_TEXTURE.legacy_mesh.mark_owner(instance)
    return true
end

function FACE_TEXTURE.legacy_mesh.bind_promoted_children(parent)
    local changed, source_changed =
        FACE_TEXTURE.legacy_mesh.apply_effective(parent, true)
    if changed then
        local owner = FACE_TEXTURE.legacy_mesh.accepts_parent(parent)
        local datamodel = rawget(parent, "_datamodel")
        if owner and datamodel then
            datamodel._legacy_mesh_promotion_dirty_parts =
                datamodel._legacy_mesh_promotion_dirty_parts or {}
            datamodel._legacy_mesh_promotion_dirty_parts[owner] =
                source_changed and true or false
        end
    end
end

function FACE_TEXTURE.legacy_mesh.flush_promotion_dirty(datamodel)
    local dirty = rawget(datamodel, "_legacy_mesh_promotion_dirty_parts")
    rawset(datamodel, "_legacy_mesh_promotion_dirty_parts", nil)
    local core = rawget(datamodel, "_core")
    if not dirty or not core
        or type(core._mark_runtime_part_legacy_mesh_dirty) ~= "function" then
        return
    end
    for owner, source_changed in pairs(dirty) do
        core:_mark_runtime_part_legacy_mesh_dirty(owner, source_changed)
    end
end

function FACE_TEXTURE.append_supported(classes)
    classes[#classes + 1] = "SurfaceAppearance"
    classes[#classes + 1] = "Decal"
    classes[#classes + 1] = "Texture"
    classes[#classes + 1] = "SpecialMesh"
    classes[#classes + 1] = "BlockMesh"
    classes[#classes + 1] = "CylinderMesh"
    return classes
end

local function descendants_array(instance, out)
    local children = instance and instance._children or {}
    for index = 1, #children do
        local child = children[index]
        out[#out + 1] = child
        descendants_array(child, out)
    end
end

local function subtree_array(instance)
    local out = { instance }
    descendants_array(instance, out)
    return out
end

local function ancestor_array(instance)
    local out = {}
    local cursor = instance and rawget(instance, "_parent") or nil
    while cursor do
        out[#out + 1] = cursor
        cursor = rawget(cursor, "_parent")
    end
    return out
end

-- workspace is the only place physics simulates, drives register/purge on reparent
local function instance_is_in_workspace(instance)
    local cursor = rawget(instance, "_parent")
    while cursor do
        if rawget(cursor, "_class_name") == "Workspace" then
            return true
        end
        cursor = rawget(cursor, "_parent")
    end
    return false
end

local function is_ancestor(candidate, instance)
    local cursor = instance
    while cursor do
        if cursor == candidate then
            return true
        end
        cursor = rawget(cursor, "_parent")
    end
    return false
end

local function rebuild_first_child_name(parent, name, start_index)
    if not parent or not name then
        return
    end
    parent._child_name_map[name] = nil
    for index = start_index or 1, #parent._children do
        local child = parent._children[index]
        if child._name == name then
            parent._child_name_map[name] = child
            return
        end
    end
end

-- raycast filter caches are only valid within one epoch
local hierarchy_epoch = 0

-- ray counters. two integer adds next to a broadphase traversal is unmeasurable, and
-- "how many rays does a frame actually cast" is otherwise unknowable without a profiler
-- filter_misses counts full re-normalizations (fresh id set + a GetDescendants walk per
-- filtered instance) -- the gap between it and raycasts is how well the filter cache works
local stat_raycasts = 0
local stat_filter_misses = 0

local function remove_child(parent, child)
    if not parent or not child then
        return false
    end
    hierarchy_epoch = hierarchy_epoch + 1
    for index = #parent._children, 1, -1 do
        if parent._children[index] == child then
            table.remove(parent._children, index)
            if parent._child_name_map[child._name] == child then
                -- the removed child was the first with this name. Earlier
                -- siblings cannot replace it, only the shifted suffix can
                rebuild_first_child_name(parent, child._name, index)
            end
            return true
        end
    end
    return false
end

local function add_child(parent, child)
    hierarchy_epoch = hierarchy_epoch + 1
    parent._children[#parent._children + 1] = child
    if parent._child_name_map[child._name] == nil then
        parent._child_name_map[child._name] = child
    end
end

-- Bulk fast-attach for the INITIAL map promotion only: parents a freshly-built facade node
-- with just the raw parent/child linkage, skipping set_instance_parent's per-node
-- subtree_array walk + (suppressed) signal loops + per-node physics remove/refresh churn +
-- per-node mover sync. Safe because: promotion builds fresh, cycle-free nodes with no old
-- parent (no remove_child / ancestry checks needed), the loader
-- (_load_runtime_parts_from_parsed -> _refresh_physics_part_registration, scene.lua:9823)
-- has ALREADY registered every core part before promotion runs, so the promote-time
-- remove-then-refresh dance nets to nothing, and body-mover nodes are synced in one deferred
-- pass at the end of promotion (see _promote_instance_roots). Runtime (post-load) reparents
-- still use the full set_instance_parent path
local function promote_attach(parent, child)
    rawset(child, "_parent", parent)
    add_child(parent, child)
end

-- bridged live to the physics core (movers.lua from_legacy)
local BODY_MOVER_INSTANCE_CLASSES = {
    BodyForce = true,
    BodyThrust = true,
    BodyVelocity = true,
    BodyAngularVelocity = true,
    BodyPosition = true,
    BodyGyro = true,
}

local function vec3_plain(v)
    if type(v) ~= "table" then
        return { x = 0, y = 0, z = 0 }
    end
    return {
        x = tonumber(v.x or v.X) or 0,
        y = tonumber(v.y or v.Y) or 0,
        z = tonumber(v.z or v.Z) or 0,
    }
end

-- Source records can omit legacy mover properties. the mover layer supplies
-- Roblox-compatible defaults for those omissions, an authored Vector3 is
-- preserved exactly, including a zero component that disables that axis
local function opt_vec3(v)
    if v == nil then
        return nil
    end
    return vec3_plain(v)
end

-- shaped like a parsed legacy record, read live so edits land next step
local function read_body_mover_props(node)
    local p = rawget(node, "_properties") or {}
    local cls = rawget(node, "_class_name")
    if cls == "BodyForce" then
        return { force = vec3_plain(p.Force or p.force) }
    elseif cls == "BodyThrust" then
        return { force = vec3_plain(p.Force or p.force), location = vec3_plain(p.Location or p.location) }
    elseif cls == "BodyVelocity" then
        return {
            velocity = vec3_plain(p.Velocity or p.velocity),
            max_force = opt_vec3(p.MaxForce or p.maxforce),
            p = p.P or p.p,
        }
    elseif cls == "BodyAngularVelocity" then
        return {
            angular_velocity = vec3_plain(p.AngularVelocity or p.angularvelocity or p.Velocity or p.velocity),
            max_torque = opt_vec3(p.MaxTorque or p.maxtorque),
            p = p.P or p.p,
        }
    elseif cls == "BodyPosition" then
        return { position = vec3_plain(p.Position or p.position), max_force = opt_vec3(p.MaxForce or p.maxforce),
            p = p.P or p.p, d = p.D or p.d }
    elseif cls == "BodyGyro" then
        return {
            cframe = p.CFrame or p.cframe or p.CoordinateFrame or p.coordinateframe,
            max_torque = opt_vec3(p.MaxTorque or p.maxtorque),
            p = p.P or p.p, d = p.D or p.d,
        }
    end
    return nil
end

-- tostring(node) collides for same-named movers
local body_mover_id_counter = 0
local function body_mover_id(node)
    local id = rawget(node, "_mover_id")
    if id == nil then
        body_mover_id_counter = body_mover_id_counter + 1
        id = "inst:" .. body_mover_id_counter
        rawset(node, "_mover_id", id)
    end
    return id
end

-- target = parent basepart in workspace
local function sync_runtime_mover(node)
    local datamodel = rawget(node, "_datamodel")
    local core = datamodel and rawget(datamodel, "_core") or nil
    if not core or not core._sync_runtime_body_mover then
        return
    end
    local id = body_mover_id(node)
    local class_name = rawget(node, "_class_name")
    local part_id
    if rawget(node, "_destroyed") ~= true then
        local parent = rawget(node, "_parent")
        local core_handle = parent and rawget(parent, "_core_handle") or nil
        if core_handle and core_handle._destroyed ~= true and instance_is_in_workspace(node) then
            part_id = core_handle._id
        end
    end
    if part_id == nil then
        core:_sync_runtime_body_mover(id, class_name, nil, nil)
        return
    end
    core:_sync_runtime_body_mover(id, class_name, read_body_mover_props(node), part_id)
end

local function notify_body_mover_destroyed(node)
    if not BODY_MOVER_INSTANCE_CLASSES[rawget(node, "_class_name")] then
        return
    end
    local datamodel = rawget(node, "_datamodel")
    local core = datamodel and rawget(datamodel, "_core") or nil
    if core and core._remove_runtime_body_mover then
        core:_remove_runtime_body_mover(body_mover_id(node))
    end
end

function LOCAL_LIGHT.is_instance(instance)
    return type(instance) == "table"
        and LOCAL_LIGHT.classes[rawget(instance, "_class_name")] == true
end

function LOCAL_LIGHT.is_directional(instance)
    local class_name = rawget(instance, "_class_name")
    return class_name == "SpotLight" or class_name == "SurfaceLight"
end

function LOCAL_LIGHT.set_properties_from_entry(instance, entry)
    local props = rawget(instance, "_properties")
    props.Enabled = entry.enabled == true
    props.Brightness = tonumber(entry.brightness) or 1
    props.Color = Color3.new(
        tonumber(entry.color_r) or 1,
        tonumber(entry.color_g) or 1,
        tonumber(entry.color_b) or 1)
    props.Range = tonumber(entry.range)
        or (rawget(instance, "_class_name") == "PointLight" and 8 or 16)
    props.Shadows = entry.shadows == true
    if LOCAL_LIGHT.is_directional(instance) then
        props.Angle = tonumber(entry.angle) or 90
        local enum = RBX.Enum and RBX.Enum.NormalId
        props.Face = enum and enum[entry.face or "Front"]
            or (entry.face or "Front")
    else
        props.Angle = nil
        props.Face = nil
    end
    props.enabled = nil
    props.brightness = nil
    props.color = nil
    props.color3 = nil
    props.range = nil
    props.shadows = nil
    props.angle = nil
    props.face = nil
end

function LOCAL_LIGHT.initialize(instance, source)
    if not LOCAL_LIGHT.is_instance(instance) then return instance end
    source = type(source) == "table" and source
        or rawget(instance, "_properties") or {}
    local class_name = rawget(instance, "_class_name")
    local entry = RBX._make_local_light_entry
        and RBX._make_local_light_entry(class_name, source) or nil
    if not entry then
        local point = class_name == "PointLight"
        entry = {
            class_name = class_name,
            enabled = true,
            brightness = 1,
            color = { 1, 1, 1 },
            color_r = 1,
            color_g = 1,
            color_b = 1,
            shadows = false,
            range = point and 8 or 16,
            raw_range = point and 8 or 16,
            angle = point and 0 or 90,
            face = "Front",
        }
    end
    -- Parser sources carry a face name/token, while public clones carry the
    -- actual EnumItem table.  the parser normalizer intentionally accepts only
    -- serialized scalar forms, so unwrap the facade value at this boundary
    if LOCAL_LIGHT.is_directional(instance)
        and (source.Face ~= nil or source.face ~= nil) then
        entry.face = FACE_TEXTURE.face_name(
            source.Face ~= nil and source.Face or source.face, class_name)
    end
    entry.name = rawget(instance, "_name") or class_name
    entry.referent = rawget(instance, "_referent")
        or entry.referent
    entry._facade_instance = instance
    rawset(instance, "_local_light_entry", entry)
    rawset(instance, "_local_light_registered", false)
    rawset(instance, "_local_light_owner_part", false)
    rawset(instance, "_local_light_owner_attachment", false)
    LOCAL_LIGHT.set_properties_from_entry(instance, entry)
    return instance
end

function LOCAL_LIGHT.ensure_entry(instance)
    local entry = rawget(instance, "_local_light_entry")
    if type(entry) ~= "table" then
        LOCAL_LIGHT.initialize(instance)
        entry = rawget(instance, "_local_light_entry")
    end
    return entry
end

function LOCAL_LIGHT.part_slot(core, part)
    if type(part) ~= "table" or part._destroyed then return nil end
    local slot = tonumber(part._loaded_part_index)
        or tonumber(part._runtime_part_slot)
    if slot and core.parts and core.parts[slot] == part then
        return slot
    end
    for index = 1, #(core.parts or {}) do
        if core.parts[index] == part then return index end
    end
    return nil
end

function LOCAL_LIGHT.owner_binding(instance)
    local datamodel = rawget(instance, "_datamodel")
    local core = datamodel and rawget(datamodel, "_core") or nil
    local parent = rawget(instance, "_parent")
    if not core or not parent
        or rawget(parent, "_datamodel") ~= datamodel then
        return core, nil, nil, nil, nil
    end

    local owner_node = parent
    local attachment
    if rawget(parent, "_class_name") == "Attachment" then
        attachment = parent
        owner_node = rawget(parent, "_parent")
    end
    if not owner_node or rawget(owner_node, "_datamodel") ~= datamodel then
        return core, nil, nil, nil, nil
    end
    local part = rawget(owner_node, "_core_handle")
    if type(part) ~= "table" or part._destroyed or part._workspace_active==false
        or rawget(owner_node, "_core") ~= core then
        return core, nil, nil, nil, nil
    end
    local slot = LOCAL_LIGHT.part_slot(core, part)
    if not slot then return core, nil, nil, nil, nil end
    return core, part, owner_node, attachment, slot
end

function LOCAL_LIGHT.attachment_cframe(attachment)
    local props = rawget(attachment, "_properties") or {}
    local raw_cframe = props.CFrame or props.CoordinateFrame
        or props.cframe or props.coordinateframe
    if raw_cframe ~= nil then
        return cframe_from_value(raw_cframe, CFrame.identity)
    end
    local position = props.Position or props.position
    if type(position) == "table" then
        return cframe_from_value(position, CFrame.identity)
    end
    return CFrame.identity
end

function LOCAL_LIGHT.attachment_data(attachment)
    local cframe = LOCAL_LIGHT.attachment_cframe(attachment)
    return {
        referent = rawget(attachment, "_referent") or nil,
        local_x = cframe.x or 0,
        local_y = cframe.y or 0,
        local_z = cframe.z or 0,
        r00 = cframe.r00 or 1,
        r01 = cframe.r01 or 0,
        r02 = cframe.r02 or 0,
        r10 = cframe.r10 or 0,
        r11 = cframe.r11 or 1,
        r12 = cframe.r12 or 0,
        r20 = cframe.r20 or 0,
        r21 = cframe.r21 or 0,
        r22 = cframe.r22 or 1,
    }
end

function LOCAL_LIGHT.apply_binding(instance, entry, part, owner_node,
        attachment, slot)
    entry.parent_kind = attachment and "Attachment" or "Part"
    entry.parent_class = part.ClassName or "BasePart"
    entry.parent_name = part.Name
    entry.parent_part_index = slot
    entry.parent_referent = part._map_referent
        or rawget(owner_node, "_referent") or nil
    entry.parent_transform = nil
    entry.parent_transform_runtime = nil
    entry.attachment_referent = attachment
        and (rawget(attachment, "_referent") or nil) or nil
    entry.attachment = attachment
        and LOCAL_LIGHT.attachment_data(attachment) or nil
    -- SurfaceLight-on-Attachment is represented by the shader's spot type
    -- clear that derived override when it returns to a direct BasePart owner
    entry.shader_type_id = nil
    entry.dirty = true
    rawset(instance, "_local_light_owner_part", part)
    rawset(instance, "_local_light_owner_attachment", attachment or false)
end

function LOCAL_LIGHT.allocate_id(core, entry)
    if entry.id ~= nil then return end
    local next_id = tonumber(core._datamodel_local_light_next_id)
    if next_id == nil then
        next_id = 0
        for index = 1, #(core.local_lights or {}) do
            next_id = math.max(next_id,
                tonumber(core.local_lights[index].id) or 0)
        end
    end
    next_id = next_id + 1
    core._datamodel_local_light_next_id = next_id
    entry.id = next_id
end

function LOCAL_LIGHT.register(core, instance, entry)
    core.local_lights = core.local_lights or {}
    LOCAL_LIGHT.allocate_id(core, entry)
    entry._facade_instance = instance
    core.local_lights[#core.local_lights + 1] = entry
    rawset(instance, "_local_light_registered", true)
end

function LOCAL_LIGHT.unregister(core, instance, entry)
    local removed = false
    for index = #(core.local_lights or {}), 1, -1 do
        if core.local_lights[index] == entry then
            table.remove(core.local_lights, index)
            removed = true
            break
        end
    end
    rawset(instance, "_local_light_registered", false)
    rawset(instance, "_local_light_owner_part", false)
    rawset(instance, "_local_light_owner_attachment", false)
    entry.active = false
    entry.bounds = nil
    entry.parent_part = nil
    entry.parent_part_id = nil
    entry.dirty = false
    return removed
end

function LOCAL_LIGHT.rebuild_part_index(core)
    local by_part_id = {}
    for index = 1, #(core.local_lights or {}) do
        local entry = core.local_lights[index]
        local part_id = entry and entry.active and entry.parent_part_id
        if part_id ~= nil then
            local bucket = by_part_id[part_id]
            if not bucket then
                bucket = {}
                by_part_id[part_id] = bucket
            end
            bucket[#bucket + 1] = entry
        end
    end
    core._local_lights_by_part_id = by_part_id
end

function LOCAL_LIGHT.commit(core)
    if not core or core._tearing_down == true then return false end
    core._local_lights_dirty = true
    if type(core._update_dirty_local_lights) == "function" then
        core:_update_dirty_local_lights()
    else
        local active_count, shadow_count = 0, 0
        for index = 1, #(core.local_lights or {}) do
            local entry = core.local_lights[index]
            if entry.dirty and type(core._compute_local_light_world) == "function" then
                entry.dirty = false
                core:_compute_local_light_world(entry)
            end
            if entry.active then
                active_count = active_count + 1
                if entry.shadows == true then
                    shadow_count = shadow_count + 1
                end
            end
        end
        core.local_light_count = active_count
        core.local_light_shadow_request_count = shadow_count
        core._local_light_revision = (core._local_light_revision or 0) + 1
        if type(core._rebuild_local_light_grid) == "function" then
            core:_rebuild_local_light_grid()
        end
        core._local_lights_dirty = false
    end
    LOCAL_LIGHT.rebuild_part_index(core)
    return true
end

function LOCAL_LIGHT.sync_node_deferred(instance)
    if not LOCAL_LIGHT.is_instance(instance)
        or rawget(instance, "_destroyed") == true then
        return nil, false
    end
    local datamodel = rawget(instance, "_datamodel")
    if datamodel and rawget(datamodel, "_local_light_promotion") then
        return rawget(datamodel, "_core"), false
    end
    local core, part, owner_node, attachment, slot =
        LOCAL_LIGHT.owner_binding(instance)
    if not core then return nil, false end
    local entry = LOCAL_LIGHT.ensure_entry(instance)
    local registered = rawget(instance, "_local_light_registered") == true
    local valid = part ~= nil and core.enable_local_lights ~= false

    if not valid then
        if registered then
            return core, LOCAL_LIGHT.unregister(core, instance, entry)
        end
        rawset(instance, "_local_light_owner_part", false)
        rawset(instance, "_local_light_owner_attachment", false)
        return core, false
    end

    if registered
        and rawget(instance, "_local_light_owner_part") == part
        and rawget(instance, "_local_light_owner_attachment")
            == (attachment or false) then
        return core, false
    end

    LOCAL_LIGHT.apply_binding(
        instance, entry, part, owner_node, attachment, slot)
    if not registered then
        LOCAL_LIGHT.register(core, instance, entry)
    end
    return core, true
end

function LOCAL_LIGHT.sync_nodes(nodes)
    local changed_core
    local changed = false
    for index = 1, #(nodes or {}) do
        local core, node_changed =
            LOCAL_LIGHT.sync_node_deferred(nodes[index])
        if node_changed then
            changed_core = core
            changed = true
        end
    end
    if changed then LOCAL_LIGHT.commit(changed_core) end
    return changed
end

function LOCAL_LIGHT.sync_attachment(attachment)
    if rawget(attachment, "_class_name") ~= "Attachment" then return false end
    local core
    local changed = false
    for index = 1, #(rawget(attachment, "_children") or {}) do
        local light = attachment._children[index]
        if LOCAL_LIGHT.is_instance(light)
            and rawget(light, "_local_light_registered") == true then
            local entry = LOCAL_LIGHT.ensure_entry(light)
            entry.attachment = LOCAL_LIGHT.attachment_data(attachment)
            entry.attachment_referent = rawget(attachment, "_referent") or nil
            entry.dirty = true
            core = rawget(light, "_core")
            changed = true
        end
    end
    if changed then LOCAL_LIGHT.commit(core) end
    return changed
end

function LOCAL_LIGHT.public_attachment_value(instance, key)
    if rawget(instance, "_class_name") ~= "Attachment" then
        return false, nil
    end
    if key == "CFrame" then
        return true, LOCAL_LIGHT.attachment_cframe(instance)
    elseif key == "Position" then
        return true, LOCAL_LIGHT.attachment_cframe(instance).Position
    elseif key == "Orientation" then
        local value = rawget(instance, "_properties").Orientation
        return true, value or Vector3.zero
    end
    return false, nil
end

function LOCAL_LIGHT.apply_attachment_write(instance, key, value)
    if rawget(instance, "_class_name") ~= "Attachment"
        or (key ~= "CFrame" and key ~= "Position"
            and key ~= "Orientation") then
        return false
    end
    local props = rawget(instance, "_properties")
    local previous = LOCAL_LIGHT.attachment_cframe(instance)
    local next_cframe
    if key == "CFrame" then
        local components = RBX._extract_cframe_components(value)
        if not components then
            error("Attachment.CFrame must be a CFrame-like value", 3)
        end
        for _, component in pairs(components) do
            if finite_component(component, nil, -1000000, 1000000) == nil then
                error("Attachment.CFrame must contain finite components", 3)
            end
        end
        next_cframe = CFrame.new(
            components.x, components.y, components.z,
            components.r00, components.r01, components.r02,
            components.r10, components.r11, components.r12,
            components.r20, components.r21, components.r22)
    else
        if type(value) ~= "table" then
            error("Attachment." .. key .. " must be a Vector3-like value", 3)
        end
        local x = finite_component(value.x or value.X or value[1],
            nil, -1000000, 1000000)
        local y = finite_component(value.y or value.Y or value[2],
            nil, -1000000, 1000000)
        local z = finite_component(value.z or value.Z or value[3],
            nil, -1000000, 1000000)
        if x == nil or y == nil or z == nil then
            error("Attachment." .. key
                .. " must contain finite components", 3)
        end
        if key == "Position" then
            next_cframe = CFrame.new(x, y, z,
                previous.r00, previous.r01, previous.r02,
                previous.r10, previous.r11, previous.r12,
                previous.r20, previous.r21, previous.r22)
        else
            next_cframe = CFrame.new(previous.x, previous.y, previous.z)
                * CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
        end
    end
    if previous == next_cframe then return true end
    props.CFrame = next_cframe
    props.CoordinateFrame = nil
    props.cframe = nil
    props.coordinateframe = nil
    props.Position = next_cframe.Position
    props.position = nil
    props.Orientation = key == "Orientation" and Vector3.new(
        value.x or value.X or value[1],
        value.y or value.Y or value[2],
        value.z or value.Z or value[3]) or nil
    LOCAL_LIGHT.sync_attachment(instance)
    ROPE.changed(instance, key)
    fire_property_changed(instance, key)
    return true
end

function LOCAL_LIGHT.apply_write(instance, key, value)
    if not LOCAL_LIGHT.is_instance(instance) then return false end
    local class_name = rawget(instance, "_class_name")
    local directional = LOCAL_LIGHT.is_directional(instance)
    local props = rawget(instance, "_properties")
    local entry = LOCAL_LIGHT.ensure_entry(instance)
    local canonical, normalized

    if key == "Enabled" or key == "Shadows" then
        if type(value) ~= "boolean" then
            error(class_name .. "." .. key .. " must be boolean", 3)
        end
        canonical, normalized = key, value
    elseif key == "Brightness" then
        canonical = key
        normalized = FACE_TEXTURE.number(value, class_name, key, 0, 40)
    elseif key == "Range" then
        canonical = key
        normalized = FACE_TEXTURE.number(value, class_name, key, 0, 60)
    elseif key == "Color" then
        canonical = key
        local color = FACE_TEXTURE.color(value, class_name, key)
        normalized = Color3.new(color[1], color[2], color[3])
    elseif key == "Angle" or key == "Face" then
        if not directional then
            error(class_name .. "." .. key .. " is not a valid property", 3)
        end
        canonical = key
        if key == "Angle" then
            normalized = FACE_TEXTURE.number(value, class_name, key, 0, 180)
        else
            local face_name = FACE_TEXTURE.face_name(value, class_name)
            local enum = RBX.Enum and RBX.Enum.NormalId
            normalized = enum and enum[face_name] or face_name
        end
    else
        return false
    end

    local unchanged = props[canonical] == normalized
    if canonical == "Color" then
        unchanged = atmosphere_color_equal(props.Color, normalized)
    end
    if unchanged then return true end
    props[canonical] = normalized
    if canonical == "Enabled" then
        entry.enabled = normalized
    elseif canonical == "Brightness" then
        entry.brightness = normalized
    elseif canonical == "Range" then
        entry.range = normalized
        entry.raw_range = normalized
    elseif canonical == "Shadows" then
        entry.shadows = normalized
    elseif canonical == "Angle" then
        entry.angle = normalized
    elseif canonical == "Face" then
        entry.face = normalized.Name or normalized.name or tostring(normalized)
        entry.face = entry.face:match("([%a_]+)$") or "Front"
    elseif canonical == "Color" then
        entry.color = { normalized.R, normalized.G, normalized.B }
        entry.color_r, entry.color_g, entry.color_b =
            normalized.R, normalized.G, normalized.B
    end
    if rawget(instance, "_local_light_registered") == true then
        entry.dirty = true
        LOCAL_LIGHT.commit(rawget(instance, "_core"))
    end
    fire_property_changed(instance, canonical)
    return true
end

function LOCAL_LIGHT.destroy(instance, defer_commit)
    if not LOCAL_LIGHT.is_instance(instance) then return false end
    local core = rawget(instance, "_core")
    local entry = LOCAL_LIGHT.ensure_entry(instance)
    local removed = false
    if core and rawget(instance, "_local_light_registered") == true then
        removed = LOCAL_LIGHT.unregister(core, instance, entry)
    end
    entry._facade_instance = nil
    if removed and not defer_commit
        and core and core._tearing_down ~= true then
        LOCAL_LIGHT.commit(core)
    end
    return removed, core
end

function LOCAL_LIGHT.begin_promotion(datamodel)
    rawset(datamodel, "_local_light_promotion", true)
    local core = rawget(datamodel, "_core")
    -- the production loader has already replaced core.local_lights with the
    -- new parsed generation.  explicit/internal promotion callers may not
    -- have done so, though, retire entries owned by the outgoing facade tree
    -- so they cannot survive as invisible, strongly-referenced ghost lights
    local outgoing_entries = {}
    local outgoing_nodes = subtree_array(datamodel)
    for index = 1, #outgoing_nodes do
        local instance = outgoing_nodes[index]
        if LOCAL_LIGHT.is_instance(instance) then
            local entry = rawget(instance, "_local_light_entry")
            if rawget(instance, "_local_light_registered") == true
                and type(entry) == "table" then
                outgoing_entries[entry] = true
            end
            rawset(instance, "_local_light_registered", false)
            rawset(instance, "_local_light_owner_part", false)
            rawset(instance, "_local_light_owner_attachment", false)
            if type(entry) == "table" then entry._facade_instance = nil end
        end
    end
    local removed_outgoing = false
    for index = #(core and core.local_lights or {}), 1, -1 do
        if outgoing_entries[core.local_lights[index]] then
            table.remove(core.local_lights, index)
            removed_outgoing = true
        end
    end
    rawset(datamodel, "_local_light_promotion_removed_outgoing",
        removed_outgoing or nil)
    local by_referent = {}
    local next_id = 0
    for index = 1, #(core and core.local_lights or {}) do
        local entry = core.local_lights[index]
        entry._facade_instance = nil
        next_id = math.max(next_id, tonumber(entry.id) or 0)
        if entry.referent ~= nil then
            by_referent[entry.referent] = entry
        end
    end
    if core then core._datamodel_local_light_next_id = next_id end
    rawset(datamodel, "_promote_local_lights_by_referent", by_referent)
end

function LOCAL_LIGHT.promoted_match(datamodel, instance, claimed)
    local core = rawget(datamodel, "_core")
    local referent = rawget(instance, "_referent")
    local by_referent = rawget(
        datamodel, "_promote_local_lights_by_referent") or {}
    local exact = referent and by_referent[referent] or nil
    if exact and not claimed[exact] then return exact end

    local _, part, _, attachment = LOCAL_LIGHT.owner_binding(instance)
    local class_name = rawget(instance, "_class_name")
    local name = rawget(instance, "_name")
    for index = 1, #(core and core.local_lights or {}) do
        local candidate = core.local_lights[index]
        if not claimed[candidate]
            and candidate.class_name == class_name
            and candidate.name == name
            and candidate.parent_part == part
            and candidate.parent_kind
                == (attachment and "Attachment" or "Part")
            and (not attachment or candidate.attachment_referent == nil
                or candidate.attachment_referent
                    == rawget(attachment, "_referent")) then
            return candidate
        end
    end
    return nil
end

function LOCAL_LIGHT.end_promotion(datamodel)
    local nodes = subtree_array(datamodel)
    local claimed = {}
    local unmatched = {}
    for index = 1, #nodes do
        local instance = nodes[index]
        if LOCAL_LIGHT.is_instance(instance) then
            local entry = LOCAL_LIGHT.promoted_match(
                datamodel, instance, claimed)
            if entry then
                claimed[entry] = true
                entry._facade_instance = instance
                rawset(instance, "_local_light_entry", entry)
                rawset(instance, "_local_light_registered", true)
                local _, part, _, attachment =
                    LOCAL_LIGHT.owner_binding(instance)
                rawset(instance, "_local_light_owner_part", part or false)
                rawset(instance, "_local_light_owner_attachment",
                    attachment or false)
                LOCAL_LIGHT.set_properties_from_entry(instance, entry)
            else
                unmatched[#unmatched + 1] = instance
            end
        end
    end
    rawset(datamodel, "_promote_local_lights_by_referent", nil)
    rawset(datamodel, "_local_light_promotion", nil)
    local changed = #unmatched > 0 and LOCAL_LIGHT.sync_nodes(unmatched)
    local removed_outgoing = rawget(
        datamodel, "_local_light_promotion_removed_outgoing") == true
    rawset(datamodel, "_local_light_promotion_removed_outgoing", nil)
    if removed_outgoing and not changed then
        LOCAL_LIGHT.commit(rawget(datamodel, "_core"))
    end
end

function LOCAL_LIGHT.append_supported(classes)
    classes[#classes + 1] = "Attachment"
    classes[#classes + 1] = "PointLight"
    classes[#classes + 1] = "SpotLight"
    classes[#classes + 1] = "SurfaceLight"
    return classes
end

local function set_instance_parent(instance, new_parent)
    if instance._destroyed then
        error("Cannot parent destroyed Instance", 3)
    end
    if new_parent ~= nil then
        if type(new_parent) ~= "table" or getmetatable(new_parent) ~= instance_mt and getmetatable(new_parent) ~= datamodel_mt then
            error("Parent must be an Instance or nil", 3)
        end
        if new_parent._destroyed then
            error("Cannot parent to destroyed Instance", 3)
        end
        if is_ancestor(instance, new_parent) then
            error("Cannot parent Instance to itself or descendant", 3)
        end
    end

    local old_parent = rawget(instance, "_parent")
    if old_parent == new_parent then
        return
    end

    local moving_subtree = subtree_array(instance)
    if old_parent then
        remove_child(old_parent, instance)
    end
    rawset(instance, "_parent", new_parent)
    if new_parent then
        add_child(new_parent, instance)
    end
    -- Membership is a hierarchy fact. publish it atomically before user
    -- callbacks can mutate a stored part and accidentally register it again
    for index=1,#moving_subtree do
        local node=moving_subtree[index];local part=rawget(node,'_core_handle')
        local core=part and rawget(node,'_core')
        if core and core._set_runtime_part_workspace_membership then
            core:_set_runtime_part_workspace_membership(part,instance_is_in_workspace(node))
        end
    end
    if RBX._reparent_gui_node then
        RBX._reparent_gui_node(instance, old_parent, new_parent)
    end
    -- a FaceInstance renders only while it is a direct BasePart child. keep
    -- the renderer-owned descriptor list synchronized before hierarchy signals
    -- expose the new relationship to user callbacks
    FACE_TEXTURE.reparent(instance, new_parent)
    FACE_TEXTURE.legacy_mesh.reparent(instance, old_parent, new_parent)
    FACE_TEXTURE.surface_appearance.reparent(
        instance, old_parent, new_parent)
    -- a Light renders only under a direct BasePart or a direct Attachment
    -- whose own parent is a BasePart.  the subtree walk is shared with the
    -- hierarchy signals below so moving an Attachment atomically rebinds all
    -- of its child lights with one grid revision
    LOCAL_LIGHT.sync_nodes(moving_subtree)
    ROPE.changed(instance, "Parent")

    if old_parent then
        fire_signal(old_parent, "ChildRemoved", instance)
    end
    if new_parent then
        fire_signal(new_parent, "ChildAdded", instance)
        local ancestors = ancestor_array(instance)
        for ancestor_index = 1, #ancestors do
            local ancestor = ancestors[ancestor_index]
            for node_index = 1, #moving_subtree do
                fire_signal(ancestor, "DescendantAdded", moving_subtree[node_index])
            end
        end
    end
    for index = 1, #moving_subtree do
        local node = moving_subtree[index]
        fire_signal(node, "AncestryChanged", node, rawget(node, "_parent"))
    end
    -- reparent out = purge (no orphan proxy), in = (re-)register
    for index = 1, #moving_subtree do
        local node = moving_subtree[index]
        local core_handle = rawget(node, "_core_handle")
        local core = core_handle and rawget(node, "_core") or nil
        if core then
            if instance_is_in_workspace(node) then
                if core._refresh_physics_part_registration then
                    core:_refresh_physics_part_registration(core_handle)
                end
            elseif core._on_runtime_part_removed_from_physics then
                core:_on_runtime_part_removed_from_physics(core_handle)
            end
        end
    end
    -- reparent in/out registers or drops the world mover
    for index = 1, #moving_subtree do
        local node = moving_subtree[index]
        if BODY_MOVER_INSTANCE_CLASSES[rawget(node, "_class_name")] then
            sync_runtime_mover(node)
        end
    end
    -- only a direct Atmosphere child of Lighting is effective. Re-evaluate
    -- once after the complete subtree move so removing the first authored
    -- child can atomically reveal the next one without transient states
    for index = 1, #moving_subtree do
        if rawget(moving_subtree[index], "_class_name") == "Atmosphere" then
            local datamodel = rawget(instance, "_datamodel")
            if datamodel and sync_effective_atmosphere then
                sync_effective_atmosphere(datamodel)
            end
            break
        end
    end
    for index = 1, #moving_subtree do
        if LIGHTING_CHILD_FIELDS[rawget(moving_subtree[index], "_class_name")] then
            sync_effective_lighting_children(rawget(instance, "_datamodel"))
            break
        end
    end
    fire_property_changed(instance, "Parent")
    RUNTIME_WELD.ancestry_changed(instance, moving_subtree)
end

local function set_instance_name(instance, value)
    local new_name = tostring(value or "")
    local old_name = instance._name
    if old_name == new_name then
        return
    end
    local parent = rawget(instance, "_parent")
    local rebuild_old_name = parent and parent._child_name_map[old_name] == instance
    instance._name = new_name
    local face_descriptor = rawget(instance, "_face_texture_descriptor")
    if type(face_descriptor) == "table" then
        face_descriptor.name = new_name
    end
    local surface_descriptor = rawget(
        instance, "_surface_appearance_descriptor")
    if type(surface_descriptor) == "table" then
        surface_descriptor.name = new_name
    end
    local local_light_entry = rawget(instance, "_local_light_entry")
    if type(local_light_entry) == "table" then
        -- Names are diagnostic-only, do not invalidate the spatial grid
        local_light_entry.name = new_name
    end
    local core_handle = rawget(instance, "_core_handle")
    if core_handle then
        local core = rawget(instance, "_core")
        if core and update_runtime_part_name_index then
            update_runtime_part_name_index(core, core_handle, core_handle.Name, new_name)
        end
        core_handle.Name = new_name
        if core_handle._dm_node and rename_datamodel_node then
            rename_datamodel_node(core_handle._dm_node, new_name)
        end
    end
    if parent then
        if rebuild_old_name then
            rebuild_first_child_name(parent, old_name)
        end
        rebuild_first_child_name(parent, new_name)
    end
    fire_property_changed(instance, "Name")
end

local function initialize_body_mover_defaults(properties, class_name)
    -- current Roblox legacy BodyMover defaults. they are deliberately eager:
    -- callers can inspect every public setting before the mover is parented,
    -- and the live bridge sees the same values as an imported place that omits
    -- an optional serialized property
    if class_name == "BodyForce" then
        properties.Force = Vector3.new(0, 1, 0)
    elseif class_name == "BodyThrust" then
        properties.Force = Vector3.new(0, 1, 0)
        properties.Location = Vector3.new()
    elseif class_name == "BodyVelocity" then
        properties.Velocity = Vector3.new(0, 2, 0)
        properties.MaxForce = Vector3.new(4000, 4000, 4000)
        properties.P = 1250
    elseif class_name == "BodyAngularVelocity" then
        properties.AngularVelocity = Vector3.new(0, 2, 0)
        properties.MaxTorque = Vector3.new(4000, 4000, 4000)
        properties.P = 1250
    elseif class_name == "BodyPosition" then
        properties.Position = Vector3.new(0, 50, 0)
        properties.MaxForce = Vector3.new(4000, 4000, 4000)
        properties.P = 10000
        properties.D = 1250
    elseif class_name == "BodyGyro" then
        properties.CFrame = CFrame.new()
        properties.MaxTorque = Vector3.new(400000, 0, 400000)
        properties.P = 3000
        properties.D = 500
    end
end

local function make_instance(datamodel, class_name, name, defer_source_descriptors)
    local instance = {
        _datamodel = datamodel,
        _core = datamodel and datamodel._core or nil,
        _core_handle = false,
        _core_handle_id = false,
        _referent = false,
        _class_name = class_name or "Instance",
        _name = name or class_name or "Instance",
        _parent = nil,
        _children = {},
        _child_name_map = {},
        _properties = {},
        _signals = {},
        _property_signals = {},
        _service_name = false,
        _is_service = false,
        _parent_locked = false,
        _suppress_signals = false,
        _destroyed = false,
    }
    setmetatable(instance, instance_mt)
    initialize_body_mover_defaults(instance._properties, class_name)
    ROPE.track(instance)
    initialize_atmosphere_instance(instance)
    -- Source promotion overwrites these defaults with authored values before
    -- attachment or callbacks. Atmosphere keeps its existing merged-properties
    -- initialization order in both paths
    if defer_source_descriptors ~= true then
        LOCAL_LIGHT.initialize(instance)
        FACE_TEXTURE.initialize(instance)
        FACE_TEXTURE.legacy_mesh.initialize(instance)
        FACE_TEXTURE.surface_appearance.initialize(instance)
    end
    return instance
end

local function effective_atmosphere_instance(datamodel)
    local services = datamodel and rawget(datamodel, "_services_by_name")
    local lighting = services and services.Lighting or nil
    local children = lighting and rawget(lighting, "_children") or nil
    for index = 1, #(children or {}) do
        local child = children[index]
        if rawget(child, "_class_name") == "Atmosphere"
            and rawget(child, "_destroyed") ~= true then
            return child
        end
    end
    return nil
end

local function atmosphere_settings_from_instance(instance)
    if not instance then
        return nil
    end
    local props = rawget(instance, "_properties") or {}
    local color = props.Color
    local decay = props.Decay
    return {
        Density = props.Density,
        Offset = props.Offset,
        Color = { color.r, color.g, color.b },
        Decay = { decay.r, decay.g, decay.b },
        Haze = props.Haze,
        Glare = props.Glare,
    }
end

sync_effective_atmosphere = function(datamodel)
    if not datamodel or rawget(datamodel, "_destroyed") == true then
        return false
    end
    if rawget(datamodel, "_suppress_signals") then
        rawset(datamodel, "_atmosphere_sync_pending", true)
        return false
    end
    if rawget(datamodel, "_syncing_atmosphere") then
        return false
    end

    local effective = effective_atmosphere_instance(datamodel)
    rawset(datamodel, "_effective_atmosphere_instance", effective or false)
    rawset(datamodel, "_atmosphere_sync_pending", false)

    local core = rawget(datamodel, "_core")
    if not core or rawget(core, "_tearing_down") == true
        or type(core.set_atmosphere_settings) ~= "function" then
        return false
    end
    rawset(datamodel, "_syncing_atmosphere", true)
    local ok, changed_or_error = pcall(
        core.set_atmosphere_settings,
        core,
        atmosphere_settings_from_instance(effective))
    rawset(datamodel, "_syncing_atmosphere", false)
    if not ok then
        rawset(datamodel, "_atmosphere_sync_error", tostring(changed_or_error))
        return false
    end
    rawset(datamodel, "_atmosphere_sync_error", nil)
    return changed_or_error == true
end

sync_effective_lighting_children = function(datamodel)
    if not datamodel or rawget(datamodel, "_destroyed") or rawget(datamodel, "_suppress_signals") then return false end
    local core = rawget(datamodel, "_core")
    local services = rawget(datamodel, "_services_by_name")
    local lighting = services and services.Lighting
    if not core or core._tearing_down or not core.set_lighting_children or not lighting then return false end
    local effects, sky, selected = {}, nil, {}
    local function select_child(child, sun_only)
        local fields = LIGHTING_CHILD_FIELDS[rawget(child, "_class_name")]
        if fields and (not sun_only or fields[1] == "sun_rays")
            and not selected[fields[1]] and not rawget(child, "_destroyed") then
            selected[fields[1]] = true
            local descriptor, props = {}, rawget(child, "_properties") or {}
            for i = 2, #fields do
                local key, value = fields[i], props[fields[i]]
                if value == nil and fields[1] == "sun_rays" then value = child[key] end
                if type(value) == "table" then
                    if value.R ~= nil or value.r ~= nil then
                        value = { value.R or value.r, value.G or value.g, value.B or value.b }
                    elseif value.X ~= nil or value.x ~= nil then
                        value = { value.X or value.x, value.Y or value.y, value.Z or value.z }
                    else
                        local copy = {};for k,v in pairs(value) do copy[k]=v end;value=copy
                    end
                end
                descriptor[key] = value
            end
            if fields[1] == "sky" then
                descriptor.source = "authored_sky_facade";sky = descriptor
            else effects[fields[1]] = descriptor end
        end
    end
    for _, child in ipairs(rawget(lighting, "_children") or {}) do select_child(child, false) end
    -- existing first-child policy, extended to the active Camera for SunRays
    -- Multiple effects are not composited: Lighting wins, then CurrentCamera
    local workspace = services.Workspace
    local camera = workspace and workspace._properties.CurrentCamera
    if camera and not rawget(camera, "_destroyed") then
        for _, child in ipairs(rawget(camera, "_children") or {}) do select_child(child, true) end
    end
    return core:set_lighting_children(effects, sky)
end

local function is_base_part_class(class_name)
    return SUPPORTED_PART_CLASSES and SUPPORTED_PART_CLASSES[class_name] == true
end

local function is_a(instance, class_name)
    if class_name == "Instance" then
        return true
    end
    if class_name == "ServiceProvider" then
        return getmetatable(instance) == datamodel_mt
            or rawget(instance, "_class_name") == "Workspace"
    end
    if class_name == "DataModel" then
        return getmetatable(instance) == datamodel_mt
    end
    local cursor = rawget(instance, "_class_name")
    while cursor do
        if cursor == class_name then
            return true
        end
        if cursor == "BasePart" and class_name == "Instance" then
            return true
        end
        cursor = INSTANCE_CLASS_SUPERCLASS[cursor]
        if cursor == "ServiceProvider" and class_name == "Instance" then
            return true
        end
    end
    return false
end

local function normalize_camera_type_name(value)
    if type(value) == "table" then
        value = value.Name or value.EnumItem or value.name
    end
    local name = tostring(value or "Scriptable")
    local enum = RBX.Enum and RBX.Enum.CameraType
    if enum and enum[name] then
        return name
    end
    if name == "Fixed" or name == "Attach" or name == "Watch" or name == "Track" or name == "Follow"
        or name == "Custom" or name == "Scriptable" or name == "Orbital" then
        return name
    end
    error("Camera.CameraType must be a CameraType enum item or valid CameraType name", 3)
end

local function camera_type_value(name)
    local enum = RBX.Enum and RBX.Enum.CameraType
    return enum and enum[name] or name
end

local function is_active_camera(instance)
    local core = rawget(instance, "_core")
    return core and core._is_current_camera_instance and core:_is_current_camera_instance(instance)
end

local function default_camera_cframe(instance)
    local core = rawget(instance, "_core")
    return core and core.camera and core.camera.cframe or CFrame.new(0, 5, -10)
end

local function default_camera_focus(instance)
    local core = rawget(instance, "_core")
    return core and core.camera and core.camera.focus or CFrame.new()
end

local function default_camera_field_of_view(instance)
    local core = rawget(instance, "_core")
    return core and core.get_camera_field_of_view and core:get_camera_field_of_view() or 70
end

local function default_camera_type(instance)
    local core = rawget(instance, "_core")
    return core and core.camera and core.camera.camera_type or "Scriptable"
end

local function get_camera_instance_property(instance, key)
    local core = rawget(instance, "_core")
    local props = rawget(instance, "_properties")
    if key == "CFrame" then
        return is_active_camera(instance) and core:_get_camera_core_cframe() or props.CFrame or default_camera_cframe(instance)
    end
    if key == "Focus" then
        return is_active_camera(instance) and core:get_camera_focus() or props.Focus or default_camera_focus(instance)
    end
    if key == "CameraType" then
        local name = is_active_camera(instance) and (core.camera and core.camera.camera_type) or props.CameraType
        return camera_type_value(name or default_camera_type(instance))
    end
    if key == "FieldOfView" then
        return is_active_camera(instance) and core:get_camera_field_of_view() or props.FieldOfView or default_camera_field_of_view(instance)
    end
    if key == "ViewportSize" then
        return core and core.get_camera_viewport_size and core:get_camera_viewport_size() or Vector3.zero
    end
    return nil
end

local function source_camera_type_name(value)
    if type(value) == "table" then
        value = value.Name or value.EnumItem or value.name or value.Value or value.value
    end
    for name, item in pairs(RBX.Enum.CameraType) do
        if value == name or tonumber(value) == item.Value then return name end
    end
    -- Studio's serialized missing/negative/out-of-range/text tokens use Fixed
    -- public assignment still uses the strict enum/name validator above
    return "Fixed"
end

local function camera_instance_snapshot(instance)
    return {
        CFrame = get_camera_instance_property(instance, "CFrame"),
        Focus = get_camera_instance_property(instance, "Focus"),
        CameraType = get_camera_instance_property(instance, "CameraType"),
        FieldOfView = get_camera_instance_property(instance, "FieldOfView"),
    }
end

local function retire_camera_source_identity(camera)
    -- Referents belong to one source file, not to a persistent embedding view
    rawset(camera, "_referent", false)
    rawget(camera, "_properties").Referent = nil
end

local function initialize_camera_instance(instance, source, preserve_core_defaults)
    if type(instance) ~= "table" or rawget(instance, "_class_name") ~= "Camera" then
        return instance
    end
    local props = rawget(instance, "_properties")
    if preserve_core_defaults then
        -- the bootstrap is an embedding camera, not Instance.new("Camera")
        props.CFrame = props.CFrame or default_camera_cframe(instance)
        props.Focus = props.Focus or default_camera_focus(instance)
        props.CameraType = props.CameraType or default_camera_type(instance)
        props.FieldOfView = props.FieldOfView or default_camera_field_of_view(instance)
        return instance
    end
    source = source or props
    -- Native Studio 0.737 fresh and missing-field Camera oracle. Inactive
    -- cameras own these values instead of following mutable active core state
    local diagonal = 0.7071068286895752
    props.CFrame = cframe_from_value(source.CFrame or source.CoordinateFrame,
        CFrame.new(0, 20, 20, 1, 0, 0,
            0, diagonal, diagonal, 0, -diagonal, diagonal))
    props.Focus = cframe_from_value(source.Focus or source.focus, CFrame.new(0, 0, -5))
    props.CameraType = source_camera_type_name(source.CameraType)
    props.FieldOfView = clamp(tonumber(source.FieldOfView) or 70, 1, 120)
    return instance
end

local function get_part_property(instance, key)
    local part = rawget(instance, "_core_handle")
    local core = rawget(instance, "_core")
    if not part or part._destroyed then
        return nil
    end

    if get_runtime_part_property_value then
        return get_runtime_part_property_value(core, part, key)
    end
    return nil
end

local function set_part_property(instance, key, value)
    local part = rawget(instance, "_core_handle")
    local core = rawget(instance, "_core")
    if not part or part._destroyed then
        error("Cannot edit destroyed Part", 3)
    end
    local descriptor = get_runtime_part_property_descriptor and get_runtime_part_property_descriptor(part.ClassName, key) or nil
    if get_runtime_part_property_descriptor and not descriptor then
        return false
    end
    if not descriptor and not PART_PROPERTY_SCHEMA[key] then
        return false
    end
    local previous_cframe, previous_size, previous_anchored = part.CFrame, part.Size, part.Anchored
    if descriptor and set_runtime_part_property_with_descriptor then
        set_runtime_part_property_with_descriptor(core, part, descriptor, value)
    else
        set_runtime_part_property(core, part, key, value)
    end
    if part.CFrame ~= previous_cframe or part.Size ~= previous_size or part.Anchored ~= previous_anchored then
        ROPE.changed(instance, key)
    end
    fire_runtime_part_property_changed(core, part, key)
    if part.CFrame ~= previous_cframe then RUNTIME_WELD.part_transform_changed(instance) end
    fire_property_changed(instance, key)
    return true
end

local function clone_part_properties(part)
    return {
        Name = part.Name,
        Shape = part.Shape,
        CFrame = part.CFrame and part.CFrame:clone() or nil,
        Size = part.Size and { x = part.Size.x, y = part.Size.y, z = part.Size.z } or nil,
        Color = part.Color and { r = part.Color.r, g = part.Color.g, b = part.Color.b } or nil,
        Transparency = part.Transparency,
        LocalTransparencyModifier = part.LocalTransparencyModifier,
        Reflectance = part.Reflectance,
        Anchored = part.Anchored,
        CanCollide = part.CanCollide,
        CanTouch = part.CanTouch,
        CanQuery = part.CanQuery,
        CollisionGroup = part.CollisionGroup,
        Massless = part.Massless,
        RootPriority = part.RootPriority,
        CustomPhysicalProperties = clone_physical_properties_value(part.CustomPhysicalProperties),
        AssemblyLinearVelocity = part.AssemblyLinearVelocity and {
            x = part.AssemblyLinearVelocity.x,
            y = part.AssemblyLinearVelocity.y,
            z = part.AssemblyLinearVelocity.z,
        } or nil,
        AssemblyAngularVelocity = part.AssemblyAngularVelocity and {
            x = part.AssemblyAngularVelocity.x,
            y = part.AssemblyAngularVelocity.y,
            z = part.AssemblyAngularVelocity.z,
        } or nil,
        Material = part.Material,
        TopSurface = part.TopSurface,
        BottomSurface = part.BottomSurface,
        LeftSurface = part.LeftSurface,
        RightSurface = part.RightSurface,
        FrontSurface = part.FrontSurface,
        BackSurface = part.BackSurface,
        MeshId = part.MeshId,
        TextureContent = part.TextureContent,
        TextureId = part.TextureId,
        UsePartColor = part.UsePartColor,
        DoubleSided = part.DoubleSided,
        SmoothingAngle = part.SmoothingAngle,
        RenderFidelity = part.RenderFidelity,
        CollisionFidelity = part.CollisionFidelity,
        PhysicsData = part.PhysicsData,
        PhysicalConfigData = part.PhysicalConfigData,
        TriangleCount = part.TriangleCount,
        MaterialVariant = part.MaterialVariant,
    }
end

-- Storage BaseParts deliberately have no live renderer/physics handle. reuse
-- the authored parser when cloning one, so the clone gets the same geometry as
-- a Workspace part without waking or rendering the original storage template
function RBX._clone_passive_source_tree(instance)
    local source = {}
    for key, value in pairs(rawget(instance, "_properties") or {}) do source[key] = value end
    source.Name, source.ClassName = instance._name, instance._class_name
    source.Referent = rawget(instance, "_referent")
    source.Children = {}
    for index, child in ipairs(instance._children) do
        source.Children[index] = RBX._clone_passive_source_tree(child)
    end
    return source
end

function RBX._bind_cloned_gui_nodes(guis, by_referent)
    local function bind(node)
        local instance = node.referent and by_referent[node.referent]
        if instance then
            rawset(instance, "_gui_node", node)
            rawset(node, "_gui_instance", instance)
            if RBX._observe_surface_gui_lifetime then RBX._observe_surface_gui_lifetime(instance, node) end
        end
        for _, child in ipairs(node.nodes or node.children or {}) do bind(child) end
    end
    for _, gui in ipairs(guis or {}) do bind(gui) end
end

-- optional cooperative Clone is one owned operation. its detached root and
-- every allocated child belong to the owner before metadata copying can yield
-- default Clone() remains the existing synchronous implementation below
local CLONE = {}
function CLONE.is_facade(value)
    if type(value) ~= "table" then return false end
    local mt = getmetatable(value)
    return mt == instance_mt or mt == datamodel_mt
end
function CLONE.step(context, stage)
    local n = (context.progress[stage] or 0) + 1
    context.progress[stage] = n
    if n % 32 == 0 then context.owner:checkpoint(stage, n) end
end
function CLONE.record(context, clone, parent)
    -- own the allocation before copying metadata can yield or fail. publish
    -- its parent only after initialization: Decal, mesh and light descriptors
    -- are replaced while copying, so an earlier bind would retain defaults
    context.owned[#context.owned + 1] = clone
end
function CLONE.cleanup(context)
    if context.cleaned then return end
    context.cleaned = true
    local errors = {}
    -- retain allocation ownership even if preparation commits its owner early
    -- a failing visit never stops later attempts in this independent ledger
    for i = #context.owned, 1, -1 do
        local clone = context.owned[i]
        local ok, err = pcall(clone.Destroy, clone)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    if #errors > 0 then error(table.concat(errors, "\n"), 0) end
end
function CLONE.resolve(context, value, seen)
    if type(value) ~= "table" then return value end
    local original = context.references[value]
    if original then return context.runtime_clones[original] or original end
    if CLONE.is_facade(value) or seen[value] then return value end
    seen[value] = true
    for key, item in pairs(value) do
        value[key] = CLONE.resolve(context, item, seen)
        CLONE.step(context, "clone:reference-values")
    end
    return value
end
function CLONE.context(loading)
    assert(type(loading) == "table", "Clone loading context must be a table or nil")
    for key, value in pairs(loading) do
        assert(key == "checkpoint" or key == "on_owner", "Unknown Clone loading field " .. tostring(key))
        assert(type(value) == "function", "Clone loading " .. tostring(key) .. " must be a function")
    end
    local owner = runtime_require("loading_owner.lua").new(loading)
    local context = { owner = owner, owned = {}, progress = {},
        markers = {}, references = {}, runtime_clones = {}, by_referent = {} }
    owner:cleanup(function() CLONE.cleanup(context) end)
    context.copy_leaf = function(value)
        -- ClassName-looking metadata is still ordinary value-owned metadata
        -- only the installed facade metatables identify reference leaves
        if not CLONE.is_facade(value) then return false end
        local marker = context.markers[value]
        if not marker then
            marker = {}; context.markers[value] = marker
            context.references[marker] = value
        end
        return true, marker
    end
    context.copy_step = function() CLONE.step(context, "clone:metadata") end
    return context
end

local function clone_owned_gui_list(guis, root)
    local owned={}
    for _,gui in ipairs(guis or{})do
        local owner=rawget(gui,'_gui_instance')
        -- Adornee can put an external GUI in a Part's render registry. That
        -- registry is not Instance ancestry: Clone must not copy that GUI
        -- Descriptors without facades remain supported for embedding callers
        if not owner or owner==root or owner:IsDescendantOf(root)then owned[#owned+1]=gui end
    end
    return RBX._clone_surface_gui_list(owned)
end
local function clone_instance_tree(instance, datamodel, by_referent, runtime_clones, context, parent, original_root)
    original_root=original_root or instance
    by_referent = by_referent or {}
    local owns_runtime_clones = runtime_clones == nil
    runtime_clones = runtime_clones or {}
    local clone
    local core_handle = rawget(instance, "_core_handle")
    local core = rawget(instance, "_core")
    if not core_handle and core and is_base_part_class(instance._class_name) then
        local source = RBX._clone_passive_source_tree(instance)
        local parts = collect_supported_parts_from_tree({ source })
        local parsed = parts and parts[1]
        if not parsed or tostring(parsed.referent) ~= tostring(source.Referent) then
            error("Cannot clone authored BasePart '" .. instance._name .. "': missing geometry", 2)
        end
        core_handle = runtime_part_from_parsed(parsed, 0)
        -- the real child facades cloned below own these layers. the temporary
        -- parsed snapshot has no facade identities with which to deduplicate
        core_handle.FaceTextures = {}
    end
    if core_handle and core then
        local props = clone_part_properties(core_handle)
        props.Parent = nil
        local part = core:_create_runtime_part(instance._class_name, props)
        if part and context then CLONE.record(context, part._instance_node, parent) end
        if part then
            part.SurfaceAppearance = RBX._clone_surface_appearance_descriptor(
                core_handle.SurfaceAppearance)
            -- some embedding callers construct core parts without a source
            -- hierarchy. preserve that value-owned legacy mesh state too, real
            -- child facades cloned below deterministically recompute the same
            -- fields and never share these vector tables
            part.MeshOwner = core_handle.MeshOwner
            part.SpecialMeshType = core_handle.SpecialMeshType
            part.SpecialMeshScale = FACE_TEXTURE.legacy_mesh.plain_vector(
                core_handle.SpecialMeshScale)
            part.SpecialMeshOffset = FACE_TEXTURE.legacy_mesh.plain_vector(
                core_handle.SpecialMeshOffset)
            part.SpecialMeshVertexColor = core_handle.SpecialMeshVertexColor and {
                r = core_handle.SpecialMeshVertexColor.r,
                g = core_handle.SpecialMeshVertexColor.g,
                b = core_handle.SpecialMeshVertexColor.b,
            } or nil
            part.BlockMeshScale = FACE_TEXTURE.legacy_mesh.plain_vector(
                core_handle.BlockMeshScale)
            part.BlockMeshOffset = FACE_TEXTURE.legacy_mesh.plain_vector(
                core_handle.BlockMeshOffset)
            part.MeshVertexColor = core_handle.MeshVertexColor and {
                r = core_handle.MeshVertexColor.r,
                g = core_handle.MeshVertexColor.g,
                b = core_handle.MeshVertexColor.b,
            } or nil
            part.MeshSize = core_handle.MeshSize and {
                x = core_handle.MeshSize.x, y = core_handle.MeshSize.y, z = core_handle.MeshSize.z,
            } or nil
            part.EmbeddedMeshData = core_handle.EmbeddedMeshData
            part.EmbeddedMeshDataCandidates = RBX._clone_string_list(core_handle.EmbeddedMeshDataCandidates)
            part._embedded_mesh_cache = nil -- decoded geometry owns separate cache pins
            part._loaded_map_mirror_x = core_handle._loaded_map_mirror_x == true
            part.CastShadow = core_handle.CastShadow ~= false
            part.SurfaceGuis = clone_owned_gui_list(core_handle.SurfaceGuis,original_root)
            part.BillboardGuis = clone_owned_gui_list(core_handle.BillboardGuis,original_root)
            -- Texture caches and per-frame visit marks use the GUI runtime ID
            -- Authored referents remain available for facade binding, but each
            -- clone must own a separate rendering identity
            for index, gui in ipairs(part.SurfaceGuis) do
                gui.runtime_id = "clone|" .. part._id .. "|surface|" .. index
            end
            for index, gui in ipairs(part.BillboardGuis) do
                gui.runtime_id = "clone|" .. part._id .. "|billboard|" .. index
            end
        end
        clone = part and part._instance_node
    else
        clone = make_instance(datamodel, instance._class_name, instance._name)
        if context then CLONE.record(context, clone, parent) end
        if RUNTIME_WELD.is_instance(instance) then RUNTIME_WELD.initialize(clone) end
        for key, value in pairs(instance._properties) do
            if not context and key=='Adornee'
                and (instance._class_name=='BillboardGui' or instance._class_name=='SurfaceGui') then
                -- this is an Instance reference, not value-owned metadata
                -- preserve external targets and remap internal targets once
                -- the synchronous clone's complete tree exists below
                clone._properties[key]=value
            elseif not RUNTIME_WELD.clone_property(instance, clone, key, value) then
                clone._properties[key] = copy_runtime_value(value, nil,
                    context and context.copy_leaf, context and context.copy_step)
            end
            if context then CLONE.step(context, "clone:properties") end
        end
        if instance._class_name == "Camera" then
            -- generic graph copies intentionally strip metatables. Snapshot
            -- live facade values, not their copied private CFrame storage;
            -- active core setters can also be newer than stored properties
            initialize_camera_instance(clone, camera_instance_snapshot(instance))
        end
        -- copy_runtime_value intentionally strips metatables from general DOM
        -- metadata. Atmosphere's public Color3 values are immutable value
        -- types, so rebuild them from the source facade instead
        initialize_atmosphere_instance(clone, instance._properties)
        -- light clones receive a fresh, unregistered renderer entry.  Color3
        -- and the remaining authored values are rebuilt from facade state so
        -- no mutable descriptor table is shared with the source instance
        LOCAL_LIGHT.initialize(clone, instance._properties)
        if instance._class_name=='Attachment' then
            -- General metadata copies strip the immutable CFrame metatable
            -- rebuild this typed channel before publishing its parent, as for
            -- light colours, otherwise cloned attachments read as identity
            clone._properties.CFrame=LOCAL_LIGHT.attachment_cframe(instance)
        end
        FACE_TEXTURE.legacy_mesh.initialize(clone, instance._properties)
        FACE_TEXTURE.surface_appearance.initialize(
            clone, instance._properties)
        if FACE_TEXTURE.is_instance(instance) then
            local descriptor = RBX._clone_face_texture_descriptor(
                rawget(instance, "_face_texture_descriptor"))
            if descriptor then
                -- a clone is a new authored instance, not a second facade for
                -- the source map referent/order slot
                descriptor.referent = nil
                descriptor.authored_index = nil
                FACE_TEXTURE.initialize(clone, descriptor)
            end
        end
    end
    if not clone then
        return nil
    end
    if context then clone.Parent = parent end
    runtime_clones[instance] = clone
    local gui_source = rawget(instance, "_gui_node")
    local source_referent = rawget(instance, "_referent")
        or (gui_source and gui_source.referent)
    if source_referent then by_referent[source_referent] = clone end
    if not context then clone.Parent = nil end
    if core_handle and rawget(clone, "_core_handle") then
        -- _create_runtime_part already queued this new part once. Child face
        -- attachment below must populate its descriptors before that build,
        -- without adding one dirty mark per layer
        rawset(clone, "_suppress_face_texture_dirty", true)
        rawset(clone, "_suppress_legacy_mesh_dirty", true)
        rawset(clone, "_suppress_surface_appearance_dirty", true)
    end
    for index = 1, #instance._children do
        local child_clone = clone_instance_tree(instance._children[index], datamodel, by_referent,
            runtime_clones, context, clone, original_root)
        if child_clone and not context then
            child_clone.Parent = clone
        end
    end
    rawset(clone, "_suppress_face_texture_dirty", nil)
    rawset(clone, "_suppress_legacy_mesh_dirty", nil)
    rawset(clone, "_suppress_surface_appearance_dirty", nil)
    if core_handle and rawget(clone, "_core_handle") then
        local clone_part = rawget(clone, "_core_handle")
        -- Clone descriptors are independent, and facade writes must target the
        -- corresponding new GUI rather than the original source referents
        RBX._bind_cloned_gui_nodes(clone_part.SurfaceGuis, by_referent)
        RBX._bind_cloned_gui_nodes(clone_part.BillboardGuis, by_referent)
        if #clone_part.SurfaceGuis > 0 or #clone_part.BillboardGuis > 0 then
            -- GUI carriers have separate scene registries. a geometry-only
            -- transform refresh cannot publish newly cloned GUI entries
            mark_parts_dirty(core)
        end
        for index = 1, #(core_handle.FaceTextures or {}) do
            local descriptor = core_handle.FaceTextures[index]
            local facade = descriptor and descriptor._facade_instance
            if not facade or rawget(facade, "_parent") ~= instance then
                local copied = RBX._clone_face_texture_descriptor(descriptor)
                if copied then
                    clone_part.FaceTextures[#clone_part.FaceTextures + 1] = copied
                end
            end
        end
    end
    if owns_runtime_clones then
        for original,copied in pairs(runtime_clones)do
            if original._class_name=='BillboardGui' or original._class_name=='SurfaceGui' then
                local adornee=original._properties.Adornee
                if CLONE.is_facade(adornee)then copied.Adornee=runtime_clones[adornee] or adornee end
            end
        end
        RUNTIME_WELD.finish_clones(runtime_clones)
    end
    if context then CLONE.step(context, "clone:nodes") end
    return clone
end

function InstanceMethods:GetChildren()
    local out = {}
    for index = 1, #self._children do
        out[index] = self._children[index]
    end
    return out
end

function InstanceMethods:GetDescendants()
    local out = {}
    descendants_array(self, out)
    return out
end

function InstanceMethods:FindFirstChild(name, recursive)
    name = tostring(name or "")
    local child = self._child_name_map[name]
    if child then
        return child
    end
    if recursive == true then
        local descendants = self:GetDescendants()
        for index = 1, #descendants do
            if descendants[index]._name == name then
                return descendants[index]
            end
        end
    end
    return nil
end

function InstanceMethods:WaitForChild(name)
    return self:FindFirstChild(name)
end

function InstanceMethods:IsA(class_name)
    return is_a(self, class_name)
end

function InstanceMethods:IsDescendantOf(ancestor)
    local cursor = rawget(self, "_parent")
    -- Typical map depths resolve without a loop, so hot callers' JIT traces
    -- do not abort on an inner loop, deeper chains continue below
    if cursor == nil then return false end
    if cursor == ancestor then return true end
    cursor = rawget(cursor, "_parent")
    if cursor == nil then return false end
    if cursor == ancestor then return true end
    cursor = rawget(cursor, "_parent")
    if cursor == nil then return false end
    if cursor == ancestor then return true end
    cursor = rawget(cursor, "_parent")
    if cursor == nil then return false end
    if cursor == ancestor then return true end
    cursor = rawget(cursor, "_parent")
    if cursor == nil then return false end
    if cursor == ancestor then return true end
    cursor = rawget(cursor, "_parent")
    while cursor do
        if cursor == ancestor then return true end
        cursor = rawget(cursor, "_parent")
    end
    return false
end

function InstanceMethods:IsAncestorOf(descendant)
    return type(descendant) == "table" and InstanceMethods.IsDescendantOf(descendant, self) or false
end

function InstanceMethods:GetFullName()
    local names = {}
    local cursor = self
    while cursor do
        names[#names + 1] = cursor._name
        cursor = rawget(cursor, "_parent")
    end
    local out = {}
    for index = #names, 1, -1 do
        out[#out + 1] = names[index]
    end
    return table.concat(out, ".")
end

function InstanceMethods:GetPropertyChangedSignal(property_name)
    return get_property_signal(self, property_name)
end

function InstanceMethods:GetPropertySchema()
    if rawget(self, "_core_handle") and PART_PROPERTY_SCHEMA then
        return PART_PROPERTY_SCHEMA
    end
    if LOCAL_LIGHT.is_instance(self) then
        return LOCAL_LIGHT.schema
    end
    if FACE_TEXTURE.legacy_mesh.is_instance(self) then
        return rawget(self, "_class_name") == "SpecialMesh"
            and FACE_TEXTURE.legacy_mesh.special_schema
            or FACE_TEXTURE.legacy_mesh.base_schema
    end
    if FACE_TEXTURE.surface_appearance.is_instance(self) then
        return FACE_TEXTURE.surface_appearance.schema
    end
    return {}
end

function InstanceMethods:GetMass()
    local part = rawget(self, "_core_handle")
    return part and (part.Mass or 0) or 0
end

function InstanceMethods:ApplyImpulse(impulse)
    local part = rawget(self, "_core_handle")
    local core = rawget(self, "_core")
    if core and part and core._apply_runtime_part_impulse then
        core:_apply_runtime_part_impulse(part, impulse)
    end
end

function InstanceMethods:ApplyImpulseAtPosition(impulse, position)
    local part = rawget(self, "_core_handle")
    local core = rawget(self, "_core")
    if core and part and core._apply_runtime_part_impulse_at_position then
        core:_apply_runtime_part_impulse_at_position(part, impulse, position)
    end
end

function InstanceMethods:ApplyAngularImpulse(impulse)
    local part = rawget(self, "_core_handle")
    local core = rawget(self, "_core")
    if core and part and core._apply_runtime_part_angular_impulse then
        core:_apply_runtime_part_angular_impulse(part, impulse)
    end
end

---@param loading? RBXLoadingContext Explicit owned checkpoints; nil preserves synchronous Clone
---@param prepare_clone? fun(clone:table, owner:table) Runs before ownership transfer
function InstanceMethods:Clone(loading, prepare_clone)
    assert(loading == nil or type(loading) == "table", "Clone loading context must be a table or nil")
    if loading == nil and prepare_clone == nil then
        return clone_instance_tree(self, self._datamodel)
    end
    assert(prepare_clone == nil or type(prepare_clone) == "function", "Clone preparation callback must be a function")
    if loading == nil then loading = {} end
    local context = CLONE.context(loading)
    local ok, result = pcall(function()
        local clone = assert(clone_instance_tree(self, self._datamodel, context.by_referent,
            context.runtime_clones, context), "Clone allocation returned nil")
        local seen = {}
        for _, node in ipairs(context.owned) do
            for key, value in pairs(node._properties) do
                local replacement = CLONE.resolve(context, value, seen)
                if replacement ~= value then node[key] = replacement end
                CLONE.step(context, "clone:reference-properties")
            end
        end
        -- preserve the existing weld completion after the whole ordered tree
        -- exists, numeric/source-specific references are the adapter's task
        RUNTIME_WELD.finish_clones(context.runtime_clones)
        context.owner:checkpoint("clone:constructed", #context.owned, #context.owned)
        if prepare_clone then prepare_clone(clone, context.owner) end
        assert(not context.owner.closed, "Clone ownership ended before preparation completed")
        local committed, errors = context.owner:commit()
        assert(committed, "Clone temporary resource release failed: " .. table.concat(errors or {}, "\n"))
        return clone
    end)
    if not ok then
        local errors = {}
        local canceled, cancel_result, details = pcall(context.owner.cancel, context.owner)
        if not canceled then errors[#errors + 1] = tostring(cancel_result)
        elseif details then for _, err in ipairs(details) do errors[#errors + 1] = tostring(err) end end
        -- Owner.cancel can be a no-op after an illegally early commit. the
        -- clone transaction still owns all its recorded native allocations
        local cleaned, cleanup_error = pcall(CLONE.cleanup, context)
        if not cleaned then errors[#errors + 1] = tostring(cleanup_error) end
        if #errors > 0 then
            error(tostring(result) .. "\nClone cleanup: " .. table.concat(errors, "\n"), 0)
        end
        error(result, 0)
    end
    return result
end

-- destroy/disable must break the physics weld. keep in sync w/ the parser's legacy_joint_instance_classes
local JOINT_INSTANCE_CLASSES = {
    Weld = true, WeldConstraint = true, ManualWeld = true,
    Snap = true, Motor = true, Motor6D = true, RotateV = true,
}

-- find_constraint selector: referent primary, part0/part1/name fallbacks
local function joint_selector(instance)
    local props = rawget(instance, "_properties") or {}
    local referent = rawget(instance, "_referent")
    return {
        referent = referent ~= false and referent or nil,
        part0 = props.Part0,
        part1 = props.Part1,
        name = rawget(instance, "_name"),
    }
end

-- splits the assembly, wakes freed pieces
local function notify_joint_destroyed(instance)
    if RUNTIME_WELD.destroy(instance) then return end
    if not JOINT_INSTANCE_CLASSES[rawget(instance, "_class_name")] then
        return
    end
    local core = rawget(instance, "_core")
    if core and core._on_physics_joint_destroyed then
        core:_on_physics_joint_destroyed(joint_selector(instance))
    end
end

-- false splits the assembly next rebuild, true re-fuses
local function notify_joint_enabled(instance, enabled)
    if not JOINT_INSTANCE_CLASSES[rawget(instance, "_class_name")] then
        return
    end
    local core = rawget(instance, "_core")
    if core and core._set_physics_joint_enabled then
        core:_set_physics_joint_enabled(joint_selector(instance), enabled ~= false)
    end
end

-- destroy/disable re-enables collision for the pair (mirrors weld lifecycle)
local NO_COLLISION_INSTANCE_CLASSES = { NoCollisionConstraint = true }

local function notify_no_collision_destroyed(instance)
    if not NO_COLLISION_INSTANCE_CLASSES[rawget(instance, "_class_name")] then
        return
    end
    local core = rawget(instance, "_core")
    if core and core._on_no_collision_constraint_destroyed then
        core:_on_no_collision_constraint_destroyed(joint_selector(instance))
    end
end

local function notify_no_collision_enabled(instance, enabled)
    if not NO_COLLISION_INSTANCE_CLASSES[rawget(instance, "_class_name")] then
        return
    end
    local core = rawget(instance, "_core")
    if core and core._set_no_collision_constraint_enabled then
        core:_set_no_collision_constraint_enabled(joint_selector(instance), enabled ~= false)
    end
end

function InstanceMethods:Destroy()
    if self._destroyed then
        return
    end
    local nodes = subtree_array(self)
    for index = #nodes, 1, -1 do
        fire_signal(nodes[index], "Destroying")
    end
    if rawget(self, "_parent") ~= nil then
        set_instance_parent(self, nil)
    end
    local local_light_destroy_core
    local local_light_destroyed = false
    for index = #nodes, 1, -1 do
        local node = nodes[index]
        -- Destroying a BasePart walks descendants without individually
        -- reparenting them. Explicitly sever a retained FaceInstance descriptor
        -- before its owner core handle is retired, the owner's destruction will
        -- release geometry, so this cleanup must not queue a redundant rebuild
        if FACE_TEXTURE.is_instance(node) then
            FACE_TEXTURE.detach(node, true)
        end
        if FACE_TEXTURE.legacy_mesh.is_instance(node) then
            rawset(node, "_legacy_mesh_owner", false)
        end
        if FACE_TEXTURE.surface_appearance.is_instance(node) then
            FACE_TEXTURE.surface_appearance.detach(node)
        end
        local light_removed, light_core = LOCAL_LIGHT.destroy(node, true)
        if light_removed then
            local_light_destroyed = true
            local_light_destroy_core = light_core
        end
        for child_index = #node._children, 1, -1 do
            rawset(node._children[child_index], "_parent", nil)
            node._children[child_index] = nil
        end
        node._child_name_map = {}
        node._destroyed = true
        local core_handle = rawget(node, "_core_handle")
        if core_handle then
            core_handle._destroyed = true
            local core = rawget(node, "_core")
            if not (core and core._tearing_down) then
                if core and rawget(node, "_core_handle_id") then
                    node._datamodel._instance_by_core_id[rawget(node, "_core_handle_id")] = nil
                end
                if node._datamodel and rawget(node, "_referent") then
                    node._datamodel._instance_by_referent[rawget(node, "_referent")] = nil
                end
                if core and unindex_runtime_part_core_handle then
                    unindex_runtime_part_core_handle(core, core_handle)
                end
                -- release just this part's baked geometry. this used to be an unconditional
                -- mark_parts_dirty(core), which sets mode="full" and re-bakes the WHOLE scene
                -- for one destroyed part -- measured at 210-380ms + ~48MB of garbage per NPC
                -- death. _release_destroyed_part_geometry drops the part's own chunk/vertex
                -- range instead, and still falls back to mark_parts_dirty when the geometry
                -- isn't individually tracked, so untracked parts behave exactly as before
                if core and core._release_destroyed_part_geometry then
                    core:_release_destroyed_part_geometry(core_handle)
                elseif core and mark_parts_dirty then
                    mark_parts_dirty(core)
                end
                -- else it lingers as an orphan collider
                if core and core._on_runtime_part_removed_from_physics then
                    core:_on_runtime_part_removed_from_physics(core_handle)
                end
            end
            if cleanup_runtime_part_signals then
                cleanup_runtime_part_signals(core_handle)
            end
        end
        ROPE.destroy(node)
        notify_joint_destroyed(node)
        notify_no_collision_destroyed(node)
        notify_body_mover_destroyed(node)
        cleanup_instance_signals(node)
    end
    -- a BasePart/Model subtree can own many lights.  retire all entries first,
    -- then recount and rebuild the light grid once for the whole Destroy call
    if local_light_destroyed and local_light_destroy_core
        and local_light_destroy_core._tearing_down ~= true then
        LOCAL_LIGHT.commit(local_light_destroy_core)
    end
end

-- while the map streams in, a missing child returns a lazy ref (not nil) that binds later + flushes stashed writes
local lazy_ref_mt = {}
local get_lazy_ref -- fwd decl, __index uses it for nested chains

local function lazy_resolve(ref)
    local inst = rawget(ref, "_resolved")
    if inst ~= nil then
        if rawget(inst, "_destroyed") ~= true then
            return inst
        end
        rawset(ref, "_resolved", nil)
    end
    local parent = rawget(ref, "_parent")
    if parent == nil then
        return nil
    end
    -- parent may itself be an unbound ref (nested a.b.c)
    if getmetatable(parent) == lazy_ref_mt then
        parent = lazy_resolve(parent)
        if parent == nil then
            return nil
        end
    end
    local name_map = rawget(parent, "_child_name_map")
    local found = name_map and name_map[rawget(ref, "_name")] or nil
    if found ~= nil then
        rawset(ref, "_resolved", found)
        local pending = rawget(ref, "_pending")
        if pending ~= nil then
            rawset(ref, "_pending", nil)
            for k, v in pairs(pending) do
                found[k] = v
            end
        end
        -- cascade so nested refs flush their stashed writes too
        local child_refs = rawget(ref, "_lazy_child_refs")
        if child_refs ~= nil then
            for _, child in pairs(child_refs) do
                lazy_resolve(child)
            end
        end
    end
    return found
end

-- so ref:Method() resolves to the real instance as self
local function lazy_method_wrapper(ref, key)
    local cache = rawget(ref, "_mcache")
    if cache == nil then
        cache = {}
        rawset(ref, "_mcache", cache)
    end
    local wrapper = cache[key]
    if wrapper == nil then
        wrapper = function(_, ...)
            local i = lazy_resolve(ref)
            if i == nil then
                return nil
            end
            return i[key](i, ...)
        end
        cache[key] = wrapper
    end
    return wrapper
end

function lazy_ref_mt.__index(ref, key)
    local inst = lazy_resolve(ref)
    if inst ~= nil then
        local value = inst[key]
        if type(value) ~= "function" then
            return value
        end
        return lazy_method_wrapper(ref, key)
    end
    -- unbound: methods stay callable, else a nested ref (no nil-index crash)
    if InstanceMethods[key] ~= nil then
        return lazy_method_wrapper(ref, key)
    end
    return get_lazy_ref(ref, key)
end

function lazy_ref_mt.__newindex(ref, key, value)
    local inst = lazy_resolve(ref)
    if inst == nil then
        local pending = rawget(ref, "_pending")
        if pending == nil then
            pending = {}
            rawset(ref, "_pending", pending)
        end
        pending[key] = value
        return
    end
    inst[key] = value
end

function lazy_ref_mt.__tostring(ref)
    local state = rawget(ref, "_resolved") and "bound" or "pending"
    return "RBXDeferredRef(" .. tostring(rawget(ref, "_name")) .. ", " .. state .. ")"
end

-- one ref per (parent, name), so repeat indexing returns the same object
function get_lazy_ref(parent, name)
    local refs = rawget(parent, "_lazy_child_refs")
    if refs == nil then
        refs = {}
        rawset(parent, "_lazy_child_refs", refs)
    end
    local ref = refs[name]
    if ref == nil then
        ref = setmetatable({ _parent = parent, _name = name }, lazy_ref_mt)
        refs[name] = ref
    end
    return ref
end

-- spatial-query + camera-ray plumbing, the core does the work, these translate params + wrap results into facades

local function read_xyz(v)
    if type(v) ~= "table" then
        return 0, 0, 0
    end
    return tonumber(v.x or v.X or v[1]) or 0,
        tonumber(v.y or v.Y or v[2]) or 0,
        tonumber(v.z or v.Z or v[3]) or 0
end

-- core part id behind a facade or part proxy
local function instance_core_id(inst)
    if type(inst) ~= "table" then
        return nil
    end
    local id = rawget(inst, "_core_handle_id")
    if id then return id end
    local part = rawget(inst, "_part")
    if part and part._id then return part._id end
    local handle = rawget(inst, "_core_handle")
    if handle and handle._id then return handle._id end
    return nil
end

local function collect_core_ids(inst, set)
    if type(inst) ~= "table" then
        return
    end
    local id = instance_core_id(inst)
    if id then set[id] = true end
    if type(inst.GetDescendants) == "function" then
        local ok, desc = pcall(inst.GetDescendants, inst)
        if ok and type(desc) == "table" then
            for i = 1, #desc do
                local did = instance_core_id(desc[i])
                if did then set[did] = true end
            end
        end
    end
end

-- -> (filter_ids, include, respect). takes RaycastParams, {FilterType=...}, or a legacy tuple
local function normalize_raycast_filter(params)
    if type(params) ~= "table" then
        return nil, false, false, false
    end
    -- static callers key only on hierarchy changes. Callers with a mutable list can opt in
    -- with a numeric revision: bump it after mutating, then every ray in that shot/query
    -- batch reuses the one normalized id set without making the list globally static
    local revision = rawget(params, "_rbx_filter_revision")
    local cacheable = rawget(params, "_rbx_filter_static") == true or revision ~= nil
    local respect = params.RespectCanCollide == true
    local ignore_water = params.IgnoreWater == true
    if cacheable then
        local cached = rawget(params, "_rbx_filter_cache")
        -- _rbx_filter_flat: the caller guarantees every list entry is a leaf (no
        -- descendants to re-walk), so the cached id set stays valid across unrelated
        -- hierarchy changes and only the caller's own revision bumps invalidate it
        local flat = rawget(params, "_rbx_filter_flat") == true and revision ~= nil
        if cached ~= nil and (flat or cached.epoch == hierarchy_epoch)
            and cached.revision == revision
            and cached.respect == respect and cached.ignore_water == ignore_water
            and cached.filter_type == params.FilterType and cached.legacy_mode == params[1] then
            return cached.set, cached.include, cached.respect, cached.ignore_water
        end
    end
    stat_filter_misses = stat_filter_misses + 1
    local ftype = params.FilterType
    local flist = params.FilterDescendantsInstances
    if ftype ~= nil or flist ~= nil then
        local include = false
        if ftype ~= nil then
            local v = (type(ftype) == "table" and ftype.Value) or ftype
            include = (v == 1) or (v == "Include") or (v == "Whitelist")
        end
        if type(flist) ~= "table" then
            return nil, include, respect, ignore_water
        end
        local set = {}
        for i = 1, #flist do collect_core_ids(flist[i], set) end
        if cacheable then
            rawset(params, "_rbx_filter_cache", {
                epoch = hierarchy_epoch, revision = revision, set = set, include = include,
                respect = respect, ignore_water = ignore_water,
                filter_type = params.FilterType, legacy_mode = params[1],
            })
        end
        return set, include, respect, ignore_water
    end
    -- legacy tuple form
    local mode = params[1]
    if type(mode) == "string" then
        local lm = mode:lower()
        local include = (lm == "whitelist" or lm == "include")
        local set = {}
        local second = params[2]
        if type(second) == "table" and getmetatable(second) == nil then
            for i = 1, #second do collect_core_ids(second[i], set) end
        else
            for i = 2, #params do collect_core_ids(params[i], set) end
        end
        if cacheable then
            rawset(params, "_rbx_filter_cache", {
                epoch = hierarchy_epoch, revision = revision, set = set, include = include,
                respect = respect, ignore_water = ignore_water,
                filter_type = params.FilterType, legacy_mode = params[1],
            })
        end
        return set, include, respect, ignore_water
    end
    return nil, false, respect, ignore_water
end

-- pass-through when IgnoreWater is set
local function water_material_code()
    local water = RBX.Enum and RBX.Enum.Material and RBX.Enum.Material.Water
    return water and water.Value or nil
end

-- numeric Material -> Enum.Material item, Plastic fallback. reverse index built once
local _material_by_value
local function material_enum_for(part)
    local materials = RBX.Enum and RBX.Enum.Material
    if not materials then return nil end
    if not _material_by_value then
        _material_by_value = {}
        for _, item in pairs(materials) do
            if type(item) == "table" and item.Value ~= nil then
                _material_by_value[item.Value] = item
            end
        end
    end
    local code = part and part.Material
    return (code and _material_by_value[code]) or materials.Plastic
end

-- min/max of a Region3 or any {CFrame,Size}
local function region_bounds(region)
    if type(region) ~= "table" then
        return nil
    end
    local minx = rawget(region, "_minx")
    if minx ~= nil then
        return minx, rawget(region, "_miny"), rawget(region, "_minz"),
            rawget(region, "_maxx"), rawget(region, "_maxy"), rawget(region, "_maxz")
    end
    local cf, sz = region.CFrame, region.Size
    if cf and sz then
        local cx, cy, cz = read_xyz(cf.Position or cf)
        local sx, sy, sz2 = read_xyz(sz)
        return cx - sx * 0.5, cy - sy * 0.5, cz - sz2 * 0.5,
            cx + sx * 0.5, cy + sy * 0.5, cz + sz2 * 0.5
    end
    return nil
end

-- reused scratch -- queries consume it synchronously, never retain it
local raycast_opts_scratch = {}

local function workspace_raycast_method(self, origin, direction, params)
    stat_raycasts = stat_raycasts + 1
    local core = rawget(self, "_core")
    if not core or type(core._physics_raycast) ~= "function" then
        return nil
    end
    local ox, oy, oz = read_xyz(origin)
    local dx, dy, dz = read_xyz(direction)
    local filter_ids, include, respect, ignore_water = normalize_raycast_filter(params)
    local opts = raycast_opts_scratch
    opts.filter_ids = filter_ids
    opts.filter_include = include
    opts.respect_can_collide = respect
    opts.collision_group = type(params) == "table" and params.CollisionGroup or "Default"
    opts.ignore_water_material = ignore_water and water_material_code() or nil
    local hit = core:_physics_raycast(ox, oy, oz, dx, dy, dz, opts)
    if not hit then
        return nil
    end
    local facade = core:_get_or_create_part_proxy(hit.part)
    return RBX.RaycastResult._new(
        facade,
        hit.px, hit.py, hit.pz,
        hit.nx, hit.ny, hit.nz,
        hit.distance,
        material_enum_for(hit.part))
end

local function workspace_find_parts_in_region3_method(self, region, ignore, maxParts)
    local core = rawget(self, "_core")
    if not core or type(core._physics_region_parts) ~= "function" then
        return {}
    end
    local minx, miny, minz, maxx, maxy, maxz = region_bounds(region)
    if not minx then
        return {}
    end
    local ignore_ids
    if ignore ~= nil then
        ignore_ids = {}
        if type(ignore) == "table" and getmetatable(ignore) == nil then
            for i = 1, #ignore do collect_core_ids(ignore[i], ignore_ids) end
        else
            collect_core_ids(ignore, ignore_ids)
        end
    end
    local parts, n = core:_physics_region_parts(minx, miny, minz, maxx, maxy, maxz, {
        ignore_ids = ignore_ids,
        max_parts = tonumber(maxParts) or nil,
    })
    local out = {}
    local count = n or #parts
    for i = 1, count do
        out[i] = core:_get_or_create_part_proxy(parts[i])
    end
    return out
end

-- viewport px -> world ray. depth defaults to 0
local function camera_viewport_point_to_ray_method(self, x, y, depth)
    local cf = get_camera_instance_property(self, "CFrame") or CFrame.new()
    local fov_deg = get_camera_instance_property(self, "FieldOfView") or 70
    local vp = get_camera_instance_property(self, "ViewportSize")
    local w = (vp and vp.x and vp.x > 0) and vp.x or 1
    local h = (vp and vp.y and vp.y > 0) and vp.y or 1
    depth = tonumber(depth) or 0
    local half = math.tan(math.rad(fov_deg) * 0.5)
    local aspect = w / h
    local ndc_x = (tonumber(x) or 0) / w * 2 - 1
    local ndc_y = 1 - (tonumber(y) or 0) / h * 2
    local sx = ndc_x * half * aspect
    local sy = ndc_y * half
    local R, U, L = cf.RightVector, cf.UpVector, cf.LookVector
    local dirx = R.x * sx + U.x * sy + L.x
    local diry = R.y * sx + U.y * sy + L.y
    local dirz = R.z * sx + U.z * sy + L.z
    local len = math.sqrt(dirx * dirx + diry * diry + dirz * dirz)
    if len < 1e-9 then len = 1 end
    dirx, diry, dirz = dirx / len, diry / len, dirz / len
    return RBX.Ray.new(
        Vector3.new(cf.x + dirx * depth, cf.y + diry * depth, cf.z + dirz * depth),
        Vector3.new(dirx, diry, dirz))
end

local function index_instance(instance, key)
    local method = InstanceMethods[key]
    if method then
        return method
    end
    if INSTANCE_SIGNAL_NAMES[key] then
        return get_signal(instance, key)
    end
    if key == "Parent" then
        return rawget(instance, "_parent")
    end
    if key == "Name" then
        return instance._name
    end
    if key == "ClassName" then
        return instance._class_name
    end
    if key == "Referent" then
        return rawget(instance, "_referent")
    end
    -- bound framework element, set by RBX:_gui_bridge_link_datamodel
    if key == "element" then
        local gui_element = rawget(instance, "_gui_element")
        if gui_element ~= nil then
            return gui_element
        end
    end
    local class_name = rawget(instance, "_class_name")
    local core = rawget(instance, "_core")
    if class_name == "PhysicsService" and PHYSICS_SERVICE[key] then
        return PHYSICS_SERVICE[key]
    end
    -- BasePart-only. merely ACCESSING registers a touch listener so the step's diff considers it
    if key == "Touched" or key == "TouchEnded" then
        local handle = rawget(instance, "_core_handle")
        if handle then
            if core and type(core._register_touch_listener) == "function" then
                core:_register_touch_listener(handle)
            end
            return get_signal(instance, key)
        end
    end
    if class_name == "Workspace" then
        if key == "TouchesUseCollisionGroups" then
            return core._workspace_touches_use_collision_groups == true
        end
        if key == "Gravity" then
            return core._workspace_settings and core._workspace_settings.Gravity or nil
        end
        if key == "FallenPartsDestroyHeight" then
            return core._workspace_settings and core._workspace_settings.FallenPartsDestroyHeight or nil
        end
        if key == "CurrentCamera" then
            return rawget(instance, "_properties").CurrentCamera
        end
        if key == "Raycast" then
            return workspace_raycast_method
        end
        if key == "FindPartsInRegion3" or key == "FindPartsInRegion3WithIgnoreList" then
            return workspace_find_parts_in_region3_method
        end
    elseif class_name == "Camera" then
        if key == "CoordinateFrame" then key = "CFrame"
        elseif key == "focus" then key = "Focus" end
        if key == "CFrame" or key == "Focus" or key == "CameraType" or key == "FieldOfView" or key == "ViewportSize" then
            return get_camera_instance_property(instance, key)
        end
        if key == "ViewportPointToRay" or key == "ScreenPointToRay" then
            return camera_viewport_point_to_ray_method
        end
    elseif class_name == "RunService" then
        if key == "Heartbeat" or key == "RenderStepped" or key == "Stepped"
            or key == "PreSimulation" or key == "FixedHeartbeat" then
            return get_signal(instance, key)
        end
    end
    local rope_property, rope_value = ROPE.public_value(instance, key)
    if rope_property then return rope_value end
    local attachment_property, attachment_value =
        LOCAL_LIGHT.public_attachment_value(instance, key)
    if attachment_property then
        return attachment_value
    end
    local face_property, face_value = FACE_TEXTURE.public_value(instance, key)
    if face_property then
        return face_value
    end
    local mesh_property, mesh_value =
        FACE_TEXTURE.legacy_mesh.public_value(instance, key)
    if mesh_property then
        return mesh_value
    end
    local surface_property, surface_value =
        FACE_TEXTURE.surface_appearance.public_value(instance, key)
    if surface_property then
        return surface_value
    end
    if rawget(instance, "_core_handle") then
        local part_value = get_part_property(instance, key)
        if part_value ~= nil then
            return part_value
        end
    end
    if key == "CollisionGroupId" and not rawget(instance, "_core_handle")
        and is_base_part_class(rawget(instance, "_class_name")) then
        return RBX._collision_group_part.get_id(core, rawget(instance, "_properties"))
    end
    local property = rawget(instance, "_properties")[key]
    if property ~= nil then
        return property
    end
    if rawget(instance, "_class_name") == "SunRaysEffect" then
        local value = runtime_require("sun_rays.lua").defaults[key]
        if value ~= nil then return value end
    end
    local child = rawget(instance, "_child_name_map")[key]
    if child ~= nil then
        return child
    end
    -- mid-stream a missing child = deferred ref that binds later, after load, missing = plain nil
    if core ~= nil and rawget(core, "_async_map_load") ~= nil then
        return get_lazy_ref(instance, key)
    end
    return nil
end

function instance_mt.__index(instance, key)
    return index_instance(instance, key)
end

function instance_mt.__newindex(instance, key, value)
    -- reject before rope wake/invalidation and before any property notifications
    if key == "Size" and is_a(instance, "BasePart") then
        RBX._size_validation.components(value, instance, true)
    end
    if key == "Parent" then
        set_instance_parent(instance, value)
        return
    end
    if key == "Name" then
        set_instance_name(instance, value)
        return
    end
    if key == "ClassName" then
        error("Instance.ClassName is read-only", 2)
    end
    if instance._class_name == "Workspace" then
        if key == "TouchesUseCollisionGroups" then
            assert(type(value) == "boolean", "Workspace.TouchesUseCollisionGroups must be a boolean")
            instance._core._workspace_touches_use_collision_groups = value
            rawget(instance, "_properties")[key] = value
            fire_property_changed(instance, key)
            return
        end
        if key == "Gravity" then
            local numeric = tonumber(value)
            if numeric == nil then
                error("Workspace.Gravity must be numeric", 2)
            end
            instance._core:_apply_workspace_settings({ Gravity = numeric })
            fire_property_changed(instance, key)
            return
        end
        if key == "FallenPartsDestroyHeight" then
            local numeric = tonumber(value)
            if numeric == nil then
                error("Workspace.FallenPartsDestroyHeight must be numeric", 2)
            end
            instance._core:_apply_workspace_settings({ FallenPartsDestroyHeight = numeric })
            fire_property_changed(instance, key)
            return
        end
        if key == "CurrentCamera" then
            if type(value) ~= "table" or value.ClassName ~= "Camera" then
                error("Workspace.CurrentCamera must be a Camera instance", 2)
            end
            if rawget(value, "_datamodel") ~= rawget(instance, "_datamodel") then
                error("Workspace.CurrentCamera cannot reference a Camera from another DataModel", 2)
            end
            if value == instance._properties.CurrentCamera then
                if instance._core and instance._core._set_current_camera_instance then
                    instance._core:_set_current_camera_instance(value)
                end
                return
            end
            instance._properties.CurrentCamera = value
            if instance._core and instance._core._set_current_camera_instance then
                instance._core:_set_current_camera_instance(value)
            end
            sync_effective_lighting_children(rawget(instance, "_datamodel"))
            fire_property_changed(instance, key)
            return
        end
    elseif instance._class_name == "Camera" then
        if key == "CoordinateFrame" then key = "CFrame"
        elseif key == "focus" then key = "Focus" end
        if key == "CFrame" then
            local cframe = cframe_from_value(value, get_camera_instance_property(instance, "CFrame"))
            instance._properties.CFrame = cframe
            if is_active_camera(instance) and instance._core._set_camera_core_cframe then
                instance._core:_set_camera_core_cframe(cframe)
            end
            fire_property_changed(instance, key)
            return
        end
        if key == "Focus" then
            local focus = cframe_from_value(value, get_camera_instance_property(instance, "Focus"))
            instance._properties.Focus = focus
            if is_active_camera(instance) and instance._core._set_camera_core_focus then
                instance._core:_set_camera_core_focus(focus)
            end
            fire_property_changed(instance, key)
            return
        end
        if key == "CameraType" then
            local camera_type = normalize_camera_type_name(value)
            instance._properties.CameraType = camera_type
            if is_active_camera(instance) and instance._core._set_camera_core_type then
                instance._core:_set_camera_core_type(camera_type)
            end
            fire_property_changed(instance, key)
            return
        end
        if key == "FieldOfView" then
            local fov = tonumber(value)
            if fov == nil then
                error("Camera.FieldOfView must be numeric", 2)
            end
            fov = clamp(fov, 1, 120)
            instance._properties.FieldOfView = fov
            if is_active_camera(instance) and instance._core._set_camera_core_field_of_view then
                instance._core:_set_camera_core_field_of_view(fov)
            end
            fire_property_changed(instance, key)
            return
        end
        if key == "ViewportSize" then
            error("Camera.ViewportSize is read-only", 2)
        end
    end
    if rawget(instance, "_class_name") == "Atmosphere" then
        local props = rawget(instance, "_properties")
        local range = ATMOSPHERE_NUMBER_RANGES[key]
        local normalized
        if range then
            normalized = atmosphere_number(
                value, props[key] or RBX._ATMOSPHERE_DEFAULTS[key],
                range[1], range[2], key)
            if props[key] == normalized then
                return
            end
        elseif ATMOSPHERE_COLOR_PROPERTIES[key] then
            normalized = atmosphere_color(value, RBX._ATMOSPHERE_DEFAULTS[key], key)
            if atmosphere_color_equal(props[key], normalized) then
                return
            end
        end
        if normalized ~= nil then
            props[key] = normalized
            fire_property_changed(instance, key)
            local datamodel = rawget(instance, "_datamodel")
            if datamodel
                and rawget(datamodel, "_effective_atmosphere_instance") == instance
                and sync_effective_atmosphere then
                sync_effective_atmosphere(datamodel)
            end
            return
        end
    end
    if ROPE.write(instance, key, value) then
        fire_property_changed(instance, key)
        return
    end
    if RUNTIME_WELD.write(instance, key, value) then
        fire_property_changed(instance, key)
        return
    end
    if LOCAL_LIGHT.apply_attachment_write(instance, key, value) then
        return
    end
    if LOCAL_LIGHT.apply_write(instance, key, value) then
        return
    end
    if FACE_TEXTURE.apply_write(instance, key, value) then
        return
    end
    if FACE_TEXTURE.legacy_mesh.apply_write(instance, key, value) then
        return
    end
    if FACE_TEXTURE.surface_appearance.apply_write(instance, key, value) then
        return
    end
    if rawget(instance, "_core_handle") and set_part_property(instance, key, value) then
        return
    end
    if not rawget(instance, "_core_handle") and is_base_part_class(rawget(instance, "_class_name"))
        and (key == "CollisionGroup" or key == "CollisionGroupId") then
        RBX._collision_group_part.set_passive(rawget(instance, "_core"),
            rawget(instance, "_properties"), key, value)
        fire_property_changed(instance, key)
        return
    end
    -- joint's Enabled toggles the physics weld (disable=split), NoCollisionConstraint's toggles the pair's collision filter
    if key == "Enabled" then
        local cls = rawget(instance, "_class_name")
        if JOINT_INSTANCE_CLASSES[cls] then
            instance._properties[key] = value
            notify_joint_enabled(instance, value)
            fire_property_changed(instance, key)
            return
        elseif NO_COLLISION_INSTANCE_CLASSES[cls] then
            instance._properties[key] = value
            notify_no_collision_enabled(instance, value)
            fire_property_changed(instance, key)
            return
        end
    end
    -- body mover prop edit (e.g. BodyForce.Force) re-syncs its world mover, equal writes (__eq) skip the re-sync
    if BODY_MOVER_INSTANCE_CLASSES[rawget(instance, "_class_name")] then
        local previous = instance._properties[key]
        if previous == value then -- __eq gives Vector3/CFrame component equality
            instance._properties[key] = value
            return
        end
        instance._properties[key] = value
        fire_property_changed(instance, key)
        sync_runtime_mover(instance)
        return
    end
    -- gui-bridged facade: forward write to gui node proxy (marks surfacegui dirty + resyncs element), property store stays authoritative for reads
    if RBX._gui_root_facade_write then RBX._gui_root_facade_write(instance,key,value)end
    local gui_node = rawget(instance, "_gui_node")
    if gui_node ~= nil and RBX._gui_bridge_apply_facade_write then
        RBX._gui_bridge_apply_facade_write(instance, gui_node, key, value)
    end
    -- Lighting facade write -> live renderer state (set_lighting_property), Color3-like tables convert to raw {r,g,b}
    if rawget(instance, "_service_name") == "Lighting" then
        local datamodel = rawget(instance, "_datamodel")
        local core = datamodel and datamodel._core or nil
        if core and core.set_lighting_property then
            local raw_value = value
            if type(value) == "table" then
                local r = value.r or value.R
                local g = value.g or value.G
                local b = value.b or value.B
                if r ~= nil or g ~= nil or b ~= nil then
                    raw_value = { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0 }
                end
            end
            local ok, reason = core:set_lighting_property(key, raw_value)
            if ok and (key == "ClockTime" or key == "TimeOfDay") then
                instance._properties.ClockTime = core.lighting_state.clock_time
                instance._properties.TimeOfDay = core.lighting_state.time_of_day
                value = instance._properties[key]
            end
        end
    end
    instance._properties[key] = value
    if LIGHTING_CHILD_FIELDS[rawget(instance, "_class_name")] then
        sync_effective_lighting_children(rawget(instance, "_datamodel"))
    end
    fire_property_changed(instance, key)
end

instance_mt.__tostring = function(instance)
    return string.format("%s<%s>", tostring(instance._class_name), tostring(instance._name))
end

local function datamodel_warn(datamodel, legacy_name, replacement)
    if datamodel._debug_deprecation_warnings ~= true then
        return
    end
    local seen = rawget(datamodel, "_deprecation_warning_seen")
    if not seen then
        seen = {}
        rawset(datamodel, "_deprecation_warning_seen", seen)
    end
    if seen[legacy_name] then
        return
    end
    seen[legacy_name] = true
    print(string.format("[rbx] %s is a compatibility alias, use %s", legacy_name, replacement))
end

function ServiceProviderMethods:FindService(service_name)
    if type(service_name) ~= "string" then
        return nil
    end
    return self._services_by_name and self._services_by_name[service_name] or nil
end

function ServiceProviderMethods:GetService(service_name)
    if type(service_name) ~= "string" then
        error("GetService expected a service name", 2)
    end
    local service = self:FindService(service_name)
    if service then
        return service
    end
    if not SERVICE_CLASSES[service_name] then
        error("Unknown service '" .. service_name .. "'", 2)
    end
    return self:_ensure_service(service_name)
end

local function delegate_core_method(method_name)
    return function(self, ...)
        return self._core[method_name](self._core, ...)
    end
end

-- host integration for transient/animated geometry. Simulation properties
-- remain authored, only this instance's draw ownership becomes persistent
function DataModelMethods:retain_dynamic_geometry(instance)
    assert(type(instance)=="table" and rawget(instance,"_datamodel")==self,
        "Dynamic geometry must belong to this world")
    local part=assert(rawget(instance,"_core_handle"),"Dynamic geometry requires a BasePart")
    return self._core:_retain_dynamic_part_geometry(part)
end

-- a small owner-controlled cache may store a retired transient outside
-- Workspace without discarding its independently-owned draw chunk. the core
-- keeps that chunk completely out of active scene lists until this same
-- Instance returns to Workspace, destroying it still releases the chunk
function DataModelMethods:preserve_dynamic_geometry_while_stored(instance)
    assert(type(instance)=="table" and rawget(instance,"_datamodel")==self,
        "Dynamic geometry must belong to this world")
    local part=assert(rawget(instance,"_core_handle"),"Dynamic geometry requires a BasePart")
    return self._core:_preserve_dynamic_part_geometry_while_stored(part)
end

-- build one opted-in stored owner into the dormant geometry cache. it stays
-- outside active scene and physics membership until its owner republishes it
function DataModelMethods:prepare_dynamic_geometry_while_stored(instance)
    assert(type(instance)=="table" and rawget(instance,"_datamodel")==self,
        "Stored dynamic preparation must belong to this world")
    local part=assert(rawget(instance,"_core_handle"),"Stored dynamic preparation requires a BasePart")
    return self._core:_prepare_dynamic_part_geometry_while_stored(part)
end

for index = 1, #INTEGRATION_METHODS do
    local method_name = INTEGRATION_METHODS[index]
    DataModelMethods[method_name] = delegate_core_method(method_name)
end

-- fires queued Touched/TouchEnded: physics step records core part pairs (deferred so callbacks can't mutate sim mid-step)
function DataModelMethods:_flush_touch_events()
    local core = self._core
    local queue = core and rawget(core, "_pending_touch_events")
    if not queue or #queue == 0 then
        return
    end
    -- swap queue before firing so re-entrant touches land in the next batch
    core._pending_touch_events = {}
    local by_core_id = self._instance_by_core_id
    -- resolves a core part to its user facade without fabricating a fresh one (destroyed part -> real node or nil, never a phantom orphan)
    local function resolve(part)
        if not part then return nil end
        local inst = by_core_id[part._id]
        if inst then return inst end
        return rawget(part, "_instance_node")
    end
    for i = 1, #queue do
        local ev = queue[i]
        local a = resolve(ev.a)
        local b = resolve(ev.b)
        -- fire only on the still-live side, passing the (maybe destroyed) other as arg, matching roblox
        if a and not rawget(a, "_destroyed") then
            fire_signal(a, ev.phase, b)
        end
        if b and not rawget(b, "_destroyed") then
            fire_signal(b, ev.phase, a)
        end
    end
end

local function sane_frame_delta(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge or value < 0 then
        return 0
    end
    return value
end

function DataModelMethods:update(dt)
    local frame_dt = sane_frame_delta(dt)
    local run_service = self:FindService("RunService")
    local signals = run_service and rawget(run_service, "_signals")
    local fixed = signals and signals.FixedHeartbeat

    -- FixedHeartbeat intentionally remains a per-substep hook. it is the
    -- right place for deterministic physics controllers, whereas Roblox's
    -- public frame events run once before the simulation batch
    self._core._fixed_heartbeat = fixed and fixed._connection_count > 0 and fixed or nil

    -- these are DataModel-private bookkeeping fields.  Reading or assigning
    -- through the public Instance metatable makes an unknown name look like a
    -- Roblox property (and, with imported map data, can resolve to a table)
    -- keep timing state raw so an authored property can never corrupt the
    -- RunService clock
    local elapsed = rawget(self, "_run_service_elapsed") or 0
    rawset(self, "_run_service_elapsed", elapsed + frame_dt)
    rawset(self, "_last_update_dt", frame_dt)
    if run_service then
        -- Stepped is retained for legacy Roblox code. both it and
        -- PreSimulation are frame events: a catch-up update must not invoke
        -- user frame callbacks once per internal fixed step
        fire_signal(run_service, "Stepped", elapsed, frame_dt)
        fire_signal(run_service, "PreSimulation", frame_dt)
    end

    self._core:update(frame_dt)
    self:_flush_touch_events()
    if run_service then
        fire_signal(run_service, "Heartbeat", frame_dt)
    end
end

function DataModelMethods:draw()
    local run_service = self:FindService("RunService")
    if run_service then
        fire_signal(run_service, "RenderStepped", rawget(self, "_last_update_dt") or 0)
    end
    return self._core:draw()
end

function DataModel:_new_instance(class_name, name)
    return make_instance(self, class_name, name)
end

function DataModel:_link_core_handle(instance, part)
    if type(instance) ~= "table" or type(part) ~= "table" then
        return instance
    end
    rawset(instance, "_core_handle", part)
    rawset(instance, "_core_handle_id", part._id)
    rawset(instance, "_referent", part._map_referent or rawget(instance, "_referent"))
    part._instance_node = instance
    self._instance_by_core_id[part._id] = instance
    local referent = rawget(instance, "_referent")
    if referent then
        self._instance_by_referent[referent] = instance
    end
    return instance
end

function DataModel:_instance_for_core_part(part)
    if not part then
        return nil
    end
    local instance = self._instance_by_core_id[part._id]
    if not instance and part._map_referent then
        instance = self._instance_by_referent[part._map_referent]
    end
    if not instance and part._instance_node and not rawget(part._instance_node, "_destroyed") then
        instance = part._instance_node
    end
    if instance then
        return self:_link_core_handle(instance, part)
    end
    instance = make_instance(self, part.ClassName, part.Name)
    return self:_link_core_handle(instance, part)
end

function DataModel:_ensure_service(service_name)
    local service = self._services_by_name[service_name]
    if service then
        return service
    end
    service = make_instance(self, service_name, service_name)
    rawset(service, "_service_name", service_name)
    rawset(service, "_is_service", true)
    rawset(service, "_parent_locked", service_name ~= "Workspace" and service_name ~= "Lighting" and service_name ~= "RunService")
    self._services_by_name[service_name] = service
    rawset(self, service_name, service)
    service.Parent = self

    if service_name == "Workspace" then
        local camera = make_instance(self, "Camera", "Camera")
        initialize_camera_instance(camera, nil, true)
        service._properties.CurrentCamera = camera
        camera.Parent = service
        if self._core and self._core._set_current_camera_instance then
            self._core:_set_current_camera_instance(camera)
        end
    end
    return service
end

function DataModel:_bootstrap_services()
    self:_ensure_service("Workspace")
    self:_ensure_service("Lighting")
    self:_ensure_service("RunService")
end

function DataModel:_clear_non_service_children()
    local workspace = self._services_by_name.Workspace
    local camera = workspace and workspace._properties.CurrentCamera
    if type(camera) == "table" and rawget(camera, "_class_name") == "Camera"
        and rawget(camera, "_destroyed") ~= true
        and rawget(camera, "_datamodel") == self then
        -- map replacement preserves the active embedding camera, not every
        -- old Camera. extract it before retiring a nested source ancestor and
        -- snapshot actual core state before the final current-camera sync
        initialize_camera_instance(camera, camera_instance_snapshot(camera))
        if camera.Parent ~= workspace then camera.Parent = workspace end
        for index = #camera._children, 1, -1 do
            local child = camera._children[index]
            if rawget(child, "_referent") then child.Parent = nil end
        end
    else
        camera = nil
    end
    for index = #self._children, 1, -1 do
        local child = self._children[index]
        if not child._is_service then
            child.Parent = nil
        end
    end
    for _, service in pairs(self._services_by_name) do
        for index = #service._children, 1, -1 do
            local child = service._children[index]
            if child ~= camera then
                child.Parent = nil
            end
        end
    end
end

-- Diagnostic-only structural census, independent of the promotion dispatch
-- Ordinary property graphs can be cyclic/shared/typed, only the Source tree
-- must be unambiguous. Unsupported structure withholds detail, never loading
local function census_source_copy(roots)
    local detail = {
        expected_calls = 0, expected_scalar_roots = 0, expected_table_roots = 0,
        attempted_calls = 0, completed_calls = 0,
        scalar_roots = 0, table_roots = 0, wall_seconds = 0,
    }
    local seen, nodes = {}, 0
    local visit
    local function visit_children(children, depth, top)
        if children == nil or children == false then return true end
        if type(children) ~= "table" or getmetatable(children) ~= nil
            or seen[children] then return false end
        seen[children] = true
        local count, length = 0, #children
        if length > 250000 then return false end
        for key in pairs(children) do
            if type(key) ~= "number" or key < 1 or key > length
                or key ~= math.floor(key) then return false end
            count = count + 1
        end
        if count ~= length then return false end
        for index = 1, length do
            if not visit(children[index], depth, top) then return false end
        end
        return true
    end
    visit = function(source, depth, top)
        if type(source) ~= "table" or getmetatable(source) ~= nil
            or seen[source] or depth > 512 then return false end
        seen[source] = true
        nodes = nodes + 1
        if nodes > 250000 then return false end
        if not (top and (source.ClassName == "DataModel"
            or source.ClassName == "Game")) then
            detail.expected_calls = detail.expected_calls + 1
            for key, value in pairs(source) do
                if key ~= "Children" and key ~= "Parent"
                    and key ~= "_dom_instance" and key ~= "Name"
                    and key ~= "ClassName" and key ~= "CurrentCamera" then
                    if type(value) == "table" then
                        detail.expected_table_roots = detail.expected_table_roots + 1
                    else
                        detail.expected_scalar_roots = detail.expected_scalar_roots + 1
                    end
                end
            end
        end
        return visit_children(source.Children, depth + 1, false)
    end
    if visit_children(roots, 1, true) then return detail end
end

function RBX._validate_source_copy_profile(detail, construction_wall)
    if type(detail) ~= "table" or type(construction_wall) ~= "number"
        or not (construction_wall >= 0 and construction_wall < math.huge) then
        return false
    end
    for _, key in ipairs({ "expected_calls", "expected_scalar_roots",
        "expected_table_roots", "attempted_calls", "completed_calls",
        "scalar_roots", "table_roots" }) do
        local count = detail[key]
        if type(count) ~= "number" or not (count >= 0 and count < math.huge)
            or count ~= math.floor(count) then return false end
    end
    return detail.expected_calls == detail.attempted_calls
        and detail.attempted_calls == detail.completed_calls
        and detail.expected_scalar_roots == detail.scalar_roots
        and detail.expected_table_roots == detail.table_roots
        and type(detail.wall_seconds) == "number"
        and detail.wall_seconds >= 0 and detail.wall_seconds <= construction_wall
        and (detail.completed_calls > 0 or (detail.wall_seconds == 0
            and detail.scalar_roots == 0 and detail.table_roots == 0))
end

local function copy_source_properties_to_instance(source, instance, detail)
    local start
    if detail then
        detail.attempted_calls = detail.attempted_calls + 1
        start = love.timer.getTime()
    end
    for key, value in pairs(source or {}) do
        if key ~= "Children"
            and key ~= "Parent"
            and key ~= "_dom_instance"
            and key ~= "Name"
            and key ~= "ClassName"
            and key ~= "CurrentCamera" then
            instance._properties[key] = copy_runtime_value(value)
            if detail then
                if type(value) == "table" then
                    detail.table_roots = detail.table_roots + 1
                else
                    detail.scalar_roots = detail.scalar_roots + 1
                end
            end
        end
    end
    if detail then
        local elapsed = love.timer.getTime() - start
        detail.wall_seconds = elapsed >= 0 and elapsed < math.huge
            and (detail.wall_seconds + elapsed) or (0 / 0)
        detail.completed_calls = detail.completed_calls + 1
    end
end

function DataModel:_promote_source_node(source, authored_index, copy_detail, progress)
    if type(source) ~= "table" then
        return nil
    end
    local referent = source.Referent
    local part = referent and self._core._runtime_part_by_referent and self._core._runtime_part_by_referent[referent] or nil
    local instance
    local camera_state
    local current = source.ClassName == "Camera" and self._core._current_camera_instance
    if rawget(self, "_promote_pending_movers") and current and referent
        and rawget(current, "_referent") == referent
        and rawget(current, "_destroyed") ~= true
        and rawget(current, "_datamodel") == self then
        -- a selected authored camera survives reload as one facade/referent
        -- it rejoins the new authored hierarchy but retains the live view
        instance = current
        camera_state = camera_instance_snapshot(current)
        instance.Parent = nil -- promote_attach requires an unparented node
        instance._name = source.Name or instance._name
    elseif part then
        instance = self:_instance_for_core_part(part)
        instance._class_name = part.ClassName
        instance._name = part.Name
    else
        instance = make_instance(self, source.ClassName or "Instance",
            source.Name or source.ClassName or "Instance", true)
    end
    rawset(instance, "_referent", referent or rawget(instance, "_referent"))
    local instance_referent = rawget(instance, "_referent")
    if instance_referent then
        self._instance_by_referent[instance_referent] = instance
    end
    copy_source_properties_to_instance(source, instance, copy_detail)
    if is_base_part_class(instance._class_name) then
        local resolved_group = RBX._collision_group_policy.resolve_source(self._core, source)
        local source_part = rawget(instance, "_core_handle")
        if source_part then
            self._core:_set_runtime_part_collision_group(source_part, resolved_group)
        else
            -- Passive storage remains passive. its Clone reparses these
            -- authoritative named props without importing a new world policy
            RBX._collision_group_part.set_passive(self._core, instance._properties,
                "CollisionGroup", resolved_group)
        end
    end
    if progress then progress:step()end
    if instance._class_name == "Camera" then
        initialize_camera_instance(instance, camera_state or source)
    end
    initialize_atmosphere_instance(instance)
    LOCAL_LIGHT.initialize(instance, source)
    FACE_TEXTURE.initialize(instance, source, authored_index)
    FACE_TEXTURE.legacy_mesh.initialize(instance, source, true)
    FACE_TEXTURE.surface_appearance.initialize(
        instance, source, authored_index)
    -- body movers bind to their parent part, collected here and synced once at the end of
    -- promotion (when the full tree is attached), replacing the per-node sync_runtime_mover
    if BODY_MOVER_INSTANCE_CLASSES[rawget(instance, "_class_name")] then
        local pm = self._promote_pending_movers
        if pm then pm[#pm + 1] = instance end
    end
    for index = 1, #(source.Children or {}) do
        local child = self:_promote_source_node(source.Children[index], index, copy_detail, progress)
        if child then
            promote_attach(instance, child)
        end
    end
    FACE_TEXTURE.bind_promoted_children(instance)
    FACE_TEXTURE.legacy_mesh.bind_promoted_children(instance)
    FACE_TEXTURE.surface_appearance.bind_promoted_children(instance)
    return instance
end

function DataModelMethods:load_map_async(map_path, options)
    if options ~= nil and type(options) ~= "table" then
        return false, "load_map_async options must be a table or nil"
    end
    options = options or {}
    for key in pairs(options) do
        if not PUBLIC_ASYNC_MAP_LOAD_OPTIONS[key] then
            return false, "Unknown public load_map_async option '"
                .. tostring(key) .. "'"
        end
    end
    if options.on_complete ~= nil
        and type(options.on_complete) ~= "function" then
        return false, "load_map_async on_complete must be a function or nil"
    end
    -- public async loads retain the complete DataModel/cache path. Coroutine
    -- slicing is an implementation detail governed by the renderer default
    return self._core:load_map_async(map_path, {
        parse_on_main = true,
        on_complete = options.on_complete,
    })
end

function DataModel:_merge_service_source(service, source, copy_detail, progress)
    if rawget(service, "_class_name") == "Workspace" then
        RBX._collision_group_policy.bind_workspace(self._core, service)
    end
    copy_source_properties_to_instance(source, service, copy_detail)
    if progress then progress:step()end
    service.Name = source.Name or service.Name
    if service._class_name == "Workspace" then
        service.TouchesUseCollisionGroups = source.TouchesUseCollisionGroups == true
        if source.Gravity ~= nil then
            service.Gravity = source.Gravity
        end
        if source.FallenPartsDestroyHeight ~= nil then
            service.FallenPartsDestroyHeight = source.FallenPartsDestroyHeight
        end
    end
    for index = 1, #(source.Children or {}) do
        local child = self:_promote_source_node(source.Children[index], index, copy_detail, progress)
        if child then
            promote_attach(service, child)
        end
    end
end

function DataModel:_ensure_workspace_current_camera()
    local workspace = self:GetService("Workspace")
    local props = rawget(workspace, "_properties") or {}
    local camera = props.CurrentCamera
    local valid = type(camera) == "table"
        and rawget(camera, "_destroyed") ~= true
        and rawget(camera, "_class_name") == "Camera"
        and rawget(camera, "_datamodel") == self

    if not valid then
        camera = nil
        for index = 1, #(workspace._children or {}) do
            local child = workspace._children[index]
            if type(child) == "table"
                and rawget(child, "_destroyed") ~= true
                and rawget(child, "_class_name") == "Camera" then
                camera = child
                break
            end
        end
        if not camera then
            camera = make_instance(self, "Camera", "Camera")
            initialize_camera_instance(camera)
            camera.Parent = workspace
        end
        props.CurrentCamera = nil
        workspace.CurrentCamera = camera
    else
        props.CurrentCamera = camera
    end

    if self._core and self._core._set_current_camera_instance then
        -- the selected camera may outlive a source container absent from the
        -- new map. keep it reachable without preserving obsolete ancestors
        local ancestor = camera.Parent
        while ancestor and ancestor ~= workspace do ancestor = ancestor.Parent end
        if ancestor ~= workspace then camera.Parent = workspace end
        self._core:_set_current_camera_instance(camera)
    end
    return camera
end

function DataModel:_promote_instance_roots(instance_roots, profile, detail_profile, checkpoint)
    local progress=checkpoint and runtime_require('loading_progress.lua').new(checkpoint,'datamodel_promote',32)
    if progress then progress:mark('datamodel:prepare')end
    -- the separate invasive opt-in adds a source-only census before the coarse
    -- marks. its overhead is inside the outer call, not construction. no graph
    -- references escape and failed promotion cannot return complete detail
    local copy_detail = profile == true and detail_profile == true
        and census_source_copy(type(instance_roots) == "table" and instance_roots or {})
        or nil
    local marks = profile == true and { love.timer.getTime() } or nil
    self._suppress_signals = true
    LOCAL_LIGHT.begin_promotion(self)
    if marks then marks[2] = love.timer.getTime() end
    rawset(self, "_promote_pending_movers", {})
    local roots = type(instance_roots) == "table" and instance_roots or {}
    local map_identity = self._core._map_build_path or self._core.map_path
    local previous_identity = rawget(self, "_promoted_map_identity")
    local same_map = map_identity and previous_identity == map_identity
        or (map_identity == nil and type(previous_identity) == "table"
            and previous_identity[1] == roots)
    -- production loads have a path namespace. Direct in-memory promotion can
    -- only prove identity for the same root array, a weak reference must not
    -- retain an otherwise retired full parsed graph
    rawset(self, "_promoted_map_identity",
        map_identity or setmetatable({ roots }, { __mode = "v" }))
    local active = self._core._current_camera_instance
    if not same_map and active and rawget(active, "_referent") then
        retire_camera_source_identity(active)
    end
    self:_clear_non_service_children()
    self._core._rope_instances = {}
    self._core._rope_dependencies = {}
    ROPE.invalidate(self._core)
    self._instance_by_referent = {}
    self._instance_by_core_id = {}
    if marks then marks[3] = love.timer.getTime() end
    for index = 1, #roots do
        local source = roots[index]
        local class_name = source and source.ClassName
        if class_name == "DataModel" or class_name == "Game" then
            for child_index = 1, #(source.Children or {}) do
                local child_source = source.Children[child_index]
                local service = child_source and self:FindService(child_source.ClassName)
                if service then
                    self:_merge_service_source(service, child_source, copy_detail, progress)
                else
                    local child = self:_promote_source_node(child_source, nil, copy_detail, progress)
                    if child then
                        promote_attach(self, child)
                    end
                end
            end
        elseif SERVICE_CLASSES[class_name] then
            self:_merge_service_source(self:GetService(class_name), source, copy_detail, progress)
        else
            local child = self:_promote_source_node(source, nil, copy_detail, progress)
            if child then
                promote_attach(self, child)
            end
        end
    end

    if marks then marks[4] = love.timer.getTime() end
    if progress then progress:mark('datamodel:roots-ready',progress.count)end
    local workspace = self:GetService("Workspace")
    for index = 1, #(self._core.parts or {}) do
        if progress and index%64==0 then progress:mark('datamodel:attach-parts',index,#self._core.parts)end
        local part = self._core.parts[index]
        if part and not part._destroyed and not part._instance_node then
            promote_attach(workspace, self:_instance_for_core_part(part))
        end
    end
    -- deferred single mover sync now that the whole tree is attached (parents resolved)
    local pending_movers = self._promote_pending_movers
    rawset(self, "_promote_pending_movers", nil)
    if pending_movers then
        for i = 1, #pending_movers do
            sync_runtime_mover(pending_movers[i])
            if progress and i%32==0 then progress:mark('datamodel:movers',i,#pending_movers)end
        end
    end
    -- a selected source Camera may have been removed or replaced by another
    -- class even within one file. preserve its view, not an obsolete ID that
    -- now belongs to another promoted object
    active = self._core._current_camera_instance
    local active_referent = active and rawget(active, "_referent")
    if active_referent and self._instance_by_referent[active_referent] ~= active then
        retire_camera_source_identity(active)
    end
    self:_ensure_workspace_current_camera()
    if progress then progress:mark('datamodel:camera-ready')end
    if marks then marks[5] = love.timer.getTime() end
    -- build gui element trees + wire instance.element by referent, bridge failure must not break map load (falls back to legacy renderer)
    if self._core and self._core._gui_bridge_link_datamodel then
        local ok, link_err = pcall(self._core._gui_bridge_link_datamodel, self._core, self, progress)
        if not ok then
            if progress and progress.failed then error(progress.failed,0)end
            print("[rbx ui] facade linking failed: " .. tostring(link_err))
        end
    end
    if marks then marks[6] = love.timer.getTime() end
    if progress then progress:mark('datamodel:gui-ready')end
    LOCAL_LIGHT.end_promotion(self)
    if marks then marks[7] = love.timer.getTime() end
    self._suppress_signals = false
    FACE_TEXTURE.flush_promotion_dirty(self)
    FACE_TEXTURE.legacy_mesh.flush_promotion_dirty(self)
    FACE_TEXTURE.surface_appearance.flush_promotion_dirty(self)
    -- the parsed LightingState is already installed by the loader. this links
    -- its promoted Atmosphere facade in one final transaction (the render-side
    -- value comparison makes the common matching case revision-free)
    sync_effective_atmosphere(self)
    local camera = self._services_by_name.Workspace._properties.CurrentCamera
    for _, child in ipairs(camera and rawget(camera, "_children") or {}) do
        if rawget(child, "_class_name") == "SunRaysEffect" then
            sync_effective_lighting_children(self);break
        end
    end
    -- the service object survives map replacement, but its old lighting values
    -- must not. mirror the one normalized effective state, including defaults
    -- for absent fields and both public time aliases, once at publication
    local state = self._core.lighting_state
    local service = self._services_by_name.Lighting
    if state and service then
        local fields = {
            Brightness="brightness", GlobalShadows="global_shadows", ClockTime="clock_time", TimeOfDay="time_of_day",
            GeographicLatitude="geographic_latitude", ExposureCompensation="exposure_compensation",
            EnvironmentDiffuseScale="environment_diffuse_scale", EnvironmentSpecularScale="environment_specular_scale",
            ShadowSoftness="shadow_softness", FogStart="fog_start", FogEnd="fog_end",
            LightingStyle="lighting_style", Technology="technology", PrioritizeLightingQuality="prioritize_lighting_quality",
        }
        for name, key in pairs(fields) do service._properties[name] = state[key] end
        for name, key in pairs({ Ambient="ambient_color", OutdoorAmbient="outdoor_ambient",
            ColorShift_Top="color_shift_top", ColorShift_Bottom="color_shift_bottom", FogColor="fog_color" }) do
            local value = state[key]
            if value then service._properties[name] = RBX.Color3.new(value[1],value[2],value[3]) end
        end
    end
    if marks then
        marks[8] = love.timer.getTime()
        return marks, RBX._validate_source_copy_profile(copy_detail,
            marks[4] - marks[3]) and copy_detail or nil
    end
end

function DataModel:Destroy()
    if self._destroyed then
        return
    end

    local core = rawget(self, "_core")
    if core then
        core._tearing_down = true
    end

    local destroy_ok, destroy_error = xpcall(function()
        InstanceMethods.Destroy(self)
    end, debug.traceback)
    if not destroy_ok and not self._destroyed then
        -- a user Destroying callback must not prevent structural cleanup. run
        -- the root walk once more with signals suppressed, then report the
        -- original callback error after renderer resources are safely retired
        self._suppress_signals = true
        pcall(InstanceMethods.Destroy, self)
    end

    local cleanup_ok, cleanup_error = true, nil
    if core and core.Destroy then
        cleanup_ok, cleanup_error = xpcall(function()
            core:Destroy(self)
        end, debug.traceback)
    elseif core then
        core._tearing_down = false
    end

    self._services_by_name = {}
    self._instance_by_referent = {}
    self._instance_by_core_id = {}
    self._instance_api = nil
    rawset(self, "_core", nil)

    if not destroy_ok then
        error(destroy_error, 0)
    end
    if not cleanup_ok then
        error(cleanup_error, 0)
    end
end

local function index_datamodel(datamodel, key)
    local method = DataModel[key] or DataModelMethods[key] or ServiceProviderMethods[key] or InstanceMethods[key]
    if method then
        return method
    end
    if key == "Workspace" or key == "Lighting" or key == "RunService" then
        return datamodel:GetService(key)
    end
    if key == "CFrame" then
        datamodel_warn(datamodel, "game.CFrame", "rbx.CFrame")
        return RBX.CFrame
    end
    if key == "Vector3" then
        datamodel_warn(datamodel, "game.Vector3", "rbx.Vector3")
        return RBX.Vector3
    end
    if key == "Color3" then
        datamodel_warn(datamodel, "game.Color3", "rbx.Color3")
        return RBX.Color3
    end
    if key == "Enum" then
        datamodel_warn(datamodel, "game.Enum", "rbx.Enum")
        return RBX.Enum
    end
    if key == "Instance" then
        datamodel_warn(datamodel, "game.Instance", "rbx.Instance")
        return datamodel._instance_api
    end
    if key == "Part" then
        datamodel_warn(datamodel, "game.Part", "game.Workspace:GetChildren() or game.Workspace:FindFirstChild(...)")
        return datamodel._core._part_explorer
    end
    return index_instance(datamodel, key)
end

function datamodel_mt.__index(datamodel, key)
    return index_datamodel(datamodel, key)
end

function datamodel_mt.__newindex(datamodel, key, value)
    if key == "Parent" then
        error("DataModel.Parent is read-only", 2)
    end
    return instance_mt.__newindex(datamodel, key, value)
end

datamodel_mt.__tostring = function(datamodel)
    return string.format("DataModel<%s>", tostring(datamodel._name))
end

function RBX:_create_datamodel_public(options)
    local datamodel = {
        _core = self,
        _datamodel = nil,
        _class_name = "DataModel",
        _name = "game",
        _parent = nil,
        _children = {},
        _child_name_map = {},
        _properties = {},
        _signals = {},
        _property_signals = {},
        _destroyed = false,
        _services_by_name = {},
        _instance_by_referent = {},
        _instance_by_core_id = {},
        _effective_atmosphere_instance = false,
        _atmosphere_sync_pending = false,
        _syncing_atmosphere = false,
        _suppress_signals = false,
        _deprecation_warning_seen = false,
        -- raw DataModel bookkeeping must exist before async map loading can
        -- expose deferred instance references through __index
        _run_service_elapsed = 0,
        _last_update_dt = 0,
        _debug_deprecation_warnings = options and options.debug_deprecation_warnings == true,
    }
    datamodel._datamodel = datamodel
    datamodel._instance_api = {
        new = function(class_name, properties)
            return datamodel:_new_public_instance(class_name, properties)
        end,
        GetSupportedClasses = function()
            local classes = LOCAL_LIGHT.append_supported(FACE_TEXTURE.append_supported({
                "Folder", "Model", "Camera", "Atmosphere", "Attachment", "RopeConstraint", "RodConstraint",
            }))
            for class_name in pairs(SUPPORTED_PART_CLASSES or {}) do
                classes[#classes + 1] = class_name
            end
            table.sort(classes)
            return classes
        end,
    }
    setmetatable(datamodel, datamodel_mt)
    datamodel:_bootstrap_services()
    self._datamodel = datamodel
    return datamodel
end

function DataModel:_new_public_instance(class_name, properties)
    class_name = tostring(class_name or "Instance")
    properties = type(properties) == "table" and properties or nil
    local parent = properties and properties.Parent or nil
    local instance
    if is_base_part_class(class_name) then
        local part = self._core:_create_runtime_part(class_name, properties)
        instance = part and part._instance_node
    else
        if class_name ~= "Instance" and not GENERIC_INSTANCE_CLASSES[class_name] and not SERVICE_CLASSES[class_name] then
            -- unsupported non-render classes still participate in hierarchy semantics
        end
        instance = make_instance(self, class_name, class_name)
        RUNTIME_WELD.initialize(instance)
        if class_name == "Camera" then
            initialize_camera_instance(instance)
        end
        if properties then
            for key, value in pairs(properties) do
                if key ~= "Parent" then
                    instance[key] = value
                end
            end
        end
        if parent ~= nil then
            instance.Parent = parent
        end
    end
    return instance
end

function RBX:_attach_runtime_part_to_datamodel(part, parent)
    local datamodel = self._datamodel
    if not datamodel or type(part) ~= "table" then
        return nil
    end
    local instance = datamodel:_instance_for_core_part(part)
    instance._class_name = part.ClassName
    instance._name = part.Name
    if parent ~= nil then
        instance.Parent = parent
    elseif self._set_runtime_part_workspace_membership then
        self:_set_runtime_part_workspace_membership(part,instance_is_in_workspace(instance))
    end
    return instance
end

function RBX:_promote_instance_roots(instance_roots, profile, detail_profile, checkpoint)
    if self._datamodel then
        return self._datamodel:_promote_instance_roots(instance_roots, profile, detail_profile, checkpoint)
    end
end

function RBX:_get_or_create_part_proxy(part)
    if self._datamodel then
        return self._datamodel:_instance_for_core_part(part)
    end
    return nil
end

function RBX:_build_instance_api()
    local core = self
    return {
        new = function(class_name, properties)
            local datamodel = core._datamodel or RBX._active_datamodel
            if not datamodel then
                error("Instance.new requires an active DataModel", 2)
            end
            return datamodel:_new_public_instance(class_name, properties)
        end,
        GetSupportedClasses = function()
            local classes = LOCAL_LIGHT.append_supported(FACE_TEXTURE.append_supported({
                "Folder", "Model", "Camera", "Atmosphere",
            }))
            for class_name in pairs(SUPPORTED_PART_CLASSES or {}) do
                classes[#classes + 1] = class_name
            end
            table.sort(classes)
            return classes
        end,
    }
end

RBX.Instance = {
    new = function(class_name, properties)
        local datamodel = RBX._active_datamodel
        if not datamodel then
            error("rbx.Instance.new requires an active DataModel; call rbx.new(...) first", 2)
        end
        return datamodel:_new_public_instance(class_name, properties)
    end,
    GetSupportedClasses = function()
        local classes = LOCAL_LIGHT.append_supported(FACE_TEXTURE.append_supported({
            "Folder", "Model", "Camera", "Atmosphere", "Attachment", "RopeConstraint", "RodConstraint",
        }))
        for class_name in pairs(SUPPORTED_PART_CLASSES or {}) do
            classes[#classes + 1] = class_name
        end
        table.sort(classes)
        return classes
    end,
}

RBX._DataModel = DataModel
RBX._InstanceMethods = InstanceMethods

-- -> raycasts, filter_misses since the last reset. `reset` makes it a per-frame delta
function DataModel.get_raycast_stats(reset)
    local r, m = stat_raycasts, stat_filter_misses
    if reset then
        stat_raycasts, stat_filter_misses = 0, 0
    end
    return r, m
end

-- explicit offline cooked geometry, ordinary MeshParts and Part+SpecialMesh
-- retain their existing colliders. Validation takes an owned copy and never
-- cooks, fetches assets, or changes an authored source archive
function DataModelMethods:create_collision_decomposition_cache(data,checkpoint)
    return runtime_require('physics/convex_decomposition.lua').create_cache(self,data,checkpoint)
end

function DataModelMethods:set_part_collision_decomposition(instance,data)
    assert(type(instance)=='table'and rawget(instance,'_datamodel')==self,'Collision geometry needs an Instance owned by this DataModel')
    assert(not rawget(instance,'_destroyed'),'Cannot change collision geometry of a destroyed Instance')
    local class=rawget(instance,'_class_name')
    assert(class=='MeshPart'or class=='UnionOperation'or class=='PartOperation'or class=='NegateOperation',
        'Offline mesh decomposition applies only to MeshParts and unions')
    local part=assert(rawget(instance,'_core_handle'),'Part has no native geometry handle')
    local Convex=runtime_require('physics/convex_decomposition.lua')
    local cache=data and Convex.resolve_cache(self,data)or nil
    if cache and cache.source_kind=='part' then
        -- Bound to bytes the part itself carries (authored or embedded data)
        local bytes=part[cache.source_field]
        assert(type(bytes)=='string'and bytes~='','Decomposition source field is empty: '..tostring(cache.source_field))
        assert(love.data.encode('string','hex',love.data.hash('sha256',bytes))==cache.mesh_sha256,
            'Decomposition SHA256 does not match the part\'s '..cache.source_field)
    elseif cache then
        -- Bind an offline cache to the same local bytes the renderer resolves
        -- this rare setter performs no remote asset request or runtime cook
        local core=self._core
        local path=assert(core:_resolve_asset_path(part.MeshId,'mesh'),'Decomposition requires a resolved local MeshPart asset')
        local info=assert(love.filesystem.getInfo(path,'file'),'Decomposition mesh asset is not a local file')
        core._collision_source_hashes=core._collision_source_hashes or{}
        local previous=core._collision_source_hashes[path]
        if not previous or previous.size~=info.size or previous.modtime~=info.modtime then
            local bytes=assert(love.filesystem.read(path),'Cannot read decomposition mesh asset')
            previous={size=info.size,modtime=info.modtime,sha256=love.data.encode('string','hex',love.data.hash('sha256',bytes))}
            core._collision_source_hashes[path]=previous
        end
        assert(previous.sha256==cache.mesh_sha256,'Decomposition mesh SHA256 does not match the resolved MeshPart source')
    end
    local prepared
    if cache then
        local candidate={Size=part.Size,_collision_decomposition=cache}
        Convex.geometry(candidate);prepared=candidate._cd_scaled
    end
    part._collision_decomposition=cache;part._cd_scaled=prepared
    self._core:_note_runtime_part_physics_transform_changed(part,false)
    return true,cache and{type='convex_decomposition',hulls=#cache.hulls,mesh_sha256=cache.mesh_sha256}or{type='authored'}
end

-- Diagnostic owned copy of the effective part-local solids. no mutable engine
-- cache escapes, and ordinary authored MeshParts explicitly return nil
function DataModelMethods:get_part_collision_decomposition(instance)
    assert(type(instance)=='table'and rawget(instance,'_datamodel')==self,'Collision geometry needs an Instance owned by this DataModel')
    assert(not rawget(instance,'_destroyed'),'Cannot inspect collision geometry of a destroyed Instance')
    local part=rawget(instance,'_core_handle');local cache=part and part._collision_decomposition
    if not cache then return nil end
    local hulls=runtime_require('physics/convex_decomposition.lua').geometry(part)
    local result={type='convex_decomposition',coordinate_space='part',mesh_sha256=cache.mesh_sha256,hulls={}}
    for i,hull in ipairs(hulls)do
        local copy={vertices={},faces={}};result.hulls[i]=copy
        for _,point in ipairs(hull.vertices)do for _,value in ipairs(point)do copy.vertices[#copy.vertices+1]=value end end
        for j,face in ipairs(hull.faces)do copy.faces[j]={};for k,id in ipairs(face)do copy.faces[j][k]=id end end
    end
    return result
end

return DataModel
