-- pack the local light vectors into one ByteData for Shader:send
-- this avoids building 25 Lua tables each time the light set changes

local packet = {}

packet.uniform_name = "uLocalLights"
packet.vector_count = 25
packet.component_count = 4
packet.float_count = packet.vector_count * packet.component_count
packet.byte_size = packet.float_count * 4

local ffi_available, ffi = pcall(require, "ffi")
local VECTOR_NAMES = { "a", "b", "c", "d", "e", "f" }
local POSITIVE_INFINITY = math.huge

local function finite_number(value)
    if value == nil then
        return 0, 0
    end
    local value_type = type(value)
    if value_type ~= "number" and value_type ~= "string" then
        return 0, 1
    end
    local number = tonumber(value)
    if number == nil
        or number ~= number
        or number == POSITIVE_INFINITY
        or number == -POSITIVE_INFINITY then
        return 0, 1
    end
    return number, 0
end

local function table_component(container, key)
    if type(container) ~= "table" then
        return 0, 0
    end
    return finite_number(rawget(container, key))
end

local function write_vector(floats, float_base, vector)
    local sanitized = 0
    for component = 1, 4 do
        local value, invalid = table_component(vector, component)
        floats[float_base + component - 1] = value
        sanitized = sanitized + invalid
    end
    return sanitized
end

function packet.clamp_light_count(max_lights, count)
    local limit = tonumber(max_lights)
    if limit == nil
        or limit ~= limit
        or limit == POSITIVE_INFINITY
        or limit == -POSITIVE_INFINITY then
        limit = 4
    end
    limit = math.max(0, math.min(4, math.floor(limit)))

    local selected = tonumber(count)
    if selected == nil
        or selected ~= selected
        or selected == POSITIVE_INFINITY
        or selected == -POSITIVE_INFINITY then
        selected = 0
    end
    return math.max(0, math.min(limit, math.floor(selected)))
end

-- the shader only reads a slot when metadata[0].w says that slot exists
-- LÖVE's Data overload accepts a prefix whose size is a multiple of one
-- vec4, so an exact lower-count packet need not copy inactive trailing slots
-- into the driver uniform store. Callers that omit the count retain the full
-- packet behavior for diagnostics and compatibility probes
function packet.local_light_byte_size(selected_count)
    if selected_count == nil then
        return packet.byte_size
    end
    local selected = packet.clamp_light_count(4, selected_count)
    return (1 + selected * 6) * packet.component_count * 4
end

---create the sole renderer-lifetime packet allocation
---@return table|nil scratch
---@return string|nil reason
function packet.new()
    if not ffi_available or not ffi then
        return nil, "ffi_unavailable"
    end
    if type(love) ~= "table"
        or type(love.data) ~= "table"
        or type(love.data.newByteData) ~= "function" then
        return nil, "love_data_unavailable"
    end

    local allocation_ok, data_or_error = pcall(
        love.data.newByteData, packet.byte_size)
    if not allocation_ok or not data_or_error then
        return nil, "byte_data_allocation_failed:"
            .. tostring(data_or_error)
    end
    local data = data_or_error
    local pointer_ok, pointer_or_error = pcall(
        data.getFFIPointer, data)
    if not pointer_ok or pointer_or_error == nil then
        if type(data.release) == "function" then
            pcall(data.release, data)
        end
        return nil, "ffi_pointer_unavailable:"
            .. tostring(pointer_or_error)
    end

    local cast_ok, floats_or_error = pcall(
        ffi.cast, "float *", pointer_or_error)
    if not cast_ok or floats_or_error == nil then
        if type(data.release) == "function" then
            pcall(data.release, data)
        end
        return nil, "ffi_pointer_cast_failed:"
            .. tostring(floats_or_error)
    end

    return {
        data = data,
        pointer = pointer_or_error,
        floats = floats_or_error,
        byte_size = packet.byte_size,
    }, nil
end

---pack metadata followed by four six-vec4 light slots in exact GLSL order
---the entire buffer is zeroed first so a smaller pack can never expose stale
---slot data. invalid numeric inputs are replaced with zero at the CPU/GPU
---boundary and reported to renderer diagnostics
---@return integer sanitized_value_count
---@return integer selected_light_count
function packet.write_local_lights(scratch, pack, max_lights)
    if type(scratch) ~= "table"
        or scratch.pointer == nil
        or scratch.floats == nil
        or scratch.data == nil then
        error("local-light uniform packet scratch is unavailable", 2)
    end
    ffi.fill(scratch.pointer, packet.byte_size, 0)

    pack = type(pack) == "table" and pack or nil
    local selected_count = packet.clamp_light_count(
        max_lights, pack and rawget(pack, "count") or 0)
    local floats = scratch.floats
    local sanitized = 0
    local ambient = pack and rawget(pack, "ambient") or nil
    for component = 1, 3 do
        local value, invalid = table_component(ambient, component)
        floats[component - 1] = value
        sanitized = sanitized + invalid
    end
    floats[3] = selected_count

    if selected_count == 0 or not pack then
        return sanitized, selected_count
    end

    -- a materialized compatibility view is authoritative because callers may
    -- edit it. Untouched runtime packs remain on their flat 96-number path
    local slots = rawget(pack, "slots")
    local compact_values = slots == nil
        and rawget(pack, "_compact_values")
        or nil
    if type(compact_values) == "table" then
        for slot_index = 1, selected_count do
            local source_base = (slot_index - 1) * 24
            local destination_base = 4 + source_base
            for component = 1, 24 do
                local value, invalid = finite_number(
                    rawget(compact_values, source_base + component))
                floats[destination_base + component - 1] = value
                sanitized = sanitized + invalid
            end
        end
        return sanitized, selected_count
    end

    if type(slots) ~= "table" then
        return sanitized, selected_count
    end
    for slot_index = 1, selected_count do
        local slot = rawget(slots, slot_index)
        for vector_index = 1, 6 do
            local vector = type(slot) == "table"
                and rawget(slot, VECTOR_NAMES[vector_index])
                or nil
            local destination_base = 4
                + (slot_index - 1) * 24
                + (vector_index - 1) * 4
            sanitized = sanitized
                + write_vector(floats, destination_base, vector)
        end
    end
    return sanitized, selected_count
end

function packet.is_real_shader(shader)
    return type(shader) == "userdata"
end

function packet.send_local_lights(shader, scratch, selected_count)
    shader:send(
        packet.uniform_name,
        scratch.data,
        0,
        packet.local_light_byte_size(selected_count)
    )
end

return packet
