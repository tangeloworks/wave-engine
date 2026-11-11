-- raycast/region queries, core parts only (never facades), reuses the sim's broadphase hash
-- raycast = amanatides-woo 3d dda, o(cells) not o(parts), both fall back to linear scan if broadphase empty

local Queries = {}
local Convex = runtime_require('physics/convex_decomposition.lua')

-- raycast static fast path: FFI survivor scratch + packed AABB slab loop (see
-- rc_scan_static_cell). Plain Lua function-splitting did NOT fix the trace aborts
-- here (LuaJIT inlines the split calls back into the recording trace), the
-- call-free FFI loop below is the recorded fix direction
local ffi = require("ffi")

local abs   = math.abs
local floor = math.floor
local sqrt  = math.sqrt
local huge  = math.huge

local EPS = 1e-5

-- member grid vs big static assemblies, else o(all members), cached on body, fresh each topology rebuild
local GRID_MIN_MEMBERS = 64
local GRID_MAX_SPAN = 96 -- per-axis cell cap (matches broadphase STATIC_MAX_SPAN)

-- packed cell key, no string garbage, exact for |idx| < 4096 (~131k studs)
local function gkey(x, y, z)
    return ((x + 4096) * 8192 + (y + 4096)) * 8192 + (z + 4096)
end

local function key_range(ax, ay, az, bx, by, bz)
    return ax >= -4096 and ay >= -4096 and az >= -4096
        and bx <= 4095 and by <= 4095 and bz <= 4095
        and ax <= bx and ay <= by and az <= bz
end

-- fwd decl for member_grid
local part_world_aabb

