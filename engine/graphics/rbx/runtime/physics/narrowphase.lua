-- per-shape-pair contact gen, detection only, no-alloc (writes into scratch, manifold.lua/solver cache+resolve)
-- Native cylinder/sphere and cylinder/block use finite circular cylinder geometry
-- Spheres and blocks use native wedge/corner-wedge solids, other wedge/mesh pairs remain approximate

local Shape     = runtime_require("physics/shape.lua")
local Materials = runtime_require("physics/materials.lua")
local Cylinder = runtime_require("physics/cylinder.lua")
local Wedge = runtime_require("physics/wedge.lua")
local WedgeBox = runtime_require("physics/wedge_box.lua")
local Convex = runtime_require("physics/convex_decomposition.lua")

local Narrowphase = {}

local sqrt = math.sqrt
local abs  = math.abs
local max  = math.max
local min  = math.min

local EPS      = 1e-9
local CLIP_EPS = 1e-6   -- min span for a distinct clip point

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- collider construction

-- aa=true picks the fast aabb path, radius=min half-extent (ball -> inscribed sphere)
function Narrowphase.make_collider(c, view, cx, cy, cz, qw, qx, qy, qz)
    -- immutable per view lifetime, cached on the view, called 2x per pair test
    local hx, hy, hz
    if view._nc_cached then
        c.kind = view._nc_kind
        hx, hy, hz = view._nc_hx, view._nc_hy, view._nc_hz
        c.friction          = view._nc_f
        c.elasticity        = view._nc_e
        c.friction_weight   = view._nc_fw
        c.elasticity_weight = view._nc_ew
    else
        c.kind = Shape.kind_of(view)
        hx, hy, hz = Shape.half_extents(view)
        c.friction          = Materials.friction_of(view)
        c.elasticity        = Materials.elasticity_of(view)
        c.friction_weight   = Materials.friction_weight_of(view)
        c.elasticity_weight = Materials.elasticity_weight_of(view)
        view._nc_kind = c.kind
        view._nc_hx, view._nc_hy, view._nc_hz = hx, hy, hz
        view._nc_f, view._nc_e = c.friction, c.elasticity
        view._nc_fw, view._nc_ew = c.friction_weight, c.elasticity_weight
        view._nc_cached = true
    end
    c.hx, c.hy, c.hz = hx, hy, hz
    c.wedge = c.kind == "wedge" and Wedge.geometry(view,hx,hy,hz) or nil
    c.convex=c.kind=='convex_decomposition'and Convex.geometry(view)or nil
    local r = hx
    if hy < r then r = hy end
    if hz < r then r = hz end
    c.radius = c.kind == "cylinder" and min(hy,hz) or r
    c.cx, c.cy, c.cz = cx, cy, cz
    qw = qw or 1; qx = qx or 0; qy = qy or 0; qz = qz or 0
    -- world box axes = quat rotation matrix columns
    local xx, yy, zz = qx * qx, qy * qy, qz * qz
    local xy, xz, yz = qx * qy, qx * qz, qy * qz
    local wx, wy, wz = qw * qx, qw * qy, qw * qz
    c.u0x, c.u0y, c.u0z = 1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy)
    c.u1x, c.u1y, c.u1z = 2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx)
    c.u2x, c.u2y, c.u2z = 2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy)
    c.aa = (abs(qx) + abs(qy) + abs(qz)) < 1e-4
    c.part_id = view.id
    return c
end

-- weighted-avg combine (blueprint §8)
function Narrowphase.combine_friction(a, b)
    local wa, wb = a.friction_weight or 1, b.friction_weight or 1
    local sum = wa + wb
    if sum <= 0 then return (a.friction + b.friction) * 0.5 end
    return (a.friction * wa + b.friction * wb) / sum
end

function Narrowphase.combine_elasticity(a, b)
    local wa, wb = a.elasticity_weight or 1, b.elasticity_weight or 1
    local sum = wa + wb
    if sum <= 0 then return (a.elasticity + b.elasticity) * 0.5 end
    return (a.elasticity * wa + b.elasticity * wb) / sum
end

-- contact emit (pooled multi-point)

