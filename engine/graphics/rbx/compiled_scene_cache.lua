-- store static scene plans as plain tables and typed byte streams
-- GPU objects belong to the renderer and stay out of the cache
-- loaded part IDs tie saved bounds and contact shading back to the right parts

local ffi_ok, ffi = pcall(require, "ffi")

local Cache = {}

Cache.MAGIC = "LGSC"
Cache.FORMAT_VERSION = 1
Cache.PAYLOAD_SCHEMA = "rbx-opaque-static-cpu-plan"
Cache.PAYLOAD_SCHEMA_VERSION = 2
Cache.CONTEXT_SCHEMA = "rbx-compiled-scene-context"
Cache.CONTEXT_SCHEMA_VERSION = 1
Cache.STREAM_SCHEMA_VERSION = 1
Cache.CACHE_DIR = "compiled_scene_cache"

local HEADER_BYTES = 88
local FLAGS_NONE = 0
local SHA256_BYTES = 32
local MAX_SAFE_INTEGER = 9007199254740991

Cache.HEADER_BYTES = HEADER_BYTES

-- include each of these values in the cache key so changes invalidate stale geometry
Cache.REQUIRED_VERSION_DIMENSIONS = {
    "coordinate_schema",
    "mirroring_schema",
    "primitive_geometry_schema",
    "mesh_decoder_schema",
    "exact_index_schema",
    "spatial_page_schema",
    "mega_layout_schema",
    "shadow_caster_schema",
    "material_registry_schema",
    "material_variant_schema",
    "surface_appearance_schema",
    "alpha_semantics_schema",
    "shader_format_schema",
    "static_vertex_format_schema",
    "textured_vertex_format_schema",
    "instance_vertex_format_schema",
    "contact_ao_format",
}

-- Option values are separate from algorithm/schema revisions above.  they cover
-- the switches that alter classification, baked values, chunk ownership, or the
-- GPU recipe selected from the cached CPU plan
Cache.REQUIRED_OPTION_FIELDS = {
    "coordinate_mode",
    "flip_loaded_map_horizontally",
    "accurate_face_axes",
    "accurate_mesh_normals",
    "independent_decal_transparency",
    "parse_invisible_parts",
    "physics_anchor_loaded_parts",
    "surface_detail_geometry_enabled",
    "sky_occlusion_bake",
    "material_studs_per_tile",
    "visibility_cell_size",
    "enable_occlusion_culling",
    "use_instancing",
    "mesh_instancing",
    "retain_mesh_transforms",
    "enable_repeated_mesh_indexing",
    "enable_static_textured_indexing",
    "enable_static_textured_spatial_pages",
    "force_static_textured_spatial_pages",
    "static_textured_spatial_page_max_batches",
    "static_textured_spatial_page_max_draw_amplification",
    "adaptive_mega_batch",
    "shadow_caster_mode",
    "disable_material_maps",
    "disable_normal_maps",
    "constant_fragment_shader",
    "textured_shader_quality",
    "render_backend_name",
    "incremental_static_release",
    "static_shape_depth_bias",
    "material_depth_bias",
    "mesh_depth_bias",
    "decal_depth_bias",
    "decal_surface_offset",
    "surface_detail_depth_bias",
}

local HARD_LIMITS = {
    max_file_bytes = 1024 * 1024 * 1024,
    max_context_bytes = 32 * 1024 * 1024,
    max_payload_bytes = 1024 * 1024 * 1024,
    max_nodes = 8000000,
    max_entries = 16000000,
    max_depth = 64,
    max_array_length = 1000000,
    max_map_entries = 262144,
    max_string_bytes = 1024 * 1024 * 1024,
    max_total_string_bytes = 1024 * 1024 * 1024,
    max_stream_bytes = 1024 * 1024 * 1024,
    max_total_stream_bytes = 1024 * 1024 * 1024,
    max_parts = 500000,
    max_chunks = 250000,
    max_primitive_batches = 500000,
    max_textured_batches = 500000,
    max_instanced_groups = 250000,
    max_dependencies = 250000,
    max_vertices_per_stream = 33554432,
    max_indices_per_stream = 100663296,
    max_asset_bindings_per_batch = 64,
    max_part_ranges_per_batch = 500000,
    max_occluders = 500000,
}

local DEFAULT_LIMITS = {
    max_file_bytes = 512 * 1024 * 1024,
    max_context_bytes = 8 * 1024 * 1024,
    max_payload_bytes = 504 * 1024 * 1024,
    max_nodes = 2000000,
    max_entries = 4000000,
    max_depth = 32,
    max_array_length = 500000,
    max_map_entries = 65536,
    max_string_bytes = 384 * 1024 * 1024,
    max_total_string_bytes = 504 * 1024 * 1024,
    max_stream_bytes = 384 * 1024 * 1024,
    max_total_stream_bytes = 480 * 1024 * 1024,
    max_parts = 250000,
    max_chunks = 131072,
    max_primitive_batches = 262144,
    max_textured_batches = 262144,
    max_instanced_groups = 65536,
    max_dependencies = 131072,
    max_vertices_per_stream = 16777216,
    max_indices_per_stream = 50331648,
    max_asset_bindings_per_batch = 32,
    max_part_ranges_per_batch = 250000,
    max_occluders = 250000,
}

Cache.DEFAULT_LIMITS = DEFAULT_LIMITS
Cache.HARD_LIMITS = HARD_LIMITS

local ERROR_PREFIX = "compiled_scene_cache|"

local function abort(code, path, detail)
    local message = ERROR_PREFIX .. tostring(code)
    if path ~= nil and path ~= "" then
        message = message .. "|" .. tostring(path)
    end
    if detail ~= nil and detail ~= "" then
        message = message .. "|" .. tostring(detail)
    end
    error(message, 0)
end

