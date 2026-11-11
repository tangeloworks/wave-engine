-- reuse vertices only when all their packed float32 bytes match
-- comparing whole rows keeps seams and signed zero intact

local ffi_ok, ffi = pcall(require, "ffi")
local bit_ok, bit = pcall(require, "bit")

local ExactIndex = {}

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_UINT32_INDEX = 4294967295

local HARD_LIMITS = {
    source_vertices = 16777216,
    stride_bytes = 1048576,
    payload_bytes = 1073741824,
    unique_vertices = MAX_UINT32_INDEX,
    index_bytes = 1073741824,
}

local DEFAULT_LIMITS = {
    source_vertices = 1048576,
    stride_bytes = 65536,
    payload_bytes = 268435456,
    unique_vertices = 1048576,
    index_bytes = 67108864,
}

local FLAT_FALLBACK_SAFE_REASONS = {
    not_smaller = true,
    index_overflow = true,
    indexed_size_overflow = true,
    index_bytes_limit = true,
    allocation_failed = true,
    output_pointer_unavailable = true,
    copy_failed = true,
}

local Result = {}
Result.__index = Result

local function failure(reason, diagnostics)
    diagnostics = diagnostics or {}
    diagnostics.reason = reason
    return nil, reason, diagnostics
end

local function complete_scan_failure(reason, diagnostics)
    diagnostics = diagnostics or {}
    diagnostics.finite_scan_complete = true
    diagnostics.flat_fallback_safe =
        FLAT_FALLBACK_SAFE_REASONS[reason] == true
    return failure(reason, diagnostics)
end

local function is_integer(value)
    return type(value) == "number"
        and value >= 0
        and value <= MAX_SAFE_INTEGER
        and value == math.floor(value)
end

local function safe_product(left, right, limit)
    if left == 0 or right == 0 then
        return 0
    end
    if left > math.floor(limit / right) then
        return nil
    end
    return left * right
end

local function safe_sum(left, right, limit)
    if left > limit - right then
        return nil
    end
    return left + right
end

local function read_limit(options, option_name, default_value, hard_value,
        allow_zero)
    local value = options[option_name]
    if value == nil then
        return default_value
    end
    value = tonumber(value)
    if not is_integer(value)
        or (not allow_zero and value == 0)
        or value > hard_value
    then
        return nil, "invalid_option", {
            option = option_name,
            value = options[option_name],
            maximum = hard_value,
        }
    end
    return value
end

local function resolve_limits(options)
    local limits = {}
    local value, reason, diagnostics = read_limit(options,
        "max_source_vertices", DEFAULT_LIMITS.source_vertices,
        HARD_LIMITS.source_vertices, true)
    if value == nil then return nil, reason, diagnostics end
    limits.source_vertices = value

    value, reason, diagnostics = read_limit(options,
        "max_stride_bytes", DEFAULT_LIMITS.stride_bytes,
        HARD_LIMITS.stride_bytes, false)
    if value == nil then return nil, reason, diagnostics end
    limits.stride_bytes = value

    value, reason, diagnostics = read_limit(options,
        "max_payload_bytes", DEFAULT_LIMITS.payload_bytes,
        HARD_LIMITS.payload_bytes, true)
    if value == nil then return nil, reason, diagnostics end
    limits.payload_bytes = value

    value, reason, diagnostics = read_limit(options,
        "max_unique_vertices", DEFAULT_LIMITS.unique_vertices,
        HARD_LIMITS.unique_vertices, true)
    if value == nil then return nil, reason, diagnostics end
    limits.unique_vertices = value

    value, reason, diagnostics = read_limit(options,
        "max_index_bytes", DEFAULT_LIMITS.index_bytes,
        HARD_LIMITS.index_bytes, true)
    if value == nil then return nil, reason, diagnostics end
    limits.index_bytes = value
    return limits
end

