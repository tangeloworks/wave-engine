-- worker-safe contact-separation AO kernel
--
-- Bounds cross the thread boundary as float64 ByteData. Float64 is deliberate:
-- render bounds are Lua numbers, and reducing them to float32 changes cell and
-- face-epsilon decisions on real maps. Pair ownership is partitioned by the
-- later entry's input index. every pair is therefore evaluated exactly once,
-- while the per-part max combine makes merging worker packets order-independent

local ContactAO = {}

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok or type(ffi) ~= "table" then
    ffi_ok = false
    ffi = nil
end

local INPUT_MAGIC = 0x43414f31 -- "CAO1"
local OUTPUT_MAGIC = 0x43414f52 -- "CAOR"
local FORMAT_VERSION = 1
local HEADER_BYTES = 32
local INPUT_STRIDE_BYTES = 6 * 8
local OUTPUT_STRIDE_BYTES = 4 * 8

local DEFAULT_MAX_PARTS = 250000
local DEFAULT_MAX_INPUT_BYTES = 64 * 1024 * 1024
local DEFAULT_MAX_OUTPUT_BYTES = 192 * 1024 * 1024
local DEFAULT_MAX_GRID_REFERENCES = 500000
local HARD_MAX_GRID_REFERENCES = 2000000
local DEFAULT_MAX_PAIR_EVALS = 5000000
local HARD_MAX_PAIR_EVALS = 50000000
local DEFAULT_MAX_ABS_CELL_COORDINATE = 10000000
local MAX_WORKERS = 3

local GRID_CELL_SIZE = 8
local GRID_LARGE_PART_CELL_LIMIT = 128
local FACE_EPSILON = 0.75

ContactAO.INPUT_MAGIC = INPUT_MAGIC
ContactAO.OUTPUT_MAGIC = OUTPUT_MAGIC
ContactAO.FORMAT_VERSION = FORMAT_VERSION
ContactAO.HEADER_BYTES = HEADER_BYTES
ContactAO.INPUT_STRIDE_BYTES = INPUT_STRIDE_BYTES
ContactAO.OUTPUT_STRIDE_BYTES = OUTPUT_STRIDE_BYTES
ContactAO.DEFAULT_MAX_PARTS = DEFAULT_MAX_PARTS
ContactAO.DEFAULT_MAX_INPUT_BYTES = DEFAULT_MAX_INPUT_BYTES
ContactAO.DEFAULT_MAX_OUTPUT_BYTES = DEFAULT_MAX_OUTPUT_BYTES
ContactAO.DEFAULT_MAX_GRID_REFERENCES = DEFAULT_MAX_GRID_REFERENCES
ContactAO.HARD_MAX_GRID_REFERENCES = HARD_MAX_GRID_REFERENCES
ContactAO.DEFAULT_MAX_PAIR_EVALS = DEFAULT_MAX_PAIR_EVALS
ContactAO.HARD_MAX_PAIR_EVALS = HARD_MAX_PAIR_EVALS
ContactAO.DEFAULT_MAX_ABS_CELL_COORDINATE =
    DEFAULT_MAX_ABS_CELL_COORDINATE
ContactAO.MAX_WORKERS = MAX_WORKERS
ContactAO.GRID_CELL_SIZE = GRID_CELL_SIZE
ContactAO.GRID_LARGE_PART_CELL_LIMIT = GRID_LARGE_PART_CELL_LIMIT
ContactAO.FACE_EPSILON = FACE_EPSILON

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function integer(value)
    return finite(value) and value >= 0 and value == math.floor(value)
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or 0
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function data_size(data)
    if not data or type(data.getSize) ~= "function" then
        return nil
    end
    local ok, size = pcall(data.getSize, data)
    if not ok or not integer(size) then return nil end
    return size
end

local function data_pointer(data)
    if not ffi_ok or not data or type(data.getFFIPointer) ~= "function" then
        return nil
    end
    local ok, pointer = pcall(data.getFFIPointer, data)
    if not ok or pointer == nil then return nil end
    return ffi.cast("uint8_t*", pointer)
end

local function bounded_integer(value, fallback, minimum, maximum)
    value = tonumber(value)
    if not integer(value) then value = fallback end
    if value < minimum then value = minimum end
    if value > maximum then value = maximum end
    return value
end

local function checked_packet_bytes(count, stride, max_bytes)
    if not integer(count) then return nil, "invalid_count" end
    local bytes = HEADER_BYTES + count * stride
    if not integer(bytes) or bytes > max_bytes then
        return nil, "byte_cap_exceeded"
    end
    return bytes
end

local function new_byte_data(bytes)
    if not love or not love.data or type(love.data.newByteData) ~= "function" then
        return nil, "bytedata_unavailable"
    end
    local ok, data = pcall(love.data.newByteData, bytes)
    if not ok or not data then
        return nil, "bytedata_allocation_failed"
    end
    return data
end

local function write_input_header(pointer, count, generation)
    local header = ffi.cast("uint32_t*", pointer)
    header[0] = INPUT_MAGIC
    header[1] = FORMAT_VERSION
    header[2] = count
    header[3] = INPUT_STRIDE_BYTES
    header[4] = generation
    header[5] = 0
    header[6] = 0
    header[7] = 0
end

local function write_output_header(pointer, count, generation,
        worker_index, worker_count, range_start, range_end)
    local header = ffi.cast("uint32_t*", pointer)
    header[0] = OUTPUT_MAGIC
    header[1] = FORMAT_VERSION
    header[2] = count
    header[3] = OUTPUT_STRIDE_BYTES
    header[4] = generation
    header[5] = worker_index
    header[6] = worker_count
    -- empty canonical ranges use start=end+1, zero entries encode 1,0
    header[7] = range_start
    -- the 32-byte header has no ninth uint32. Range end is deterministic from
    -- count/index/count, so it is validated rather than serialized
