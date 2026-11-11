-- persistent contact-manifold cache, one per overlapping part pair (keyed by sorted id pair), refreshed from broadphase pairs each step, warm-starts matches
-- no solver here, just stores/preserves impulses, bounded by prune + lru cap

local Narrowphase = runtime_require("physics/narrowphase.lua")
local Integrate   = runtime_require("physics/integrate.lua")
local Shape       = runtime_require("physics/shape.lua")
local MemberRanges = runtime_require("physics/member_ranges.lua")

local ManifoldCache = {}
ManifoldCache.__index = ManifoldCache

local sqrt  = math.sqrt
local floor = math.floor

-- static assembly this big gets a cached grid so awake parts test only nearby statics (~1600 in a classic map), smaller = naive scan
local STATIC_GRID_MIN_MEMBERS = 64
local STATIC_GRID_CELL        = 16   -- studs per grid cell

local PRUNE_AFTER   = 3      -- frames a manifold may stay inactive before pruning
-- Hard cap backstop, evicts oldest last_step. 4096 was reachable by a mere ~2000-body
-- dense pile, and at the cap every substep evicted live manifolds (cold restarts +
-- pathological O(n) scans per eviction). 16384 keeps it a true safety net
local MAX_MANIFOLDS = 16384
local MAX_POINTS    = 4      -- max contact points per manifold
-- orientation tolerance for "axis-aligned". Must be wide enough that a RESTING box with
-- solver-noise rotation stays on one clip path: the aa and obb paths use different
-- feature ids, so flip-flopping across this threshold resets warm-start impulses every
-- flip and a stack collapses. 5e-3 ~ 0.57 deg keeps rest stable, the position error from
-- treating that as axis-aligned is < 0.02 studs on a 4-stud face
local AA_EPS        = 5e-3

ManifoldCache.PRUNE_AFTER   = PRUNE_AFTER
ManifoldCache.MAX_MANIFOLDS = MAX_MANIFOLDS
ManifoldCache.MAX_POINTS    = MAX_POINTS

local abs = math.abs

-- aa = world rotation ~identity, only then is multi-point face clip exact, else single-point fallback
local function quat_is_identity(qw, qx, qy, qz)
    return (abs(qx) + abs(qy) + abs(qz)) < AA_EPS
end

-- view w/o rotation data counts as axis-aligned
local function cframe_axis_identity(cf)
    if cf == nil or cf.r00 == nil then
        return true
    end
    local off = abs(cf.r01 or 0) + abs(cf.r02 or 0) + abs(cf.r10 or 0)
              + abs(cf.r12 or 0) + abs(cf.r20 or 0) + abs(cf.r21 or 0)
    return off < AA_EPS
        and abs((cf.r00 or 1) - 1) < AA_EPS
        and abs((cf.r11 or 1) - 1) < AA_EPS
        and abs((cf.r22 or 1) - 1) < AA_EPS
end

-- packed numeric pair key (min*2^26+max), alloc-free, must stay in sync w/ physics.lua's contact_pair_key
-- no_collision map keeps the legacy "a:b" string key, built lazily only when non-empty
local PAIR_SHIFT = 67108864 -- 2^26

local function pair_key(a, b)
    if a < b then
        return a * PAIR_SHIFT + b
    end
    return b * PAIR_SHIFT + a
end

-- compat w/ no_collision producers
local function no_collision_string_key(a, b)
    local sa, sb = tostring(a), tostring(b)
    if sa < sb then
        return sa .. ":" .. sb
    end
    return sb .. ":" .. sa
end

-- nil _part (headless/test) = alive, prune() checks membership instead
local function view_destroyed(view)
    local p = view and view._part
    return p ~= nil and p._destroyed == true
end

local function view_no_collide(view)
    return view ~= nil and view.CanCollide == false
end

function ManifoldCache.new()
    return setmetatable({
        manifolds     = {},
        list          = {},  -- dense array of live manifolds (m._li = index), prune
                             -- iterates this numerically instead of pairs()-walking
                             -- the hash (a LuaJIT trace abort on the substep path)
        by_part       = {},  -- part_id -> {key -> manifold}
        cache_count   = 0,   -- live manifolds
        active_count  = 0,   -- refreshed this step
        pruned_count  = 0,   -- cumulative deletions
        contact_count = 0,   -- contact points this step
        -- per-step reject counters, set in update()
        can_collide_rejects  = 0,
        group_rejects        = 0,
        no_collision_rejects = 0,
        filter_rejects       = 0,
        -- reused scratch
        _ca = {}, _cb = {},  -- collider structs
        _out = {},           -- narrowphase output
        _ma = {}, _mb = {},  -- member buffers (view + world center)
    }, ManifoldCache)