local function public_error(value)
    local message = tostring(value or "unknown_error")
    local start = string.find(message, ERROR_PREFIX, 1, true)
    if start then
        return string.sub(message, start + #ERROR_PREFIX)
    end
    return "internal_error|" .. message
end

local function finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    return finite_number(value)
        and value == math.floor(value)
        and value >= (minimum or 0)
        and value <= (maximum or MAX_SAFE_INTEGER)
end

local function checked_product(left, right, maximum, code, path)
    if left == 0 or right == 0 then return 0 end
    if left > math.floor(maximum / right) then
        abort(code or "size_overflow", path)
    end
    return left * right
end

local function resolve_limits(overrides)
    overrides = type(overrides) == "table" and overrides or {}
    local result = {}
    for name, default_value in pairs(DEFAULT_LIMITS) do
        local value = overrides[name]
        if value == nil then value = default_value end
        local hard = HARD_LIMITS[name]
        if not integer(value, 0, hard) then
            abort("invalid_limit", name, tostring(value))
        end
        result[name] = value
    end
    if result.max_context_bytes > result.max_file_bytes
        or result.max_payload_bytes > result.max_file_bytes then
        abort("invalid_limit_relationship", "file_bytes")
    end
    if result.max_stream_bytes > result.max_payload_bytes
        or result.max_total_stream_bytes > result.max_payload_bytes then
        abort("invalid_limit_relationship", "stream_bytes")
    end
    return result
end

function Cache.resolve_limits(overrides)
    local ok, result = pcall(resolve_limits, overrides)
    if not ok then return nil, public_error(result) end
    return result
end

local function require_ffi()
    if not ffi_ok or type(ffi) ~= "table" then
        abort("ffi_unavailable")
    end
end

local endian_probe
local HOST_LITTLE_ENDIAN = false
if ffi_ok then
    endian_probe = ffi.new("uint16_t[1]", 0x0102)
    HOST_LITTLE_ENDIAN = ffi.cast("uint8_t*", endian_probe)[0] == 0x02
end

local function raw_sha256(data)
    if not (love and love.data and type(love.data.hash) == "function") then
        abort("sha256_unavailable")
    end
    local ok, digest = pcall(love.data.hash, "sha256", data)
    if not ok or digest == nil then
        abort("sha256_failed", nil, digest)
    end
    if type(digest) == "userdata" and type(digest.getString) == "function" then
        local string_ok, value = pcall(digest.getString, digest)
        if not string_ok then abort("sha256_failed", nil, value) end
        digest = value
    end
    if type(digest) ~= "string" or #digest ~= SHA256_BYTES then
        abort("sha256_invalid_result", nil, type(digest) .. ":" .. tostring(#digest))
    end
    return digest
end

local HEX = {}
for value = 0, 255 do
    HEX[value] = string.format("%02x", value)
end

local function bytes_to_hex(data)
    local parts = {}
    for index = 1, #data do
        parts[index] = HEX[string.byte(data, index)]
    end
    return table.concat(parts)
end

local function fingerprint_bytes(data)
    return "sha256:" .. bytes_to_hex(raw_sha256(data))
end

local function pack_u32(value)
    if not integer(value, 0, 0xffffffff) then
        abort("u32_out_of_range", nil, tostring(value))
    end
    local b1 = value % 256
    value = math.floor(value / 256)
    local b2 = value % 256
    value = math.floor(value / 256)
    local b3 = value % 256
    value = math.floor(value / 256)
    local b4 = value % 256
    return string.char(b1, b2, b3, b4)
end

local function read_u32_at(data, position)
    if position < 1 or position + 3 > #data then
        abort("truncated_u32")
    end
    local b1, b2, b3, b4 = string.byte(data, position, position + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local scratch_double
local scratch_double_bytes
if ffi_ok then
    scratch_double = ffi.new("double[1]")
    scratch_double_bytes = ffi.cast("uint8_t*", scratch_double)
end

local function pack_double(value)
    require_ffi()
    if not finite_number(value) then abort("non_finite_number") end
    scratch_double[0] = value
    local bytes = ffi.string(scratch_double_bytes, 8)
    if HOST_LITTLE_ENDIAN then return bytes end
    return string.reverse(bytes)
end

local function unpack_double(data, position)
    require_ffi()
    if position < 1 or position + 7 > #data then
        abort("truncated_number")
    end
    if HOST_LITTLE_ENDIAN then
        ffi.copy(scratch_double_bytes, data:sub(position, position + 7), 8)
    else
        ffi.copy(scratch_double_bytes,
            string.reverse(data:sub(position, position + 7)), 8)
    end
    local value = tonumber(scratch_double[0])
    if not finite_number(value) then abort("non_finite_number") end
    return value
end

-- Deterministic tree codec.  it intentionally has no reference tags: a decoded
-- payload is value-owned, and cycles/shared runtime graphs cannot cross the seam
local TAG_FALSE = 1
local TAG_TRUE = 2
local TAG_NUMBER = 3
local TAG_STRING = 4
local TAG_ARRAY = 5
local TAG_MAP = 6

local function writer_new(max_bytes)
    require_ffi()
    local capacity = math.min(math.max(1024, math.min(max_bytes, 1024 * 1024)), max_bytes)
    if capacity <= 0 then abort("writer_byte_cap_exceeded") end
    return {
        buffer = ffi.new("uint8_t[?]", capacity),
        capacity = capacity,
        length = 0,
        maximum = max_bytes,
    }
end

local function writer_reserve(writer, extra)
    if not integer(extra, 0, writer.maximum)
        or writer.length > writer.maximum - extra then
        abort("writer_byte_cap_exceeded")
    end
    local needed = writer.length + extra
    if needed <= writer.capacity then return end
    local capacity = writer.capacity
    while capacity < needed do
        capacity = math.min(writer.maximum, math.max(capacity + 1, capacity * 2))
        if capacity < needed and capacity == writer.maximum then
            abort("writer_byte_cap_exceeded")
        end
    end
    local replacement = ffi.new("uint8_t[?]", capacity)
    ffi.copy(replacement, writer.buffer, writer.length)
    writer.buffer = replacement
    writer.capacity = capacity
end

local function writer_bytes(writer, value)
    local length = #value
    writer_reserve(writer, length)
    if length > 0 then
        ffi.copy(writer.buffer + writer.length, value, length)
    end
    writer.length = writer.length + length
end

local function writer_u8(writer, value)
    writer_reserve(writer, 1)
    writer.buffer[writer.length] = value
    writer.length = writer.length + 1
end

local function writer_u32(writer, value)
    writer_bytes(writer, pack_u32(value))
end

local function writer_string(writer)
    return ffi.string(writer.buffer, writer.length)
end

local function table_shape(value, limits, path)
    local count = 0
    local maximum = 0
    local numeric = true
    local strings = true
    for key in pairs(value) do
        count = count + 1
        if count > limits.max_entries then
            abort("entry_cap_exceeded", path)
        end
        if type(key) == "number" and integer(key, 1, limits.max_array_length) then
            if key > maximum then maximum = key end
            strings = false
        elseif type(key) == "string" then
            numeric = false
        else
            abort("invalid_table_key", path, type(key))
        end
    end
    if count == 0 then return "map", 0 end
    if numeric and not strings then
        if maximum ~= count then abort("sparse_array", path) end
        return "array", count
    end
    if strings and not numeric then
        if count > limits.max_map_entries then
            abort("map_entry_cap_exceeded", path)
        end
        return "map", count
    end
    abort("mixed_table_keys", path)
end

local function encode_tree(value, limits, maximum_bytes)
    local writer = writer_new(maximum_bytes)
    local state = {
        limits = limits,
        nodes = 0,
        entries = 0,
        string_bytes = 0,
        active = {},
    }

    local encode_value
    encode_value = function(item, depth, path)
        if depth > limits.max_depth then abort("depth_cap_exceeded", path) end
        state.nodes = state.nodes + 1
        if state.nodes > limits.max_nodes then abort("node_cap_exceeded", path) end
        local kind = type(item)
        if kind == "boolean" then
            writer_u8(writer, item and TAG_TRUE or TAG_FALSE)
        elseif kind == "number" then
            if not finite_number(item) then abort("non_finite_number", path) end
            writer_u8(writer, TAG_NUMBER)
            writer_bytes(writer, pack_double(item))
        elseif kind == "string" then
            if #item > limits.max_string_bytes then abort("string_cap_exceeded", path) end
            state.string_bytes = state.string_bytes + #item
            if state.string_bytes > limits.max_total_string_bytes then
                abort("total_string_cap_exceeded", path)
            end
            writer_u8(writer, TAG_STRING)
            writer_u32(writer, #item)
            writer_bytes(writer, item)
        elseif kind == "table" then
            if getmetatable(item) ~= nil then abort("metatable_rejected", path) end
            if state.active[item] then abort("cycle_rejected", path) end
            state.active[item] = true
            local shape, count = table_shape(item, limits, path)
            state.entries = state.entries + count
            if state.entries > limits.max_entries then abort("entry_cap_exceeded", path) end
            if shape == "array" then
                writer_u8(writer, TAG_ARRAY)
                writer_u32(writer, count)
                for index = 1, count do
                    encode_value(item[index], depth + 1,
                        path .. "[" .. tostring(index) .. "]")
                end
            else
                writer_u8(writer, TAG_MAP)
                writer_u32(writer, count)
                local keys = {}
                for key in pairs(item) do keys[#keys + 1] = key end
                table.sort(keys)
                for index = 1, #keys do
                    local key = keys[index]
                    if #key > 4096 then abort("map_key_cap_exceeded", path) end
                    writer_u32(writer, #key)
                    writer_bytes(writer, key)
                    encode_value(item[key], depth + 1, path .. "." .. key)
                end
            end
            state.active[item] = nil
        else
            abort("unsupported_value_type", path, kind)
        end
    end

    encode_value(value, 1, "$" )
    return writer_string(writer), {
        bytes = writer.length,
        nodes = state.nodes,
        entries = state.entries,
        string_bytes = state.string_bytes,
    }
end

local function decode_tree(data, limits)
    require_ffi()
    local context = {
        data = data,
        pointer = ffi.cast("const uint8_t*", data),
        length = #data,
        position = 0,
        nodes = 0,
        entries = 0,
        string_bytes = 0,
    }

    local function read_u8()
        if context.position >= context.length then abort("truncated_tag") end
        local value = tonumber(context.pointer[context.position])
        context.position = context.position + 1
        return value
    end

    local function read_u32()
        if context.position + 4 > context.length then abort("truncated_u32") end
        local position = context.position
        local p = context.pointer
        local value = tonumber(p[position])
            + tonumber(p[position + 1]) * 256
            + tonumber(p[position + 2]) * 65536
            + tonumber(p[position + 3]) * 16777216
        context.position = position + 4
        return value
    end

    local function read_bytes(length, path, is_key)
        if not integer(length, 0, context.length)
            or context.position > context.length - length then
            abort("truncated_string", path)
        end
        if (is_key and length > 4096)
            or (not is_key and length > limits.max_string_bytes) then
            abort(is_key and "map_key_cap_exceeded" or "string_cap_exceeded", path)
        end
        context.string_bytes = context.string_bytes + length
        if context.string_bytes > limits.max_total_string_bytes then
            abort("total_string_cap_exceeded", path)
        end
        local value = ffi.string(context.pointer + context.position, length)
        context.position = context.position + length
        return value
    end

    local decode_value
    decode_value = function(depth, path)
        if depth > limits.max_depth then abort("depth_cap_exceeded", path) end
        context.nodes = context.nodes + 1
        if context.nodes > limits.max_nodes then abort("node_cap_exceeded", path) end
        local tag = read_u8()
        if tag == TAG_FALSE then return false end
        if tag == TAG_TRUE then return true end
        if tag == TAG_NUMBER then
            if context.position + 8 > context.length then abort("truncated_number", path) end
            local value = unpack_double(data, context.position + 1)
            context.position = context.position + 8
            return value
        end
        if tag == TAG_STRING then
            return read_bytes(read_u32(), path, false)
        end
        if tag == TAG_ARRAY then
            local count = read_u32()
            if count > limits.max_array_length then abort("array_cap_exceeded", path) end
            context.entries = context.entries + count
            if context.entries > limits.max_entries then abort("entry_cap_exceeded", path) end
            local result = {}
            for index = 1, count do
                result[index] = decode_value(depth + 1,
                    path .. "[" .. tostring(index) .. "]")
            end
            return result
        end
        if tag == TAG_MAP then
            local count = read_u32()
            if count > limits.max_map_entries then abort("map_entry_cap_exceeded", path) end
            context.entries = context.entries + count
            if context.entries > limits.max_entries then abort("entry_cap_exceeded", path) end
            local result = {}
            local previous_key
            for _ = 1, count do
                local key = read_bytes(read_u32(), path, true)
                if previous_key ~= nil and key <= previous_key then
                    abort("non_canonical_map_keys", path)
                end
                previous_key = key
                result[key] = decode_value(depth + 1, path .. "." .. key)
            end
            return result
        end
        abort("invalid_tag", path, tostring(tag))
    end

    local value = decode_value(1, "$")
    if context.position ~= context.length then abort("trailing_tree_bytes") end
    return value, {
        bytes = #data,
        nodes = context.nodes,
        entries = context.entries,
        string_bytes = context.string_bytes,
    }
end

local function dense_array(value, maximum, path)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        abort("array_required", path)
    end
    local count = 0
    local max_index = 0
    for key in pairs(value) do
        if not integer(key, 1, maximum) then abort("dense_array_required", path) end
        count = count + 1
        if key > max_index then max_index = key end
    end
    if count ~= max_index then abort("sparse_array", path) end
    if count > maximum then abort("array_cap_exceeded", path) end
    return count
end

local function required_string(value, path, maximum)
    if type(value) ~= "string" or value == "" then abort("string_required", path) end
    if #value > (maximum or 4096) then abort("string_cap_exceeded", path) end
    return value
end

local function optional_string(value, path, maximum)
    if value == nil then return nil end
    return required_string(value, path, maximum)
end

local function required_integer(value, path, minimum, maximum)
    if not integer(value, minimum or 0, maximum or MAX_SAFE_INTEGER) then
        abort("integer_required", path, tostring(value))
    end
    return value
end

local function required_finite(value, path)
    if not finite_number(value) then abort("finite_number_required", path) end
    return value
end

local function copy_plain(value, limits, state, depth, path, forbidden_keys)
    state = state or { nodes = 0, entries = 0, string_bytes = 0, active = {} }
    depth = depth or 1
    path = path or "$"
    if depth > limits.max_depth then abort("depth_cap_exceeded", path) end
    state.nodes = state.nodes + 1
    if state.nodes > limits.max_nodes then abort("node_cap_exceeded", path) end
    local kind = type(value)
    if kind == "boolean" then return value end
    if kind == "number" then
        if not finite_number(value) then abort("non_finite_number", path) end
        return value
    end
    if kind == "string" then
        if #value > limits.max_string_bytes then abort("string_cap_exceeded", path) end
        state.string_bytes = state.string_bytes + #value
        if state.string_bytes > limits.max_total_string_bytes then
            abort("total_string_cap_exceeded", path)
        end
        return value
    end
    if kind ~= "table" then abort("unsupported_value_type", path, kind) end
    if getmetatable(value) ~= nil then abort("metatable_rejected", path) end
    if state.active[value] then abort("cycle_rejected", path) end
    state.active[value] = true
    local shape, count = table_shape(value, limits, path)
    state.entries = state.entries + count
    if state.entries > limits.max_entries then abort("entry_cap_exceeded", path) end
    local result = {}
    if shape == "array" then
        for index = 1, count do
            result[index] = copy_plain(value[index], limits, state, depth + 1,
                path .. "[" .. tostring(index) .. "]", forbidden_keys)
        end
    else
        for key, child in pairs(value) do
            if forbidden_keys and forbidden_keys[key] then
                abort("forbidden_state_field", path .. "." .. key)
            end
            result[key] = copy_plain(child, limits, state, depth + 1,
                path .. "." .. key, forbidden_keys)
        end
    end
    state.active[value] = nil
    return result
end

local function encode_for_fingerprint(value, limits)
    local data = encode_tree(value, limits, limits.max_context_bytes)
    return fingerprint_bytes(data)
end

local function normalize_dependencies(value, limits)
    value = value or {}
    local count = dense_array(value, limits.max_dependencies, "context.dependencies")
    local result = {}
    local seen = {}
    for index = 1, count do
        local source = value[index]
        local path = "context.dependencies[" .. tostring(index) .. "]"
        if type(source) ~= "table" or getmetatable(source) ~= nil then
            abort("dependency_record_required", path)
        end
        local key = required_string(source.key, path .. ".key")
        if seen[key] then abort("duplicate_dependency", path, key) end
        seen[key] = true
        if source.pending == true or source.status == "pending" then
            abort("remote_pending_dependency", path, key)
        end
        local status = source.status or "ready"
        if status ~= "ready" then abort("dependency_not_ready", path, tostring(status)) end
        local revision = source.revision
        if revision ~= nil and type(revision) ~= "string" then
            revision = required_finite(revision, path .. ".revision")
        elseif type(revision) == "string" then
            required_string(revision, path .. ".revision", 1024)
        end
        local digest = optional_string(source.digest, path .. ".digest", 1024)
        if revision == nil and digest == nil then
            abort("dependency_revision_required", path)
        end
        result[#result + 1] = {
            key = key,
            kind = required_string(source.kind or "asset", path .. ".kind", 128),
            status = "ready",
            revision = revision,
            digest = digest,
            digest_algorithm = optional_string(
                source.digest_algorithm, path .. ".digest_algorithm", 64),
            byte_size = source.byte_size ~= nil
                and required_integer(source.byte_size, path .. ".byte_size", 0)
                or nil,
            remote = source.remote == true,
            pending = false,
        }
    end
    table.sort(result, function(left, right) return left.key < right.key end)
    return result
end

local function normalize_context(context, limits)
    if type(context) ~= "table" or getmetatable(context) ~= nil then
        abort("context_required")
    end
    if context.schema ~= Cache.CONTEXT_SCHEMA
        or context.schema_version ~= Cache.CONTEXT_SCHEMA_VERSION then
        abort("context_schema_mismatch")
    end
    local source = context.source
    if type(source) ~= "table" then abort("context_source_required") end
    local options = copy_plain(context.options, limits, nil, 1, "context.options")
    for index = 1, #Cache.REQUIRED_OPTION_FIELDS do
        local field = Cache.REQUIRED_OPTION_FIELDS[index]
        if rawget(options, field) == nil then
            abort("missing_option_fingerprint_field", field)
        end
    end
    local material_schema = copy_plain(
        context.material_schema, limits, nil, 1, "context.material_schema")
    local versions = copy_plain(context.versions, limits, nil, 1, "context.versions")
    for index = 1, #Cache.REQUIRED_VERSION_DIMENSIONS do
        local field = Cache.REQUIRED_VERSION_DIMENSIONS[index]
        local value = rawget(versions, field)
        if not ((type(value) == "string" and value ~= "")
            or finite_number(value)) then
            abort("missing_version_dimension", field)
        end
    end
    local dependencies = normalize_dependencies(context.dependencies, limits)
    local result = {
        schema = Cache.CONTEXT_SCHEMA,
        schema_version = Cache.CONTEXT_SCHEMA_VERSION,
        source = {
            hash_algorithm = required_string(
                source.hash_algorithm, "context.source.hash_algorithm", 64),
            hash = required_string(source.hash, "context.source.hash", 1024),
            byte_size = required_integer(
                source.byte_size, "context.source.byte_size", 0),
        },
        parse_cache_format_version = required_integer(
            context.parse_cache_format_version,
            "context.parse_cache_format_version", 1, 0xffffffff),
        options = options,
        material_schema = material_schema,
        versions = versions,
        dependencies = dependencies,
    }
    result.options_fingerprint = encode_for_fingerprint(options, limits)
    result.material_schema_fingerprint =
        encode_for_fingerprint(material_schema, limits)
    result.dependency_fingerprint =
        encode_for_fingerprint(dependencies, limits)
    if context.options_fingerprint ~= nil
        and context.options_fingerprint ~= result.options_fingerprint then
        abort("options_fingerprint_mismatch")
    end
    if context.material_schema_fingerprint ~= nil
        and context.material_schema_fingerprint
            ~= result.material_schema_fingerprint then
        abort("material_schema_fingerprint_mismatch")
    end
    if context.dependency_fingerprint ~= nil
        and context.dependency_fingerprint ~= result.dependency_fingerprint then
        abort("dependency_fingerprint_mismatch")
    end
    return result
end

function Cache.build_context(spec, options)
    local ok, result = pcall(function()
        local limits = resolve_limits(options and options.limits)
        if type(spec) ~= "table" then abort("context_spec_required") end
        local provisional = {
            schema = Cache.CONTEXT_SCHEMA,
            schema_version = Cache.CONTEXT_SCHEMA_VERSION,
            source = {
                hash_algorithm = spec.source_hash_algorithm or "sha256",
                hash = spec.source_hash,
                byte_size = spec.source_byte_size,
            },
            parse_cache_format_version = spec.parse_cache_format_version,
            options = spec.options,
            material_schema = spec.material_schema,
            versions = spec.versions,
            dependencies = spec.dependencies or {},
        }
        return normalize_context(provisional, limits)
    end)
    if not ok then return nil, public_error(result) end
    return result
end

local STREAM_ENCODINGS = {
    f32le = 4,
    f64le = 8,
    u16le = 2,
    u32le = 4,
}

local function stream_checksum(data)
    return fingerprint_bytes(data)
end

function Cache.make_stream(encoding, component_count, count, data, options)
    local ok, result = pcall(function()
        local scalar_bytes = STREAM_ENCODINGS[encoding]
        if not scalar_bytes then abort("unsupported_stream_encoding", "stream.encoding") end
        component_count = required_integer(component_count,
            "stream.component_count", 1, 64)
        count = required_integer(count, "stream.count", 0)
        if type(data) ~= "string" then abort("stream_data_string_required") end
        local stride = options and options.stride_bytes
            or component_count * scalar_bytes
        stride = required_integer(stride, "stream.stride_bytes", 1, 4096)
        if stride ~= component_count * scalar_bytes then
            abort("stream_stride_mismatch")
        end
        local expected = checked_product(count, stride, MAX_SAFE_INTEGER,
            "stream_size_overflow")
        if #data ~= expected then abort("stream_length_mismatch") end
        return {
            schema_version = Cache.STREAM_SCHEMA_VERSION,
            encoding = encoding,
            endian = "little",
            component_count = component_count,
            stride_bytes = stride,
            count = count,
            byte_length = #data,
            checksum = stream_checksum(data),
            index_base = options and options.index_base or nil,
            data = data,
        }
    end)
    if not ok then return nil, public_error(result) end
    return result
end

local function normalize_stream(stream, expected, limits, counters, path)
    if type(stream) ~= "table" or getmetatable(stream) ~= nil then
        abort("typed_stream_required", path)
    end
    if stream.schema_version ~= Cache.STREAM_SCHEMA_VERSION then
        abort("stream_schema_mismatch", path)
    end
    local encoding = required_string(stream.encoding, path .. ".encoding", 16)
    local scalar_bytes = STREAM_ENCODINGS[encoding]
    if not scalar_bytes then abort("unsupported_stream_encoding", path) end
    if expected.encoding and encoding ~= expected.encoding then
        abort("stream_encoding_mismatch", path)
    end
    if stream.endian ~= "little" or not HOST_LITTLE_ENDIAN then
        abort("little_endian_stream_required", path)
    end
    local components = required_integer(stream.component_count,
        path .. ".component_count", 1, 64)
    if expected.components and components ~= expected.components then
        abort("stream_component_mismatch", path)
    end
    local stride = required_integer(stream.stride_bytes,
        path .. ".stride_bytes", 1, 4096)
    if stride ~= components * scalar_bytes
        or (expected.stride and stride ~= expected.stride) then
        abort("stream_stride_mismatch", path)
    end
    local maximum_count = expected.max_count or limits.max_vertices_per_stream
    local count = required_integer(stream.count, path .. ".count", 0, maximum_count)
    if expected.nonempty and count == 0 then abort("empty_stream_rejected", path) end
    local byte_length = checked_product(count, stride, limits.max_stream_bytes,
        "stream_byte_cap_exceeded", path)
    if stream.byte_length ~= byte_length then abort("stream_declared_length_mismatch", path) end
    if type(stream.data) ~= "string" or #stream.data ~= byte_length then
        abort("stream_length_mismatch", path)
    end
    counters.stream_bytes = counters.stream_bytes + byte_length
    if counters.stream_bytes > limits.max_total_stream_bytes then
        abort("total_stream_byte_cap_exceeded", path)
    end
    local checksum = required_string(stream.checksum, path .. ".checksum", 80)
    if checksum ~= stream_checksum(stream.data) then
        abort("stream_checksum_mismatch", path)
    end
    local index_base = stream.index_base
    if encoding == "u16le" or encoding == "u32le" then
        index_base = required_integer(index_base, path .. ".index_base", 0, 1)
    elseif index_base ~= nil then
        abort("unexpected_stream_index_base", path)
    end
    local result = {
        schema_version = Cache.STREAM_SCHEMA_VERSION,
        encoding = encoding,
        endian = "little",
        component_count = components,
        stride_bytes = stride,
        count = count,
        byte_length = byte_length,
        checksum = checksum,
        index_base = index_base,
        data = stream.data,
    }
    return result
end

local function scan_finite_stream(stream, path, bounded_components)
    local pointer = ffi.cast("const uint8_t*", stream.data)
    local total = stream.count * stream.component_count
    local values
    if stream.encoding == "f32le" then
        values = ffi.cast("const float*", pointer)
    elseif stream.encoding == "f64le" then
        values = ffi.cast("const double*", pointer)
    else
        return
    end
    for offset = 0, total - 1 do
        local value = tonumber(values[offset])
        if not finite_number(value) then
            abort("non_finite_stream_value", path, tostring(offset + 1))
        end
    end
    if bounded_components then
        for row = 0, stream.count - 1 do
            local base = row * stream.component_count
            for index = 1, #bounded_components do
                local component = bounded_components[index]
                local value = tonumber(values[base + component - 1])
                if value < 0 or value > 1 then
                    abort("bounded_stream_value_out_of_range", path,
                        tostring(row + 1) .. ":" .. tostring(component))
                end
            end
        end
    end
end

local function scan_bounds_stream(
        stream, path, invalid_bounds_code, allow_degenerate)
    local values = ffi.cast("const double*",
        ffi.cast("const uint8_t*", stream.data))
    for row = 0, stream.count - 1 do
        local base = row * 6
        local min_x, min_y, min_z = tonumber(values[base]),
            tonumber(values[base + 1]), tonumber(values[base + 2])
        local max_x, max_y, max_z = tonumber(values[base + 3]),
            tonumber(values[base + 4]), tonumber(values[base + 5])
        if not (finite_number(min_x) and finite_number(min_y)
            and finite_number(min_z) and finite_number(max_x)
            and finite_number(max_y) and finite_number(max_z)) then
            abort("non_finite_stream_value", path, tostring(row + 1))
        end
        local ordered = allow_degenerate
            and min_x <= max_x and min_y <= max_y and min_z <= max_z
            or min_x < max_x and min_y < max_y and min_z < max_z
        if not ordered then
            abort(invalid_bounds_code or "invalid_instance_bounds",
                path, tostring(row + 1))
        end
    end
end

local function scan_indices(stream, vertex_count, path)
    local pointer = ffi.cast("const uint8_t*", stream.data)
    local values = stream.encoding == "u16le"
        and ffi.cast("const uint16_t*", pointer)
        or ffi.cast("const uint32_t*", pointer)
    local minimum = stream.index_base
    local maximum = vertex_count - 1 + minimum
    for index = 0, stream.count - 1 do
        local value = tonumber(values[index])
        if value < minimum or value > maximum then
            abort("index_out_of_range", path,
                tostring(index + 1) .. ":" .. tostring(value))
        end
    end
end

local function normalize_bounds(value, path, allow_flat)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        abort("bounds_required", path)
    end
    local result = {
        min_x = required_finite(value.min_x, path .. ".min_x"),
        min_y = required_finite(value.min_y, path .. ".min_y"),
        min_z = required_finite(value.min_z, path .. ".min_z"),
        max_x = required_finite(value.max_x, path .. ".max_x"),
        max_y = required_finite(value.max_y, path .. ".max_y"),
        max_z = required_finite(value.max_z, path .. ".max_z"),
    }
    local compare = allow_flat and function(a, b) return a <= b end
        or function(a, b) return a < b end
    if not (compare(result.min_x, result.max_x)
        and compare(result.min_y, result.max_y)
        and compare(result.min_z, result.max_z)) then
        abort("invalid_bounds", path)
    end
    return result
end

local function normalize_part_keys(value, expected_count, limits, path, unique)
    local count = dense_array(value, limits.max_parts, path)
    if expected_count ~= nil and count ~= expected_count then
        abort("part_key_count_mismatch", path)
    end
    local result = {}
    local seen = unique and {} or nil
    for index = 1, count do
        local key = required_string(value[index],
            path .. "[" .. tostring(index) .. "]")
        if seen and seen[key] then abort("duplicate_part_key", path, key) end
        if seen then seen[key] = true end
        result[index] = key
    end
    return result, seen
end

local FORBIDDEN_STATE_FIELDS = {
    Parent = true,
    Children = true,
    ClassName = true,
    Properties = true,
    _dom_instance = true,
    part = true,
    part_ref = true,
    facade = true,
    renderer = true,
    mesh = true,
    draw_mesh = true,
    instance_mesh = true,
    shader = true,
    texture = true,
    normal_texture = true,
    detail_normal_texture = true,
    roughness_texture = true,
    metalness_texture = true,
    emissive_texture = true,
    remote_texture_handle = true,
    remote_normal_texture_handle = true,
    remote_mesh_handle = true,
    surface_remote_handles = true,
    surface_resources = true,
    surface_gui_ref = true,
    surface_gui_part_ref = true,
    dynamic_part = true,
    _static_resource_batch = true,
    _instance_resource_batch = true,
}

local function normalize_state(value, limits, path)
    value = value or {}
    local result = copy_plain(value, limits, nil, 1, path,
        FORBIDDEN_STATE_FIELDS)
    if result.dynamic_chunk == true then abort("dynamic_state_rejected", path) end
    if result.source_transparent_part == true or result.transparent == true then
        abort("transparent_state_rejected", path)
    end
    if result.source_kind == "SurfaceGui" then abort("surface_gui_state_rejected", path) end
    return result
end

local function dependency_lookup(context)
    local result = {}
    for index = 1, #(context.dependencies or {}) do
        local dependency = context.dependencies[index]
        result[dependency.key] = dependency
    end
    return result
end

local function normalize_asset_bindings(value, dependency_by_key,
        limits, path)
    value = value or {}
    local count = dense_array(value,
        limits.max_asset_bindings_per_batch, path)
    local result = {}
    local seen_roles = {}
    for index = 1, count do
        local source = value[index]
        local item_path = path .. "[" .. tostring(index) .. "]"
        if type(source) ~= "table" or getmetatable(source) ~= nil then
            abort("asset_binding_required", item_path)
        end
        local role = required_string(source.role, item_path .. ".role", 128)
        local key = required_string(source.dependency_key,
            item_path .. ".dependency_key")
        if seen_roles[role] then abort("duplicate_asset_role", item_path, role) end
        seen_roles[role] = true
        local dependency = dependency_by_key[key]
        if not dependency then abort("unknown_asset_dependency", item_path, key) end
        if dependency.pending == true or dependency.status ~= "ready" then
            abort("asset_dependency_not_ready", item_path, key)
        end
        result[#result + 1] = { role = role, dependency_key = key }
    end
    table.sort(result, function(left, right) return left.role < right.role end)
    return result
end

local function normalize_scalar_map(value, limits, path, maximum_entries)
    value = value or {}
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        abort("map_required", path)
    end
    local result = {}
    local count = 0
    for key, child in pairs(value) do
        count = count + 1
        if count > maximum_entries then abort("map_entry_cap_exceeded", path) end
        if type(key) ~= "string" or #key > 256 then abort("invalid_table_key", path) end
        local kind = type(child)
        if kind == "number" then
            result[key] = required_finite(child, path .. "." .. key)
        elseif kind == "string" then
            result[key] = required_string(child, path .. "." .. key, 4096)
        elseif kind == "boolean" then
            result[key] = child
        else
            abort("scalar_value_required", path .. "." .. key)
        end
    end
    return result
end

local function normalize_part_ranges(value, vertex_count, included, limits, path)
    value = value or {}
    local count = dense_array(value, limits.max_part_ranges_per_batch, path)
    local result = {}
    local next_unoccupied = 1
    for index = 1, count do
        local source = value[index]
        local item_path = path .. "[" .. tostring(index) .. "]"
        if type(source) ~= "table" or getmetatable(source) ~= nil then
            abort("part_range_required", item_path)
        end
        local part_key = required_string(source.part_key, item_path .. ".part_key")
        if not included[part_key] then abort("range_part_not_included", item_path, part_key) end
        local first = required_integer(source.first_vertex,
            item_path .. ".first_vertex", 1, vertex_count)
        local count_value = required_integer(source.vertex_count,
            item_path .. ".vertex_count", 1, vertex_count)
        if count_value % 3 ~= 0 then abort("range_triangle_alignment", item_path) end
        if first < next_unoccupied then abort("part_range_overlap", item_path) end
        if first > vertex_count - count_value + 1 then
            abort("part_range_out_of_bounds", item_path)
        end
        next_unoccupied = first + count_value
        result[index] = {
            part_key = part_key,
            first_vertex = first,
            vertex_count = count_value,
        }
    end
    return result
end

local function normalize_textured_batch(source, pass_name, included,
        dependency_by_key, limits, counters, path)
    if type(source) ~= "table" or getmetatable(source) ~= nil then
        abort("textured_batch_required", path)
    end
    local source_kind = source.source_kind or "Geometry"
    source_kind = required_string(source_kind, path .. ".source_kind", 128)
    if source_kind == "SurfaceGui" then abort("surface_gui_batch_rejected", path) end
    if source.remote_pending == true then abort("remote_pending_batch_rejected", path) end
    local vertices = normalize_stream(source.vertices, {
        encoding = "f32le",
        components = 20,
        stride = 80,
        max_count = limits.max_vertices_per_stream,
        nonempty = true,
    }, limits, counters, path .. ".vertices")
    if vertices.count % 3 ~= 0 then abort("vertex_triangle_alignment", path) end
    scan_finite_stream(vertices, path .. ".vertices")
    counters.vertices = counters.vertices + vertices.count
    local result = {
        key = required_string(source.key, path .. ".key", 16384),
        pass = pass_name,
        source_kind = source_kind,
        vertices = vertices,
        part_ranges = normalize_part_ranges(
            source.part_ranges, vertices.count, included, limits,
            path .. ".part_ranges"),
        bounds = normalize_bounds(source.bounds, path .. ".bounds", false),
        state = normalize_state(source.state, limits, path .. ".state"),
        assets = normalize_asset_bindings(source.assets,
            dependency_by_key, limits, path .. ".assets"),
    }
    if result.state.source_kind ~= nil
        and result.state.source_kind ~= source_kind then
        abort("source_kind_state_mismatch", path)
    end
    return result
end

local function normalize_textured_batches(value, pass_name, included,
        dependency_by_key, limits, counters, path)
    value = value or {}
    local count = dense_array(value, limits.max_textured_batches, path)
    counters.textured_batches = counters.textured_batches + count
    if counters.textured_batches > limits.max_textured_batches then
        abort("textured_batch_cap_exceeded", path)
    end
    local result = {}
    local seen = {}
    for index = 1, count do
        local batch = normalize_textured_batch(value[index], pass_name,
            included, dependency_by_key, limits, counters,
            path .. "[" .. tostring(index) .. "]")
        if seen[batch.key] then abort("duplicate_textured_batch_key", path, batch.key) end
        seen[batch.key] = true
        result[index] = batch
    end
    table.sort(result, function(left, right) return left.key < right.key end)
    return result
end

local function normalize_primitive_batches(value, included, limits,
        counters, path)
    value = value or {}
    local count = dense_array(value, limits.max_primitive_batches, path)
    counters.primitive_batches = counters.primitive_batches + count
    if counters.primitive_batches > limits.max_primitive_batches then
        abort("primitive_batch_cap_exceeded", path)
    end
    local result = {}
    local seen = {}
    for index = 1, count do
        local source = value[index]
        local item_path = path .. "[" .. tostring(index) .. "]"
        if type(source) ~= "table" or getmetatable(source) ~= nil then
            abort("primitive_batch_required", item_path)
        end
        if source.dynamic == true or source.transparent == true
            or source.remote_pending == true then
            abort("ineligible_primitive_batch", item_path)
        end
        local rows = normalize_stream(source.rows, {
            encoding = "f32le", components = 24, stride = 96,
            max_count = limits.max_parts, nonempty = true,
        }, limits, counters, item_path .. ".rows")
        scan_finite_stream(rows, item_path .. ".rows", { 21, 22, 23, 24 })
        local part_keys = normalize_part_keys(source.part_keys,
            rows.count, limits, item_path .. ".part_keys", false)
        for part_index = 1, #part_keys do
            if not included[part_keys[part_index]] then
                abort("primitive_part_not_included", item_path, part_keys[part_index])
            end
        end
        local key = required_string(source.key, item_path .. ".key", 16384)
        if seen[key] then abort("duplicate_primitive_batch_key", item_path, key) end
        seen[key] = true
        result[index] = {
            key = key,
            shape = required_string(source.shape, item_path .. ".shape", 128),
            rows = rows,
            part_keys = part_keys,
            bounds = source.bounds and normalize_bounds(
                source.bounds, item_path .. ".bounds", false) or nil,
        }
    end
    table.sort(result, function(left, right) return left.key < right.key end)
    return result
end

local function normalize_occluders(value, included, limits, counters, path)
    value = value or {}
    local count = dense_array(value, limits.max_occluders, path)
    counters.occluders = counters.occluders + count
    if counters.occluders > limits.max_occluders then abort("occluder_cap_exceeded", path) end
    local result = {}
    for index = 1, count do
        local source = value[index]
        local item_path = path .. "[" .. tostring(index) .. "]"
        if type(source) ~= "table" or getmetatable(source) ~= nil then
            abort("occluder_required", item_path)
        end
        local part_key = required_string(source.part_key, item_path .. ".part_key")
        if not included[part_key] then abort("occluder_part_not_included", item_path) end
        local min_extent = required_finite(source.min_extent, item_path .. ".min_extent")
        local mid_extent = required_finite(source.mid_extent, item_path .. ".mid_extent")
        local max_extent = required_finite(source.max_extent, item_path .. ".max_extent")
        if min_extent < 0 or min_extent > mid_extent or mid_extent > max_extent then
            abort("invalid_occluder_extents", item_path)
        end
        result[index] = {
            part_key = part_key,
            bounds = normalize_bounds(source.bounds, item_path .. ".bounds", false),
            min_extent = min_extent,
            mid_extent = mid_extent,
            max_extent = max_extent,
        }
    end
    return result
end

local function normalize_chunk(source, included, dependency_by_key,
        limits, counters, path)
    if type(source) ~= "table" or getmetatable(source) ~= nil then
        abort("chunk_required", path)
    end
    if source.dynamic == true or source.dynamic_chunk == true then
        abort("dynamic_chunk_rejected", path)
    end
    local grid = source.grid
    if type(grid) ~= "table" then abort("chunk_grid_required", path) end
    return {
        key = required_string(source.key, path .. ".key", 16384),
        grid = {
            x = required_integer(grid.x, path .. ".grid.x", -2147483648, 2147483647),
            y = required_integer(grid.y, path .. ".grid.y", -2147483648, 2147483647),
            z = required_integer(grid.z, path .. ".grid.z", -2147483648, 2147483647),
        },
        bounds = normalize_bounds(source.bounds, path .. ".bounds", false),
        metrics = normalize_scalar_map(source.metrics, limits,
            path .. ".metrics", 128),
        occluders = normalize_occluders(source.occluders, included,
            limits, counters, path .. ".occluders"),
        primitive_batches = normalize_primitive_batches(
            source.primitive_batches, included, limits, counters,
            path .. ".primitive_batches"),
        opaque_textured_batches = normalize_textured_batches(
            source.opaque_textured_batches, "opaque", included,
            dependency_by_key, limits, counters,
            path .. ".opaque_textured_batches"),
        overlay_textured_batches = normalize_textured_batches(
            source.overlay_textured_batches, "overlay", included,
            dependency_by_key, limits, counters,
            path .. ".overlay_textured_batches"),
    }
end

local function normalize_instanced_group(source, included,
        dependency_by_key, limits, counters, path)
    if type(source) ~= "table" or getmetatable(source) ~= nil then
        abort("instanced_group_required", path)
    end
    if source.dynamic == true or source.transparent == true
        or source.remote_pending == true then
        abort("ineligible_instanced_group", path)
    end
    local vertices = normalize_stream(source.base_vertices, {
        encoding = "f32le",
        max_count = limits.max_vertices_per_stream,
        nonempty = true,
    }, limits, counters, path .. ".base_vertices")
    scan_finite_stream(vertices, path .. ".base_vertices")
    counters.vertices = counters.vertices + vertices.count
    local indices
    if source.indices ~= nil then
        local encoding = source.indices.encoding
        if encoding ~= "u16le" and encoding ~= "u32le" then
            abort("index_stream_encoding_required", path .. ".indices")
        end
        indices = normalize_stream(source.indices, {
            encoding = encoding,
            components = 1,
            stride = STREAM_ENCODINGS[encoding],
            max_count = limits.max_indices_per_stream,
            nonempty = true,
        }, limits, counters, path .. ".indices")
        if indices.count % 3 ~= 0 then abort("index_triangle_alignment", path) end
        scan_indices(indices, vertices.count, path .. ".indices")
    elseif vertices.count % 3 ~= 0 then
        abort("vertex_triangle_alignment", path .. ".base_vertices")
    end
    local rows = normalize_stream(source.instance_rows, {
        encoding = "f32le", components = 27, stride = 108,
        max_count = limits.max_parts, nonempty = true,
    }, limits, counters, path .. ".instance_rows")
    scan_finite_stream(rows, path .. ".instance_rows", { 24, 25, 26, 27 })
    local instance_bounds = normalize_stream(source.instance_bounds, {
        encoding = "f64le", components = 6, stride = 48,
        max_count = limits.max_parts, nonempty = true,
    }, limits, counters, path .. ".instance_bounds")
    if instance_bounds.count ~= rows.count then
        abort("instance_bounds_count_mismatch", path)
    end
    scan_bounds_stream(instance_bounds, path .. ".instance_bounds")
    local part_keys = normalize_part_keys(source.part_keys,
        rows.count, limits, path .. ".part_keys", true)
    for index = 1, #part_keys do
        if not included[part_keys[index]] then
            abort("instanced_part_not_included", path, part_keys[index])
        end
    end
    return {
        key = required_string(source.key, path .. ".key", 16384),
        vertex_format_id = required_string(
            source.vertex_format_id, path .. ".vertex_format_id", 256),
        base_vertices = vertices,
        indices = indices,
        instance_rows = rows,
        instance_bounds = instance_bounds,
        part_keys = part_keys,
        bounds = normalize_bounds(source.bounds, path .. ".bounds", false),
        state = normalize_state(source.state, limits, path .. ".state"),
        assets = normalize_asset_bindings(source.assets,
            dependency_by_key, limits, path .. ".assets"),
    }
end

local ALLOWED_EXCLUSION_REASONS = {
    dynamic = true,
    transparent = true,
    surface_gui = true,
    billboard_gui = true,
    remote_pending = true,
    constraint = true,
    unsupported = true,
}

local REQUIRED_REBUILD_POLICY = {
    dynamic = "rebuild",
    transparent = "rebuild",
    surface_gui = "rebuild",
    billboard_gui = "rebuild",
    remote_pending = "rebuild",
    constraints = "rebuild",
}

local function normalize_excluded_parts(value, included, limits)
    value = value or {}
    local count = dense_array(value, limits.max_parts, "payload.excluded_parts")
    local result = {}
    local seen = {}
    for index = 1, count do
        local source = value[index]
        local path = "payload.excluded_parts[" .. tostring(index) .. "]"
        if type(source) ~= "table" or getmetatable(source) ~= nil then
            abort("excluded_part_record_required", path)
        end
        local part_key = required_string(source.part_key, path .. ".part_key")
        if included[part_key] then abort("included_part_also_excluded", path, part_key) end
        if seen[part_key] then abort("duplicate_excluded_part", path, part_key) end
        seen[part_key] = true
        local reason_count = dense_array(source.reasons, 16, path .. ".reasons")
        if reason_count == 0 then abort("exclusion_reason_required", path) end
        local reasons = {}
        local reason_seen = {}
        for reason_index = 1, reason_count do
            local reason = required_string(source.reasons[reason_index],
                path .. ".reasons[" .. tostring(reason_index) .. "]", 64)
            if not ALLOWED_EXCLUSION_REASONS[reason] then
                abort("unknown_exclusion_reason", path, reason)
            end
            if reason_seen[reason] then abort("duplicate_exclusion_reason", path, reason) end
            reason_seen[reason] = true
            reasons[#reasons + 1] = reason
        end
        table.sort(reasons)
        result[#result + 1] = { part_key = part_key, reasons = reasons }
    end
    table.sort(result, function(left, right) return left.part_key < right.part_key end)
    return result, seen
end

local function normalize_rebuild_policy(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        abort("rebuild_policy_required")
    end
    local result = {}
    for field, expected in pairs(REQUIRED_REBUILD_POLICY) do
        if value[field] ~= expected then
            abort("rebuild_policy_mismatch", field)
        end
        result[field] = expected
    end
    return result
end

local function normalize_contact_ao(value, source_part_count,
        partition, limits, counters)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        abort("contact_ao_required")
    end
    local part_keys, seen = normalize_part_keys(value.part_keys,
        source_part_count, limits, "payload.contact_ao.part_keys", true)
    for index = 1, #part_keys do
        if not partition[part_keys[index]] then
            abort("ao_part_not_in_partition", "payload.contact_ao", part_keys[index])
        end
    end
    for part_key in pairs(partition) do
        if not seen[part_key] then
            abort("partition_part_missing_ao", "payload.contact_ao", part_key)
        end
    end
    local rows = normalize_stream(value.rows, {
        encoding = "f64le", components = 4, stride = 32,
        max_count = limits.max_parts,
    }, limits, counters, "payload.contact_ao.rows")
    if rows.count ~= source_part_count then abort("ao_row_count_mismatch") end
    scan_finite_stream(rows, "payload.contact_ao.rows", { 1, 2, 3, 4 })
    return { part_keys = part_keys, rows = rows }
end

local function normalize_render_bounds(value, source_part_count,
        partition, limits, counters)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        abort("render_bounds_required")
    end
    local part_keys, seen = normalize_part_keys(value.part_keys,
        source_part_count, limits, "payload.render_bounds.part_keys", true)
    for index = 1, #part_keys do
        if not partition[part_keys[index]] then
            abort("bounds_part_not_in_partition",
                "payload.render_bounds", part_keys[index])
        end
    end
    for part_key in pairs(partition) do
        if not seen[part_key] then
            abort("partition_part_missing_bounds",
                "payload.render_bounds", part_key)
        end
    end
    local rows = normalize_stream(value.rows, {
        encoding = "f64le", components = 6, stride = 48,
        max_count = limits.max_parts,
    }, limits, counters, "payload.render_bounds.rows")
    if rows.count ~= source_part_count then
        abort("render_bounds_row_count_mismatch")
    end
    -- exact source-wide bounds also cover invisible legacy meshes with an
    -- authored zero Scale component. Equality on one or more axes is a real,
    -- non-rendering bound, not corruption. Rendered instance/group bounds keep
    -- the strict-volume contract used by culling and GPU ownership
    scan_bounds_stream(rows, "payload.render_bounds.rows",
        "invalid_render_bounds", true)
    return { part_keys = part_keys, rows = rows }
end

local function normalize_payload(payload, context, limits)
    if type(payload) ~= "table" or getmetatable(payload) ~= nil then
        abort("payload_required")
    end
    if payload.schema ~= Cache.PAYLOAD_SCHEMA
        or payload.schema_version ~= Cache.PAYLOAD_SCHEMA_VERSION then
        abort("payload_schema_mismatch")
    end
    local source_part_count = required_integer(payload.source_part_count,
        "payload.source_part_count", 0, limits.max_parts)
    local included_keys, included = normalize_part_keys(
        payload.included_part_keys, nil, limits,
        "payload.included_part_keys", true)
    table.sort(included_keys)
    local excluded_parts, excluded = normalize_excluded_parts(
        payload.excluded_parts, included, limits)
    if #included_keys + #excluded_parts ~= source_part_count then
        abort("part_partition_count_mismatch")
    end
    local partition = {}
    for key in pairs(included) do partition[key] = true end
    for key in pairs(excluded) do partition[key] = true end
    local counters = {
        stream_bytes = 0,
        vertices = 0,
        primitive_batches = 0,
        textured_batches = 0,
        instanced_groups = 0,
        occluders = 0,
    }
    local dependency_by_key = dependency_lookup(context)
    local chunks_value = payload.chunks or {}
    local chunk_count = dense_array(chunks_value, limits.max_chunks, "payload.chunks")
    local chunks = {}
    local chunk_seen = {}
    for index = 1, chunk_count do
        local chunk = normalize_chunk(chunks_value[index], included,
            dependency_by_key, limits, counters,
            "payload.chunks[" .. tostring(index) .. "]")
        if chunk_seen[chunk.key] then abort("duplicate_chunk_key", "payload.chunks", chunk.key) end
        chunk_seen[chunk.key] = true
        chunks[index] = chunk
    end
    table.sort(chunks, function(left, right) return left.key < right.key end)
    local group_values = payload.instanced_mesh_groups or {}
    local group_count = dense_array(group_values,
        limits.max_instanced_groups, "payload.instanced_mesh_groups")
    counters.instanced_groups = group_count
    local groups = {}
    local group_seen = {}
    for index = 1, group_count do
        local group = normalize_instanced_group(group_values[index], included,
            dependency_by_key, limits, counters,
            "payload.instanced_mesh_groups[" .. tostring(index) .. "]")
        if group_seen[group.key] then
            abort("duplicate_instanced_group_key", "payload.instanced_mesh_groups", group.key)
        end
        group_seen[group.key] = true
        groups[index] = group
    end
    table.sort(groups, function(left, right) return left.key < right.key end)
    local render_bounds = normalize_render_bounds(payload.render_bounds,
        source_part_count, partition, limits, counters)
    local contact_ao = normalize_contact_ao(payload.contact_ao,
        source_part_count, partition, limits, counters)
    local result = {
        schema = Cache.PAYLOAD_SCHEMA,
        schema_version = Cache.PAYLOAD_SCHEMA_VERSION,
        source_part_count = source_part_count,
        included_part_keys = included_keys,
        excluded_parts = excluded_parts,
        rebuild_policy = normalize_rebuild_policy(payload.rebuild_policy),
        render_bounds = render_bounds,
        contact_ao = contact_ao,
        chunks = chunks,
        instanced_mesh_groups = groups,
        static_scene_bounds = payload.static_scene_bounds
            and normalize_bounds(payload.static_scene_bounds,
                "payload.static_scene_bounds", false)
            or nil,
        stats = copy_plain(payload.stats or {}, limits, nil, 1,
            "payload.stats", FORBIDDEN_STATE_FIELDS),
    }
    return result, counters
end

function Cache.validate_payload(payload, context, options)
    local ok, normalized, counters = pcall(function()
        local limits = resolve_limits(options and options.limits)
        local normalized_context = normalize_context(context, limits)
        return normalize_payload(payload, normalized_context, limits)
    end)
    if not ok then return nil, public_error(normalized) end
    return normalized, counters
end

local function encode_cache(payload, context, options)
    local limits = resolve_limits(options and options.limits)
    local normalized_context = normalize_context(context, limits)
    local normalized_payload, counters = normalize_payload(
        payload, normalized_context, limits)
    local context_data, context_stats = encode_tree(
        normalized_context, limits, limits.max_context_bytes)
    local payload_data, payload_stats = encode_tree(
        normalized_payload, limits, limits.max_payload_bytes)
    local total_bytes = HEADER_BYTES + #context_data + #payload_data
    if total_bytes > limits.max_file_bytes then abort("file_byte_cap_exceeded") end
    local context_hash = raw_sha256(context_data)
    local payload_hash = raw_sha256(payload_data)
    local header = table.concat({
        Cache.MAGIC,
        pack_u32(Cache.FORMAT_VERSION),
        pack_u32(HEADER_BYTES),
        pack_u32(FLAGS_NONE),
        pack_u32(#context_data),
        pack_u32(#payload_data),
        context_hash,
        payload_hash,
    })
    if #header ~= HEADER_BYTES then abort("internal_header_size_mismatch") end
    return header .. context_data .. payload_data, {
        format_version = Cache.FORMAT_VERSION,
        context_fingerprint = fingerprint_bytes(context_data),
        context_bytes = #context_data,
        payload_bytes = #payload_data,
        file_bytes = total_bytes,
        context_stats = context_stats,
        payload_stats = payload_stats,
        scene_counts = counters,
    }
end

function Cache.encode(payload, context, options)
    local ok, data, info = pcall(encode_cache, payload, context, options)
    if not ok then return nil, public_error(data) end
    return data, info
end
Cache.serialize = Cache.encode

local function inspect_header(data, limits)
    if type(data) ~= "string" then abort("cache_data_string_required") end
    if #data > limits.max_file_bytes then abort("file_byte_cap_exceeded") end
    if #data < HEADER_BYTES then abort("truncated_header") end
    if data:sub(1, 4) ~= Cache.MAGIC then abort("magic_mismatch") end
    local version = read_u32_at(data, 5)
    if version ~= Cache.FORMAT_VERSION then abort("format_version_mismatch") end
    local header_bytes = read_u32_at(data, 9)
    if header_bytes ~= HEADER_BYTES then abort("header_size_mismatch") end
    local flags = read_u32_at(data, 13)
    if flags ~= FLAGS_NONE then abort("unsupported_flags") end
    local context_bytes = read_u32_at(data, 17)
    local payload_bytes = read_u32_at(data, 21)
    if context_bytes > limits.max_context_bytes then abort("context_byte_cap_exceeded") end
    if payload_bytes > limits.max_payload_bytes then abort("payload_byte_cap_exceeded") end
    if context_bytes > limits.max_file_bytes - HEADER_BYTES
        or payload_bytes > limits.max_file_bytes - HEADER_BYTES - context_bytes then
        abort("file_size_overflow")
    end
    if HEADER_BYTES + context_bytes + payload_bytes ~= #data then
        abort("file_size_mismatch")
    end
    return {
        version = version,
        flags = flags,
        context_bytes = context_bytes,
        payload_bytes = payload_bytes,
        context_hash = data:sub(25, 56),
        payload_hash = data:sub(57, 88),
        context_start = HEADER_BYTES + 1,
        payload_start = HEADER_BYTES + context_bytes + 1,
    }
end

function Cache.inspect_header(data, options)
    local ok, result = pcall(function()
        return inspect_header(data, resolve_limits(options and options.limits))
    end)
    if not ok then return nil, public_error(result) end
    return result
end

-- decode and canonicalize only the small context prefix.  production cache
-- users need this before constructing their expected dependency list: the
-- cached list names the exact local files that must be re-hashed, while the
-- much larger payload must remain untouched until those hashes and every
-- renderer option/version dimension agree.  this is not a trust bypass -- the
-- header, context checksum, resource limits, schema, and canonical encoding are
-- all validated exactly as they are in the full decoder
local function decode_cache_context(data, options)
    local limits = resolve_limits(options and options.limits)
    local header = inspect_header(data, limits)
    local context_end = header.payload_start - 1
    local context_data = data:sub(header.context_start, context_end)
    if raw_sha256(context_data) ~= header.context_hash then
        abort("context_checksum_mismatch")
    end
    local decoded_context = decode_tree(context_data, limits)
    local normalized_context = normalize_context(decoded_context, limits)
    local canonical_context = encode_tree(
        normalized_context, limits, limits.max_context_bytes)
    if canonical_context ~= context_data then abort("non_canonical_context") end
    return normalized_context, {
        format_version = header.version,
        context_fingerprint = fingerprint_bytes(context_data),
        context_bytes = header.context_bytes,
        payload_bytes = header.payload_bytes,
        file_bytes = #data,
    }
end

function Cache.decode_context(data, options)
    local ok, context, info = pcall(decode_cache_context, data, options)
    if not ok then return nil, public_error(context) end
    return context, info
end

local function decode_cache(data, expected_context, options)
    local limits = resolve_limits(options and options.limits)
    local header = inspect_header(data, limits)
    local context_end = header.payload_start - 1
    local payload_end = #data
    local context_data = data:sub(header.context_start, context_end)
    if raw_sha256(context_data) ~= header.context_hash then
        abort("context_checksum_mismatch")
    end

    -- reject stale data before hashing/decoding the much larger scene payload
    local normalized_expected = normalize_context(expected_context, limits)
    local expected_data = encode_tree(
        normalized_expected, limits, limits.max_context_bytes)
    if #expected_data ~= #context_data or expected_data ~= context_data then
        abort("stale_context")
    end

    local decoded_context = decode_tree(context_data, limits)
    local normalized_context = normalize_context(decoded_context, limits)
    local canonical_context = encode_tree(
        normalized_context, limits, limits.max_context_bytes)
    if canonical_context ~= context_data then abort("non_canonical_context") end

    local payload_data = data:sub(header.payload_start, payload_end)
    if raw_sha256(payload_data) ~= header.payload_hash then
        abort("payload_checksum_mismatch")
    end
    local decoded_payload, decode_stats = decode_tree(payload_data, limits)
    local normalized_payload, counters = normalize_payload(
        decoded_payload, normalized_context, limits)
    local canonical_payload = encode_tree(
        normalized_payload, limits, limits.max_payload_bytes)
    if canonical_payload ~= payload_data then abort("non_canonical_payload") end
    return normalized_payload, {
        format_version = header.version,
        context_fingerprint = fingerprint_bytes(context_data),
        context_bytes = header.context_bytes,
        payload_bytes = header.payload_bytes,
        file_bytes = #data,
        decode_stats = decode_stats,
        scene_counts = counters,
    }
end

function Cache.decode(data, expected_context, options)
    local ok, payload, info = pcall(
        decode_cache, data, expected_context, options)
    if not ok then return nil, public_error(payload) end
    return payload, info
end
Cache.deserialize = Cache.decode

local function validate_cache_name(cache_name)
    if type(cache_name) ~= "string" or cache_name == ""
        or #cache_name > 128
        or not cache_name:match("^[%w%._%-]+$")
        or cache_name == "." or cache_name == ".." then
        abort("invalid_cache_name")
    end
    return cache_name
end

function Cache.path(cache_name)
    local ok, result = pcall(function()
        return Cache.CACHE_DIR .. "/"
            .. validate_cache_name(cache_name) .. ".scene-cache"
    end)
    if not ok then return nil, public_error(result) end
    return result
end

local temporary_sequence = 0

local function filesystem_call(filesystem, name, ...)
    local fn = filesystem and filesystem[name]
    if type(fn) ~= "function" then abort("filesystem_method_unavailable", name) end
    local ok, first, second = pcall(fn, ...)
    if not ok then abort("filesystem_" .. name .. "_failed", nil, first) end
    return first, second
end

local function default_atomic_replace(temporary_path, final_path)
    local filesystem = love and love.filesystem
    if not filesystem then return false, "love.filesystem unavailable" end
    if type(filesystem.rename) == "function" then
        local ok, renamed, rename_error = pcall(
            filesystem.rename, temporary_path, final_path)
        if ok and renamed then return true end
        if not ok then rename_error = renamed end
        -- fall through to the native atomic replace.  some LOVE releases expose
        -- rename but cannot replace an existing Windows destination
    end
    if type(filesystem.getSaveDirectory) ~= "function" then
        return false, "save directory unavailable"
    end
    local save_directory = filesystem.getSaveDirectory()
    if type(save_directory) ~= "string" or save_directory == "" then
        return false, "save directory unavailable"
    end
    local separator = package.config:sub(1, 1)
    local function absolute(relative)
        relative = relative:gsub("/", separator)
        if save_directory:sub(-1) == separator then
            return save_directory .. relative
        end
        return save_directory .. separator .. relative
    end
    local temporary_absolute = absolute(temporary_path)
    local final_absolute = absolute(final_path)
    if separator == "\\" then
        if not ffi_ok then return false, "ffi unavailable for atomic Windows replace" end
        pcall(ffi.cdef, [[
            int __stdcall MoveFileExA(const char *existing_name,
                const char *new_name, unsigned long flags);
        ]])
        local loaded, kernel32 = pcall(ffi.load, "kernel32")
        if not loaded or not kernel32 then
            return false, "kernel32 unavailable"
        end
        local moved = kernel32.MoveFileExA(
            temporary_absolute, final_absolute, 0x1 + 0x8)
        return moved ~= 0, moved ~= 0 and nil or "MoveFileExA failed"
    end
    local renamed, rename_error = os.rename(temporary_absolute, final_absolute)
    return renamed == true, rename_error
end

local function save_cache(cache_name, payload, context, options)
    options = options or {}
    local data, encode_info = encode_cache(payload, context, options)
    local filesystem = options.filesystem or (love and love.filesystem)
    if not filesystem then abort("filesystem_unavailable") end
    cache_name = validate_cache_name(cache_name)
    local final_path = Cache.CACHE_DIR .. "/" .. cache_name .. ".scene-cache"
    filesystem_call(filesystem, "createDirectory", Cache.CACHE_DIR)
    temporary_sequence = temporary_sequence + 1
    local temporary_path = Cache.CACHE_DIR .. "/." .. cache_name
        .. "." .. tostring(temporary_sequence) .. ".tmp"
    local wrote, write_error = filesystem_call(
        filesystem, "write", temporary_path, data)
    if not wrote then
        pcall(function() filesystem_call(filesystem, "remove", temporary_path) end)
        abort("filesystem_write_failed", nil, write_error)
    end
    if type(filesystem.getInfo) == "function" then
        local info = filesystem_call(filesystem, "getInfo", temporary_path, "file")
        if type(info) ~= "table" or tonumber(info.size) ~= #data then
            pcall(function() filesystem_call(filesystem, "remove", temporary_path) end)
            abort("temporary_file_size_mismatch")
        end
    end
    local replaced, replace_error
    if type(options.atomic_replace) == "function" then
        local ok, first, second = pcall(
            options.atomic_replace, filesystem, temporary_path, final_path)
        if ok then replaced, replace_error = first, second
        else replaced, replace_error = false, first end
    elseif type(filesystem.atomic_replace) == "function" then
        local ok, first, second = pcall(
            filesystem.atomic_replace, temporary_path, final_path)
        if ok then replaced, replace_error = first, second
        else replaced, replace_error = false, first end
    elseif filesystem == (love and love.filesystem) then
        replaced, replace_error = default_atomic_replace(
            temporary_path, final_path)
    else
        replaced, replace_error = false, "atomic replace unavailable"
    end
    if not replaced then
        pcall(function() filesystem_call(filesystem, "remove", temporary_path) end)
        abort("atomic_replace_failed", nil, replace_error)
    end
    encode_info.path = final_path
    return true, encode_info
end

function Cache.save(cache_name, payload, context, options)
    local ok, saved, info = pcall(
        save_cache, cache_name, payload, context, options)
    if not ok then return false, public_error(saved) end
    return saved, info
end

local function load_cache(cache_name, expected_context, options)
    options = options or {}
    local limits = resolve_limits(options.limits)
    local filesystem = options.filesystem or (love and love.filesystem)
    if not filesystem then abort("filesystem_unavailable") end
    cache_name = validate_cache_name(cache_name)
    local path = Cache.CACHE_DIR .. "/" .. cache_name .. ".scene-cache"
    if type(filesystem.getInfo) == "function" then
        local info = filesystem_call(filesystem, "getInfo", path, "file")
        if info == nil then abort("cache_miss") end
        local size = tonumber(info.size)
        if not integer(size, 0, limits.max_file_bytes) then
            abort("file_byte_cap_exceeded")
        end
    end
    local data, read_error = filesystem_call(filesystem, "read", path)
    if type(data) ~= "string" then
        abort(data == nil and "cache_miss" or "filesystem_read_invalid", nil, read_error)
    end
    local payload, info = decode_cache(data, expected_context, options)
    info.path = path
    return payload, info
end

function Cache.load(cache_name, expected_context, options)
    local ok, payload, info = pcall(
        load_cache, cache_name, expected_context, options)
    if not ok then return nil, public_error(payload) end
    return payload, info
end

local function load_cache_context(cache_name, options)
    options = options or {}
    local limits = resolve_limits(options.limits)
    local filesystem = options.filesystem or (love and love.filesystem)
    if not filesystem then abort("filesystem_unavailable") end
    cache_name = validate_cache_name(cache_name)
    local path = Cache.CACHE_DIR .. "/" .. cache_name .. ".scene-cache"
    if type(filesystem.getInfo) == "function" then
        local file_info = filesystem_call(filesystem, "getInfo", path, "file")
        if file_info == nil then abort("cache_miss") end
        local size = tonumber(file_info.size)
        if not integer(size, 0, limits.max_file_bytes) then
            abort("file_byte_cap_exceeded")
        end
    end
    local data, read_error = filesystem_call(filesystem, "read", path)
    if type(data) ~= "string" then
        abort(data == nil and "cache_miss" or "filesystem_read_invalid",
            nil, read_error)
    end
    local context, info = decode_cache_context(data, options)
    info.path = path
    return context, info
end

function Cache.load_context(cache_name, options)
    local ok, context, info = pcall(
        load_cache_context, cache_name, options)
    if not ok then return nil, public_error(context) end
    return context, info
end

return Cache