end

local function canonical_range(count, worker_index, worker_count)
    local range_start = math.floor((worker_index - 1) * count / worker_count) + 1
    local range_end = math.floor(worker_index * count / worker_count)
    return range_start, range_end
end

ContactAO.canonical_range = canonical_range

function ContactAO.pack_entries(entries, options)
    options = options or {}
    if not ffi_ok then return nil, "ffi_unavailable" end
    if type(entries) ~= "table" then return nil, "entries_not_table" end

    local count = #entries
    local max_parts = bounded_integer(options.max_parts,
        DEFAULT_MAX_PARTS, 0, DEFAULT_MAX_PARTS)
    if count > max_parts then return nil, "part_cap_exceeded" end
    local max_bytes = bounded_integer(options.max_input_bytes,
        DEFAULT_MAX_INPUT_BYTES, HEADER_BYTES, DEFAULT_MAX_INPUT_BYTES)
    local bytes, bytes_error = checked_packet_bytes(
        count, INPUT_STRIDE_BYTES, max_bytes)
    if not bytes then return nil, bytes_error end
    local generation = bounded_integer(options.generation, 0, 0, 0xffffffff)

    -- validate before allocating so hostile bounds cannot pressure native memory
    for index = 1, count do
        local entry = entries[index]
        if type(entry) ~= "table" then return nil, "invalid_entry" end
        local min_x, min_y, min_z = tonumber(entry.min_x), tonumber(entry.min_y), tonumber(entry.min_z)
        local max_x, max_y, max_z = tonumber(entry.max_x), tonumber(entry.max_y), tonumber(entry.max_z)
        if not (finite(min_x) and finite(min_y) and finite(min_z)
            and finite(max_x) and finite(max_y) and finite(max_z)) then
            return nil, "non_finite_entry"
        end
        if not (min_x < max_x and min_y < max_y and min_z < max_z) then
            return nil, "degenerate_entry"
        end
    end

    local data, allocation_error = new_byte_data(bytes)
    if not data then return nil, allocation_error end
    local pointer = data_pointer(data)
    if not pointer then
        if data.release then pcall(data.release, data) end
        return nil, "bytedata_pointer_unavailable"
    end
    write_input_header(pointer, count, generation)
    local values = ffi.cast("double*", pointer + HEADER_BYTES)
    for index = 1, count do
        local entry = entries[index]
        local offset = (index - 1) * 6
        values[offset] = tonumber(entry.min_x)
        values[offset + 1] = tonumber(entry.min_y)
        values[offset + 2] = tonumber(entry.min_z)
        values[offset + 3] = tonumber(entry.max_x)
        values[offset + 4] = tonumber(entry.max_y)
        values[offset + 5] = tonumber(entry.max_z)
    end
    return data, {
        count = count,
        generation = generation,
        bytes = bytes,
    }
end

function ContactAO.validate_input(data, options)
    options = options or {}
    if not ffi_ok then return nil, "ffi_unavailable" end
    local size = data_size(data)
    if not size then return nil, "invalid_bytedata" end
    local max_bytes = bounded_integer(options.max_input_bytes,
        DEFAULT_MAX_INPUT_BYTES, HEADER_BYTES, DEFAULT_MAX_INPUT_BYTES)
    if size < HEADER_BYTES or size > max_bytes then
        return nil, size > max_bytes and "byte_cap_exceeded" or "truncated_header"
    end
    local pointer = data_pointer(data)
    if not pointer then return nil, "bytedata_pointer_unavailable" end
    local header = ffi.cast("const uint32_t*", pointer)
    local magic = tonumber(header[0])
    local version = tonumber(header[1])
    local count = tonumber(header[2])
    local stride = tonumber(header[3])
    local generation = tonumber(header[4])
    if magic ~= INPUT_MAGIC then return nil, "input_magic_mismatch" end
    if version ~= FORMAT_VERSION then return nil, "input_version_mismatch" end
    if stride ~= INPUT_STRIDE_BYTES then return nil, "input_stride_mismatch" end
    local max_parts = bounded_integer(options.max_parts,
        DEFAULT_MAX_PARTS, 0, DEFAULT_MAX_PARTS)
    if not integer(count) or count > max_parts then return nil, "part_cap_exceeded" end
    local expected, bytes_error = checked_packet_bytes(
        count, INPUT_STRIDE_BYTES, max_bytes)
    if not expected then return nil, bytes_error end
    if size ~= expected then return nil, "input_size_mismatch" end
    if options.generation ~= nil
        and generation ~= bounded_integer(options.generation, 0, 0, 0xffffffff) then
        return nil, "input_generation_mismatch"
    end
    local values = ffi.cast("const double*", pointer + HEADER_BYTES)
    for index = 1, count do
        local offset = (index - 1) * 6
        local min_x, min_y, min_z = values[offset], values[offset + 1], values[offset + 2]
        local max_x, max_y, max_z = values[offset + 3], values[offset + 4], values[offset + 5]
        if not (finite(tonumber(min_x)) and finite(tonumber(min_y))
            and finite(tonumber(min_z)) and finite(tonumber(max_x))
            and finite(tonumber(max_y)) and finite(tonumber(max_z))) then
            return nil, "non_finite_input_payload"
        end
        if not (min_x < max_x and min_y < max_y and min_z < max_z) then
            return nil, "degenerate_input_payload"
        end
    end
    return {
        data = data,
        pointer = pointer,
        values = values,
        count = count,
        generation = generation,
        bytes = size,
    }
end

