-- joint-frame math for snap/weld/legacy-surface joints, pure numbers on cframe_math's flat cframe
-- face convention matches surface_welds.lua/normalid (right+x/left-x/top+y/bottom-y/back+z/front-z), tangents always det +1

local CFrameMath = runtime_require("physics/cframe_math.lua")

local JointFrames = {}

local abs = math.abs
local acos = math.acos
local sqrt = math.sqrt

-- normalid -> outward normal
local FACE_NORMAL = {
    Right  = { 1, 0, 0 },
    Left   = { -1, 0, 0 },
    Top    = { 0, 1, 0 },
    Bottom = { 0, -1, 0 },
    Back   = { 0, 0, 1 },
    Front  = { 0, 0, -1 },
}
-- enum.normalid order
local FACE_BY_INDEX = { [0] = "Right", [1] = "Top", [2] = "Back", [3] = "Left", [4] = "Bottom", [5] = "Front" }

-- name or 0..5 index -> "Top".. or nil
local function canon_face(id)
    if type(id) == "number" then
        return FACE_BY_INDEX[id]
    end
    if type(id) ~= "string" then
        return nil
    end
    if FACE_NORMAL[id] then
        return id
    end
    -- accept lowercase / surface-key form too
    local cap = id:sub(1, 1):upper() .. id:sub(2):lower()
    if FACE_NORMAL[cap] then
        return cap
    end
    return nil
end
JointFrames.canon_face = canon_face
JointFrames.face_normal = function(id)
    local f = canon_face(id)
    local n = f and FACE_NORMAL[f]
    if n == nil then return nil end
    return n[1], n[2], n[3]
end

local function vlen(x, y, z) return sqrt(x * x + y * y + z * z) end

-- frame for a normalid: translation = face center, +z = outward normal, +x/+y right-handed tangents (det +1)
-- nil sx/sy/sz = unit box, what rotatev's axle wants (direction only)
function JointFrames.face_basis(normalId, sx, sy, sz)
    local f = canon_face(normalId)
    local n = f and FACE_NORMAL[f]
    if n == nil then
        return CFrameMath.identity()
    end
    local nx, ny, nz = n[1], n[2], n[3]
    -- ref up = world +y, top/bottom fall back to +x (else degenerate projection)
    local rx, ry, rz = 0, 1, 0
    if abs(ny) > 0.5 then
        rx, ry, rz = 1, 0, 0
    end
    -- u = normalize(ref - (ref . n) n)
    local d = rx * nx + ry * ny + rz * nz
    local ux, uy, uz = rx - d * nx, ry - d * ny, rz - d * nz
    local ul = vlen(ux, uy, uz)
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    -- v = n x u  (right-handed -> det +1)
    local vx = ny * uz - nz * uy
    local vy = nz * ux - nx * uz
    local vz = nx * uy - ny * ux
    -- columns (u, v, n)
    local hx = (sx and 0.5 * nx * sx) or (0.5 * nx)
    local hy = (sy and 0.5 * ny * sy) or (0.5 * ny)
    local hz = (sz and 0.5 * nz * sz) or (0.5 * nz)
    return CFrameMath.pack(hx, hy, hz,
        ux, vx, nx,
        uy, vy, ny,
        uz, vz, nz)
end

-- re-exported from cframe_math
JointFrames.weld_relation_ok = CFrameMath.weld_relation_ok
JointFrames.weld_part1_cframe = CFrameMath.weld_part1_cframe

-- relabel only: newc0=c1, newc1=c0 preserves the world relation, no inverse needed
function JointFrames.swap(c0, c1)
    return c1, c0
end

-- nil -> 0, tolerates x/X casing
local function size_of(view)
    local s = view and view.Size
    if s == nil then return 0, 0, 0 end
    return abs((s.x or s.X) or 0), abs((s.y or s.Y) or 0), abs((s.z or s.Z) or 0)
end
JointFrames.size_of = size_of

-- rx(pi), det +1: flips +z/+y keeps +x -> mated faces anti-parallel, chirality preserved
-- not a mirror (mirror = spurious wrong-side twist)
local FLIP_RX = CFrameMath.pack(0, 0, 0, 1, 0, 0, 0, -1, 0, 0, 0, -1)
JointFrames.FLIP_RX = FLIP_RX

