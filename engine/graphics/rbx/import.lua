local constants = require("engine/graphics/rbx/constants")
local dom = require("engine/graphics/rbx/dom")
local mesh = require("engine/graphics/rbx/mesh")
local util = require("engine/graphics/rbx/util")

local import = {}

local PART_SHAPE_ENUM = {
    [0] = "Ball",
    [1] = "Block",
    [2] = "Cylinder",
    [3] = "Wedge",
    [4] = "CornerWedge",
}

local SPECIAL_MESH_TYPE_ENUM = {
    [0] = "Head",
    [1] = "Torso",
    [2] = "Wedge",
    [3] = "Sphere",
    [4] = "Cylinder",
    [5] = "FileMesh",
    [6] = "Brick",
    [7] = "Prism",
    [8] = "Pyramid",
    [9] = "ParallelRamp",
    [10] = "RightAngleRamp",
    [11] = "CornerWedge",
}

local LEGACY_EMPTY_SPECIAL_MESH_TYPES = {
    Prism = true,
    Pyramid = true,
    ParallelRamp = true,
    RightAngleRamp = true,
    CornerWedge = true,
}

local function normalize_shape(shape, class_name)
    if class_name == "WedgePart" then
        return "Wedge"
    end
    if class_name == "CornerWedgePart" then
        return "CornerWedge"
    end
    if class_name == "TrussPart" then
        return "Truss"
    end
    if type(shape) == "table" then
        shape = shape.Value
            or shape.value
            or shape.Name
            or shape.name
            or shape.EnumItem
            or shape.enumItem
            or shape.Id
            or shape.id
    end
    local numeric = tonumber(shape)
    if numeric ~= nil then
        return PART_SHAPE_ENUM[math.floor(numeric + 0.5)] or "Block"
    end
    local key = type(shape) == "string" and util.trim(shape):lower() or nil
    return key and constants.PART_SHAPES.aliases[key] or "Block"
end

local function special_mesh_builtin_shape(mesh_type)
    local key = type(mesh_type) == "string" and (constants.SPECIAL_MESH_TYPES.aliases[mesh_type:lower()] or mesh_type) or nil
    if key and LEGACY_EMPTY_SPECIAL_MESH_TYPES[key] then
        return "None"
    end
    return key and constants.SPECIAL_MESH_TYPES.primitive_shapes[key] or nil
end

local function normalize_special_mesh_type(mesh_type, mesh_id)
    if type(mesh_id) == "string" then
        mesh_id = util.trim(mesh_id)
        if mesh_id == "" then
            mesh_id = nil
        end
    else
        mesh_id = nil
    end

    if type(mesh_type) == "table" then
        mesh_type = mesh_type.Value
            or mesh_type.value
            or mesh_type.Name
            or mesh_type.name
            or mesh_type.EnumItem
            or mesh_type.enumItem
            or mesh_type.Id
            or mesh_type.id
    end

    local numeric = tonumber(mesh_type)
    if numeric ~= nil then
        local resolved = SPECIAL_MESH_TYPE_ENUM[math.floor(numeric + 0.5)]
        return resolved or (mesh_id and "FileMesh" or nil)
    end

    if type(mesh_type) == "string" then
        local normalized = util.trim(mesh_type):gsub("^Enum%.MeshType%.", "")
        local lowered = normalized:gsub("[%s_]+", ""):lower()
        local aliases = {
            prism = "Prism",
            pyramid = "Pyramid",
            parallelramp = "ParallelRamp",
            rightangleramp = "RightAngleRamp",
            cornerwedge = "CornerWedge",
        }
        return constants.SPECIAL_MESH_TYPES.aliases[lowered]
            or aliases[lowered]
            or normalized
    end

    return mesh_id and "FileMesh" or nil
end

local function find_child_by_class(instance, class_name)
    for index = 1, #(instance.children or {}) do
        local child = instance.children[index]
        if child.className == class_name then
            return child
        end
    end
    return nil
end

local function get_raw_property(instance, name)
    local properties = instance and instance.properties or nil
    if not properties then return nil end
    local value = properties[name]
    if value == nil then value = properties[name:lower()] end
    return value
end

local function get_property(instance, name)
    local value = get_raw_property(instance, name)
    return dom.unwrap(value)
end

local function get_content_text(value)
    if dom.is_value(value) then
        value = value.value
    end
    if type(value) == "table" then
        if value.uri then
            return value.uri
        end
        if value.value then
            return value.value
        end
        if value.text then
            return value.text
        end
    end
    return type(value) == "string" and value or nil
