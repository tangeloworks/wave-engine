local abs = math.abs

local mat3 = {}

function mat3.zero()
    return { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
end

function mat3.identity()
    return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

function mat3.diag(xx, yy, zz)
    return { xx or 0, 0, 0, 0, yy or 0, 0, 0, 0, zz or 0 }
end

function mat3.transpose(m)
    return {
        m[1], m[4], m[7],
        m[2], m[5], m[8],
        m[3], m[6], m[9],
    }
end

function mat3.apply(m, x, y, z)
    return m[1] * x + m[2] * y + m[3] * z,
        m[4] * x + m[5] * y + m[6] * z,
        m[7] * x + m[8] * y + m[9] * z
end

function mat3.mul(a, b)
    return {
        a[1] * b[1] + a[2] * b[4] + a[3] * b[7],
        a[1] * b[2] + a[2] * b[5] + a[3] * b[8],
        a[1] * b[3] + a[2] * b[6] + a[3] * b[9],
        a[4] * b[1] + a[5] * b[4] + a[6] * b[7],
        a[4] * b[2] + a[5] * b[5] + a[6] * b[8],
        a[4] * b[3] + a[5] * b[6] + a[6] * b[9],
        a[7] * b[1] + a[8] * b[4] + a[9] * b[7],
        a[7] * b[2] + a[8] * b[5] + a[9] * b[8],
        a[7] * b[3] + a[8] * b[6] + a[9] * b[9],
    }
end

function mat3.add_inplace(a, b)
    for index = 1, 9 do
        a[index] = (a[index] or 0) + (b[index] or 0)
    end
    return a
end

function mat3.inverse(m)
    local a00, a01, a02 = m[1], m[2], m[3]
    local a10, a11, a12 = m[4], m[5], m[6]
    local a20, a21, a22 = m[7], m[8], m[9]
    local c00 = a11 * a22 - a12 * a21
    local c01 = a02 * a21 - a01 * a22
    local c02 = a01 * a12 - a02 * a11
    local c10 = a12 * a20 - a10 * a22
    local c11 = a00 * a22 - a02 * a20
    local c12 = a02 * a10 - a00 * a12
    local c20 = a10 * a21 - a11 * a20
    local c21 = a01 * a20 - a00 * a21
    local c22 = a00 * a11 - a01 * a10
    local det = a00 * c00 + a01 * c10 + a02 * c20
    if abs(det or 0) <= 1e-12 then
        return mat3.zero()
    end
    local inv_det = 1 / det
    return {
        c00 * inv_det, c01 * inv_det, c02 * inv_det,
        c10 * inv_det, c11 * inv_det, c12 * inv_det,
        c20 * inv_det, c21 * inv_det, c22 * inv_det,
    }
end

return mat3