-- c0=face_basis(s0), c1=face_basis(s1)*flip_rx -> coincident faces, anti-parallel normals
function JointFrames.derive_surface_c0_c1(part0_view, s0, part1_view, s1)
    local s0x, s0y, s0z = size_of(part0_view)
    local s1x, s1y, s1z = size_of(part1_view)
    local c0 = JointFrames.face_basis(s0, s0x, s0y, s0z)
    local c1raw = JointFrames.face_basis(s1, s1x, s1y, s1z)
    local c1 = CFrameMath.mul(c1raw, FLIP_RX)
    return c0, c1
end

-- keeps authored poses+c1, recomputes c0 so the weld invariant holds exactly: c0'=inv(p0)*p1*c1
function JointFrames.rederive_consistent_c0_c1(part0_cf, part1_cf, c0_authored, c1_authored)
    local c1 = c1_authored or CFrameMath.identity()
    local c0 = CFrameMath.mul(CFrameMath.mul(CFrameMath.inv(part0_cf), part1_cf), c1)
    return c0, c1
end

-- = frame's local +z column, already unit
function JointFrames.face_normal_world(frame)
    local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = CFrameMath.unpack(frame)
    return r02, r12, r22
end

local function clamp1(v)
    if v > 1 then return 1 elseif v < -1 then return -1 else return v end
end

-- rad: acos((trace(inv(a).r*b.r)-1)/2)
local function rot_geodesic(a, b)
    local m = CFrameMath.mul(CFrameMath.inv(a), b)
    local _, _, _, r00, _, _, _, r11, _, _, _, r22 = CFrameMath.unpack(m)
    return acos(clamp1((r00 + r11 + r22 - 1) * 0.5))
end
JointFrames.rot_geodesic = rot_geodesic

-- geometry-derived face frame (expected) vs authored c0 (actual), both world-space
function JointFrames.face_diagnostics(part0_cf, s0, size0, c0)
    local sx, sy, sz
    if type(size0) == "table" and (size0.Size ~= nil) then
        sx, sy, sz = size_of(size0)
    elseif type(size0) == "table" then
        sx, sy, sz = abs((size0.x or size0.X) or 0), abs((size0.y or size0.Y) or 0), abs((size0.z or size0.Z) or 0)
    else
        sx, sy, sz = 0, 0, 0
    end
    local expected = CFrameMath.mul(part0_cf, JointFrames.face_basis(s0, sx, sy, sz))
    local actual = CFrameMath.mul(part0_cf, c0 or CFrameMath.identity())
    local ex, ey, ez = CFrameMath.unpack(expected)
    local ax, ay, az = CFrameMath.unpack(actual)
    local enx, eny, enz = JointFrames.face_normal_world(expected)
    local anx, any, anz = JointFrames.face_normal_world(actual)
    local pos_err = vlen(ex - ax, ey - ay, ez - az)
    local ndot = clamp1(enx * anx + eny * any + enz * anz)
    local normal_angle = acos(ndot)
    local geodesic_angle = rot_geodesic(expected, actual)
    return {
        expected_center = { ex, ey, ez },
        actual_center   = { ax, ay, az },
        expected_normal = { enx, eny, enz },
        actual_normal   = { anx, any, anz },
        pos_err = pos_err,
        normal_angle = normal_angle,
        geodesic_angle = geodesic_angle,
    }
end

-- for snaps w/ no authored surface0/surface1: part0->part1 offset into part0-local, pick dominant axis
function JointFrames.infer_touching_face(part0_cf, part1_cf)
    local p0x, p0y, p0z = CFrameMath.unpack(part0_cf)
    local p1x, p1y, p1z = CFrameMath.unpack(part1_cf)
    -- into part0-local space
    local local0 = CFrameMath.mul(CFrameMath.inv(part0_cf), part1_cf)
    local lx, ly, lz = CFrameMath.unpack(local0)
    local axc = abs(lx)
    local ayc = abs(ly)
    local azc = abs(lz)
    if axc >= ayc and axc >= azc then
        return lx >= 0 and "Right" or "Left"
    elseif ayc >= axc and ayc >= azc then
        return ly >= 0 and "Top" or "Bottom"
    else
        return lz >= 0 and "Back" or "Front"
    end
end

return JointFrames