-- Validates the renderer's flat {part_id, first, count} range convention and
-- returns its partition count for the scan. Ranges are deliberately required
-- to be in source order and to cover every source vertex exactly once. keeping
-- the validated input as the scan descriptor avoids allocating one Lua object
-- per part before the bounded compaction output exists
local function validate_part_ranges(part_ranges, source_count,
        require_triangles)
    if part_ranges == nil then
        return nil
    end
    if type(part_ranges) ~= "table" then
        return failure("invalid_part_ranges", {
            detail = "not_table",
            value_type = type(part_ranges),
        })
    end

    local maximum_entries = safe_product(source_count, 3, MAX_SAFE_INTEGER)
    local entry_count = 0
    local maximum_index = 0
    for key in pairs(part_ranges) do
        if not is_integer(key) or key < 1 then
            return failure("invalid_part_ranges", {
                detail = "non_array_key",
                key = tostring(key),
            })
        end
        if maximum_entries == nil or key > maximum_entries then
            return failure("invalid_part_ranges", {
                detail = "entry_limit",
                entry_index = key,
                maximum_entries = maximum_entries or 0,
            })
        end
        entry_count = entry_count + 1
        if key > maximum_index then
            maximum_index = key
        end
    end

    if entry_count == 0 then
        if source_count == 0 then
            return 0
        end
        return failure("part_range_incomplete", {
            expected_source_vertex_count = source_count,
            covered_source_vertex_count = 0,
            next_expected_first = 1,
        })
    end
    if maximum_index % 3 ~= 0 then
        return failure("invalid_part_ranges", {
            detail = "triple_layout",
            entry_count = entry_count,
            maximum_index = maximum_index,
        })
    end
    if entry_count ~= maximum_index then
        return failure("invalid_part_ranges", {
            detail = "sparse",
            entry_count = entry_count,
            maximum_index = maximum_index,
        })
    end

    local expected_first = 1
    local misaligned_partition
    local misaligned_first
    local misaligned_count
    for entry_index = 1, maximum_index, 3 do
        local partition_index = (entry_index + 2) / 3
        local part_id = rawget(part_ranges, entry_index)
        local first = rawget(part_ranges, entry_index + 1)
        local range_count = rawget(part_ranges, entry_index + 2)
        if part_id == nil then
            return failure("invalid_part_ranges", {
                detail = "missing_part_id",
                partition_index = partition_index,
            })
        end
        if type(part_id) == "number"
            and (part_id ~= part_id
                or part_id == math.huge
                or part_id == -math.huge)
        then
            return failure("invalid_part_ranges", {
                detail = "non_finite_part_id",
                partition_index = partition_index,
            })
        end
        if not is_integer(first) or first < 1 then
            return failure("invalid_part_range", {
                detail = "first",
                partition_index = partition_index,
                first = first,
            })
        end
        if not is_integer(range_count) or range_count == 0 then
            return failure("invalid_part_range", {
                detail = "count",
                partition_index = partition_index,
                count = range_count,
            })
        end
        if first < expected_first then
            return failure("part_range_overlap", {
                partition_index = partition_index,
                first = first,
                count = range_count,
                next_expected_first = expected_first,
            })
        end
        if first > expected_first then
            return failure("part_range_gap", {
                partition_index = partition_index,
                first = first,
                count = range_count,
                next_expected_first = expected_first,
            })
        end
        local after_last = safe_sum(first, range_count, MAX_SAFE_INTEGER)
        if after_last == nil or after_last - 1 > source_count then
            return failure("part_range_out_of_bounds", {
                partition_index = partition_index,
                first = first,
                count = range_count,
                source_vertex_count = source_count,
            })
        end
        -- a partition is the complete geometry owned by one part. Allowing a
        -- boundary through the middle of a triangle would make zeroing either
        -- returned compact span mutate a primitive shared with its neighbour
        if require_triangles and range_count % 3 ~= 0
            and misaligned_partition == nil then
            misaligned_partition = partition_index
            misaligned_first = first
            misaligned_count = range_count
        end
        expected_first = after_last
    end

    if expected_first ~= source_count + 1 then
        return failure("part_range_incomplete", {
            expected_source_vertex_count = source_count,
            covered_source_vertex_count = expected_first - 1,
            next_expected_first = expected_first,
        })
    end
    if misaligned_partition ~= nil then
        return failure("invalid_part_range", {
            detail = "triangle_alignment",
            partition_index = misaligned_partition,
            first = misaligned_first,
            count = misaligned_count,
        })
    end
    return maximum_index / 3
