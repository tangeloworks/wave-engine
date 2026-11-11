-- normalize SurfaceAppearance settings before the renderer picks textures and shader uniforms

local SurfaceAppearance = {}

SurfaceAppearance.ALPHA_OVERLAY = 0
SurfaceAppearance.ALPHA_TRANSPARENCY = 1
SurfaceAppearance.ALPHA_TINT_MASK = 2
SurfaceAppearance.ALPHA_OPAQUE = 3

SurfaceAppearance.DEFAULT_EMISSIVE_STRENGTH = 1
SurfaceAppearance.TRANSPARENCY_BLEND_THRESHOLD = 0.02
SurfaceAppearance.DEFAULT_CUTOUT_THRESHOLD = 0.5
SurfaceAppearance.LEGACY_OPAQUE_ALPHA_THRESHOLD = 0.999

local ALPHA_MODE_BY_NAME = {
    overlay = SurfaceAppearance.ALPHA_OVERLAY,
    transparency = SurfaceAppearance.ALPHA_TRANSPARENCY,
    tintmask = SurfaceAppearance.ALPHA_TINT_MASK,
    opaque = SurfaceAppearance.ALPHA_OPAQUE,
}

local function finite_number(value)
    value = tonumber(value)
    if value == nil or value ~= value
        or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function trim(value)
    if type(value) ~= "string" then return nil end
    return value:match("^%s*(.-)%s*$")
end

local function unwrap_enum(value)
    local seen = nil
    while type(value) == "table" do
        seen = seen or {}
        if seen[value] then return nil end
        seen[value] = true
        value = value.Value
            or value.value
            or value.Name
            or value.name
            or value.EnumItem
            or value.enum_item
    end
    return value
end

function SurfaceAppearance.normalize_alpha_mode(value)
    value = unwrap_enum(value)
    local numeric = finite_number(value)
    if numeric ~= nil then
        if numeric == math.floor(numeric) and numeric >= 0 and numeric <= 3 then
            return numeric
        end
        return SurfaceAppearance.ALPHA_OVERLAY
    end
    value = trim(value)
    if not value or value == "" then
        return SurfaceAppearance.ALPHA_OVERLAY
    end
    local name = value:match("([%a_]+)$") or value
    name = name:gsub("_", ""):lower()
    return ALPHA_MODE_BY_NAME[name] or SurfaceAppearance.ALPHA_OVERLAY
end

local function unwrap_content(value)
    local seen = nil
    while type(value) == "table" do
        seen = seen or {}
        if seen[value] then return nil end
        seen[value] = true
        value = value.uri
            or value.Uri
            or value.URI
            or value.url
            or value.Url
            or value.URL
            or value.value
            or value.Value
            or value.content
            or value.Content
            or value.asset_id
            or value.AssetId
            or value.assetId
    end
    return value
end

local function normalize_asset_reference(value)
    value = unwrap_content(value)
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge
            or value <= 0 or value ~= math.floor(value) then
            return nil
        end
        value = string.format("%.0f", value)
    end
    value = trim(value)
    if not value or value == "" then return nil end
    local lower = value:lower()
    if lower == "0"
        or lower == "null"
        or lower == "nil"
        or lower == "rbxassetid://0"
        or lower == "rbxasset://0" then
        return nil
    end
    return value
end

local function source_value(source, ...)
    if type(source) ~= "table" then return nil end
    for index = 1, select("#", ...) do
        local key = select(index, ...)
        local value = source[key]
        if value ~= nil then return value end
    end
    return nil
end

local function normalize_color(value, default_r, default_g, default_b)
    default_r = default_r or 1
    default_g = default_g or 1
    default_b = default_b or 1
    if type(value) ~= "table" then
        return { default_r, default_g, default_b }
    end
    local r = finite_number(value[1] or value.r or value.R) or default_r
    local g = finite_number(value[2] or value.g or value.G) or default_g
    local b = finite_number(value[3] or value.b or value.B) or default_b
    return {
        clamp(r, 0, 1),
        clamp(g, 0, 1),
        clamp(b, 0, 1),
    }
end

local function first_asset_reference(source, ...)
    for index = 1, select("#", ...) do
        local value = source_value(source, select(index, ...))
        local normalized = normalize_asset_reference(value)
        if normalized then return normalized end
    end
    return nil
end

local function normalize_resample_mode(value)
    value = unwrap_enum(value)
    local numeric = finite_number(value)
    if numeric ~= nil then
        return numeric == 1 and 1 or 0
    end
    value = trim(value)
    if not value then return 0 end
    local name = value:match("([%a_]+)$") or value
    name = name:gsub("_", ""):lower()
    return name == "pixelated" and 1 or 0
