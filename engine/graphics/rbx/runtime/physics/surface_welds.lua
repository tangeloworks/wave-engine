-- legacy surface-weld fallback for classic maps, axis-aligned + rigid pairs only, off by default (physics_surface_welds)

local SurfaceWelds = {}

local abs = math.abs
local floor = math.floor

local FACE_EPS = 0.05   -- gap within this = touching (studs)
local AREA_EPS = 1e-3   -- min overlap, rejects edge/corner contact
local CELL = 32         -- grid cell, matches broadphase
local MAX_CELLS = 1024  -- more cells than this = oversized

-- imply motion, never weld
local MOTION_SURFACES = { Hinge = true, Motor = true, SteppingMotor = true }

-- blank surface = no joint
local function is_blank(s)
    return s == nil or s == "Smooth" or s == "SmoothNoOutlines" or s == "NoSurface"
end

-- conservative subset of rigid-weld surface pairs
function SurfaceWelds.compatible(a, b)
    if MOTION_SURFACES[a] or MOTION_SURFACES[b] then
        return false
    end
    if is_blank(a) or is_blank(b) then
        return false
    end
    if a == "Weld" or b == "Weld" then
        return true
    end
    if a == "Universal" or b == "Universal" then
        return true
    end
    if a == "Glue" and b == "Glue" then
        return true
    end
    if (a == "Studs" and b == "Inlet") or (a == "Inlet" and b == "Studs") then
        return true
    end
    return false
end

local function size_xyz(view)
    local s = view.Size
    local sx = s and (s.x or s.X) or 0
    local sy = s and (s.y or s.Y) or 0
    local sz = s and (s.z or s.Z) or 0
    return abs(sx), abs(sy), abs(sz)
end

local function pos_xyz(view)
    local p = view.Position
    if p == nil then
        return 0, 0, 0
    end
    return (p.x or p.X) or 0, (p.y or p.Y) or 0, (p.z or p.Z) or 0
end

-- missing cframeref = identity (rotated parts skipped by caller)
local function is_axis_aligned(view)
    local cf = view.CFrameRef
    if cf == nil then
        return true
    end
    local function near(v, t)
        return abs((v or 0) - t) <= 1e-4
    end
    return near(cf.r00, 1) and near(cf.r11, 1) and near(cf.r22, 1)
        and near(cf.r01, 0) and near(cf.r02, 0) and near(cf.r10, 0)
        and near(cf.r12, 0) and near(cf.r20, 0) and near(cf.r21, 0)
end

local function make_box(view)
    local px, py, pz = pos_xyz(view)
    local sx, sy, sz = size_xyz(view)
    local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    return {
        minx = px - hx, maxx = px + hx,
        miny = py - hy, maxy = py + hy,
        minz = pz - hz, maxz = pz + hz,
        sfc = view.surfaces or {},
        aa = is_axis_aligned(view),
        id = view.id,
    }
end

-- <=0 if disjoint
local function overlap(amin, amax, bmin, bmax)
    local lo = amin > bmin and amin or bmin
    local hi = amax < bmax and amax or bmax
    return hi - lo
end

-- axes: +x right/-x left, +y top/-y bottom, +z back/-z front
local function touching_faces(a, b)
    local sa, sb = a.sfc, b.sfc
    -- x faces
    if abs(a.maxx - b.minx) <= FACE_EPS
        and overlap(a.miny, a.maxy, b.miny, b.maxy) > AREA_EPS
        and overlap(a.minz, a.maxz, b.minz, b.maxz) > AREA_EPS then
        return sa.right, sb.left
    end
    if abs(a.minx - b.maxx) <= FACE_EPS
        and overlap(a.miny, a.maxy, b.miny, b.maxy) > AREA_EPS
        and overlap(a.minz, a.maxz, b.minz, b.maxz) > AREA_EPS then
        return sa.left, sb.right
    end
    -- y faces
    if abs(a.maxy - b.miny) <= FACE_EPS
        and overlap(a.minx, a.maxx, b.minx, b.maxx) > AREA_EPS
        and overlap(a.minz, a.maxz, b.minz, b.maxz) > AREA_EPS then
        return sa.top, sb.bottom
    end
    if abs(a.miny - b.maxy) <= FACE_EPS
        and overlap(a.minx, a.maxx, b.minx, b.maxx) > AREA_EPS
        and overlap(a.minz, a.maxz, b.minz, b.maxz) > AREA_EPS then
        return sa.bottom, sb.top
    end
    -- z faces
    if abs(a.maxz - b.minz) <= FACE_EPS
        and overlap(a.minx, a.maxx, b.minx, b.maxx) > AREA_EPS
        and overlap(a.miny, a.maxy, b.miny, b.maxy) > AREA_EPS then
        return sa.back, sb.front
    end
    if abs(a.minz - b.maxz) <= FACE_EPS
        and overlap(a.minx, a.maxx, b.minx, b.maxx) > AREA_EPS
        and overlap(a.miny, a.maxy, b.miny, b.maxy) > AREA_EPS then
        return sa.front, sb.back
    end
    return nil, nil
end

local function pair_weldable(a, b)
    if not a.aa or not b.aa then
        return false
    end
    local sa, sb = touching_faces(a, b)
    if sa == nil and sb == nil then
        return false
    end
    return SurfaceWelds.compatible(sa, sb)
end

-- returns (edges, added_count), edges may be nil, created on demand
function SurfaceWelds.append_edges(edges, views)
    local n = views and #views or 0
    if n < 2 then
        return edges, 0
    end

    local boxes = {}
    for i = 1, n do
        boxes[i] = make_box(views[i])
    end

    -- >max_cells boxes go oversized, checked vs everything (bounds memory for huge parts)
    local grid = {}
    local oversized = {}
    for i = 1, n do
        local box = boxes[i]
        local cx0, cx1 = floor(box.minx / CELL), floor(box.maxx / CELL)
        local cy0, cy1 = floor(box.miny / CELL), floor(box.maxy / CELL)
        local cz0, cz1 = floor(box.minz / CELL), floor(box.maxz / CELL)
        local cells = (cx1 - cx0 + 1) * (cy1 - cy0 + 1) * (cz1 - cz0 + 1)
        if cells > MAX_CELLS or cells < 1 then
            oversized[#oversized + 1] = i
        else
            for cx = cx0, cx1 do
                for cy = cy0, cy1 do
                    for cz = cz0, cz1 do
                        local key = cx .. ":" .. cy .. ":" .. cz
                        local bucket = grid[key]
                        if not bucket then
                            bucket = {}
                            grid[key] = bucket
                        end
                        bucket[#bucket + 1] = i
                    end
                end
            end
        end
    end

    edges = edges or {}
    local added = 0
    local seen = {}
    local stride = n + 1
    local function consider(i, j)
        if i == j then
            return
        end
        local lo, hi = i, j
        if lo > hi then
            lo, hi = hi, lo
        end
        local key = lo * stride + hi
        if seen[key] then
            return
        end
        seen[key] = true
        if pair_weldable(boxes[lo], boxes[hi]) then
            edges[#edges + 1] = { a = boxes[lo].id, b = boxes[hi].id }
            added = added + 1
        end
    end

    -- gridded vs gridded (shared cell)
    for _, bucket in pairs(grid) do
        local m = #bucket
        for x = 1, m do
            for y = x + 1, m do
                consider(bucket[x], bucket[y])
            end
        end
    end
    -- oversized vs everything
    for oi = 1, #oversized do
        local i = oversized[oi]
        for j = 1, n do
            consider(i, j)
        end
    end

    return edges, added
end

return SurfaceWelds