local function validate_output(data, options)
    options = options or {}
    if not ffi_ok then return nil, "ffi_unavailable" end
    local size = data_size(data)
    if not size then return nil, "invalid_bytedata" end
    local max_bytes = bounded_integer(options.max_output_bytes,
        DEFAULT_MAX_OUTPUT_BYTES, HEADER_BYTES, DEFAULT_MAX_OUTPUT_BYTES)
    if size < HEADER_BYTES or size > max_bytes then
        return nil, size > max_bytes and "byte_cap_exceeded" or "truncated_header"
    end
    local pointer = data_pointer(data)
    if not pointer then return nil, "bytedata_pointer_unavailable" end
    local header = ffi.cast("const uint32_t*", pointer)
    local magic = tonumber(header[0])
    local version = tonumber(header[1])
    local count = tonumber(header[2])
    local stride = tonumber(header[3])
    local generation = tonumber(header[4])
    local worker_index = tonumber(header[5])
    local worker_count = tonumber(header[6])
    local range_start = tonumber(header[7])
    if magic ~= OUTPUT_MAGIC then return nil, "output_magic_mismatch" end
    if version ~= FORMAT_VERSION then return nil, "output_version_mismatch" end
    if stride ~= OUTPUT_STRIDE_BYTES then return nil, "output_stride_mismatch" end
    if not integer(count) then return nil, "invalid_output_count" end
    local expected, bytes_error = checked_packet_bytes(
        count, OUTPUT_STRIDE_BYTES, max_bytes)
    if not expected then return nil, bytes_error end
    if size ~= expected then return nil, "output_size_mismatch" end
    if not integer(worker_count) or worker_count < 1 or worker_count > MAX_WORKERS
        or not integer(worker_index) or worker_index < 1 or worker_index > worker_count then
        return nil, "invalid_worker_identity"
    end
    local canonical_start, canonical_end = canonical_range(count, worker_index, worker_count)
    if range_start ~= canonical_start then return nil, "output_range_mismatch" end
    if options.count ~= nil and count ~= options.count then return nil, "output_count_mismatch" end
    if options.generation ~= nil and generation ~= options.generation then
        return nil, "output_generation_mismatch"
    end
    if options.worker_count ~= nil and worker_count ~= options.worker_count then
        return nil, "output_worker_count_mismatch"
    end
    local values = ffi.cast("const double*", pointer + HEADER_BYTES)
    if options.validate_payload == true then
        for offset = 0, count * 4 - 1 do
            local value = tonumber(values[offset])
            if not finite(value) or value < 0 or value > 1 then
                return nil, "invalid_output_payload"
            end
        end
    end
    return {
        data = data,
        pointer = pointer,
        values = values,
        count = count,
        generation = generation,
        worker_index = worker_index,
        worker_count = worker_count,
        range_start = canonical_start,
        range_end = canonical_end,
        bytes = size,
    }
end

ContactAO.validate_output = validate_output

local function grid_key(cx, cy, cz)
    -- this intentionally reproduces the renderer's numeric Teschner hash,
    -- including collisions, candidate AABBs are rechecked by the kernel
    return (cx * 73856093) + (cy * 19349663) + (cz * 83492791)
end

local function overlap_len(a0, a1, b0, b1)
    local lo = math.max(a0, b0)
    local hi = math.min(a1, b1)
    return math.max(0, hi - lo)
end

local function scaled_strength(area_fraction, gap_factor, scale, minimum, maximum)
    area_fraction = clamp(area_fraction, 0, 1)
    if area_fraction <= 0.035 then return 0 end
    return clamp(area_fraction * (tonumber(gap_factor) or 0) * scale,
        minimum, maximum)
end

-- internal field order in every result row: top, bottom, side, overall max
local TOP, BOTTOM, SIDE, OVERALL = 0, 1, 2, 3

local function set_face(output, index, field, strength)
    strength = clamp(strength, 0, 1)
    if strength <= 0 then return end
    local offset = (index - 1) * 4
    if strength > output[offset + field] then
        output[offset + field] = strength
    end
    if strength > output[offset + OVERALL] then
        output[offset + OVERALL] = strength
    end
end

local function note_vertical(output, lower, upper,
        lower_strength, upper_strength, stats)
    if (tonumber(lower_strength) or 0) <= 0
        and (tonumber(upper_strength) or 0) <= 0 then
        return
    end
    set_face(output, lower, TOP, lower_strength)
    set_face(output, upper, BOTTOM, upper_strength)
    stats.contact_top_count = stats.contact_top_count + 1
    stats.contact_pair_count = stats.contact_pair_count + 1
end

local function note_side(output, a, b, a_strength, b_strength, stats)
    if (tonumber(a_strength) or 0) <= 0
        and (tonumber(b_strength) or 0) <= 0 then
        return
    end
    set_face(output, a, SIDE, a_strength)
    set_face(output, b, SIDE, b_strength)
    stats.contact_side_count = stats.contact_side_count + 1
    stats.contact_pair_count = stats.contact_pair_count + 1
end