end

local function is_normalized_descriptor(value)
    return type(value) == "table"
        and value._surface_semantics_version == 2
end

-- return a complete value-owned renderer descriptor.  parsed descriptors are
-- already normalized, but accepting legacy/property aliases here keeps runtime
-- mutation and synthetic tests on the same contract
function SurfaceAppearance.normalize_descriptor(descriptor)
    if type(descriptor) ~= "table" then return nil end

    local properties = type(descriptor.properties) == "table"
        and descriptor.properties or {}
    local function from_descriptor_or_properties(...)
        local value = source_value(descriptor, ...)
        if value ~= nil then return value end
        return source_value(properties, ...)
    end
    local function first_map(...)
        for index = 1, select("#", ...) do
            local key = select(index, ...)
            local value = from_descriptor_or_properties(key)
            local normalized = normalize_asset_reference(value)
            if normalized then return normalized end
        end
        return nil
    end

    local alpha_mode = SurfaceAppearance.normalize_alpha_mode(
        from_descriptor_or_properties("alpha_mode", "raw_alpha_mode", "AlphaMode"))
    local color = normalize_color(
        from_descriptor_or_properties("color", "Color", "Color3"), 1, 1, 1)
    local emissive_tint = normalize_color(
        from_descriptor_or_properties("emissive_tint", "EmissiveTint"), 1, 1, 1)
    local emissive_strength = finite_number(
        from_descriptor_or_properties("emissive_strength", "EmissiveStrength"))
    if emissive_strength == nil then
        emissive_strength = SurfaceAppearance.DEFAULT_EMISSIVE_STRENGTH
    else
        emissive_strength = math.max(0, emissive_strength)
    end

    local texture_pack_metadata = from_descriptor_or_properties(
        "texture_pack_metadata", "TexturePackMetadata")
    if type(texture_pack_metadata) ~= "string" then
        texture_pack_metadata = nil
    end

    local normalized = {
        _surface_semantics_version = 2,
        active = true,
        alpha_mode = alpha_mode,
        color = color,
        color_map = first_map(
            "color_map", "color_map_content", "ColorMapContent", "ColorMap"),
        normal_map = first_map(
            "normal_map", "normal_map_content", "NormalMapContent", "NormalMap"),
        roughness_map = first_map(
            "roughness_map", "roughness_map_content", "RoughnessMapContent", "RoughnessMap"),
        metalness_map = first_map(
            "metalness_map", "metalness_map_content", "MetalnessMapContent", "MetalnessMap"),
        emissive_mask = first_map(
            "emissive_mask", "emissive_mask_content", "EmissiveMaskContent"),
        emissive_strength = emissive_strength,
        emissive_tint = emissive_tint,
        resample_mode = normalize_resample_mode(
            from_descriptor_or_properties("resample_mode", "ResampleMode")),
        texture_pack = first_map(
            "texture_pack_content", "TexturePackContent", "texture_pack", "TexturePack"),
        texture_pack_metadata = texture_pack_metadata,
    }
    normalized.color_map_active = normalized.color_map ~= nil
    normalized.has_data_maps = normalized.normal_map ~= nil
        or normalized.roughness_map ~= nil
        or normalized.metalness_map ~= nil
        or normalized.emissive_mask ~= nil
    normalized.emissive_active = normalized.emissive_mask ~= nil
        and normalized.emissive_strength > 0
    return normalized
end

local function component(value, numeric_index, lower_key, upper_key, fallback)
    if type(value) ~= "table" then return fallback end
    return finite_number(value[numeric_index]
        or value[lower_key] or value[upper_key]) or fallback
end