local function set_point(out, idx, px, py, pz, pen, feature)
    local pts = out.points
    if not pts then pts = {}; out.points = pts end
    local p = pts[idx]
    if not p then p = {}; pts[idx] = p end
    p.px, p.py, p.pz = px, py, pz
    p.penetration = pen
    p.feature_id  = feature
    return p
end

local function emit_single(out, nx, ny, nz, pen, px, py, pz, feature)
    out.nx, out.ny, out.nz = nx, ny, nz
    set_point(out, 1, px, py, pz, pen, feature)
    out.count = 1
end

-- shape-pair routines (normal points a -> b)

local function sphere_sphere(a, b, out)
    local dx, dy, dz = b.cx - a.cx, b.cy - a.cy, b.cz - a.cz
    local d2 = dx * dx + dy * dy + dz * dz
    local rs = a.radius + b.radius
    if d2 >= rs * rs then
        out.count = 0
        return 0
    end
    local nx, ny, nz, dist
    if d2 > EPS then
        dist = sqrt(d2)
        nx, ny, nz = dx / dist, dy / dist, dz / dist
    else
        nx, ny, nz, dist = 0, 1, 0, 0   -- coincident centers: default +y, no nan
    end
    local pen = rs - dist
    local along = a.radius - pen * 0.5
    emit_single(out, nx, ny, nz, pen,
        a.cx + nx * along, a.cy + ny * along, a.cz + nz * along, 100)
    return 1
end

-- box-local frame, exact even when the box is rotated, normal s -> bx
local function sphere_box_dir(s, bx, out)
    -- sphere center in box-local
    local dcx, dcy, dcz = s.cx - bx.cx, s.cy - bx.cy, s.cz - bx.cz
    local lx = dcx * bx.u0x + dcy * bx.u0y + dcz * bx.u0z
    local ly = dcx * bx.u1x + dcy * bx.u1y + dcz * bx.u1z
    local lz = dcx * bx.u2x + dcy * bx.u2y + dcz * bx.u2z
    -- closest point on box, local
    local clx = clamp(lx, -bx.hx, bx.hx)
    local cly = clamp(ly, -bx.hy, bx.hy)
    local clz = clamp(lz, -bx.hz, bx.hz)
    -- back to world
    local qx = bx.cx + clx * bx.u0x + cly * bx.u1x + clz * bx.u2x
    local qy = bx.cy + clx * bx.u0y + cly * bx.u1y + clz * bx.u2y
    local qz = bx.cz + clx * bx.u0z + cly * bx.u1z + clz * bx.u2z
    local dx, dy, dz = s.cx - qx, s.cy - qy, s.cz - qz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > s.radius * s.radius then
        out.count = 0
        return 0
    end
    if d2 > EPS then
        -- outside: d is box->sphere, so negate for s->box
        local dist = sqrt(d2)
        emit_single(out, -dx / dist, -dy / dist, -dz / dist, s.radius - dist, qx, qy, qz, 110)
        return 1
    end
    -- inside: separate along the least-penetrated face, normal toward box center
    local ox = bx.hx - abs(lx)
    local oy = bx.hy - abs(ly)
    local oz = bx.hz - abs(lz)
    local ux, uy, uz, pen
    if ox <= oy and ox <= oz then
        local sgn = (lx >= 0) and -1 or 1
        ux, uy, uz, pen = bx.u0x * sgn, bx.u0y * sgn, bx.u0z * sgn, ox + s.radius
    elseif oy <= oz then
        local sgn = (ly >= 0) and -1 or 1
        ux, uy, uz, pen = bx.u1x * sgn, bx.u1y * sgn, bx.u1z * sgn, oy + s.radius
    else
        local sgn = (lz >= 0) and -1 or 1
        ux, uy, uz, pen = bx.u2x * sgn, bx.u2y * sgn, bx.u2z * sgn, oz + s.radius
    end
    emit_single(out, ux, uy, uz, pen, s.cx, s.cy, s.cz, 111)
    return 1
end

-- overlap of two 1d segments (center, half-extent)
local function overlap_interval(ac, ah, bc, bh)
    return max(ac - ah, bc - bh), min(ac + ah, bc + bh)
