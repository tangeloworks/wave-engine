-- worker-safe composition of the BaseParts stored in legacy CSG ChildData
-- containers.  this module owns no renderer state and creates no LOVE graphics
-- resources, callers provide payload decoding and local dependency resolution

local dom = require("engine/graphics/rbx/dom")
local import = require("engine/graphics/rbx/import")
local primitive_geometry = require("engine/graphics/rbx/primitive_geometry")

local Composer = {}

Composer.DEFAULT_LIMITS = {
    max_parts = 16384,
    max_renderables = 16384,
    max_output_vertices = 1000000,
    max_dependencies = 128,
}

local SUPPORTED_CLASS = {
    Part = true,
    SpawnLocation = true,
    WedgePart = true,
    CornerWedgePart = true,
    TrussPart = true,
    Seat = true,
    VehicleSeat = true,
    MeshPart = true,
    UnionOperation = true,
    PartOperation = true,
}

local CSG_CLASS = {
    UnionOperation = true,
    PartOperation = true,
}

-- Concatenating positive child meshes is a useful worker-safe fallback for
-- legacy unions, but it cannot represent subtraction or intersection.  keep
-- these classes explicit so a container that needs boolean evaluation fails
-- closed instead of silently publishing filled holes or union-only geometry
local UNSUPPORTED_BOOLEAN_CLASS = {
    NegateOperation = true,
    IntersectOperation = true,
}

local EMBEDDED_FIELDS = {
    "ModelMeshData",
    "MeshData",
    "ChildData",
    "ModelMeshData2",
    "MeshData2",
    "ChildData2",
    "AeroMeshData",
    "PhysicalConfigData",
    "PhysicsData",
}

local SOURCE_SCORE = {
    csg_mesh = 4,
    csg_child_parts = 3,
    mesh = 2,
    csg_physics = 1,
}

local PRIMITIVES = primitive_geometry.build_primitive_vertices()

local function is_finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function clamp_color_channel(value, fallback)
    value = tonumber(value)
    if not is_finite(value) then value = fallback or 1 end
    return math.max(0, math.min(1, value))
end

local function score(mesh_data)
    return type(mesh_data) == "table"
        and (SOURCE_SCORE[mesh_data.source_kind] or 0) or -1
end

local function prefer(current, candidate)
    if score(candidate) > score(current) then
        return candidate
    end
    return current
end

local function normalize(x, y, z, fallback_x, fallback_y, fallback_z)
    x, y, z = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
    local length = math.sqrt(x * x + y * y + z * z)
    if length <= 1e-12 or not is_finite(length) then
        return fallback_x or 0, fallback_y or 1, fallback_z or 0
    end
    return x / length, y / length, z / length
end

local function get_property(instance, name)
    local properties = instance and instance.properties or nil
    if not properties then return nil end
    local value = properties[name]
    if value == nil then value = properties[name:lower()] end
    return dom.unwrap(value)
end

local function get_content(instance, ...)
    local properties = instance and instance.properties or {}
    for index = 1, select("#", ...) do
        local name = select(index, ...)
        local value = properties[name]
        if value == nil then value = properties[name:lower()] end
        local text = dom.property_to_string(value)
        if type(text) ~= "string" then
            value = dom.unwrap(value)
            if type(value) == "table" then
                text = value.uri or value.value or value.text
            elseif type(value) == "string" then
                text = value
            end
        end
        if type(text) == "string" then
            text = text:match("^%s*(.-)%s*$")
            if text ~= "" then return text end
        end
    end
    return nil
end

local function get_vector(instance, name, defaults)
    defaults = defaults or { x = 0, y = 0, z = 0 }
    local value = get_property(instance, name)
    if type(value) ~= "table" then value = defaults end
    return {
        x = tonumber(value.x or value.X or value[1]) or defaults.x or 0,
        y = tonumber(value.y or value.Y or value[2]) or defaults.y or 0,
        z = tonumber(value.z or value.Z or value[3]) or defaults.z or 0,
    }
end

local function find_child(instance, class_name)
    for index = 1, #(instance and instance.children or {}) do
        local child = instance.children[index]
        if child.className == class_name then return child end
    end
    return nil
end