end

local function get_vector3(instance, name, defaults)
    local value = get_property(instance, name) or defaults or {}
    return {
        x = tonumber(value.x or value.X or defaults and defaults.x or 0) or 0,
        y = tonumber(value.y or value.Y or defaults and defaults.y or 0) or 0,
        z = tonumber(value.z or value.Z or defaults and defaults.z or 0) or 0,
    }
end

local function get_cframe(instance)
    local value = get_property(instance, "CFrame") or get_property(instance, "CoordinateFrame")
    if type(value) ~= "table" then
        return {
            position = { x = 0, y = 0, z = 0 },
            orientation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        }
    end
    if value.position and value.orientation then
        return value
    end
    return {
        position = {
            x = tonumber(value.X or value.x or 0) or 0,
            y = tonumber(value.Y or value.y or 0) or 0,
            z = tonumber(value.Z or value.z or 0) or 0,
        },
        orientation = {
            tonumber(value.R00 or value.r00 or 1) or 1,
            tonumber(value.R01 or value.r01 or 0) or 0,
            tonumber(value.R02 or value.r02 or 0) or 0,
            tonumber(value.R10 or value.r10 or 0) or 0,
            tonumber(value.R11 or value.r11 or 1) or 1,
            tonumber(value.R12 or value.r12 or 0) or 0,
            tonumber(value.R20 or value.r20 or 0) or 0,
            tonumber(value.R21 or value.r21 or 0) or 0,
            tonumber(value.R22 or value.r22 or 1) or 1,
        },
    }
end

