-- RBX-specific Menori resource backend
--
-- this is intentionally a small resource seam, not a second scene graph. the
-- RBX runtime already owns partitioning, culling, and submission order, Menori
-- owns GPU resources for opaque instanced batches and non-instanced static or
-- streaming meshes. raw LOVE aliases remain public because RBX, not Menori's
-- scene graph, owns state ordering, uniforms, draw ranges, and submission

local menori = require("engine/services/oss/menori")

local IDENTITY = {
    id = "menori",
    name = "Menori",
    api_version = 1,
    library_path = "engine/services/oss/menori",
    opaque_instancing = true,
    generic_instancing = true,
    static_mesh_resources = true,
    static_mesh_updates = true,
    raw_mesh_adoption = true,
    indexed_geometry = true,
    uint16_indices = true,
    uint32_indices = true,
    legacy_raw_meshes = true,
}

local Backend = {}
Backend.__index = Backend
Backend.id = IDENTITY.id
Backend.name = IDENTITY.id
Backend.identity = IDENTITY

local Batch = {}
Batch.__index = Batch

local function copy_table(source)
    local target = {}
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

local function assert_array(value, name, allow_empty)
    assert(type(value) == "table", name .. " must be a table")
    if not allow_empty then
        assert(#value > 0, name .. " must not be empty")
    end
    return value
end

local function normalize_instance_count(rows, count)
    rows = assert_array(rows or {}, "instance rows", true)
    if count == nil then
        count = #rows
    end

    local numeric_count = tonumber(count)
    assert(numeric_count ~= nil, "instance count must be a number")
    assert(numeric_count >= 0 and numeric_count == math.floor(numeric_count),
        "instance count must be a non-negative integer")
    assert(#rows >= numeric_count, "instance row table is shorter than instance count")
    return rows, numeric_count
end

local VERTEX_SCALAR_BYTES = {
    byte = 1,
    int8 = 1,
    uint8 = 1,
    unorm8 = 1,
    snorm8 = 1,
    short = 2,
    int16 = 2,
    uint16 = 2,
    unorm16 = 2,
    snorm16 = 2,
    half = 2,
    float16 = 2,
    int = 4,
    uint = 4,
    int32 = 4,
    uint32 = 4,
    float = 4,
    float32 = 4,
}

local function attribute_byte_size(attribute)
    local format = attribute.format or attribute[2]
    local components = tonumber(attribute.components or attribute[3]) or 1
    assert(type(format) == "string", "vertex attribute format must be a string")
    local scalar, vector_count = format:match("^(.-)vec([1-4])$")
    if scalar then
        format = scalar
        components = tonumber(vector_count)
    else
        local legacy_scalar, legacy_count = format:match("^(.-)([1-4])$")
        if legacy_scalar and VERTEX_SCALAR_BYTES[legacy_scalar] then
            format = legacy_scalar
            components = tonumber(legacy_count)
        end
    end
    local scalar_bytes = VERTEX_SCALAR_BYTES[format]
    assert(scalar_bytes ~= nil,
        "unsupported vertex attribute format '" .. tostring(format) .. "'; provide vertex_stride_bytes")
    assert(components >= 1 and components == math.floor(components),
        "vertex attribute component count must be a positive integer")
    return scalar_bytes * components
end

local function vertex_stride_bytes(vertex_format, explicit_stride)
    if explicit_stride ~= nil then
        local stride = tonumber(explicit_stride)
        assert(stride and stride > 0 and stride == math.floor(stride),
            "vertex_stride_bytes must be a positive integer")
        return stride
    end
    assert_array(vertex_format, "base vertex format", false)
    local stride = 0
    for index = 1, #vertex_format do
        stride = stride + attribute_byte_size(vertex_format[index])
    end
    return stride
end

local function static_spec_is_textured(spec)
    if spec.textured ~= nil then
        return spec.textured == true
    end
    if spec.category == "textured" or spec.resource_category == "textured" then
        return true
    end
    return tostring(spec.kind or ""):find("textured", 1, true) ~= nil
end

local function normalize_usage(usage)
    usage = usage or "static"
    assert(usage == "static" or usage == "dynamic" or usage == "stream",
        "mesh usage must be 'static', 'dynamic', or 'stream'")
    return usage
end

local function is_love_mesh(value)
    if type(value) ~= "userdata" then
        return false
    end
    local ok, result = pcall(function()
        return value.typeOf and value:typeOf("Mesh")
    end)
    return ok and result == true
end

local function get_data_size(value)
    if type(value) ~= "userdata" then
        return nil
    end
    local ok, size = pcall(function()
        return value.getSize and value:getSize()
    end)
    return ok and tonumber(size) or nil
end

local function vertex_format_signature(vertex_format)
    local fields = {}
    for index = 1, #(vertex_format or {}) do
        local attribute = vertex_format[index]
        fields[#fields + 1] = tostring(attribute.name or attribute[1] or "")
        fields[#fields + 1] = tostring(attribute.format or attribute[2] or "")
        fields[#fields + 1] = tostring(attribute.components or attribute[3] or "")
        fields[#fields + 1] = tostring(attribute.location or attribute[4] or "")
    end
    return table.concat(fields, "\31")
end

local function looks_like_static_spec(value)
    return type(value) == "table" and (
        value.base_vertex_format ~= nil
        or value.vertex_format ~= nil
        or value.vertexformat ~= nil
        or value.base_vertices ~= nil
        or value.vertices ~= nil
        or value.vertex_data ~= nil
        or value.draw_mesh ~= nil
        or value.raw_mesh ~= nil
        or value.vertex_count ~= nil
        or value.vertex_capacity ~= nil
        or value.vertex_stride_bytes ~= nil
        or value.usage ~= nil
        or value.indices ~= nil
        or value.clear_indices ~= nil
        or value.force_replace ~= nil
        or value.texture ~= nil
        or value.bound ~= nil
        or value.bounds ~= nil
        or value.kind ~= nil
        or value.textured ~= nil
        or value.category ~= nil
        or value.resource_category ~= nil
        or value.mode ~= nil
    )
end

local function normalize_static_create_spec(vertex_format_or_spec, vertices, options)
    local spec
    if vertices == nil and looks_like_static_spec(vertex_format_or_spec) then
        spec = copy_table(vertex_format_or_spec)
    else
        spec = copy_table(options)
        spec.base_vertex_format = vertex_format_or_spec
        spec.base_vertices = vertices
    end

    local supplied_draw_mesh = spec.draw_mesh or spec.raw_mesh
    if supplied_draw_mesh ~= nil then
        assert(is_love_mesh(supplied_draw_mesh), "draw_mesh must be a LOVE Mesh")
    end
    local base_vertex_format = spec.base_vertex_format
        or spec.vertex_format
        or spec.vertexformat
    if base_vertex_format == nil and supplied_draw_mesh then
        base_vertex_format = supplied_draw_mesh:getVertexFormat()
    end
    local base_vertices = spec.base_vertices or spec.vertices
    local vertex_data = spec.vertex_data
    if vertex_data == nil and base_vertices ~= nil and type(base_vertices) ~= "table" then
        vertex_data = base_vertices
        base_vertices = nil
    end
    local vertex_count = tonumber(spec.vertex_count or spec.count)
    if vertex_count == nil and type(base_vertices) == "table" then
        vertex_count = #base_vertices
    elseif vertex_count == nil and supplied_draw_mesh then
        vertex_count = supplied_draw_mesh:getVertexCount()
    end
    assert(vertex_count ~= nil and vertex_count >= 0
            and vertex_count == math.floor(vertex_count),
        "vertex_count must be a non-negative integer")

    local vertex_capacity = tonumber(spec.vertex_capacity)
    if vertex_capacity == nil and supplied_draw_mesh then
        vertex_capacity = supplied_draw_mesh:getVertexCount()
    end
    vertex_capacity = vertex_capacity or vertex_count
    assert(vertex_capacity > 0 and vertex_capacity == math.floor(vertex_capacity)
            and vertex_capacity >= vertex_count,
        "vertex_capacity must be a positive integer at least vertex_count")
    if not supplied_draw_mesh then
        assert(base_vertices ~= nil or vertex_data ~= nil or vertex_count == 0,
            "base vertices or vertex_data are required")
    end

    local stride = vertex_stride_bytes(base_vertex_format, spec.vertex_stride_bytes)
    local data_size = get_data_size(vertex_data)
    local vertex_payload_bytes = 0
    if data_size ~= nil then
        assert(data_size % stride == 0,
            "vertex_data size must be a multiple of vertex_stride_bytes")
        assert(data_size >= vertex_count * stride,
            "vertex_data is shorter than vertex_count * vertex_stride_bytes")
        assert(data_size <= vertex_capacity * stride,
            "vertex_data is larger than vertex_capacity * vertex_stride_bytes")
        vertex_payload_bytes = data_size
    elseif type(base_vertices) == "table" then
        assert(#base_vertices >= vertex_count,
            "base vertex table is shorter than vertex_count")
        assert(#base_vertices <= vertex_capacity,
            "base vertex table is longer than vertex_capacity")
        vertex_payload_bytes = #base_vertices * stride
    end

    local indices = spec.indices
    if indices ~= nil then
        assert_array(indices, "base vertex indices", false)
    end
    local index_count = tonumber(spec.index_count)
        or (indices and #indices or 0)
    assert(index_count >= 0 and index_count == math.floor(index_count),
        "index_count must be a non-negative integer")
    if indices then
        assert(index_count == #indices,
            "index_count must match the supplied index array length")
    end
    local indices_tsize = tonumber(spec.indices_tsize)
    if index_count > 0 then
        indices_tsize = indices_tsize or 4
        assert(indices_tsize == 2 or indices_tsize == 4,
            "index data type size must be 2 or 4 bytes")
    else
        indices_tsize = nil
    end

    local textured = static_spec_is_textured(spec)
    local fallback_reason = spec.fallback_reason
    if fallback_reason ~= nil then
        fallback_reason = tostring(fallback_reason)
        if fallback_reason == "" then fallback_reason = nil end
    end
    return {
        base_vertex_format = base_vertex_format,
        base_vertices = base_vertices,
        vertex_data = vertex_data,
        vertex_count = vertex_count,
        vertex_capacity = vertex_capacity,
        vertex_stride_bytes = stride,
        vertex_payload_bytes = supplied_draw_mesh
            and 0 or vertex_payload_bytes,
        vertex_format_signature = vertex_format_signature(base_vertex_format),
        indices = indices,
        index_count = index_count,
        indices_tsize = indices_tsize,
        source_vertex_count = tonumber(spec.source_vertex_count)
            or (index_count > 0 and index_count or vertex_count),
        supplied_draw_mesh = supplied_draw_mesh,
        owns_draw_mesh = supplied_draw_mesh == nil or spec.owns_draw_mesh ~= false,
        usage = normalize_usage(spec.usage),
        mode = spec.mode or "triangles",
        kind = spec.kind or (textured and "static_textured" or "static_mesh"),
        opaque = spec.opaque ~= false,
        textured = textured,
        texture = spec.texture,
        bound = spec.bound or spec.bounds,
        skip_bound_calculation = spec.skip_bound_calculation ~= false
            and spec.calculate_bound ~= true,
        fallback = spec.fallback == true or fallback_reason ~= nil,
        fallback_reason = fallback_reason,
    }
end

local function static_resource_metrics(spec)
    local vertex_bytes = spec.vertex_capacity * spec.vertex_stride_bytes
    local index_bytes = spec.index_count * (spec.indices_tsize or 0)
    return vertex_bytes, index_bytes, vertex_bytes + index_bytes
end

local function normalize_create_spec(vertex_format_or_spec, vertices, instance_format, rows, options)
    if vertices == nil
        and type(vertex_format_or_spec) == "table"
        and (
            vertex_format_or_spec.base_vertex_format ~= nil
            or vertex_format_or_spec.vertex_format ~= nil
            or vertex_format_or_spec.vertexformat ~= nil
            or vertex_format_or_spec.base_vertices ~= nil
            or vertex_format_or_spec.vertices ~= nil
            or vertex_format_or_spec.draw_mesh ~= nil
            or vertex_format_or_spec.raw_mesh ~= nil
        )
    then
        return copy_table(vertex_format_or_spec)
    end

    local spec = copy_table(options)
    spec.base_vertex_format = vertex_format_or_spec
    spec.base_vertices = vertices
    spec.instance_format = instance_format
    spec.instance_rows = rows
    return spec
end

local function safe_release(resource)
    if resource == nil then
        return true
    end

    local release = resource.release
    if type(release) ~= "function" then
        return true
    end
    return pcall(release, resource)
end

local function update_peaks(stats)
    stats.peak_live_batches = math.max(stats.peak_live_batches, stats.live_batches)
    stats.peak_live_instances = math.max(stats.peak_live_instances, stats.live_instances)
    stats.peak_live_static_batches = math.max(
        stats.peak_live_static_batches or 0,
        stats.live_static_batches or 0)
    stats.peak_live_static_bytes = math.max(
        stats.peak_live_static_bytes or 0,
        stats.live_static_bytes or 0)
    stats.peak_live_textured_batches = math.max(
        stats.peak_live_textured_batches or 0,
        stats.live_textured_batches or 0)
    stats.peak_live_textured_bytes = math.max(
        stats.peak_live_textured_bytes or 0,
        stats.live_textured_bytes or 0)
end

local function refresh_batch_handles(batch)
    local instances = batch.instances
    batch.draw_mesh = batch.base_mesh and batch.base_mesh.lg_mesh
        or batch.raw_draw_mesh
        or nil
    batch.instance_mesh = instances and instances.instanced_mesh_buffer or nil
    batch.instance_capacity = instances and instances:get_capacity() or 0
end

function Batch:update(rows, count)
    if self.static_mesh then
        return self.backend:update_static_batch(self, rows, count)
    end
    return self.backend:update_opaque_batch(self, rows, count)
end

function Batch:replace(spec)
    assert(self.static_mesh, "replace is only available on static mesh batches")
    return self.backend:replace_static_batch(self, spec)
end

function Batch:release()
    return self.backend:release_batch(self)
end

function Backend.new(options)
    options = options or {}
    local implementation = options.menori or menori
    assert(type(implementation) == "table", "menori implementation must be a table")
    assert(implementation.Mesh ~= nil, "menori.Mesh is unavailable")
    assert(implementation.InstancedMesh ~= nil, "menori.InstancedMesh is unavailable")

    return setmetatable({
        id = IDENTITY.id,
        name = IDENTITY.id,
        identity = IDENTITY,
        generation = 1,
        menori = implementation,
        _batches = {},
        stats = {
            backend_id = IDENTITY.id,
            created_batches = 0,
            released_batches = 0,
            live_batches = 0,
            live_base_vertices = 0,
            live_base_indices = 0,
            live_indexed_batches = 0,
            live_instances = 0,
            peak_live_batches = 0,
            peak_live_instances = 0,
            instance_uploads = 0,
            uploaded_instance_rows = 0,
            uploaded_base_vertices = 0,
            uploaded_base_indices = 0,
            created_indexed_batches = 0,
            buffer_reallocations = 0,
            release_errors = 0,
            created_static_batches = 0,
            released_static_batches = 0,
            live_static_batches = 0,
            created_textured_batches = 0,
            released_textured_batches = 0,
            live_textured_batches = 0,
            peak_live_static_batches = 0,
            peak_live_static_bytes = 0,
            peak_live_textured_batches = 0,
            peak_live_textured_bytes = 0,
            adopted_static_batches = 0,
            live_adopted_static_batches = 0,
            static_uploads = 0,
            static_updates = 0,
            static_replacements = 0,
            static_create_errors = 0,
            static_update_errors = 0,
            static_replacement_errors = 0,
            static_fallback_count = 0,
            textured_fallback_count = 0,
            live_static_vertex_bytes = 0,
            live_static_index_bytes = 0,
            live_static_bytes = 0,
            live_textured_vertex_bytes = 0,
            live_textured_index_bytes = 0,
            live_textured_bytes = 0,
            uploaded_static_vertex_bytes = 0,
            uploaded_static_index_bytes = 0,
            uploaded_static_bytes = 0,
            uploaded_textured_vertex_bytes = 0,
            uploaded_textured_index_bytes = 0,
            uploaded_textured_bytes = 0,
            updated_static_vertex_bytes = 0,
            updated_static_index_bytes = 0,
            updated_static_bytes = 0,
            replacement_static_vertex_bytes = 0,
            replacement_static_index_bytes = 0,
            replacement_static_bytes = 0,
            fallback_static_vertex_bytes = 0,
            fallback_static_index_bytes = 0,
            fallback_static_bytes = 0,
            fallback_textured_vertex_bytes = 0,
            fallback_textured_index_bytes = 0,
            fallback_textured_bytes = 0,
            static_fallback_reasons = {},
        },
    }, Backend)
end

function Backend:get_identity()
    return copy_table(IDENTITY)
end

function Backend:get_stats()
    local stats = copy_table(self.stats)
    stats.static_fallback_reasons = copy_table(
        self.stats.static_fallback_reasons)
    return stats
end

function Backend:_assert_owned_batch(batch)
    assert(type(batch) == "table" and getmetatable(batch) == Batch,
        "expected a Menori resource batch")
    assert(batch.backend == self, "resource batch belongs to a different backend")
end

function Backend:_assert_owned_static_batch(batch)
    self:_assert_owned_batch(batch)
    assert(batch.static_mesh == true, "expected a Menori static mesh batch")
end

local function adjust_static_live_stats(stats, batch, direction)
    local vertex_bytes = tonumber(batch.vertex_bytes) or 0
    local index_bytes = tonumber(batch.index_bytes) or 0
    local total_bytes = vertex_bytes + index_bytes
    stats.live_static_batches = math.max(0,
        stats.live_static_batches + direction)
    stats.live_static_vertex_bytes = math.max(0,
        stats.live_static_vertex_bytes + direction * vertex_bytes)
    stats.live_static_index_bytes = math.max(0,
        stats.live_static_index_bytes + direction * index_bytes)
    stats.live_static_bytes = math.max(0,
        stats.live_static_bytes + direction * total_bytes)
    if batch.textured then
        stats.live_textured_batches = math.max(0,
            stats.live_textured_batches + direction)
        stats.live_textured_vertex_bytes = math.max(0,
            stats.live_textured_vertex_bytes + direction * vertex_bytes)
        stats.live_textured_index_bytes = math.max(0,
            stats.live_textured_index_bytes + direction * index_bytes)
        stats.live_textured_bytes = math.max(0,
            stats.live_textured_bytes + direction * total_bytes)
    end
    if batch.adopted then
        stats.live_adopted_static_batches = math.max(0,
            stats.live_adopted_static_batches + direction)
    end
end

local function note_static_upload(stats, textured, vertex_bytes, index_bytes, operation)
    vertex_bytes = math.max(0, tonumber(vertex_bytes) or 0)
    index_bytes = math.max(0, tonumber(index_bytes) or 0)
    local total_bytes = vertex_bytes + index_bytes
    if total_bytes <= 0 then
        return
    end
    stats.static_uploads = stats.static_uploads + 1
    stats.uploaded_static_vertex_bytes =
        stats.uploaded_static_vertex_bytes + vertex_bytes
    stats.uploaded_static_index_bytes =
        stats.uploaded_static_index_bytes + index_bytes
    stats.uploaded_static_bytes = stats.uploaded_static_bytes + total_bytes
    if textured then
        stats.uploaded_textured_vertex_bytes =
            stats.uploaded_textured_vertex_bytes + vertex_bytes
        stats.uploaded_textured_index_bytes =
            stats.uploaded_textured_index_bytes + index_bytes
        stats.uploaded_textured_bytes =
            stats.uploaded_textured_bytes + total_bytes
    end
    if operation == "update" then
        stats.updated_static_vertex_bytes =
            stats.updated_static_vertex_bytes + vertex_bytes
        stats.updated_static_index_bytes =
            stats.updated_static_index_bytes + index_bytes
        stats.updated_static_bytes =
            stats.updated_static_bytes + total_bytes
    elseif operation == "replacement" then
        stats.replacement_static_vertex_bytes =
            stats.replacement_static_vertex_bytes + vertex_bytes
        stats.replacement_static_index_bytes =
            stats.replacement_static_index_bytes + index_bytes
        stats.replacement_static_bytes =
            stats.replacement_static_bytes + total_bytes
    end
end

local function note_static_fallback(stats, textured, vertex_bytes, index_bytes, reason)
    vertex_bytes = math.max(0, tonumber(vertex_bytes) or 0)
    index_bytes = math.max(0, tonumber(index_bytes) or 0)
    local total_bytes = vertex_bytes + index_bytes
    stats.static_fallback_count = stats.static_fallback_count + 1
    stats.fallback_static_vertex_bytes =
        stats.fallback_static_vertex_bytes + vertex_bytes
    stats.fallback_static_index_bytes =
        stats.fallback_static_index_bytes + index_bytes
    stats.fallback_static_bytes =
        stats.fallback_static_bytes + total_bytes
    if textured then
        stats.textured_fallback_count = stats.textured_fallback_count + 1
        stats.fallback_textured_vertex_bytes =
            stats.fallback_textured_vertex_bytes + vertex_bytes
        stats.fallback_textured_index_bytes =
            stats.fallback_textured_index_bytes + index_bytes
        stats.fallback_textured_bytes =
            stats.fallback_textured_bytes + total_bytes
    end
    reason = tostring(reason or "unspecified")
    stats.static_fallback_reasons[reason] =
        (stats.static_fallback_reasons[reason] or 0) + 1
end

local function build_static_resource(backend, spec)
    local owner
    local ok, create_error = pcall(function()
        owner = backend.menori.Mesh({
            vertexformat = spec.base_vertex_format,
            vertices = spec.base_vertices,
            vertex_data = spec.vertex_data,
            vertex_count = spec.vertex_count,
            vertex_capacity = spec.vertex_capacity,
            indices = spec.indices,
            indices_tsize = spec.indices_tsize,
            mode = spec.mode,
            usage = spec.usage,
            lg_mesh = spec.supplied_draw_mesh,
            bound = spec.bound,
            skip_bound_calculation = spec.skip_bound_calculation,
        })
        if spec.texture ~= nil then
            owner.lg_mesh:setTexture(spec.texture)
        end
    end)
    if not ok or not owner or not owner.lg_mesh then
        -- Ownership of an adopted raw mesh transfers only after the complete
        -- wrapper succeeds. a newly-created Menori mesh can be retired here
        if owner and owner.lg_mesh and not spec.supplied_draw_mesh then
            safe_release(owner.lg_mesh)
        end
        error(create_error or "Menori static mesh construction returned no mesh", 0)
    end

    local vertex_bytes, index_bytes = static_resource_metrics(spec)
    local vertex_upload_bytes = spec.supplied_draw_mesh and 0
        or spec.vertex_payload_bytes
    local index_upload_bytes = spec.indices and index_bytes or 0
    return {
        base_mesh = owner,
        raw_draw_mesh = spec.supplied_draw_mesh,
        resource_mesh = owner.lg_mesh,
        draw_mesh = spec.vertex_count > 0 and owner.lg_mesh or nil,
        draw_count = spec.vertex_count,
        drawable = spec.vertex_count > 0,
        owns_draw_mesh = spec.owns_draw_mesh,
        adopted = spec.supplied_draw_mesh ~= nil,
        vertex_count = spec.vertex_count,
        vertex_capacity = spec.vertex_capacity,
        vertex_stride_bytes = spec.vertex_stride_bytes,
        vertex_format = spec.base_vertex_format,
        vertex_format_signature = spec.vertex_format_signature,
        source_vertex_count = spec.source_vertex_count,
        index_count = spec.index_count,
        indices_tsize = spec.indices_tsize,
        indexed = spec.index_count > 0,
        usage = spec.usage,
        mode = spec.mode,
        kind = spec.kind,
        opaque = spec.opaque,
        textured = spec.textured,
        texture = spec.texture,
        bound = spec.bound,
        fallback = spec.fallback,
        fallback_reason = spec.fallback_reason,
        vertex_bytes = vertex_bytes,
        index_bytes = index_bytes,
        uploaded_vertex_bytes = vertex_upload_bytes,
        uploaded_vertex_count = spec.vertex_stride_bytes > 0
            and vertex_upload_bytes / spec.vertex_stride_bytes or 0,
        uploaded_index_bytes = index_upload_bytes,
    }
end

local STATIC_DESCRIPTOR_FIELDS = {
    "base_mesh",
    "raw_draw_mesh",
    "resource_mesh",
    "draw_mesh",
    "draw_count",
    "drawable",
    "owns_draw_mesh",
    "adopted",
    "vertex_count",
    "vertex_capacity",
    "vertex_stride_bytes",
    "vertex_format",
    "vertex_format_signature",
    "source_vertex_count",
    "index_count",
    "indices_tsize",
    "indexed",
    "usage",
    "mode",
    "kind",
    "opaque",
    "textured",
    "texture",
    "bound",
    "fallback",
    "fallback_reason",
    "vertex_bytes",
    "index_bytes",
}

local function apply_static_descriptor(batch, descriptor)
    for index = 1, #STATIC_DESCRIPTOR_FIELDS do
        local field = STATIC_DESCRIPTOR_FIELDS[index]
        batch[field] = descriptor[field]
    end
    batch.count = descriptor.vertex_count
end

-- creates a non-instanced Menori Mesh owner while retaining a raw draw_mesh
-- alias. a supplied LOVE Mesh is adopted without reading its vertices, packed
-- Data is uploaded through Menori Mesh with an explicit count/capacity
function Backend:create_static_batch(vertex_format_or_spec, vertices, options)
    local ok, result = pcall(function()
        local spec = normalize_static_create_spec(
            vertex_format_or_spec, vertices, options)
        local descriptor = build_static_resource(self, spec)
        local batch = setmetatable({
            backend = self,
            backend_id = IDENTITY.id,
            static_mesh = true,
            released = false,
            instance_count = 0,
            instance_capacity = 0,
            instance_mesh = nil,
            instances = nil,
        }, Batch)
        apply_static_descriptor(batch, descriptor)

        self._batches[batch] = true
        local stats = self.stats
        stats.created_batches = stats.created_batches + 1
        stats.created_static_batches = stats.created_static_batches + 1
        stats.live_batches = stats.live_batches + 1
        stats.live_base_vertices = stats.live_base_vertices + batch.vertex_count
        stats.live_base_indices = stats.live_base_indices + batch.index_count
        if batch.indexed then
            stats.created_indexed_batches = stats.created_indexed_batches + 1
            stats.live_indexed_batches = stats.live_indexed_batches + 1
        end
        if batch.textured then
            stats.created_textured_batches = stats.created_textured_batches + 1
        end
        if batch.adopted then
            stats.adopted_static_batches = stats.adopted_static_batches + 1
        end
        adjust_static_live_stats(stats, batch, 1)
        note_static_upload(stats, batch.textured,
            descriptor.uploaded_vertex_bytes,
            descriptor.uploaded_index_bytes,
            "create")
        if descriptor.uploaded_vertex_bytes > 0 then
            stats.uploaded_base_vertices =
                stats.uploaded_base_vertices
                    + descriptor.uploaded_vertex_count
        end
        if descriptor.uploaded_index_bytes > 0 then
            stats.uploaded_base_indices =
                stats.uploaded_base_indices + batch.index_count
        end
        if batch.fallback then
            note_static_fallback(stats, batch.textured,
                batch.vertex_bytes, batch.index_bytes,
                batch.fallback_reason)
        end
        update_peaks(stats)
        return batch
    end)
    if not ok then
        self.stats.static_create_errors = self.stats.static_create_errors + 1
        error(result, 0)
    end
    return result
end

-- Records a caller-selected raw fallback. this method performs no allocation or
-- upload, so fallback bytes never contaminate uploaded_static_* counters
function Backend:note_static_fallback(vertex_format_or_spec, vertices, options, reason)
    if type(vertices) == "string" and options == nil and reason == nil
        and looks_like_static_spec(vertex_format_or_spec) then
        reason = vertices
        vertices = nil
    end
    if type(options) == "string" and reason == nil then
        reason = options
        options = nil
    end
    local spec = normalize_static_create_spec(
        vertex_format_or_spec, vertices, options)
    local vertex_bytes, index_bytes = static_resource_metrics(spec)
    note_static_fallback(self.stats, spec.textured,
        vertex_bytes, index_bytes, reason or spec.fallback_reason)
    return vertex_bytes + index_bytes
end

local function complete_static_replacement_spec(batch, value, count_or_options)
    local spec
    if looks_like_static_spec(value) then
        spec = copy_table(value)
    else
        spec = type(count_or_options) == "table"
            and copy_table(count_or_options) or {}
        spec.base_vertices = value
        if type(count_or_options) == "number" then
            spec.vertex_count = count_or_options
        end
    end
    spec.base_vertex_format = spec.base_vertex_format
        or spec.vertex_format
        or spec.vertexformat
        or batch.vertex_format
    spec.vertex_stride_bytes = spec.vertex_stride_bytes
        or batch.vertex_stride_bytes
    spec.usage = spec.usage or batch.usage
    spec.mode = spec.mode or batch.mode
    spec.kind = spec.kind or batch.kind
    if spec.opaque == nil then
        spec.opaque = batch.opaque
    end
    if spec.textured == nil and spec.category == nil
        and spec.resource_category == nil then
        spec.textured = batch.textured
    end
    if spec.texture == nil then
        spec.texture = batch.texture
    end
    if spec.bound == nil and spec.bounds == nil then
        spec.bound = batch.bound
    end
    if spec.fallback == nil and spec.fallback_reason == nil then
        spec.fallback = batch.fallback
        spec.fallback_reason = batch.fallback_reason
    end
    if spec.indices == nil and batch.indexed
        and spec.clear_indices ~= true then
        local resource_mesh = batch.resource_mesh or batch.draw_mesh
        local ok, indices = pcall(
            resource_mesh.getVertexMap, resource_mesh)
        assert(ok and type(indices) == "table" and #indices > 0,
            "indexed static replacement requires the existing or replacement index map")
        spec.indices = indices
        spec.indices_tsize = batch.indices_tsize
    end
    return spec
end

function Backend:replace_static_batch(batch, spec)
    self:_assert_owned_static_batch(batch)
    assert(not batch.released, "cannot replace a released static mesh batch")
    local pending_descriptor
    local ok, result = pcall(function()
        local complete = complete_static_replacement_spec(batch, spec)
        local normalized = normalize_static_create_spec(complete)
        pending_descriptor = build_static_resource(self, normalized)
        local descriptor = pending_descriptor
        local old_resource_mesh = batch.resource_mesh or batch.draw_mesh
        local old_owns_draw_mesh = batch.owns_draw_mesh
        local old_vertex_count = batch.vertex_count or 0
        local old_index_count = batch.index_count or 0
        local old_indexed = batch.indexed == true

        local stats = self.stats
        adjust_static_live_stats(stats, batch, -1)
        stats.live_base_vertices = math.max(0,
            stats.live_base_vertices - old_vertex_count)
        stats.live_base_indices = math.max(0,
            stats.live_base_indices - old_index_count)
        if old_indexed then
            stats.live_indexed_batches = math.max(0,
                stats.live_indexed_batches - 1)
        end

        apply_static_descriptor(batch, descriptor)
        adjust_static_live_stats(stats, batch, 1)
        stats.live_base_vertices = stats.live_base_vertices + batch.vertex_count
        stats.live_base_indices = stats.live_base_indices + batch.index_count
        if batch.indexed then
            stats.live_indexed_batches = stats.live_indexed_batches + 1
            stats.created_indexed_batches = stats.created_indexed_batches + 1
        end
        if batch.adopted then
            stats.adopted_static_batches = stats.adopted_static_batches + 1
        end
        stats.static_replacements = stats.static_replacements + 1
        note_static_upload(stats, batch.textured,
            descriptor.uploaded_vertex_bytes,
            descriptor.uploaded_index_bytes,
            "replacement")
        if descriptor.uploaded_vertex_bytes > 0 then
            stats.uploaded_base_vertices =
                stats.uploaded_base_vertices
                    + descriptor.uploaded_vertex_count
        end
        if descriptor.uploaded_index_bytes > 0 then
            stats.uploaded_base_indices =
                stats.uploaded_base_indices + batch.index_count
        end
        if batch.fallback then
            note_static_fallback(stats, batch.textured,
                batch.vertex_bytes, batch.index_bytes,
                batch.fallback_reason)
        end
        update_peaks(stats)

        if old_resource_mesh ~= batch.resource_mesh
            and old_owns_draw_mesh ~= false
        then
            if not safe_release(old_resource_mesh) then
                stats.release_errors = stats.release_errors + 1
            end
        end
        return batch
    end)
    if not ok then
        local pending_resource = pending_descriptor
            and (pending_descriptor.resource_mesh
                or pending_descriptor.draw_mesh)
        if pending_resource ~= nil
            and pending_resource ~= batch.resource_mesh
            and pending_descriptor.owns_draw_mesh ~= false
            and not safe_release(pending_resource)
        then
            self.stats.release_errors = self.stats.release_errors + 1
        end
        self.stats.static_replacement_errors =
            self.stats.static_replacement_errors + 1
        error(result, 0)
    end
    return result
end

function Backend:update_static_batch(batch, value, count_or_options)
    self:_assert_owned_static_batch(batch)
    assert(not batch.released, "cannot update a released static mesh batch")

    local raw_spec
    if looks_like_static_spec(value) then
        raw_spec = copy_table(value)
    else
        raw_spec = type(count_or_options) == "table"
            and copy_table(count_or_options) or {}
        raw_spec.base_vertices = value
        if type(count_or_options) == "number" then
            raw_spec.vertex_count = count_or_options
        end
    end

    local supplied_draw_mesh = raw_spec.draw_mesh or raw_spec.raw_mesh
    local vertex_format = raw_spec.base_vertex_format
        or raw_spec.vertex_format
        or raw_spec.vertexformat
        or batch.vertex_format
    local format_signature = vertex_format_signature(vertex_format)
    local base_vertices = raw_spec.base_vertices or raw_spec.vertices
    local vertex_data = raw_spec.vertex_data
    if vertex_data == nil and base_vertices ~= nil
        and type(base_vertices) ~= "table" then
        vertex_data = base_vertices
        base_vertices = nil
    end
    local vertex_count = tonumber(raw_spec.vertex_count or raw_spec.count)
    if vertex_count == nil and type(base_vertices) == "table" then
        vertex_count = #base_vertices
    end
    vertex_count = vertex_count or batch.vertex_count
    local usage = normalize_usage(raw_spec.usage or batch.usage)
    local mode = raw_spec.mode or batch.mode
    assert(vertex_count >= 0 and vertex_count == math.floor(vertex_count),
        "vertex_count must be a non-negative integer")
    local requested_capacity = raw_spec.vertex_capacity ~= nil
        and tonumber(raw_spec.vertex_capacity) or nil
    local structural_change = raw_spec.force_replace == true
        or supplied_draw_mesh ~= nil
        or vertex_count > batch.vertex_capacity
        or (batch.indexed and vertex_count ~= batch.vertex_count)
        or (requested_capacity ~= nil
            and requested_capacity ~= batch.vertex_capacity)
        or usage ~= batch.usage
        or mode ~= batch.mode
        or format_signature ~= batch.vertex_format_signature
        or raw_spec.indices ~= nil
        or raw_spec.clear_indices == true

    local explicit_stride
    if raw_spec.vertex_stride_bytes ~= nil then
        explicit_stride = vertex_stride_bytes(
            vertex_format, raw_spec.vertex_stride_bytes)
    end
    if not structural_change and explicit_stride ~= nil then
        assert(explicit_stride == batch.vertex_stride_bytes,
            "nonstructural static update cannot change vertex_stride_bytes")
    end

    if structural_change then
        local complete = complete_static_replacement_spec(
            batch, raw_spec, count_or_options)
        if raw_spec.clear_indices == true then
            complete.indices = nil
            complete.index_count = 0
            complete.indices_tsize = nil
        end
        return self:replace_static_batch(batch, complete)
    end

    local source = vertex_data or base_vertices
    local stride = vertex_stride_bytes(vertex_format,
        explicit_stride or batch.vertex_stride_bytes)
    local data_size = get_data_size(vertex_data)
    local uploaded_vertex_bytes = 0
    if data_size ~= nil then
        assert(data_size % stride == 0,
            "vertex_data size must be a multiple of vertex_stride_bytes")
        assert(data_size >= vertex_count * stride,
            "vertex_data is shorter than vertex_count * vertex_stride_bytes")
        assert(data_size <= batch.vertex_capacity * stride,
            "vertex_data is larger than vertex_capacity * vertex_stride_bytes")
        uploaded_vertex_bytes = data_size
    elseif type(base_vertices) == "table" then
        assert(#base_vertices >= vertex_count,
            "base vertex table is shorter than vertex_count")
        assert(#base_vertices <= batch.vertex_capacity,
            "base vertex table is longer than vertex_capacity")
        uploaded_vertex_bytes = #base_vertices * stride
    end
    local previous_vertex_count = batch.vertex_count
    local texture_changed = raw_spec.texture ~= nil
        and raw_spec.texture ~= batch.texture
    local bound_changed = raw_spec.bound ~= nil
        or raw_spec.bounds ~= nil
    local resource_mesh = batch.resource_mesh or batch.draw_mesh
    assert(resource_mesh ~= nil, "static mesh resource is unavailable")
    local ok, update_error = pcall(function()
        if source ~= nil then
            resource_mesh:setVertices(source)
        end
        if vertex_count ~= previous_vertex_count and vertex_count > 0 then
            resource_mesh:setDrawRange(1, vertex_count)
        end
        if texture_changed then
            resource_mesh:setTexture(raw_spec.texture)
        end
    end)
    if not ok then
        self.stats.static_update_errors = self.stats.static_update_errors + 1
        error(update_error, 0)
    end

    if raw_spec.texture ~= nil then
        batch.texture = raw_spec.texture
    end
    if raw_spec.bound ~= nil or raw_spec.bounds ~= nil then
        batch.bound = raw_spec.bound or raw_spec.bounds
        if batch.base_mesh then
            batch.base_mesh.bound = batch.bound
        end
    end
    if vertex_count ~= previous_vertex_count then
        self.stats.live_base_vertices = math.max(0,
            self.stats.live_base_vertices
                + vertex_count - previous_vertex_count)
        batch.vertex_count = vertex_count
        batch.source_vertex_count = vertex_count
        batch.count = vertex_count
        if batch.base_mesh then
            batch.base_mesh.vertex_count = vertex_count
        end
    end
    batch.draw_count = vertex_count
    batch.drawable = vertex_count > 0
    batch.draw_mesh = batch.drawable and resource_mesh or nil
    if source ~= nil or vertex_count ~= previous_vertex_count
        or texture_changed or bound_changed then
        self.stats.static_updates = self.stats.static_updates + 1
    end
    if source ~= nil then
        local stats = self.stats
        stats.uploaded_base_vertices =
            stats.uploaded_base_vertices
                + uploaded_vertex_bytes / stride
        note_static_upload(stats, batch.textured,
            uploaded_vertex_bytes, 0, "update")
    end
    return batch
end

-- accepts either a specification table or positional arguments:
--
--   create_opaque_batch({
--       base_vertex_format = format,
--       base_vertices = vertices,
--       instance_format = instance_format,
--       instance_rows = rows,
--   })
--
--   create_opaque_batch(format, vertices, instance_format, rows, options)
function Backend:create_opaque_batch(vertex_format_or_spec, vertices, instance_format, rows, options)
    local spec = normalize_create_spec(
        vertex_format_or_spec, vertices, instance_format, rows, options)

    local base_vertex_format = spec.base_vertex_format
        or spec.vertex_format
        or spec.vertexformat
    local base_vertices = spec.base_vertices or spec.vertices
    local instanced_format = spec.instance_format or spec.instanced_format
    local instance_rows = spec.instance_rows or spec.rows or spec.instances or {}
    local supplied_draw_mesh = spec.draw_mesh or spec.raw_mesh
    local indices = spec.indices
    local indices_tsize = tonumber(spec.indices_tsize)

    if supplied_draw_mesh == nil then
        assert_array(base_vertex_format, "base vertex format", false)
        assert_array(base_vertices, "base vertices", false)
        if indices ~= nil then
            assert_array(indices, "base vertex indices", false)
            if indices_tsize ~= nil then
                assert(indices_tsize == 2 or indices_tsize == 4,
                    "index data type size must be 2 or 4 bytes")
            end
        end
    else
        assert(type(supplied_draw_mesh) == "userdata"
                and type(supplied_draw_mesh.getVertexCount) == "function",
            "draw_mesh must be a LOVE Mesh")
    end
    assert_array(instanced_format, "instance format", false)
    instance_rows, spec.instance_count = normalize_instance_count(
        instance_rows, spec.instance_count or spec.count)

    local initial_capacity = spec.initial_capacity or spec.instance_capacity
        or math.max(1, spec.instance_count)
    initial_capacity = tonumber(initial_capacity)
    assert(initial_capacity ~= nil
        and initial_capacity >= 0
        and initial_capacity == math.floor(initial_capacity),
        "initial capacity must be a non-negative integer")

    local base_mesh
    local raw_draw_mesh
    local instances
    local ok, create_error = pcall(function()
        if supplied_draw_mesh then
            raw_draw_mesh = supplied_draw_mesh
            instances = self.menori.InstancedMesh(
                raw_draw_mesh, instanced_format, math.max(1, initial_capacity))
        else
            base_mesh = self.menori.Mesh({
                vertexformat = base_vertex_format,
                vertices = base_vertices,
                mode = spec.mode or "triangles",
                indices = indices,
                indices_tsize = indices_tsize,
                material_index = spec.material_index,
                count = spec.vertex_count,
            })
            instances = self.menori.InstancedMesh(
                base_mesh, instanced_format, math.max(1, initial_capacity))
        end
        instances:set_instances(instance_rows, spec.instance_count)
    end)

    if not ok then
        if instances then
            safe_release(instances)
        end
        if base_mesh and base_mesh.lg_mesh then
            safe_release(base_mesh.lg_mesh)
        elseif raw_draw_mesh and spec.owns_draw_mesh ~= false then
            safe_release(raw_draw_mesh)
        end
        error(create_error, 0)
    end

    local base_vertex_count = tonumber(spec.vertex_count)
    if not base_vertex_count then
        if supplied_draw_mesh then
            base_vertex_count = supplied_draw_mesh:getVertexCount()
        else
            base_vertex_count = #base_vertices
        end
    end
    local index_count = indices and #indices or 0
    local source_vertex_count = tonumber(spec.source_vertex_count)
        or (index_count > 0 and index_count or base_vertex_count)
    local batch = setmetatable({
        backend = self,
        backend_id = IDENTITY.id,
        kind = spec.kind or "opaque_instanced",
        opaque = spec.opaque ~= false,
        released = false,
        base_mesh = base_mesh,
        raw_draw_mesh = raw_draw_mesh,
        owns_draw_mesh = supplied_draw_mesh == nil or spec.owns_draw_mesh ~= false,
        instances = instances,
        instance_count = spec.instance_count,
        count = spec.instance_count,
        vertex_count = base_vertex_count,
        source_vertex_count = source_vertex_count,
        index_count = index_count,
        indices_tsize = index_count > 0 and (indices_tsize or 4) or nil,
        indexed = index_count > 0,
    }, Batch)
    refresh_batch_handles(batch)

    self._batches[batch] = true
    local stats = self.stats
    stats.created_batches = stats.created_batches + 1
    stats.live_batches = stats.live_batches + 1
    stats.live_base_vertices = stats.live_base_vertices + batch.vertex_count
    stats.live_base_indices = stats.live_base_indices + batch.index_count
    stats.uploaded_base_vertices =
        stats.uploaded_base_vertices + batch.vertex_count
    stats.uploaded_base_indices =
        stats.uploaded_base_indices + batch.index_count
    if batch.indexed then
        stats.created_indexed_batches = stats.created_indexed_batches + 1
        stats.live_indexed_batches = stats.live_indexed_batches + 1
    end
    stats.live_instances = stats.live_instances + batch.instance_count
    stats.instance_uploads = stats.instance_uploads + 1
    stats.uploaded_instance_rows = stats.uploaded_instance_rows + batch.instance_count
    update_peaks(stats)

    return batch
end

function Backend:update_opaque_batch(batch, rows, count)
    self:_assert_owned_batch(batch)
    assert(not batch.released, "cannot update a released opaque batch")
    rows, count = normalize_instance_count(rows, count)

    local previous_count = batch.instance_count
    local previous_buffer = batch.instance_mesh
    local previous_capacity = batch.instance_capacity
    local ok, update_error = pcall(batch.instances.set_instances, batch.instances, rows, count)

    -- set_instances may grow the Menori buffer before a LOVE upload error. keep
    -- the legacy alias truthful even when propagating that error
    refresh_batch_handles(batch)
    if not ok then
        error(update_error, 0)
    end

    batch.instance_count = count
    batch.count = count

    local stats = self.stats
    stats.live_instances = stats.live_instances + count - previous_count
    stats.instance_uploads = stats.instance_uploads + 1
    stats.uploaded_instance_rows = stats.uploaded_instance_rows + count
    if batch.instance_mesh ~= previous_buffer
        or batch.instance_capacity ~= previous_capacity
    then
        stats.buffer_reallocations = stats.buffer_reallocations + 1
    end
    update_peaks(stats)
    return batch
end

function Backend:refresh_batch_handles(batch)
    self:_assert_owned_batch(batch)
    if batch.released then
        return false
    end
    refresh_batch_handles(batch)
    return true
end

function Backend:release_batch(batch)
    self:_assert_owned_batch(batch)
    if batch.released then
        return false
    end
    if batch.static_mesh then
        batch.released = true
        self._batches[batch] = nil
        local draw_mesh = batch.resource_mesh or batch.draw_mesh
        local draw_ok = true
        if batch.owns_draw_mesh ~= false then
            draw_ok = safe_release(draw_mesh)
        end

        local stats = self.stats
        if not draw_ok then
            stats.release_errors = stats.release_errors + 1
        end
        stats.released_batches = stats.released_batches + 1
        stats.released_static_batches = stats.released_static_batches + 1
        stats.live_batches = math.max(0, stats.live_batches - 1)
        stats.live_base_vertices = math.max(0,
            stats.live_base_vertices - (batch.vertex_count or 0))
        stats.live_base_indices = math.max(0,
            stats.live_base_indices - (batch.index_count or 0))
        if batch.indexed then
            stats.live_indexed_batches = math.max(0,
                stats.live_indexed_batches - 1)
        end
        if batch.textured then
            stats.released_textured_batches =
                stats.released_textured_batches + 1
        end
        adjust_static_live_stats(stats, batch, -1)

        batch.base_mesh = nil
        batch.raw_draw_mesh = nil
        batch.resource_mesh = nil
        batch.draw_mesh = nil
        batch.vertex_format = nil
        batch.vertex_format_signature = nil
        batch.texture = nil
        batch.bound = nil
        batch.vertex_count = 0
        batch.vertex_capacity = 0
        batch.source_vertex_count = 0
        batch.index_count = 0
        batch.indices_tsize = nil
        batch.indexed = false
        batch.vertex_bytes = 0
        batch.index_bytes = 0
        batch.count = 0
        batch.draw_count = 0
        batch.drawable = false
        return true
    end

    -- mark first so cleanup remains idempotent even if a driver rejects one of
    -- the release operations
    batch.released = true
    self._batches[batch] = nil

    local instances = batch.instances
    local raw_instance_mesh = batch.instance_mesh
    local raw_draw_mesh = batch.draw_mesh
    local instances_ok = safe_release(instances)
    if not instances_ok then
        -- Menori normally owns this release. this fallback prevents a leaked
        -- buffer if detaching an attribute failed first
        safe_release(raw_instance_mesh)
    end
    local draw_ok = true
    if batch.owns_draw_mesh ~= false then
        draw_ok = safe_release(raw_draw_mesh)
    end

    local stats = self.stats
    if not instances_ok then
        stats.release_errors = stats.release_errors + 1
    end
    if not draw_ok then
        stats.release_errors = stats.release_errors + 1
    end
    stats.released_batches = stats.released_batches + 1
    stats.live_batches = math.max(0, stats.live_batches - 1)
    stats.live_base_vertices = math.max(0,
        stats.live_base_vertices - (batch.vertex_count or 0))
    stats.live_base_indices = math.max(0,
        stats.live_base_indices - (batch.index_count or 0))
    if batch.indexed then
        stats.live_indexed_batches = math.max(
            0, stats.live_indexed_batches - 1)
    end
    stats.live_instances = math.max(0,
        stats.live_instances - (batch.instance_count or 0))

    batch.base_mesh = nil
    batch.raw_draw_mesh = nil
    batch.instances = nil
    batch.draw_mesh = nil
    batch.instance_mesh = nil
    batch.instance_capacity = 0
    batch.instance_count = 0
    batch.count = 0
    return true
end

-- Releases the current map's resources while leaving this backend reusable for
-- the next map loaded by the same renderer
function Backend:release()
    local owned = {}
    for batch in pairs(self._batches) do
        owned[#owned + 1] = batch
    end
    for index = 1, #owned do
        self:release_batch(owned[index])
    end
    self.generation = (self.generation or 0) + 1
    return #owned
end

Backend.reset = Backend.release
Backend.create_instanced_batch = Backend.create_opaque_batch
Backend.update_instanced_batch = Backend.update_opaque_batch
Backend.create_opaque_instanced_batch = Backend.create_opaque_batch
Backend.update_opaque_instanced_batch = Backend.update_opaque_batch
Backend.create_static_mesh_batch = Backend.create_static_batch
Backend.update_static_mesh_batch = Backend.update_static_batch
Backend.replace_static_mesh_batch = Backend.replace_static_batch

return setmetatable(Backend, {
    __call = function(_, options)
        return Backend.new(options)
    end,
})