-- CPU reference for the shader's base-color/alpha contract. Inputs are assumed
-- to already be in the same working color space (the renderer converts authored
-- Color3 to linear before sending uniforms in gamma-correct mode)
function SurfaceAppearance.evaluate_base_color(
    descriptor, map_rgba, underlying_rgba, color_map_active)
    local underlying_r = component(underlying_rgba, 1, "r", "R", 1)
    local underlying_g = component(underlying_rgba, 2, "g", "G", 1)
    local underlying_b = component(underlying_rgba, 3, "b", "B", 1)
    local underlying_a = component(underlying_rgba, 4, "a", "A", 1)
    local normalized = is_normalized_descriptor(descriptor)
        and descriptor or SurfaceAppearance.normalize_descriptor(descriptor)
    local active = normalized ~= nil
        and (color_map_active == nil and normalized.color_map_active
            or color_map_active == true)
    if not active then
        return underlying_r, underlying_g, underlying_b, underlying_a
    end

    local map_r = component(map_rgba, 1, "r", "R", 1)
    local map_g = component(map_rgba, 2, "g", "G", 1)
    local map_b = component(map_rgba, 3, "b", "B", 1)
    local map_a = clamp(component(map_rgba, 4, "a", "A", 1), 0, 1)
    local tint = normalized.color or { 1, 1, 1 }
    local tint_r, tint_g, tint_b = tint[1], tint[2], tint[3]
    local mode = normalized.alpha_mode

    if mode == SurfaceAppearance.ALPHA_OVERLAY then
        return underlying_r * (1 - map_a) + map_r * tint_r * map_a,
            underlying_g * (1 - map_a) + map_g * tint_g * map_a,
            underlying_b * (1 - map_a) + map_b * tint_b * map_a,
            underlying_a
    elseif mode == SurfaceAppearance.ALPHA_TRANSPARENCY then
        return map_r * tint_r, map_g * tint_g, map_b * tint_b,
            underlying_a * map_a
    elseif mode == SurfaceAppearance.ALPHA_TINT_MASK then
        return map_r * ((1 - map_a) + tint_r * map_a),
            map_g * ((1 - map_a) + tint_g * map_a),
            map_b * ((1 - map_a) + tint_b * map_a),
            underlying_a
    end

    return map_r * tint_r, map_g * tint_g, map_b * tint_b, underlying_a
end

-- Roblox adds emissive contribution to combined lighting, then multiplies the
-- result by albedo. this helper models the pre-albedo lighting term
function SurfaceAppearance.evaluate_emissive_lighting(
    descriptor, lighting_rgb, emissive_mask)
    local normalized = is_normalized_descriptor(descriptor)
        and descriptor or SurfaceAppearance.normalize_descriptor(descriptor)
    local lr = component(lighting_rgb, 1, "r", "R", 0)
    local lg = component(lighting_rgb, 2, "g", "G", 0)
    local lb = component(lighting_rgb, 3, "b", "B", 0)
    if not normalized or not normalized.emissive_active then
        return lr, lg, lb
    end
    local mask = clamp(finite_number(emissive_mask) or 0, 0, 1)
    local scale = mask * normalized.emissive_strength
    local tint = normalized.emissive_tint
    return lr + scale * tint[1],
        lg + scale * tint[2],
        lb + scale * tint[3]
end

-- resolve the pass/depth contract. Transparency mode has a native cutout path
-- for an otherwise opaque MeshPart and a sorted blend path from 0.02 onward
function SurfaceAppearance.classify_route(
    descriptor, part_transparency, color_map_active, options)
    options = options or {}
    local normalized = is_normalized_descriptor(descriptor)
        and descriptor or SurfaceAppearance.normalize_descriptor(descriptor)
    local transparency = clamp(finite_number(part_transparency) or 0, 0, 1)
    local alpha = 1 - transparency
    local result = {
        part_transparency = transparency,
        part_alpha = alpha,
        submit_geometry = alpha > 0,
        blend = false,
        alpha_discard = false,
        depth_write = true,
        depth_prepass = true,
        sorted = false,
        cutout_threshold = clamp(
            finite_number(options.cutout_threshold)
                or SurfaceAppearance.DEFAULT_CUTOUT_THRESHOLD, 0, 1),
    }
    if alpha <= 0 then
        result.route = "invisible"
        result.depth_write = false
        result.depth_prepass = false
        return result
    end

    local map_active = normalized ~= nil
        and (color_map_active == nil and normalized.color_map_active
            or color_map_active == true)
    if map_active
        and normalized.alpha_mode == SurfaceAppearance.ALPHA_TRANSPARENCY then
        local blend_threshold = clamp(
            finite_number(options.transparency_blend_threshold)
                or SurfaceAppearance.TRANSPARENCY_BLEND_THRESHOLD, 0, 1)
        if transparency < blend_threshold then
            result.route = "opaque_cutout"
            result.alpha_discard = true
            -- the existing RBX depth-only shader does not sample the color map
            -- Main-pass depth writes preserve occlusion without falsely filling
            -- holes in the prepass
            result.depth_prepass = options.depth_prepass_samples_alpha == true
            return result
        end
        result.route = "transparent_blend"
        result.blend = true
        result.depth_write = false
        result.depth_prepass = false
        result.sorted = true
        return result
    end

    local opaque_alpha_threshold = clamp(
        finite_number(options.opaque_alpha_threshold)
            or SurfaceAppearance.LEGACY_OPAQUE_ALPHA_THRESHOLD, 0, 1)
    if alpha < opaque_alpha_threshold then
        result.route = "transparent_blend"
        result.blend = true
        result.depth_write = false
        result.depth_prepass = false
        result.sorted = true
    else
        result.route = "opaque"
    end
    return result