end

-- axis=clip-plane coord, u/v=in-plane, ubit/vbit=stable corner id
local function add_clip_point(out, n, axis, rc, u, v, ubit, vbit, pen, axis_code)
    n = n + 1
    local px, py, pz
    if axis == 1 then
        px, py, pz = rc, u, v
    elseif axis == 2 then
        px, py, pz = u, rc, v
    else
        px, py, pz = u, v, rc
    end
    set_point(out, n, px, py, pz, pen, axis_code * 10 + (ubit + vbit))
    return n
end

-- obb sat (15 axes) + incident-face clip, face axis biased over edge so a resting box doesnt flip-flop

local FACE_BIAS = 1e-3   -- edge axis must beat best face axis by this to win

local function box_axis(c, i)
    if i == 0 then return c.u0x, c.u0y, c.u0z
    elseif i == 1 then return c.u1x, c.u1y, c.u1z
    else return c.u2x, c.u2y, c.u2z end
end

local function box_half(c, i)
    if i == 0 then return c.hx elseif i == 1 then return c.hy else return c.hz end
end

-- pooled, reused across calls (single-threaded), grown on demand
local _ip = {}   -- incident polygon
local _op = {}   -- output polygon
local function poly_pt(pool, i)
    local p = pool[i]
    if not p then p = {}; pool[i] = p end
    return p
end

-- midpoint of the closest points on two lines, falls back to avg when ~parallel
local function edge_edge_point(pax, pay, paz, dax, day, daz,
                               pbx, pby, pbz, dbx, dby, dbz)
    local r0x, r0y, r0z = pax - pbx, pay - pby, paz - pbz
    local A = dax * dax + day * day + daz * daz
    local E = dbx * dbx + dby * dby + dbz * dbz
    local F = dbx * r0x + dby * r0y + dbz * r0z
    local B = dax * dbx + day * dby + daz * dbz
    local C = dax * r0x + day * r0y + daz * r0z
    local denom = A * E - B * B
    local s, u
    if denom > EPS then s = (B * F - C * E) / denom else s = 0 end
    if E > EPS then u = (B * s + F) / E else u = 0 end
    local cax, cay, caz = pax + dax * s, pay + day * s, paz + daz * s
    local cbx, cby, cbz = pbx + dbx * u, pby + dby * u, pbz + dbz * u
    return (cax + cbx) * 0.5, (cay + cby) * 0.5, (caz + cbz) * 0.5
end

-- module scratch, reused, per-call alloc was ~10x the gc cost
local _sat = { best = 0, best_cmp = 0, bnx = 0, bny = 0, bnz = 0, kind = 0, i = 0, j = 0 }
local SIGNS0 = { -1, -1, 1, 1 }
local SIGNS1 = { -1, 1, 1, -1 }

-- keeps the smallest overlap in _sat, false = separating
local function sat_test(a, b, tx, ty, tz, lx, ly, lz, kind, i, j, bias, st)
    local len2 = lx * lx + ly * ly + lz * lz
    if len2 < 1e-12 then return true end  -- degenerate axis: not separating
    local inv = 1 / sqrt(len2)
    lx, ly, lz = lx * inv, ly * inv, lz * inv
    local ra = a.hx * abs(a.u0x * lx + a.u0y * ly + a.u0z * lz)
        + a.hy * abs(a.u1x * lx + a.u1y * ly + a.u1z * lz)
        + a.hz * abs(a.u2x * lx + a.u2y * ly + a.u2z * lz)
    local rb = b.hx * abs(b.u0x * lx + b.u0y * ly + b.u0z * lz)
        + b.hy * abs(b.u1x * lx + b.u1y * ly + b.u1z * lz)
        + b.hz * abs(b.u2x * lx + b.u2y * ly + b.u2z * lz)
    local dist = tx * lx + ty * ly + tz * lz
    local overlap = ra + rb - (dist < 0 and -dist or dist)
    if overlap <= 0 then return false end  -- separating, no contact
    local cmp = overlap * bias
    if cmp < st.best_cmp then
        st.best_cmp = cmp
        st.best = overlap
        if dist < 0 then lx, ly, lz = -lx, -ly, -lz end  -- orient a -> b
        st.bnx, st.bny, st.bnz = lx, ly, lz
        st.kind, st.i, st.j = kind, i, j
    end
    return true
