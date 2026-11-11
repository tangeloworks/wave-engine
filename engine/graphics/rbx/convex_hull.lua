-- build a convex hull by inserting one point at a time
-- a single CSGPHS hull can be triangulated from its vertices without decoding its connectivity stream
-- cache each face plane so the inner loop only needs a dot product

local convex_hull = {}

local sqrt = math.sqrt
local abs = math.abs
local huge = math.huge

local function plane_of(p, ia, ib, ic)
    local a, b, c = p[ia], p[ib], p[ic]
    local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
    local nx = uy * vz - uz * vy
    local ny = uz * vx - ux * vz
    local nz = ux * vy - uy * vx
    local len = sqrt(nx * nx + ny * ny + nz * nz)
    if len <= 1e-20 then
        return nil
    end
    nx, ny, nz = nx / len, ny / len, nz / len
    return nx, ny, nz, nx * a[1] + ny * a[2] + nz * a[3]
end

local function make_face(p, ia, ib, ic)
    local nx, ny, nz, d = plane_of(p, ia, ib, ic)
    if not nx then
        return nil
    end
    return { ia, ib, ic, nx = nx, ny = ny, nz = nz, d = d, dead = false }
end

---Chooses four points that span a non-degenerate tetrahedron
---@return number|nil i0, number i1, number i2, number i3
local function seed_tetrahedron(p, n, eps)
    -- widest axis-aligned extent gives the most numerically stable base edge
    local min_i, max_i = { 1, 1, 1 }, { 1, 1, 1 }
    for i = 2, n do
        local v = p[i]
        for axis = 1, 3 do
            if v[axis] < p[min_i[axis]][axis] then min_i[axis] = i end
            if v[axis] > p[max_i[axis]][axis] then max_i[axis] = i end
        end
    end
    local i0, i1, best = 1, 1, -1
    for axis = 1, 3 do
        local a, b = p[min_i[axis]], p[max_i[axis]]
        local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
        local m = dx * dx + dy * dy + dz * dz
        if m > best then
            best, i0, i1 = m, min_i[axis], max_i[axis]
        end
    end
    if best <= eps * eps then
        return nil
    end

    local a, b = p[i0], p[i1]
    local ex, ey, ez = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local i2 = 0
    best = -1
    for i = 1, n do
        local v = p[i]
        local wx, wy, wz = v[1] - a[1], v[2] - a[2], v[3] - a[3]
        local cx = ey * wz - ez * wy
        local cy = ez * wx - ex * wz
        local cz = ex * wy - ey * wx
        local m = cx * cx + cy * cy + cz * cz
        if m > best then best, i2 = m, i end
    end
    if i2 == 0 or best <= eps * eps then
        return nil
    end

    local nx, ny, nz = plane_of(p, i0, i1, i2)
    if not nx then
        return nil
    end
    local i3, signed = 0, 0
    for i = 1, n do
        local v = p[i]
        local s = nx * (v[1] - a[1]) + ny * (v[2] - a[2]) + nz * (v[3] - a[3])
        if abs(s) > abs(signed) then signed, i3 = s, i end
    end
    if i3 == 0 or abs(signed) <= eps then
        return nil
    end
    -- order so that (i0,i1,i2) winds away from i3, i.e. all four faces face outward
    if signed > 0 then
        return i0, i2, i1, i3
    end
    return i0, i1, i2, i3
end