local function apply_offset(transform, offset)
    transform.px = transform.px
        + transform.rx * offset.x
        + transform.ux * offset.y
        + transform.bx * offset.z
    transform.py = transform.py
        + transform.ry * offset.x
        + transform.uy * offset.y
        + transform.by * offset.z
    transform.pz = transform.pz
        + transform.rz * offset.x
        + transform.uz * offset.y
        + transform.bz * offset.z
end

local function base_transform(render, opts)
    local transform = render.transform or {}
    local position = transform.position or {}
    local orientation = transform.orientation
        or { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    local px = tonumber(position.x or position.X) or 0
    local py = tonumber(position.y or position.Y) or 0
    local pz = tonumber(position.z or position.Z) or 0
    local o = {
        tonumber(orientation[1]) or 1,
        tonumber(orientation[2]) or 0,
        tonumber(orientation[3]) or 0,
        tonumber(orientation[4]) or 0,
        tonumber(orientation[5]) or 1,
        tonumber(orientation[6]) or 0,
        tonumber(orientation[7]) or 0,
        tonumber(orientation[8]) or 0,
        tonumber(orientation[9]) or 1,
    }

    -- the renderer's legacy loaded-map X mirror is opt-in. Child composition
    -- must use the same default (authored Roblox coordinates unchanged), an
    -- embedding caller that enables the legacy renderer option can opt in here
    if opts.mirror_loaded_map_x == true then
        px = -px
        o[2], o[3] = -o[2], -o[3]
        o[4], o[7] = -o[4], -o[7]
    end

    local rx, ry, rz = normalize(o[1], o[4], o[7], 1, 0, 0)
    local ux, uy, uz = normalize(o[2], o[5], o[8], 0, 1, 0)
    local bx, by, bz = normalize(o[3], o[6], o[9], 0, 0, 1)
    local size = render.size or { x = 4, y = 1, z = 2 }
    local out = {
        px = px, py = py, pz = pz,
        rx = rx, ry = ry, rz = rz,
        ux = ux, uy = uy, uz = uz,
        bx = bx, by = by, bz = bz,
        scale_x = tonumber(size.x) or 4,
        scale_y = tonumber(size.y) or 1,
        scale_z = tonumber(size.z) or 2,
    }

    local block_mesh = find_child(render.sourceInstance, "BlockMesh")
    if block_mesh then
        local scale = get_vector(block_mesh, "Scale", { x = 1, y = 1, z = 1 })
        out.scale_x = out.scale_x * scale.x
        out.scale_y = out.scale_y * scale.y
        out.scale_z = out.scale_z * scale.z
        apply_offset(out, get_vector(block_mesh, "Offset", { x = 0, y = 0, z = 0 }))
    end
    return out
end

local function primitive_transform(render, opts)
    local out = base_transform(render, opts)
    local decorator = render.decorator
    local shape = render.geometryData and render.geometryData.primitiveShape
        or render.primitiveShapeKind or "Block"
    if decorator and decorator.className == "CylinderMesh" then
        shape = "CylinderY"
    elseif decorator and decorator.className == "BlockMesh" then
        shape = render.primitiveShapeKind or "Block"
    end
    local mesh_type = decorator and decorator.meshType or nil
    local builtin = decorator and decorator.className ~= "BlockMesh"
        and mesh_type ~= "FileMesh"
        and shape ~= nil

    if builtin then
        apply_offset(out, decorator.offset or { x = 0, y = 0, z = 0 })
        local scale = decorator.scale or { x = 1, y = 1, z = 1 }
        out.scale_x = out.scale_x * (tonumber(scale.x) or 1)
        out.scale_y = out.scale_y * (tonumber(scale.y) or 1)
        out.scale_z = out.scale_z * (tonumber(scale.z) or 1)
    elseif shape == "Cylinder" then
        local radius = math.min(math.abs(out.scale_y), math.abs(out.scale_z))
        out.scale_y, out.scale_z = radius, radius
    elseif shape == "Ball" then
        local diameter = math.min(
            math.abs(out.scale_x), math.abs(out.scale_y),
            math.abs(out.scale_z))
        out.scale_x, out.scale_y, out.scale_z = diameter, diameter, diameter
    end

    return out, shape
end

local function mesh_bounds_size(mesh_data)
    local bounds = type(mesh_data) == "table" and mesh_data.bounds or nil
    bounds = bounds or {
        min_x = -0.5, min_y = -0.5, min_z = -0.5,
        max_x = 0.5, max_y = 0.5, max_z = 0.5,
    }
    return bounds,
        math.max((tonumber(bounds.max_x) or 0.5)
            - (tonumber(bounds.min_x) or -0.5), 1e-6),
        math.max((tonumber(bounds.max_y) or 0.5)
            - (tonumber(bounds.min_y) or -0.5), 1e-6),
        math.max((tonumber(bounds.max_z) or 0.5)
            - (tonumber(bounds.min_z) or -0.5), 1e-6)
end

local function mesh_transform(render, mesh_data, opts)
    local decorator = render.decorator
    local mesh_type = decorator and decorator.meshType or nil
    local out
    if decorator and decorator.className == "SpecialMesh"
        and mesh_type ~= "FileMesh" then
        out = primitive_transform(render, opts)
    else
        out = base_transform(render, opts)
    end

    local _, width, height, depth = mesh_bounds_size(mesh_data)
    if decorator and decorator.className == "SpecialMesh"
        and (mesh_type == "FileMesh" or mesh_type == "Head") then
        if mesh_type == "FileMesh" then
            apply_offset(out, decorator.offset or { x = 0, y = 0, z = 0 })
        end
        local scale = decorator.scale or { x = 1, y = 1, z = 1 }
        out.scale_x = tonumber(scale.x) or 1
        out.scale_y = tonumber(scale.y) or 1
        out.scale_z = tonumber(scale.z) or 1
    else
        local mesh_size = get_vector(render.sourceInstance, "MeshSize")
        if math.abs(mesh_size.x) <= 1e-6
            or math.abs(mesh_size.y) <= 1e-6
            or math.abs(mesh_size.z) <= 1e-6 then
            mesh_size = get_vector(render.sourceInstance, "ModelMeshSize")
        end
        if math.abs(mesh_size.x) <= 1e-6
            or math.abs(mesh_size.y) <= 1e-6
            or math.abs(mesh_size.z) <= 1e-6 then
            mesh_size = get_vector(render.sourceInstance, "InitialSize")
        end
        if math.abs(mesh_size.x) > 1e-6
            and math.abs(mesh_size.y) > 1e-6
            and math.abs(mesh_size.z) > 1e-6 then
            width, height, depth = math.abs(mesh_size.x),
                math.abs(mesh_size.y), math.abs(mesh_size.z)
        end
        out.scale_x = out.scale_x / width
        out.scale_y = out.scale_y / height
        out.scale_z = out.scale_z / depth
    end

    if mesh_data.basis and mesh_data.basis.flip_back_axis then
        out.bx, out.by, out.bz = -out.bx, -out.by, -out.bz
    end
    return out
end

local function transform_point(transform, x, y, z)
    return transform.px
            + transform.rx * x + transform.ux * y + transform.bx * z,
        transform.py
            + transform.ry * x + transform.uy * y + transform.by * z,
        transform.pz
            + transform.rz * x + transform.uz * y + transform.bz * z
end

local function transform_normal(transform, x, y, z)
    local function inverse_scaled(value, scale)
        scale = tonumber(scale) or 1
        if math.abs(scale) <= 1e-12 then return 0 end
        return value / scale
    end
    x = inverse_scaled(x, transform.scale_x)
    y = inverse_scaled(y, transform.scale_y)
    z = inverse_scaled(z, transform.scale_z)
    return normalize(
        transform.rx * x + transform.ux * y + transform.bx * z,
        transform.ry * x + transform.uy * y + transform.by * z,
        transform.rz * x + transform.uz * y + transform.bz * z,
        x, y, z)
end

local function transform_flips_winding(transform)
    local basis_determinant = transform.rx
            * (transform.uy * transform.bz - transform.uz * transform.by)
        - transform.ux
            * (transform.ry * transform.bz - transform.rz * transform.by)
        + transform.bx
            * (transform.ry * transform.uz - transform.rz * transform.uy)
    return basis_determinant
        * transform.scale_x * transform.scale_y * transform.scale_z < 0
end

local function embedded_candidates(instance)
    local candidates, seen = {}, {}
    local properties = instance and instance.properties or {}
    for index = 1, #EMBEDDED_FIELDS do
        local field = EMBEDDED_FIELDS[index]
        local bytes = dom.property_to_string(
            properties[field] or properties[field:lower()])
        if type(bytes) == "string" and bytes ~= "" and not seen[bytes] then
            seen[bytes] = true
            candidates[#candidates + 1] = bytes
        end
    end
    return candidates
end

local function unwrap_resolution(value, extra)
    if type(value) == "table" and type(value.positions) == "table" then
        return value, "ready", nil
    end
    if type(value) == "table" then
        return value.mesh or value.result,
            value.status or value.state,
            value.dependency or value.reason
    end
    return nil, value and "ready" or nil, extra
end

function Composer.compose_file(file_or_scene, opts)
    opts = opts or {}
    local limits = opts.limits or {}
    local max_parts = math.max(1, math.floor(tonumber(limits.max_parts)
        or Composer.DEFAULT_LIMITS.max_parts))
    local max_renderables = math.max(1, math.floor(
        tonumber(limits.max_renderables)
        or Composer.DEFAULT_LIMITS.max_renderables))
    local max_vertices = math.max(3, math.floor(
        tonumber(limits.max_output_vertices)
        or Composer.DEFAULT_LIMITS.max_output_vertices))
    local max_dependencies = math.max(0, math.floor(
        tonumber(limits.max_dependencies)
        or Composer.DEFAULT_LIMITS.max_dependencies))

    local file = file_or_scene.file or file_or_scene
    local unsupported_operation = nil
    local traversal_stats = opts.traversal_stats or {}
    local renderables = import.import_renderables(file, {
        decode_mesh_payloads = false,
        retain_source_instances = true,
        include_compound_containers = false,
        max_parts = max_parts,
        max_renderables = max_renderables,
        traversal_stats = traversal_stats,
        on_visit_instance = function(instance)
            local class_name = instance and instance.className
            if UNSUPPORTED_BOOLEAN_CLASS[class_name] then
                -- one deterministic preorder diagnostic is sufficient to fail
                -- closed.  Retaining every path/referent made an adversarial
                -- boolean-only file consume memory proportional to its size
                unsupported_operation = {
                    class_name = class_name,
                    path = dom.instance_path(instance),
                    referent = instance.referent,
                }
                return false, "unsupported_boolean"
            end
            return true
        end,
    })
    local traversal = traversal_stats
    if unsupported_operation then
        return {
            status = "unsupported",
            reason = "csg_boolean_operation_unsupported:"
                .. tostring(unsupported_operation.class_name),
            mesh = nil,
            unsupported_operations = { unsupported_operation },
            stats = {
                traversal_visits = traversal.visited,
                renderables_materialized = traversal.materialized,
                unsupported_diagnostics = 1,
            },
        }
    end
    if traversal.limit_reason then
        return {
            status = "limited",
            reason = traversal.limit_reason == "max_renderables"
                and "csg_renderable_limit" or "csg_part_limit",
            mesh = nil,
            stats = {
                traversal_visits = traversal.visited,
                renderables_materialized = traversal.materialized,
            },
        }
    end

    local parts = {}
    for index = 1, #renderables do
        local render = renderables[index]
        if SUPPORTED_CLASS[render.sourceClassName] then
            parts[#parts + 1] = render
        end
    end
    if #parts == 0 then
        return {
            status = "empty",
            reason = "csg_container_holds_no_parts",
            mesh = nil,
            stats = { part_count = 0, output_vertices = 0 },
        }
    end

    local positions, normals, uvs, colors = {}, {}, {}, {}
    local dependencies, dependency_seen = {}, {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
    local source_mesh_parts, primitive_parts = 0, 0

    local function add_dependency(reference, detail)
        local key = tostring(reference or detail or "unknown")
        if dependency_seen[key] then return true end
        if #dependencies >= max_dependencies then
            return false, "csg_dependency_limit"
        end
        dependency_seen[key] = true
        if type(detail) == "table" then
            local dependency = {}
            for name, value in pairs(detail) do dependency[name] = value end
            dependency.reference = dependency.reference or reference
            dependencies[#dependencies + 1] = dependency
        else
            dependencies[#dependencies + 1] = {
                reference = reference,
                reason = detail or "external_dependency",
            }
        end
        return true
    end

    local function decode_payload(bytes, context)
        if type(opts.decode_payload) ~= "function" then return nil end
        local value, extra = opts.decode_payload(bytes, context)
        local parsed, state, detail = unwrap_resolution(value, extra)
        if state == "limited" or state == "limit"
            or (type(detail) == "string"
                and detail:find("limit", 1, true)) then
            return nil, detail or "csg_nested_limit"
        end
        return parsed
    end

    local function resolve(reference, context, record_missing)
        if type(reference) ~= "string" or reference == "" then return nil end
        if record_missing == nil then record_missing = true end
        if type(opts.resolve_mesh) ~= "function" then
            if record_missing then
                local ok, reason = add_dependency(
                    reference, "external_dependency")
                if not ok then return nil, reason end
            end
            return nil, nil, "external_dependency"
        end
        local value, extra = opts.resolve_mesh(reference, context)
        local parsed, state, detail = unwrap_resolution(value, extra)
        if parsed then return parsed end
        if state == "limited" or state == "limit"
            or (type(detail) == "string"
                and detail:find("limit", 1, true)) then
            return nil, detail or "csg_dependency_limit"
        end
        if record_missing then
            local ok, reason = add_dependency(reference, detail)
            if not ok then return nil, reason end
        end
        return nil, nil, detail
    end

    local function resolve_part_mesh(render)
        local instance = render.sourceInstance
        local class_name = render.sourceClassName
        local decorator = render.decorator
        local reference
        if decorator and decorator.className == "SpecialMesh" then
            reference = decorator.meshId
            if not reference and decorator.meshType == "Head" then
                reference = "rbxasset://asset/Head.mesh"
            end
        elseif CSG_CLASS[class_name] then
            reference = get_content(instance, "AssetId", "MeshId", "MeshID")
        elseif class_name == "MeshPart" then
            reference = get_content(instance, "MeshId", "MeshID")
        end

        local is_csg = CSG_CLASS[class_name] == true
        local explicit = nil
        local resolution_reason = nil
        local deferred_dependency = nil
        if is_csg and reference then
            explicit, resolution_reason, deferred_dependency = resolve(reference, {
                role = "csg_explicit_mesh",
                class_name = class_name,
                path = render.sourceInstancePath,
                asset_type = "csg_mesh",
            }, false)
            if resolution_reason then return nil, resolution_reason end
            if explicit then return explicit end
        end

        local best = nil
        local candidates = embedded_candidates(instance)
        for index = 1, #candidates do
            local candidate, reason = decode_payload(candidates[index], {
                role = "embedded_part_mesh",
                class_name = class_name,
                path = render.sourceInstancePath,
                asset_type = is_csg and "csg_mesh" or "mesh",
            })
            if reason then return nil, reason end
            best = prefer(best, candidate)
            if score(best) >= 4 then break end
        end
        if best and score(best) > 1 then return best end

        if is_csg and reference then
            local ok, reason = add_dependency(reference, deferred_dependency)
            if not ok then return nil, reason end
        end
        if best then return best end

        if reference and not is_csg then
            local parsed, reason = resolve(reference, {
                role = decorator and "special_mesh" or "part_mesh",
                class_name = class_name,
                path = render.sourceInstancePath,
                asset_type = is_csg and "csg_mesh" or "mesh",
            })
            if reason then return nil, reason end
            return parsed
        end
        return nil
    end

    local function reserve(vertex_count)
        local current = math.floor(#positions / 3)
        if vertex_count < 0 or current + vertex_count > max_vertices then
            return false, "csg_output_vertex_limit"
        end
        return true
    end

    local function append_bounds(x, y, z)
        if not is_finite(x) or not is_finite(y) or not is_finite(z) then
            return false
        end
        min_x, min_y, min_z = math.min(min_x, x),
            math.min(min_y, y), math.min(min_z, z)
        max_x, max_y, max_z = math.max(max_x, x),
            math.max(max_y, y), math.max(max_z, z)
        return true
    end

    local function render_rgba(render)
        local color = type(render.color) == "table" and render.color or {}
        local transparency = clamp_color_channel(
            get_property(render.sourceInstance, "Transparency"), 0)
        local authored_alpha = clamp_color_channel(
            color.a or color.A or color.alpha or color.Alpha or color[4], 1)
        return clamp_color_channel(color.r or color.R or color.x
                or color.X or color[1], 1),
            clamp_color_channel(color.g or color.G or color.y
                or color.Y or color[2], 1),
            clamp_color_channel(color.b or color.B or color.z
                or color.Z or color[3], 1),
            authored_alpha * (1 - transparency)
    end

    local function append_rgba(mesh_colors, vertex_index,
            fallback_r, fallback_g, fallback_b, fallback_a)
        if type(mesh_colors) == "table" and #mesh_colors > 0 then
            local color_index = (vertex_index - 1) * 4 + 1
            -- Authored mesh colors own all four channels. missing or malformed
            -- components fail safely to the mesh convention (opaque white),
            -- never to the host child's color
            colors[#colors + 1] = clamp_color_channel(
                mesh_colors[color_index], 1)
            colors[#colors + 1] = clamp_color_channel(
                mesh_colors[color_index + 1], 1)
            colors[#colors + 1] = clamp_color_channel(
                mesh_colors[color_index + 2], 1)
            colors[#colors + 1] = clamp_color_channel(
                mesh_colors[color_index + 3], 1)
            return
        end
        colors[#colors + 1] = fallback_r
        colors[#colors + 1] = fallback_g
        colors[#colors + 1] = fallback_b
        colors[#colors + 1] = fallback_a
    end

    local function append_mesh(mesh_data, transform,
            fallback_r, fallback_g, fallback_b, fallback_a)
        local mesh_positions = mesh_data.positions or {}
        local mesh_normals = mesh_data.normals or {}
        local mesh_uvs = mesh_data.uvs or {}
        local mesh_colors = mesh_data.colors
        local vertex_count = math.floor(#mesh_positions / 9) * 3
        if vertex_count <= 0 then return false end
        local ok, reason = reserve(vertex_count)
        if not ok then return nil, reason end
        local flip_winding = transform_flips_winding(transform)
        if mesh_data.winding_flipped == true then
            flip_winding = not flip_winding
        end
        local order = flip_winding and { 0, 2, 1 } or { 0, 1, 2 }
        for triangle_start = 1, vertex_count, 3 do
            for order_index = 1, 3 do
                local vertex_index = triangle_start + order[order_index]
                local pidx = (vertex_index - 1) * 3 + 1
                local uidx = (vertex_index - 1) * 2 + 1
                local lx = (tonumber(mesh_positions[pidx]) or 0)
                    * transform.scale_x
                local ly = (tonumber(mesh_positions[pidx + 1]) or 0)
                    * transform.scale_y
                local lz = (tonumber(mesh_positions[pidx + 2]) or 0)
                    * transform.scale_z
                local x, y, z = transform_point(transform, lx, ly, lz)
                if not append_bounds(x, y, z) then
                    return nil, "csg_nonfinite_geometry"
                end
                positions[#positions + 1] = x
                positions[#positions + 1] = y
                positions[#positions + 1] = z
                local nx, ny, nz = transform_normal(transform,
                    tonumber(mesh_normals[pidx]) or 0,
                    tonumber(mesh_normals[pidx + 1]) or 1,
                    tonumber(mesh_normals[pidx + 2]) or 0)
                normals[#normals + 1] = nx
                normals[#normals + 1] = ny
                normals[#normals + 1] = nz
                uvs[#uvs + 1] = tonumber(mesh_uvs[uidx]) or 0
                uvs[#uvs + 1] = tonumber(mesh_uvs[uidx + 1]) or 0
                append_rgba(mesh_colors, vertex_index,
                    fallback_r, fallback_g, fallback_b, fallback_a)
            end
        end
        return true
    end

    local function append_primitive(vertices, transform,
            color_r, color_g, color_b, color_a)
        if type(vertices) ~= "table" or #vertices == 0 then return false end
        local vertex_count = math.floor(#vertices / 3) * 3
        local ok, reason = reserve(vertex_count)
        if not ok then return nil, reason end
        local flip_winding = transform_flips_winding(transform)
        local order = flip_winding and { 0, 2, 1 } or { 0, 1, 2 }
        for index = 1, vertex_count, 3 do
            local triangle = {}
            for corner = 1, 3 do
                local vertex = vertices[index + order[corner]]
                local x, y, z = transform_point(transform,
                    (tonumber(vertex[1]) or 0) * transform.scale_x,
                    (tonumber(vertex[2]) or 0) * transform.scale_y,
                    (tonumber(vertex[3]) or 0) * transform.scale_z)
                if not append_bounds(x, y, z) then
                    return nil, "csg_nonfinite_geometry"
                end
                local triangle_index = (corner - 1) * 3 + 1
                triangle[triangle_index], triangle[triangle_index + 1],
                    triangle[triangle_index + 2] = x, y, z
            end
            local ax, ay, az = triangle[1], triangle[2], triangle[3]
            local bx, by, bz = triangle[4], triangle[5], triangle[6]
            local cx, cy, cz = triangle[7], triangle[8], triangle[9]
            local ux, uy, uz = bx - ax, by - ay, bz - az
            local vx, vy, vz = cx - ax, cy - ay, cz - az
            local nx, ny, nz = normalize(
                uy * vz - uz * vy,
                uz * vx - ux * vz,
                ux * vy - uy * vx,
                0, 1, 0)
            for offset = 1, 9 do
                positions[#positions + 1] = triangle[offset]
                if offset % 3 == 0 then
                    normals[#normals + 1] = nx
                    normals[#normals + 1] = ny
                    normals[#normals + 1] = nz
                    uvs[#uvs + 1] = 0
                    uvs[#uvs + 1] = 0
                    append_rgba(nil, 1,
                        color_r, color_g, color_b, color_a)
                end
            end
        end
        return true
    end

    -- resolve every dependency before writing a single output vertex. Besides
    -- making all limit failures atomic, this lets worker callers reject an
    -- unresolved composition without paying to build a large fallback mesh
    local resolved_part_meshes = {}
    for index = 1, #parts do
        local parsed, reason = resolve_part_mesh(parts[index])
        if reason then
            return { status = "limited", reason = reason, mesh = nil }
        end
        resolved_part_meshes[index] = parsed or false
    end
    if #dependencies > 0 and opts.allow_provisional_geometry == false then
        return {
            status = "provisional",
            mesh = nil,
            dependencies = dependencies,
            stats = {
                part_count = #parts,
                output_vertices = 0,
                dependency_count = #dependencies,
            },
        }
    end

    for index = 1, #parts do
        local render = parts[index]
        local parsed = resolved_part_meshes[index]
        if parsed == false then parsed = nil end
        local color_r, color_g, color_b, color_a = render_rgba(render)
        local appended = false
        if parsed then
            local ok, append_reason = append_mesh(
                parsed, mesh_transform(render, parsed, opts),
                color_r, color_g, color_b, color_a)
            if ok == nil then
                return {
                    status = "limited",
                    reason = append_reason,
                    mesh = nil,
                }
            end
            appended = ok == true
            if appended then source_mesh_parts = source_mesh_parts + 1 end
        end
        if not appended then
            local transform, shape = primitive_transform(render, opts)
            local primitive = PRIMITIVES[shape]
            local ok, append_reason = append_primitive(primitive, transform,
                color_r, color_g, color_b, color_a)
            if ok == nil then
                return {
                    status = "limited",
                    reason = append_reason,
                    mesh = nil,
                }
            end
            if ok then primitive_parts = primitive_parts + 1 end
        end
    end

    if #positions == 0 then
        return {
            status = "empty",
            reason = "csg_parts_hold_no_render_geometry",
            mesh = nil,
            dependencies = dependencies,
            stats = {
                part_count = #parts,
                output_vertices = 0,
            },
        }
    end

    local vertex_count = math.floor(#positions / 3)
    local result = {
        positions = positions,
        normals = normals,
        uvs = uvs,
        colors = colors,
        bounds = {
            min_x = min_x, min_y = min_y, min_z = min_z,
            max_x = max_x, max_y = max_y, max_z = max_z,
        },
        source_kind = "csg_child_parts",
        vertex_count = vertex_count,
        triangle_count = math.floor(vertex_count / 3),
        index_count = vertex_count,
        has_uvs = true,
        has_normals = true,
        has_vertex_colors = #colors == vertex_count * 4,
        csg_composition_complete = #dependencies == 0,
        csg_dependencies = dependencies,
        basis = nil,
        uv_transform = {
            flip_u = false,
            flip_v = false,
            source = "composed_child_parts",
        },
    }
    return {
        status = #dependencies == 0 and "ready" or "provisional",
        mesh = result,
        dependencies = dependencies,
        stats = {
            part_count = #parts,
            source_mesh_parts = source_mesh_parts,
            primitive_parts = primitive_parts,
            output_vertices = vertex_count,
            dependency_count = #dependencies,
        },
    }
end

return Composer