end

-- keep the SAT phases small enough for LuaJIT to compile each loop
-- the phases share their best contact axis through the scratch record

-- 3 edge-edge cross axes of one a-axis vs all b axes (straight-line: the old 3x3
-- nested loop was trace-hostile - 3-iteration inner loop + per-axis guards churned
-- side traces that never assembled), identical call order and arithmetic
local function obb_sat_edges_of(a, b, tx, ty, tz, aix, aiy, aiz, i, st)
    local bjx, bjy, bjz = b.u0x, b.u0y, b.u0z
    local cx = aiy * bjz - aiz * bjy
    local cy = aiz * bjx - aix * bjz
    local cz = aix * bjy - aiy * bjx
    if not sat_test(a, b, tx, ty, tz, cx, cy, cz, 3, i, 0, 1 + FACE_BIAS, st) then return true end
    bjx, bjy, bjz = b.u1x, b.u1y, b.u1z
    cx = aiy * bjz - aiz * bjy
    cy = aiz * bjx - aix * bjz
    cz = aix * bjy - aiy * bjx
    if not sat_test(a, b, tx, ty, tz, cx, cy, cz, 3, i, 1, 1 + FACE_BIAS, st) then return true end
    bjx, bjy, bjz = b.u2x, b.u2y, b.u2z
    cx = aiy * bjz - aiz * bjy
    cy = aiz * bjx - aix * bjz
    cz = aix * bjy - aiy * bjx
    if not sat_test(a, b, tx, ty, tz, cx, cy, cz, 3, i, 2, 1 + FACE_BIAS, st) then return true end
    return false
end

-- 6 face axes of a and b (already unit), true = separating
local function obb_sat_faces(a, b, tx, ty, tz, st)
    if not sat_test(a, b, tx, ty, tz, a.u0x, a.u0y, a.u0z, 1, 0, 0, 1, st) then return true end
    if not sat_test(a, b, tx, ty, tz, a.u1x, a.u1y, a.u1z, 1, 1, 0, 1, st) then return true end
    if not sat_test(a, b, tx, ty, tz, a.u2x, a.u2y, a.u2z, 1, 2, 0, 1, st) then return true end
    if not sat_test(a, b, tx, ty, tz, b.u0x, b.u0y, b.u0z, 2, 0, 0, 1, st) then return true end
    if not sat_test(a, b, tx, ty, tz, b.u1x, b.u1y, b.u1z, 2, 1, 0, 1, st) then return true end
    if not sat_test(a, b, tx, ty, tz, b.u2x, b.u2y, b.u2z, 2, 2, 0, 1, st) then return true end
    return false
end

-- all 15 sat axes, true = separating axis found (no contact), winner left in st
local function obb_sat_separating(a, b, tx, ty, tz, st)
    if obb_sat_faces(a, b, tx, ty, tz, st) then return true end
    -- 9 edge-edge axes = cross(a_i,b_j), biased so face axis wins ties
    if obb_sat_edges_of(a, b, tx, ty, tz, a.u0x, a.u0y, a.u0z, 0, st) then return true end
    if obb_sat_edges_of(a, b, tx, ty, tz, a.u1x, a.u1y, a.u1z, 1, st) then return true end
    if obb_sat_edges_of(a, b, tx, ty, tz, a.u2x, a.u2y, a.u2z, 2, st) then return true end
    return false
end

-- edge anchors, straight-line per-axis (was a k~=i guard loop: 3 iterations never
-- form a loop trace and the guards churned side traces), same ascending-k op order
local function edge_anchor_a(a, tx, ty, tz, i)
    -- edge of a along axis i, offset toward b
    local pax, pay, paz = a.cx, a.cy, a.cz
    if i ~= 0 then
        local s = (tx * a.u0x + ty * a.u0y + tz * a.u0z) >= 0 and a.hx or -a.hx
        pax, pay, paz = pax + a.u0x * s, pay + a.u0y * s, paz + a.u0z * s
    end
    if i ~= 1 then
        local s = (tx * a.u1x + ty * a.u1y + tz * a.u1z) >= 0 and a.hy or -a.hy
        pax, pay, paz = pax + a.u1x * s, pay + a.u1y * s, paz + a.u1z * s
    end
    if i ~= 2 then
        local s = (tx * a.u2x + ty * a.u2y + tz * a.u2z) >= 0 and a.hz or -a.hz
        pax, pay, paz = pax + a.u2x * s, pay + a.u2y * s, paz + a.u2z * s
    end
    return pax, pay, paz
