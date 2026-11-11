-- spatial-hash broadphase, statics inserted once, dynamics upserted per step for active bodies only
-- dynamic aabb = com sphere (conservative), static aabb = exact member union

local Shape = runtime_require("physics/shape.lua")
local Integrate = runtime_require("physics/integrate.lua")

-- packed per-cell member AABBs for the raycast fast path (static_query_cell)
local ffi = require("ffi")

local Broadphase = {}
Broadphase.__index = Broadphase

local CELL        = 32   -- studs
local MAX_SPAN    = 8    -- cells per axis, dynamic body (8^3 = 512 cells)
-- statics hash per member once at bind so a big span is cheap, a huge floor needs full-footprint hashing or parts phase through
local STATIC_MAX_SPAN = 96   -- per-member, 96 cells ~ 3072 studs
local MAX_PER_CELL = 256  -- bodies per cell slot (dynamic/sleeping hashes)
-- statics get a far higher ceiling: with per-part singleton assemblies
-- (physics_anchor_loaded_parts) a dense 32-stud cell can legitimately hold
-- hundreds of static BODIES, and the old shared 256 cap SILENTLY dropped the
-- overflow -- those parts had no broadphase presence at all, so the player
-- phased straight through them. Queries AABB-reject members cheaply, so a big
-- static cell costs memory, not per-step CPU, the cap is only a runaway valve
local STATIC_MAX_PER_CELL = 8192
local STATIC_INCREMENTAL_RELOCATE_MIN_CELLS = 512

-- key + math helpers

-- packed int key, exact for |cell index|<4096 (~131k studs), string keys were the biggest GC source
local function hkey(cx, cy, cz)
    return ((cx + 4096) * 8192 + (cy + 4096)) * 8192 + (cz + 4096)
end

-- decode the packed static-hash key only on rare large-static range shifts
-- keeping the test here avoids allocating a 4k+ cell membership set just to
-- find the departing boundary strip
local function key_in_cell_range(k, ax, ay, az, bx, by, bz)
    local z = k % 8192
    local yz = (k - z) / 8192
    local y = yz % 8192
    local x = (yz - y) / 8192
    x, y, z = x - 4096, y - 4096, z - 4096
    return x >= ax and x <= bx and y >= ay and y <= by and z >= az and z <= bz
end

local function fl(v)
    return math.floor(v / CELL)
end

-- Numeric packed keys are one-to-one only in this inclusive digit range
-- Unrepresentable or uneconomical extents belong to a maintained overflow map;
-- a cap must select a complete fallback, never truncate spatial coverage
local function key_range(ax, ay, az, bx, by, bz)
    return ax >= -4096 and ay >= -4096 and az >= -4096
        and bx <= 4095 and by <= 4095 and bz <= 4095
        and ax <= bx and ay <= by and az <= bz
end

local function hash_range(ax, ay, az, bx, by, bz, limit)
    return key_range(ax, ay, az, bx, by, bz)
        and bx - ax <= limit and by - ay <= limit and bz - az <= limit
end

local function overlaps(a, lx, ly, lz, rx, ry, rz)
    return a and a[4] >= lx and a[1] <= rx and a[5] >= ly
        and a[2] <= ry and a[6] >= lz and a[3] <= rz
end

local function max3(a, b, c)
    if a >= b then
        return a >= c and a or c
    else
        return b >= c and b or c
    end
end

local function radius_bound(view, hx, hy, hz)
    local kind = Shape.kind_of(view)
    if kind == "cylinder" then
        -- Finite cylinder along X, circular section in Y/Z
        local r = math.min(hy, hz)
        return math.sqrt(hx * hx + r * r)
    end
    if kind == "ball" then return max3(hx, hy, hz) end
    -- Boxes and convex parts fit their corner circumradius at every member/body
    -- rotation. max(half-extents) under-covered rotating compound corners
    return math.sqrt(hx * hx + hy * hy + hz * hz)
end

-- aabb builders

-- conservative radius = max com-to-corner dist (offsets post-bind, root half-extents
-- pre-bind). Constant for a body's lifetime EXCEPT that binding fills local_offsets
-- after the body exists, so the cache keys on the offsets table identity + length;
-- Size changes rebuild bodies, which drops the cache with them
local function dyn_radius(body)
    local offs = body.local_offsets
    local n = offs and #offs or 0
    local r = body._bp_radius
    if r and body._bp_radius_key == offs and body._bp_radius_n == n then
        return r
    end
    r = 0
    if n > 0 then
        for i = 1, n do
            local o = offs[i]
            if o and o.view then
                local hx, hy, hz = Shape.half_extents(o.view)
                local d = math.sqrt(o.lx * o.lx + o.ly * o.ly + o.lz * o.lz) + radius_bound(o.view, hx, hy, hz)
                if d > r then r = d end
            end
        end
    end
    if r == 0 then
        local asm  = body.assembly
        local root = asm and asm.root_part
        if root then
            local hx, hy, hz = Shape.half_extents(root)
            r = radius_bound(root, hx, hy, hz)
        else
            r = 2
        end
    end
    body._bp_radius, body._bp_radius_key, body._bp_radius_n = r, offs, n
    return r
end

-- fatten the tight box a hair: resting contacts sit at ~slop penetration, and
-- wake_sleepers_overlapping/manifold pruning tolerate zero-gap touching better with it
local BP_TIGHT_MARGIN = 0.05

-- cache singleton extents in body space, Size/topology edits invalidate the
-- same key as dyn_radius. the caller projects these by the live body rotation
local function dyn_tight(body)
    local offs = body.local_offsets
    local n = offs and #offs or 0
    if body._bp_tight_key == offs and body._bp_tight_n == n then
        return body._bp_tight
    end
    local tight = false
    body._bp_uniform_ball = false
    if n == 1 then
        local o = offs[1]
        if o and o.view then
            local hx, hy, hz = Shape.half_extents(o.view)
            -- Uniform spheres are independent of BOTH body and member rotation
            -- other singleton shapes retain the exact member-identity gate
            local uniform_ball = Shape.kind_of(o.view) == "ball" and hx == hy and hy == hz
            if uniform_ball or ((o.qx or 0)==0 and (o.qy or 0)==0 and (o.qz or 0)==0) then
                body._bp_uniform_ball = uniform_ball
                body._bp_thx = hx + BP_TIGHT_MARGIN
                body._bp_thy = hy + BP_TIGHT_MARGIN
                body._bp_thz = hz + BP_TIGHT_MARGIN
                body._bp_tlx, body._bp_tly, body._bp_tlz = o.lx or 0, o.ly or 0, o.lz or 0
                tight = true
            end
        end
    end
    body._bp_tight, body._bp_tight_key, body._bp_tight_n = tight, offs, n
    return tight
end

