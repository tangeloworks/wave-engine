-- Approximate convex decomposition for collision meshes, cooked offline or
-- once at load and cached, never during gameplay
--
-- the method follows V-HACD (K. Mamou, "Volumetric Hierarchical Approximate
-- Convex Decomposition", Game Engine Gems 3, 2016): voxelize the mesh into a
-- solid, recursively cut it with axis-aligned planes chosen to minimise the
-- concavity (hull volume minus solid volume) of both halves, then merge the
-- neighbouring hulls whose union adds the least volume until the hull budget
-- is met. each hull is built from the actual mesh surface clipped to its
-- region, so outer surfaces are exact, only the internal cut faces follow the
-- voxel grid
--
-- cooking uses plain Lua and can run in a worker
local Hull = require("engine/graphics/rbx/convex_hull")

local M = {}

-- bump whenever cooked output can change, it is part of every cache key
M.VERSION = 2

-- resolution: voxels along the longest axis. concavity: stop splitting a
-- region once its hull exceeds its solid by this fraction of the whole
-- volume. max_hulls: merge budget. max_vertices: per-hull vertex budget
M.PRESETS = {
    Default = { resolution = 24, concavity = 0.02, max_hulls = 16, max_depth = 6, max_vertices = 128, candidates = 6 },
    PreciseConvexDecomposition = { resolution = 48, concavity = 0.0025, max_hulls = 64, max_depth = 9, max_vertices = 128, candidates = 10 },
}

local abs, min, max, floor, ceil, sqrt = math.abs, math.min, math.max, math.floor, math.ceil, math.sqrt

-------------------------------------------------------------------- geometry

-- Triangle / axis-aligned box overlap (Akenine-Möller): box centre c, half
-- size h, triangle corners already relative to c
local function axis_test(ax, ay, az, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz)
    local p0 = ax * v0x + ay * v0y + az * v0z
    local p1 = ax * v1x + ay * v1y + az * v1z
    local p2 = ax * v2x + ay * v2y + az * v2z
    local r = hx * abs(ax) + hy * abs(ay) + hz * abs(az)
    return not (min(p0, p1, p2) > r or max(p0, p1, p2) < -r)
end

local function triangle_box(v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz)
    if min(v0x, v1x, v2x) > hx or max(v0x, v1x, v2x) < -hx then return false end
    if min(v0y, v1y, v2y) > hy or max(v0y, v1y, v2y) < -hy then return false end
    if min(v0z, v1z, v2z) > hz or max(v0z, v1z, v2z) < -hz then return false end
    local e0x, e0y, e0z = v1x - v0x, v1y - v0y, v1z - v0z
    local e1x, e1y, e1z = v2x - v1x, v2y - v1y, v2z - v1z
    local e2x, e2y, e2z = v0x - v2x, v0y - v2y, v0z - v2z
    -- Edge x axis cross products
    if not axis_test(0, -e0z, e0y, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(0, -e1z, e1y, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(0, -e2z, e2y, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(e0z, 0, -e0x, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(e1z, 0, -e1x, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(e2z, 0, -e2x, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(-e0y, e0x, 0, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(-e1y, e1x, 0, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    if not axis_test(-e2y, e2x, 0, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, hx, hy, hz) then return false end
    -- Triangle plane against the box
    local nx, ny, nz = e0y * e1z - e0z * e1y, e0z * e1x - e0x * e1z, e0x * e1y - e0y * e1x
    local d = nx * v0x + ny * v0y + nz * v0z
    local r = hx * abs(nx) + hy * abs(ny) + hz * abs(nz)
    return abs(d) <= r
end

-- Volume of a hull given its points and outward triangle faces
local function hull_volume(points, faces)
    local cx, cy, cz, n = 0, 0, 0, 0
    for _, f in ipairs(faces) do
        for k = 1, 3 do local p = points[f[k]]; cx, cy, cz, n = cx + p[1], cy + p[2], cz + p[3], n + 1 end
    end
    cx, cy, cz = cx / n, cy / n, cz / n
    local volume = 0
    for _, f in ipairs(faces) do
        local a, b, c = points[f[1]], points[f[2]], points[f[3]]
        local ax, ay, az = a[1] - cx, a[2] - cy, a[3] - cz
        local bx, by, bz = b[1] - cx, b[2] - cy, b[3] - cz
        local qx, qy, qz = c[1] - cx, c[2] - cy, c[3] - cz
        volume = volume + abs(ax * (by * qz - bz * qy) - ay * (bx * qz - bz * qx) + az * (bx * qy - by * qx)) / 6
    end
    return volume
end

-- Hull of a point list, nil when the points are flat or too few. the list
-- is reordered outermost first: the incremental builder skips points that
-- would make degenerate faces, so true corners must arrive before the many
-- coplanar points of a face
local function build_hull(points)
    if #points < 4 then return nil end
    local cx, cy, cz = 0, 0, 0
    for _, p in ipairs(points) do cx, cy, cz = cx + p[1], cy + p[2], cz + p[3] end
    cx, cy, cz = cx / #points, cy / #points, cz / #points
    for _, p in ipairs(points) do
        local dx, dy, dz = p[1] - cx, p[2] - cy, p[3] - cz
        p.order = dx * dx + dy * dy + dz * dz
    end
    table.sort(points, function(a, b) return a.order > b.order end)
    local faces = Hull.build(points)
    if not faces then return nil end
    return faces, hull_volume(points, faces)
end

-- keep `count` well spread points: farthest-point sampling from the first
local function spread(points, count)
    if #points <= count then return points end
    local chosen, distance = { points[1] }, {}
    for i = 1, #points do distance[i] = math.huge end
    local last = points[1]
    while #chosen < count do
        local best, best_i = -1, nil
        for i = 1, #points do
            local p = points[i]
            local dx, dy, dz = p[1] - last[1], p[2] - last[2], p[3] - last[3]
            local d = dx * dx + dy * dy + dz * dz
            if d < distance[i] then distance[i] = d end
            if distance[i] > best then best, best_i = distance[i], i end
        end
        if best <= 0 then break end
        last = points[best_i]
        chosen[#chosen + 1] = last
    end
    return chosen
end

-------------------------------------------------------------------- voxels

local function voxelize(positions, resolution)
    local lo = { math.huge, math.huge, math.huge }
    local hi = { -math.huge, -math.huge, -math.huge }
    for i = 1, #positions, 3 do
        for k = 1, 3 do
            local v = positions[i + k - 1]
            if v < lo[k] then lo[k] = v end
            if v > hi[k] then hi[k] = v end
        end
    end
    local extent = max(hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3])
    assert(extent > 0, "Collision mesh has no extent")
    local h = extent / resolution
    local n = {}
    for k = 1, 3 do
        -- Pad flat axes to one voxel so a planar mesh still gets a grid
        n[k] = max(1, ceil((hi[k] - lo[k]) / h - 1e-9))
        local slack = n[k] * h - (hi[k] - lo[k])
        lo[k] = lo[k] - slack / 2
    end
    local nx, ny, nz = n[1], n[2], n[3]
    local surface = {}
    local half = h * 0.5 * (1 + 1e-6)
    for t = 1, #positions, 9 do
        local ax, ay, az = positions[t], positions[t + 1], positions[t + 2]
        local bx, by, bz = positions[t + 3], positions[t + 4], positions[t + 5]
        local cx, cy, cz = positions[t + 6], positions[t + 7], positions[t + 8]
        -- Faces on the grid's far boundary belong to its last voxel layer
        local i0 = min(nx - 1, max(0, floor((min(ax, bx, cx) - lo[1]) / h)))
        local i1 = min(nx - 1, floor((max(ax, bx, cx) - lo[1]) / h))
        local j0 = min(ny - 1, max(0, floor((min(ay, by, cy) - lo[2]) / h)))
        local j1 = min(ny - 1, floor((max(ay, by, cy) - lo[2]) / h))
        local k0 = min(nz - 1, max(0, floor((min(az, bz, cz) - lo[3]) / h)))
        local k1 = min(nz - 1, floor((max(az, bz, cz) - lo[3]) / h))
        for k = k0, k1 do
            local oz = lo[3] + (k + 0.5) * h
            for j = j0, j1 do
                local oy = lo[2] + (j + 0.5) * h
                for i = i0, i1 do
                    local id = i + nx * (j + ny * k)
                    if not surface[id] then
                        local ox = lo[1] + (i + 0.5) * h
                        if triangle_box(ax - ox, ay - oy, az - oz, bx - ox, by - oy, bz - oz, cx - ox, cy - oy, cz - oz, half, half, half) then
                            surface[id] = true
                        end
                    end
                end
            end
        end
    end
    -- Flood the outside from a one-voxel border, whatever stays dry and is
    -- not surface is interior. an open mesh simply has no interior
    local px, py, pz = nx + 2, ny + 2, nz + 2
    local outside, queue, head = {}, {}, 1
    local function push(i, j, k)
        local id = (i + 1) + px * ((j + 1) + py * (k + 1))
        if outside[id] then return end
        if i >= 0 and j >= 0 and k >= 0 and i < nx and j < ny and k < nz and surface[i + nx * (j + ny * k)] then return end
        outside[id] = true
        queue[#queue + 1] = id
    end
    push(-1, -1, -1)
    while head <= #queue do
        local id = queue[head]; head = head + 1
        local i = id % px - 1
        local rest = (id - (i + 1)) / px
        local j = rest % py - 1
        local k = (rest - (j + 1)) / py - 1
        if i > -1 then push(i - 1, j, k) end
        if i < nx then push(i + 1, j, k) end
        if j > -1 then push(i, j - 1, k) end
        if j < ny then push(i, j + 1, k) end
        if k > -1 then push(i, j, k - 1) end
        if k < nz then push(i, j, k + 1) end
    end
    local solid, count = {}, 0
    for k = 0, nz - 1 do
        for j = 0, ny - 1 do
            for i = 0, nx - 1 do
                local id = i + nx * (j + ny * k)
                if surface[id] or not outside[(i + 1) + px * ((j + 1) + py * (k + 1))] then
                    solid[id] = true
                    count = count + 1
                end
            end
        end
    end
    -- Summed-volume table: solid voxels in any box in constant time
    local sat = {}
    local sx, sy = nx + 1, ny + 1
    for k = 0, nz do
        for j = 0, ny do
            for i = 0, nx do
                local id = i + sx * (j + sy * k)
                if i == 0 or j == 0 or k == 0 then
                    sat[id] = 0
                else
                    local v = solid[(i - 1) + nx * ((j - 1) + ny * (k - 1))] and 1 or 0
                    sat[id] = v + sat[id - 1] + sat[id - sx] + sat[id - sx * sy]
                        - sat[id - 1 - sx] - sat[id - 1 - sx * sy] - sat[id - sx - sx * sy]
                        + sat[id - 1 - sx - sx * sy]
                end
            end
        end
    end
    return {
        lo = lo, h = h, n = n, solid = solid, surface = surface, count = count, sat = sat, sx = sx, sy = sy,
    }
end

-- Solid voxels in the half-open index box [i0,i1) x [j0,j1) x [k0,k1)
local function box_count(g, i0, i1, j0, j1, k0, k1)
    local sat, sx, sxy = g.sat, g.sx, g.sx * g.sy
    local function at(i, j, k) return sat[i + sx * j + sxy * k] end
    return at(i1, j1, k1) - at(i0, j1, k1) - at(i1, j0, k1) - at(i1, j1, k0)
        + at(i0, j0, k1) + at(i0, j1, k0) + at(i1, j0, k0) - at(i0, j0, k0)
end

-- Directions for support points: the 26 grid directions catch box corners
-- and a Fibonacci sphere catches rounded surfaces
local DIRECTIONS = {}
do
    for x = -1, 1 do for y = -1, 1 do for z = -1, 1 do
        if x ~= 0 or y ~= 0 or z ~= 0 then
            local l = sqrt(x * x + y * y + z * z)
            DIRECTIONS[#DIRECTIONS + 1] = { x / l, y / l, z / l }
        end
    end end end
    local count, golden = 40, math.pi * (3 - sqrt(5))
    for i = 0, count - 1 do
        local y = 1 - (i + 0.5) / count * 2
        local radius = sqrt(1 - y * y)
        DIRECTIONS[#DIRECTIONS + 1] = { math.cos(golden * i) * radius, y, math.sin(golden * i) * radius }
    end
end
local DIRECTION_COUNT = #DIRECTIONS

-- Solid voxels of region r with a non-solid or out-of-region neighbour, the
-- hull of these is the hull of the region's solid
local function boundary_voxels(g, r)
    local nx, ny = g.n[1], g.n[2]
    local solid = g.solid
    local i0, i1, j0, j1, k0, k1 = r[1], r[2], r[3], r[4], r[5], r[6]
    local list = {}
    local function inside(i, j, k)
        return i >= i0 and i < i1 and j >= j0 and j < j1 and k >= k0 and k < k1 and solid[i + nx * (j + ny * k)]
    end
    for k = k0, k1 - 1 do
        for j = j0, j1 - 1 do
            for i = i0, i1 - 1 do
                if solid[i + nx * (j + ny * k)] and not (inside(i - 1, j, k) and inside(i + 1, j, k)
                    and inside(i, j - 1, k) and inside(i, j + 1, k) and inside(i, j, k - 1) and inside(i, j, k + 1)) then
                    list[#list + 1] = { i, j, k }
                end
            end
        end
    end
    return list
end

-- per-slice support of the region along each axis: for every slice and
-- direction, the voxel whose outermost corner reaches furthest. a cut's two
-- halves then take prefix and suffix maxima, so every candidate cut on an
-- axis costs one pass over the boundary
local function slice_supports(g, r, voxels)
    local lo, h = g.lo, g.h
    local reach = {}
    for d = 1, DIRECTION_COUNT do
        local v = DIRECTIONS[d]
        reach[d] = h * 0.5 * (abs(v[1]) + abs(v[2]) + abs(v[3]))
    end
    local axes = {}
    for axis = 1, 3 do
        local span = r[axis * 2] - r[axis * 2 - 1]
        local best, point = {}, {}
        for s = 1, span do best[s] = {}; point[s] = {} end
        axes[axis] = { best = best, point = point, span = span, origin = r[axis * 2 - 1] }
    end
    for _, voxel in ipairs(voxels) do
        local cx, cy, cz = lo[1] + (voxel[1] + 0.5) * h, lo[2] + (voxel[2] + 0.5) * h, lo[3] + (voxel[3] + 0.5) * h
        local s1 = voxel[1] - axes[1].origin + 1
        local s2 = voxel[2] - axes[2].origin + 1
        local s3 = voxel[3] - axes[3].origin + 1
        local b1, b2, b3 = axes[1].best[s1], axes[2].best[s2], axes[3].best[s3]
        local p1, p2, p3 = axes[1].point[s1], axes[2].point[s2], axes[3].point[s3]
        for d = 1, DIRECTION_COUNT do
            local v = DIRECTIONS[d]
            local value = v[1] * cx + v[2] * cy + v[3] * cz + reach[d]
            if not b1[d] or value > b1[d] then b1[d] = value; p1[d] = voxel end
            if not b2[d] or value > b2[d] then b2[d] = value; p2[d] = voxel end
            if not b3[d] or value > b3[d] then b3[d] = value; p3[d] = voxel end
        end
    end
    return axes
end

-- Hull volume of the voxels supporting slices [first, last] of one axis
local function supported_volume(g, support, first, last)
    local lo, h = g.lo, g.h
    local points, seen = {}, {}
    for d = 1, DIRECTION_COUNT do
        local best, voxel = nil, nil
        for s = first, last do
            local value = support.best[s][d]
            if value and (not best or value > best) then best, voxel = value, support.point[s][d] end
        end
        if voxel then
            local v = DIRECTIONS[d]
            -- the voxel's corner on the direction's side
            local x = lo[1] + (voxel[1] + (v[1] >= 0 and 1 or 0)) * h
            local y = lo[2] + (voxel[2] + (v[2] >= 0 and 1 or 0)) * h
            local z = lo[3] + (voxel[3] + (v[3] >= 0 and 1 or 0)) * h
            local key = x .. "," .. y .. "," .. z
            if not seen[key] then seen[key] = true; points[#points + 1] = { x, y, z } end
        end
    end
    local _, volume = build_hull(points)
    return volume or 0
end

local function concavity_of(g, count, volume, total)
    return max(0, volume - count * g.h * g.h * g.h) / total
end

-- Shrink a region box to the bounds of the solid voxels it contains
local function tighten(g, r)
    local i0, i1, j0, j1, k0, k1 = r[1], r[2], r[3], r[4], r[5], r[6]
    while i1 - i0 > 1 and box_count(g, i0, i0 + 1, j0, j1, k0, k1) == 0 do i0 = i0 + 1 end
    while i1 - i0 > 1 and box_count(g, i1 - 1, i1, j0, j1, k0, k1) == 0 do i1 = i1 - 1 end
    while j1 - j0 > 1 and box_count(g, i0, i1, j0, j0 + 1, k0, k1) == 0 do j0 = j0 + 1 end
    while j1 - j0 > 1 and box_count(g, i0, i1, j1 - 1, j1, k0, k1) == 0 do j1 = j1 - 1 end
    while k1 - k0 > 1 and box_count(g, i0, i1, j0, j1, k0, k0 + 1) == 0 do k0 = k0 + 1 end
    while k1 - k0 > 1 and box_count(g, i0, i1, j0, j1, k1 - 1, k1) == 0 do k1 = k1 - 1 end
    return { i0, i1, j0, j1, k0, k1 }
end

-------------------------------------------------------------------- splitting

local function split(g, params, total)
    local regions = {}
    local stack = { { region = tighten(g, { 0, g.n[1], 0, g.n[2], 0, g.n[3] }), depth = 0 } }
    while #stack > 0 do
        local item = table.remove(stack)
        local r = item.region
        local count = box_count(g, r[1], r[2], r[3], r[4], r[5], r[6])
        local size = { r[2] - r[1], r[4] - r[3], r[6] - r[5] }
        local supports = count > 0 and slice_supports(g, r, boundary_voxels(g, r))
        local c = supports and concavity_of(g, count, supported_volume(g, supports[1], 1, supports[1].span), total) or 0
        if c <= params.concavity or item.depth >= params.max_depth or count < 8
            or (size[1] <= 1 and size[2] <= 1 and size[3] <= 1) then
            regions[#regions + 1] = r
        else
            local best, best_a, best_b = math.huge, nil, nil
            for axis = 1, 3 do
                local support = supports[axis]
                local lo_i, span = r[axis * 2 - 1], support.span
                if span >= 2 then
                    local steps = min(params.candidates, span - 1)
                    for step = 1, steps do
                        local cut = floor(step * span / (steps + 1) + 0.5)
                        if cut >= 1 and cut < span then
                            local a = { r[1], r[2], r[3], r[4], r[5], r[6] }
                            local b = { r[1], r[2], r[3], r[4], r[5], r[6] }
                            a[axis * 2] = lo_i + cut
                            b[axis * 2 - 1] = lo_i + cut
                            local na = box_count(g, a[1], a[2], a[3], a[4], a[5], a[6])
                            local nb = count - na
                            if na > 0 and nb > 0 then
                                local ca = concavity_of(g, na, supported_volume(g, support, 1, cut), total)
                                local cb = concavity_of(g, nb, supported_volume(g, support, cut + 1, span), total)
                                local cost = ca + cb + 0.05 * abs(na - nb) / g.count
                                if cost < best then best, best_a, best_b = cost, a, b end
                            end
                        end
                    end
                end
            end
            if best_a then
                stack[#stack + 1] = { region = tighten(g, best_a), depth = item.depth + 1 }
                stack[#stack + 1] = { region = tighten(g, best_b), depth = item.depth + 1 }
            else
                regions[#regions + 1] = r
            end
        end
    end
    return regions
end

-------------------------------------------------------------------- hulls

-- Clip a convex polygon to one axis-aligned half space (Sutherland-Hodgman)
local function clip(polygon, axis, value, keep_below)
    local out = {}
    local count = #polygon
    for index = 1, count do
        local a, b = polygon[index], polygon[index % count + 1]
        local da = keep_below and (value - a[axis]) or (a[axis] - value)
        local db = keep_below and (value - b[axis]) or (b[axis] - value)
        if da >= 0 then out[#out + 1] = a end
        if (da >= 0) ~= (db >= 0) then
            local t = da / (da - db)
            out[#out + 1] = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
        end
    end
    return out
end

-- Points of the solid inside a region: the mesh surface clipped to the
-- region box, plus the voxel corners of the solid's cross-section on each
-- cut face, so the hull closes across the internal seams
local function exact_points(g, positions, triangles, r)
    local lo, h = g.lo, g.h
    -- a hair of padding keeps faces lying exactly on a region's bounds,
    -- which grid arithmetic can place just outside them
    local pad = h * 1e-4
    local ex0, ex1 = lo[1] + r[1] * h, lo[1] + r[2] * h
    local ey0, ey1 = lo[2] + r[3] * h, lo[2] + r[4] * h
    local ez0, ez1 = lo[3] + r[5] * h, lo[3] + r[6] * h
    local bx0, bx1, by0, by1, bz0, bz1 = ex0 - pad, ex1 + pad, ey0 - pad, ey1 + pad, ez0 - pad, ez1 + pad
    local points, seen = {}, {}
    -- Points closer than this merge, so hulls get no sliver faces
    local quantum = h * 1e-3
    local function add(p)
        -- back onto the exact box: no point sits a padding width outside
        p = { min(ex1, max(ex0, p[1])), min(ey1, max(ey0, p[2])), min(ez1, max(ez0, p[3])) }
        local key = floor(p[1] / quantum + 0.5) .. "," .. floor(p[2] / quantum + 0.5) .. "," .. floor(p[3] / quantum + 0.5)
        if not seen[key] then seen[key] = true; points[#points + 1] = p end
    end
    for _, t in ipairs(triangles) do
        if not (t.x1 < bx0 or t.x0 > bx1 or t.y1 < by0 or t.y0 > by1 or t.z1 < bz0 or t.z0 > bz1) then
            local i = t.index
            local polygon = {
                { positions[i], positions[i + 1], positions[i + 2] },
                { positions[i + 3], positions[i + 4], positions[i + 5] },
                { positions[i + 6], positions[i + 7], positions[i + 8] },
            }
            polygon = clip(polygon, 1, bx0, false); if #polygon > 0 then polygon = clip(polygon, 1, bx1, true) end
            if #polygon > 0 then polygon = clip(polygon, 2, by0, false) end
            if #polygon > 0 then polygon = clip(polygon, 2, by1, true) end
            if #polygon > 0 then polygon = clip(polygon, 3, bz0, false) end
            if #polygon > 0 then polygon = clip(polygon, 3, bz1, true) end
            for _, p in ipairs(polygon) do add(p) end
        end
    end
    -- Cross-section corners where the solid meets the region's faces
    local nx, ny = g.n[1], g.n[2]
    local solid = g.solid
    for k = r[5], r[6] - 1 do
        for j = r[3], r[4] - 1 do
            for i = r[1], r[2] - 1 do
                if solid[i + nx * (j + ny * k)] and (i == r[1] or i == r[2] - 1 or j == r[3] or j == r[4] - 1
                    or k == r[5] or k == r[6] - 1) and not g.surface[i + nx * (j + ny * k)] then
                    for c = 0, 7 do
                        local ci, cj, ck = i + c % 2, j + floor(c / 2) % 2, k + floor(c / 4)
                        add({ lo[1] + ci * h, lo[2] + cj * h, lo[3] + ck * h })
                    end
                end
            end
        end
    end
    return points, { ex0, ex1, ey0, ey1, ez0, ez1 }
end

-- a flat point set (a single planar surface) becomes a thin slab
local function thicken(points, h)
    local out = {}
    local ax, ay, az, best = 0, 0, 0, -1
    local p0 = points[1]
    for _, p in ipairs(points) do
        for _, q in ipairs(points) do
            local ux, uy, uz = p[1] - p0[1], p[2] - p0[2], p[3] - p0[3]
            local vx, vy, vz = q[1] - p0[1], q[2] - p0[2], q[3] - p0[3]
            local cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            local l = cx * cx + cy * cy + cz * cz
            if l > best then best, ax, ay, az = l, cx, cy, cz end
        end
        if #points > 64 then break end
    end
    if best <= 0 then return nil end
    local l = sqrt(best)
    ax, ay, az = ax / l * h * 0.25, ay / l * h * 0.25, az / l * h * 0.25
    for _, p in ipairs(points) do
        out[#out + 1] = { p[1] + ax, p[2] + ay, p[3] + az }
        out[#out + 1] = { p[1] - ax, p[2] - ay, p[3] - az }
    end
    return out
end

local function finish_hull(points, max_vertices, h)
    if #points > 4096 then points = spread(points, 4096) end
    local faces, volume = build_hull(points)
    if not faces then
        local slab = points[1] and thicken(points, h)
        if not slab then return nil end
        points = slab
        faces, volume = build_hull(points)
        if not faces then return nil end
    end
    -- keep only the hull's own vertices, then meet the vertex budget
    local used, hull_points = {}, {}
    for _, f in ipairs(faces) do for k = 1, 3 do
        if not used[f[k]] then used[f[k]] = true; hull_points[#hull_points + 1] = points[f[k]] end
    end end
    if #hull_points > max_vertices then
        hull_points = spread(hull_points, max_vertices)
    end
    faces, volume = build_hull(hull_points)
    if not faces then return nil end
    return { points = hull_points, faces = faces, volume = volume }
end

-- rebuild a hull from its own vertices until none lies outside any face
-- plane by more than `tolerance`, so the engine's strict convexity and
-- closed-manifold checks accept it. a vertex the builder kept within its
-- coplanarity margin of a face is dropped, that moves the surface by less
-- than the margin. returns flat vertices and triangle faces, or nil
local function clean(points, tolerance)
    -- Points closer than this are one point
    local extent = 0
    for _, p in ipairs(points) do extent = max(extent, abs(p[1]), abs(p[2]), abs(p[3])) end
    local quantum, seen, unique = max(1e-9, extent * 1e-7), {}, {}
    for _, p in ipairs(points) do
        local key = floor(p[1] / quantum + 0.5) .. "," .. floor(p[2] / quantum + 0.5) .. "," .. floor(p[3] / quantum + 0.5)
        if not seen[key] then seen[key] = true; unique[#unique + 1] = p end
    end
    points = unique
    for _ = 1, 32 do
        local faces = build_hull(points)
        if not faces then return nil end
        local remap, vertices, flat = {}, {}, {}
        for _, f in ipairs(faces) do for k = 1, 3 do
            local id = f[k]
            if not remap[id] then
                vertices[#vertices + 1] = points[id]
                remap[id] = #vertices
            end
        end end
        local out = {}
        local worst, worst_id = tolerance, nil
        for index, f in ipairs(faces) do
            local a, b, c = points[f[1]], points[f[2]], points[f[3]]
            local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
            local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
            local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            local l = sqrt(nx * nx + ny * ny + nz * nz)
            if l <= 1e-12 * max(1, extent * extent) then
                -- a sliver: its middle point (opposite the longest edge) goes
                local function d2(p, q) local x, y, z = p[1] - q[1], p[2] - q[2], p[3] - q[3]; return x * x + y * y + z * z end
                local ab, bc, ca = d2(a, b), d2(b, c), d2(c, a)
                local middle = ab >= bc and ab >= ca and f[3] or bc >= ca and f[1] or f[2]
                worst, worst_id = math.huge, remap[middle]
                break
            end
            nx, ny, nz = nx / l, ny / l, nz / l
            local d = nx * a[1] + ny * a[2] + nz * a[3]
            for id, p in ipairs(vertices) do
                local over = nx * p[1] + ny * p[2] + nz * p[3] - d
                if over > worst then worst, worst_id = over, id end
            end
            out[index] = { remap[f[1]], remap[f[2]], remap[f[3]] }
        end
        if not worst_id then
            if #out ~= 2 * #vertices - 4 then return nil end
            for _, p in ipairs(vertices) do flat[#flat + 1] = p[1]; flat[#flat + 1] = p[2]; flat[#flat + 1] = p[3] end
            return flat, out, vertices
        end
        local kept = {}
        for id, p in ipairs(vertices) do if id ~= worst_id then kept[#kept + 1] = p end end
        points = kept
        if #points < 4 then return nil end
    end
    return nil
end

---a convex hull of `points` ({x,y,z} each) that passes the engine's cache
---validation, as flat vertices and triangles, nil for flat or tiny sets
function M.clean_hull(points, tolerance)
    local copy = {}
    for index, p in ipairs(points) do copy[index] = { p[1], p[2], p[3] } end
    local flat, faces = clean(copy, tolerance or 2e-7)
    if not flat then return nil end
    return { vertices = flat, faces = faces }
end

local function boxes_touch(a, b)
    local function overlap(a0, a1, b0, b1) return a0 <= b1 + 1e-9 and b0 <= a1 + 1e-9 end
    return overlap(a[1], a[2], b[1], b[2]) and overlap(a[3], a[4], b[3], b[4]) and overlap(a[5], a[6], b[5], b[6])
end

-- Greedily merge touching hulls by the least added volume: always while
-- over the budget, and beyond it while a merge adds less than `tolerance`
-- (a fraction of the solid's volume), as V-HACD does, so pieces of a convex
-- part rejoin and real openings stay open
local function merge(hulls, budget, max_vertices, h, tolerance, total)
    local function union_cost(a, b)
        local points = {}
        for _, p in ipairs(a.points) do points[#points + 1] = p end
        for _, p in ipairs(b.points) do points[#points + 1] = p end
        local faces, volume = build_hull(points)
        if not faces then return math.huge end
        return volume - a.volume - b.volume
    end
    while #hulls > 1 do
        local best, bi, bj = math.huge, nil, nil
        for i = 1, #hulls do
            for j = i + 1, #hulls do
                if boxes_touch(hulls[i].box, hulls[j].box) then
                    local key = hulls[i].id .. ":" .. hulls[j].id
                    local cost = hulls.costs[key]
                    if not cost then cost = union_cost(hulls[i], hulls[j]); hulls.costs[key] = cost end
                    if cost < best then best, bi, bj = cost, i, j end
                end
            end
        end
        local over = #hulls > budget
        if not bi and over then
            -- no touching pair left (separate pieces): merge the closest boxes
            for i = 1, #hulls do for j = i + 1, #hulls do
                local a, b = hulls[i].box, hulls[j].box
                local gap = max(0, a[1] - b[2], b[1] - a[2]) + max(0, a[3] - b[4], b[3] - a[4]) + max(0, a[5] - b[6], b[5] - a[6])
                if gap < best then best, bi, bj = gap, i, j end
            end end
        end
        if not bi or not (over or best <= tolerance * total) then break end
        local a, b = hulls[bi], hulls[bj]
        local points = {}
        for _, p in ipairs(a.points) do points[#points + 1] = p end
        for _, p in ipairs(b.points) do points[#points + 1] = p end
        local merged = finish_hull(points, max_vertices, h)
        if not merged then break end
        merged.box = { min(a.box[1], b.box[1]), max(a.box[2], b.box[2]), min(a.box[3], b.box[3]),
            max(a.box[4], b.box[4]), min(a.box[5], b.box[5]), max(a.box[6], b.box[6]) }
        hulls.serial = hulls.serial + 1
        merged.id = hulls.serial
        table.remove(hulls, bj); table.remove(hulls, bi)
        hulls[#hulls + 1] = merged
    end
end

-------------------------------------------------------------------- public


---Decompose a triangle soup into convex hulls
---@param positions number[] x,y,z per vertex, three vertices per triangle
---@param preset string|table a name from M.PRESETS or explicit parameters
---@return table hulls array of { vertices = {x,y,z,...}, faces = {{a,b,c},...} }
---@return table stats
function M.decompose(positions, preset)
    local params = type(preset) == "table" and preset or assert(M.PRESETS[preset], "Unknown decomposition preset " .. tostring(preset))
    assert(#positions >= 9 and #positions % 9 == 0, "Decomposition needs whole triangles")
    local started = os.clock()
    local g = voxelize(positions, params.resolution)
    assert(g.count > 0, "Collision mesh produced no solid voxels")
    local total = g.count * g.h * g.h * g.h
    local regions = split(g, params, total)
    local triangles = {}
    for i = 1, #positions, 9 do
        triangles[#triangles + 1] = {
            index = i,
            x0 = min(positions[i], positions[i + 3], positions[i + 6]), x1 = max(positions[i], positions[i + 3], positions[i + 6]),
            y0 = min(positions[i + 1], positions[i + 4], positions[i + 7]), y1 = max(positions[i + 1], positions[i + 4], positions[i + 7]),
            z0 = min(positions[i + 2], positions[i + 5], positions[i + 8]), z1 = max(positions[i + 2], positions[i + 5], positions[i + 8]),
        }
    end
    local hulls = { costs = {}, serial = 0 }
    local dropped = 0
    for _, r in ipairs(regions) do
        local points, box = exact_points(g, positions, triangles, r)
        local hull = #points > 0 and finish_hull(points, params.max_vertices, g.h)
        if hull then
            hulls.serial = hulls.serial + 1
            hull.id, hull.box = hulls.serial, box
            hulls[#hulls + 1] = hull
        else
            dropped = dropped + 1
        end
    end
    local leaves = #hulls
    merge(hulls, params.max_hulls, params.max_vertices, g.h, params.concavity, total)
    local out, hull_volume_sum = {}, 0
    local tolerance = 1e-9 * max(1, g.h * max(g.n[1], g.n[2], g.n[3]))
    for _, hull in ipairs(hulls) do
        local cleaned = M.clean_hull(hull.points, tolerance)
        if cleaned then
            out[#out + 1] = cleaned
            hull_volume_sum = hull_volume_sum + hull.volume
        else
            dropped = dropped + 1
        end
    end
    return out, {
        voxels = g.count, voxel_size = g.h, grid = { g.n[1], g.n[2], g.n[3] },
        regions = #regions, leaves = leaves, dropped = dropped, hulls = #out,
        solid_volume = total, hull_volume = hull_volume_sum, seconds = os.clock() - started,
        grid_data = g,
    }
end

local function hull_planes(hulls)
    local planes = {}
    for index, hull in ipairs(hulls) do
        local v = hull.vertices
        local list = {}
        local cx, cy, cz, n = 0, 0, 0, #v / 3
        for i = 1, #v, 3 do cx, cy, cz = cx + v[i], cy + v[i + 1], cz + v[i + 2] end
        cx, cy, cz = cx / n, cy / n, cz / n
        for _, f in ipairs(hull.faces) do
            local a, b, c = (f[1] - 1) * 3 + 1, (f[2] - 1) * 3 + 1, (f[3] - 1) * 3 + 1
            local ux, uy, uz = v[b] - v[a], v[b + 1] - v[a + 1], v[b + 2] - v[a + 2]
            local wx, wy, wz = v[c] - v[a], v[c + 1] - v[a + 1], v[c + 2] - v[a + 2]
            local nx, ny, nz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
            local l = sqrt(nx * nx + ny * ny + nz * nz)
            if l > 1e-9 then
                nx, ny, nz = nx / l, ny / l, nz / l
                local d = nx * v[a] + ny * v[a + 1] + nz * v[a + 2]
                if nx * cx + ny * cy + nz * cz > d then nx, ny, nz, d = -nx, -ny, -nz, -d end
                list[#list + 1] = { nx, ny, nz, d }
            end
        end
        planes[index] = list
    end
    return planes
end
M.hull_planes = hull_planes

-- Inside a closed triangle mesh by ray parity along a slightly tilted axis
local function inside_mesh(positions, x, y, z)
    local dx, dy, dz = 1, 0.0123, 0.0071
    local crossings = 0
    for t = 1, #positions, 9 do
        local ax, ay, az = positions[t], positions[t + 1], positions[t + 2]
        local e1x, e1y, e1z = positions[t + 3] - ax, positions[t + 4] - ay, positions[t + 5] - az
        local e2x, e2y, e2z = positions[t + 6] - ax, positions[t + 7] - ay, positions[t + 8] - az
        local px, py, pz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
        local det = e1x * px + e1y * py + e1z * pz
        if abs(det) > 1e-14 then
            local inv = 1 / det
            local sx, sy, sz = x - ax, y - ay, z - az
            local u = (sx * px + sy * py + sz * pz) * inv
            if u >= 0 and u <= 1 then
                local qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
                local v = (dx * qx + dy * qy + dz * qz) * inv
                if v >= 0 and u + v <= 1 and (e2x * qx + e2y * qy + e2z * qz) * inv > 0 then crossings = crossings + 1 end
            end
        end
    end
    return crossings % 2 == 1
end

---Coverage of a closed mesh by hulls, sampled on a regular grid over its
---bounds: `missed` is mesh volume outside every hull and `extra` is hull
---volume outside the mesh, both as fractions of the mesh volume
function M.measure(hulls, positions, samples)
    samples = samples or 24
    local lo = { math.huge, math.huge, math.huge }
    local hi = { -math.huge, -math.huge, -math.huge }
    for i = 1, #positions, 3 do for k = 1, 3 do
        lo[k] = min(lo[k], positions[i + k - 1]); hi[k] = max(hi[k], positions[i + k - 1])
    end end
    local planes = hull_planes(hulls)
    local function inside_hulls(x, y, z)
        for _, list in ipairs(planes) do
            local ok = true
            for _, p in ipairs(list) do
                if p[1] * x + p[2] * y + p[3] * z - p[4] > 1e-9 then ok = false; break end
            end
            if ok then return true end
        end
        return false
    end
    local step = max(hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3]) / samples
    local mesh, missed, extra = 0, 0, 0
    for x = lo[1] + step / 2, hi[1], step do
        for y = lo[2] + step / 2, hi[2], step do
            for z = lo[3] + step / 2, hi[3], step do
                local m, h = inside_mesh(positions, x, y, z), inside_hulls(x, y, z)
                if m then mesh = mesh + 1 end
                if m and not h then missed = missed + 1 end
                if h and not m then extra = extra + 1 end
            end
        end
    end
    if mesh == 0 then return { missed = 0, extra = 0, samples = 0 } end
    return { missed = missed / mesh, extra = extra / mesh, samples = mesh }
end

return M