end

local function edge_anchor_b(b, tx, ty, tz, j)
    -- edge of b along axis j, offset toward a
    local pbx, pby, pbz = b.cx, b.cy, b.cz
    if j ~= 0 then
        local s = (tx * b.u0x + ty * b.u0y + tz * b.u0z) >= 0 and -b.hx or b.hx
        pbx, pby, pbz = pbx + b.u0x * s, pby + b.u0y * s, pbz + b.u0z * s
    end
    if j ~= 1 then
        local s = (tx * b.u1x + ty * b.u1y + tz * b.u1z) >= 0 and -b.hy or b.hy
        pbx, pby, pbz = pbx + b.u1x * s, pby + b.u1y * s, pbz + b.u1z * s
    end
    if j ~= 2 then
        local s = (tx * b.u2x + ty * b.u2y + tz * b.u2z) >= 0 and -b.hz or b.hz
        pbx, pby, pbz = pbx + b.u2x * s, pby + b.u2y * s, pbz + b.u2z * s
    end
    return pbx, pby, pbz
end

-- edge-edge manifold: skew=1 point, near-parallel=2 endpoints (no pivot), exactly-parallel takes the face path
local function obb_emit_edge(a, b, tx, ty, tz, st, out)
    local best = st.best
    local bnx, bny, bnz = st.bnx, st.bny, st.bnz
    local best_i, best_j = st.i, st.j
    local i, j = best_i, best_j
    local hA, hB = box_half(a, i), box_half(b, j)
    local dax, day, daz = box_axis(a, i)
    local dbx, dby, dbz = box_axis(b, j)
    local pax, pay, paz = edge_anchor_a(a, tx, ty, tz, i)
    local pbx, pby, pbz = edge_anchor_b(b, tx, ty, tz, j)

    local code = 900 + best_i * 3 + best_j
    local cosang = dax * dbx + day * dby + daz * dbz
    if cosang > 0.999 or cosang < -0.999 then
        -- near-parallel: edge overlap projected onto da
        local rel = (pbx - pax) * dax + (pby - pay) * day + (pbz - paz) * daz
        local lo = math.max(-hA, rel - hB)
        local hi = math.min(hA, rel + hB)
        if hi - lo > CLIP_EPS then
            out.nx, out.ny, out.nz = bnx, bny, bnz
            local n = 0
            for q = 1, 2 do
                local s = (q == 1) and lo or hi
                local axp, ayp, azp = pax + dax * s, pay + day * s, paz + daz * s
                -- closest point on edge b, clamped
                local u = (axp - pbx) * dbx + (ayp - pby) * dby + (azp - pbz) * dbz
                if u < -hB then u = -hB elseif u > hB then u = hB end
                local bxp, byp, bzp = pbx + dbx * u, pby + dby * u, pbz + dbz * u
                n = n + 1
                set_point(out, n, (axp + bxp) * 0.5, (ayp + byp) * 0.5, (azp + bzp) * 0.5,
                    best, code + (q - 1) * 33)
            end
            out.count = n
            return n
        end
    end
    -- skew edges: single closest-segment midpoint
    local px, py, pz = edge_edge_point(pax, pay, paz, dax, day, daz,
        pbx, pby, pbz, dbx, dby, dbz)
    emit_single(out, bnx, bny, bnz, best, px, py, pz, code)
    return 1
end