end

local function release_data(data)
    if data == nil then return true end
    local ok, release = pcall(function() return data.release end)
    if not ok or type(release) ~= "function" then return false end
    local release_ok, released = pcall(release, data)
    return release_ok and released ~= false
end

local function preserve_failed_output_cleanup(output, diagnostics)
    diagnostics = diagnostics or {}
    diagnostics.output_cleanup_attempted = true
    if release_data(output) then
        diagnostics.output_cleanup_succeeded = true
        diagnostics.cleanup_required = false
    else
        diagnostics.output_cleanup_succeeded = false
        diagnostics.cleanup_required = true
        -- Ownership transfers to the diagnostic until the caller retries the
        -- cleanup. never discard the only remaining reference to an allocated
        -- output merely because a LOVE release operation raised
        diagnostics.vertex_data = output
    end
    return diagnostics
end

local function data_size(data)
    if type(data) ~= "userdata" then
        return nil, "invalid_data", { value_type = type(data) }
    end
    local ok, size_or_error = pcall(function()
        assert(type(data.getSize) == "function", "getSize unavailable")
        return data:getSize()
    end)
    if not ok then
        return nil, "payload_size_unavailable", {
            detail = tostring(size_or_error),
        }
    end
    local size = tonumber(size_or_error)
    if not is_integer(size) then
        return nil, "payload_size_unavailable", {
            detail = "non_integer_size",
        }
    end
    return size
end

local function data_pointer(data, ctype, reason)
    local ok, pointer = pcall(function()
        assert(type(data.getFFIPointer) == "function",
            "getFFIPointer unavailable")
        return data:getFFIPointer()
    end)
    if not ok or pointer == nil then
        return nil, reason, { detail = ok and "nil_pointer" or tostring(pointer) }
    end
    local cast_ok, cast_pointer = pcall(ffi.cast, ctype, pointer)
    if not cast_ok or cast_pointer == nil then
        return nil, reason, {
            detail = cast_ok and "nil_cast_pointer" or tostring(cast_pointer),
        }
    end
    return cast_pointer
end

local function metrics(source_count, unique_count, stride, index_size)
    local flat_bytes = source_count * stride
    local compact_vertex_bytes = unique_count * stride
    local index_bytes = source_count * index_size
    local indexed_bytes = compact_vertex_bytes + index_bytes
    return {
        source_vertex_count = source_count,
        vertex_count = unique_count,
        unique_vertex_count = unique_count,
        index_count = source_count,
        vertex_stride_bytes = stride,
        indices_tsize = index_size,
        index_type = index_size == 2 and "uint16" or "uint32",
        flat_bytes = flat_bytes,
        flat_vertex_bytes = flat_bytes,
        compact_vertex_bytes = compact_vertex_bytes,
        index_bytes = index_bytes,
        indexed_bytes = indexed_bytes,
        bytes_saved = flat_bytes - indexed_bytes,
    }
end

-- Selects LOVE's index element width without allocating an index buffer
function ExactIndex.select_index_size(unique_vertex_count)
    local count = tonumber(unique_vertex_count)
    if not is_integer(count) then
        return failure("invalid_unique_count", {
            unique_vertex_count = unique_vertex_count,
        })
    end
    if count > MAX_UINT32_INDEX then
        return failure("index_overflow", {
            unique_vertex_count = count,
            maximum = MAX_UINT32_INDEX,
        })
    end
    return count <= 65535 and 2 or 4
