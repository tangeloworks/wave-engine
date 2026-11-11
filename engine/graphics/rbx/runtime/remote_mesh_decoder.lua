-- decode downloaded mesh bytes in a worker before the renderer uploads them

local binary = require("engine/graphics/rbx/binary")
local Composer = require("engine/graphics/rbx/csg_child_composer")
local constants = require("engine/graphics/rbx/constants")
local dom = require("engine/graphics/rbx/dom")
local mesh = require("engine/graphics/rbx/mesh")
local StreamAccounting = require("engine/graphics/rbx/mesh_stream_accounting")
local xml = require("engine/graphics/rbx/xml")

local Decoder = {}

local MiB = 1024 * 1024
local MAX_CONTAINER_DEPTH = 4
local MAX_CONTAINER_COUNT = 64
local MAX_CONTAINER_INSTANCES = 200000
local MAX_XML_CONTAINER_BYTES = 32 * MiB
local MAX_BINARY_CHUNK_BYTES = 32 * MiB
local MAX_DECOMPRESSED_BYTES = 64 * MiB
local MAX_GZIP_EXPANSION_RATIO = 256
local MAX_GZIP_HEADER_BYTES = 64 * 1024
local MAX_GZIP_DEFLATE_BLOCKS = 65536
local MAX_NESTED_AND_LOCAL_BYTES = 64 * MiB
local MAX_LOCAL_FILE_BYTES = 32 * MiB
local MAX_LOCAL_DEPENDENCIES = 128
local MAX_CSG_PARTS = 16384
local DEFAULT_OUTPUT_VERTICES = 1000000
local HARD_MAX_OUTPUT_VERTICES = 2000000
local DEFAULT_OUTPUT_TRIANGLES = 4000000
local HARD_MAX_OUTPUT_TRIANGLES = 40000000