end

-- counts as pruned, unindexes
function ManifoldCache:_remove(key)
    local m = self.manifolds[key]
    if m ~= nil then
        self.manifolds[key] = nil
        m._dead = true -- active_list may still reference it, solver skips

        -- dense-list swap-remove
        local list = self.list
        local li = m._li
        if list and li then
            local last = #list
            local moved = list[last]
            list[li] = moved
            list[last] = nil
            if moved then moved._li = li end
            m._li = nil
        end

        local by_part = self.by_part
        if by_part then
            local la = by_part[m.part_a_id]
            if la then
                la[key] = nil
                if next(la) == nil then by_part[m.part_a_id] = nil end
            end
            local lb = by_part[m.part_b_id]
            if lb then
                lb[key] = nil
                if next(lb) == nil then by_part[m.part_b_id] = nil end
            end
        end
        self.cache_count  = self.cache_count - 1
        self.pruned_count = self.pruned_count + 1
    end
end

-- reused {view,cx,cy,cz} per member world center, static caches once on body, dynamic per substep
-- without the cache, one awake body vs a ~1600-part static rebuilds every entry (quat+sqrt) per pair per substep
local collect_member_epoch = 0 -- stamped from update(), single-world convention

local function collect_members(body, buf)
    local n = 0
    if body.is_static then
        local cached = body._static_member_cache
        if cached then return cached, cached.n end
        local cache = {}
        local asm = body.assembly
        local parts = asm and asm.parts or {}
        for i = 1, #parts do
            local v = parts[i]
            local p = v.Position
            n = n + 1
            local e = {}; cache[n] = e
            e.view = v
            e.cx = p and (p.x or p.X) or 0
            e.cy = p and (p.y or p.Y) or 0
            e.cz = p and (p.z or p.Z) or 0
            -- from static bind cframe, so the obb path gets real axes for a rotated anchored collider
            local cf = v.CFrameRef
            if cf and cf.r00 ~= nil then
                e.qw, e.qx, e.qy, e.qz = Integrate.quat_from_matrix(
                    cf.r00, cf.r01, cf.r02, cf.r10, cf.r11, cf.r12, cf.r20, cf.r21, cf.r22)
            else
                e.qw, e.qx, e.qy, e.qz = 1, 0, 0, 0
            end
            e.aa = cframe_axis_identity(cf)
            local hx, hy, hz = Shape.half_extents(v)
            e.br = sqrt(hx * hx + hy * hy + hz * hz)  -- circumradius for the cheap pair reject
            -- project each local half-extent onto the world axes with |R| * h
            -- contact rejection needs an upper bound even when the part is rotated
            local m00, m01, m02, m10, m11, m12, m20, m21, m22 =
                Integrate.quat_to_matrix(e.qw, e.qx, e.qy, e.qz)
            e.hbx = abs(m00) * hx + abs(m01) * hy + abs(m02) * hz
            e.hby = abs(m10) * hx + abs(m11) * hy + abs(m12) * hz
            e.hbz = abs(m20) * hx + abs(m21) * hy + abs(m22) * hz
        end
        cache.n = n
        body._static_member_cache = cache
        return cache, n
    end

    local offs = body.local_offsets
    if offs and #offs > 0 then
        -- per-body per-substep cache, refilled once per epoch, else members re-rotate k times per substep for k neighbours
        local mbuf = body._member_buf
        if mbuf and body._member_step == collect_member_epoch then
            return mbuf, mbuf.n
        end
        if not mbuf then
            mbuf = {}
            body._member_buf = mbuf
        end
        local cmx, cmy, cmz = body.com_x, body.com_y, body.com_z
        local qw, qx, qy, qz = body.qw, body.qx, body.qy, body.qz
        for i = 1, #offs do
            local o = offs[i]
            local rx, ry, rz = Integrate.rotate_vec(qw, qx, qy, qz, o.lx, o.ly, o.lz)
            n = n + 1
            local e = mbuf[n]; if not e then e = {}; mbuf[n] = e end
            e.view = o.view
            e.cx = cmx + rx; e.cy = cmy + ry; e.cz = cmz + rz
            -- body_q * member_local_q, so a rotated member's obb axes are exact
            local mw, mx, my, mz = Integrate.quat_mul(qw, qx, qy, qz,
                o.qw or 1, o.qx or 0, o.qy or 0, o.qz or 0)
            e.qw, e.qx, e.qy, e.qz = mw, mx, my, mz
            e.aa = quat_is_identity(mw, mx, my, mz)
            local hx, hy, hz = Shape.half_extents(o.view)
            e.hx, e.hy, e.hz = hx, hy, hz
            e.br = sqrt(hx * hx + hy * hy + hz * hz)
        end
        -- project each local half-extent onto the world axes with |R| * h
        -- contact rejection needs an upper bound even when the part is rotated
        for i = 1, n do
            local e = mbuf[i]
            -- the unrotated shortcut is only valid for an EXACTLY identity rotation
            -- e.aa is deliberately tolerant (~0.57 degrees) so that solver noise keeps a
            -- member on one clip path, reusing it here understated the world AABB of any
            -- near-axis-aligned part and made the disjoint-AABB reject in
            -- _collide_member_pair drop real contacts. Test the quaternion exactly
            -- instead: genuinely axis-aligned parts -- the large majority on a Roblox
            -- map -- still skip the projection, and anything actually rotated pays for
            -- the correct bound
            local qw, qx, qy, qz = e.qw, e.qx, e.qy, e.qz
            if (qx == 0 and qy == 0 and qz == 0) and (qw == 1 or qw == -1) then
                e.hbx, e.hby, e.hbz = e.hx, e.hy, e.hz
            else
                local m00, m01, m02, m10, m11, m12, m20, m21, m22 =
                    Integrate.quat_to_matrix(qw, qx, qy, qz)
                e.hbx = abs(m00) * e.hx + abs(m01) * e.hy + abs(m02) * e.hz
                e.hby = abs(m10) * e.hx + abs(m11) * e.hy + abs(m12) * e.hz
                e.hbz = abs(m20) * e.hx + abs(m21) * e.hy + abs(m22) * e.hz
            end
        end
        mbuf.n = n
        body._member_step = collect_member_epoch
        return mbuf, n
    end

    -- unbound fallback (no bind ran): com + world-frame build offset
    local asm = body.assembly
    local parts = asm and asm.parts or {}
    local acx = asm and asm.com_x or 0
    local acy = asm and asm.com_y or 0
    local acz = asm and asm.com_z or 0
    local cmx, cmy, cmz = body.com_x, body.com_y, body.com_z
    for i = 1, #parts do
        local v = parts[i]
        local p = v.Position
        local px = p and (p.x or p.X) or 0
        local py = p and (p.y or p.Y) or 0
        local pz = p and (p.z or p.Z) or 0
        n = n + 1
        local e = buf[n]; if not e then e = {}; buf[n] = e end
        e.view = v
        e.cx = cmx + (px - acx); e.cy = cmy + (py - acy); e.cz = cmz + (pz - acz)
        e.qw, e.qx, e.qy, e.qz = 1, 0, 0, 0
        e.aa = true   -- no orientation info: treat as axis-aligned
        local hx, hy, hz = Shape.half_extents(v)
        e.hx, e.hy, e.hz = hx, hy, hz
        -- unrotated by definition here, so the world AABB is the local box
        e.hbx, e.hby, e.hbz = hx, hy, hz
        e.br = sqrt(hx * hx + hy * hy + hz * hz)
    end
    return buf, n
