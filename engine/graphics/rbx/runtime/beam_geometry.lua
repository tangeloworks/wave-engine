-- bounded, renderer-independent Beam geometry
--
-- Roblox documents Beam as a cubic Bezier ribbon.  its four control points are
-- Attachment0, Attachment0 + Right0 * CurveSize0,
-- Attachment1 - Right1 * CurveSize1, and Attachment1.  this module implements
-- that public contract without retaining Instances or allocating LOVE objects
--
-- Ownership boundary:
--   * build_recipe() owns immutable/value-owned, view-independent sampling
--   * bake() owns deterministic ribbon math and can reuse caller-owned output
--   * a future scene integration owns when a FaceCamera/ZOffset recipe is
--     rebaked for a new camera generation
--
-- every non-empty bake is an indexed renderer-compatible 20-float stream:
-- position3, normal3, uv2, color4, reflectance1, tangent3, bitangent3,
-- contactAO1.  Color/alpha conventions are explicit on the returned payload

local BeamGeometry = {}

BeamGeometry.SEMANTICS_VERSION = 1
BeamGeometry.DEFAULT_SEGMENTS = 10
BeamGeometry.MAX_SEGMENTS = 256
BeamGeometry.MAX_VERTICES = (BeamGeometry.MAX_SEGMENTS + 1) * 2
BeamGeometry.MAX_INDICES = BeamGeometry.MAX_SEGMENTS * 6
BeamGeometry.VERTEX_FLOATS = 20
BeamGeometry.VERTEX_STRIDE_BYTES = BeamGeometry.VERTEX_FLOATS * 4
BeamGeometry.INDEX_STRIDE_BYTES = 2
BeamGeometry.MAX_RESOURCE_BYTES = BeamGeometry.MAX_VERTICES
    * BeamGeometry.VERTEX_STRIDE_BYTES
    + BeamGeometry.MAX_INDICES * BeamGeometry.INDEX_STRIDE_BYTES
BeamGeometry.MAX_SEQUENCE_KEYPOINTS = 128
BeamGeometry.MAX_ABS_COORDINATE = 10000000
BeamGeometry.MAX_CURVE_SIZE = 1000000
BeamGeometry.MAX_WIDTH = 100000
BeamGeometry.MAX_TEXTURE_LENGTH = 1000000
BeamGeometry.MAX_TEXTURE_SPEED = 1000000
BeamGeometry.MAX_TIME_SECONDS = 1000000000

local EPSILON = 1e-9
local FRAME_EPSILON = 1e-12
local MIN_WRAP_TEXTURE_LENGTH = 1e-4
local unpack_values = unpack or table.unpack

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok or type(ffi) ~= "table" then
    ffi_ok = false
    ffi = nil
end

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function number_or(value, fallback)
    value = tonumber(value)
    if not finite(value) then return fallback end
    return value
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function clean(value)
    -- Canonical positive zero keeps packed rows byte-identical across fallback
    -- branches which may otherwise manufacture IEEE negative zero
    if value == 0 or math.abs(value) < 1e-15 then return 0 end
    return value
end

local function property(source, ...)
    if type(source) ~= "table" then return nil end
    for index = 1, select("#", ...) do
        local value = source[select(index, ...)]
        if value ~= nil then return value end
    end
    return nil
end

local function vec(x, y, z)
    return { clean(x), clean(y), clean(z) }
end

local function vector_components(value)
    if type(value) ~= "table" then return nil end
    local x = value[1]
    if x == nil then x = value.x or value.X end
    local y = value[2]
    if y == nil then y = value.y or value.Y end
    local z = value[3]
    if z == nil then z = value.z or value.Z end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    return x, y, z
end

local function dot(ax, ay, az, bx, by, bz)
    return ax * bx + ay * by + az * bz
end

local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx
end

local function length_and_unit(x, y, z)
    local largest = math.max(math.abs(x), math.abs(y), math.abs(z))
    if largest <= FRAME_EPSILON or not finite(largest) then return nil end
    local sx, sy, sz = x / largest, y / largest, z / largest
    local scaled_length = math.sqrt(sx * sx + sy * sy + sz * sz)
    if scaled_length <= FRAME_EPSILON or not finite(scaled_length) then return nil end
    return largest * scaled_length,
        clean(sx / scaled_length), clean(sy / scaled_length),
        clean(sz / scaled_length)
end

local function distance(a, b)
    local length = length_and_unit(
        b[1] - a[1], b[2] - a[2], b[3] - a[3])
    return length or 0
end

local function orthogonal_to(x, y, z)
    local gx, gy, gz
    if math.abs(x) <= math.abs(y) and math.abs(x) <= math.abs(z) then
        gx, gy, gz = 1, 0, 0
    elseif math.abs(y) <= math.abs(z) then
        gx, gy, gz = 0, 1, 0
    else
        gx, gy, gz = 0, 0, 1
    end
    local projection = dot(gx, gy, gz, x, y, z)
    local _, ox, oy, oz = length_and_unit(
        gx - x * projection, gy - y * projection, gz - z * projection)
    if ox then return ox, oy, oz end
    return 0, 1, 0
end

local function project_unit(x, y, z, nx, ny, nz, fx, fy, fz)
    local projection = dot(x, y, z, nx, ny, nz)
    local _, px, py, pz = length_and_unit(
        x - nx * projection, y - ny * projection, z - nz * projection)
    if px then return px, py, pz, false end
    if fx ~= nil then
        projection = dot(fx, fy, fz, nx, ny, nz)
        _, px, py, pz = length_and_unit(
            fx - nx * projection, fy - ny * projection,
            fz - nz * projection)
        if px then return px, py, pz, true end
    end
    px, py, pz = orthogonal_to(nx, ny, nz)
    return px, py, pz, true
end

local function cancelled(options, phase, index)
    local check = options and (options.cancel_check or options.cancelled)
    if check == true then return true end
    if type(check) ~= "function" then return false end
    local ok, result = pcall(check, phase, index)
    return not ok or result == true