local function eval_pair(input, output, a_index, b_index, stats)
    if a_index == b_index then return true end
    if stats.pair_eval_count >= stats.max_pair_evals then
        return false
    end
    stats.pair_eval_count = stats.pair_eval_count + 1
    local ao = (a_index - 1) * 6
    local bo = (b_index - 1) * 6
    local aminx, aminy, aminz = input[ao], input[ao + 1], input[ao + 2]
    local amaxx, amaxy, amaxz = input[ao + 3], input[ao + 4], input[ao + 5]
    local bminx, bminy, bminz = input[bo], input[bo + 1], input[bo + 2]
    local bmaxx, bmaxy, bmaxz = input[bo + 3], input[bo + 4], input[bo + 5]
    local x_overlap = overlap_len(aminx, amaxx, bminx, bmaxx)
    local y_overlap = overlap_len(aminy, amaxy, bminy, bmaxy)
    local z_overlap = overlap_len(aminz, amaxz, bminz, bmaxz)
    local xz = x_overlap > 0.02 and z_overlap > 0.02
    if not (xz or (y_overlap > 0.02
        and (x_overlap > 0.02 or z_overlap > 0.02))) then
        return true
    end

    local ax = math.max(0.001, amaxx - aminx)
    local ay = math.max(0.001, amaxy - aminy)
    local az = math.max(0.001, amaxz - aminz)
    local bx = math.max(0.001, bmaxx - bminx)
    local by = math.max(0.001, bmaxy - bminy)
    local bz = math.max(0.001, bmaxz - bminz)
    local acy = (aminy + amaxy) * 0.5
    local bcy = (bminy + bmaxy) * 0.5

    if xz then
        local a_area_factor = math.sqrt(math.max(0,
            clamp(x_overlap / ax, 0, 1) * clamp(z_overlap / az, 0, 1)))
        local b_area_factor = math.sqrt(math.max(0,
            clamp(x_overlap / bx, 0, 1) * clamp(z_overlap / bz, 0, 1)))
        local gap_ab = bminy - amaxy
        if acy <= bcy and gap_ab >= -FACE_EPSILON and gap_ab <= FACE_EPSILON then
            local gap_factor = 1 - clamp(math.max(0, gap_ab) / FACE_EPSILON, 0, 1)
            note_vertical(output, a_index, b_index,
                scaled_strength(a_area_factor, gap_factor, 0.62, 0.08, 0.58),
                scaled_strength(b_area_factor, gap_factor, 0.90, 0.18, 0.82),
                stats)
        end
        local gap_ba = aminy - bmaxy
        if bcy <= acy and gap_ba >= -FACE_EPSILON and gap_ba <= FACE_EPSILON then
            local gap_factor = 1 - clamp(math.max(0, gap_ba) / FACE_EPSILON, 0, 1)
            note_vertical(output, b_index, a_index,
                scaled_strength(b_area_factor, gap_factor, 0.62, 0.08, 0.58),
                scaled_strength(a_area_factor, gap_factor, 0.90, 0.18, 0.82),
                stats)
        end
    end

    if y_overlap > 0.02 then
        if z_overlap > 0.02 then
            local a_area_factor = math.sqrt(math.max(0,
                clamp(y_overlap / ay, 0, 1) * clamp(z_overlap / az, 0, 1)))
            local b_area_factor = math.sqrt(math.max(0,
                clamp(y_overlap / by, 0, 1) * clamp(z_overlap / bz, 0, 1)))
            local gap_ab = bminx - amaxx
            local gap_ba = aminx - bmaxx
            if gap_ab >= -FACE_EPSILON and gap_ab <= FACE_EPSILON then
                local gap_factor = 1 - clamp(math.max(0, gap_ab) / FACE_EPSILON, 0, 1)
                note_side(output, a_index, b_index,
                    scaled_strength(a_area_factor, gap_factor, 0.78, 0.10, 0.68),
                    scaled_strength(b_area_factor, gap_factor, 0.78, 0.10, 0.68), stats)
            elseif gap_ba >= -FACE_EPSILON and gap_ba <= FACE_EPSILON then
                local gap_factor = 1 - clamp(math.max(0, gap_ba) / FACE_EPSILON, 0, 1)
                note_side(output, a_index, b_index,
                    scaled_strength(a_area_factor, gap_factor, 0.78, 0.10, 0.68),
                    scaled_strength(b_area_factor, gap_factor, 0.78, 0.10, 0.68), stats)
            end
        end
        if x_overlap > 0.02 then
            local a_area_factor = math.sqrt(math.max(0,
                clamp(y_overlap / ay, 0, 1) * clamp(x_overlap / ax, 0, 1)))
            local b_area_factor = math.sqrt(math.max(0,
                clamp(y_overlap / by, 0, 1) * clamp(x_overlap / bx, 0, 1)))
            local gap_ab = bminz - amaxz
            local gap_ba = aminz - bmaxz
            if gap_ab >= -FACE_EPSILON and gap_ab <= FACE_EPSILON then
                local gap_factor = 1 - clamp(math.max(0, gap_ab) / FACE_EPSILON, 0, 1)
                note_side(output, a_index, b_index,
                    scaled_strength(a_area_factor, gap_factor, 0.78, 0.10, 0.68),
                    scaled_strength(b_area_factor, gap_factor, 0.78, 0.10, 0.68), stats)
            elseif gap_ba >= -FACE_EPSILON and gap_ba <= FACE_EPSILON then
                local gap_factor = 1 - clamp(math.max(0, gap_ba) / FACE_EPSILON, 0, 1)
                note_side(output, a_index, b_index,
                    scaled_strength(a_area_factor, gap_factor, 0.78, 0.10, 0.68),
                    scaled_strength(b_area_factor, gap_factor, 0.78, 0.10, 0.68), stats)
            end
        end
    end
    return true
end

local function entry_cell_range(input, index, max_abs_cell_coordinate)
    local offset = (index - 1) * 6
    local inv_cell = 1 / GRID_CELL_SIZE
    local min_cx = math.floor((input[offset] - FACE_EPSILON) * inv_cell)
    local max_cx = math.floor((input[offset + 3] + FACE_EPSILON) * inv_cell)
    local min_cy = math.floor((input[offset + 1] - FACE_EPSILON) * inv_cell)
    local max_cy = math.floor((input[offset + 4] + FACE_EPSILON) * inv_cell)
    local min_cz = math.floor((input[offset + 2] - FACE_EPSILON) * inv_cell)
    local max_cz = math.floor((input[offset + 5] + FACE_EPSILON) * inv_cell)
    if math.abs(min_cx) > max_abs_cell_coordinate
        or math.abs(max_cx) > max_abs_cell_coordinate
        or math.abs(min_cy) > max_abs_cell_coordinate
        or math.abs(max_cy) > max_abs_cell_coordinate
        or math.abs(min_cz) > max_abs_cell_coordinate
        or math.abs(max_cz) > max_abs_cell_coordinate then
        return nil, "cell_coordinate_cap_exceeded"
    end
    local cell_count = math.max(1, max_cx - min_cx + 1)
        * math.max(1, max_cy - min_cy + 1)
        * math.max(1, max_cz - min_cz + 1)
    return min_cx, max_cx, min_cy, max_cy, min_cz, max_cz,
        cell_count <= GRID_LARGE_PART_CELL_LIMIT