-- Rotating a singleton does not require falling back to its circumradius
-- |R|*half-extents covers the rotated box tightly, avoiding extra floor/wall
-- candidates when long props wake. Compounds keep the conservative sphere
local function dyn_aabb(body)
    local cx, cy, cz = body.com_x, body.com_y, body.com_z
    if dyn_tight(body) then
        local hx,hy,hz=body._bp_thx,body._bp_thy,body._bp_thz
        local lx,ly,lz=body._bp_tlx,body._bp_tly,body._bp_tlz
        if (body.qx or 0)~=0 or (body.qy or 0)~=0 or (body.qz or 0)~=0 then
            local a,b,c,d,e,f,g,h,i=Integrate.quat_to_matrix(body.qw,body.qx,body.qy,body.qz)
            lx,ly,lz=a*lx+b*ly+c*lz,d*lx+e*ly+f*lz,g*lx+h*ly+i*lz
            if not body._bp_uniform_ball then
                local abs=math.abs
                hx,hy,hz=abs(a)*hx+abs(b)*hy+abs(c)*hz,
                    abs(d)*hx+abs(e)*hy+abs(f)*hz,abs(g)*hx+abs(h)*hy+abs(i)*hz
            end
        end
        local mx,my,mz=cx+lx,cy+ly,cz+lz
        return mx-hx,my-hy,mz-hz,mx+hx,my+hy,mz+hz
    end
    local r = dyn_radius(body)
    return cx - r, cy - r, cz - r, cx + r, cy + r, cz + r
end