end

-- Classifies a compact() failure for renderer fallback policy. a reason name
-- alone is deliberately insufficient: the diagnostic must also prove that all
-- source float32 rows were validated finite
function ExactIndex.classify_failure(reason, diagnostics)
    local complete = type(diagnostics) == "table"
        and diagnostics.finite_scan_complete == true
    local safe = complete
        and FLAT_FALLBACK_SAFE_REASONS[tostring(reason)] == true
    return {
        reason = reason,
        finite_scan_complete = complete,
        flat_fallback_safe = safe,
        cleanup_required = type(diagnostics) == "table"
            and diagnostics.cleanup_required == true,
    }
end

function ExactIndex.is_flat_fallback_safe(reason, diagnostics)
    return ExactIndex.classify_failure(
        reason, diagnostics).flat_fallback_safe
end

-- Retries ownership cleanup surfaced by an allocation-output failure
function ExactIndex.release_failure_output(diagnostics)
    if type(diagnostics) ~= "table"
        or diagnostics.cleanup_required ~= true
        or diagnostics.vertex_data == nil
    then
        return false
    end
    diagnostics.output_cleanup_attempted = true
    if not release_data(diagnostics.vertex_data) then
        diagnostics.output_cleanup_succeeded = false
        return false
    end
    diagnostics.vertex_data = nil
    diagnostics.cleanup_required = false
    diagnostics.output_cleanup_succeeded = true
    return true
end

function Result:release()
    if self.released then return false end
    local output = self.vertex_data
    if output ~= nil and not release_data(output) then
        self.release_failed = true
        return false
    end
    self.vertex_data = nil
    self.release_failed = false
    self.released = true
    return true
end