-- member spanning cells is listed in each, caller dedups by id
local function member_grid(body, cell)
    local grid = body._query_member_grid
    if grid and grid.cell == cell then
        return grid
    end
    grid = { cell = cell, cells = {}, overflow = {} }
    local cells = grid.cells
    local members = body.assembly and body.assembly.parts
    if members then
        for i = 1, #members do
            local part = members[i]._part
            if part and not part._destroyed and part._workspace_active~=false then
                local minx, miny, minz, maxx, maxy, maxz = part_world_aabb(part)
                local ax, ay, az = floor(minx / cell), floor(miny / cell), floor(minz / cell)
                local bx, by, bz = floor(maxx / cell), floor(maxy / cell), floor(maxz / cell)
                if not key_range(ax, ay, az, bx, by, bz) or bx - ax > GRID_MAX_SPAN
                    or by - ay > GRID_MAX_SPAN or bz - az > GRID_MAX_SPAN then
                    grid.overflow[#grid.overflow + 1] = part
                else
                for gx = ax, bx do
                    for gy = ay, by do
                        for gz = az, bz do
                            local k = gkey(gx, gy, gz)
                            local bucket = cells[k]
                            if not bucket then bucket = {}; cells[k] = bucket end
                            bucket[#bucket + 1] = part
                        end
                    end
                end
                end
            end
        end
    end
    body._query_member_grid = grid
    return grid
end

-- large static assembly only
local function use_member_grid(body)
    if not body.is_static then return false end
    local members = body.assembly and body.assembly.parts
    return members ~= nil and #members >= GRID_MIN_MEMBERS
end

local function half_extents(part)
    if part._collision_decomposition then return Convex.half_extents(part)end
    local s = part.Size
    local sx = s and (s.x or s.X) or 1
    local sy = s and (s.y or s.Y) or 1
    local sz = s and (s.z or s.Z) or 1
    sx = abs(tonumber(sx) or 1); sy = abs(tonumber(sy) or 1); sz = abs(tonumber(sz) or 1)
    if sx < 0.001 then sx = 0.001 end
    if sy < 0.001 then sy = 0.001 end
    if sz < 0.001 then sz = 0.001 end
    return sx * 0.5, sy * 0.5, sz * 0.5
end

-- -> entry t + outward normal, or nil. ray starting inside box = not a hit
local function ray_obb(ox, oy, oz, ux, uy, uz, cx, cy, cz,
                       rx, ry, rz, upx, upy, upz, wx, wy, wz, hx, hy, hz, maxdist)
    local dx, dy, dz = ox - cx, oy - cy, oz - cz
    -- ray in box-local axes
    local o_r = dx * rx + dy * ry + dz * rz
    local o_u = dx * upx + dy * upy + dz * upz
    local o_w = dx * wx + dy * wy + dz * wz
    local d_r = ux * rx + uy * ry + uz * rz
    local d_u = ux * upx + uy * upy + uz * upz
    local d_w = ux * wx + uy * wy + uz * wz

    local tmin, tmax = -huge, huge
    local axis, nsign = 0, 0

    -- unrolled on purpose: a closure here allocs + blocks jit (FNEW not compiled)
    if d_r > -1e-12 and d_r < 1e-12 then
        if o_r < -hx or o_r > hx then return nil end
    else
        local inv = 1 / d_r
        local t1 = (-hx - o_r) * inv
        local t2 = (hx - o_r) * inv
        local entry_sign = (d_r > 0) and -1 or 1
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1; axis = 1; nsign = entry_sign end
        if t2 < tmax then tmax = t2 end
        if tmin > tmax then return nil end
    end
    if d_u > -1e-12 and d_u < 1e-12 then
        if o_u < -hy or o_u > hy then return nil end
    else
        local inv = 1 / d_u
        local t1 = (-hy - o_u) * inv
        local t2 = (hy - o_u) * inv
        local entry_sign = (d_u > 0) and -1 or 1
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1; axis = 2; nsign = entry_sign end
        if t2 < tmax then tmax = t2 end
        if tmin > tmax then return nil end
    end
    if d_w > -1e-12 and d_w < 1e-12 then
        if o_w < -hz or o_w > hz then return nil end
    else
        local inv = 1 / d_w
        local t1 = (-hz - o_w) * inv
        local t2 = (hz - o_w) * inv
        local entry_sign = (d_w > 0) and -1 or 1
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1; axis = 3; nsign = entry_sign end
        if t2 < tmax then tmax = t2 end
        if tmin > tmax then return nil end
    end
    if tmin <= EPS or tmin > maxdist then
        return nil
    end
    -- outward normal = entry-axis vector * sign
    local nx, ny, nz
    if axis == 1 then nx, ny, nz = rx * nsign, ry * nsign, rz * nsign
    elseif axis == 2 then nx, ny, nz = upx * nsign, upy * nsign, upz * nsign
    else nx, ny, nz = wx * nsign, wy * nsign, wz * nsign end
    return tmin, nx, ny, nz
end

-- shape = intersection of half-spaces in the scratch arrays below, same conventions as ray_obb
local plane_nx, plane_ny, plane_nz, plane_d = {}, {}, {}, {}

local function ray_convex(count, o_r, o_u, o_w, d_r, d_u, d_w, maxdist)
    local tmin, tmax = -huge, huge
    local entry = 0
    for i = 1, count do
        local nx, ny, nz = plane_nx[i], plane_ny[i], plane_nz[i]
        local dn = d_r * nx + d_u * ny + d_w * nz
        local on = o_r * nx + o_u * ny + o_w * nz - plane_d[i]
        if dn > -1e-12 and dn < 1e-12 then
            if on > 0 then return nil end
        else
            local t = -on / dn
            if dn < 0 then
                if t > tmin then tmin = t; entry = i end
            else
                if t < tmax then tmax = t end
            end
            if tmin > tmax then return nil end
        end
    end
    if entry == 0 or tmin <= EPS or tmin > maxdist then
        return nil
    end
    return tmin, plane_nx[entry], plane_ny[entry], plane_nz[entry]
end

-- wedge planes, must match geometry.lua builds, slope descends toward -Z, back quad at +Z
local function fill_wedge_planes(hx, hy, hz)
    local inv = 1 / sqrt(hy * hy + hz * hz)
    plane_nx[1], plane_ny[1], plane_nz[1], plane_d[1] = 0, -1, 0, hy       -- bottom
    plane_nx[2], plane_ny[2], plane_nz[2], plane_d[2] = 0, 0, 1, hz        -- back
    plane_nx[3], plane_ny[3], plane_nz[3], plane_d[3] = 1, 0, 0, hx        -- right
    plane_nx[4], plane_ny[4], plane_nz[4], plane_d[4] = -1, 0, 0, hx       -- left
    plane_nx[5], plane_ny[5], plane_nz[5], plane_d[5] = 0, hz * inv, -hy * inv, 0 -- slope (through center)
    return 5
end

-- corner wedge: apex above (+X,-Z) corner, slopes replace +Z and -X
local function fill_corner_wedge_planes(hx, hy, hz)
    local inv_a = 1 / sqrt(hz * hz + hy * hy)
    local inv_b = 1 / sqrt(hy * hy + hx * hx)
    plane_nx[1], plane_ny[1], plane_nz[1], plane_d[1] = 0, -1, 0, hy       -- bottom
    plane_nx[2], plane_ny[2], plane_nz[2], plane_d[2] = 1, 0, 0, hx        -- +X vertical triangle
    plane_nx[3], plane_ny[3], plane_nz[3], plane_d[3] = 0, 0, -1, hz       -- -Z vertical triangle
    plane_nx[4], plane_ny[4], plane_nz[4], plane_d[4] = 0, hz * inv_a, hy * inv_a, 0   -- slope toward +Z
    plane_nx[5], plane_ny[5], plane_nz[5], plane_d[5] = -hy * inv_b, hx * inv_b, 0, 0  -- slope toward -X
    return 5
end

-- Capped cylinder along local X (caps at +/-hx). Part.Shape=Cylinder uses a
-- circular Y/Z section, the caller passes the lower radial half-extent for both
local function ray_cylinder(o_r, o_u, o_w, d_r, d_u, d_w, hx, hy, hz, maxdist)
    -- cap slab on X axis
    local tx0, tx1 = -huge, huge
    if d_r > -1e-12 and d_r < 1e-12 then
        if o_r < -hx or o_r > hx then return nil end
    else
        local inv = 1 / d_r
        tx0 = (-hx - o_r) * inv
        tx1 = (hx - o_r) * inv
        if tx0 > tx1 then tx0, tx1 = tx1, tx0 end
    end
    -- side surface: scale to unit circle in YZ
    local oy, oz = o_u / hy, o_w / hz
    local dy, dz = d_u / hy, d_w / hz
    local a = dy * dy + dz * dz
    local ts0, ts1 = -huge, huge
    if a > 1e-12 then
        local b = oy * dy + oz * dz
        local c = oy * oy + oz * oz - 1
        local disc = b * b - a * c
        if disc < 0 then return nil end
        local root = sqrt(disc)
        ts0 = (-b - root) / a
        ts1 = (-b + root) / a
    else
        if oy * oy + oz * oz > 1 then return nil end
    end
    local t_in = (tx0 > ts0) and tx0 or ts0
    local t_out = (tx1 < ts1) and tx1 or ts1
    if t_in > t_out or t_in <= EPS or t_in > maxdist then
        return nil
    end
    if tx0 > ts0 then
        -- entered through a cap
        return t_in, (d_r > 0) and -1 or 1, 0, 0
    end
    -- entered through side: normal = ellipse gradient
    local py = o_u + d_u * t_in
    local pz = o_w + d_w * t_in
    local gy, gz = py / (hy * hy), pz / (hz * hz)
    local glen = sqrt(gy * gy + gz * gz)
    if glen < 1e-12 then return nil end
    return t_in, 0, gy / glen, gz / glen
end

-- same conventions as ray_obb
local function ray_sphere(ox, oy, oz, ux, uy, uz, cx, cy, cz, r, maxdist)
    local ocx, ocy, ocz = ox - cx, oy - cy, oz - cz
    local b = ocx * ux + ocy * uy + ocz * uz
    local c = ocx * ocx + ocy * ocy + ocz * ocz - r * r
    if c < 0 then
        return nil   -- origin inside sphere = not a hit
    end
    local disc = b * b - c
    if disc < 0 then
        return nil
    end
    local t = -b - sqrt(disc)
    if t <= EPS or t > maxdist then
        return nil
    end
    local hx, hy, hz = ox + ux * t, oy + uy * t, oz + uz * t
    local inv = (r > 1e-9) and (1 / r) or 0
    return t, (hx - cx) * inv, (hy - cy) * inv, (hz - cz) * inv
end

-- shape-exact (sphere/wedge/cylinder/box per Shape)
-- narrowphase still boxes everything, queries match what the player sees
-- raw component reads (cf._x etc are plain fields on CFrame objects, so no __index
-- dispatch): a long ray tests hundreds of parts and the metamethod round-trips per
-- component were a measurable share of query time. Flat cframe tables fall back to
-- their own raw x/r00 fields, so both representations stay plain hash reads
local function ray_vs_part(part, ox, oy, oz, ux, uy, uz, maxdist)
    local cf = part.CFrame
    if not cf then return nil end
    local cx = cf._x or cf.x or 0
    local cy = cf._y or cf.y or 0
    local cz = cf._z or cf.z or 0
    local hx, hy, hz = half_extents(part)
    local shape = part.Shape
    if shape == "Ball" and not part._collision_decomposition then
        local r = hx
        if hy < r then r = hy end
        if hz < r then r = hz end
        return ray_sphere(ox, oy, oz, ux, uy, uz, cx, cy, cz, r, maxdist)
    end
    local m00 = cf._r00 or cf.r00 or 1
    local m01 = cf._r01 or cf.r01 or 0
    local m02 = cf._r02 or cf.r02 or 0
    local m10 = cf._r10 or cf.r10 or 0
    local m11 = cf._r11 or cf.r11 or 1
    local m12 = cf._r12 or cf.r12 or 0
    local m20 = cf._r20 or cf.r20 or 0
    local m21 = cf._r21 or cf.r21 or 0
    local m22 = cf._r22 or cf.r22 or 1
    -- basis columns: right=(r00,r10,r20) up=(r01,r11,r21) back=(r02,r12,r22)=-look
    local rx, ry, rz = m00, m10, m20
    local upx, upy, upz = m01, m11, m21
    local wx, wy, wz = m02, m12, m22
    if shape == "Wedge" or shape == "CornerWedge" or shape == "Cylinder" or part._collision_decomposition then
        -- ray in part-local axes
        local dx, dy, dz = ox - cx, oy - cy, oz - cz
        local o_r = dx * rx + dy * ry + dz * rz
        local o_u = dx * upx + dy * upy + dz * upz
        local o_w = dx * wx + dy * wy + dz * wz
        local d_r = ux * rx + uy * ry + uz * rz
        local d_u = ux * upx + uy * upy + uz * upz
        local d_w = ux * wx + uy * wy + uz * wz
        local t, lnx, lny, lnz
        if part._collision_decomposition then
            t,lnx,lny,lnz=Convex.ray_local(Convex.geometry(part),o_r,o_u,o_w,d_r,d_u,d_w,maxdist)
        elseif shape == "Cylinder" then
            local radial = hy < hz and hy or hz
            t, lnx, lny, lnz = ray_cylinder(
                o_r, o_u, o_w, d_r, d_u, d_w,
                hx, radial, radial, maxdist)
        else
            local count = (shape == "Wedge") and fill_wedge_planes(hx, hy, hz)
                or fill_corner_wedge_planes(hx, hy, hz)
            t, lnx, lny, lnz = ray_convex(count, o_r, o_u, o_w, d_r, d_u, d_w, maxdist)
        end
        if not t then return nil end
        -- normal back to world space
        return t,
            lnx * rx + lny * upx + lnz * wx,
            lnx * ry + lny * upy + lnz * wy,
            lnx * rz + lny * upz + lnz * wz
    end
    return ray_obb(ox, oy, oz, ux, uy, uz, cx, cy, cz,
        rx, ry, rz, upx, upy, upz, wx, wy, wz, hx, hy, hz, maxdist)
end

-- assigns the fwd-declared upvalue for member_grid, raw component reads (see ray_vs_part)
function part_world_aabb(part)
    local cf = part.CFrame
    local cx = cf._x or cf.x or 0
    local cy = cf._y or cf.y or 0
    local cz = cf._z or cf.z or 0
    local hx, hy, hz = half_extents(part)
    local m00 = cf._r00 or cf.r00 or 1
    local m01 = cf._r01 or cf.r01 or 0
    local m02 = cf._r02 or cf.r02 or 0
    local m10 = cf._r10 or cf.r10 or 0
    local m11 = cf._r11 or cf.r11 or 1
    local m12 = cf._r12 or cf.r12 or 0
    local m20 = cf._r20 or cf.r20 or 0
    local m21 = cf._r21 or cf.r21 or 0
    local m22 = cf._r22 or cf.r22 or 1
    local ax = hx * abs(m00) + hy * abs(m01) + hz * abs(m02)
    local ay = hx * abs(m10) + hy * abs(m11) + hz * abs(m12)
    local az = hx * abs(m20) + hy * abs(m21) + hz * abs(m22)
    return cx - ax, cy - ay, cz - az, cx + ax, cy + ay, cz + az
end

-- CanQuery + include/exclude set
Queries.part_world_aabb = part_world_aabb
local function ray_part_passes(part, opts)
    if part._workspace_active==false then return false end
    if part.CanQuery == false then return false end
    if opts.collision_groups and not opts.collision_groups:collidable(opts.collision_group or "Default", part.CollisionGroup) then return false end
    if opts.respect_can_collide and part.CanCollide == false then return false end
    if opts.ignore_water_material and part.Material == opts.ignore_water_material then return false end
    local fset = opts.filter_ids
    if fset then
        local inset = fset[part._id] == true
        if opts.filter_include then
            if not inset then return false end
        elseif inset then
            return false
        end
    end
    return true
end

-- raycast(...) -> hit|nil, hit={part,distance,px,py,pz,nx,ny,nz}, dx,dy,dz length = reach
-- opts: filter_ids/filter_include (whitelist/blacklist), respect_can_collide, ignore_water_material, extra_parts (untracked, always tested), fallback_parts (broadphase empty)
-- module-level state so test/visit arent per-call closures (closure = jit trace abort), non-reentrant, never raycast inside a query callback
local rc_opts, rc_epoch, rc_seen, rc_tested
local rc_ox, rc_oy, rc_oz, rc_ux, rc_uy, rc_uz
local rc_best_t, rc_best_part, rc_bnx, rc_bny, rc_bnz
-- per-ray slab precompute for rc_scan_static_cell: inverse direction plus the
-- near/far plane offsets into a 6-double AABB record (0..2 = min xyz, 3..5 = max)
local rc_invx, rc_invy, rc_invz
local rc_x0, rc_x1, rc_y0, rc_y1, rc_z0, rc_z1

-- survivor scratch for the slab loop, int32 indices, grown geometrically (a dense
-- static cell can hold thousands of members under STATIC_MAX_PER_CELL)
local rc_surv = ffi.new("int32_t[?]", 1024)
local rc_surv_cap = 1024

local function rc_test_part(part)
    if not part or part._destroyed or part._workspace_active==false then return end
    local pid = part._id
    if pid then
        if rc_tested[pid] == rc_epoch then return end
        rc_tested[pid] = rc_epoch
    end
    if not ray_part_passes(part, rc_opts) then return end
    local t, nx, ny, nz = ray_vs_part(part, rc_ox, rc_oy, rc_oz, rc_ux, rc_uy, rc_uz, rc_best_t)
    if t and t < rc_best_t then
        rc_best_t = t
        rc_best_part, rc_bnx, rc_bny, rc_bnz = part, nx, ny, nz
    end
end

-- Moving (dynamic + sleeping) bodies only: statics are handled per cell by
-- rc_scan_static_cell, so the old member_grid branch for large STATIC assemblies
-- is gone from this visitor (use_member_grid is is_static-gated and moving bodies
-- can never take it)
local function rc_visit_body(body)
    if rc_seen[body.id] == rc_epoch then return end
    rc_seen[body.id] = rc_epoch
    local asm = body.assembly
    local members = asm and asm.parts
    if not members then return end
    for i = 1, #members do
        rc_test_part(members[i]._part)
    end
end

-- compare the ray against the cell’s packed bounds first
-- only surviving members need an exact shape query
local function rc_scan_static_cell(rec)
    local n = rec.n
    if n == 0 then return end
    if n > rc_surv_cap then
        local cap = rc_surv_cap
        while cap < n do cap = cap * 2 end
        rc_surv = ffi.new("int32_t[?]", cap)
        rc_surv_cap = cap
    end
    local boxes = rec.boxes
    local surv = rc_surv
    local ox, oy, oz = rc_ox, rc_oy, rc_oz
    local invx, invy, invz = rc_invx, rc_invy, rc_invz
    local x0, x1, y0, y1, z0, z1 = rc_x0, rc_x1, rc_y0, rc_y1, rc_z0, rc_z1
    -- snapshotting rc_best_t here is safe: it only ever shrinks, so a stale (larger)
    -- limit admits extra survivors, never rejects a valid one
    local limit = rc_best_t
    local m = 0
    for i = 0, n - 1 do
        local b = i * 6
        local t1 = (boxes[b + x0] - ox) * invx
        local t2 = (boxes[b + x1] - ox) * invx
        local u1 = (boxes[b + y0] - oy) * invy
        local u2 = (boxes[b + y1] - oy) * invy
        local v1 = (boxes[b + z0] - oz) * invz
        local v2 = (boxes[b + z1] - oz) * invz
        local tmin = t1 > u1 and t1 or u1
        if v1 > tmin then tmin = v1 end
        local tmax = t2 < u2 and t2 or u2
        if v2 < tmax then tmax = v2 end
        -- accept when [tmin,tmax] overlaps [0, limit], origin-inside gives tmin < 0
        if tmax >= tmin and tmax >= 0 and tmin <= limit then
            surv[m] = i
            m = m + 1
        end
    end
    local views = rec.views
    for j = 0, m - 1 do
        -- deref the core part at test time, exactly like the old members[i]._part read
        rc_test_part(views[surv[j] + 1]._part)
    end
end

function Queries.raycast(world, ox, oy, oz, dx, dy, dz, opts)
    opts = opts or {}
    local maxdist = sqrt(dx * dx + dy * dy + dz * dz)
    if maxdist < EPS then
        return nil
    end
    local ux, uy, uz = dx / maxdist, dy / maxdist, dz / maxdist

    -- epoch-stamped dedup, no per-call alloc/clear
    local seen, tested, epoch
    if world then
        epoch = (world._query_epoch or 0) + 1
        world._query_epoch = epoch
        seen = world._query_seen; if not seen then seen = {}; world._query_seen = seen end
        tested = world._query_tested; if not tested then tested = {}; world._query_tested = tested end
    else
        epoch, seen, tested = 1, {}, {}
    end

    rc_opts, rc_epoch, rc_seen, rc_tested = opts, epoch, seen, tested
    rc_ox, rc_oy, rc_oz, rc_ux, rc_uy, rc_uz = ox, oy, oz, ux, uy, uz
    rc_best_t = maxdist
    rc_best_part, rc_bnx, rc_bny, rc_bnz = nil, 0, 0, 0

    -- slab precompute for rc_scan_static_cell: near/far record offsets picked by
    -- direction sign so the loop needs no per-box swap, degenerate axes (|u| <=
    -- 1e-12, same zero threshold the exact tests use) get a huge finite inverse
    -- so the slab test degrades to containment on that axis without NaN
    if ux > 1e-12 or ux < -1e-12 then rc_invx = 1 / ux else rc_invx = 1e30 end
    if uy > 1e-12 or uy < -1e-12 then rc_invy = 1 / uy else rc_invy = 1e30 end
    if uz > 1e-12 or uz < -1e-12 then rc_invz = 1 / uz else rc_invz = 1e30 end
    if rc_invx >= 0 then rc_x0, rc_x1 = 0, 3 else rc_x0, rc_x1 = 3, 0 end
    if rc_invy >= 0 then rc_y0, rc_y1 = 1, 4 else rc_y0, rc_y1 = 4, 1 end
    if rc_invz >= 0 then rc_z0, rc_z1 = 2, 5 else rc_z0, rc_z1 = 5, 2 end

    local bp = world and world.broadphase
    if bp and bp.has_any_proxy and bp:has_any_proxy() then
        if world.ensure_static_proxies then
            world:ensure_static_proxies()
        end
        -- amanatides-woo 3d dda through broadphase grid
        local cell = bp:cell_size()
        local cx = floor(ox / cell)
        local cy = floor(oy / cell)
        local cz = floor(oz / cell)

        local step_x = (ux > 0) and 1 or ((ux < 0) and -1 or 0)
        local step_y = (uy > 0) and 1 or ((uy < 0) and -1 or 0)
        local step_z = (uz > 0) and 1 or ((uz < 0) and -1 or 0)

        local t_max_x, t_delta_x = huge, huge
        local t_max_y, t_delta_y = huge, huge
        local t_max_z, t_delta_z = huge, huge
        if step_x ~= 0 then
            local nb = (cx + ((ux > 0) and 1 or 0)) * cell
            t_max_x = (nb - ox) / ux
            t_delta_x = cell / abs(ux)
        end
        if step_y ~= 0 then
            local nb = (cy + ((uy > 0) and 1 or 0)) * cell
            t_max_y = (nb - oy) / uy
            t_delta_y = cell / abs(uy)
        end
        if step_z ~= 0 then
            local nb = (cz + ((uz > 0) and 1 or 0)) * cell
            t_max_z = (nb - oz) / uz
            t_delta_z = cell / abs(uz)
        end

        local t_entry = 0
        -- safety fuse only, 3x since a diagonal ray crosses up to 3 axes/cell
        local cap = floor(maxdist / cell) * 3 + 3
        if cap > 4096 then cap = 4096 end
        local iters = 0
        local ex, ey, ez = ox + dx, oy + dy, oz + dz
        local ax, ay, az = floor(math.min(ox, ex) / cell), floor(math.min(oy, ey) / cell), floor(math.min(oz, ez) / cell)
        local bx, by, bz = floor(math.max(ox, ex) / cell), floor(math.max(oy, ey) / cell), floor(math.max(oz, ez) / cell)
        local complete_scan = not key_range(ax, ay, az, bx, by, bz) or floor(maxdist / cell) * 3 + 3 > 4096
        if complete_scan then
            -- a long/out-of-key-range ray cannot stop at a DDA fuse. the proxy
            -- scan supplies a conservative broad bound, unchanged exact leaves
            -- still decide filters, nearest distance, normal and shape coverage
            bp:collect_region(math.min(ox, ex), math.min(oy, ey), math.min(oz, ez),
                math.max(ox, ex), math.max(oy, ey), math.max(oz, ez), rc_visit_body)
        else
        bp:for_overflow_bodies(math.min(ox, ex), math.min(oy, ey), math.min(oz, ez),
            math.max(ox, ex), math.max(oy, ey), math.max(oz, ez), rc_visit_body)
        while t_entry <= maxdist and t_entry <= rc_best_t and iters < cap do
            -- statics: packed-AABB slab prefilter (cell arrays cached in the
            -- broadphase, built lazily on first visit)
            local sq = bp:static_query_cell(cx, cy, cz)
            if sq then rc_scan_static_cell(sq) end
            -- dynamics + sleepers: unchanged per-body visitor
            bp:for_moving_bodies_in_cell(cx, cy, cz, rc_visit_body)
            iters = iters + 1
            if t_max_x <= t_max_y and t_max_x <= t_max_z then
                t_entry = t_max_x; cx = cx + step_x; t_max_x = t_max_x + t_delta_x
            elseif t_max_y <= t_max_z then
                t_entry = t_max_y; cy = cy + step_y; t_max_y = t_max_y + t_delta_y
            else
                t_entry = t_max_z; cz = cz + step_z; t_max_z = t_max_z + t_delta_z
            end
        end
        end
        -- not reliably hashed yet (new dynamics/kinematic followers): always tested, deduped via `tested`
        local extra = opts.extra_parts
        if extra then
            for i = 1, #extra do rc_test_part(extra[i]) end
        end
    else
        -- linear fallback (physics disabled / nothing indexed yet)
        local parts = opts.fallback_parts
        if parts then
            for i = 1, #parts do
                rc_test_part(parts[i])
            end
        end
    end

    local best_part, best_t = rc_best_part, rc_best_t
    local bnx, bny, bnz = rc_bnx, rc_bny, rc_bnz
    -- drop refs so a finished query cant pin parts/opts alive
    rc_best_part, rc_opts, rc_seen, rc_tested = nil, nil, nil, nil

    if not best_part then
        return nil
    end
    return {
        part = best_part,
        distance = best_t,
        px = ox + ux * best_t, py = oy + uy * best_t, pz = oz + uz * best_t,
        nx = bnx, ny = bny, nz = bnz,
    }
end

-- region(...) -> out (core parts w/ aabb overlapping region), opts: ignore_ids, max_parts, fallback_parts
-- module-level state, same closure-free/non-reentrant reasons as raycast above
local rg_n, rg_max, rg_ignore, rg_tested, rg_epoch, rg_out, rg_cell, rg_opts
local rg_minx, rg_miny, rg_minz, rg_maxx, rg_maxy, rg_maxz

local function rg_consider(part)
    if rg_n >= rg_max then return end
    if not part or part._destroyed or part._workspace_active==false then return end
    if rg_opts.exclude_anchored and part.Anchored == true then return end
    local pid = part._id
    if pid then
        if rg_tested[pid] == rg_epoch then return end
        rg_tested[pid] = rg_epoch
    end
    if part.CanQuery == false and not rg_opts.ignore_can_query then return end
    if rg_opts.collision_groups and not rg_opts.collision_groups:collidable(rg_opts.collision_group or "Default", part.CollisionGroup) then return end
    if rg_ignore and rg_ignore[pid] then return end
    local plx, ply, plz, prx, pry, prz = part_world_aabb(part)
    if prx >= rg_minx and plx <= rg_maxx
        and pry >= rg_miny and ply <= rg_maxy
        and prz >= rg_minz and plz <= rg_maxz then
        local n = rg_n + 1
        rg_n = n
        rg_out[n] = part
    end
end

local function rg_visit_body(body)
    if rg_n >= rg_max then return end
    local asm = body.assembly
    local members = asm and asm.parts
    if not members then return end
    if use_member_grid(body) then
        -- large static: cell range must cover the full span, clamping drops far members
        -- region spanning more cells than the body has members: scan members directly, cheaper + cant miss
        local cell = rg_cell
        local ax, ay, az = floor(rg_minx / cell), floor(rg_miny / cell), floor(rg_minz / cell)
        local bx, by, bz = floor(rg_maxx / cell), floor(rg_maxy / cell), floor(rg_maxz / cell)
        local span = (bx - ax + 1) * (by - ay + 1) * (bz - az + 1)
        if span > #members or not key_range(ax, ay, az, bx, by, bz) then
            for i = 1, #members do rg_consider(members[i]._part) end
            return
        end
        local rec = member_grid(body, cell)
        for i = 1, #rec.overflow do rg_consider(rec.overflow[i]) end
        local grid = rec.cells
        for gx = ax, bx do
            for gy = ay, by do
                for gz = az, bz do
                    local bucket = grid[gkey(gx, gy, gz)]
                    if bucket then
                        for i = 1, #bucket do rg_consider(bucket[i]) end
                    end
                end
            end
        end
        return
    end
    for i = 1, #members do
        rg_consider(members[i]._part)
    end
end

function Queries.region(world, minx, miny, minz, maxx, maxy, maxz, opts, out)
    opts = opts or {}
    out = out or {}
    -- pooled epoch dedup (see raycast), no per-call alloc/clear
    local tested, epoch
    if world then
        epoch = (world._query_epoch or 0) + 1
        world._query_epoch = epoch
        tested = world._query_tested; if not tested then tested = {}; world._query_tested = tested end
    else
        epoch, tested = 1, {}
    end

    rg_n = 0
    rg_opts = opts
    rg_max = opts.max_parts or huge
    rg_ignore = opts.ignore_ids
    rg_tested, rg_epoch = tested, epoch
    rg_out = out
    rg_minx, rg_miny, rg_minz = minx, miny, minz
    rg_maxx, rg_maxy, rg_maxz = maxx, maxy, maxz

    local bp = world and world.broadphase
    if bp and bp.has_any_proxy and bp:has_any_proxy() then
        if world.ensure_static_proxies then
            world:ensure_static_proxies()
        end
        rg_cell = bp:cell_size()
        bp:collect_region(minx, miny, minz, maxx, maxy, maxz, rg_visit_body)
        -- not reliably hashed yet (new dynamics/kinematic followers): always considered, deduped via `tested`
        local extra = opts.extra_parts
        if extra then
            for i = 1, #extra do rg_consider(extra[i]) end
        end
    else
        local parts = opts.fallback_parts
        if parts then
            for i = 1, #parts do
                rg_consider(parts[i])
            end
        end
    end
    local n = rg_n
    -- drop refs so a finished query cant pin parts/tables alive
    rg_ignore, rg_tested, rg_out, rg_opts = nil, nil, nil, nil
    return out, n
end

return Queries