-- world-axis half extents: |R| * local halves (obb -> aabb projection, same math
-- as manifold.lua's member entries). local halves alone under-cover ROTATED parts:
-- a 45-degree 20-stud wall hashed by its local extents misses cells its world
-- footprint actually occupies -> candidate misses -> phase-through
local function world_half_extents(v)
    local hx, hy, hz = Shape.half_extents(v)
    local cf = v and v.CFrameRef or nil
    local r00 = cf and cf.r00 or nil
    if r00 == nil then
        return hx, hy, hz
    end
    local abs = math.abs
    return abs(r00) * hx + abs(cf.r01 or 0) * hy + abs(cf.r02 or 0) * hz,
        abs(cf.r10 or 0) * hx + abs(cf.r11 or 1) * hy + abs(cf.r12 or 0) * hz,
        abs(cf.r20 or 0) * hx + abs(cf.r21 or 0) * hy + abs(cf.r22 or 1) * hz
end

-- exact member-union, members never move
local function sta_aabb(body)
    local asm  = body.assembly
    local mems = asm and asm.parts or {}
    local lx, ly, lz =  math.huge,  math.huge,  math.huge
    local rx, ry, rz = -math.huge, -math.huge, -math.huge
    for i = 1, #mems do
        local v   = mems[i]
        local pos = v.Position or {}
        local px  = pos.x or pos.X or 0
        local py  = pos.y or pos.Y or 0
        local pz  = pos.z or pos.Z or 0
        local hx, hy, hz = world_half_extents(v)
        if px - hx < lx then lx = px - hx end
        if py - hy < ly then ly = py - hy end
        if pz - hz < lz then lz = pz - hz end
        if px + hx > rx then rx = px + hx end
        if py + hy > ry then ry = py + hy end
        if pz + hz > rz then rz = pz + hz end
    end
    if lx == math.huge then
        return 0, 0, 0, 0, 0, 0
    end
    return lx, ly, lz, rx, ry, rz
end

-- cell-level insert / remove

local function cells_remove(hash, proxy, body_id)
    local cells = proxy.cells
    for i = 1, #cells do
        local c = hash[cells[i]]
        if c then
            for j = 1, #c do
                if c[j].id == body_id then
                    local last = #c
                    if j < last then c[j] = c[last] end
                    c[last] = nil
                    break
                end
            end
            if #c == 0 then hash[cells[i]] = nil end
        end
        cells[i] = nil
    end
end

-- insert into an already-clamped integer cell range, returns upsert count
local function cells_insert_range(hash, proxy, body, ax, ay, az, bx, by, bz)
    local cells = proxy.cells
    local n, upserts = 0, 0
    for cx = ax, bx do
        for cy = ay, by do
            for cz = az, bz do
                local k = hkey(cx, cy, cz)
                local cell = hash[k]
                if not cell then
                    cell = {}
                    hash[k] = cell
                end
                if #cell < MAX_PER_CELL then
                    cell[#cell + 1] = body
                    n = n + 1
                    cells[n] = k
                    upserts = upserts + 1
                else
                    -- Partial hashing is harmless only with complete overflow ownership
                    proxy.overflow = true
                end
            end
        end
    end
    for i = n + 1, #cells do cells[i] = nil end  -- trim stale tail
    return upserts
end

-- records cells in proxy.cells for fast removal, returns upsert count
local function cells_insert(hash, proxy, body, lx, ly, lz, rx, ry, rz)
    local ax, ay, az = fl(lx), fl(ly), fl(lz)
    local bx, by, bz = fl(rx), fl(ry), fl(rz)
    if not hash_range(ax, ay, az, bx, by, bz, MAX_SPAN) then
        proxy.overflow = true
        return 0
    end
    return cells_insert_range(hash, proxy, body, ax, ay, az, bx, by, bz)
end

-- constructor

function Broadphase.new()
    return setmetatable({
        static_hash     = {},
        dynamic_hash    = {},
        sleeping_hash   = {},   -- resting colliders
        -- [hkey] -> {n, boxes=double[6n], views={member views}} raycast slab arrays,
        -- built lazily per visited cell by static_query_cell, invalidated per cell
        -- on insert_static/remove_static and wholesale on reset_statics
        _static_query_cells = {},
        static_proxies  = {},   -- [id] -> {cells={}, aabb={lx,ly,lz,rx,ry,rz}}
        dynamic_proxies = {},   -- [id] -> {cells={}, aabb={lx,ly,lz,rx,ry,rz}}
        sleeping_proxies = {},  -- [id] -> {cells={}, aabb={...}}, rebuilt on sleep/wake
        static_overflow = {}, dynamic_overflow = {}, sleeping_overflow = {},
        -- cumulative (not reset per step)
        static_proxy_count  = 0,
        dynamic_proxy_count = 0,
        sleeping_proxy_count = 0,
        -- per-step (reset by reset_step_counters)
        dirty_proxy_count     = 0,
        proxy_upsert_count    = 0,
        candidate_check_count = 0,
        broadphase_pair_count = 0,
    }, Broadphase)
end

-- static proxy management

-- call before re-inserting after a topology change
function Broadphase:reset_statics()
    self.static_hash    = {}
    self.static_overflow = {}
    self.static_proxies = {}
    self.static_proxy_count = 0
    self._static_query_cells = {}   -- every cached slab array is stale now
end

-- idempotent, re-insert of same id is a no-op
function Broadphase:insert_static(asm)
    local body = asm and asm.body
    if not body or not body.is_static then return end
    local id = asm.id
    if self.static_proxies[id] then return end
    local proxy = { cells = {}, body = body }
    self.static_proxies[id] = proxy
    body._bp_proxy = proxy
    local lx, ly, lz, rx, ry, rz = sta_aabb(body)
    proxy.aabb = { lx, ly, lz, rx, ry, rz }  -- coarse union, used by the support query

    -- hash deduped member cells, not the union aabb (union leaves a big floor mostly unhashed), runs once
    local parts = (body.assembly and body.assembly.parts) or nil
    local hash = self.static_hash
    local cells = proxy.cells
    local n, upserts = 0, 0
    if parts and #parts > 0 then
        local cellset = {}
        -- per-member aabbs: union proxy.aabb is useless for support (airborne part inside union reads supported)
        local member_aabbs = {}
        for i = 1, #parts do
            local v = parts[i]
            local p = v.Position or {}
            local px = (p.x or p.X) or 0
            local py = (p.y or p.Y) or 0
            local pz = (p.z or p.Z) or 0
            -- ROTATED world extents: local halves under-cover rotated parts (missed
            -- cells + wrong member aabbs = support/CCD/candidate misses)
            local hx, hy, hz = world_half_extents(v)
            -- [7] = member view, so ccd sweep can read a live CanCollide
            member_aabbs[i] = { px - hx, py - hy, pz - hz, px + hx, py + hy, pz + hz, v }
            local ax, ay, az = fl(px - hx), fl(py - hy), fl(pz - hz)
            local bx, by, bz = fl(px + hx), fl(py + hy), fl(pz + hz)
            local ma = member_aabbs[i]
            ma.overflow = not hash_range(ax, ay, az, bx, by, bz, STATIC_MAX_SPAN)
            if ma.overflow then proxy.overflow = true end
            if not ma.overflow then
            for cx = ax, bx do
                for cy = ay, by do
                    for cz = az, bz do
                        cellset[hkey(cx, cy, cz)] = true
                    end
                end
            end
            end
        end
        local qcells = self._static_query_cells
        for k in pairs(cellset) do
            -- membership changed: any cached raycast slab array for this cell is stale
            if qcells then qcells[k] = nil end
            local cell = hash[k]
            if not cell then cell = {}; hash[k] = cell end
            if #cell < STATIC_MAX_PER_CELL then
                cell[#cell + 1] = body
                n = n + 1
                cells[n] = k
                upserts = upserts + 1
            else
                -- the body remains discoverable through its overflow proxy
                proxy.overflow = true
                self.static_cell_overflow_count = (self.static_cell_overflow_count or 0) + 1
                if not self._static_overflow_warned then
                    self._static_overflow_warned = true
                    print(("[physics] static broadphase cell full (limit %d): body %s "
                        .. "kept in the overflow registry"):format(STATIC_MAX_PER_CELL, tostring(id)))
                end
            end
        end
        proxy.members = member_aabbs
    else
        upserts = cells_insert(hash, proxy, body, lx, ly, lz, rx, ry, rz)
        -- same staleness rule as the member path, cells_insert recorded the touched keys
        local qcells = self._static_query_cells
        if qcells then
            local pc = proxy.cells
            for i = 1, #pc do qcells[pc[i]] = nil end
        end
    end
    if proxy.overflow then self.static_overflow[id] = proxy end
    self.proxy_upsert_count  = self.proxy_upsert_count + upserts
    self.static_proxy_count  = self.static_proxy_count + 1
end

-- dynamic proxy management

-- call after a topology change (set_assemblies)
function Broadphase:reset_dynamics()
    self.dynamic_hash    = {}
    self.dynamic_overflow = {}
    self.dynamic_proxies = {}
    self.dynamic_proxy_count = 0
end

-- each step for every active body, sleepers skipped (not in active_bodies)
-- the occupied cell range is cached on the proxy: while a body moves inside the same
-- cells (the common case at 32-stud cells) only the AABB numbers are refreshed and the
-- remove+reinsert (two linear cell scans + table churn per body per substep) is skipped
function Broadphase:upsert_dynamic(body)
    if body.is_static then return end
    local id    = body.id
    local proxy = self.dynamic_proxies[id]
    local lx, ly, lz, rx, ry, rz = dyn_aabb(body)
    local ax, ay, az = fl(lx), fl(ly), fl(lz)
    local bx, by, bz = fl(rx), fl(ry), fl(rz)
    local hashable = hash_range(ax, ay, az, bx, by, bz, MAX_SPAN)
    if proxy then
        local aabb = proxy.aabb
        -- in place: a fresh 6-slot table per body per substep adds up
        aabb[1], aabb[2], aabb[3], aabb[4], aabb[5], aabb[6] = lx, ly, lz, rx, ry, rz
        if proxy.cax == ax and proxy.cay == ay and proxy.caz == az
        and proxy.cbx == bx and proxy.cby == by and proxy.cbz == bz then
            self.dirty_proxy_count = self.dirty_proxy_count + 1
            self.proxy_range_skip_count = (self.proxy_range_skip_count or 0) + 1
            return
        end
        cells_remove(self.dynamic_hash, proxy, id)
        self.dynamic_overflow[id] = nil
    else
        proxy = { cells = {}, body = body, aabb = { lx, ly, lz, rx, ry, rz } }
        self.dynamic_proxies[id] = proxy
        self.dynamic_proxy_count = self.dynamic_proxy_count + 1
    end
    proxy.cax, proxy.cay, proxy.caz = ax, ay, az
    proxy.cbx, proxy.cby, proxy.cbz = bx, by, bz
    body._bp_proxy = proxy
    proxy.overflow = not hashable
    local u = hashable and cells_insert_range(self.dynamic_hash, proxy, body, ax, ay, az, bx, by, bz) or 0
    if proxy.overflow then self.dynamic_overflow[id] = proxy end
    self.proxy_upsert_count = self.proxy_upsert_count + u
    self.dirty_proxy_count  = self.dirty_proxy_count + 1
end

-- sleeper keeps a rest-pose proxy so awake bodies can contact/wake it, sleepers never query, so a resting pile is free

function Broadphase:reset_sleeping()
    self.sleeping_hash     = {}
    self.sleeping_overflow = {}
    self.sleeping_proxies  = {}
    self.sleeping_proxy_count = 0
end

-- from its current rest pose, idempotent
function Broadphase:insert_sleeping(body)
    if body.is_static then return end
    local id = body.id
    if self.sleeping_proxies[id] then return end
    local proxy = { cells = {}, body = body }
    self.sleeping_proxies[id] = proxy
    body._bp_proxy = proxy
    local lx, ly, lz, rx, ry, rz = dyn_aabb(body)
    proxy.aabb = { lx, ly, lz, rx, ry, rz }
    local u = cells_insert(self.sleeping_hash, proxy, body, lx, ly, lz, rx, ry, rz)
    if proxy.overflow then self.sleeping_overflow[id] = proxy end
    self.proxy_upsert_count   = self.proxy_upsert_count + u
    self.sleeping_proxy_count = self.sleeping_proxy_count + 1
end

-- call when the body wakes, idempotent
function Broadphase:remove_sleeping(id)
    local proxy = self.sleeping_proxies[id]
    if not proxy then return end
    local cells = proxy.cells
    for i = 1, #cells do
        local c = self.sleeping_hash[cells[i]]
        if c then
            for j = 1, #c do
                if c[j].id == id then
                    local last = #c
                    if j < last then c[j] = c[last] end
                    c[last] = nil
                    break
                end
            end
            if #c == 0 then self.sleeping_hash[cells[i]] = nil end
        end
        cells[i] = nil
    end
    self.sleeping_overflow[id] = nil
    self.sleeping_proxies[id] = nil
    self.sleeping_proxy_count = math.max(0, self.sleeping_proxy_count - 1)
end

-- in-place anchored flip: part released to dynamic w/o a topology rebuild, idempotent
function Broadphase:remove_static(id)
    local proxy = self.static_proxies[id]
    if not proxy then return end
    local qcells = self._static_query_cells
    local cells = proxy.cells
    for i = 1, #cells do
        -- membership changed: drop the cached raycast slab array for this cell
        if qcells then qcells[cells[i]] = nil end
        local c = self.static_hash[cells[i]]
        if c then
            for j = 1, #c do
                if c[j].assembly and c[j].assembly.id == id then
                    local last = #c
                    if j < last then c[j] = c[last] end
                    c[last] = nil
                    break
                end
            end
            if #c == 0 then self.static_hash[cells[i]] = nil end
        end
        cells[i] = nil
    end
    self.static_overflow[id] = nil
    self.static_proxies[id] = nil
    self.static_proxy_count = math.max(0, self.static_proxy_count - 1)
end

-- moves one existing static singleton without rewriting the spatial hash when its
-- full member cell span is unchanged. Query slabs cache AABB lanes, so their
-- affected cells are still invalidated even though membership remains stable
function Broadphase:refresh_static_singleton(asm)
    local body = asm and asm.body
    local id = asm and asm.id
    local parts = asm and asm.parts
    local proxy = id and self.static_proxies[id]
    local members = proxy and proxy.members
    local member = members and #members == 1 and members[1]
    local view = parts and #parts == 1 and parts[1]
    if not body or not body.is_static or not proxy or proxy.body ~= body
        or proxy.overflow or not member or member.overflow or not view
        or member[7] ~= view then
        return false
    end
    local position = view.Position or {}
    local px = (position.x or position.X) or 0
    local py = (position.y or position.Y) or 0
    local pz = (position.z or position.Z) or 0
    local hx, hy, hz = world_half_extents(view)
    local lx, ly, lz = px - hx, py - hy, pz - hz
    local rx, ry, rz = px + hx, py + hy, pz + hz
    local ax, ay, az = fl(lx), fl(ly), fl(lz)
    local bx, by, bz = fl(rx), fl(ry), fl(rz)
    if not hash_range(ax, ay, az, bx, by, bz, STATIC_MAX_SPAN) then return false end
    local oldax, olday, oldaz = fl(member[1]), fl(member[2]), fl(member[3])
    local oldbx, oldby, oldbz = fl(member[4]), fl(member[5]), fl(member[6])
    local old_cells = (oldbx - oldax + 1) * (oldby - olday + 1) * (oldbz - oldaz + 1)
    local new_cells = (bx - ax + 1) * (by - ay + 1) * (bz - az + 1)
    local cells = proxy.cells
    local aabb = proxy.aabb
    if #cells ~= old_cells or type(aabb) ~= "table" then return false end

    if ax == oldax and ay == olday and az == oldaz
        and bx == oldbx and by == oldby and bz == oldbz then
        if #cells ~= new_cells then return false end
        aabb[1], aabb[2], aabb[3], aabb[4], aabb[5], aabb[6] = lx, ly, lz, rx, ry, rz
        member[1], member[2], member[3], member[4], member[5], member[6], member[7] =
            lx, ly, lz, rx, ry, rz, view
        local qcells = self._static_query_cells
        if qcells then
            for index = 1, #cells do qcells[cells[index]] = nil end
        end
        self.static_same_cell_refresh_count = (self.static_same_cell_refresh_count or 0) + 1
        return true
    end

    -- a one-cell water-like slide previously did a full 4k+ removal/rebuild
    -- retain the conservative fallback unless most of a sufficiently large
    -- static footprint overlaps, every entering cell has capacity, and every
    -- departing cell still contains this exact body
    local ix0, iy0, iz0 = math.max(ax, oldax), math.max(ay, olday), math.max(az, oldaz)
    local ix1, iy1, iz1 = math.min(bx, oldbx), math.min(by, oldby), math.min(bz, oldbz)
    local overlap = ix0 <= ix1 and iy0 <= iy1 and iz0 <= iz1
        and (ix1 - ix0 + 1) * (iy1 - iy0 + 1) * (iz1 - iz0 + 1) or 0
    local changed = old_cells + new_cells - overlap * 2
    if old_cells < STATIC_INCREMENTAL_RELOCATE_MIN_CELLS
        or new_cells < STATIC_INCREMENTAL_RELOCATE_MIN_CELLS
        or overlap == 0 or changed * 2 > old_cells + new_cells then
        return false
    end

    local hash = self.static_hash
    for cx = ax, bx do
        for cy = ay, by do
            for cz = az, bz do
                if cx < oldax or cx > oldbx or cy < olday or cy > oldby or cz < oldaz or cz > oldbz then
                    local existing = hash[hkey(cx, cy, cz)]
                    if existing and #existing >= STATIC_MAX_PER_CELL then return false end
                end
            end
        end
    end
    for index = 1, #cells do
        local key = cells[index]
        if not key_in_cell_range(key, ax, ay, az, bx, by, bz) then
            local cell, found = hash[key], false
            if cell then
                for i = 1, #cell do
                    if cell[i] == body then found = true; break end
                end
            end
            if not found then return false end
        end
    end

    local qcells = self._static_query_cells
    for index = 1, #cells do
        local key = cells[index]
        -- every retained overlap cached the old member AABB, so it must be
        -- dropped as well as the cells whose membership changes
        if qcells then qcells[key] = nil end
        if not key_in_cell_range(key, ax, ay, az, bx, by, bz) then
            local cell = hash[key]
            for i = 1, #cell do
                if cell[i] == body then
                    local last = #cell
                    if i < last then cell[i] = cell[last] end
                    cell[last] = nil
                    break
                end
            end
            if #cell == 0 then hash[key] = nil end
        end
    end

    local count, added = 0, 0
    for cx = ax, bx do
        for cy = ay, by do
            for cz = az, bz do
                local key = hkey(cx, cy, cz)
                count = count + 1
                cells[count] = key
                if cx < oldax or cx > oldbx or cy < olday or cy > oldby or cz < oldaz or cz > oldbz then
                    if qcells then qcells[key] = nil end
                    local cell = hash[key]
                    if not cell then cell = {}; hash[key] = cell end
                    cell[#cell + 1] = body
                    added = added + 1
                end
            end
        end
    end
    for index = count + 1, old_cells do cells[index] = nil end
    aabb[1], aabb[2], aabb[3], aabb[4], aabb[5], aabb[6] = lx, ly, lz, rx, ry, rz
    member[1], member[2], member[3], member[4], member[5], member[6], member[7] =
        lx, ly, lz, rx, ry, rz, view
    self.proxy_upsert_count = self.proxy_upsert_count + added
    self.static_incremental_relocation_count = (self.static_incremental_relocation_count or 0) + 1
    self.static_incremental_relocation_added = (self.static_incremental_relocation_added or 0) + added
    self.static_incremental_relocation_removed = (self.static_incremental_relocation_removed or 0) + (old_cells - overlap)
    return true
end
-- call when a body is destroyed or goes static
function Broadphase:remove_dynamic(id)
    local proxy = self.dynamic_proxies[id]
    if not proxy then return end
    local cells = proxy.cells
    for i = 1, #cells do
        local c = self.dynamic_hash[cells[i]]
        if c then
            for j = 1, #c do
                if c[j].id == id then
                    local last = #c
                    if j < last then c[j] = c[last] end
                    c[last] = nil
                    break
                end
            end
            if #c == 0 then self.dynamic_hash[cells[i]] = nil end
        end
        cells[i] = nil
    end
    self.dynamic_overflow[id] = nil
    self.dynamic_proxies[id] = nil
    self.dynamic_proxy_count = math.max(0, self.dynamic_proxy_count - 1)
end

-- the pair tuple pool deliberately survives steps to avoid allocations. Destruction is
-- rare, so scan it once and release references to the removed body, current pairs are
-- compacted by World before this is called
function Broadphase:forget_body(body)
    if body == nil then return end
    local pool = self._pair_tuple_pool
    if not pool then return end
    for i = 1, #pool do
        local pair = pool[i]
        if pair and (pair[1] == body or pair[2] == body) then
            pair[1], pair[2] = nil, nil
        end
    end
end

-- read-only collider statistics

-- cb(kind, id, aabb), kind = "static"/"dynamic"/"sleeping", aabb is read-only
function Broadphase:for_each_proxy(cb)
    for id, proxy in pairs(self.static_proxies) do cb("static", id, proxy.aabb) end
    for id, proxy in pairs(self.dynamic_proxies) do cb("dynamic", id, proxy.aabb) end
    for id, proxy in pairs(self.sleeping_proxies) do cb("sleeping", id, proxy.aabb) end
end

-- counts the maps directly, so its exact even if a counter drifts
function Broadphase:proxy_count()
    local n = 0
    for _ in pairs(self.static_proxies) do n = n + 1 end
    for _ in pairs(self.dynamic_proxies) do n = n + 1 end
    for _ in pairs(self.sleeping_proxies) do n = n + 1 end
    return n
end

-- pair query

-- module-level so test_pair isnt a closure realloc'd per body/substep (closures abort jit traces too), single-threaded
local tp_self, tp_bp, tp_seen, tp_epoch, tp_out
local tp_lx, tp_ly, tp_lz, tp_rx, tp_ry, tp_rz
local tp_self_id

-- canonical pair key min*2^26+max, exact + alloc-free (string keys were 2nd-biggest GC source)
local PAIR_SHIFT = 67108864 -- 2^26

-- visit order matters for cost: the AABB reject runs FIRST off the proxy cached on the
-- body (body._bp_proxy, one field read instead of up to three hash-map lookups), and the
-- seen-map is only touched for overlapping pairs. non-overlapping pairs sharing several
-- cells get re-tested per cell, but 6 numeric compares beat stamping a big hash table
local function test_pair(other)
    local oid = other.id
    if oid == tp_self_id then return end
    local bp = tp_bp
    bp.candidate_check_count = bp.candidate_check_count + 1
    local op = other._bp_proxy
    if not op then return end
    local oa = op.aabb
    if not oa then return end
    if tp_lx > oa[4] or tp_rx < oa[1]
    or tp_ly > oa[5] or tp_ry < oa[2]
    or tp_lz > oa[6] or tp_rz < oa[3] then return end
    local pk
    if tp_self_id < oid then
        pk = tp_self_id * PAIR_SHIFT + oid
    else
        pk = oid * PAIR_SHIFT + tp_self_id
    end
    if tp_seen[pk] == tp_epoch then return end
    tp_seen[pk] = tp_epoch
    -- pooled, reused across substeps, consumer reads synchronously, never retains
    local used = bp._pair_tuple_used + 1
    bp._pair_tuple_used = used
    local pool = bp._pair_tuple_pool
    local tuple = pool[used]
    if not tuple then
        tuple = {}
        pool[used] = tuple
    end
    tuple[1], tuple[2] = tp_self, other
    tp_out[#tp_out + 1] = tuple
    bp.broadphase_pair_count = bp.broadphase_pair_count + 1
end

-- Dynamic-hash variant: every body in the dynamic hash is active and therefore also
-- queries, so a dynamic-dynamic pair is emitted only by the lower id -- the higher-id
-- visit exits on one compare instead of paying pair-key + seen-map work
local function test_pair_dyn(other)
    local oid = other.id
    if oid <= tp_self_id then return end
    local bp = tp_bp
    bp.candidate_check_count = bp.candidate_check_count + 1
    local op = other._bp_proxy
    if not op then return end
    local oa = op.aabb
    if not oa then return end
    if tp_lx > oa[4] or tp_rx < oa[1]
    or tp_ly > oa[5] or tp_ry < oa[2]
    or tp_lz > oa[6] or tp_rz < oa[3] then return end
    local pk = tp_self_id * PAIR_SHIFT + oid
    if tp_seen[pk] == tp_epoch then return end
    tp_seen[pk] = tp_epoch
    local used = bp._pair_tuple_used + 1
    bp._pair_tuple_used = used
    local pool = bp._pair_tuple_pool
    local tuple = pool[used]
    if not tuple then
        tuple = {}
        pool[used] = tuple
    end
    tuple[1], tuple[2] = tp_self, other
    tp_out[#tp_out + 1] = tuple
    bp.broadphase_pair_count = bp.broadphase_pair_count + 1
end

-- one active body vs the cells its aabb covers, epoch-stamped dedup, pooled tuples out
function Broadphase:query_candidates(body, out_pairs, seen, epoch)
    local proxy = self.dynamic_proxies[body.id]
    if not proxy or not proxy.aabb then return end
    local aabb = proxy.aabb
    local lx, ly, lz = aabb[1], aabb[2], aabb[3]
    local rx, ry, rz = aabb[4], aabb[5], aabb[6]

    -- upsert_dynamic computed the complete range for the same AABB
    local ax, ay, az = proxy.cax, proxy.cay, proxy.caz
    local bx, by, bz = proxy.cbx, proxy.cby, proxy.cbz
    if ax == nil then
        ax, ay, az = fl(lx), fl(ly), fl(lz)
        bx, by, bz = fl(rx), fl(ry), fl(rz)

    end
    local range_clamped = not hash_range(ax, ay, az, bx, by, bz, MAX_SPAN)

    self._pair_tuple_pool = self._pair_tuple_pool or {}
    if self._pair_tuple_used == nil then self._pair_tuple_used = 0 end

    tp_self, tp_bp, tp_seen, tp_out = body, self, seen, out_pairs
    tp_epoch = epoch or true
    tp_self_id = body.id
    tp_lx, tp_ly, tp_lz, tp_rx, tp_ry, tp_rz = lx, ly, lz, rx, ry, rz

    local static_hash   = self.static_hash
    local dynamic_hash  = self.dynamic_hash
    local sleeping_hash = self.sleeping_hash

    -- Complete bounds scan only for unhashable movers, ordinary movers visit the
    -- maintained overflow maps once, then keep the existing packed-cell path
    local sm = range_clamped and self.static_proxies or self.static_overflow
    local dm = range_clamped and self.dynamic_proxies or self.dynamic_overflow
    local lm = range_clamped and self.sleeping_proxies or self.sleeping_overflow
    for _, op in pairs(sm) do test_pair(op.body) end
    for _, op in pairs(dm) do test_pair_dyn(op.body) end
    for _, op in pairs(lm) do test_pair(op.body) end
    if not range_clamped then
    for cx = ax, bx do
        for cy = ay, by do
            for cz = az, bz do
                local k  = hkey(cx, cy, cz)
                local sc = static_hash[k]
                if sc then
                    -- member-box FFI prefilter reusing the ray path's packed cell
                    -- arrays: dense singleton-static cells hold hundreds of bodies,
                    -- and the flat double[] overlap loop compiles tight, so
                    -- test_pair (seen-map + emission) runs only on true overlaps
                    -- Member boxes are a strict subset of the old per-body
                    -- union-AABB test -- we emit fewer already-doomed pairs, and
                    -- identical contacts (a body only ever contacts via a member) --
                    -- EXCEPT under a clamped range (see range_clamped above), where
                    -- the legacy union scan must handle out-of-range members
                    local rec = not range_clamped and self:static_query_cell(cx, cy, cz) or nil
                    if rec then
                        local boxes = rec.boxes
                        local bodies = rec.bodies
                        for i = 0, rec.n - 1 do
                            local b6 = i * 6
                            if boxes[b6] <= rx and boxes[b6 + 3] >= lx
                                and boxes[b6 + 1] <= ry and boxes[b6 + 4] >= ly
                                and boxes[b6 + 2] <= rz and boxes[b6 + 5] >= lz then
                                test_pair(bodies[i + 1])
                            end
                        end
                    else
                        for i = 1, #sc do test_pair(sc[i]) end
                    end
                end
                local dc = dynamic_hash[k]
                if dc then
                    for i = 1, #dc do test_pair_dyn(dc[i]) end
                end
                local lc = sleeping_hash[k]
                if lc then
                    for i = 1, #lc do test_pair(lc[i]) end
                end
            end
        end
    end
    end
    tp_self, tp_bp, tp_seen, tp_out = nil, nil, nil, nil
end

-- support query (one-time bind pass)

-- exact, not the conservative dyn_aabb sphere: an over-tall sphere misclassifies a resting plate as airborne
function Broadphase:body_aabb(body)
    return sta_aabb(body)
end

-- anything under the body? "static"/"sleeping"/nil (airborne), static wins
function Broadphase:query_region_support(lx, ly, lz, rx, ry, rz, exclude_id)
    local ax, ay, az = fl(lx), fl(ly), fl(lz)
    local bx, by, bz = fl(rx), fl(ry), fl(rz)
    local hashable = hash_range(ax, ay, az, bx, by, bz, MAX_SPAN)
    local static_hash      = self.static_hash
    local sleeping_hash    = self.sleeping_hash
    local static_proxies   = self.static_proxies
    local sleeping_proxies = self.sleeping_proxies
    local found_sleeping = false
    -- a big static hashes into many cells, test its members once
    local tested = {}
    local sm = hashable and self.static_overflow or static_proxies
    for id, op in pairs(sm) do
        tested[id] = true
        local ms = op.members
        if ms then
            for i = 1, #ms do
                local m = ms[i]
                if m[5] >= ly and m[5] <= ry and lx <= m[4] and rx >= m[1]
                    and lz <= m[6] and rz >= m[3] then return "static" end
            end
        else
            local a = op.aabb
            if a and a[5] >= ly and a[5] <= ry and lx <= a[4] and rx >= a[1]
                and lz <= a[6] and rz >= a[3] then return "static" end
        end
    end
    local lm = hashable and self.sleeping_overflow or sleeping_proxies
    for id, op in pairs(lm) do
        if id ~= exclude_id and overlaps(op.aabb, lx, ly, lz, rx, ry, rz) then found_sleeping = true end
    end
    if not hashable then return found_sleeping and "sleeping" or nil end
    for cx = ax, bx do
        for cy = ay, by do
            for cz = az, bz do
                local k = hkey(cx, cy, cz)
                local sc = static_hash[k]
                if sc then
                    for i = 1, #sc do
                        local body = sc[i]
                        local bid = body.id
                        if not tested[bid] then
                            tested[bid] = true
                            local op = static_proxies[bid]
                            if op and op.members then
                                -- support = member top face in the slab under the body, a wall passing through is penetration, not support
                                local ms = op.members
                                for mi = 1, #ms do
                                    local m = ms[mi]
                                    if m[5] >= ly and m[5] <= ry
                                    and lx <= m[4] and rx >= m[1]
                                    and lz <= m[6] and rz >= m[3] then
                                        return "static"
                                    end
                                end
                            elseif op and op.aabb then
                                -- single-part statics (coarse cells_insert path): op.aabb is the part
                                local oa = op.aabb
                                if oa[5] >= ly and oa[5] <= ry
                                and lx <= oa[4] and rx >= oa[1]
                                and lz <= oa[6] and rz >= oa[3] then
                                    return "static"
                                end
                            end
                        end
                    end
                end
                local lc = sleeping_hash[k]
                if lc then
                    for i = 1, #lc do
                        local oid = lc[i].id
                        if oid ~= exclude_id then
                            local op = sleeping_proxies[oid]
                            if op and op.aabb then
                                local oa = op.aabb
                                if lx <= oa[4] and rx >= oa[1]
                                and ly <= oa[5] and ry >= oa[2]
                                and lz <= oa[6] and rz >= oa[3] then
                                    found_sleeping = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return found_sleeping and "sleeping" or nil
end

-- continuous collision (swept-aabb vs static)

-- ray vs static aabb expanded by half-extents (slab), returns entry time + face normal, or nil
-- only on tunnel/deep penetration, shallow landings left to the solver (keeps contact response/restitution)
local function ray_aabb_entry(cx, cy, cz, dx, dy, dz, aabb, hbx, hby, hbz)
    local minx, miny, minz = aabb[1] - hbx, aabb[2] - hby, aabb[3] - hbz
    local maxx, maxy, maxz = aabb[4] + hbx, aabb[5] + hby, aabb[6] + hbz
    local tmin, tmax = -math.huge, math.huge
    local nax, nsign = 0, 0
    -- x slab
    if dx > -1e-12 and dx < 1e-12 then
        if cx < minx or cx > maxx then return nil end
    else
        local inv = 1 / dx
        local t1, t2 = (minx - cx) * inv, (maxx - cx) * inv
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1; nax = 1; nsign = (dx > 0) and -1 or 1 end
        if t2 < tmax then tmax = t2 end
        if tmin > tmax then return nil end
    end
    -- y slab
    if dy > -1e-12 and dy < 1e-12 then
        if cy < miny or cy > maxy then return nil end
    else
        local inv = 1 / dy
        local t1, t2 = (miny - cy) * inv, (maxy - cy) * inv
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1; nax = 2; nsign = (dy > 0) and -1 or 1 end
        if t2 < tmax then tmax = t2 end
        if tmin > tmax then return nil end
    end
    -- z slab
    if dz > -1e-12 and dz < 1e-12 then
        if cz < minz or cz > maxz then return nil end
    else
        local inv = 1 / dz
        local t1, t2 = (minz - cz) * inv, (maxz - cz) * inv
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1; nax = 3; nsign = (dz > 0) and -1 or 1 end
        if t2 < tmax then tmax = t2 end
        if tmin > tmax then return nil end
    end
    -- must enter the expanded box from outside this step
    if tmin <= 1e-6 or tmin >= 1 then return nil end
    -- tunnel cases: pass-through, center inside box, or a static thinner than the step travel
    -- last one = a thin plate crossed in a fraction of a step, narrowphase never samples it -> needs ccd even on a shallow landing
    local entry_thickness, step_travel
    if nax == 1 then entry_thickness, step_travel = aabb[4] - aabb[1], dx < 0 and -dx or dx
    elseif nax == 2 then entry_thickness, step_travel = aabb[5] - aabb[2], dy < 0 and -dy or dy
    else entry_thickness, step_travel = aabb[6] - aabb[3], dz < 0 and -dz or dz end
    local thin_collider = entry_thickness < step_travel
    if tmax >= 1 and not thin_collider then
        local ex, ey, ez = cx + dx, cy + dy, cz + dz
        local center_inside = ex >= aabb[1] and ex <= aabb[4]
            and ey >= aabb[2] and ey <= aabb[5]
            and ez >= aabb[3] and ez <= aabb[6]
        if not center_inside then return nil end
    end
    if nax == 1 then return tmin, nsign, 0, 0
    elseif nax == 2 then return tmin, 0, nsign, 0
    else return tmin, 0, 0, nsign end
end

local function sweep_member_collidable(moving, target, world)
    if target and target.CanCollide == false then return false end
    if not moving or not target or not world then return true end
    local no_collision = world.no_collision
    local has_pair_filter = next(no_collision) ~= nil
    if world.collision_groups.blocked_count == 0 and not has_pair_filter then return true end
    local members = moving.parts or {}
    for i = 1, moving.part_count or #members do
        local view = members[i]
        if view and view.CanCollide ~= false
            and world.collision_groups:collidable(view.CollisionGroup, target.CollisionGroup) then
            if not has_pair_filter then return true end
            local a, b = tostring(view.id), tostring(target.id)
            local key = a < b and (a .. ":" .. b) or (b .. ":" .. a)
            if not no_collision[key] then return true end
        end
    end
    return false
end

-- earliest toi 0..1 vs any static, + contact normal, t=1 = no hit
function Broadphase:sweep_aabb_vs_static(cx, cy, cz, hbx, hby, hbz, dx, dy, dz, moving, world,member_filter)
    local ex = cx + dx
    local ey = cy + dy
    local ez = cz + dz
    local lx = (cx < ex and cx or ex) - hbx
    local ly = (cy < ey and cy or ey) - hby
    local lz = (cz < ez and cz or ez) - hbz
    local rx = (cx > ex and cx or ex) + hbx
    local ry = (cy > ey and cy or ey) + hby
    local rz = (cz > ez and cz or ez) + hbz
    local ax, ay, az = fl(lx), fl(ly), fl(lz)
    local bx, by, bz = fl(rx), fl(ry), fl(rz)
    local hashable = hash_range(ax, ay, az, bx, by, bz, MAX_SPAN)
    local static_hash    = self.static_hash
    local static_proxies = self.static_proxies
    local best_t = 1
    local bnx, bny, bnz = 0, 0, 0
    -- pooled epoch-stamped dedup, no per-call alloc
    local epoch = (self._sweep_epoch or 0) + 1
    self._sweep_epoch = epoch
    local seen = self._sweep_seen
    if not seen then seen = {}; self._sweep_seen = seen end
    local extras = hashable and self.static_overflow or static_proxies
    for id, proxy in pairs(extras) do
        seen[id] = epoch
        -- member-level: a big assembly is one union proxy, a body falling inside never "enters" it so the coarse ray misses tunneling
        local op = proxy
        local mems = op and op.members
        if mems and #mems > 0 then
            for m = 1, #mems do
                local ma = mems[m]
                -- non-collidable members never clamp (CanCollide is live)
                local mv = ma[7]
                if (not member_filter or member_filter(mv))and sweep_member_collidable(moving, mv, world)
                    and ma[4] >= lx and ma[1] <= rx
                    and ma[5] >= ly and ma[2] <= ry
                    and ma[6] >= lz and ma[3] <= rz then
                    local t, nx, ny, nz =
                        ray_aabb_entry(cx, cy, cz, dx, dy, dz, ma, hbx, hby, hbz)
                    if t and t < best_t then
                        best_t, bnx, bny, bnz = t, nx, ny, nz
                    end
                end
            end
        elseif op and op.aabb then
            local t, nx, ny, nz =
                ray_aabb_entry(cx, cy, cz, dx, dy, dz, op.aabb, hbx, hby, hbz)
            if t and t < best_t then
                best_t, bnx, bny, bnz = t, nx, ny, nz
            end
        end
    end
    if not hashable then return best_t, bnx, bny, bnz end
    for gx = ax, bx do
        for gy = ay, by do
            for gz = az, bz do
                local cell = static_hash[hkey(gx, gy, gz)]
                if cell then
                    for i = 1, #cell do
                        local body = cell[i]
                        local id = body.id
                        if seen[id] ~= epoch then
                            seen[id] = epoch
                            -- member-level: a big assembly is one union proxy, a body falling inside never "enters" it so the coarse ray misses tunneling
                            local op = static_proxies[id]
                            local mems = op and op.members
                            if mems and #mems > 0 then
                                for m = 1, #mems do
                                    local ma = mems[m]
                                    -- non-collidable members never clamp (CanCollide is live)
                                    local mv = ma[7]
                                    if (not member_filter or member_filter(mv))and sweep_member_collidable(moving, mv, world)
                                        and ma[4] >= lx and ma[1] <= rx
                                        and ma[5] >= ly and ma[2] <= ry
                                        and ma[6] >= lz and ma[3] <= rz then
                                        local t, nx, ny, nz =
                                            ray_aabb_entry(cx, cy, cz, dx, dy, dz, ma, hbx, hby, hbz)
                                        if t and t < best_t then
                                            best_t, bnx, bny, bnz = t, nx, ny, nz
                                        end
                                    end
                                end
                            elseif op and op.aabb then
                                local t, nx, ny, nz =
                                    ray_aabb_entry(cx, cy, cz, dx, dy, dz, op.aabb, hbx, hby, hbz)
                                if t and t < best_t then
                                    best_t, bnx, bny, bnz = t, nx, ny, nz
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best_t, bnx, bny, bnz
end

-- spatial query traversal (raycast / region overlap)

-- for physics/queries.lua (Raycast/FindPartsInRegion3), walks the sim's own hashes, only pays when called

local QUERY_MAX_SPAN = 256   -- per-axis cells for a region walk, ~8192 studs
local QUERY_MAX_CELLS = 4096 -- a dense volume selects a complete proxy scan

local function query_hash_range(ax, ay, az, bx, by, bz)
    return hash_range(ax, ay, az, bx, by, bz, QUERY_MAX_SPAN)
        and (bx - ax + 1) * (by - ay + 1) * (bz - az + 1) <= QUERY_MAX_CELLS
end

-- existing maps own the generation, removal/reset releases the matching overflow
-- entry. a query callback receives the current body only, never an old id owner
local function visit_proxy_map(map, lx, ly, lz, rx, ry, rz, fn, seen, epoch)
    for id, proxy in pairs(map) do
        if (not seen or seen[id] ~= epoch) and overlaps(proxy.aabb, lx, ly, lz, rx, ry, rz) then
            if seen then seen[id] = epoch end
            fn(proxy.body)
        end
    end
end

function Broadphase:for_overflow_bodies(lx, ly, lz, rx, ry, rz, fn)
    visit_proxy_map(self.static_overflow, lx, ly, lz, rx, ry, rz, fn)
    visit_proxy_map(self.dynamic_overflow, lx, ly, lz, rx, ry, rz, fn)
    visit_proxy_map(self.sleeping_overflow, lx, ly, lz, rx, ry, rz, fn)
end

-- studs, so callers can march the grid in world units
function Broadphase:cell_size()
    return CELL
end

-- o(1), lets a query pick hash-walk vs linear fallback without a proxy_count() scan
function Broadphase:has_any_proxy()
    return next(self.static_proxies) ~= nil
        or next(self.dynamic_proxies) ~= nil
        or next(self.sleeping_proxies) ~= nil
end

-- keep static bounds together so a ray can reject a whole cell’s distant members cheaply
-- run the exact shape query on the survivors
local QUERY_AABB_PAD = 1e-3 -- studs, outward-only, so float rounding in the slab
                            -- math can never under-cover a member (superset filter)

function Broadphase:static_query_cell(cx, cy, cz)
    if not key_range(cx, cy, cz, cx, cy, cz) then return nil end
    local k = hkey(cx, cy, cz)
    local cell = self.static_hash[k]
    if not cell then return nil end
    local rec = self._static_query_cells[k]
    if rec then return rec end

    local proxies = self.static_proxies
    -- collect member entries whose insert-time hash range covers THIS cell, the
    -- fl() + STATIC_MAX_SPAN clamp must mirror insert_static exactly so the array
    -- holds precisely the parts this cell's hashed bodies contribute here (a body
    -- is tested per cell now, not all-members-on-first-sight -- correctness holds
    -- because a member's own cells always cover any hit point on it, see queries)
    local views = {}
    local bodies = {}
    local n = 0
    for i = 1, #cell do
        local body = cell[i]
        local proxy = proxies[body.id]
        -- bodies inserted via the no-members fallback contribute nothing, matching
        -- the old visitor (it iterated assembly.parts, which is empty/nil for them)
        local mems = proxy and proxy.members
        if mems then
            for m = 1, #mems do
                local ma = mems[m]
                local ax, bx = fl(ma[1]), fl(ma[4])
                if not ma.overflow and cx >= ax and cx <= bx then
                    local ay, by = fl(ma[2]), fl(ma[5])
                    if cy >= ay and cy <= by then
                        local az, bz = fl(ma[3]), fl(ma[6])
                        if cz >= az and cz <= bz then
                            n = n + 1
                            views[n] = ma
                            -- parallel owner-body array so the candidate-pair scan
                            -- (query_candidates) can reuse these packed boxes too
                            bodies[n] = body
                        end
                    end
                end
            end
        end
    end
    -- doubles, not floats: values pass through bit-exact, so the only slab-filter
    -- slack needed is the pad covering arithmetic rounding
    local boxes = ffi.new("double[?]", n * 6)
    for i = 1, n do
        local ma = views[i]
        local b = (i - 1) * 6
        boxes[b]     = ma[1] - QUERY_AABB_PAD
        boxes[b + 1] = ma[2] - QUERY_AABB_PAD
        boxes[b + 2] = ma[3] - QUERY_AABB_PAD
        boxes[b + 3] = ma[4] + QUERY_AABB_PAD
        boxes[b + 4] = ma[5] + QUERY_AABB_PAD
        boxes[b + 5] = ma[6] + QUERY_AABB_PAD
        views[i] = ma[7]   -- keep only the member view, the survivor pass reads ._part live
    end
    rec = { n = n, boxes = boxes, views = views, bodies = bodies }
    self._static_query_cells[k] = rec
    return rec
end

-- dynamic + sleeping hashes only, no dedup (caller keeps a seen set), used by the
-- ray DDA, whose statics go through static_query_cell above instead of a visitor
-- (replaces the old for_bodies_in_cell, which also walked the static hash)
function Broadphase:for_moving_bodies_in_cell(cx, cy, cz, fn)
    if not key_range(cx, cy, cz, cx, cy, cz) then return end
    local k = hkey(cx, cy, cz)
    local dc = self.dynamic_hash[k]
    if dc then
        for i = 1, #dc do fn(dc[i]) end
    end
    local lc = self.sleeping_hash[k]
    if lc then
        for i = 1, #lc do fn(lc[i]) end
    end
end

-- fn(body) once per unique candidate, all 3 hashes, large regions scan complete proxies
function Broadphase:collect_region(lx, ly, lz, rx, ry, rz, fn)
    local ax, ay, az = fl(lx), fl(ly), fl(lz)
    local bx, by, bz = fl(rx), fl(ry), fl(rz)
    local hashable = query_hash_range(ax, ay, az, bx, by, bz)
    local static_hash   = self.static_hash
    local dynamic_hash  = self.dynamic_hash
    local sleeping_hash = self.sleeping_hash
    -- epoch-stamped scratch: region queries can run hundreds of times per frame and a
    -- fresh seen table each call was measurable GC pressure
    local epoch = (self._region_epoch or 0) + 1
    self._region_epoch = epoch
    local seen = self._region_seen
    if not seen then seen = {}; self._region_seen = seen end
    if not hashable then
        visit_proxy_map(self.static_proxies, lx, ly, lz, rx, ry, rz, fn, seen, epoch)
        visit_proxy_map(self.dynamic_proxies, lx, ly, lz, rx, ry, rz, fn, seen, epoch)
        visit_proxy_map(self.sleeping_proxies, lx, ly, lz, rx, ry, rz, fn, seen, epoch)
        return
    end
    visit_proxy_map(self.static_overflow, lx, ly, lz, rx, ry, rz, fn, seen, epoch)
    visit_proxy_map(self.dynamic_overflow, lx, ly, lz, rx, ry, rz, fn, seen, epoch)
    visit_proxy_map(self.sleeping_overflow, lx, ly, lz, rx, ry, rz, fn, seen, epoch)
    for cx = ax, bx do
        for cy = ay, by do
            for cz = az, bz do
                local k = hkey(cx, cy, cz)
                local sc = static_hash[k]
                if sc then
                    for i = 1, #sc do
                        local b = sc[i]
                        if seen[b.id] ~= epoch then seen[b.id] = epoch; fn(b) end
                    end
                end
                local dc = dynamic_hash[k]
                if dc then
                    for i = 1, #dc do
                        local b = dc[i]
                        if seen[b.id] ~= epoch then seen[b.id] = epoch; fn(b) end
                    end
                end
                local lc = sleeping_hash[k]
                if lc then
                    for i = 1, #lc do
                        local b = lc[i]
                        if seen[b.id] ~= epoch then seen[b.id] = epoch; fn(b) end
                    end
                end
            end
        end
    end
end

-- Sleeping-only neighborhood query. collect first: waking removes entries from
-- these hash cells and must not mutate a cell while it is being traversed
function Broadphase:collect_sleepers(lx,ly,lz,rx,ry,rz,out)
    local seen, count = self._wake_region_seen or {}, 0
    self._wake_region_seen = seen
    local epoch = (self._wake_region_epoch or 0)+1; self._wake_region_epoch=epoch
    local ax,ay,az,bx,by,bz=fl(lx),fl(ly),fl(lz),fl(rx),fl(ry),fl(rz)
    local hashable=query_hash_range(ax,ay,az,bx,by,bz)
    local extras=hashable and self.sleeping_overflow or self.sleeping_proxies
    for id,proxy in pairs(extras) do
        seen[id]=epoch
        if overlaps(proxy.aabb,lx,ly,lz,rx,ry,rz) then count=count+1;out[count]=proxy.body end
    end
    if hashable then
    for x=ax,bx do for y=ay,by do for z=az,bz do
        local cell=self.sleeping_hash[hkey(x,y,z)]
        if cell then for i=1,#cell do
            local body=cell[i]
            if seen[body.id]~=epoch then
                seen[body.id]=epoch
                local a=self.sleeping_proxies[body.id].aabb
                if a[4]>=lx and a[1]<=rx and a[5]>=ly and a[2]<=ry and a[6]>=lz and a[3]<=rz then
                    count=count+1;out[count]=body
                end
            end
        end end
    end end end
    end
    for i=#out,count+1,-1 do out[i]=nil end
    if epoch%4096==0 then self._wake_region_seen=nil end
    return count
end

-- step counter management

-- start of each fixed_step
function Broadphase:reset_step_counters()
    self.dirty_proxy_count     = 0
    self.proxy_upsert_count    = 0
    self.candidate_check_count = 0
    self.broadphase_pair_count = 0
    self._pair_tuple_used      = 0
end

return Broadphase