-- compact identical packed float32 rows in first-seen order and return one-based indices
-- every vertex attribute participates in the comparison
function ExactIndex.compact(packed_data, source_vertex_count,
        vertex_stride_bytes, options)
    if options ~= nil and type(options) ~= "table" then
        return failure("invalid_options", { value_type = type(options) })
    end
    options = options or {}

    if not ffi_ok or not bit_ok then
        return failure("unsupported", {
            feature = not ffi_ok and "ffi" or "bit",
        })
    end
    if type(love) ~= "table" or type(love.data) ~= "table"
        or type(love.data.newByteData) ~= "function"
    then
        return failure("unsupported", { feature = "love.data" })
    end
    if ffi.sizeof("unsigned int") ~= 4 then
        return failure("unsupported", { feature = "uint32_float_bits" })
    end

    local limits, limit_reason, limit_diagnostics = resolve_limits(options)
    if limits == nil then
        return failure(limit_reason, limit_diagnostics)
    end

    local count = tonumber(source_vertex_count)
    if not is_integer(count) then
        return failure("invalid_source_count", {
            source_vertex_count = source_vertex_count,
        })
    end
    local stride = tonumber(vertex_stride_bytes)
    if not is_integer(stride) or stride == 0 then
        return failure("invalid_stride", {
            vertex_stride_bytes = vertex_stride_bytes,
        })
    end
    if stride % 4 ~= 0 then
        return failure("stride_not_float32", {
            vertex_stride_bytes = stride,
        })
    end
    if count > limits.source_vertices then
        return failure("source_count_limit", {
            source_vertex_count = count,
            maximum = limits.source_vertices,
        })
    end
    if stride > limits.stride_bytes then
        return failure("stride_limit", {
            vertex_stride_bytes = stride,
            maximum = limits.stride_bytes,
        })
    end
    local require_triangles = options.require_triangles ~= false
        and options.triangle_list ~= false
    if require_triangles and count % 3 ~= 0 then
        return failure("triangle_count", {
            source_vertex_count = count,
            remainder = count % 3,
        })
    end

    local part_partition_count, part_reason, part_diagnostics =
        validate_part_ranges(options.part_ranges, count,
            require_triangles)
    if part_reason ~= nil then
        return failure(part_reason, part_diagnostics)
    end

    local expected_size = safe_product(count, stride, MAX_SAFE_INTEGER)
    if expected_size == nil then
        return failure("payload_overflow", {
            source_vertex_count = count,
            vertex_stride_bytes = stride,
        })
    end
    if expected_size > limits.payload_bytes then
        return failure("payload_limit", {
            payload_bytes = expected_size,
            maximum = limits.payload_bytes,
        })
    end
    local actual_size, size_reason, size_diagnostics = data_size(packed_data)
    if actual_size == nil then
        return failure(size_reason, size_diagnostics)
    end
    if actual_size ~= expected_size then
        return failure("payload_mismatch", {
            expected_payload_bytes = expected_size,
            actual_payload_bytes = actual_size,
            source_vertex_count = count,
            vertex_stride_bytes = stride,
        })
    end
    if count == 0 then
        return complete_scan_failure(
            "not_smaller", metrics(0, 0, stride, 2))
    end

    local source_bytes, pointer_reason, pointer_diagnostics = data_pointer(
        packed_data, "const unsigned char*", "pointer_unavailable")
    if source_bytes == nil then
        return failure(pointer_reason, pointer_diagnostics)
    end
    local source_words, words_reason, words_diagnostics = data_pointer(
        packed_data, "const unsigned int*", "pointer_unavailable")
    if source_words == nil then
        return failure(words_reason, words_diagnostics)
    end

    local component_count = stride / 4
    local vertex_by_bytes = {}
    local unique_source_offsets = {}
    local indices = {}
    local unique_count = 0
    local part_ranges = part_partition_count ~= nil
        and options.part_ranges or nil
    local part_compact_ranges = part_ranges and {} or nil
    local partition_index = part_ranges and 1 or nil
    local partition_entry = partition_index and 1 or nil
    local partition_part_id
    local partition_first
    local partition_last
    if partition_entry then
        partition_part_id = rawget(part_ranges, partition_entry)
        partition_first = rawget(part_ranges, partition_entry + 1)
        partition_last = partition_first
            + rawget(part_ranges, partition_entry + 2) - 1
    end
    local partition_compact_first

    for source_offset = 0, count - 1 do
        local source_index = source_offset + 1
        if partition_entry and source_index == partition_first then
            -- a row shared by two parts must have two compact copies: later
            -- incremental zeroing can then mutate one contiguous part span
            -- without erasing geometry owned by the other part
            -- reuse the hash allocation across thousands of small parts. this
            -- clear is proportional to the prior partition's unique rows and
            -- avoids making the load-time garbage collector retire one table
            -- object per part
            for row_key in pairs(vertex_by_bytes) do
                vertex_by_bytes[row_key] = nil
            end
            partition_compact_first = unique_count + 1
        end
        local word_offset = source_offset * component_count
        for component_offset = 0, component_count - 1 do
            local bits = tonumber(source_words[word_offset + component_offset])
            if bit.band(bits, 0x7f800000) == 0x7f800000 then
                return failure("non_finite_component", {
                    source_vertex_index = source_index,
                    component_index = component_offset + 1,
                    index = source_index,
                    component = component_offset + 1,
                    bit_pattern = string.format("%08x", bits),
                })
            end
        end

        local byte_offset = source_offset * stride
        local row_key = ffi.string(source_bytes + byte_offset, stride)
        local compact_index = vertex_by_bytes[row_key]
        if compact_index == nil then
            unique_count = unique_count + 1
            if unique_count > limits.unique_vertices then
                return failure("unique_count_limit", {
                    unique_vertex_count = unique_count,
                    maximum = limits.unique_vertices,
                    source_vertex_index = source_index,
                })
            end
            compact_index = unique_count
            vertex_by_bytes[row_key] = compact_index
            unique_source_offsets[compact_index] = byte_offset
        end
        indices[source_index] = compact_index

        if partition_entry and source_index == partition_last then
            part_compact_ranges[#part_compact_ranges + 1] =
                partition_part_id
            part_compact_ranges[#part_compact_ranges + 1] =
                partition_compact_first
            part_compact_ranges[#part_compact_ranges + 1] =
                unique_count - partition_compact_first + 1
            partition_index = partition_index + 1
            if partition_index <= part_partition_count then
                partition_entry = partition_entry + 3
                partition_part_id = rawget(part_ranges, partition_entry)
                partition_first = rawget(part_ranges, partition_entry + 1)
                partition_last = partition_first
                    + rawget(part_ranges, partition_entry + 2) - 1
            else
                partition_entry = nil
                partition_part_id = nil
                partition_first = nil
                partition_last = nil
            end
        end
    end

    local index_size, index_reason, index_diagnostics =
        ExactIndex.select_index_size(unique_count)
    if index_size == nil then
        return complete_scan_failure(index_reason, index_diagnostics)
    end
    local compact_bytes = safe_product(unique_count, stride, MAX_SAFE_INTEGER)
    local index_bytes = safe_product(count, index_size, MAX_SAFE_INTEGER)
    if compact_bytes == nil or index_bytes == nil then
        return complete_scan_failure("indexed_size_overflow", {
            source_vertex_count = count,
            unique_vertex_count = unique_count,
            vertex_stride_bytes = stride,
            indices_tsize = index_size,
        })
    end
    if index_bytes > limits.index_bytes then
        return complete_scan_failure("index_bytes_limit", {
            index_bytes = index_bytes,
            maximum = limits.index_bytes,
        })
    end
    local indexed_bytes = safe_sum(compact_bytes, index_bytes,
        MAX_SAFE_INTEGER)
    if indexed_bytes == nil then
        return complete_scan_failure("indexed_size_overflow", {
            compact_vertex_bytes = compact_bytes,
            index_bytes = index_bytes,
        })
    end
    local diagnostic_metrics = metrics(count, unique_count, stride, index_size)
    if part_partition_count ~= nil then
        diagnostic_metrics.partition_count = part_partition_count
    end
    if indexed_bytes >= expected_size then
        return complete_scan_failure("not_smaller", diagnostic_metrics)
    end

    local output
    local allocation_ok, allocation_error = pcall(function()
        output = love.data.newByteData(compact_bytes)
    end)
    if not allocation_ok or output == nil then
        local diagnostics = {
            requested_bytes = compact_bytes,
            detail = tostring(allocation_error),
        }
        if output ~= nil then
            preserve_failed_output_cleanup(output, diagnostics)
        end
        return complete_scan_failure("allocation_failed", diagnostics)
    end

    local output_bytes, output_reason, output_diagnostics = data_pointer(
        output, "unsigned char*", "output_pointer_unavailable")
    if output_bytes == nil then
        preserve_failed_output_cleanup(output, output_diagnostics)
        return complete_scan_failure(output_reason, output_diagnostics)
    end
    local copy_ok, copy_error = pcall(function()
        for compact_index = 1, unique_count do
            ffi.copy(output_bytes + (compact_index - 1) * stride,
                source_bytes + unique_source_offsets[compact_index], stride)
        end
    end)
    if not copy_ok then
        local diagnostics = preserve_failed_output_cleanup(output, {
            detail = tostring(copy_error),
        })
        return complete_scan_failure("copy_failed", diagnostics)
    end

    local result = diagnostic_metrics
    result.vertex_data = output
    result.indices = indices
    result.part_compact_ranges = part_compact_ranges
    result.released = false
    return setmetatable(result, Result)
end

ExactIndex.build = ExactIndex.compact
ExactIndex.compact_packed_rows = ExactIndex.compact

function ExactIndex.release(result)
    if type(result) ~= "table" or type(result.release) ~= "function" then
        return false
    end
    return result:release()
end

return ExactIndex