end

local function pixelated_resample(value)
    return normalize_resample_mode(value) == 1
end

function SurfaceAppearance.sampler_options(role, descriptor, options)
    options = options or {}
    local normalized = is_normalized_descriptor(descriptor)
        and descriptor or SurfaceAppearance.normalize_descriptor(descriptor)
    role = tostring(role or "color"):lower()
    local color_role = role == "color" or role == "albedo"
    local pixelated = pixelated_resample(
        normalized and normalized.resample_mode or options.resample_mode)
    local alpha_mode = normalized and normalized.alpha_mode
        or SurfaceAppearance.ALPHA_OVERLAY
    local alpha_bleed = color_role
        and alpha_mode ~= SurfaceAppearance.ALPHA_TINT_MASK
        and alpha_mode ~= SurfaceAppearance.ALPHA_OPAQUE
    return {
        role = role,
        wrap_mode = options.wrap_mode == "repeat" and "repeat" or "clamp",
        mipmaps = options.mipmaps ~= false,
        min_filter = pixelated and "nearest" or "linear",
        mag_filter = pixelated and "nearest" or "linear",
        mipmap_filter = pixelated and "nearest" or "linear",
        color_space = color_role and "srgb_color" or "linear_data",
        alpha_bleed = alpha_bleed,
        remote_pending_placeholder = color_role and "white" or "neutral_data",
    }
end

local function signature_atom(value)
    local encoded
    if value == nil then
        encoded = "n"
    elseif type(value) == "boolean" then
        encoded = value and "b1" or "b0"
    elseif type(value) == "number" then
        if value ~= value then encoded = "nan"
        elseif value == math.huge then encoded = "+inf"
        elseif value == -math.huge then encoded = "-inf"
        else encoded = "d" .. string.format("%.17g", value) end
    elseif type(value) == "string" then
        encoded = "s" .. tostring(value)
    else
        encoded = "unsupported:" .. type(value)
    end
    return tostring(#encoded) .. ":" .. encoded
end

local SIGNATURE_ROLES = { "color", "normal", "roughness", "metalness", "emissive" }

-- build a collision-resistant, deterministic identity for batching and uniform
-- caches. `resources` may contain per-role resource keys and `revision` values;
-- live promotion changes only those atoms and never mutates the descriptor
function SurfaceAppearance.build_signature(descriptor, resources, options)
    local normalized = is_normalized_descriptor(descriptor)
        and descriptor or SurfaceAppearance.normalize_descriptor(descriptor)
    if not normalized then return "surface:inactive" end
    resources = type(resources) == "table" and resources or {}
    options = type(options) == "table" and options or {}
    local encoded = {}
    local function append(value)
        encoded[#encoded + 1] = signature_atom(value)
    end
    append("surface:v2")
    append(normalized.alpha_mode)
    append(normalized.color_map)
    append(normalized.normal_map)
    append(normalized.roughness_map)
    append(normalized.metalness_map)
    append(normalized.emissive_mask)
    append(normalized.color[1])
    append(normalized.color[2])
    append(normalized.color[3])
    append(normalized.emissive_strength)
    append(normalized.emissive_tint[1])
    append(normalized.emissive_tint[2])
    append(normalized.emissive_tint[3])
    append(normalized.resample_mode)
    append(normalized.texture_pack)
    append(normalized.texture_pack_metadata)
    append(resources.revision or resources.resource_revision or 0)
    for index = 1, #SIGNATURE_ROLES do
        local role = SIGNATURE_ROLES[index]
        local role_resource = type(resources[role]) == "table"
            and resources[role] or nil
        local sampler = SurfaceAppearance.sampler_options(
            role, normalized, options[role] or options)
        append(role)
        append(role_resource
            and (role_resource.resource_key or role_resource.key)
            or resources[role .. "_key"])
        append(role_resource
            and (role_resource.revision or role_resource.resource_revision)
            or resources[role .. "_revision"])
        append(sampler.wrap_mode)
        append(sampler.mipmaps)
        append(sampler.min_filter)
        append(sampler.mag_filter)
        append(sampler.mipmap_filter)
        append(sampler.color_space)
        append(sampler.alpha_bleed)
    end
    return table.concat(encoded, "|")
end

function SurfaceAppearance.instancing_eligibility(descriptor)
    if type(descriptor) ~= "table" then return true end
    return false, "surface_appearance_requires_baked_shader"
end

SurfaceAppearance.normalize_asset_reference = normalize_asset_reference
SurfaceAppearance.normalize_resample_mode = normalize_resample_mode

return SurfaceAppearance