end

-- points matched to pool by feature_id for warm-start, unproduced ones pruned
function ManifoldCache:_apply(key, view_a, view_b, body_a, body_b, ca, cb, out, step_index)
    local m = self.manifolds[key]
    if not m then
        m = {
            key = key,
            points = {},   -- live ordered points this step, what the solver reads
            pool = {},     -- ARRAY keyed by feature_id field, persists for warm-start
            lifetime = 0,
        }
        self.manifolds[key] = m
        local list = self.list
        local li = #list + 1
        list[li] = m
        m._li = li
        self.cache_count = self.cache_count + 1
    end
    m.part_a_id = view_a.id
    m.part_b_id = view_b.id
    m.view_a, m.view_b = view_a, view_b
    m.body_a, m.body_b = body_a, body_b
    m.normal_x, m.normal_y, m.normal_z = out.nx, out.ny, out.nz
    -- per-part index: grounded checks read it (no raycast), remove_for_part uses it (no full scan)
    local by_part = self.by_part
    local la = by_part[m.part_a_id]
    if not la then la = {}; by_part[m.part_a_id] = la end
    la[key] = m
    local lb = by_part[m.part_b_id]
    if not lb then lb = {}; by_part[m.part_b_id] = lb end
    lb[key] = m
    m.friction   = Narrowphase.combine_friction(ca, cb)
    m.elasticity = Narrowphase.combine_elasticity(ca, cb)

    -- linear scan not hash: pairs() is a luajit trace abort, kept the whole contact pipeline interpreted
    local pool = m.pool
    local pts  = m.points
    local cnt  = out.count
    if cnt > MAX_POINTS then cnt = MAX_POINTS end

    for i = 1, cnt do
        local src  = out.points[i]
        local feat = src.feature_id
        local p
        for k = 1, #pool do
            local candidate = pool[k]
            if candidate.feature_id == feat then
                p = candidate
                break
            end
        end
        if not p then
            -- Feature ids changed without the contact moving: the aa and obb clip paths
            -- assign different id families to the SAME physical face contact, so a
            -- resting box that drifts across the axis-aligned tolerance would reset its
            -- warm-start impulses every flip (measured: a 5-box tower collapses from
            -- exactly this). Inherit the impulse of the nearest unclaimed old point
            local best_d = 0.09   -- (0.3 studs)^2: resting contacts move far less
            for k = 1, #pool do
                local candidate = pool[k]
                if candidate.seen_step ~= step_index then
                    local dx = candidate.px - src.px
                    local dy = candidate.py - src.py
                    local dz = candidate.pz - src.pz
                    local d = dx * dx + dy * dy + dz * dz
                    if d < best_d then
                        best_d = d
                        p = candidate
                    end
                end
            end
        end
        if not p then
            -- new feature: cold impulses
            p = { normal_impulse = 0, tangent_impulse_x = 0, tangent_impulse_y = 0 }
            pool[#pool + 1] = p
        end
        -- geometry refreshed, impulses preserved (warm-start)
        p.px, p.py, p.pz = src.px, src.py, src.pz
        p.penetration = src.penetration
        p.feature_id  = feat
        p.seen_step   = step_index
        pts[i] = p
    end
    for i = #pts, cnt + 1, -1 do pts[i] = nil end

    -- backwards swap-remove keeps it alloc/pairs()-free
    for k = #pool, 1, -1 do
        if pool[k].seen_step ~= step_index then
            local last = #pool
            pool[k] = pool[last]
            pool[last] = nil
        end
    end

    m.lifetime = m.lifetime + 1
    m.last_step = step_index
    m.inactive_frames = 0
    m._dead = nil
    local alist = self.active_list
    if alist then
        local an = (self.active_n or 0) + 1
        self.active_n = an
        alist[an] = m
    end
    self.active_count = self.active_count + 1
    self.contact_count = self.contact_count + cnt
end

-- packed cell key (same scheme as broadphase hkey), exact under 4096 (~65k studs at cell=16)
local function gkey(cx, cy, cz)
    return ((cx + 4096) * 8192 + (cy + 4096)) * 8192 + (cz + 4096)
end

-- into every cell its aabb overlaps, big flat members (baseplate) land in many
local function grid_insert(grid, e)
    local cell  = grid.cell
    local cells = grid.cells
    local ax, bx = floor((e.cx - e.hbx) / cell), floor((e.cx + e.hbx) / cell)
    local ay, by = floor((e.cy - e.hby) / cell), floor((e.cy + e.hby) / cell)
    local az, bz = floor((e.cz - e.hbz) / cell), floor((e.cz + e.hbz) / cell)
    for gx = ax, bx do
        for gy = ay, by do
            for gz = az, bz do
                local k = gkey(gx, gy, gz)
                local bucket = cells[k]
                if not bucket then bucket = {}; cells[k] = bucket end
                bucket[#bucket + 1] = e
            end
        end
    end
end

-- self-invalidating: fresh body per topology rebuild
function ManifoldCache:_ensure_static_grid(body)
    if body._static_member_grid then return end
    local cache, n = collect_members(body, nil)
    local grid = { cell = STATIC_GRID_CELL, cells = {} }
    for i = 1, n do
        grid_insert(grid, cache[i])
    end
    body._static_member_grid = grid
end

-- one member may touch many other bodies during a group wake. its collider
-- (pose, dimensions and material) is identical for every pair in this step
local function member_collider(entry,step)
    local collider=entry._collider
    if not collider then collider={};entry._collider=collider end
    if entry._collider_step~=step then
        Narrowphase.make_collider(collider,entry.view,entry.cx,entry.cy,entry.cz,
            entry.qw,entry.qx,entry.qy,entry.qz)
        collider.aa=entry.aa
        entry._collider_step=step
    end
    return collider
end

-- sphere reject -> filters -> narrowphase+manifold
function ManifoldCache:_collide_member_pair(ea, body_ea, eb, body_eb, no_collision, groups, step_index)
    local va, vb = ea.view, eb.view
    if not vb or vb.id == nil or vb.id == va.id or view_destroyed(vb) then return end
    self.member_test_count = (self.member_test_count or 0) + 1
    local ddx = ea.cx - eb.cx
    local ddy = ea.cy - eb.cy
    local ddz = ea.cz - eb.cz
    -- skip pairs whose world bounds are disjoint before computing the contact manifold
    local ahbx = ea.hbx
    if ahbx then
        local bhbx = eb.hbx
        if bhbx then
            if ddx >= ahbx + bhbx or -ddx >= ahbx + bhbx then return end
            local sy = ea.hby + eb.hby
            if ddy >= sy or -ddy >= sy then return end
            local sz = ea.hbz + eb.hbz
            if ddz >= sz or -ddz >= sz then return end
        end
    end
    local rsum = (ea.br or 0) + (eb.br or 0)
    if ddx * ddx + ddy * ddy + ddz * ddz > rsum * rsum then return end  -- circumradius reject
    self.member_survivor_count = (self.member_survivor_count or 0) + 1
    if view_no_collide(vb) then
        self.can_collide_rejects = self.can_collide_rejects + 1
        self.filter_rejects = self.filter_rejects + 1
        return
    end
    -- lower id is a (matches key + a->b normal convention)
    local lowE, highE, lowBody, highBody
    if va.id < vb.id then
        lowE, highE, lowBody, highBody = ea, eb, body_ea, body_eb
    else
        lowE, highE, lowBody, highBody = eb, ea, body_eb, body_ea
    end
    local key = pair_key(lowE.view.id, highE.view.id)
    -- string-keyed + usually empty, only build the string key when it has entries
    if self._no_collision_active
        and no_collision[no_collision_string_key(lowE.view.id, highE.view.id)] then
        self.no_collision_rejects = self.no_collision_rejects + 1
        self.filter_rejects = self.filter_rejects + 1
        self:_remove(key)
    elseif groups and not groups:collidable(
            lowE.view.CollisionGroup, highE.view.CollisionGroup) then
        self.group_rejects = self.group_rejects + 1
        self.filter_rejects = self.filter_rejects + 1
        self:_remove(key)
    else
        local ca,cb,out=member_collider(lowE,step_index),member_collider(highE,step_index),self._out
        if Narrowphase.collide(ca, cb, out) > 0 then
            self:_apply(key, lowE.view, highE.view, lowBody, highBody, ca, cb, out, step_index)
        end
    end
end

-- grid lookup per probe member instead of testing all, dedup epoch avoids re-testing a static spanning several cells
function ManifoldCache:_collide_probe_vs_grid(probe_body, grid_body, no_collision, groups, step_index)
    local pm, np = collect_members(probe_body, self._ma)
    local grid  = grid_body._static_member_grid
    local cell  = grid.cell
    local cells = grid.cells
    for ip = 1, np do
        local ea = pm[ip]
        local va = ea.view
        if va and va.id ~= nil and not view_destroyed(va) then
            if view_no_collide(va) then
                self.can_collide_rejects = self.can_collide_rejects + 1
                self.filter_rejects = self.filter_rejects + 1
            else
                self._grid_epoch = (self._grid_epoch or 0) + 1
                local epoch = self._grid_epoch
                -- Query by the probe's world AABB, not its circumradius. grid_insert
                -- files each static under the cells ITS aabb covers, so two overlapping
                -- AABBs always share a cell -- the sphere query was simply a looser
                -- superset of the same answer, and for a long thin probe (a 20-stud
                -- wall: br=10, hb=(10,0.5,0.5)) it swept whole cell rows that could
                -- never contain a real overlap
                local hbx, hby, hbz = ea.hbx, ea.hby, ea.hbz
                if not hbx then
                    hbx = ea.br or 0; hby = hbx; hbz = hbx
                end
                local ax, bx = floor((ea.cx - hbx) / cell), floor((ea.cx + hbx) / cell)
                local ay, by = floor((ea.cy - hby) / cell), floor((ea.cy + hby) / cell)
                local az, bz = floor((ea.cz - hbz) / cell), floor((ea.cz + hbz) / cell)
                for gx = ax, bx do
                    for gy = ay, by do
                        for gz = az, bz do
                            local bucket = cells[gkey(gx, gy, gz)]
                            if bucket then
                                for k = 1, #bucket do
                                    local eb = bucket[k]
                                    if eb._qepoch ~= epoch then
                                        eb._qepoch = epoch
                                        self:_collide_member_pair(ea, probe_body, eb, grid_body,
                                            no_collision, groups, step_index)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function ManifoldCache:_collide_member_ranges(ma_buf, mb_buf, alo, ahi, blo, bhi, body_a, body_b, no_collision, groups, step_index)
    local nb = mb_buf.n or #mb_buf
for ia = alo, ahi do
    local ea = ma_buf[ia]
    local va = ea.view
    if va and va.id ~= nil and not view_destroyed(va) then
        if view_no_collide(va) then
            -- cancollide=false on a rejects every pair it would form
            self.can_collide_rejects = self.can_collide_rejects + nb
            self.filter_rejects = self.filter_rejects + nb
        else
            -- AABB reject INLINE, before the call. Broadphase pairs are
            -- body-level, so a 39-part body next to one static still
            -- expands to 39 member tests here and >99% of them are
            -- rejected -- paying a method call to find that out made the
            -- call itself the dominant narrowphase cost. same test and
            -- same conservatism as the one inside _collide_member_pair
            -- (kept there for any other caller)
            local acx, acy, acz = ea.cx, ea.cy, ea.cz
            local ahbx, ahby, ahbz = ea.hbx, ea.hby, ea.hbz
            for ib = blo, bhi do
                local eb = mb_buf[ib]
                local hit = true
                if ahbx and eb.hbx then
                    local d = acx - eb.cx
                    local s = ahbx + eb.hbx
                    if d >= s or -d >= s then
                        hit = false
                    else
                        d = acy - eb.cy; s = ahby + eb.hby
                        if d >= s or -d >= s then
                            hit = false
                        else
                            d = acz - eb.cz; s = ahbz + eb.hbz
                            if d >= s or -d >= s then hit = false end
                        end
                    end
                end
                if hit then
                    self:_collide_member_pair(ea, body_a, eb, body_b,
                        no_collision, groups, step_index)
                else
                    self.member_test_count = (self.member_test_count or 0) + 1
                end
            end
        end
    end
end
end

-- Nodes are preordered and each subtree has an exclusive end index. Skipping
-- a disjoint range needs neither recursion nor a candidate-list allocation
-- the nested leaf loops retain the original A-major, then B-major order
local function collide_trees(self, a, b, ma, mb, body_a, body_b, no_collision, groups, step)
    local anodes, bnodes = a.nodes, b.nodes
    local ai = 1
    while ai <= #anodes do
        local node_a = anodes[ai]
        self.member_node_visits = self.member_node_visits + 1
        if not MemberRanges.overlap(node_a, b.root) then
            ai = node_a.after
        elseif node_a.left then
            ai = ai + 1
        else
            if not b.root.left then
                -- the common compound/singleton case. the unchanged inline leaf
                -- test is cheaper than rebuilding another per-member query box
                self:_collide_member_ranges(ma, mb, node_a.lo, node_a.hi,
                    b.root.lo, b.root.hi, body_a, body_b, no_collision, groups, step)
            else
                for ia = node_a.lo, node_a.hi do
                    local va = ma[ia].view
                    if va and va.id ~= nil and not view_destroyed(va) then
                        if view_no_collide(va) then
                            self.can_collide_rejects = self.can_collide_rejects + (mb.n or #mb)
                            self.filter_rejects = self.filter_rejects + (mb.n or #mb)
                        else
                            local bi = 1
                            while bi <= #bnodes do
                                local node_b = bnodes[bi]
                                self.member_node_visits = self.member_node_visits + 1
                                -- a's leaf-group enclosure is conservative for
                                -- every member. Exact rejection remains below
                                if not MemberRanges.overlap(node_a, node_b) then
                                    bi = node_b.after
                                elseif node_b.left then
                                    bi = bi + 1
                                else
                                    self:_collide_member_ranges(ma, mb, ia, ia,
                                        node_b.lo, node_b.hi, body_a, body_b, no_collision, groups, step)
                                    bi = bi + 1
                                end
                            end
                        end
                    end
                end
            end
            ai = ai + 1
        end
    end
end
function ManifoldCache:_collide_members(ma,na,mb,nb,body_a,body_b,no_collision,groups,step)
    local stable_a=body_a._static_member_cache==ma or body_a._member_buf==ma
    local stable_b=body_b._static_member_cache==mb or body_b._member_buf==mb
    if self._member_selection_disabled~=true and (na>=MemberRanges.MIN_MEMBERS or nb>=MemberRanges.MIN_MEMBERS)
        and stable_a and stable_b then
        local a=MemberRanges.prepare(ma,na,body_a.is_static and ma or body_a._member_step,self)
        local b=MemberRanges.prepare(mb,nb,body_b.is_static and mb or body_b._member_step,self)
        if a and b then
            collide_trees(self,a,b,ma,mb,body_a,body_b,no_collision,groups,step)
            return
        end
        self.member_tree_fallbacks=self.member_tree_fallbacks+1
    end
    self:_collide_member_ranges(ma,mb,1,na,1,nb,body_a,body_b,no_collision,groups,step)
end
ManifoldCache.release_member_ranges = MemberRanges.release

-- refresh from this step's broadphase pairs, filters run before narrowphase math, rejects counted for diagnostics
-- vs a large static assembly uses the member grid, everything else naive member x member
function ManifoldCache:update(pairs_in, no_collision, part_to_assembly, step_index, groups)
    self.active_count = 0
    self.contact_count = 0
    self.can_collide_rejects  = 0
    self.group_rejects        = 0
    self.no_collision_rejects = 0
    self.filter_rejects       = 0
    -- dense list so the solver uses a numeric loop, not pairs()
    local active_list = self.active_list
    if not active_list then
        active_list = {}
        self.active_list = active_list
    end
    self.active_n = 0
    self.member_node_visits = 0
    self.member_tree_builds = 0
    self.member_tree_refits = 0
    self.member_tree_fallbacks = 0
    self.member_test_count = 0
    self.member_survivor_count = 0
    no_collision = no_collision or {}
    self._no_collision_active = next(no_collision) ~= nil
    collect_member_epoch = step_index
    pairs_in = pairs_in or {}

    local ma, mb = self._ma, self._mb

    for i = 1, #pairs_in do
        local pr = pairs_in[i]
        local body_a, body_b = pr[1], pr[2]
        if body_a ~= body_b then
            -- route an awake-vs-large-static pair through the member grid
            local grid_body, probe_body
            local sa = body_a.assembly
            local sb = body_b.assembly
            local sa_parts = sa and sa.parts
            local sb_parts = sb and sb.parts
            if body_b.is_static and sb_parts and #sb_parts >= STATIC_GRID_MIN_MEMBERS then
                grid_body, probe_body = body_b, body_a
            elseif body_a.is_static and sa_parts and #sa_parts >= STATIC_GRID_MIN_MEMBERS then
                grid_body, probe_body = body_a, body_b
            end
            if grid_body and not probe_body.is_static then
                self:_ensure_static_grid(grid_body)
                self:_collide_probe_vs_grid(probe_body, grid_body, no_collision, groups, step_index)
            else
                local ma_buf, na = collect_members(body_a, ma)
                local mb_buf, nb = collect_members(body_b, mb)
                self:_collide_members(ma_buf,na,mb_buf,nb,body_a,body_b,no_collision,groups,step_index)
            end
        end
    end
end

-- age out + delete invalid manifolds, enforce hard cap, numeric backwards walk over the
-- dense list so the frequent-substep path never runs pairs()
function ManifoldCache:prune(step_index, part_to_assembly)
    local list = self.list
    for i = #list, 1, -1 do
        local m = list[i]
        local dead = false
        if view_destroyed(m.view_a) or view_destroyed(m.view_b)
            or view_no_collide(m.view_a) or view_no_collide(m.view_b) then
            dead = true
        elseif part_to_assembly
            and (part_to_assembly[m.part_a_id] == nil or part_to_assembly[m.part_b_id] == nil) then
            dead = true
        elseif (m.last_step or 0) < step_index then
            m.inactive_frames = (m.inactive_frames or 0) + 1
            if m.inactive_frames > PRUNE_AFTER then
                dead = true
            end
        end
        if dead then
            self:_remove(m.key)
        end
    end
    if self.cache_count > MAX_MANIFOLDS then
        self:_evict_lru()
    end
end

-- Rare backstop: one sort of the (small) dense list, then drop the oldest overflow in a
-- single batch. the old per-eviction full scan was O(n * overflow) and, once a dense
-- pile pinned the cache at the cap, ran every prune
function ManifoldCache:_evict_lru()
    local over = self.cache_count - MAX_MANIFOLDS
    if over <= 0 then return end
    local list = self.list
    local by_age = {}
    for i = 1, #list do by_age[i] = list[i] end
    table.sort(by_age, function(a, b) return (a.last_step or 0) < (b.last_step or 0) end)
    for i = 1, over do
        local m = by_age[i]
        if m and not m._dead then self:_remove(m.key) end
    end
end

-- immediate no-collision/group-filter invalidation
function ManifoldCache:remove_pair(key)
    if key ~= nil and self.manifolds[key] ~= nil then
        self:_remove(key)
        return true
    end
    return false
end

-- cancollide/collisiongroup invalidation, or teardown
function ManifoldCache:remove_for_part(part_id)
    if part_id == nil then
        return 0
    end
    local removed = 0
    local indexed = self.by_part and self.by_part[part_id]
    if indexed then
        -- collect keys first, _remove mutates the set. reuse scratch because destruction
        -- can otherwise add a small allocation spike on top of the operation it fixes
        local keys = self._remove_keys
        if not keys then keys = {}; self._remove_keys = keys end
        local n = 0
        for key in pairs(indexed) do
            n = n + 1
            keys[n] = key
        end
        for i = 1, n do
            self:_remove(keys[i])
            keys[i] = nil
            removed = removed + 1
        end
    else
        for key, m in pairs(self.manifolds) do
            if m.part_a_id == part_id or m.part_b_id == part_id then
                self:_remove(key)
                removed = removed + 1
            end
        end
    end

    -- _remove marks cached active manifolds dead so the solver is safe. a body being
    -- destroyed is stronger than a filter edit: compact the current dense list now so
    -- diagnostics and retained references also become exact before the next substep
    if removed > 0 and self.active_list then
        local list = self.active_list
        local n = self.active_n or 0
        local write, contacts = 1, 0
        for i = 1, n do
            local m = list[i]
            if m and not m._dead then
                list[write] = m
                write = write + 1
                contacts = contacts + #(m.points or {})
            end
        end
        for i = write, n do list[i] = nil end
        self.active_n = write - 1
        self.active_count = write - 1
        self.contact_count = contacts
    end
    return removed
end

-- topology rebuild: stale body refs. pruned_count not reset here
function ManifoldCache:clear()
    self.manifolds = {}
    self.list = {}
    self.by_part = {}
    self.active_list = nil
    self.active_n = 0
    self.cache_count = 0
    self.active_count = 0
    self.contact_count = 0
end

-- incl. cumulative counter
function ManifoldCache:reset()
    self:clear()
    self.pruned_count = 0
end

return ManifoldCache
