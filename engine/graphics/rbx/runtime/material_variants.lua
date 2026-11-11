-- Value-owned MaterialService/MaterialVariant catalog and resolver
--
-- this module deliberately has no graphics dependency. it can run in the map
-- worker, survive a LOVE channel/cache copy, and feed both part and Terrain
-- renderers without retaining the parsed Instance graph

local MaterialRegistry = runtime_require("material_registry.lua")
local SurfaceAppearance = runtime_require("surface_appearance.lua")

local MaterialVariants = {}

MaterialVariants.DEFAULT_STUDS_PER_TILE = 10
MaterialVariants.PATTERN_REGULAR = 0
MaterialVariants.PATTERN_ORGANIC = 1
MaterialVariants.DEFAULT_LIMITS = {
    max_nodes = 250000,
    max_variants = 4096,
    max_diagnostics = 128,
}

local function finite_number(value)
    value = tonumber(value)
    if value == nil or value ~= value
        or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

local function trim(value)
    if type(value) ~= "string" then return nil end
    return value:match("^%s*(.-)%s*$")
end

local function unwrap(value)
    local seen
    for _ = 1, 8 do
        if type(value) ~= "table" then break end
        seen = seen or {}
        if seen[value] then return nil end
        seen[value] = true
        local next_value = value.Value
            or value.value
            or value.EnumItem
            or value.enum_item
        if next_value == nil then break end
        value = next_value
    end
    return value
end

local function source_value(source, ...)
    if type(source) ~= "table" then return nil end
    local properties = type(source.Properties) == "table"
        and source.Properties
        or (type(source.properties) == "table" and source.properties or nil)
    for index = 1, select("#", ...) do
        local key = select(index, ...)
        local value = source[key]
        if value == nil and properties then value = properties[key] end
        if value ~= nil then return value end
    end
    return nil
end

local function class_name(source)
    return unwrap(source_value(
        source, "ClassName", "className", "class_name", "class"))
end

local function children(source)
    if type(source) ~= "table" then return nil end
    local result = source.Children or source.children
    return type(result) == "table" and result or nil
end

local function normalize_pattern(value)
    value = unwrap(value)
    local numeric = finite_number(value)
    if numeric ~= nil then
        return math.floor(numeric + 0.5) == 1
            and MaterialVariants.PATTERN_ORGANIC
            or MaterialVariants.PATTERN_REGULAR
    end
    value = trim(value)
    if not value then return MaterialVariants.PATTERN_REGULAR end
    local suffix = value:match("([%a_]+)$") or value
    suffix = suffix:gsub("_", ""):lower()
    return suffix == "organic"
        and MaterialVariants.PATTERN_ORGANIC
        or MaterialVariants.PATTERN_REGULAR
end

local function normalized_name(value)
    value = trim(unwrap(value))
    if not value or value == "" then return nil end
    return value
end

local function copy_physical_properties(value)
    if type(value) ~= "table" then return nil end
    local keys = {
        "Density", "Friction", "Elasticity",
        "FrictionWeight", "ElasticityWeight", "AcousticAbsorption",
        "density", "friction", "elasticity",
        "friction_weight", "elasticity_weight", "acoustic_absorption",
    }
    local result = {}
    local count = 0
    for index = 1, #keys do
        local key = keys[index]
        local numeric = finite_number(value[key])
        if numeric ~= nil then
            result[key] = numeric
            count = count + 1
        end
    end
    return count > 0 and result or nil
end

