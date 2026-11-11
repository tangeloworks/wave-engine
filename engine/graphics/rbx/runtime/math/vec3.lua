local sqrt = math.sqrt

local vec3 = {}

function vec3.new(x, y, z)
    return { x = x or 0, y = y or 0, z = z or 0 }
end

function vec3.copy(value)
    return {
        x = value and value.x or 0,
        y = value and value.y or 0,
        z = value and value.z or 0,
    }
end

function vec3.dot_xyz(ax, ay, az, bx, by, bz)
    return ax * bx + ay * by + az * bz
end

function vec3.cross_xyz(ax, ay, az, bx, by, bz)
    return ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx
end

function vec3.length2_xyz(x, y, z)
    return x * x + y * y + z * z
end

function vec3.length_xyz(x, y, z)
    return sqrt(vec3.length2_xyz(x, y, z))
end

function vec3.normalize_xyz(x, y, z, fallback_x, fallback_y, fallback_z)
    local length = vec3.length_xyz(x, y, z)
    if length <= 1e-12 then
        return fallback_x or 0, fallback_y or 0, fallback_z or 0
    end
    return x / length, y / length, z / length
end

function vec3.scale(value, scalar)
    return {
        x = (value and value.x or 0) * (scalar or 0),
        y = (value and value.y or 0) * (scalar or 0),
        z = (value and value.z or 0) * (scalar or 0),
    }
end

function vec3.add(a, b)
    return {
        x = (a and a.x or 0) + (b and b.x or 0),
        y = (a and a.y or 0) + (b and b.y or 0),
        z = (a and a.z or 0) + (b and b.z or 0),
    }
end

function vec3.sub(a, b)
    return {
        x = (a and a.x or 0) - (b and b.x or 0),
        y = (a and a.y or 0) - (b and b.y or 0),
        z = (a and a.z or 0) - (b and b.z or 0),
    }
end

return vec3