end

local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 then return math.atan(y / x) - math.pi end
    if y > 0 then return math.pi * 0.5 end
    if y < 0 then return -math.pi * 0.5 end
    return 0
end

local function rotate_about_axis(x, y, z, ax, ay, az, angle)
    if angle == 0 then return x, y, z end
    local cosine, sine = math.cos(angle), math.sin(angle)
    local cx, cy, cz = cross(ax, ay, az, x, y, z)
    local along = dot(ax, ay, az, x, y, z) * (1 - cosine)
    return clean(x * cosine + cx * sine + ax * along),
        clean(y * cosine + cy * sine + ay * along),
        clean(z * cosine + cz * sine + az * along)
end

local function read_frame(frame, label)
    if type(frame) ~= "table" then return nil, label .. "_missing" end
    local nested = property(frame, "world_cframe", "WorldCFrame", "cframe", "CFrame")
    if type(nested) == "table" then frame = nested end

    local position = property(frame, "position", "Position", "world_position", "WorldPosition")
    local px, py, pz = vector_components(position)
    if px == nil then
        px = tonumber(frame.x or frame.X)
        py = tonumber(frame.y or frame.Y)
        pz = tonumber(frame.z or frame.Z)
    end
    if not (finite(px) and finite(py) and finite(pz)) then
        return nil, label .. "_position_invalid"
    end
    if math.max(math.abs(px), math.abs(py), math.abs(pz))
        > BeamGeometry.MAX_ABS_COORDINATE then
        return nil, label .. "_position_limit"
    end

    local right_value = property(frame, "right", "RightVector", "axis", "Axis", "world_axis", "WorldAxis")
    local rx, ry, rz = vector_components(right_value)
    if rx == nil then
        rx = number_or(frame.r00 or frame.R00, 1)
        ry = number_or(frame.r10 or frame.R10, 0)
        rz = number_or(frame.r20 or frame.R20, 0)
    end
    local _, nrx, nry, nrz = length_and_unit(rx, ry, rz)
    local basis_sanitized = false
    if nrx == nil then
        nrx, nry, nrz = 1, 0, 0
        basis_sanitized = true
    end

    local up_value = property(frame, "up", "UpVector", "secondary_axis", "SecondaryAxis",
        "world_secondary_axis", "WorldSecondaryAxis")
    local ux, uy, uz = vector_components(up_value)
    if ux == nil then
        ux = number_or(frame.r01 or frame.R01, 0)
        uy = number_or(frame.r11 or frame.R11, 1)
        uz = number_or(frame.r21 or frame.R21, 0)
    end
    local projection = dot(ux, uy, uz, nrx, nry, nrz)
    local _, nux, nuy, nuz = length_and_unit(
        ux - nrx * projection, uy - nry * projection,
        uz - nrz * projection)
    if nux == nil then
        nux, nuy, nuz = orthogonal_to(nrx, nry, nrz)
        basis_sanitized = true
    end
    local bx, by, bz = cross(nrx, nry, nrz, nux, nuy, nuz)
    local _, nbx, nby, nbz = length_and_unit(bx, by, bz)
    if nbx == nil then
        return nil, label .. "_basis_invalid"
    end
    return {
        position = vec(px, py, pz),
        right = vec(nrx, nry, nrz),
        up = vec(nux, nuy, nuz),
        back = vec(nbx, nby, nbz),
        basis_sanitized = basis_sanitized,
    }
end

local function texture_mode(value)
    if type(value) == "table" then
        value = value.Name or value.name or value.Value or value.value
    end
    local numeric = tonumber(value)
    if numeric ~= nil then
        numeric = math.floor(numeric + 0.5)
        if numeric == 1 then return "Wrap", 1 end
        if numeric == 2 then return "Static", 2 end
        return "Stretch", 0
    end
    if type(value) == "string" then
        local name = value:gsub("^Enum%.TextureMode%.", ""):lower()
        if name == "wrap" then return "Wrap", 1 end
        if name == "static" then return "Static", 2 end
    end
    return "Stretch", 0
end

local function sequence_array(raw)
    if type(raw) ~= "table" then return nil end
    if type(raw.keypoints) == "table" then return raw.keypoints end
    if type(raw.Keypoints) == "table" then return raw.Keypoints end
    if (raw.type == "ColorSequence" or raw.type == "NumberSequence")
        and type(raw.value) == "table" then
        return raw.value
    end
    if type(raw.value) == "table" and #raw == 0 then return raw.value end
    return raw
end

local function read_color(value, fallback_r, fallback_g, fallback_b)
    if type(value) ~= "table" then
        return fallback_r, fallback_g, fallback_b
    end
    local r = value[1]
    if r == nil then r = value.r or value.R end
    local g = value[2]
    if g == nil then g = value.g or value.G end
    local b = value[3]
    if b == nil then b = value.b or value.B end
    return clamp(number_or(r, fallback_r), 0, 1),
        clamp(number_or(g, fallback_g), 0, 1),
        clamp(number_or(b, fallback_b), 0, 1)
end