end

function ContactAO.compute_packed(input_data, worker_index, worker_count, options)
    options = options or {}
    worker_count = bounded_integer(worker_count, 1, 1, MAX_WORKERS)
    worker_index = bounded_integer(worker_index, 1, 1, worker_count)
    local input, input_error = ContactAO.validate_input(input_data, options)
    if not input then return nil, input_error end
    local count = input.count
    local range_start, range_end = canonical_range(count, worker_index, worker_count)
    local max_output_bytes = bounded_integer(options.max_output_bytes,
        DEFAULT_MAX_OUTPUT_BYTES, HEADER_BYTES, DEFAULT_MAX_OUTPUT_BYTES)
    local output_bytes, bytes_error = checked_packet_bytes(
        count, OUTPUT_STRIDE_BYTES, max_output_bytes)
    if not output_bytes then return nil, bytes_error end
    local output_data, allocation_error = new_byte_data(output_bytes)
    if not output_data then return nil, allocation_error end
    local output_pointer = data_pointer(output_data)
    if not output_pointer then
        if output_data.release then pcall(output_data.release, output_data) end
        return nil, "bytedata_pointer_unavailable"
    end
    write_output_header(output_pointer, count, input.generation,
        worker_index, worker_count, range_start, range_end)
    local output = ffi.cast("double*", output_pointer + HEADER_BYTES)
    for offset = 0, count * 4 - 1 do output[offset] = 0 end
    local max_grid_references = bounded_integer(options.max_grid_references,
        DEFAULT_MAX_GRID_REFERENCES, 0, HARD_MAX_GRID_REFERENCES)
    local max_pair_evals = bounded_integer(options.max_pair_evals,
        DEFAULT_MAX_PAIR_EVALS, 0, HARD_MAX_PAIR_EVALS)
    local max_abs_cell_coordinate = bounded_integer(
        options.max_abs_cell_coordinate,
        DEFAULT_MAX_ABS_CELL_COORDINATE, 1,
        DEFAULT_MAX_ABS_CELL_COORDINATE)

    local stats = {
        part_count = count,
        contact_pair_count = 0,
        contact_top_count = 0,
        contact_side_count = 0,
        pair_eval_count = 0,
        max_pair_evals = max_pair_evals,
        grid_cell_count = 0,
        grid_reference_count = 0,
        max_grid_references = max_grid_references,
        large_part_count = 0,
        cell_size = GRID_CELL_SIZE,
        generation = input.generation,
        worker_index = worker_index,
        worker_count = worker_count,
        worker_compute_ms = 0,
        range_start = range_start,
        range_end = range_end,
    }

    local grid, grid_keys = {}, {}
    local large_entries = {}
    local seen = {}
    local input_values = input.values
    local is_cancelled = type(options.is_cancelled) == "function"
        and options.is_cancelled or nil
    local progress_callback = type(options.progress_callback) == "function"
        and options.progress_callback or nil

    local function abort(reason)
        if output_data then
            if output_data.release then pcall(output_data.release, output_data) end
            output_data = nil
        end
        return nil, reason
    end

    local function add_grid_entry(key, index)
        if stats.grid_reference_count >= max_grid_references then
            return false
        end
        local cell = grid[key]
        if not cell then
            cell = {}
            grid[key] = cell
            grid_keys[#grid_keys + 1] = key
        end
        cell[#cell + 1] = index
        stats.grid_reference_count = stats.grid_reference_count + 1
        return true
    end

    for index = 1, range_end do
        if index % 64 == 0 then
            if is_cancelled and is_cancelled() then
                return abort("cancelled")
            end
            if progress_callback then
                local progress_ok, progress_error = pcall(
                    progress_callback, index, range_end)
                if not progress_ok then
                    return abort("progress_callback_failed:"
                        .. tostring(progress_error))
                end
            end
        end
        local min_cx, max_cx, min_cy, max_cy, min_cz, max_cz, fits_grid =
            entry_cell_range(input_values, index, max_abs_cell_coordinate)
        if not min_cx then return abort(max_cx) end
        if index >= range_start then
            if fits_grid then
                for cx = min_cx, max_cx do
                    for cy = min_cy, max_cy do
                        for cz = min_cz, max_cz do
                            local cell = grid[grid_key(cx, cy, cz)]
                            for cell_index = 1, #(cell or {}) do
                                local candidate = cell[cell_index]
                                if candidate and seen[candidate] ~= index then
                                    seen[candidate] = index
                                    if not eval_pair(input_values, output,
                                        index, candidate, stats) then
                                        return abort("pair_eval_cap_exceeded")
                                    end
                                end
                            end
                        end
                    end
                end
            end
            for large_index = 1, #large_entries do
                local candidate = large_entries[large_index]
                if candidate and seen[candidate] ~= index then
                    seen[candidate] = index
                    if not eval_pair(input_values, output,
                        index, candidate, stats) then
                        return abort("pair_eval_cap_exceeded")
                    end
                end
            end
            if not fits_grid then
                for candidate = 1, index - 1 do
                    if seen[candidate] ~= index then
                        seen[candidate] = index
                        if not eval_pair(input_values, output,
                            index, candidate, stats) then
                            return abort("pair_eval_cap_exceeded")
                        end
                    end
                end
            end
        end

        if fits_grid then
            for cx = min_cx, max_cx do
                for cy = min_cy, max_cy do
                    for cz = min_cz, max_cz do
                        if not add_grid_entry(
                            grid_key(cx, cy, cz), index) then
                            return abort("grid_reference_cap_exceeded")
                        end
                    end
                end
            end
        else
            large_entries[#large_entries + 1] = index
        end
    end

    if is_cancelled and is_cancelled() then
        return abort("cancelled")
    end
    stats.grid_cell_count = #grid_keys
    stats.large_part_count = #large_entries
    stats.structure_complete = range_end == count
    return {
        data = output_data,
        stats = stats,
        generation = input.generation,
        worker_index = worker_index,
        worker_count = worker_count,
        range_start = range_start,
        range_end = range_end,
    }
end

local function safe_release(data)
    if data and type(data.release) == "function" then
        pcall(data.release, data)
    end
end

ContactAO.safe_release = safe_release

function ContactAO.is_work_cap_error(reason)
    reason = tostring(reason or "")
    return reason:find("grid_reference_cap_exceeded", 1, true) ~= nil
        or reason:find("pair_eval_cap_exceeded", 1, true) ~= nil
        or reason:find("cell_coordinate_cap_exceeded", 1, true) ~= nil
end

local function aggregate_stats(values, count, stats)
    local contact_count, contact_sum = 0, 0
    local contact_min, contact_max = 1, 0
    for index = 1, count do
        local amount = clamp(values[(index - 1) * 4 + OVERALL], 0, 1)
        if amount > 0 then
            contact_count = contact_count + 1
            contact_sum = contact_sum + amount
            contact_min = math.min(contact_min, amount)
            contact_max = math.max(contact_max, amount)
        end
    end
    stats.contact_part_count = contact_count
    stats.contact_min = contact_count > 0 and contact_min or 0
    stats.contact_avg = contact_count > 0 and (contact_sum / contact_count) or 0
    stats.contact_max = contact_max
end

function ContactAO.merge_results(result_packets, options)
    options = options or {}
    if type(result_packets) ~= "table" or #result_packets < 1 then
        return nil, "missing_worker_results"
    end
    local worker_count = bounded_integer(options.worker_count,
        #result_packets, 1, MAX_WORKERS)
    if #result_packets ~= worker_count then return nil, "worker_result_count_mismatch" end
    local count = options.count
    local generation = options.generation
    local validated, seen_workers = {}, {}
    for index = 1, #result_packets do
        local packet = result_packets[index]
        local data = type(packet) == "table" and packet.data or packet
        local view, validation_error = validate_output(data, {
            count = count,
            generation = generation,
            worker_count = worker_count,
            max_output_bytes = options.max_output_bytes,
            validate_payload = true,
        })
        if not view then return nil, validation_error end
        count = count or view.count
        generation = generation or view.generation
        if seen_workers[view.worker_index] then return nil, "duplicate_worker_result" end
        seen_workers[view.worker_index] = true
        view.stats = type(packet) == "table" and packet.stats or nil
        validated[view.worker_index] = view
    end
    for worker_index = 1, worker_count do
        if not validated[worker_index] then return nil, "missing_worker_result" end
    end

    -- max_pair_evals is a generation-wide work cap, not a per-thread budget
    -- a partition can leave every worker individually below the limit while
    -- their aggregate exceeds it (six coincident boxes split three ways are
    -- 1/5/9 evaluations). reject before allocating the merged packet so sync,
    -- two-worker, and three-worker execution have the same atomic outcome
    local max_pair_evals = bounded_integer(options.max_pair_evals,
        DEFAULT_MAX_PAIR_EVALS, 0, HARD_MAX_PAIR_EVALS)
    local aggregate_pair_evals = 0
    for worker_index = 1, worker_count do
        local worker_stats = validated[worker_index].stats or {}
        aggregate_pair_evals = aggregate_pair_evals
            + (tonumber(worker_stats.pair_eval_count) or 0)
        if aggregate_pair_evals > max_pair_evals then
            return nil, "pair_eval_cap_exceeded"
        end
    end

    local max_output_bytes = bounded_integer(options.max_output_bytes,
        DEFAULT_MAX_OUTPUT_BYTES, HEADER_BYTES, DEFAULT_MAX_OUTPUT_BYTES)
    local bytes, bytes_error = checked_packet_bytes(
        count, OUTPUT_STRIDE_BYTES, max_output_bytes)
    if not bytes then return nil, bytes_error end
    local merged_data, allocation_error = new_byte_data(bytes)
    if not merged_data then return nil, allocation_error end
    local merged_pointer = data_pointer(merged_data)
    if not merged_pointer then
        safe_release(merged_data)
        return nil, "bytedata_pointer_unavailable"
    end
    write_output_header(merged_pointer, count, generation, 1, 1, 1, count)
    local merged = ffi.cast("double*", merged_pointer + HEADER_BYTES)
    local stats = {
        part_count = count,
        contact_pair_count = 0,
        contact_top_count = 0,
        contact_side_count = 0,
        pair_eval_count = 0,
        grid_cell_count = 0,
        grid_reference_count = 0,
        large_part_count = 0,
        cell_size = GRID_CELL_SIZE,
        generation = generation,
        worker_count = worker_count,
        worker_compute_ms = 0,
        worker_compute_max_ms = 0,
        max_pair_evals = max_pair_evals,
    }
    for offset = 0, count * 4 - 1 do
        local maximum = 0
        for worker_index = 1, worker_count do
            local value = validated[worker_index].values[offset]
            if value > maximum then maximum = value end
        end
        merged[offset] = maximum
    end
    for worker_index = 1, worker_count do
        local worker_stats = validated[worker_index].stats or {}
        stats.contact_pair_count = stats.contact_pair_count
            + (tonumber(worker_stats.contact_pair_count) or 0)
        stats.contact_top_count = stats.contact_top_count
            + (tonumber(worker_stats.contact_top_count) or 0)
        stats.contact_side_count = stats.contact_side_count
            + (tonumber(worker_stats.contact_side_count) or 0)
        stats.pair_eval_count = stats.pair_eval_count
            + (tonumber(worker_stats.pair_eval_count) or 0)
        stats.worker_compute_ms = stats.worker_compute_ms
            + (tonumber(worker_stats.worker_compute_ms) or 0)
        stats.worker_compute_max_ms = math.max(stats.worker_compute_max_ms,
            tonumber(worker_stats.worker_compute_ms) or 0)
    end
    local final_stats = validated[worker_count].stats or {}
    stats.grid_cell_count = tonumber(final_stats.grid_cell_count) or 0
    stats.grid_reference_count =
        tonumber(final_stats.grid_reference_count) or 0
    stats.max_grid_references =
        tonumber(final_stats.max_grid_references) or DEFAULT_MAX_GRID_REFERENCES
    stats.max_pair_evals = max_pair_evals
    stats.large_part_count = tonumber(final_stats.large_part_count) or 0
    aggregate_stats(merged, count, stats)
    return {
        data = merged_data,
        stats = stats,
        count = count,
        generation = generation,
        worker_count = worker_count,
    }
end

function ContactAO.compute_sync(input_data, options)
    options = options or {}
    local packet, compute_error = ContactAO.compute_packed(input_data, 1, 1, options)
    if not packet then return nil, compute_error end
    local merged, merge_error = ContactAO.merge_results({ packet }, {
        count = packet.stats.part_count,
        generation = packet.generation,
        worker_count = 1,
        max_output_bytes = options.max_output_bytes,
        max_pair_evals = options.max_pair_evals,
    })
    safe_release(packet.data)
    if not merged then return nil, merge_error end
    return merged
end

function ContactAO.result_values(result, index)
    if type(result) ~= "table" or result._released then
        return nil, "invalid_result"
    end
    local view, validation_error = validate_output(result.data, {
        count = result.count,
        generation = result.generation,
    })
    if not view then return nil, validation_error end
    index = tonumber(index)
    if not integer(index) or index < 1 or index > view.count then
        return nil, "result_index_out_of_range"
    end
    local offset = (index - 1) * 4
    return tonumber(view.values[offset]), tonumber(view.values[offset + 1]),
        tonumber(view.values[offset + 2]), tonumber(view.values[offset + 3])
end

-- applies one fully validated packet in a single pointer walk. Validation of
-- every target happens before the first write, so a stale/malformed entry list
-- cannot leave half the scene on a new AO generation
function ContactAO.apply_result(result, entries, parts)
    if type(result) ~= "table" or result._released then
        return nil, "invalid_result"
    end
    if type(entries) ~= "table" then return nil, "entries_not_table" end
    local view, validation_error = validate_output(result.data, {
        count = result.count,
        generation = result.generation,
    })
    if not view then return nil, validation_error end
    if #entries ~= view.count then return nil, "entry_count_mismatch" end
    if parts ~= nil and type(parts) ~= "table" then
        return nil, "parts_not_table"
    end
    for index = 1, view.count do
        local part
        if parts ~= nil then
            part = parts[index]
        else
            part = entries[index] and entries[index].part
        end
        if type(part) ~= "table" then return nil, "invalid_entry_part" end
    end
    for index = 1, view.count do
        local part
        if parts ~= nil then
            part = parts[index]
        else
            part = entries[index].part
        end
        local offset = (index - 1) * 4
        part._contact_ao_top = tonumber(view.values[offset])
        part._contact_ao_bottom = tonumber(view.values[offset + 1])
        part._contact_ao_side = tonumber(view.values[offset + 2])
        part._contact_ao_max = tonumber(view.values[offset + 3])
    end
    return true
end

function ContactAO.release_result(result)
    if type(result) ~= "table" or result._released then return false end
    result._released = true
    safe_release(result.data)
    result.data = nil
    return true
end

-- one-shot worker orchestration. the input packet remains caller-owned. every
-- worker receives that same immutable ByteData, partial result packets are
-- either all merged or all discarded
local Job = {}
Job.__index = Job
local channel_serial = 0

local function unique_channel_prefix(generation)
    channel_serial = channel_serial + 1
    local stamp = love and love.timer and love.timer.getTime
        and tostring(love.timer.getTime()) or tostring(os.clock())
    stamp = stamp:gsub("[^%w]", "")
    return "rbx_contact_ao_" .. tostring(generation) .. "_"
        .. stamp .. "_" .. tostring(channel_serial)
end

local function release_message_packet(message)
    if type(message) == "table" then safe_release(message.data) end
end

function Job:_cleanup_threads()
    for index = 1, #self.threads do
        local thread = self.threads[index]
        if thread and type(thread.release) == "function" then
            pcall(thread.release, thread)
        end
        self.threads[index] = nil
    end
    if self.response then pcall(self.response.clear, self.response) end
    if self.cancel_channel then pcall(self.cancel_channel.clear, self.cancel_channel) end
end

function Job:_wait_threads(wait_callback)
    local errors = {}
    if type(wait_callback) == "function" then
        while true do
            local any_running = false
            for index = 1, #self.threads do
                local thread = self.threads[index]
                if thread and type(thread.isRunning) == "function" then
                    local ok_running, running = pcall(thread.isRunning, thread)
                    if ok_running and running then any_running = true end
                end
            end
            if not any_running then break end
            local callback_ok, callback_error = pcall(wait_callback)
            if not callback_ok then
                errors[#errors + 1] = "wait_callback_failed:"
                    .. tostring(callback_error)
                wait_callback = nil
                break
            end
            -- Yield the main thread so it does not steal a core from workers
            -- one millisecond also bounds texture-prefetch response residency
            if love and love.timer and love.timer.sleep then
                love.timer.sleep(0.001)
            end
        end
    end
    for index = 1, #self.threads do
        local thread = self.threads[index]
        if thread then
            local wait_ok, wait_error = pcall(thread.wait, thread)
            if not wait_ok then errors[#errors + 1] = tostring(wait_error) end
            if type(thread.getError) == "function" then
                local ok_error, thread_error = pcall(thread.getError, thread)
                if ok_error and thread_error then errors[#errors + 1] = tostring(thread_error) end
            end
        end
    end
    return errors
end

function Job:finish(wait_callback)
    if self.state ~= "running" then return nil, "job_" .. tostring(self.state) end
    local thread_errors = self:_wait_threads(wait_callback)
    local messages = {}
    while true do
        local message = self.response:pop()
        if message == nil then break end
        messages[#messages + 1] = message
    end
    local failure
    if #thread_errors > 0 then
        failure = "worker_thread_failed:" .. table.concat(thread_errors, "|")
    elseif #messages ~= self.worker_count then
        failure = "worker_response_count_mismatch"
    else
        local first_error
        local cap_error
        for index = 1, #messages do
            local message = messages[index]
            if type(message) ~= "table" or message.ok ~= true
                or message.generation ~= self.generation then
                local message_error = type(message) == "table"
                    and tostring(message.error)
                    or "malformed_worker_response"
                first_error = first_error or message_error
                if ContactAO.is_work_cap_error(message_error) then
                    cap_error = cap_error or message_error
                end
            end
        end
        failure = cap_error or first_error
    end
    local merged
    if not failure then
        merged, failure = ContactAO.merge_results(messages, {
            count = self.count,
            generation = self.generation,
            worker_count = self.worker_count,
            max_output_bytes = self.max_output_bytes,
            max_pair_evals = self.max_pair_evals,
        })
    end
    for index = 1, #messages do release_message_packet(messages[index]) end
    self.state = merged and "finished" or "failed"
    self:_cleanup_threads()
    if not merged then return nil, failure or "worker_merge_failed" end
    return merged
end

function Job:cancel()
    if self.state ~= "running" then return false end
    self.state = "cancelling"
    pcall(self.cancel_channel.push, self.cancel_channel, self.generation)
    self:_wait_threads()
    while true do
        local message = self.response:pop()
        if message == nil then break end
        release_message_packet(message)
    end
    self.state = "cancelled"
    self:_cleanup_threads()
    return true
end

function ContactAO.start_workers(input_data, options)
    options = options or {}
    if not (love and love.thread and type(love.thread.getChannel) == "function"
        and type(love.thread.newThread) == "function") then
        return nil, "threading_unavailable"
    end
    local input, input_error = ContactAO.validate_input(input_data, options)
    if not input then return nil, input_error end
    local worker_count = bounded_integer(options.worker_count, 3, 2, MAX_WORKERS)
    local max_output_bytes = bounded_integer(options.max_output_bytes,
        DEFAULT_MAX_OUTPUT_BYTES, HEADER_BYTES, DEFAULT_MAX_OUTPUT_BYTES)
    local max_pair_evals = bounded_integer(options.max_pair_evals,
        DEFAULT_MAX_PAIR_EVALS, 0, HARD_MAX_PAIR_EVALS)
    local packet_bytes, bytes_error = checked_packet_bytes(
        input.count, OUTPUT_STRIDE_BYTES, max_output_bytes)
    if not packet_bytes then return nil, bytes_error end
    local max_total_result_bytes = bounded_integer(options.max_total_result_bytes,
        DEFAULT_MAX_OUTPUT_BYTES, HEADER_BYTES, DEFAULT_MAX_OUTPUT_BYTES)
    if packet_bytes * (worker_count + 1) > max_total_result_bytes then
        return nil, "aggregate_output_cap_exceeded"
    end

    local prefix = unique_channel_prefix(input.generation)
    local response = love.thread.getChannel(prefix .. "_response")
    local cancel_channel = love.thread.getChannel(prefix .. "_cancel")
    response:clear()
    cancel_channel:clear()
    local job = setmetatable({
        state = "running",
        threads = {},
        response = response,
        cancel_channel = cancel_channel,
        count = input.count,
        generation = input.generation,
        worker_count = worker_count,
        max_output_bytes = max_output_bytes,
        max_pair_evals = max_pair_evals,
    }, Job)
    local worker_path = options.worker_path
        or require("engine/root") .. "/graphics/rbx/contact_ao_thread.lua"
    for worker_index = 1, worker_count do
        local ok_thread, thread = pcall(love.thread.newThread, worker_path)
        if not ok_thread or not thread then
            job:cancel()
            return nil, "worker_create_failed:" .. tostring(thread)
        end
        job.threads[#job.threads + 1] = thread
        local ok_start, start_error = pcall(thread.start, thread,
            prefix .. "_response", prefix .. "_cancel", input_data,
            worker_index, worker_count, input.generation,
            options.max_parts or DEFAULT_MAX_PARTS,
            options.max_input_bytes or DEFAULT_MAX_INPUT_BYTES,
            max_output_bytes,
            options.max_grid_references or DEFAULT_MAX_GRID_REFERENCES,
            max_pair_evals,
            options.max_abs_cell_coordinate
                or DEFAULT_MAX_ABS_CELL_COORDINATE)
        if not ok_start then
            job:cancel()
            return nil, "worker_start_failed:" .. tostring(start_error)
        end
    end
    return job
end

return ContactAO
