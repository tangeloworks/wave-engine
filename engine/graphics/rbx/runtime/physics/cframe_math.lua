-- CFrame math for assemblies and physics, independent of the graphics context
-- flat {x,y,z,r00..r22}, world=t+r*local, rigid: p0*c0==p1*c1, motor6d: p1=p0*c0*transform*c1^-1

local Integrate = runtime_require("physics/integrate.lua")

local CFrameMath = {}

local abs = math.abs
local max = math.max

-- nil -> identity, lua 0 is truthy so 'or 1' only fills real nils
local function unpack_cf(cf)
    if cf == nil then
        return 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1
    end
    return
        tonumber(cf.x) or 0, tonumber(cf.y) or 0, tonumber(cf.z) or 0,
        tonumber(cf.r00) or 1, tonumber(cf.r01) or 0, tonumber(cf.r02) or 0,
        tonumber(cf.r10) or 0, tonumber(cf.r11) or 1, tonumber(cf.r12) or 0,
        tonumber(cf.r20) or 0, tonumber(cf.r21) or 0, tonumber(cf.r22) or 1
end
CFrameMath.unpack = unpack_cf

local function pack_cf(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    return {
        x = x, y = y, z = z,
        r00 = r00, r01 = r01, r02 = r02,
        r10 = r10, r11 = r11, r12 = r12,
        r20 = r20, r21 = r21, r22 = r22,
    }
end
CFrameMath.pack = pack_cf

function CFrameMath.identity()
    return pack_cf(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
end

-- a*b: r=a.r·b.r, t=a.t+a.r·b.t
function CFrameMath.compose_scalar(
    ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22,
    bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22)
    local r00 = a00 * b00 + a01 * b10 + a02 * b20
    local r01 = a00 * b01 + a01 * b11 + a02 * b21
    local r02 = a00 * b02 + a01 * b12 + a02 * b22
    local r10 = a10 * b00 + a11 * b10 + a12 * b20
    local r11 = a10 * b01 + a11 * b11 + a12 * b21
    local r12 = a10 * b02 + a11 * b12 + a12 * b22
    local r20 = a20 * b00 + a21 * b10 + a22 * b20
    local r21 = a20 * b01 + a21 * b11 + a22 * b21
    local r22 = a20 * b02 + a21 * b12 + a22 * b22
    local x = ax + a00 * bx + a01 * by + a02 * bz
    local y = ay + a10 * bx + a11 * by + a12 * bz
    local z = az + a20 * bx + a21 * by + a22 * bz
    return x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22
end

-- r^-1=r^t (assumes orthonormal), t'=-r^t·t
function CFrameMath.inverse_scalar(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    local i00, i01, i02 = r00, r10, r20
    local i10, i11, i12 = r01, r11, r21
    local i20, i21, i22 = r02, r12, r22
    local ix = -(i00 * x + i01 * y + i02 * z)
    local iy = -(i10 * x + i11 * y + i12 * z)
    local iz = -(i20 * x + i21 * y + i22 * z)
    return ix, iy, iz, i00, i01, i02, i10, i11, i12, i20, i21, i22
end

-- table wrappers
function CFrameMath.mul(a, b)
    local ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22 = unpack_cf(a)
    local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 = unpack_cf(b)
    return pack_cf(CFrameMath.compose_scalar(
        ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22,
        bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22))
end

function CFrameMath.inv(a)
    return pack_cf(CFrameMath.inverse_scalar(unpack_cf(a)))
end

function CFrameMath.from_part(view)
    local pos = (view and view.Position) or nil
    local cf = (view and view.CFrameRef) or nil
    local px = pos and (pos.x or pos.X) or 0
    local py = pos and (pos.y or pos.Y) or 0
    local pz = pos and (pos.z or pos.Z) or 0
    if cf == nil then
        return pack_cf(px, py, pz, 1, 0, 0, 0, 1, 0, 0, 0, 1)
    end
    return pack_cf(px, py, pz,
        cf.r00 or 1, cf.r01 or 0, cf.r02 or 0,
        cf.r10 or 0, cf.r11 or 1, cf.r12 or 0,
        cf.r20 or 0, cf.r21 or 0, cf.r22 or 1)
end

function CFrameMath.transform_point(cf, px, py, pz)
    local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = unpack_cf(cf)
    return x + r00 * px + r01 * py + r02 * pz,
        y + r10 * px + r11 * py + r12 * pz,
        z + r20 * px + r21 * py + r22 * pz
end

-- -> max_pos, max_rot (per-component max-abs)
local function cf_diff(a, b)
    local ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22 = unpack_cf(a)
    local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 = unpack_cf(b)
    local mp = max(abs(ax - bx), abs(ay - by), abs(az - bz))
    local mr = max(
        abs(a00 - b00), abs(a01 - b01), abs(a02 - b02),
        abs(a10 - b10), abs(a11 - b11), abs(a12 - b12),
        abs(a20 - b20), abs(a21 - b21), abs(a22 - b22))
    return mp, mr
end
CFrameMath.diff = cf_diff

function CFrameMath.approx_equal(a, b, eps_pos, eps_rot)
    local mp, mr = cf_diff(a, b)
    return mp <= (eps_pos or 1e-4) and mr <= (eps_rot or 1e-4), mp, mr
end

function CFrameMath.is_identity(cf, eps_pos, eps_rot)
    return (CFrameMath.approx_equal(cf, CFrameMath.identity(), eps_pos or 1e-6, eps_rot or 1e-6))
end

-- p0*c0==p1*c1 within tol -> ok,max_pos_err,max_rot_err
function CFrameMath.weld_relation_ok(part0_cf, c0, part1_cf, c1, eps_pos, eps_rot)
    local left = CFrameMath.mul(part0_cf, c0)
    local right = CFrameMath.mul(part1_cf, c1)
    local mp, mr = cf_diff(left, right)
    return mp <= (eps_pos or 1e-4) and mr <= (eps_rot or 1e-4), mp, mr
end

-- p1 = p0*c0*transform*c1^-1
function CFrameMath.motor6d_part1_cframe(part0_cf, c0, transform, c1)
    local acc = CFrameMath.mul(part0_cf, c0)
    acc = CFrameMath.mul(acc, transform)
    acc = CFrameMath.mul(acc, CFrameMath.inv(c1))
    return acc
end

-- transform=identity
function CFrameMath.weld_part1_cframe(part0_cf, c0, c1)
    return CFrameMath.motor6d_part1_cframe(part0_cf, c0, CFrameMath.identity(), c1)
end

-- p1 = p0_now*c0*transform*rel_j, rel_j captured at bind
-- reproduces authored p1 at rest even w/ stale c1, so follower never flips
function CFrameMath.motor6d_rest_relative(part0_cf, c0, transform, rel_j)
    local acc = CFrameMath.mul(part0_cf, c0)
    acc = CFrameMath.mul(acc, transform)
    return CFrameMath.mul(acc, rel_j)
end

-- gram-schmidt anchored on +z so the joint axle survives, x/y drift cleaned
function CFrameMath.orthonormalize_rot(cf)
    local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = unpack_cf(cf)
    -- columns: col0=(r00,r10,r20) +x, col1=(r01,r11,r21) +y, col2=(r02,r12,r22) +z
    local zx, zy, zz = r02, r12, r22
    local zl = (zx * zx + zy * zy + zz * zz) ^ 0.5
    if zl < 1e-9 then
        zx, zy, zz, zl = 0, 0, 1, 1
    end
    zx, zy, zz = zx / zl, zy / zl, zz / zl
    -- x from col0, project out z
    local ux, uy, uz = r00, r10, r20
    local d = ux * zx + uy * zy + uz * zz
    ux, uy, uz = ux - d * zx, uy - d * zy, uz - d * zz
    local ul = (ux * ux + uy * uy + uz * uz) ^ 0.5
    if ul < 1e-9 then
        -- col0 parallel to z, seed from axis least aligned with z
        local sx, sy, sz = 1, 0, 0
        if abs(zx) >= abs(zy) and abs(zx) >= abs(zz) then sx, sy, sz = 0, 1, 0 end
        local d2 = sx * zx + sy * zy + sz * zz
        ux, uy, uz = sx - d2 * zx, sy - d2 * zy, sz - d2 * zz
        ul = (ux * ux + uy * uy + uz * uz) ^ 0.5
    end
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    -- y = z x x (right-handed)
    local vx = zy * uz - zz * uy
    local vy = zz * ux - zx * uz
    local vz = zx * uy - zy * ux
    return pack_cf(x, y, z,
        ux, vx, zx,
        uy, vy, zy,
        uz, vz, zz)
end

-- rotation only
function CFrameMath.to_quat(cf)
    local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = unpack_cf(cf)
    return Integrate.quat_from_matrix(r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

return CFrameMath