local function diagnostic(catalog, code, fields)
    catalog.diagnostic_counts[code] =
        (catalog.diagnostic_counts[code] or 0) + 1
    if #catalog.diagnostics >= catalog.max_diagnostics then return end
    local item = { code = code }
    if type(fields) == "table" then
        for key, value in pairs(fields) do
            local kind = type(value)
            if kind == "string" or kind == "number" or kind == "boolean" then
                item[key] = value
            end
        end
    end
    catalog.diagnostics[#catalog.diagnostics + 1] = item
end

local function make_variant(source, order)
    local name = normalized_name(source_value(source, "Name", "name"))
    if not name then return nil, "material_variant_missing_name" end

    local base = MaterialRegistry.get(source_value(
        source, "BaseMaterial", "base_material"))
        or MaterialRegistry.get(256)
    local raw_alpha = source_value(source, "AlphaMode", "alpha_mode")
    if raw_alpha == nil then raw_alpha = SurfaceAppearance.ALPHA_OPAQUE end
    local surface = SurfaceAppearance.normalize_descriptor({
        AlphaMode = raw_alpha,
        ColorMapContent = source_value(
            source, "ColorMapContent", "ColorMap", "color_map_content", "color_map"),
        NormalMapContent = source_value(
            source, "NormalMapContent", "NormalMap", "normal_map_content", "normal_map"),
        RoughnessMapContent = source_value(
            source, "RoughnessMapContent", "RoughnessMap", "roughness_map_content", "roughness_map"),
        MetalnessMapContent = source_value(
            source, "MetalnessMapContent", "MetalnessMap", "metalness_map_content", "metalness_map"),
        EmissiveMaskContent = source_value(
            source, "EmissiveMaskContent", "emissive_mask_content", "emissive_mask"),
        EmissiveStrength = source_value(
            source, "EmissiveStrength", "emissive_strength"),
        EmissiveTint = source_value(
            source, "EmissiveTint", "emissive_tint"),
    })

    local studs = finite_number(source_value(
        source, "StudsPerTile", "studs_per_tile"))
    if studs == nil or studs <= 0 then
        studs = MaterialVariants.DEFAULT_STUDS_PER_TILE
    end

    return {
        _material_variant_semantics_version = 1,
        name = name,
        base_material = base.canonical_token,
        base_material_name = base.name,
        studs_per_tile = math.min(studs, 1000000),
        material_pattern = normalize_pattern(source_value(
            source, "MaterialPattern", "material_pattern")),
        alpha_mode = surface.alpha_mode,
        color_map = surface.color_map,
        normal_map = surface.normal_map,
        roughness_map = surface.roughness_map,
        metalness_map = surface.metalness_map,
        emissive_mask = surface.emissive_mask,
        emissive_strength = surface.emissive_strength,
        emissive_tint = surface.emissive_tint,
        has_data_maps = surface.has_data_maps,
        emissive_active = surface.emissive_active,
        custom_physical_properties = copy_physical_properties(source_value(
            source, "CustomPhysicalProperties", "custom_physical_properties")),
        source_order = order,
    }
end

local function variant_key(base_material, name)
    return tostring(base_material) .. "\0" .. tostring(name)
end

local function option_limit(options, name)
    local value = options and options[name]
    if value == nil and type(options and options.limits) == "table" then
        value = options.limits[name]
    end
    value = finite_number(value)
        or MaterialVariants.DEFAULT_LIMITS[name]
    return math.max(1, math.floor(value))
end

---build a bounded, value-owned catalog from one or more parsed Instance roots
function MaterialVariants.extract_from_roots(roots, options)
    options = options or {}
    local max_nodes = option_limit(options, "max_nodes")
    local max_variants = option_limit(options, "max_variants")
    local catalog = {
        _material_variant_catalog_version = 1,
        variants = {},
        variants_by_key = {},
        base_overrides = {},
        diagnostics = {},
        diagnostic_counts = {},
        max_diagnostics = option_limit(options, "max_diagnostics"),
        scanned_nodes = 0,
        service_count = 0,
    }

    if type(roots) ~= "table" then
        return catalog
    end
    local stack = {}
    if roots.ClassName or roots.class_name or roots.class then
        stack[1] = roots
    else
        for index = #roots, 1, -1 do
            if type(roots[index]) == "table" then
                stack[#stack + 1] = roots[index]
            end
        end
    end

    local services = {}
    while #stack > 0 do
        local node = stack[#stack]
        stack[#stack] = nil
        catalog.scanned_nodes = catalog.scanned_nodes + 1
        if catalog.scanned_nodes > max_nodes then
            return nil, {
                code = "MaterialVariantNodeLimit",
                max_nodes = max_nodes,
            }
        end
        if class_name(node) == "MaterialService" then
            services[#services + 1] = node
        end
        local node_children = children(node)
        if node_children then
            for index = #node_children, 1, -1 do
                if type(node_children[index]) == "table" then
                    stack[#stack + 1] = node_children[index]
                end
            end
        end
    end

    catalog.service_count = #services
    if #services > 1 then
        diagnostic(catalog, "multiple_material_services", {
            count = #services,
        })
    end

    for service_index = 1, #services do
        local service = services[service_index]
        local service_stack = {}
        local service_children = children(service) or {}
        for index = #service_children, 1, -1 do
            service_stack[#service_stack + 1] = service_children[index]
        end
        while #service_stack > 0 do
            local node = service_stack[#service_stack]
            service_stack[#service_stack] = nil
            if class_name(node) == "MaterialVariant" then
                if #catalog.variants >= max_variants then
                    return nil, {
                        code = "MaterialVariantCountLimit",
                        max_variants = max_variants,
                    }
                end
                local variant, reason = make_variant(
                    node, #catalog.variants + 1)
                if not variant then
                    diagnostic(catalog, reason or "invalid_material_variant")
                else
                    local key = variant_key(
                        variant.base_material, variant.name)
                    if catalog.variants_by_key[key] then
                        diagnostic(catalog, "duplicate_material_variant", {
                            name = variant.name,
                            base_material = variant.base_material,
                        })
                    else
                        catalog.variants[#catalog.variants + 1] = variant
                        catalog.variants_by_key[key] = variant
                    end
                end
            end
            local node_children = children(node)
            if node_children then
                for index = #node_children, 1, -1 do
                    service_stack[#service_stack + 1] = node_children[index]
                end
            end
        end

        -- a malformed file can contain duplicate MaterialService instances
        -- Roblox has one service, make the first authoritative and keep later
        -- instances diagnostic-only for deterministic worker/main parity
        if service_index == 1 then
            local tokens = MaterialRegistry.official_tokens()
            for index = 1, #tokens do
                local base = MaterialRegistry.get(tokens[index])
                local override = normalized_name(source_value(
                    service, base.name .. "Name"))
                if override then
                    local key = variant_key(base.canonical_token, override)
                    if catalog.variants_by_key[key] then
                        catalog.base_overrides[base.canonical_token] = override
                    else
                        diagnostic(catalog, "material_override_not_found", {
                            base_material = base.canonical_token,
                            name = override,
                        })
                    end
                end
            end
        end
    end

    catalog.max_diagnostics = nil
    return catalog
end

---resolve BasePart.MaterialVariant or a MaterialService base override
---explicit non-empty part names do not fall through to a base override
function MaterialVariants.resolve(catalog, base_material, requested_name)
    if type(catalog) ~= "table"
        or type(catalog.variants_by_key) ~= "table" then
        return nil, "catalog_unavailable"
    end
    local base = MaterialRegistry.get(base_material)
    if not base then return nil, "unknown_base_material" end
    local explicit = normalized_name(requested_name)
    local name = explicit
    local source = "part"
    if not name then
        name = catalog.base_overrides
            and catalog.base_overrides[base.canonical_token]
        source = "override"
    end
    if not name then return nil, "base_material" end
    local result = catalog.variants_by_key[
        variant_key(base.canonical_token, name)]
    if not result then
        return nil, explicit and "part_variant_not_found"
            or "base_override_not_found"
    end
    return result, source
end

return MaterialVariants