---builds the convex hull of `points` ({x,y,z} arrays, 1-based)
---
---@param points table
---@param eps number|nil  absolute tolerance; defaults to 1e-5 x cloud extent
---@return table|nil faces  array of {i1,i2,i3} index triples, outward-wound
---@return table|nil info   { vertex_count, face_count, centroid = {x,y,z}, exact }
function convex_hull.build(points, eps)
    local n = points and #points or 0
    if n < 4 then
        return nil, nil
    end

    if not eps then
        local min_x, min_y, min_z = huge, huge, huge
        local max_x, max_y, max_z = -huge, -huge, -huge
        for i = 1, n do
            local v = points[i]
            local x, y, z = v[1], v[2], v[3]
            if x < min_x then min_x = x end
            if y < min_y then min_y = y end
            if z < min_z then min_z = z end
            if x > max_x then max_x = x end
            if y > max_y then max_y = y end
            if z > max_z then max_z = z end
        end
        local extent = max_x - min_x
        if max_y - min_y > extent then extent = max_y - min_y end
        if max_z - min_z > extent then extent = max_z - min_z end
        eps = extent * 1e-5
        if eps < 1e-9 then eps = 1e-9 end
    end

    local i0, i1, i2, i3 = seed_tetrahedron(points, n, eps)
    if not i0 then
        return nil, nil
    end

    local faces = {}
    local seeds = {
        { i0, i1, i2 }, { i0, i2, i3 }, { i0, i3, i1 }, { i1, i3, i2 },
    }
    for k = 1, 4 do
        local f = make_face(points, seeds[k][1], seeds[k][2], seeds[k][3])
        if not f then
            return nil, nil
        end
        faces[k] = f
    end

    local in_hull = {}
    in_hull[i0], in_hull[i1], in_hull[i2], in_hull[i3] = true, true, true, true
    -- Euler invariant for a simplicial convex polytope: faces == 2*vertices - 4
    -- it holds for the seed tetrahedron (4 == 2*4-4) and every accepted insertion is
    -- required to preserve it. That is not cosmetic: a horizon triangle that comes
    -- out degenerate would otherwise leave a HOLE in the hull, after which the
    -- horizon of the next point is no longer a single cycle and the face list grows
    -- geometrically (measured: the corpus decode never terminated). Rejecting the
    -- offending point instead keeps the surface closed and bounds faces at 2n-4
    local hull_verts = 4

    local visible = {}
    local edge_key, edge_a, edge_b = {}, {}, {}
    local fresh = {}

    for i = 1, n do
        if not in_hull[i] then
            local v = points[i]
            local vx, vy, vz = v[1], v[2], v[3]

            local vis_count = 0
            for fi = 1, #faces do
                local f = faces[fi]
                if f.nx * vx + f.ny * vy + f.nz * vz - f.d > eps then
                    vis_count = vis_count + 1
                    visible[vis_count] = fi
                    f.dead = true
                end
            end

            if vis_count > 0 then
                -- horizon = directed edges of the visible set whose opposite is not
                -- also visible. Marked in an open map keyed by (u,v)
                local ne = 0
                for k = 1, vis_count do
                    local f = faces[visible[k]]
                    local a, b, c = f[1], f[2], f[3]
                    ne = ne + 1; edge_a[ne] = a; edge_b[ne] = b
                    ne = ne + 1; edge_a[ne] = b; edge_b[ne] = c
                    ne = ne + 1; edge_a[ne] = c; edge_b[ne] = a
                end
                for k = 1, ne do
                    edge_key[edge_a[k] * 1048576 + edge_b[k]] = k
                end
                -- build the replacement cone BEFORE deleting anything, so a
                -- degenerate horizon edge cannot leave the hull with a hole
                local horizon, added = 0, 0
                for k = 1, ne do
                    local a, b = edge_a[k], edge_b[k]
                    if edge_key[b * 1048576 + a] == nil then
                        horizon = horizon + 1
                        local f = make_face(points, a, b, i)
                        if f then
                            added = added + 1
                            fresh[added] = f
                        end
                    end
                end
                for k = 1, ne do
                    edge_key[edge_a[k] * 1048576 + edge_b[k]] = nil
                end

                local kept = #faces - vis_count
                if added ~= horizon or added < 3 or kept + added ~= 2 * (hull_verts + 1) - 4 then
                    for k = 1, vis_count do
                        faces[visible[k]].dead = false
                    end
                    for k = 1, added do fresh[k] = nil end
                else
                    local live = 0
                    for fi = 1, #faces do
                        local f = faces[fi]
                        if not f.dead then
                            live = live + 1
                            faces[live] = f
                        end
                    end
                    for fi = #faces, live + 1, -1 do
                        faces[fi] = nil
                    end
                    for k = 1, added do
                        faces[live + k] = fresh[k]
                        fresh[k] = nil
                    end
                    hull_verts = hull_verts + 1
                    in_hull[i] = true
                end
            end
        end
    end

    local used, vertex_count = {}, 0
    local cx, cy, cz = 0, 0, 0
    local out = {}
    for fi = 1, #faces do
        local f = faces[fi]
        out[fi] = { f[1], f[2], f[3] }
        for corner = 1, 3 do
            local idx = f[corner]
            if not used[idx] then
                used[idx] = true
                vertex_count = vertex_count + 1
                local v = points[idx]
                cx, cy, cz = cx + v[1], cy + v[2], cz + v[3]
            end
        end
    end
    if vertex_count < 4 or #out < 4 then
        return nil, nil
    end

    return out, {
        vertex_count = vertex_count,
        face_count = #out,
        -- mean of the hull's own vertices: guaranteed strictly interior for a
        -- convex polytope, which is all the winding test needs
        centroid = { cx / vertex_count, cy / vertex_count, cz / vertex_count },
        -- Euler characteristic for a simplicial convex polytope. a violation means
        -- the incremental build hit a degeneracy it could not resolve
        euler_ok = (#out == 2 * vertex_count - 4),
    }
end

return convex_hull