local function normalize_number_sequence(raw, fallback, options, label)
    if type(raw) == "number" then
        local value = clamp(number_or(raw, fallback), 0, 1)
        return {
            { time = 0, value = value, envelope = 0 },
            { time = 1, value = value, envelope = 0 },
        }
    end
    local source = sequence_array(raw)
    if type(source) ~= "table" or #source == 0 then
        return {
            { time = 0, value = fallback, envelope = 0, synthetic = true },
            { time = 1, value = fallback, envelope = 0, synthetic = true },
        }
    end
    if #source > BeamGeometry.MAX_SEQUENCE_KEYPOINTS then
        return nil, label .. "_keypoint_cap_exceeded"
    end
    local points = {}
    for index = 1, #source do
        if cancelled(options, label .. "_sequence", index) then
            return nil, "cancelled"
        end
        local input = source[index]
        if type(input) == "table" then
            local time = number_or(input.time or input.Time or input[1], nil)
            local value = number_or(input.value or input.Value
                or input.transparency or input.Transparency or input[2], nil)
            if time ~= nil and value ~= nil then
                points[#points + 1] = {
                    time = clamp(time, 0, 1),
                    value = clamp(value, 0, 1),
                    envelope = math.max(0, number_or(input.envelope or input.Envelope
                        or input[3], 0)),
                    _order = index,
                }
            end
        end
    end
    if #points == 0 then return normalize_number_sequence(nil, fallback) end
    table.sort(points, function(a, b)
        if a.time == b.time then return a._order < b._order end
        return a.time < b.time
    end)
    local unique = {}
    for index = 1, #points do
        local point = points[index]
        point._order = nil
        if unique[#unique] and unique[#unique].time == point.time then
            unique[#unique] = point
        else
            unique[#unique + 1] = point
        end
    end
    if unique[1].time ~= 0 then
        table.insert(unique, 1, {
            time = 0, value = unique[1].value,
            envelope = unique[1].envelope, synthetic = true,
        })
    end
    if unique[#unique].time ~= 1 then
        unique[#unique + 1] = {
            time = 1, value = unique[#unique].value,
            envelope = unique[#unique].envelope, synthetic = true,
        }
    end
    return unique
end

local function normalize_color_sequence(raw, fallback, options)
    local constant = type(raw) == "table" and sequence_array(raw) == raw
        and #raw == 0 and raw or nil
    if constant and (raw.r ~= nil or raw.R ~= nil or raw[1] ~= nil) then
        local r, g, b = read_color(raw, fallback[1], fallback[2], fallback[3])
        return {
            { time = 0, color = vec(r, g, b), envelope = 0 },
            { time = 1, color = vec(r, g, b), envelope = 0 },
        }
    end
    local source = sequence_array(raw)
    if type(source) ~= "table" or #source == 0 then
        return {
            { time = 0, color = vec(unpack_values(fallback)), envelope = 0, synthetic = true },
            { time = 1, color = vec(unpack_values(fallback)), envelope = 0, synthetic = true },
        }
    end
    if #source > BeamGeometry.MAX_SEQUENCE_KEYPOINTS then
        return nil, "color_keypoint_cap_exceeded"
    end
    local points = {}
    for index = 1, #source do
        if cancelled(options, "color_sequence", index) then
            return nil, "cancelled"
        end
        local input = source[index]
        if type(input) == "table" then
            local time = number_or(input.time or input.Time or input[1], nil)
            local color = input.color or input.Color or input.value or input.Value
            if color == nil and type(input[2]) == "table" then color = input[2] end
            if time ~= nil and type(color) == "table" then
                local r, g, b = read_color(color, fallback[1], fallback[2], fallback[3])
                points[#points + 1] = {
                    time = clamp(time, 0, 1),
                    color = vec(r, g, b),
                    envelope = math.max(0, number_or(input.envelope or input.Envelope
                        or input[5], 0)),
                    _order = index,
                }
            end
        end
    end
    if #points == 0 then return normalize_color_sequence(nil, fallback) end
    table.sort(points, function(a, b)
        if a.time == b.time then return a._order < b._order end
        return a.time < b.time
    end)
    local unique = {}
    for index = 1, #points do
        local point = points[index]
        point._order = nil
        if unique[#unique] and unique[#unique].time == point.time then
            unique[#unique] = point
        else
            unique[#unique + 1] = point
        end
    end
    if unique[1].time ~= 0 then
        table.insert(unique, 1, {
            time = 0, color = vec(unpack_values(unique[1].color)),
            envelope = unique[1].envelope, synthetic = true,
        })
    end
    if unique[#unique].time ~= 1 then
        unique[#unique + 1] = {
            time = 1, color = vec(unpack_values(unique[#unique].color)),
            envelope = unique[#unique].envelope, synthetic = true,
        }
    end
    return unique
end

local function sample_number(points, time)
    time = clamp(number_or(time, 0), 0, 1)
    if time <= points[1].time then return points[1].value end
    for index = 2, #points do
        local right = points[index]
        if time <= right.time then
            local left = points[index - 1]
            local span = right.time - left.time
            if span <= 0 then return right.value end
            local alpha = (time - left.time) / span
            return left.value + (right.value - left.value) * alpha
        end
    end
    return points[#points].value
end

local function sample_color(points, time)
    time = clamp(number_or(time, 0), 0, 1)
    if time <= points[1].time then return unpack_values(points[1].color) end
    for index = 2, #points do
        local right = points[index]
        if time <= right.time then
            local left = points[index - 1]
            local span = right.time - left.time
            if span <= 0 then return unpack_values(right.color) end
            local alpha = (time - left.time) / span
            return left.color[1] + (right.color[1] - left.color[1]) * alpha,
                left.color[2] + (right.color[2] - left.color[2]) * alpha,
                left.color[3] + (right.color[3] - left.color[3]) * alpha
        end
    end
    return unpack_values(points[#points].color)
end

function BeamGeometry.sample_number_sequence(sequence, time)
    local points = sequence
    if type(points) ~= "table" or type(points[1]) ~= "table"
        or points[1].time == nil then
        points = normalize_number_sequence(sequence, 0)
    end
    return sample_number(points, time)
end

function BeamGeometry.sample_color_sequence(sequence, time)
    local points = sequence
    if type(points) ~= "table" or type(points[1]) ~= "table"
        or points[1].time == nil or points[1].color == nil then
        points = normalize_color_sequence(sequence, { 1, 1, 1 })
    end
    return sample_color(points, time)
end

local function evaluate_xyz(points, time)
    local inverse = 1 - time
    local w0 = inverse * inverse * inverse
    local w1 = 3 * inverse * inverse * time
    local w2 = 3 * inverse * time * time
    local w3 = time * time * time
    return clean(points[1][1] * w0 + points[2][1] * w1
            + points[3][1] * w2 + points[4][1] * w3),
        clean(points[1][2] * w0 + points[2][2] * w1
            + points[3][2] * w2 + points[4][2] * w3),
        clean(points[1][3] * w0 + points[2][3] * w1
            + points[3][3] * w2 + points[4][3] * w3)
end

local function derivative_xyz(points, time)
    local inverse = 1 - time
    local w0, w1, w2 = 3 * inverse * inverse,
        6 * inverse * time, 3 * time * time
    return clean((points[2][1] - points[1][1]) * w0
            + (points[3][1] - points[2][1]) * w1
            + (points[4][1] - points[3][1]) * w2),
        clean((points[2][2] - points[1][2]) * w0
            + (points[3][2] - points[2][2]) * w1
            + (points[4][2] - points[3][2]) * w2),
        clean((points[2][3] - points[1][3]) * w0
            + (points[3][3] - points[2][3]) * w1
            + (points[4][3] - points[3][3]) * w2)
end

function BeamGeometry.evaluate(control_points, time)
    if type(control_points) ~= "table" or #control_points < 4 then return nil end
    time = clamp(number_or(time, 0), 0, 1)
    return vec(evaluate_xyz(control_points, time))
end

function BeamGeometry.derivative(control_points, time)
    if type(control_points) ~= "table" or #control_points < 4 then return nil end
    time = clamp(number_or(time, 0), 0, 1)
    return vec(derivative_xyz(control_points, time))
end

local function resolve_budget(options)
    options = options or {}
    local max_segments = math.floor(clamp(number_or(options.max_segments,
        BeamGeometry.MAX_SEGMENTS), 1, BeamGeometry.MAX_SEGMENTS))
    local max_vertices = math.floor(clamp(number_or(options.max_vertices,
        BeamGeometry.MAX_VERTICES), 0, BeamGeometry.MAX_VERTICES))
    local max_indices = math.floor(clamp(number_or(options.max_indices,
        BeamGeometry.MAX_INDICES), 0, BeamGeometry.MAX_INDICES))
    local max_bytes = math.floor(clamp(number_or(options.max_resource_bytes
        or options.max_bytes, BeamGeometry.MAX_RESOURCE_BYTES), 0,
        BeamGeometry.MAX_RESOURCE_BYTES))
    local by_vertices = math.floor(max_vertices / 2) - 1
    local by_indices = math.floor(max_indices / 6)
    local per_segment_bytes = 2 * BeamGeometry.VERTEX_STRIDE_BYTES
        + 6 * BeamGeometry.INDEX_STRIDE_BYTES
    local by_bytes = math.floor((max_bytes
        - 2 * BeamGeometry.VERTEX_STRIDE_BYTES) / per_segment_bytes)
    max_segments = math.min(max_segments, by_vertices, by_indices, by_bytes)
    if max_segments < 1 then return nil, "resource_budget_too_small" end
    return {
        segments = max_segments,
        vertices = max_vertices,
        indices = max_indices,
        bytes = max_bytes,
    }
end

local function color_fallback(source)
    local r = property(source, "color_r", "ColorR")
    local g = property(source, "color_g", "ColorG")
    local b = property(source, "color_b", "ColorB")
    if r == nil or g == nil or b == nil then return { 1, 1, 1 } end
    r, g, b = number_or(r, 255), number_or(g, 255), number_or(b, 255)
    if math.max(math.abs(r), math.abs(g), math.abs(b)) > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end
    return { clamp(r, 0, 1), clamp(g, 0, 1), clamp(b, 0, 1) }
end

local function build_axis_sides(samples, frame0, frame1)
    local first_tangent = samples[1].tangent
    local side_x, side_y, side_z = project_unit(
        frame0.up[1], frame0.up[2], frame0.up[3],
        first_tangent[1], first_tangent[2], first_tangent[3])
    local forward = {}
    forward[1] = vec(side_x, side_y, side_z)
    for index = 2, #samples do
        local tangent = samples[index].tangent
        local previous = forward[index - 1]
        side_x, side_y, side_z = project_unit(
            previous[1], previous[2], previous[3],
            tangent[1], tangent[2], tangent[3],
            samples[index - 1].axis_seed[1],
            samples[index - 1].axis_seed[2],
            samples[index - 1].axis_seed[3])
        forward[index] = vec(side_x, side_y, side_z)
    end

    local last = samples[#samples]
    local target_x, target_y, target_z = project_unit(
        frame1.up[1], frame1.up[2], frame1.up[3],
        last.tangent[1], last.tangent[2], last.tangent[3])
    local transported = forward[#forward]
    local cx, cy, cz = cross(
        transported[1], transported[2], transported[3],
        target_x, target_y, target_z)
    local sine = dot(cx, cy, cz,
        last.tangent[1], last.tangent[2], last.tangent[3])
    local cosine = clamp(dot(
        transported[1], transported[2], transported[3],
        target_x, target_y, target_z), -1, 1)
    local endpoint_roll = atan2(sine, cosine)

    for index = 1, #samples do
        local sample = samples[index]
        local side = forward[index]
        side_x, side_y, side_z = rotate_about_axis(
            side[1], side[2], side[3],
            sample.tangent[1], sample.tangent[2], sample.tangent[3],
            endpoint_roll * sample.time)
        side_x, side_y, side_z = project_unit(
            side_x, side_y, side_z,
            sample.tangent[1], sample.tangent[2], sample.tangent[3])
        sample.axis_side = vec(side_x, side_y, side_z)
        sample.axis_seed = nil
    end
    return endpoint_roll
end

function BeamGeometry.build_recipe(source, options)
    options = options or {}
    if type(source) ~= "table" then return nil, "source_not_table" end
    if cancelled(options, "begin", 0) then return nil, "cancelled" end

    local budget, budget_error = resolve_budget(options)
    if not budget then return nil, budget_error end
    local frame0, frame0_error = read_frame(property(source,
        "attachment0_frame", "Attachment0Frame", "attachment0", "Attachment0"),
        "attachment0")
    if not frame0 then return nil, frame0_error end
    local frame1, frame1_error = read_frame(property(source,
        "attachment1_frame", "Attachment1Frame", "attachment1", "Attachment1"),
        "attachment1")
    if not frame1 then return nil, frame1_error end

    local curve0 = clamp(number_or(property(source, "curve_size0", "CurveSize0"), 0),
        -BeamGeometry.MAX_CURVE_SIZE, BeamGeometry.MAX_CURVE_SIZE)
    local curve1 = clamp(number_or(property(source, "curve_size1", "CurveSize1"), 0),
        -BeamGeometry.MAX_CURVE_SIZE, BeamGeometry.MAX_CURVE_SIZE)
    local p0, p3 = frame0.position, frame1.position
    local p1 = vec(p0[1] + frame0.right[1] * curve0,
        p0[2] + frame0.right[2] * curve0,
        p0[3] + frame0.right[3] * curve0)
    local p2 = vec(p3[1] - frame1.right[1] * curve1,
        p3[2] - frame1.right[2] * curve1,
        p3[3] - frame1.right[3] * curve1)
    for _, point in ipairs({ p1, p2 }) do
        if math.max(math.abs(point[1]), math.abs(point[2]), math.abs(point[3]))
            > BeamGeometry.MAX_ABS_COORDINATE then
            return nil, "control_point_limit"
        end
    end
    local control_points = {
        vec(unpack_values(p0)), p1, p2, vec(unpack_values(p3)),
    }

    local requested = math.floor(number_or(property(source, "segments", "Segments"),
        BeamGeometry.DEFAULT_SEGMENTS))
    if requested < 1 then requested = 1 end
    local segments = math.min(requested, budget.segments)
    local width0 = clamp(number_or(property(source, "width0", "Width0"), 1),
        0, BeamGeometry.MAX_WIDTH)
    local width1 = clamp(number_or(property(source, "width1", "Width1"), 1),
        0, BeamGeometry.MAX_WIDTH)
    local mode_name, mode_value = texture_mode(property(source,
        "texture_mode", "TextureMode"))
    local authored_texture_length = clamp(number_or(property(source,
        "texture_length", "TextureLength"), 1), 0,
        BeamGeometry.MAX_TEXTURE_LENGTH)
    local effective_texture_length = authored_texture_length
    if mode_name ~= "Stretch" and effective_texture_length < MIN_WRAP_TEXTURE_LENGTH then
        effective_texture_length = MIN_WRAP_TEXTURE_LENGTH
    end

    local fallback_color = color_fallback(source)
    local colors, color_error = normalize_color_sequence(property(source,
        "color", "Color"), fallback_color, options)
    if not colors then return nil, color_error end
    local transparencies, transparency_error = normalize_number_sequence(
        property(source, "transparency", "Transparency"), 0,
        options, "transparency")
    if not transparencies then return nil, transparency_error end

    local samples = {}
    local cumulative = 0
    for index = 0, segments do
        if cancelled(options, "sample", index) then return nil, "cancelled" end
        local time = index / segments
        local x, y, z = evaluate_xyz(control_points, time)
        local sample = {
            time = time,
            position = vec(x, y, z),
            width = clean(width0 + (width1 - width0) * time),
            transparency = sample_number(transparencies, time),
        }
        local r, g, b = sample_color(colors, time)
        sample.color = vec(r, g, b)
        if index > 0 then cumulative = cumulative + distance(samples[index].position, sample.position) end
        sample.arc_length = clean(cumulative)
        samples[index + 1] = sample
    end

    -- prefer the analytic derivative. at stationary/cusp samples, a centered
    -- chord preserves continuity, a fully degenerate curve falls back to the
    -- attachment axis without ever normalizing zero
    for index = 1, #samples do
        local sample = samples[index]
        local dx, dy, dz = derivative_xyz(control_points, sample.time)
        local _, tx, ty, tz = length_and_unit(dx, dy, dz)
        if tx == nil then
            local before = samples[math.max(1, index - 1)].position
            local after = samples[math.min(#samples, index + 1)].position
            _, tx, ty, tz = length_and_unit(
                after[1] - before[1], after[2] - before[2],
                after[3] - before[3])
        end
        if tx == nil then
            tx, ty, tz = frame0.right[1], frame0.right[2], frame0.right[3]
        end
        sample.tangent = vec(tx, ty, tz)
        sample.axis_seed = vec(unpack_values(frame0.up))
    end
    local endpoint_roll = build_axis_sides(samples, frame0, frame1)

    local total_length = samples[#samples].arc_length
    for index = 1, #samples do
        local sample = samples[index]
        if mode_name == "Stretch" then
            local progress = total_length > EPSILON
                and sample.arc_length / total_length or sample.time
            sample.base_u = clean(progress * authored_texture_length)
        else
            sample.base_u = clean(sample.arc_length / effective_texture_length)
        end
    end

    local face_camera = property(source, "face_camera", "FaceCamera") == true
    local z_offset = clamp(number_or(property(source, "z_offset", "ZOffset"), 0),
        -BeamGeometry.MAX_WIDTH, BeamGeometry.MAX_WIDTH)
    local texture_speed = clamp(number_or(property(source,
        "texture_speed", "TextureSpeed"), 1),
        -BeamGeometry.MAX_TEXTURE_SPEED, BeamGeometry.MAX_TEXTURE_SPEED)
    local uv_offset = clamp(number_or(property(source, "uv_offset", "UVOffset",
        "texture_offset", "TextureOffset"), 0),
        -BeamGeometry.MAX_TIME_SECONDS, BeamGeometry.MAX_TIME_SECONDS)
    local vertex_count = (segments + 1) * 2
    local index_count = segments * 6
    local resource_bytes = vertex_count * BeamGeometry.VERTEX_STRIDE_BYTES
        + index_count * BeamGeometry.INDEX_STRIDE_BYTES
    if vertex_count > budget.vertices or index_count > budget.indices
        or resource_bytes > budget.bytes
        or resource_bytes > BeamGeometry.MAX_RESOURCE_BYTES then
        return nil, "resource_cap_exceeded"
    end

    return {
        _rbx_beam_geometry_version = BeamGeometry.SEMANTICS_VERSION,
        control_points = control_points,
        attachment0_frame = frame0,
        attachment1_frame = frame1,
        curve_size0 = curve0,
        curve_size1 = curve1,
        segments = segments,
        segments_requested = requested,
        segments_clamped = segments ~= requested,
        samples = samples,
        total_length = clean(total_length),
        degenerate = total_length <= EPSILON,
        width0 = width0,
        width1 = width1,
        zero_width = width0 <= EPSILON and width1 <= EPSILON,
        color_keypoints = colors,
        transparency_keypoints = transparencies,
        sequence_envelope_policy = "deterministic_mean; envelope_ignored",
        texture = tostring(property(source, "texture", "Texture") or ""),
        texture_mode = mode_name,
        texture_mode_value = mode_value,
        texture_length = authored_texture_length,
        effective_texture_length = effective_texture_length,
        texture_speed = texture_speed,
        uv_offset = uv_offset,
        face_camera = face_camera,
        z_offset = z_offset,
        needs_view_rebake = face_camera or z_offset ~= 0,
        enabled = property(source, "enabled", "Enabled") ~= false
            and property(source, "visible", "Visible") ~= false,
        light_emission = clamp(number_or(property(source,
            "light_emission", "LightEmission"), 0), 0, 1),
        light_influence = clamp(number_or(property(source,
            "light_influence", "LightInfluence"), 1), 0, 1),
        brightness = clamp(number_or(property(source, "brightness", "Brightness"), 1),
            0, 10000),
        endpoint_roll = endpoint_roll,
        basis_sanitized = frame0.basis_sanitized or frame1.basis_sanitized,
        vertex_count = vertex_count,
        index_count = index_count,
        resource_bytes = resource_bytes,
    }
end

local function read_view_position(view)
    if type(view) ~= "table" then return nil end
    local value = property(view, "camera_position", "CameraPosition",
        "position", "Position")
    local x, y, z = vector_components(value)
    if x == nil then x, y, z = vector_components(view) end
    if x == nil then return nil end
    if math.max(math.abs(x), math.abs(y), math.abs(z))
        > BeamGeometry.MAX_ABS_COORDINATE then return nil end
    return x, y, z
end

local function srgb_to_linear(component)
    component = clamp(component, 0, 1)
    if component <= 0.04045 then return component / 12.92 end
    return ((component + 0.055) / 1.055) ^ 2.4
end

local function phase(value)
    value = number_or(value, 0)
    local wrapped = value - math.floor(value)
    if wrapped >= 1 then return 0 end
    return clean(wrapped)
end

function BeamGeometry.uv_phase(recipe, time_seconds, extra_offset)
    if type(recipe) ~= "table" then return nil end
    local time = clamp(number_or(time_seconds, 0),
        -BeamGeometry.MAX_TIME_SECONDS, BeamGeometry.MAX_TIME_SECONDS)
    local offset = clamp(number_or(extra_offset, 0),
        -BeamGeometry.MAX_TIME_SECONDS, BeamGeometry.MAX_TIME_SECONDS)
    -- Positive TextureSpeed moves an image feature from Attachment0 to
    -- Attachment1, hence sample coordinates move in the negative direction
    -- SetTextureOffset/UVOffset is documented to move in the inverse direction
    return phase(recipe.uv_offset + offset - recipe.texture_speed * time)
end

local function material_metadata(recipe, color_space)
    return {
        texture = recipe.texture,
        texture_mode = recipe.texture_mode,
        texture_mode_value = recipe.texture_mode_value,
        texture_length = recipe.texture_length,
        effective_texture_length = recipe.effective_texture_length,
        texture_speed = recipe.texture_speed,
        uv_offset = recipe.uv_offset,
        uv_scroll_cycles_per_second = -recipe.texture_speed,
        uv_scroll_direction = "Attachment0_to_Attachment1_for_positive_speed",
        sampler_u = "repeat",
        sampler_v = "clamp",
        authored_color_space = "srgb",
        vertex_color_space = color_space,
        vertex_alpha_mode = "straight",
        vertex_color_premultiplied = false,
        texture_premultiplication = "owned_by_texture_loader",
        shader_output_alpha_mode = "premultiplied",
        blend_mode = "alpha_premultiplied",
        light_emission = recipe.light_emission,
        light_influence = recipe.light_influence,
        brightness = recipe.brightness,
        z_offset = recipe.z_offset,
        double_sided = true,
    }
end

local function prepare_output(output)
    output = type(output) == "table" and output or {}
    local vertices = type(output.vertices) == "table" and output.vertices or {}
    local indices = type(output.indices) == "table" and output.indices or {}
    output.vertices, output.indices = vertices, indices
    return output, vertices, indices
end

local function trim_array(array, count)
    for index = #array, count + 1, -1 do array[index] = nil end
end

local function set_empty_resource(output, vertices, indices, recipe, reason, color_space)
    trim_array(vertices, 0)
    trim_array(indices, 0)
    output.kind = "indexed_ribbon20"
    output.draw_mode = "triangles"
    output.vertex_format = "rbx_textured_20f"
    output.vertex_floats = BeamGeometry.VERTEX_FLOATS
    output.vertex_stride_bytes = BeamGeometry.VERTEX_STRIDE_BYTES
    output.index_type = "uint16"
    output.index_stride_bytes = BeamGeometry.INDEX_STRIDE_BYTES
    output.vertex_count = 0
    output.index_count = 0
    output.byte_size = 0
    output.bounds = nil
    output.empty_reason = reason
    output.view_dependent = recipe.needs_view_rebake
    output.face_camera = recipe.face_camera
    output.material = material_metadata(recipe, color_space)
    output.contract = {
        rows_are_finite = true,
        winding = "counter_clockwise_for_VertexNormal",
        cull_mode = "none",
        love_userdata = false,
    }
    return output
end

local function set_row(row, px, py, pz, nx, ny, nz, u, v,
        r, g, b, a, tx, ty, tz, sx, sy, sz)
    row[1], row[2], row[3] = clean(px), clean(py), clean(pz)
    row[4], row[5], row[6] = clean(nx), clean(ny), clean(nz)
    row[7], row[8] = clean(u), clean(v)
    row[9], row[10], row[11], row[12] = clean(r), clean(g), clean(b), clean(a)
    row[13] = 0
    row[14], row[15], row[16] = clean(tx), clean(ty), clean(tz)
    row[17], row[18], row[19] = clean(sx), clean(sy), clean(sz)
    row[20] = 1
    trim_array(row, BeamGeometry.VERTEX_FLOATS)
end

function BeamGeometry.bake(recipe, view, options)
    options = options or {}
    if type(recipe) ~= "table"
        or recipe._rbx_beam_geometry_version ~= BeamGeometry.SEMANTICS_VERSION then
        return nil, "invalid_recipe"
    end
    if cancelled(options, "bake_begin", 0) then return nil, "cancelled" end
    local output, vertices, indices = prepare_output(options.output)
    local color_space = options.vertex_color_space
    local color_transform = options.color_transform
    if type(color_transform) == "function" then
        color_space = color_space or "custom"
    elseif color_space == "srgb" then
        color_transform = function(r, g, b) return r, g, b end
    else
        color_space = "linear"
        color_transform = function(r, g, b)
            return srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)
        end
    end

    if not recipe.enabled then
        return set_empty_resource(output, vertices, indices, recipe,
            "disabled", color_space)
    end
    if recipe.degenerate then
        return set_empty_resource(output, vertices, indices, recipe,
            "degenerate_centerline", color_space)
    end
    if recipe.zero_width then
        return set_empty_resource(output, vertices, indices, recipe,
            "zero_width", color_space)
    end

    local camera_x, camera_y, camera_z = read_view_position(view)
    if recipe.needs_view_rebake and camera_x == nil then
        return nil, "view_required"
    end
    local time_seconds = property(options, "time_seconds", "TimeSeconds")
    if time_seconds == nil then
        time_seconds = property(view, "time_seconds", "TimeSeconds", "time", "Time")
    end
    local extra_offset = property(options, "uv_offset", "UVOffset")
    local uv_phase = BeamGeometry.uv_phase(recipe, time_seconds, extra_offset)

    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
    local previous_side
    local collinear_fallbacks, z_fallbacks = 0, 0
    for index = 1, #recipe.samples do
        if cancelled(options, "bake_sample", index) then return nil, "cancelled" end
        local sample = recipe.samples[index]
        local tangent, axis_side = sample.tangent, sample.axis_side
        local center = sample.position
        local cx, cy, cz = center[1], center[2], center[3]
        local view_x, view_y, view_z
        if camera_x ~= nil then
            view_x, view_y, view_z = camera_x - cx, camera_y - cy, camera_z - cz
        end

        if recipe.z_offset ~= 0 then
            local _, zx, zy, zz = length_and_unit(view_x, view_y, view_z)
            if zx == nil then
                zx, zy, zz = cross(
                    tangent[1], tangent[2], tangent[3],
                    axis_side[1], axis_side[2], axis_side[3])
                local _, ux, uy, uz = length_and_unit(zx, zy, zz)
                zx, zy, zz = ux or 0, uy or 0, uz or 1
                z_fallbacks = z_fallbacks + 1
            end
            cx, cy, cz = cx + zx * recipe.z_offset,
                cy + zy * recipe.z_offset, cz + zz * recipe.z_offset
            view_x, view_y, view_z = camera_x - cx, camera_y - cy, camera_z - cz
        end

        local side_x, side_y, side_z
        if recipe.face_camera then
            local raw_x, raw_y, raw_z = cross(
                view_x, view_y, view_z,
                tangent[1], tangent[2], tangent[3])
            local _, ux, uy, uz = length_and_unit(raw_x, raw_y, raw_z)
            if ux == nil then
                local fallback = previous_side or axis_side
                ux, uy, uz = project_unit(
                    fallback[1], fallback[2], fallback[3],
                    tangent[1], tangent[2], tangent[3],
                    axis_side[1], axis_side[2], axis_side[3])
                collinear_fallbacks = collinear_fallbacks + 1
            end
            side_x, side_y, side_z = ux, uy, uz
        else
            side_x, side_y, side_z = axis_side[1], axis_side[2], axis_side[3]
        end
        previous_side = vec(side_x, side_y, side_z)
        local normal_x, normal_y, normal_z = cross(
            tangent[1], tangent[2], tangent[3], side_x, side_y, side_z)
        local _, nnx, nny, nnz = length_and_unit(normal_x, normal_y, normal_z)
        if nnx == nil then
            nnx, nny, nnz = orthogonal_to(
                tangent[1], tangent[2], tangent[3])
        end

        local half_width = sample.width * 0.5
        local left_x, left_y, left_z = cx - side_x * half_width,
            cy - side_y * half_width, cz - side_z * half_width
        local right_x, right_y, right_z = cx + side_x * half_width,
            cy + side_y * half_width, cz + side_z * half_width
        local authored = sample.color
        local ok, r, g, b = pcall(color_transform,
            authored[1], authored[2], authored[3])
        if not ok or not (finite(r) and finite(g) and finite(b)) then
            return nil, "non_finite_color_transform"
        end
        r, g, b = clamp(r, 0, 1), clamp(g, 0, 1), clamp(b, 0, 1)
        local alpha = clamp(1 - sample.transparency, 0, 1)
        local u = clean(sample.base_u + uv_phase)
        local left_index, right_index = index * 2 - 1, index * 2
        local left_row = type(vertices[left_index]) == "table"
            and vertices[left_index] or {}
        local right_row = type(vertices[right_index]) == "table"
            and vertices[right_index] or {}
        vertices[left_index], vertices[right_index] = left_row, right_row
        set_row(left_row, left_x, left_y, left_z, nnx, nny, nnz,
            u, 0, r, g, b, alpha,
            tangent[1], tangent[2], tangent[3], side_x, side_y, side_z)
        set_row(right_row, right_x, right_y, right_z, nnx, nny, nnz,
            u, 1, r, g, b, alpha,
            tangent[1], tangent[2], tangent[3], side_x, side_y, side_z)

        min_x, min_y, min_z = math.min(min_x, left_x, right_x),
            math.min(min_y, left_y, right_y), math.min(min_z, left_z, right_z)
        max_x, max_y, max_z = math.max(max_x, left_x, right_x),
            math.max(max_y, left_y, right_y), math.max(max_z, left_z, right_z)
    end
    trim_array(vertices, recipe.vertex_count)

    local cursor = 1
    for segment = 1, recipe.segments do
        if cancelled(options, "bake_indices", segment) then return nil, "cancelled" end
        local left0, right0 = segment * 2 - 1, segment * 2
        local left1, right1 = left0 + 2, right0 + 2
        -- cross(L1-L0, R0-L0) agrees with VertexNormal
        indices[cursor], indices[cursor + 1], indices[cursor + 2] =
            left0, left1, right0
        indices[cursor + 3], indices[cursor + 4], indices[cursor + 5] =
            right0, left1, right1
        cursor = cursor + 6
    end
    trim_array(indices, recipe.index_count)

    local center_x, center_y, center_z = (min_x + max_x) * 0.5,
        (min_y + max_y) * 0.5, (min_z + max_z) * 0.5
    local extent_x, extent_y, extent_z = (max_x - min_x) * 0.5,
        (max_y - min_y) * 0.5, (max_z - min_z) * 0.5
    output.kind = "indexed_ribbon20"
    output.draw_mode = "triangles"
    output.vertex_format = "rbx_textured_20f"
    output.vertex_floats = BeamGeometry.VERTEX_FLOATS
    output.vertex_stride_bytes = BeamGeometry.VERTEX_STRIDE_BYTES
    output.index_type = "uint16"
    output.index_stride_bytes = BeamGeometry.INDEX_STRIDE_BYTES
    output.vertex_count = recipe.vertex_count
    output.index_count = recipe.index_count
    output.byte_size = recipe.resource_bytes
    output.empty_reason = nil
    output.bounds = {
        min_x = clean(min_x), min_y = clean(min_y), min_z = clean(min_z),
        max_x = clean(max_x), max_y = clean(max_y), max_z = clean(max_z),
        center_x = clean(center_x), center_y = clean(center_y), center_z = clean(center_z),
        extent_x = clean(extent_x), extent_y = clean(extent_y), extent_z = clean(extent_z),
        radius = clean(math.sqrt(extent_x * extent_x
            + extent_y * extent_y + extent_z * extent_z)),
    }
    output.view_dependent = recipe.needs_view_rebake
    output.face_camera = recipe.face_camera
    output.camera_collinear_fallbacks = collinear_fallbacks
    output.z_offset_fallbacks = z_fallbacks
    output.uv_phase = uv_phase
    output.material = material_metadata(recipe, color_space)
    output.contract = {
        rows_are_finite = true,
        winding = "counter_clockwise_for_VertexNormal",
        cull_mode = "none",
        love_userdata = false,
    }
    return output
end

function BeamGeometry.build(source, view, options)
    local recipe, recipe_error = BeamGeometry.build_recipe(source, options)
    if not recipe then return nil, recipe_error end
    local resource, resource_error = BeamGeometry.bake(recipe, view, options)
    if not resource then return nil, resource_error end
    return resource, nil, recipe
end

function BeamGeometry.pack_resource(resource)
    if not ffi_ok then return nil, "ffi_unavailable" end
    if type(resource) ~= "table" or type(resource.vertices) ~= "table"
        or type(resource.indices) ~= "table" then
        return nil, "invalid_resource"
    end
    local vertex_count = tonumber(resource.vertex_count)
    local index_count = tonumber(resource.index_count)
    if not finite(vertex_count) or not finite(index_count)
        or vertex_count ~= math.floor(vertex_count)
        or index_count ~= math.floor(index_count)
        or vertex_count < 0 or index_count < 0
        or vertex_count > BeamGeometry.MAX_VERTICES
        or index_count > BeamGeometry.MAX_INDICES then
        return nil, "resource_cap_exceeded"
    end
    local floats = ffi.new("float[?]", math.max(1,
        vertex_count * BeamGeometry.VERTEX_FLOATS))
    local cursor = 0
    for vertex_index = 1, vertex_count do
        local row = resource.vertices[vertex_index]
        if type(row) ~= "table" or #row ~= BeamGeometry.VERTEX_FLOATS then
            return nil, "invalid_vertex_row"
        end
        for component = 1, BeamGeometry.VERTEX_FLOATS do
            local value = row[component]
            if not finite(value) then return nil, "non_finite_vertex" end
            floats[cursor] = value
            if not finite(tonumber(floats[cursor])) then
                return nil, "float32_overflow"
            end
            cursor = cursor + 1
        end
    end
    local index_data = ffi.new("uint16_t[?]", math.max(1, index_count))
    for index = 1, index_count do
        local value = resource.indices[index]
        if not finite(value) or value ~= math.floor(value)
            or value < 1 or value > vertex_count then
            return nil, "invalid_index"
        end
        index_data[index - 1] = value
    end
    return {
        vertex_bytes = ffi.string(floats,
            vertex_count * BeamGeometry.VERTEX_STRIDE_BYTES),
        index_bytes = ffi.string(index_data,
            index_count * BeamGeometry.INDEX_STRIDE_BYTES),
        byte_size = vertex_count * BeamGeometry.VERTEX_STRIDE_BYTES
            + index_count * BeamGeometry.INDEX_STRIDE_BYTES,
        byte_order = "native_little_endian",
        vertex_encoding = "float32",
        index_encoding = "uint16",
    }
end

return BeamGeometry