-- face contact setup: ref face + incident face pick, 4 incident verts into _ip;
-- ref = box owning the separating axis
local function obb_face_setup(a, b, st)
    local bnx, bny, bnz = st.bnx, st.bny, st.bnz
    local ref, inc, ref_is_a
    local rnx, rny, rnz   -- ref outward normal (toward incident)
    if st.kind == 1 then
        ref, inc, ref_is_a = a, b, true
        rnx, rny, rnz = bnx, bny, bnz             -- a face, normal already points a->b
    else
        ref, inc, ref_is_a = b, a, false
        rnx, rny, rnz = -bnx, -bny, -bnz          -- b face, outward toward a
    end
    -- ref axis = axis most aligned with refn
    local rai = st.i
    -- incident face = most anti-parallel to refn
    local ii, idot = 0, math.huge
    for k = 0, 2 do
        local kx, ky, kz = box_axis(inc, k)
        local d = kx * rnx + ky * rny + kz * rnz
        if d < idot then idot = d; ii = k end       -- most negative (anti-parallel +k)
        if -d < idot then idot = -d; ii = k end      -- consider -k too
    end
    -- outward sign: normal opposes refn
    local iix, iiy, iiz = box_axis(inc, ii)
    local isign = (iix * rnx + iiy * rny + iiz * rnz) > 0 and -1 or 1
    -- in-plane axes of incident face
    local ia0 = (ii + 1) % 3
    local ia1 = (ii + 2) % 3
    local fcx = inc.cx + iix * isign * box_half(inc, ii)
    local fcy = inc.cy + iiy * isign * box_half(inc, ii)
    local fcz = inc.cz + iiz * isign * box_half(inc, ii)
    local e0x, e0y, e0z = box_axis(inc, ia0)
    local e1x, e1y, e1z = box_axis(inc, ia1)
    local h0, h1 = box_half(inc, ia0), box_half(inc, ia1)
    -- 4 incident-face vertices, corner-signed for stable ids
    local np = 0
    for q = 1, 4 do
        local s0, s1 = SIGNS0[q], SIGNS1[q]
        local p = poly_pt(_ip, q)
        p.x = fcx + e0x * s0 * h0 + e1x * s1 * h1
        p.y = fcy + e0y * s0 * h0 + e1y * s1 * h1
        p.z = fcz + e0z * s0 * h0 + e1z * s1 * h1
        p.fid = q   -- stable corner id for resting contact
        np = np + 1
    end
    return ref, ref_is_a, rai, rnx, rny, rnz, np
end

-- clip incident polygon (_ip) against ref face's 4 side planes, returns final poly + count
local function obb_clip_side_planes(ref, rai, np)
    local cur, other = _ip, _op
    local rcx, rcy, rcz = ref.cx, ref.cy, ref.cz
    for k = 0, 2 do
        if k ~= rai then
            local kx, ky, kz = box_axis(ref, k)
            local hk = box_half(ref, k)
            for sgn = -1, 1, 2 do
                -- plane: normal=sgn*axis_k, point=center+sgn*hk*axis_k
                local pnx, pny, pnz = kx * sgn, ky * sgn, kz * sgn
                local ppx, ppy, ppz = rcx + pnx * hk, rcy + pny * hk, rcz + pnz * hk
                local on = 0
                for q = 1, np do
                    local p = cur[q]
                    local nq = cur[q == np and 1 or q + 1]
                    local dp = (p.x - ppx) * pnx + (p.y - ppy) * pny + (p.z - ppz) * pnz
                    local dn = (nq.x - ppx) * pnx + (nq.y - ppy) * pny + (nq.z - ppz) * pnz
                    if dp <= 0 then
                        on = on + 1
                        local o = poly_pt(other, on)
                        o.x, o.y, o.z, o.fid = p.x, p.y, p.z, p.fid
                    end
                    if (dp < 0) ~= (dn < 0) and (dp - dn) ~= 0 then
                        local tt = dp / (dp - dn)
                        on = on + 1
                        local o = poly_pt(other, on)
                        o.x = p.x + (nq.x - p.x) * tt
                        o.y = p.y + (nq.y - p.y) * tt
                        o.z = p.z + (nq.z - p.z) * tt
                        o.fid = 10 * k + (sgn > 0 and 5 or 0) + (p.fid % 5)
                    end
                end
                np = on
                cur, other = other, cur
                if np == 0 then break end
            end
        end
        if np == 0 then break end
    end
    return cur, np