local function compute_bounds(transform, size)
    local hx, hy, hz = math.abs(size.x or 0) * 0.5, math.abs(size.y or 0) * 0.5, math.abs(size.z or 0) * 0.5
    local o = transform.orientation or { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    local ex = math.abs(o[1]) * hx + math.abs(o[2]) * hy + math.abs(o[3]) * hz
    local ey = math.abs(o[4]) * hx + math.abs(o[5]) * hy + math.abs(o[6]) * hz
    local ez = math.abs(o[7]) * hx + math.abs(o[8]) * hy + math.abs(o[9]) * hz
    local p = transform.position or { x = 0, y = 0, z = 0 }
    return {
        min = { x = p.x - ex, y = p.y - ey, z = p.z - ez },
        max = { x = p.x + ex, y = p.y + ey, z = p.z + ez },
    }
end

local function geometry_equivalence_key(shape, decorator_class, decorator_type)
    if decorator_class == "CylinderMesh" or decorator_type == "Cylinder" or shape == "Cylinder" then
        return "geometry:cylinder"
    end
    if decorator_type == "Sphere" or decorator_type == "Head" or shape == "Ball" then
        return "geometry:sphere"
    end
    if decorator_class == "BlockMesh" or decorator_type == "Brick" or shape == "Block" then
        return "geometry:block"
    end
    if decorator_type == "Wedge" or shape == "Wedge" then
        return "geometry:wedge"
    end
    return "geometry:" .. tostring(shape or "unknown")
end

local function extract_mesh_payload(instance, opts)
    opts = opts or {}
    local extracted = mesh.extract_from_instance(instance)
    if not extracted then
        return nil
    end

    local render = {
        raw = extracted,
    }
    if extracted.meshData and opts.decode_mesh_payloads ~= false then
        render.meshData = mesh.parse(extracted.meshData)
    end
    if extracted.physicsData and opts.decode_mesh_payloads ~= false then
        render.physicsData = mesh.parse(extracted.physicsData)
    end
    render.preferred = mesh.choose_preferred(render.meshData, render.physicsData)
    return render
end

local function classify_basepart(instance, opts)
    local class_name = instance.className
    local primitive_shape = normalize_shape(get_property(instance, "Shape"), class_name)
    local transform = get_cframe(instance)
    local size = get_vector3(instance, "Size", { x = 4, y = 1, z = 2 })
    local color = get_property(instance, "Color") or get_property(instance, "Color3") or get_property(instance, "Color3uint8")
    local material = get_property(instance, "Material")
    local render = {
        sourceClassName = class_name,
        sourceInstance = opts.retain_source_instances == true
            and instance or nil,
        sourceInstancePath = dom.instance_path(instance),
        sourceInstanceRef = instance.referent,
        sourceGeometryKind = class_name,
        transform = transform,
        bounds = compute_bounds(transform, size),
        material = material,
        color = color,
        size = size,
        sourceProperties = instance.properties,
        primitiveShapeKind = primitive_shape,
        meshDecoratorKind = nil,
        meshSourceKind = nil,
        geometryData = nil,
    }

    if class_name == "MeshPart" then
        render.renderKind = "MeshPartObject"
        render.semanticKind = "MeshPartObject"
        render.meshSourceKind = "meshpart_content"
        render.geometryData = extract_mesh_payload(instance, opts)
        render.geometryEquivalenceKey = "geometry:meshpart:" .. tostring(render.sourceInstanceRef)
        return render
    end
    if class_name == "UnionOperation" then
        render.renderKind = "UnionOperationObject"
        render.semanticKind = "UnionOperationObject"
        render.meshSourceKind = "union_blob"
        render.geometryData = extract_mesh_payload(instance, opts)
        render.geometryEquivalenceKey = "geometry:union:" .. tostring(render.sourceInstanceRef)
        return render
    end
    if class_name == "PartOperation" or class_name == "NegateOperation" then
        render.renderKind = "PartOperationObject"
        render.semanticKind = "PartOperationObject"
        render.meshSourceKind = "partoperation_blob"
        render.geometryData = extract_mesh_payload(instance, opts)
        render.geometryEquivalenceKey = "geometry:partoperation:" .. tostring(render.sourceInstanceRef)
        return render
    end

    local special_mesh = find_child_by_class(instance, "SpecialMesh")
    local block_mesh = find_child_by_class(instance, "BlockMesh")
    local cylinder_mesh = find_child_by_class(instance, "CylinderMesh")
    local decorator = special_mesh or cylinder_mesh or block_mesh

    if decorator then
        local mesh_id = get_content_text(
            get_raw_property(decorator, "MeshId")
                or get_raw_property(decorator, "MeshID"))
        local mesh_type = decorator.className == "SpecialMesh" and normalize_special_mesh_type(
                get_property(decorator, "MeshType"),
                mesh_id
            )
            or (decorator.className == "CylinderMesh" and "Cylinder")
            or (decorator.className == "BlockMesh" and "Brick")
            or nil
        local normalized_mesh_type = type(mesh_type) == "string"
            and (constants.SPECIAL_MESH_TYPES.aliases[mesh_type:lower()] or mesh_type)
            or mesh_type

        render.renderKind = "PrimitivePartWithDecorativeMesh"
        render.semanticKind = "PrimitivePartWithDecorativeMesh"
        render.meshDecoratorKind = decorator.className == "SpecialMesh" and normalized_mesh_type or decorator.className
        render.meshSourceKind = decorator.className == "SpecialMesh"
                and (mesh_id and util.trim(mesh_id) ~= "" and "specialmesh_filemesh" or "specialmesh_builtin")
            or "specialmesh_builtin"
        render.decorator = {
            className = decorator.className,
            meshType = normalized_mesh_type,
            meshId = mesh_id,
            textureId = get_content_text(
                get_raw_property(decorator, "TextureId")
                    or get_raw_property(decorator, "TextureID")),
            scale = get_vector3(decorator, "Scale", { x = 1, y = 1, z = 1 }),
            offset = get_vector3(decorator, "Offset", { x = 0, y = 0, z = 0 }),
            vertexColor = get_property(decorator, "VertexColor"),
        }
        render.geometryData = {
            primitiveShape = special_mesh_builtin_shape(normalized_mesh_type) or primitive_shape,
            decorator = render.decorator,
        }
        render.geometryEquivalenceKey = geometry_equivalence_key(render.geometryData.primitiveShape, decorator.className, normalized_mesh_type)
        return render
    end

    render.renderKind = "PrimitivePart"
    render.semanticKind = "PrimitivePart"
    render.meshSourceKind = "primitive"
    render.geometryData = {
        primitiveShape = primitive_shape,
    }
    render.geometryEquivalenceKey = geometry_equivalence_key(primitive_shape)
    return render
end

local function classify_instance(instance, renderables, opts)
    if constants.SUPPORTED_BASEPART_CLASSES[instance.className] then
        renderables[#renderables + 1] = classify_basepart(instance, opts)
        return
    end

    if opts.include_compound_containers ~= false
        and #(instance.children or {}) > 0 then
        renderables[#renderables + 1] = {
            renderKind = "CompoundContainer",
            semanticKind = "ModelNode",
            sourceClassName = instance.className,
            sourceInstance = opts.retain_source_instances == true
                and instance or nil,
            sourceInstancePath = dom.instance_path(instance),
            sourceInstanceRef = instance.referent,
            sourceGeometryKind = "container",
            transform = get_cframe(instance),
            bounds = nil,
            geometryData = nil,
            geometryEquivalenceKey = nil,
        }
    end
end

local function normalize_traversal_limit(value)
    value = tonumber(value)
    if value == nil or value ~= value then return nil end
    if value == math.huge then return nil end
    return math.max(0, math.floor(value))
end

-- Preorder traversal with an early-stop contract.  dom.walk intentionally has
-- no cancellation path, which is right for ordinary imports but let worker CSG
-- composition visit and materialize an entire hostile ChildData tree before it
-- noticed that max_parts had already been exceeded.  keeping a stack of child
-- arrays (rather than pushing every sibling) bounds auxiliary storage by depth
local function walk_bounded(roots, visit)
    roots = util.arrayify(roots)
    local stack = {
        { children = roots, index = 1 },
    }
    while #stack > 0 do
        local frame = stack[#stack]
        local instance = frame.children[frame.index]
        if instance == nil then
            stack[#stack] = nil
        else
            frame.index = frame.index + 1
            if visit(instance) == false then
                return false
            end
            local children = instance.children or {}
            if #children > 0 then
                stack[#stack + 1] = { children = children, index = 1 }
            end
        end
    end
    return true
end

function import.import_renderables(file_or_scene, opts)
    opts = opts or {}
    local file = file_or_scene.file or file_or_scene
    local renderables = {}

    -- these options are deliberately opt-in.  existing map imports preserve
    -- their complete traversal, while untrusted worker callers can stop before
    -- allocating the first entry beyond either budget.  the optional
    -- caller-owned stats table is also a cheap instrumentation seam for proving
    -- that the cap applies during traversal rather than after the fact
    local max_parts = normalize_traversal_limit(opts.max_parts)
    local max_renderables = normalize_traversal_limit(opts.max_renderables)
    local traversal = opts.traversal_stats or {}
    traversal.visited = 0
    traversal.parts_seen = 0
    traversal.materialized = 0
    traversal.completed = false
    traversal.stopped = false
    traversal.limit_reason = nil
    traversal.stop_reason = nil

    local completed = walk_bounded(file.roots, function(instance)
        traversal.visited = traversal.visited + 1

        if type(opts.on_visit_instance) == "function" then
            local keep_going, stop_reason = opts.on_visit_instance(
                instance, traversal)
            if keep_going == false then
                traversal.stopped = true
                traversal.stop_reason = stop_reason or "caller_stop"
                return false
            end
        end

        local is_part = constants.SUPPORTED_BASEPART_CLASSES[
            instance.className] == true
        local materializes = is_part
            or (opts.include_compound_containers ~= false
                and #(instance.children or {}) > 0)

        if is_part then
            traversal.parts_seen = traversal.parts_seen + 1
            if max_parts ~= nil and traversal.parts_seen > max_parts then
                traversal.stopped = true
                traversal.limit_reason = "max_parts"
                return false
            end
        end
        if materializes and max_renderables ~= nil
            and traversal.materialized >= max_renderables then
            traversal.stopped = true
            traversal.limit_reason = "max_renderables"
            return false
        end

        local before = #renderables
        classify_instance(instance, renderables, opts)
        traversal.materialized = traversal.materialized
            + (#renderables - before)
        return true
    end)
    traversal.completed = completed == true
    return renderables
end

function import.import_scene(file, opts)
    opts = opts or {}
    local renderables = import.import_renderables(file, opts)
    local bounds = util.empty_bounds()
    for index = 1, #renderables do
        local entry = renderables[index]
        if entry.bounds then
            util.expand_bounds(bounds, {
                min = { x = entry.bounds.min.x, y = entry.bounds.min.y, z = entry.bounds.min.z },
                max = { x = entry.bounds.max.x, y = entry.bounds.max.y, z = entry.bounds.max.z },
            })
        end
    end

    return {
        file = file,
        formatKind = file.formatKind,
        path = file.sourceName,
        roots = file.roots,
        renderables = renderables,
        bounds = util.ensure_bounds(bounds, 32),
        warnings = file.warnings,
        stats = {
            instanceCount = #file.instances,
            rootCount = #file.roots,
            renderableCount = #renderables,
        },
    }
end

return import
