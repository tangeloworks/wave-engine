local cos = math.cos
local sin = math.sin
local sqrt = math.sqrt

local vec3 = runtime_require("math/vec3.lua")
local mat3 = runtime_require("math/mat3.lua")

local quat = {}

function quat.new(x, y, z, w)
    return { x = x or 0, y = y or 0, z = z or 0, w = w or 1 }
end

function quat.normalize(q)
    local length = sqrt((q.x * q.x) + (q.y * q.y) + (q.z * q.z) + (q.w * q.w))
    if length <= 1e-12 then
        return quat.new()
    end
    return quat.new(q.x / length, q.y / length, q.z / length, q.w / length)
end

function quat.from_axis_angle(ax, ay, az, angle)
    local nx, ny, nz = vec3.normalize_xyz(ax, ay, az, 1, 0, 0)
    local half = (angle or 0) * 0.5
    local scale = sin(half)
    return quat.normalize(quat.new(nx * scale, ny * scale, nz * scale, cos(half)))
end

function quat.mul(a, b)
    return quat.normalize(quat.new(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    ))
end

function quat.from_matrix(m)
    local trace = m[1] + m[5] + m[9]
    if trace > 0 then
        local s = sqrt(trace + 1) * 2
        return quat.normalize(quat.new(
            (m[8] - m[6]) / s,
            (m[3] - m[7]) / s,
            (m[4] - m[2]) / s,
            0.25 * s
        ))
    end
    return quat.new()
end

function quat.to_matrix(q)
    local x2, y2, z2 = q.x + q.x, q.y + q.y, q.z + q.z
    local xx, xy, xz = q.x * x2, q.x * y2, q.x * z2
    local yy, yz, zz = q.y * y2, q.y * z2, q.z * z2
    local wx, wy, wz = q.w * x2, q.w * y2, q.w * z2
    return {
        1 - (yy + zz), xy - wz, xz + wy,
        xy + wz, 1 - (xx + zz), yz - wx,
        xz - wy, yz + wx, 1 - (xx + yy),
    }
end

function quat.integrate_rotation_matrix(rotation, wx, wy, wz, dt)
    local speed = sqrt(vec3.length2_xyz(wx, wy, wz))
    if speed <= 1e-8 then
        return rotation or mat3.identity()
    end
    local delta = quat.from_axis_angle(wx, wy, wz, speed * dt)
    local current = quat.from_matrix(rotation or mat3.identity())
    return quat.to_matrix(quat.mul(delta, current))
end

return quat