end

-- keep points below ref face (penetrating), deepest first, capped at 4, grazing fallback
local function obb_face_emit(cur, np, ref, ref_is_a, rai, rnx, rny, rnz, st, out)
    local best = st.best
    local bnx, bny, bnz = st.bnx, st.bny, st.bnz
    local rfx = ref.cx + rnx * box_half(ref, rai)
    local rfy = ref.cy + rny * box_half(ref, rai)
    local rfz = ref.cz + rnz * box_half(ref, rai)
    out.nx, out.ny, out.nz = bnx, bny, bnz
    local n = 0
    for q = 1, np do
        local p = cur[q]
        local d = (p.x - rfx) * rnx + (p.y - rfy) * rny + (p.z - rfz) * rnz
        if d <= 1e-5 then
            local pen = -d
            if pen < 0 then pen = 0 end
            if n < 4 then
                n = n + 1
                set_point(out, n, p.x, p.y, p.z, pen, (ref_is_a and 200 or 300) + rai * 10 + (p.fid % 10))
            else
                -- replace shallowest of the 4 if deeper
                local shallow_i, shallow_pen = 1, out.points[1].penetration
                for r = 2, 4 do
                    if out.points[r].penetration < shallow_pen then
                        shallow_pen, shallow_i = out.points[r].penetration, r
                    end
                end
                if pen > shallow_pen then
                    set_point(out, shallow_i, p.x, p.y, p.z, pen,
                        (ref_is_a and 200 or 300) + rai * 10 + (p.fid % 10))
                end
            end
        end
    end

    if n == 0 then
        -- grazing/edge: single point, never zero points
        local p = cur[1] or _ip[1]
        emit_single(out, bnx, bny, bnz, best, p.x, p.y, p.z, (ref_is_a and 250 or 350) + rai)
        return 1
    end
    out.count = n
    return n
end

-- dispatcher: phase order and every expression identical to the pre-split version
local function obb_box_box(a, b, out)
    local tx, ty, tz = b.cx - a.cx, b.cy - a.cy, b.cz - a.cz

    local st = _sat
    st.best = math.huge; st.best_cmp = math.huge
    st.bnx, st.bny, st.bnz = 0, 0, 0
    st.kind, st.i, st.j = 0, 0, 0

    if obb_sat_separating(a, b, tx, ty, tz, st) then out.count = 0; return 0 end
    if st.best == math.huge then out.count = 0; return 0 end

    -- edge-edge winner: skew=1 point, near-parallel=2 endpoints, exactly-parallel takes the face path
    if st.kind == 3 then
        return obb_emit_edge(a, b, tx, ty, tz, st, out)
    end
    local ref, ref_is_a, rai, rnx, rny, rnz, np = obb_face_setup(a, b, st)
    local cur
    cur, np = obb_clip_side_planes(ref, rai, np)
    return obb_face_emit(cur, np, ref, ref_is_a, rai, rnx, rny, rnz, st, out)
end