Decoder.LIMITS = {
    max_container_depth = MAX_CONTAINER_DEPTH,
    max_container_count = MAX_CONTAINER_COUNT,
    max_container_instances = MAX_CONTAINER_INSTANCES,
    max_xml_container_bytes = MAX_XML_CONTAINER_BYTES,
    max_decompressed_bytes = MAX_DECOMPRESSED_BYTES,
    max_gzip_expansion_ratio = MAX_GZIP_EXPANSION_RATIO,
    max_gzip_header_bytes = MAX_GZIP_HEADER_BYTES,
    max_gzip_deflate_blocks = MAX_GZIP_DEFLATE_BLOCKS,
    max_nested_and_local_bytes = MAX_NESTED_AND_LOCAL_BYTES,
    max_local_file_bytes = MAX_LOCAL_FILE_BYTES,
    max_local_dependencies = MAX_LOCAL_DEPENDENCIES,
    max_csg_parts = MAX_CSG_PARTS,
    default_output_vertices = DEFAULT_OUTPUT_VERTICES,
    hard_max_output_vertices = HARD_MAX_OUTPUT_VERTICES,
    default_output_triangles = DEFAULT_OUTPUT_TRIANGLES,
    hard_max_output_triangles = HARD_MAX_OUTPUT_TRIANGLES,
    max_cumulative_resolved_vertices = HARD_MAX_OUTPUT_VERTICES,
    max_cumulative_resolved_triangles = HARD_MAX_OUTPUT_TRIANGLES,
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

local function score(value)
    if type(value) ~= "table" then return -1 end
    return SOURCE_SCORE[value.source_kind] or 0
end

local function prefer(current, candidate)
    if score(candidate) > score(current) then return candidate end
    return current
end

local function is_limit_reason(reason)
    return type(reason) == "string"
        and reason:find("limit", 1, true) ~= nil
end

local function is_unsupported_csg_reason(reason)
    return type(reason) == "string"
        and reason:find("csg_boolean_operation_unsupported:", 1, true) == 1
end

local function gzip_flag_set(flags, mask)
    return math.floor(flags / mask) % 2 == 1
end

local function gzip_read_header(data)
    local size = #data
    if size < 18 then return nil, "gzip_truncated" end
    if data:byte(3) ~= 8 then return nil, "gzip_method_unsupported" end
    local flags = data:byte(4)
    if flags >= 32 then return nil, "gzip_header_invalid" end

    local cursor = 11
    local function header_room(bytes)
        return cursor + bytes - 1 <= size - 8
            and cursor + bytes - 1 <= MAX_GZIP_HEADER_BYTES
    end
    if gzip_flag_set(flags, 4) then
        if not header_room(2) then return nil, "gzip_header_byte_limit" end
        local extra_size = data:byte(cursor) + data:byte(cursor + 1) * 256
        cursor = cursor + 2
        if not header_room(extra_size) then
            return nil, "gzip_header_byte_limit"
        end
        cursor = cursor + extra_size
    end
    local function skip_zero_terminated()
        local terminator = data:find("\0", cursor, true)
        if not terminator or terminator > size - 8
            or terminator > MAX_GZIP_HEADER_BYTES then
            return false
        end
        cursor = terminator + 1
        return true
    end
    if gzip_flag_set(flags, 8) and not skip_zero_terminated() then
        return nil, "gzip_header_byte_limit"
    end
    if gzip_flag_set(flags, 16) and not skip_zero_terminated() then
        return nil, "gzip_header_byte_limit"
    end
    if gzip_flag_set(flags, 2) then
        if not header_room(2) then return nil, "gzip_header_byte_limit" end
        cursor = cursor + 2
    end
    if cursor > size - 8 then return nil, "gzip_truncated" end
    return cursor
end

-- LOVE's gzip API neither accepts an output ceiling nor reports how many input
-- bytes one member consumed.  this DEFLATE walk deliberately materializes no
-- output: literals and back-references only advance a checked byte count.  it
-- therefore proves the expansion bound and exact first-member boundary before
-- the native inflater is allowed to allocate the decoded string
local function new_deflate_reader(data, first)
    return {
        data = data,
        cursor = first,
        last = #data,
        bit_buffer = 0,
        bit_count = 0,
    }
end

local function deflate_read_bits(reader, count)
    while reader.bit_count < count do
        if reader.cursor > reader.last then
            return nil, "gzip_deflate_truncated"
        end
        reader.bit_buffer = reader.bit_buffer
            + reader.data:byte(reader.cursor) * (2 ^ reader.bit_count)
        reader.bit_count = reader.bit_count + 8
        reader.cursor = reader.cursor + 1
    end
    local divisor = 2 ^ count
    local value = reader.bit_buffer % divisor
    reader.bit_buffer = math.floor(reader.bit_buffer / divisor)
    reader.bit_count = reader.bit_count - count
    return value
end

local function deflate_align_byte(reader)
    reader.bit_buffer = 0
    reader.bit_count = 0
end

local function reverse_code(code, bit_count)
    local reversed = 0
    for _ = 1, bit_count do
        reversed = reversed * 2 + code % 2
        code = math.floor(code / 2)
    end
    return reversed
end

local function build_huffman(code_lengths, symbol_count, allow_empty)
    local counts = {}
    local max_bits, populated = 0, 0
    for symbol = 0, symbol_count - 1 do
        local bit_count = tonumber(code_lengths[symbol + 1]) or 0
        if bit_count < 0 or bit_count > 15 or bit_count ~= math.floor(bit_count) then
            return nil, "gzip_deflate_invalid"
        end
        if bit_count > 0 then
            counts[bit_count] = (counts[bit_count] or 0) + 1
            max_bits = math.max(max_bits, bit_count)
            populated = populated + 1
        end
    end
    if populated == 0 then
        if allow_empty then return { max_bits = 0, symbols = {} } end
        return nil, "gzip_deflate_invalid"
    end

    local remaining = 1
    for bit_count = 1, max_bits do
        remaining = remaining * 2 - (counts[bit_count] or 0)
        if remaining < 0 then return nil, "gzip_deflate_invalid" end
    end

    local next_code, code = {}, 0
    for bit_count = 1, max_bits do
        code = (code + (counts[bit_count - 1] or 0)) * 2
        next_code[bit_count] = code
    end
    local symbols = {}
    for symbol = 0, symbol_count - 1 do
        local bit_count = code_lengths[symbol + 1] or 0
        if bit_count > 0 then
            local canonical = next_code[bit_count]
            next_code[bit_count] = canonical + 1
            local bucket = symbols[bit_count]
            if not bucket then
                bucket = {}
                symbols[bit_count] = bucket
            end
            bucket[reverse_code(canonical, bit_count)] = symbol
        end
    end
    return { max_bits = max_bits, symbols = symbols }
end

local function deflate_read_symbol(reader, tree)
    if not tree or tree.max_bits == 0 then
        return nil, "gzip_deflate_invalid"
    end
    local code = 0
    for bit_count = 1, tree.max_bits do
        local bit, reason = deflate_read_bits(reader, 1)
        if bit == nil then return nil, reason end
        code = code + bit * (2 ^ (bit_count - 1))
        local bucket = tree.symbols[bit_count]
        local symbol = bucket and bucket[code]
        if symbol ~= nil then return symbol end
    end
    return nil, "gzip_deflate_invalid"
end

local FIXED_LITERAL_TREE
local FIXED_DISTANCE_TREE

local function fixed_deflate_trees()
    if FIXED_LITERAL_TREE then
        return FIXED_LITERAL_TREE, FIXED_DISTANCE_TREE
    end
    local literal_lengths = {}
    for symbol = 0, 287 do
        if symbol <= 143 then
            literal_lengths[symbol + 1] = 8
        elseif symbol <= 255 then
            literal_lengths[symbol + 1] = 9
        elseif symbol <= 279 then
            literal_lengths[symbol + 1] = 7
        else
            literal_lengths[symbol + 1] = 8
        end
    end
    local distance_lengths = {}
    for symbol = 0, 31 do distance_lengths[symbol + 1] = 5 end
    FIXED_LITERAL_TREE = assert(build_huffman(literal_lengths, 288, false))
    FIXED_DISTANCE_TREE = assert(build_huffman(distance_lengths, 32, false))
    return FIXED_LITERAL_TREE, FIXED_DISTANCE_TREE
end

local CODE_LENGTH_ORDER = {
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5,
    11, 4, 12, 3, 13, 2, 14, 1, 15,
}

local function dynamic_deflate_trees(reader)
    local hlit, reason = deflate_read_bits(reader, 5)
    if hlit == nil then return nil, nil, reason end
    local hdist
    hdist, reason = deflate_read_bits(reader, 5)
    if hdist == nil then return nil, nil, reason end
    local hclen
    hclen, reason = deflate_read_bits(reader, 4)
    if hclen == nil then return nil, nil, reason end
    hlit, hdist, hclen = hlit + 257, hdist + 1, hclen + 4
    if hlit > 286 or hdist > 32 then
        return nil, nil, "gzip_deflate_invalid"
    end

    local alphabet_lengths = {}
    for index = 1, 19 do alphabet_lengths[index] = 0 end
    for index = 1, hclen do
        local bit_count
        bit_count, reason = deflate_read_bits(reader, 3)
        if bit_count == nil then return nil, nil, reason end
        alphabet_lengths[CODE_LENGTH_ORDER[index] + 1] = bit_count
    end
    local alphabet
    alphabet, reason = build_huffman(alphabet_lengths, 19, false)
    if not alphabet then return nil, nil, reason end

    local lengths, total = {}, hlit + hdist
    while #lengths < total do
        local symbol
        symbol, reason = deflate_read_symbol(reader, alphabet)
        if symbol == nil then return nil, nil, reason end
        if symbol <= 15 then
            lengths[#lengths + 1] = symbol
        elseif symbol == 16 then
            if #lengths == 0 then
                return nil, nil, "gzip_deflate_invalid"
            end
            local extra
            extra, reason = deflate_read_bits(reader, 2)
            if extra == nil then return nil, nil, reason end
            local repeated = lengths[#lengths]
            local count = extra + 3
            if #lengths + count > total then
                return nil, nil, "gzip_deflate_invalid"
            end
            for _ = 1, count do lengths[#lengths + 1] = repeated end
        elseif symbol == 17 or symbol == 18 then
            local extra_bits = symbol == 17 and 3 or 7
            local base = symbol == 17 and 3 or 11
            local extra
            extra, reason = deflate_read_bits(reader, extra_bits)
            if extra == nil then return nil, nil, reason end
            local count = base + extra
            if #lengths + count > total then
                return nil, nil, "gzip_deflate_invalid"
            end
            for _ = 1, count do lengths[#lengths + 1] = 0 end
        else
            return nil, nil, "gzip_deflate_invalid"
        end
    end

    local literal_lengths, distance_lengths = {}, {}
    for index = 1, hlit do literal_lengths[index] = lengths[index] end
    for index = 1, hdist do
        distance_lengths[index] = lengths[hlit + index]
    end
    if (literal_lengths[257] or 0) == 0 then
        return nil, nil, "gzip_deflate_invalid"
    end
    local literal_tree
    literal_tree, reason = build_huffman(literal_lengths, hlit, false)
    if not literal_tree then return nil, nil, reason end
    local distance_tree
    distance_tree, reason = build_huffman(distance_lengths, hdist, true)
    if not distance_tree then return nil, nil, reason end
    return literal_tree, distance_tree
end

local LENGTH_BASE = {
    3, 4, 5, 6, 7, 8, 9, 10,
    11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258,
}
local LENGTH_EXTRA = {
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0,
}
local DISTANCE_BASE = {
    1, 2, 3, 4, 5, 7, 9, 13,
    17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577,
}
local DISTANCE_EXTRA = {
    0, 0, 0, 0, 1, 1, 2, 2,
    3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10,
    11, 11, 12, 12, 13, 13,
}

local function scan_compressed_deflate_block(reader, literal_tree,
        distance_tree, output_size)
    while true do
        local symbol, reason = deflate_read_symbol(reader, literal_tree)
        if symbol == nil then return nil, reason end
        if symbol < 256 then
            output_size = output_size + 1
        elseif symbol == 256 then
            return output_size
        elseif symbol >= 257 and symbol <= 285 then
            local index = symbol - 256
            local length = LENGTH_BASE[index]
            local extra_bits = LENGTH_EXTRA[index]
            if extra_bits > 0 then
                local extra
                extra, reason = deflate_read_bits(reader, extra_bits)
                if extra == nil then return nil, reason end
                length = length + extra
            end
            local distance_symbol
            distance_symbol, reason = deflate_read_symbol(reader, distance_tree)
            if distance_symbol == nil then return nil, reason end
            if distance_symbol > 29 then
                return nil, "gzip_deflate_invalid"
            end
            local distance_index = distance_symbol + 1
            local distance = DISTANCE_BASE[distance_index]
            extra_bits = DISTANCE_EXTRA[distance_index]
            if extra_bits > 0 then
                local extra
                extra, reason = deflate_read_bits(reader, extra_bits)
                if extra == nil then return nil, reason end
                distance = distance + extra
            end
            if distance > output_size then
                return nil, "gzip_deflate_invalid"
            end
            output_size = output_size + length
        else
            return nil, "gzip_deflate_invalid"
        end
        if output_size > MAX_DECOMPRESSED_BYTES then
            return nil, "decompressed_byte_limit"
        end
    end
end

local function scan_deflate(data, first)
    local reader = new_deflate_reader(data, first)
    local output_size, block_count, final = 0, 0, false
    while not final do
        block_count = block_count + 1
        if block_count > MAX_GZIP_DEFLATE_BLOCKS then
            return nil, nil, "gzip_deflate_block_limit"
        end
        local final_bit, reason = deflate_read_bits(reader, 1)
        if final_bit == nil then return nil, nil, reason end
        final = final_bit == 1
        local block_type
        block_type, reason = deflate_read_bits(reader, 2)
        if block_type == nil then return nil, nil, reason end
        if block_type == 0 then
            deflate_align_byte(reader)
            if reader.cursor + 3 > reader.last then
                return nil, nil, "gzip_deflate_truncated"
            end
            local length = reader.data:byte(reader.cursor)
                + reader.data:byte(reader.cursor + 1) * 256
            local complement = reader.data:byte(reader.cursor + 2)
                + reader.data:byte(reader.cursor + 3) * 256
            reader.cursor = reader.cursor + 4
            if length + complement ~= 65535 then
                return nil, nil, "gzip_deflate_invalid"
            end
            if reader.cursor + length - 1 > reader.last then
                return nil, nil, "gzip_deflate_truncated"
            end
            output_size = output_size + length
            if output_size > MAX_DECOMPRESSED_BYTES then
                return nil, nil, "decompressed_byte_limit"
            end
            reader.cursor = reader.cursor + length
        elseif block_type == 1 or block_type == 2 then
            local literal_tree, distance_tree
            if block_type == 1 then
                literal_tree, distance_tree = fixed_deflate_trees()
            else
                literal_tree, distance_tree, reason =
                    dynamic_deflate_trees(reader)
                if not literal_tree then return nil, nil, reason end
            end
            output_size, reason = scan_compressed_deflate_block(
                reader, literal_tree, distance_tree, output_size)
            if output_size == nil then return nil, nil, reason end
        else
            return nil, nil, "gzip_deflate_invalid"
        end
    end
    return output_size, reader.cursor
end

local function preflight_gzip(data)
    local compressed_start, reason = gzip_read_header(data)
    if not compressed_start then return nil, reason end
    local output_size, trailer_start
    output_size, trailer_start, reason = scan_deflate(data, compressed_start)
    if output_size == nil then return nil, reason end
    if trailer_start + 7 > #data then return nil, "gzip_truncated" end
    -- a decoder API that reports consumed input would also prove this. LOVE's
    -- API does not, so the structural pass must place the first trailer exactly
    -- at EOF, any bytes after it are a second member or ambiguous trailing data
    if trailer_start + 7 ~= #data then return nil, "gzip_multiple_members" end
    local isize_offset = trailer_start + 4
    local isize = data:byte(isize_offset)
        + data:byte(isize_offset + 1) * 256
        + data:byte(isize_offset + 2) * 65536
        + data:byte(isize_offset + 3) * 16777216
    if isize > MAX_DECOMPRESSED_BYTES then
        return nil, "decompressed_byte_limit"
    end
    if output_size ~= isize then return nil, "gzip_size_mismatch" end
    if output_size == 0 then return nil, "gzip_empty_payload" end
    local compressed_size = trailer_start - compressed_start
    if compressed_size <= 0 then return nil, "gzip_deflate_invalid" end
    if output_size > compressed_size * MAX_GZIP_EXPANSION_RATIO then
        return nil, "decompression_ratio_limit"
    end
    return {
        output_size = output_size,
        compressed_size = compressed_size,
    }
end

local function maybe_gzip(data)
    if type(data) ~= "string" or #data < 2
        or data:byte(1) ~= 0x1f or data:byte(2) ~= 0x8b then
        return nil, nil, false
    end
    local preflight, preflight_reason = preflight_gzip(data)
    if not preflight then return nil, preflight_reason, true end
    if not (love and love.data and love.data.decompress) then
        return nil, "gzip_unavailable", true
    end
    local ok, result = pcall(love.data.decompress, "gzip", data)
    if not ok or type(result) ~= "string" or result == "" then
        ok, result = pcall(love.data.decompress, "string", "gzip", data)
    end
    if not ok or type(result) ~= "string" or result == "" then
        return nil, "gzip_decompress_failed", true
    end
    if #result > MAX_DECOMPRESSED_BYTES then
        return nil, "decompressed_byte_limit", true
    end
    if #result ~= preflight.output_size then
        return nil, "gzip_size_mismatch", true
    end
    return result, nil, true
end

local function looks_like_xml(data)
    if type(data) ~= "string" then return false end
    local prefix = data:sub(1, 512):lower()
    return prefix:find("<roblox", 1, true) ~= nil
end

local function count_xml_items_bounded(data, remaining)
    local count, cursor = 0, 1
    remaining = math.max(0, tonumber(remaining) or MAX_CONTAINER_INSTANCES)
    while true do
        local found = data:find("<Item", cursor, true)
        if not found then return count end
        count = count + 1
        if count > remaining then return count end
        cursor = found + 5
    end
end

local function new_state(job)
    local requested_vertices = math.floor(
        tonumber(job and (job.max_output_vertices
            or job.max_decoded_vertices)) or DEFAULT_OUTPUT_VERTICES)
    requested_vertices = math.max(3,
        math.min(HARD_MAX_OUTPUT_VERTICES, requested_vertices))
    local requested_triangles = math.floor(
        tonumber(job and (job.max_output_triangles
            or job.max_decoded_triangles)) or DEFAULT_OUTPUT_TRIANGLES)
    requested_triangles = math.max(1,
        math.min(HARD_MAX_OUTPUT_TRIANGLES, requested_triangles))
    local resolved_vertices = math.floor(tonumber(
        job and job.max_resolved_vertices) or HARD_MAX_OUTPUT_VERTICES)
    resolved_vertices = math.max(3,
        math.min(HARD_MAX_OUTPUT_VERTICES, resolved_vertices))
    local resolved_triangles = math.floor(tonumber(
        job and job.max_resolved_triangles) or HARD_MAX_OUTPUT_TRIANGLES)
    resolved_triangles = math.max(1,
        math.min(HARD_MAX_OUTPUT_TRIANGLES, resolved_triangles))
    return {
        container_count = 0,
        instance_count = 0,
        nested_and_local_bytes = 0,
        local_dependency_count = 0,
        local_reference_seen = {},
        local_reference_cache = {},
        local_active_paths = {},
        max_output_vertices = requested_vertices,
        max_output_triangles = requested_triangles,
        max_resolved_vertices = resolved_vertices,
        max_resolved_triangles = resolved_triangles,
        resolved_vertex_count = 0,
        resolved_triangle_count = 0,
        resolved_vertex_stream_seen = setmetatable({}, { __mode = "k" }),
        resolved_triangle_stream_seen = setmetatable({}, { __mode = "k" }),
    }
end

local function charge_resolved_mesh(state, parsed)
    if type(parsed) ~= "table" then return true end
    local vertex_count, triangle_count, vertex_keys, triangle_keys, reason =
        StreamAccounting.collect(parsed,
            state.resolved_vertex_stream_seen,
            state.resolved_triangle_stream_seen)
    if vertex_count == nil then
        return false, reason == "retained_stream_limit"
            and "resolved_stream_limit" or "resolved_geometry_invalid"
    end
    if state.resolved_vertex_count + vertex_count
        > state.max_resolved_vertices then
        return false, "resolved_vertex_limit"
    end
    if state.resolved_triangle_count + triangle_count
        > state.max_resolved_triangles then
        return false, "resolved_triangle_limit"
    end
    StreamAccounting.commit(
        state.resolved_vertex_stream_seen,
        state.resolved_triangle_stream_seen,
        vertex_keys, triangle_keys)
    state.resolved_vertex_count = state.resolved_vertex_count + vertex_count
    state.resolved_triangle_count =
        state.resolved_triangle_count + triangle_count
    return true
end

local function validate_output_mesh(state, parsed, prefix)
    local vertex_count, triangle_count, _, _, reason =
        StreamAccounting.collect(parsed)
    if vertex_count == nil then
        return false, reason == "retained_stream_limit"
            and (prefix .. "_stream_limit")
            or (prefix .. "_geometry_invalid")
    end
    if vertex_count > state.max_output_vertices then
        return false, prefix .. "_vertex_limit"
    end
    if triangle_count > state.max_output_triangles then
        return false, prefix .. "_triangle_limit"
    end
    return true
end

local function charge_nested_bytes(state, byte_count)
    byte_count = math.max(0, tonumber(byte_count) or 0)
    if state.nested_and_local_bytes + byte_count
        > MAX_NESTED_AND_LOCAL_BYTES then
        return false, "nested_dependency_byte_limit"
    end
    state.nested_and_local_bytes = state.nested_and_local_bytes + byte_count
    return true
end

local function read_container(data, state)
    local is_binary = data:sub(1, #constants.BINARY_SIGNATURE)
        == constants.BINARY_SIGNATURE
    local is_xml = not is_binary and looks_like_xml(data)
    if not is_binary and not is_xml then return nil, "not_container" end
    if state.container_count >= MAX_CONTAINER_COUNT then
        return nil, "container_count_limit"
    end
    if is_xml and #data > MAX_XML_CONTAINER_BYTES then
        return nil, "xml_container_byte_limit"
    end

    local remaining = MAX_CONTAINER_INSTANCES - state.instance_count
    if remaining <= 0 then return nil, "container_instance_limit" end
    local predicted_count = nil
    if is_xml then
        predicted_count = count_xml_items_bounded(data, remaining)
        if predicted_count > remaining then
            return nil, "container_instance_limit"
        end
    end

    state.container_count = state.container_count + 1
    local ok, file
    if is_binary then
        ok, file = pcall(binary.read, data, {
            formatKind = ".rbxm",
            source_name = "remote-mesh.asset",
            limits = {
                max_classes = 20000,
                max_instances = remaining,
                max_chunk_bytes = MAX_BINARY_CHUNK_BYTES,
                max_decompressed_bytes = MAX_DECOMPRESSED_BYTES,
            },
        })
    else
        ok, file = pcall(xml.read, data, {
            formatKind = ".rbxmx",
            source_name = "remote-mesh.asset",
        })
    end
    if not ok or type(file) ~= "table" then
        return nil, "container_parse_failed"
    end
    local instance_count = type(file.instances) == "table"
        and #file.instances or predicted_count or 0
    if state.instance_count + instance_count > MAX_CONTAINER_INSTANCES then
        return nil, "container_instance_limit"
    end
    state.instance_count = state.instance_count + instance_count
    return file
end

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function extract_asset_id(reference)
    reference = trim(reference)
    if reference:match("^%d+$") then return reference end
    local lower = reference:lower()
    return lower:match("^rbxassetid://(%d+)")
        or lower:match("[?&]id=(%d+)")
        or lower:match("/asset/(%d+)")
end

local function safe_relative_path(value)
    value = trim(value):gsub("\\", "/"):gsub("^/+", "")
    if value == "" or value:find(":", 1, true) then return nil end
    local parts = {}
    for segment in value:gmatch("[^/]+") do
        if segment == ".." then return nil end
        if segment ~= "." and segment ~= "" then
            if not segment:match("^[%w%._%-%s]+$") then return nil end
            parts[#parts + 1] = segment
        end
    end
    return #parts > 0 and table.concat(parts, "/") or nil
end

local AssetPaths = require("engine/graphics/rbx/runtime/asset_paths")

local function local_candidates(reference, asset_type, job)
    local candidates = AssetPaths.candidates(reference, asset_type, job)
    local safe = {}
    for _, path in ipairs(candidates) do
        local relative = safe_relative_path(path)
        if relative then safe[#safe + 1] = relative end
    end
    return safe
end

local function filesystem_info(path)
    if love and love.filesystem and love.filesystem.getInfo then
        local ok, info = pcall(love.filesystem.getInfo, path, "file")
        if ok and type(info) == "table" then return info end
    end
    local handle = io and io.open and io.open(path, "rb") or nil
    if not handle then return nil end
    local size = handle:seek("end")
    handle:close()
    return { type = "file", size = size }
end

local function filesystem_read(path)
    if love and love.filesystem and love.filesystem.read then
        local ok, data = pcall(love.filesystem.read, path)
        if ok and type(data) == "string" then return data end
    end
    local handle = io and io.open and io.open(path, "rb") or nil
    if not handle then return nil end
    local data = handle:read("*a")
    handle:close()
    return data
end

local decode_internal

local function resolve_local_mesh(reference, context, job, depth, state)
    reference = trim(reference)
    if reference == "" then
        return { status = "external", reason = "empty_dependency" }
    end
    local asset_type = context and context.asset_type or "mesh"
    local cache_key = asset_type .. "|" .. reference
    local cached = state.local_reference_cache[cache_key]
    if cached then return cached end
    if not state.local_reference_seen[reference] then
        if state.local_dependency_count >= MAX_LOCAL_DEPENDENCIES then
            return { status = "limited", reason = "local_dependency_limit" }
        end
        state.local_reference_seen[reference] = true
        state.local_dependency_count = state.local_dependency_count + 1
    end

    local candidates = local_candidates(reference,
        context and context.asset_type or "mesh", job)
    for index = 1, #candidates do
        local path = candidates[index]
        local info = filesystem_info(path)
        if info and info.type ~= "directory" then
            local size = tonumber(info.size) or 0
            if size > MAX_LOCAL_FILE_BYTES then
                return { status = "limited", reason = "local_file_byte_limit" }
            end
            if state.local_active_paths[path] then
                local result = {
                    status = "external",
                    dependency = {
                        reference = reference,
                        path = path,
                        reason = "local_dependency_cycle",
                    },
                }
                state.local_reference_cache[cache_key] = result
                return result
            end
            local data = filesystem_read(path)
            if type(data) == "string" then
                if #data > MAX_LOCAL_FILE_BYTES then
                    return { status = "limited", reason = "local_file_byte_limit" }
                end
                local charged, charge_reason = charge_nested_bytes(state, #data)
                if not charged then
                    return { status = "limited", reason = charge_reason }
                end
                state.local_active_paths[path] = true
                local nested_job = {
                    asset_id = extract_asset_id(reference),
                    asset_type = asset_type,
                    decode_policy = job.decode_policy,
                    map_path = job.map_path,
                    asset_root = job.asset_root,
                    max_output_vertices = state.max_output_vertices,
                    max_output_triangles = state.max_output_triangles,
                }
                local parsed, reason = decode_internal(
                    data, nested_job, depth + 1, state, false)
                state.local_active_paths[path] = nil
                if parsed then
                    local result = { status = "ready", mesh = parsed, path = path }
                    state.local_reference_cache[cache_key] = result
                    return result
                end
                if is_limit_reason(reason) then
                    return { status = "limited", reason = reason }
                end
                local result = {
                    status = "external",
                    dependency = {
                        reference = reference,
                        path = path,
                        reason = "local_dependency_decode_failed",
                        decode_reason = reason,
                    },
                }
                state.local_reference_cache[cache_key] = result
                return result
            end
        end
    end

    local result = {
        status = "external",
        dependency = {
            reference = reference,
            reason = #candidates > 0
                and "local_dependency_missing" or "external_dependency",
        },
    }
    state.local_reference_cache[cache_key] = result
    return result
end

local function decode_container(data, job, depth, state)
    local file, reason = read_container(data, state)
    if not file then return nil, reason end
    local stack = {}
    for index = #(file.roots or {}), 1, -1 do
        stack[#stack + 1] = file.roots[index]
    end
    local visited = 0
    local best = nil
    local unsupported_reason = nil
    local external_references, external_seen = {}, {}
    local function record_external_reason(external_reason)
        local prefix = "csg_external_dependencies:"
        if type(external_reason) ~= "string"
            or external_reason:sub(1, #prefix) ~= prefix then
            return false
        end
        local suffix = external_reason:sub(#prefix + 1)
        for reference in suffix:gmatch("[^,]+") do
            if reference ~= "" and not external_seen[reference] then
                external_seen[reference] = true
                external_references[#external_references + 1] = reference
            end
        end
        return true
    end
    while #stack > 0 do
        local instance = stack[#stack]
        stack[#stack] = nil
        visited = visited + 1
        if visited > MAX_CONTAINER_INSTANCES then
            return nil, "container_instance_limit"
        end
        if type(instance) == "table" then
            local properties = instance.properties or {}
            for field_index = 1, #EMBEDDED_FIELDS do
                local bytes = dom.property_to_string(
                    properties[EMBEDDED_FIELDS[field_index]])
                if type(bytes) == "string" and bytes ~= "" then
                    local candidate, nested_reason = decode_internal(
                        bytes, job, depth + 1, state, true)
                    if not candidate and is_limit_reason(nested_reason) then
                        return nil, nested_reason
                    end
                    if not candidate and is_unsupported_csg_reason(
                            nested_reason) then
                        -- keep scanning: an authoritative score-4 render CSG
                        -- payload may live in a later legacy field. if none is
                        -- found, this blocker wins over every lower fallback
                        unsupported_reason = unsupported_reason or nested_reason
                    end
                    if not candidate then
                        record_external_reason(nested_reason)
                    end
                    best = prefer(best, candidate)
                    -- a canonical render CSG payload is authoritative over
                    -- ChildData composition and every fallback source
                    if score(best) >= 4 then return best end
                end
            end
            local children = instance.children or {}
            for index = #children, 1, -1 do
                stack[#stack + 1] = children[index]
            end
        end
    end

    if unsupported_reason then return nil, unsupported_reason end

    if job.asset_type == "csg_mesh" then
        local remaining_resolved_vertices = math.max(0,
            state.max_resolved_vertices - state.resolved_vertex_count)
        if remaining_resolved_vertices < 3 then
            return nil, "resolved_vertex_limit"
        end
        local composed = Composer.compose_file(file, {
            allow_provisional_geometry = false,
            limits = {
                max_parts = MAX_CSG_PARTS,
                max_output_vertices = math.min(state.max_output_vertices,
                    remaining_resolved_vertices),
                max_dependencies = MAX_LOCAL_DEPENDENCIES,
            },
            decode_payload = function(bytes)
                local candidate, nested_reason = decode_internal(
                    bytes, job, depth + 1, state, true)
                if candidate then return candidate end
                return nil, nested_reason
            end,
            resolve_mesh = function(reference, context)
                return resolve_local_mesh(
                    reference, context, job, depth, state)
            end,
        })
        if composed.status == "limited" then
            return nil, composed.reason or "csg_composition_limit"
        end
        if composed.status == "unsupported" then
            return nil, composed.reason
                or "csg_boolean_operation_unsupported:unknown"
        end
        if composed.status == "ready" then
            local output_ok, output_reason = validate_output_mesh(
                state, composed.mesh, "csg_output")
            if not output_ok then return nil, output_reason end
            local charged, charge_reason = charge_resolved_mesh(
                state, composed.mesh)
            if not charged then return nil, charge_reason end
            best = prefer(best, composed.mesh)
        elseif composed.status == "provisional" then
            for index = 1, #(composed.dependencies or {}) do
                local reference = tostring(
                    composed.dependencies[index].reference or "unknown")
                if not external_seen[reference] then
                    external_seen[reference] = true
                    external_references[#external_references + 1] = reference
                end
            end
        end
    end
    if #external_references > 0 then
        return nil, "csg_external_dependencies:"
            .. table.concat(external_references, ",")
    end
    return best, best and nil or "container_holds_no_mesh"
end

decode_internal = function(data, job, depth, state, charge_nested)
    if type(data) ~= "string" or data == "" then
        return nil, "source_payload_missing"
    end
    depth = depth or 0
    if charge_nested then
        local charged, reason = charge_nested_bytes(state, #data)
        if not charged then return nil, reason end
    end

    local decompressed, gzip_reason, was_gzip = maybe_gzip(data)
    -- Bytes positively identified as gzip must never fall through to the mesh
    -- or model parsers after a malformed, ambiguous, or unavailable inflate
    if was_gzip and not decompressed then return nil, gzip_reason end
    if decompressed and decompressed ~= data then
        local charged, reason = charge_nested_bytes(state, #decompressed)
        if not charged then return nil, reason end
        local parsed, nested_reason = decode_internal(
            decompressed, job, depth + 1, state, false)
        if parsed then return parsed end
        if is_limit_reason(nested_reason) then return nil, nested_reason end
    end

    local policy = tostring(job and job.decode_policy or "")
    local parsed, reason, info = mesh.parse(data, {
        crease_degrees = 65,
        accurate_face_axes = policy:find("accurate_axes", 1, true) ~= nil,
        max_render_lod_vertices = state.max_output_vertices,
        max_render_lod_triangles = state.max_output_triangles,
    })
    if parsed then
        if parsed.render_lod_limit_reason then
            return nil, parsed.render_lod_limit_reason
        end
        local output_ok, output_reason = validate_output_mesh(
            state, parsed, "mesh_output")
        if not output_ok then return nil, output_reason end
        local charged, charge_reason = charge_resolved_mesh(state, parsed)
        if not charged then return nil, charge_reason end
        return parsed
    end
    if depth >= MAX_CONTAINER_DEPTH then
        return nil, "container_depth_limit", info
    end
    local nested, nested_reason = decode_container(data, job, depth, state)
    if nested then
        local charged, charge_reason = charge_resolved_mesh(state, nested)
        if not charged then return nil, charge_reason end
        return nested
    end
    return nil, nested_reason or reason or gzip_reason
        or "mesh_decode_failed", info
end

function Decoder.decode_remote_mesh(data, job)
    job = job or {}
    local state = new_state(job)
    local parsed, reason = decode_internal(data, job, 0, state, false)
    if parsed then return parsed end
    -- Payload bytes from a successful immutable asset response do not become
    -- valid by retrying the same decoder. Network/cache failures are retried by
    -- the acquisition manager before this module is invoked
    return nil, tostring(reason or "mesh_decode_failed"), false
end

return Decoder