-- fast face clip when both ~aa, else obb, unsupported wedge/mesh routes by orientation
local function box_box(a, b, out)
    if not (a.aa and b.aa) then
        return obb_box_box(a, b, out)
    end
    local ox = (a.hx + b.hx) - abs(a.cx - b.cx)
    if ox <= 0 then out.count = 0; return 0 end
    local oy = (a.hy + b.hy) - abs(a.cy - b.cy)
    if oy <= 0 then out.count = 0; return 0 end
    local oz = (a.hz + b.hz) - abs(a.cz - b.cz)
    if oz <= 0 then out.count = 0; return 0 end

    local pen, axis = ox, 1
    if oy < pen then pen, axis = oy, 2 end
    if oz < pen then pen, axis = oz, 3 end

    -- normal sign along chosen axis (b relative to a)
    local nx, ny, nz, sign = 0, 0, 0, 1
    if axis == 1 then
        sign = (b.cx >= a.cx) and 1 or -1; nx = sign
    elseif axis == 2 then
        sign = (b.cy >= a.cy) and 1 or -1; ny = sign
    else
        sign = (b.cz >= a.cz) and 1 or -1; nz = sign
    end

    -- aa face clip: contact coord = mid-plane between surfaces, points = overlap rect corners
    local axis_code = axis * sign
    out.nx, out.ny, out.nz = nx, ny, nz

    local rc, ulo, uhi, vlo, vhi
    if axis == 1 then
        rc = 0.5 * ((a.cx + sign * a.hx) + (b.cx - sign * b.hx))
        ulo, uhi = overlap_interval(a.cy, a.hy, b.cy, b.hy)
        vlo, vhi = overlap_interval(a.cz, a.hz, b.cz, b.hz)
    elseif axis == 2 then
        rc = 0.5 * ((a.cy + sign * a.hy) + (b.cy - sign * b.hy))
        ulo, uhi = overlap_interval(a.cx, a.hx, b.cx, b.hx)
        vlo, vhi = overlap_interval(a.cz, a.hz, b.cz, b.hz)
    else
        rc = 0.5 * ((a.cz + sign * a.hz) + (b.cz - sign * b.hz))
        ulo, uhi = overlap_interval(a.cx, a.hx, b.cx, b.hx)
        vlo, vhi = overlap_interval(a.cy, a.hy, b.cy, b.hy)
    end

    local u_has_hi = (uhi - ulo) > CLIP_EPS
    local v_has_hi = (vhi - vlo) > CLIP_EPS

    local n = 0
    n = add_clip_point(out, n, axis, rc, ulo, vlo, 0, 0, pen, axis_code)
    if v_has_hi then
        n = add_clip_point(out, n, axis, rc, ulo, vhi, 0, 1, pen, axis_code)
    end
    if u_has_hi then
        n = add_clip_point(out, n, axis, rc, uhi, vlo, 2, 0, pen, axis_code)
    end
    if u_has_hi and v_has_hi then
        n = add_clip_point(out, n, axis, rc, uhi, vhi, 2, 1, pen, axis_code)
    end
    out.count = n
    return n
end

-- dispatch

-- returns point count 0..4, out.nx/ny/nz = normal a -> b
function Narrowphase.collide(a, b, out)
    if a.convex or b.convex then return Convex.collide(a,b,out)end
    if a.kind == "wedge" and b.kind == "block" then return WedgeBox.collide(a,b,out) end
    if b.kind == "wedge" and a.kind == "block" then
        local n=WedgeBox.collide(b,a,out)
        if n>0 then out.nx,out.ny,out.nz=-out.nx,-out.ny,-out.nz end
        return n
    end
    if a.kind == "wedge" and b.kind == "ball" then return Wedge.sphere(a,b,out) end
    if b.kind == "wedge" and a.kind == "ball" then
        local n = Wedge.sphere(b,a,out)
        if n > 0 then out.nx,out.ny,out.nz = -out.nx,-out.ny,-out.nz end
        return n
    end
    if a.kind == "cylinder" and b.kind == "cylinder" then return Cylinder.cylinder(a,b,out) end
    if a.kind == "cylinder" and (b.kind == "ball" or b.kind == "block") then
        return b.kind == "ball" and Cylinder.sphere(a,b,out) or Cylinder.box(a,b,out)
    elseif b.kind == "cylinder" and (a.kind == "ball" or a.kind == "block") then
        local n=a.kind == "ball" and Cylinder.sphere(b,a,out) or Cylinder.box(b,a,out)
        if n>0 then out.nx,out.ny,out.nz=-out.nx,-out.ny,-out.nz end
        return n
    end
    local a_ball = a.kind == "ball"
    local b_ball = b.kind == "ball"
    if a_ball and b_ball then
        return sphere_sphere(a, b, out)
    elseif a_ball then
        return sphere_box_dir(a, b, out)            -- normal a(sphere) -> b(box) == a->b
    elseif b_ball then
        local n = sphere_box_dir(b, a, out)          -- computes b(sphere) -> a(box)
        if n > 0 then
            out.nx, out.ny, out.nz = -out.nx, -out.ny, -out.nz  -- flip to a->b
        end
        return n
    end
    return box_box(a, b, out)
end

return Narrowphase
