-- pgs solver over manifold.lua's persistent manifolds, order: prepare, warmstart, n velocity iters, writeback, m position iters (ngs)
-- normal per-point (resists tipping), friction once per manifold at the centroid, normal a->b (a=lower id)

local Integrate = runtime_require("physics/integrate.lua")
local Rope = runtime_require("physics/rope.lua")

local Solver = {}
local sqrt = math.sqrt
local abs  = math.abs
local max  = math.max
local clamp_finite = Integrate.clamp_finite

local DEFAULT_VELOCITY_ITERATIONS = 8
local DEFAULT_POSITION_ITERATIONS = 3
local DEFAULT_BAUMGARTE           = 0.2   -- positional correction fraction per iter
local DEFAULT_SLOP                = 0.01  -- penetration left uncorrected (studs)
local RESTITUTION_FLOOR           = 1.0   -- min approach speed that can bounce
local MAX_CORRECTION              = 0.2   -- max ngs push per contact/iter (studs)
local MAX_ANGULAR_CORRECTION      = 0.1   -- max ngs pseudo-rotation per contact/iter (rad)
local MAX_IMPULSE                 = 1e9   -- normal impulse cap (anti-inf)
-- angular ngs only past this: deep tilt un-tilts to flat, resting stays linear-only (no rotation drift)
local ANGULAR_NGS_MIN_PEN         = 0.05

Solver.__index = Solver

function Solver.new(params)
    params = params or {}
    return setmetatable({
        velocity_iterations = params.velocity_iterations or DEFAULT_VELOCITY_ITERATIONS,
        position_iterations = params.position_iterations or DEFAULT_POSITION_ITERATIONS,
        baumgarte           = params.baumgarte or DEFAULT_BAUMGARTE,
        slop                = params.slop or DEFAULT_SLOP,
        -- impact-wake: 0 uses the normal 1 stud/second activation threshold
        sleep_linear_threshold = params.sleep_linear_threshold or 0.25,
        wake_speed_threshold   = params.wake_speed_threshold or 0,
        -- pooled scratch, grown on demand, reused across frames
        _c = {},        -- per-point normal constraints
        _count = 0,
        _f = {},        -- per-manifold friction constraints
        _fcount = 0,
    }, Solver)
end

-- retune from world config without reallocating
function Solver:configure(params)
    if not params then return end
    if params.velocity_iterations then self.velocity_iterations = params.velocity_iterations end
    if params.position_iterations then self.position_iterations = params.position_iterations end
    if params.baumgarte then self.baumgarte = params.baumgarte end
    if params.slop then self.slop = params.slop end
    if params.sleep_linear_threshold then self.sleep_linear_threshold = params.sleep_linear_threshold end
    if params.wake_speed_threshold ~= nil then self.wake_speed_threshold = params.wake_speed_threshold end
end

-- Contact scratch is pooled across frames. a topology rebuild replaces the whole world,
-- but incremental destruction must explicitly release the removed body (and its dead
-- manifold/contact point) from every high-water slot, not only the current live range
-- returns the number of normal constraints that belonged to the last prepared solve
function Solver:forget_body(body)
    if body == nil then return 0 end
    local removed_active = 0
    local active_count = self._count or 0
    local contacts = self._c
    for i = 1, #contacts do
        local c = contacts[i]
        if c and (c.ba == body or c.bb == body) then
            if i <= active_count then removed_active = removed_active + 1 end
            c.ba, c.bb, c.m, c.pt = nil, nil, nil, nil
        end
    end
    local friction = self._f
    for i = 1, #friction do
        local f = friction[i]
        if f and (f.ba == body or f.bb == body) then
            f.ba, f.bb, f.m = nil, nil, nil
        end
    end
    local fallback = self._prepare_fallback_list
    if fallback then
        for i, m in pairs(fallback) do
            if m and (m.body_a == body or m.body_b == body) then fallback[i] = nil end
        end
    end
    -- no phase consumes prepared scratch after solve returns, the next solve repopulates
    -- it through _prepare. Zeroing the ranges makes accidental between-step reuse safe
    self._count, self._fcount = 0, 0
    return removed_active
end

-- impulse at lever arm r, im/inertia 0 for static/sleeping = immovable support
local function apply_impulse(b, jx, jy, jz, rx, ry, rz, im, Ixx, Iyy, Izz, Ixy, Ixz, Iyz)
    if im == 0 then return end
    b.vx = b.vx + jx * im
    b.vy = b.vy + jy * im
    b.vz = b.vz + jz * im
    local tx = ry * jz - rz * jy
    local ty = rz * jx - rx * jz
    local tz = rx * jy - ry * jx
    b.wx = b.wx + Ixx * tx + Ixy * ty + Ixz * tz
    b.wy = b.wy + Ixy * tx + Iyy * ty + Iyz * tz
    b.wz = b.wz + Ixz * tx + Iyz * ty + Izz * tz
end

-- denom along axis u: invmass + dot(u,(iinv*(r x u)) x r)
local function effective_mass(ax, ay, az, im, Ixx, Iyy, Izz, Ixy, Ixz, Iyz, ux, uy, uz)
    -- c = r x u
    local cx = ay * uz - az * uy
    local cy = az * ux - ax * uz
    local cz = ax * uy - ay * ux
    -- i = iinv * c (full symmetric tensor)
    local ix = Ixx * cx + Ixy * cy + Ixz * cz
    local iy = Ixy * cx + Iyy * cy + Iyz * cz
    local iz = Ixz * cx + Iyz * cy + Izz * cz
    -- (i x r) . u
    local kx = iy * az - iz * ay
    local ky = iz * ax - ix * az
    local kz = ix * ay - iy * ax
    return im + (kx * ux + ky * uy + kz * uz)
end

-- combined a+b along axis -> 1/k, zero for static/sleeping
local function pair_mass(rax, ray, raz, aim, aIxx, aIyy, aIzz, aIxy, aIxz, aIyz,
                         rbx, rby, rbz, bim, bIxx, bIyy, bIzz, bIxy, bIxz, bIyz, ux, uy, uz)
    local k = effective_mass(rax, ray, raz, aim, aIxx, aIyy, aIzz, aIxy, aIxz, aIyz, ux, uy, uz)
        + effective_mass(rbx, rby, rbz, bim, bIxx, bIyy, bIzz, bIxy, bIxz, bIyz, ux, uy, uz)
    return k > 0 and (1 / k) or 0
end

-- pure angular impulse through the body's live world inverse inertia, im gates
-- sleepers/statics exactly like apply_impulse does
local function apply_angular_only(b, ax, ay, az, im)
    if im == 0 then return end
    b.wx = b.wx + b.wii_xx * ax + b.wii_xy * ay + b.wii_xz * az
    b.wy = b.wy + b.wii_xy * ax + b.wii_yy * ay + b.wii_yz * az
    b.wz = b.wz + b.wii_xz * ax + b.wii_yz * ay + b.wii_zz * az
end

-- angular effective inverse mass about an axis: 1 / (axis' * (Ia + Ib) * axis)
local function axis_angular_inv_mass(ux, uy, uz, sxx, syy, szz, sxy, sxz, syz)
    local k = ux * (sxx * ux + sxy * uy + sxz * uz)
        + uy * (sxy * ux + syy * uy + syz * uz)
        + uz * (sxz * ux + syz * uy + szz * uz)
    return k > 1e-12 and (1 / k) or 0
end

-- rel velocity b minus a at the contact, dotted with axis
local function rel_vel_along(c, ux, uy, uz)
    local a, b = c.ba, c.bb
    -- vela = va + wa x ra, velb = vb + wb x rb
    local vax = a.vx + (a.wy * c.raz - a.wz * c.ray)
    local vay = a.vy + (a.wz * c.rax - a.wx * c.raz)
    local vaz = a.vz + (a.wx * c.ray - a.wy * c.rax)
    local vbx = b.vx + (b.wy * c.rbz - b.wz * c.rby)
    local vby = b.vy + (b.wz * c.rbx - b.wx * c.rbz)
    local vbz = b.vz + (b.wx * c.rby - b.wy * c.rbx)
    return (vbx - vax + (c.surface_x or 0)) * ux
        + (vby - vay + (c.surface_y or 0)) * uy
        + (vbz - vaz + (c.surface_z or 0)) * uz
end

-- a restitution patch has at most four existing normal rows. its four-point
-- matrix can have rank three, a feasible nonsingular active subset still
-- represents every original point, whose complementary residual is checked
local function normal_block_finite(x)
    return type(x)=='number' and x==x and x~=math.huge and x~=-math.huge
end

local function normal_block_angular(c,which,x,y,z)
    local p=which..'_'
    return c[p..'Ixx']*x+c[p..'Ixy']*y+c[p..'Ixz']*z,
        c[p..'Ixy']*x+c[p..'Iyy']*y+c[p..'Iyz']*z,
        c[p..'Ixz']*x+c[p..'Iyz']*y+c[p..'Izz']*z
end

function Solver:_prepare_normal_block(first,last)
    local rows=self._c
    local root=rows[first]
    local w=root._normal_block or {k={},a={{},{},{},{}},rhs={},indices={},scale={},solution={},old={},q={}}
    root._normal_block=w
    w.first,w.last,w.n=first,last,last-first+1
    for i=1,w.n do
        local a=rows[first+i-1];local arx,ary,arz=a.ray*a.nz-a.raz*a.ny,a.raz*a.nx-a.rax*a.nz,a.rax*a.ny-a.ray*a.nx
        local brx,bry,brz=a.rby*a.nz-a.rbz*a.ny,a.rbz*a.nx-a.rbx*a.nz,a.rbx*a.ny-a.rby*a.nx
        local ax,ay,az=normal_block_angular(a,'a',arx,ary,arz)
        local bx,by,bz=normal_block_angular(a,'b',brx,bry,brz)
        for j=1,w.n do
            local b=rows[first+j-1]
            local acx,acy,acz=b.ray*b.nz-b.raz*b.ny,b.raz*b.nx-b.rax*b.nz,b.rax*b.ny-b.ray*b.nx
            local bcx,bcy,bcz=b.rby*b.nz-b.rbz*b.ny,b.rbz*b.nx-b.rbx*b.nz,b.rbx*b.ny-b.rby*b.nx
            local k=(a.a_im+a.b_im)*(a.nx*b.nx+a.ny*b.ny+a.nz*b.nz)
                +ax*acx+ay*acy+az*acz+bx*bcx+by*bcy+bz*bcz
            if not normal_block_finite(k) then return end
            w.k[(i-1)*w.n+j]=k
        end
    end
    for i=1,w.n do
        local k=w.k[(i-1)*w.n+i]
        if k<=0 then return end
        w.scale[i]=sqrt(k)
    end
    root.normal_block_end=last
end

-- Pivoted solve of one normalized active submatrix. all scratch is bounded
-- and pooled on the first prepared row, it owns numbers, never extra bodies
local function normal_block_subset(w,mask,count)
    local indices,n=w.indices,0
    for i=1,w.n do if math.floor(mask/2^(i-1))%2==1 then n=n+1;indices[n]=i end end
    if n~=count then return false end
    for i=1,n do
        local ii=indices[i]
        w.rhs[i]=-w.q[ii]/w.scale[ii]
        for j=1,n do local jj=indices[j]
            w.a[i][j]=w.k[(ii-1)*w.n+jj]/(w.scale[ii]*w.scale[jj])
        end
    end
    for i=1,n do
        local pivot=i
        for j=i+1,n do if abs(w.a[j][i])>abs(w.a[pivot][i]) then pivot=j end end
        if not normal_block_finite(w.a[pivot][i]) or abs(w.a[pivot][i])<=1e-12 then return false end
        if pivot~=i then w.a[i],w.a[pivot]=w.a[pivot],w.a[i];w.rhs[i],w.rhs[pivot]=w.rhs[pivot],w.rhs[i] end
        for j=i+1,n do
            local f=w.a[j][i]/w.a[i][i]
            for k=i+1,n do w.a[j][k]=w.a[j][k]-f*w.a[i][k] end
            w.rhs[j]=w.rhs[j]-f*w.rhs[i]
        end
    end
    for i=n,1,-1 do
        local v=w.rhs[i]
        for j=i+1,n do v=v-w.a[i][j]*w.rhs[j] end
        w.rhs[i]=v/w.a[i][i]
    end
    for i=1,w.n do w.solution[i]=0 end
    for i=1,n do
        local ii=indices[i];local p=w.rhs[i]/w.scale[ii]
        if not normal_block_finite(p) or p < -w.tolerance or p>MAX_IMPULSE then return false end
        w.solution[ii]=max(0,p)
    end
    for i=1,w.n do
        local residual=w.q[i]
        for j=1,w.n do residual=residual+w.k[(i-1)*w.n+j]*w.solution[j] end
        if not normal_block_finite(residual) or residual < -w.tolerance
            or (w.solution[i]>0 and abs(residual)>w.tolerance) then return false end
    end
    return true
end

-- nil requests untouched scalar fallback. no body or accumulated impulse is
-- changed until a finite nonnegative solution satisfies every original row
function Solver:_solve_normal_block(first,last)
    local w=self._c[first]._normal_block
    if self._c[first].normal_block_end~=last or not w or w.first~=first or w.last~=last then return nil end
    local scale=1
    for i=1,w.n do
        local c=self._c[first+i-1];local vn=rel_vel_along(c,c.nx,c.ny,c.nz)
        w.old[i]=c.pn;w.q[i]=vn-c.rest_target
        if not normal_block_finite(vn) or not normal_block_finite(c.rest_target)
            or not normal_block_finite(c.pn) then return nil end
        scale=max(scale,abs(vn),abs(c.rest_target))
    end
    for i=1,w.n do for j=1,w.n do
        w.q[i]=w.q[i]-w.k[(i-1)*w.n+j]*w.old[j]
    end end
    for i=1,w.n do if not normal_block_finite(w.q[i]) then return nil end;scale=max(scale,abs(w.q[i])) end
    w.tolerance=1e-9*scale
    local solved=false
    local sum=w._support_sum
    if not sum then sum={};w._support_sum=sum end
    for count=w.n,0,-1 do
        local feasible=0
        for i=1,w.n do sum[i]=0 end
        for mask=0,2^w.n-1 do
            if normal_block_subset(w,mask,count) then
                feasible=feasible+1
                for i=1,w.n do sum[i]=sum[i]+w.solution[i] end
            end
        end
        if feasible>0 then
            for i=1,w.n do
                local p=sum[i]/feasible
                if not normal_block_finite(p) or p<0 or p>MAX_IMPULSE then return nil end
                w.solution[i]=p
            end
            solved=true;break
        end
    end
    if not solved then return nil end
    -- Feasible PSD-LCP solutions have a convex allocation set. Recheck the
    -- average against EVERY original row before any body/impulse mutation
    for i=1,w.n do
        local residual=w.q[i]
        for j=1,w.n do residual=residual+w.k[(i-1)*w.n+j]*w.solution[j] end
        if not normal_block_finite(residual) or residual < -w.tolerance
            or (w.solution[i]>0 and abs(residual)>w.tolerance) then return nil end
    end
    local delta=0
    for i=1,w.n do
        local c=self._c[first+i-1];local d=w.solution[i]-w.old[i]
        c.pn=w.solution[i];delta=max(delta,abs(d))
        if d~=0 then
            apply_impulse(c.bb,d*c.nx,d*c.ny,d*c.nz,c.rbx,c.rby,c.rbz,c.b_im,c.b_Ixx,c.b_Iyy,c.b_Izz,c.b_Ixy,c.b_Ixz,c.b_Iyz)
            apply_impulse(c.ba,-d*c.nx,-d*c.ny,-d*c.nz,c.rax,c.ray,c.raz,c.a_im,c.a_Ixx,c.a_Iyy,c.a_Izz,c.a_Ixy,c.a_Ixz,c.a_Iyz)
        end
    end
    return delta
end

-- Off-diagonal term of the 2D tangent effective-mass matrix. Translation
-- contributes zero because the tangents are orthogonal
local function tangent_coupling(rx, ry, rz, Ixx, Iyy, Izz, Ixy, Ixz, Iyz,
        ux, uy, uz, vx, vy, vz)
    local ax, ay, az = ry*uz-rz*uy, rz*ux-rx*uz, rx*uy-ry*ux
    local bx, by, bz = ry*vz-rz*vy, rz*vx-rx*vz, rx*vy-ry*vx
    return ax*(Ixx*bx+Ixy*by+Ixz*bz) + ay*(Ixy*bx+Iyy*by+Iyz*bz)
        + az*(Ixz*bx+Iyz*by+Izz*bz)
end

-- Anchored conveyor velocities belong to individual parts, even when the
-- static broadphase merges an entire room into one assembly
local function surface_delta(body, view, world, dt)
    local part = body.is_static and view and view._part
    if not part then return 0, 0, 0 end
    -- Callback-authored anchored translation has real surface motion even
    -- when its public velocity remains zero. Feed the current interval to
    -- ordinary contacts too, so slow overlap is pushed rather than repaired
    -- as a stationary penetration. the CCD map is cleared after this step;
    -- conveyors and out-of-step teleports retain their authored semantics
    local motions=world and world._ccd_static_motions
    local motion=motions and motions[body.id]
    if motion and motion.view==view and not motion.rotating and dt and dt>0
        and motion.dx*motion.dx+motion.dy*motion.dy+motion.dz*motion.dz>1e-16 then
        return motion.dx/dt-body.vx,motion.dy/dt-body.vy,motion.dz/dt-body.vz
    end
    local v = part.AssemblyLinearVelocity or part.Velocity
    return ((v and (v.x or v.X)) or 0) - body.vx,
        ((v and (v.y or v.Y)) or 0) - body.vy,
        ((v and (v.z or v.Z)) or 0) - body.vz
end

local function scratch(self, i)
    local c = self._c[i]
    if not c then
        c = {}
        self._c[i] = c
    end
    return c
end

local function fscratch(self, i)
    local f = self._f[i]
    if not f then
        f = {}
        self._f[i] = f
    end
    return f
end

-- collect active contacts into pooled scratch: 1 normal constraint/point + 1 centroid friction/manifold
function Solver:_prepare(cache, step_index, dt, gravity, world)
    local n  = 0   -- normal contact points
    local nf = 0   -- friction constraints (one per manifold)
    local restitution_threshold = max(RESTITUTION_FLOOR, 2 * (gravity or 0) * dt)
    -- velocity-bias factor: beta/dt like Box2D, using the shared baumgarte + slop tuning
    local slop_v = self.slop
    local bias_scale = (dt and dt > 0) and (self.baumgarte / dt) or 0
    -- Roblox wakes touching assemblies at normal movement speeds. Subtract
    -- this step's gravity later so a resting support does not wake every frame
    local wake_thr = self.wake_speed_threshold
    if wake_thr <= 0 then
        wake_thr = 1
    end

    -- dense list = numeric loop, hash walk fallback when theres no list
    local alist = cache.active_list
    local acount
    if alist then
        acount = cache.active_n or 0
    else
        alist = self._prepare_fallback_list or {}
        self._prepare_fallback_list = alist
        acount = 0
        for _key, m in pairs(cache.manifolds) do
            acount = acount + 1
            alist[acount] = m
        end
        for i = #alist, acount + 1, -1 do alist[i] = nil end
    end
    -- wake before preparing ANY effective masses. Deferring this until after
    -- solve discarded the first impact's momentum and cached immovable rows
    -- only current local contacts are visited, resting neighbours stay asleep
    local woke = false
    if world then
        for mi=1,acount do
            local m=alist[mi]
            local a,b=m.body_a,m.body_b
            if not m._dead and m.last_step==step_index and a and b
                and ((a.sleeping and not a.is_static) or (b.sleeping and not b.is_static)) then
                local sax,say,saz=surface_delta(a,m.view_a,world,dt)
                local sbx,sby,sbz=surface_delta(b,m.view_b,world,dt)
                local gravity_y=(b.sleeping and 0 or (b._step_gravity_vy or 0))
                    -(a.sleeping and 0 or (a._step_gravity_vy or 0))
                for _,p in ipairs(m.points or {}) do
                    local ax,ay,az=p.px-a.com_x,p.py-a.com_y,p.pz-a.com_z
                    local bx,by,bz=p.px-b.com_x,p.py-b.com_y,p.pz-b.com_z
                    local x=b.vx+b.wy*bz-b.wz*by-a.vx-a.wy*az+a.wz*ay+sbx-sax
                    local y=b.vy+b.wz*bx-b.wx*bz-a.vy-a.wz*ax+a.wx*az+sby-say-gravity_y
                    local z=b.vz+b.wx*by-b.wy*bx-a.vz-a.wx*ay+a.wy*ax+sbz-saz
                    local vn=x*m.normal_x+y*m.normal_y+z*m.normal_z
                    local tangent2=math.max(0,x*x+y*y+z*z-vn*vn)
                    if vn < -wake_thr or (vn<=0 and tangent2>wake_thr*wake_thr) then
                        if a.sleeping and not a.is_static then
                            world:wake_body(a,true);a._rope_wake_pending=#world.ropes>0 or nil;woke=true
                        end
                        if b.sleeping and not b.is_static then
                            world:wake_body(b,true);b._rope_wake_pending=#world.ropes>0 or nil;woke=true
                        end
                        break
                    end
                end
            end
        end
        if woke then Rope.wake(world,dt,true) end
    end
    for mi = 1, acount do
        local m = alist[mi]
        if not m._dead and (m.last_step or 0) == step_index then
            local a, b = m.body_a, m.body_b
            if a and b then
                local sax, say, saz = surface_delta(a, m.view_a, world, dt)
                local sbx, sby, sbz = surface_delta(b, m.view_b, world, dt)
                local surface_x, surface_y, surface_z = sbx - sax, sby - say, sbz - saz
                -- sleeper = immovable support (mass/inertia 0, real inv_mass kept for warm-start), at most one of a/b sleeps
                local a_sleep = a.sleeping == true and not a.is_static
                local b_sleep = b.sleeping == true and not b.is_static
                local a_im  = a_sleep and 0 or a.inv_mass
                local b_im  = b_sleep and 0 or b.inv_mass
                -- world-frame inverse inertia, once/step, or rotated parts respond wrong
                if a._wi_step ~= step_index then a:update_world_inertia(); a._wi_step = step_index end
                if b._wi_step ~= step_index then b:update_world_inertia(); b._wi_step = step_index end
                local a_Ixx = a_sleep and 0 or a.wii_xx
                local a_Iyy = a_sleep and 0 or a.wii_yy
                local a_Izz = a_sleep and 0 or a.wii_zz
                local a_Ixy = a_sleep and 0 or a.wii_xy
                local a_Ixz = a_sleep and 0 or a.wii_xz
                local a_Iyz = a_sleep and 0 or a.wii_yz
                local b_Ixx = b_sleep and 0 or b.wii_xx
                local b_Iyy = b_sleep and 0 or b.wii_yy
                local b_Izz = b_sleep and 0 or b.wii_zz
                local b_Ixy = b_sleep and 0 or b.wii_xy
                local b_Ixz = b_sleep and 0 or b.wii_xz
                local b_Iyz = b_sleep and 0 or b.wii_yz
                local points = m.points
                local np = points and #points or 0
                local nx, ny, nz = m.normal_x, m.normal_y, m.normal_z
                local nlen2 = nx * nx + ny * ny + nz * nz
                if (a_im + b_im) > 0 and np > 0 and nlen2 > 1e-12 then
                    -- shared per-manifold geometry, once for all points
                    if abs(nlen2 - 1) > 1e-6 then
                        local inv = 1 / sqrt(nlen2)
                        nx, ny, nz = nx * inv, ny * inv, nz * inv
                    end

                    -- tangent basis: n cross the world axis least aligned to it
                    local ax, ay, az
                    local axn, ayn, azn = abs(nx), abs(ny), abs(nz)
                    if axn <= ayn and axn <= azn then
                        ax, ay, az = 1, 0, 0
                    elseif ayn <= azn then
                        ax, ay, az = 0, 1, 0
                    else
                        ax, ay, az = 0, 0, 1
                    end
                    local t1x = ay * nz - az * ny
                    local t1y = az * nx - ax * nz
                    local t1z = ax * ny - ay * nx
                    local tl2 = t1x * t1x + t1y * t1y + t1z * t1z
                    if tl2 > 1e-12 then
                        local inv = 1 / sqrt(tl2)
                        t1x, t1y, t1z = t1x * inv, t1y * inv, t1z * inv
                    else
                        t1x, t1y, t1z = 1, 0, 0
                    end
                    local t2x = ny * t1z - nz * t1y
                    local t2y = nz * t1x - nx * t1z
                    local t2z = nx * t1y - ny * t1x

                    local friction   = m.friction or 0
                    local elasticity = m.elasticity or 0
                    -- Gravity integrated earlier in this step has not acted
                    -- across the contact yet. Restitution measures the
                    -- approach before it, otherwise every bounce gains g*dt
                    local step_gravity_rel = (b_sleep and 0 or (b._step_gravity_vy or 0))
                        - (a_sleep and 0 or (a._step_gravity_vy or 0))

                    -- one push-only normal constraint per manifold point
                    local cstart = n + 1
                    local impact_block = false
                    local sx, sy, sz = 0, 0, 0   -- centroid accumulator
                    for pi = 1, np do
                        local pt = points[pi]
                        n = n + 1
                        local c = scratch(self, n)
                        c.m, c.pt = m, pt
                        c.ba, c.bb = a, b
                        c.surface_x, c.surface_y, c.surface_z = surface_x, surface_y, surface_z
                        c.np = np
                        c.normal_block_end = nil
                        c.nx, c.ny, c.nz = nx, ny, nz
                        -- sleeper-aware inv mass + world inertia
                        c.a_im = a_im
                        c.a_Ixx, c.a_Iyy, c.a_Izz = a_Ixx, a_Iyy, a_Izz
                        c.a_Ixy, c.a_Ixz, c.a_Iyz = a_Ixy, a_Ixz, a_Iyz
                        c.b_im = b_im
                        c.b_Ixx, c.b_Iyy, c.b_Izz = b_Ixx, b_Iyy, b_Izz
                        c.b_Ixy, c.b_Ixz, c.b_Iyz = b_Ixy, b_Ixz, b_Iyz

                        local rax = pt.px - a.com_x
                        local ray = pt.py - a.com_y
                        local raz = pt.pz - a.com_z
                        local rbx = pt.px - b.com_x
                        local rby = pt.py - b.com_y
                        local rbz = pt.pz - b.com_z
                        c.rax, c.ray, c.raz = rax, ray, raz
                        c.rbx, c.rby, c.rbz = rbx, rby, rbz

                        c.n_mass = pair_mass(
                            rax, ray, raz, a_im, a_Ixx, a_Iyy, a_Izz, a_Ixy, a_Ixz, a_Iyz,
                            rbx, rby, rbz, b_im, b_Ixx, b_Iyy, b_Izz, b_Ixy, b_Ixz, b_Iyz,
                            nx, ny, nz)
                        local pen = pt.penetration or 0
                        c.penetration = pen
                        c.corrected   = 0

                        -- restitution target uses the pre-warmstart closing velocity
                        local vn_approach = rel_vel_along(c, nx, ny, nz) - step_gravity_rel * ny
                        local target = 0
                        local impact = vn_approach < -restitution_threshold
                        if impact then
                            target = -elasticity * vn_approach
                            if elasticity > 0 then impact_block = true end
                        elseif pen > slop_v then
                            -- velocity-level Baumgarte: feeds penetration into the warm-started
                            -- impulse chain, which is what actually holds a tall column. NGS
                            -- alone recovers positions but the accumulated normal impulses sag
                            -- under PGS at high gravity (measured: 5-box tower sank + toppled)
                            -- Impacts skip it: their penetration is detection latency, and a
                            -- bias there launched inelastic landings upward. Capped so deep
                            -- spawn overlap cannot launch bodies
                            local bias = bias_scale * (pen - slop_v)
                            if bias > 4 then bias = 4 end
                            target = bias
                        end
                        c.rest_target = target
                        c.separation = 0
                        c.pn = pt.normal_impulse or 0
                        sx, sy, sz = sx + pt.px, sy + pt.py, sz + pt.pz
                    end

                    if impact_block and np >= 2 and np <= 4 then self:_prepare_normal_block(cstart,n) end

                    -- one friction constraint per manifold, at the contact centroid
                    if friction > 0 then
                        nf = nf + 1
                        local f = fscratch(self, nf)
                        f.m = m
                        f.ba, f.bb = a, b
                        f.surface_x, f.surface_y, f.surface_z = surface_x, surface_y, surface_z
                        f.t1x, f.t1y, f.t1z = t1x, t1y, t1z
                        f.t2x, f.t2y, f.t2z = t2x, t2y, t2z
                        f.nx, f.ny, f.nz = nx, ny, nz
                        f.cstart, f.cend = cstart, n
                        f.friction = friction

                        -- Contact friction acts at the patch centroid. Applying it
                        -- at the COM prevented rolling entirely and turned a
                        -- force-driven sphere into a permanently sliding block
                        local cx, cy, cz = sx / np, sy / np, sz / np
                        f.rax, f.ray, f.raz = cx - a.com_x, cy - a.com_y, cz - a.com_z
                        f.rbx, f.rby, f.rbz = cx - b.com_x, cy - b.com_y, cz - b.com_z
                        f.a_im = a_im
                        f.b_im = b_im
                        f.a_Ixx, f.a_Iyy, f.a_Izz = a_Ixx, a_Iyy, a_Izz
                        f.a_Ixy, f.a_Ixz, f.a_Iyz = a_Ixy, a_Ixz, a_Iyz
                        f.b_Ixx, f.b_Iyy, f.b_Izz = b_Ixx, b_Iyy, b_Izz
                        f.b_Ixy, f.b_Ixz, f.b_Iyz = b_Ixy, b_Ixz, b_Iyz
                        f.t1_mass = pair_mass(f.rax, f.ray, f.raz, a_im, a_Ixx, a_Iyy, a_Izz, a_Ixy, a_Ixz, a_Iyz,
                            f.rbx, f.rby, f.rbz, b_im, b_Ixx, b_Iyy, b_Izz, b_Ixy, b_Ixz, b_Iyz, t1x, t1y, t1z)
                        f.t2_mass = pair_mass(f.rax, f.ray, f.raz, a_im, a_Ixx, a_Iyy, a_Izz, a_Ixy, a_Ixz, a_Iyz,
                            f.rbx, f.rby, f.rbz, b_im, b_Ixx, b_Iyy, b_Izz, b_Ixy, b_Ixz, b_Iyz, t2x, t2y, t2z)
                        local k12 = tangent_coupling(f.rax,f.ray,f.raz,a_Ixx,a_Iyy,a_Izz,a_Ixy,a_Ixz,a_Iyz,
                            t1x,t1y,t1z,t2x,t2y,t2z)
                            + tangent_coupling(f.rbx,f.rby,f.rbz,b_Ixx,b_Iyy,b_Izz,b_Ixy,b_Ixz,b_Iyz,
                            t1x,t1y,t1z,t2x,t2y,t2z)
                        local k11, k22 = 1/f.t1_mass, 1/f.t2_mass
                        local det = k11*k22-k12*k12
                        if det > 1e-12 then
                            f.tm11, f.tm12, f.tm22 = k22/det, -k12/det, k11/det
                        else
                            f.tm11, f.tm12, f.tm22 = f.t1_mass, 0, f.t2_mass
                        end
                        f.jt1 = m.fric_jt1 or 0
                        f.jt2 = m.fric_jt2 or 0
                        -- the least-aligned-axis tangent basis can switch by
                        -- 90 degrees under tiny normal changes. Warm impulses
                        -- are world vectors, not coordinates in the new basis
                        if m.fric_px then
                            f.jt1 = m.fric_px*t1x + m.fric_py*t1y + m.fric_pz*t1z
                            f.jt2 = m.fric_px*t2x + m.fric_py*t2y + m.fric_pz*t2z
                        end

                        -- a finite patch resists twist about its normal. Tipping
                        -- is already resisted by the normal rows at each contact;
                        -- adding tangent-axis torque here glued bricks to the floor
                        if np >= 2 then
                            local cx, cy, cz = sx / np, sy / np, sz / np
                            local lever = 0
                            for pi2 = 1, np do
                                local pt2 = points[pi2]
                                local ex = pt2.px - cx
                                local ey = pt2.py - cy
                                local ez = pt2.pz - cz
                                local d2 = ex * ex + ey * ey + ez * ez
                                if d2 > lever then lever = d2 end
                            end
                            f.lever = sqrt(lever)
                            -- angular effective mass about each axis: axis' * (Ia + Ib) * axis
                            local sxx = a_Ixx + b_Ixx
                            local syy = a_Iyy + b_Iyy
                            local szz = a_Izz + b_Izz
                            local sxy = a_Ixy + b_Ixy
                            local sxz = a_Ixz + b_Ixz
                            local syz = a_Iyz + b_Iyz
                            f.wn_mass = axis_angular_inv_mass(nx, ny, nz, sxx, syy, szz, sxy, sxz, syz)
                            f.w1_mass, f.w2_mass, f.jw1, f.jw2 = 0, 0, 0, 0
                            f.jwn = m.fric_jwn or 0
                            if m.fric_wx then
                                f.jwn = m.fric_wx*nx + m.fric_wy*ny + m.fric_wz*nz
                            end
                        else
                            f.lever = 0
                            f.w1_mass, f.w2_mass, f.wn_mass = 0, 0, 0
                            f.jw1, f.jw2, f.jwn = 0, 0, 0
                        end
                    else
                        m.fric_jt1, m.fric_jt2 = 0, 0
                        m.fric_jw1, m.fric_jw2, m.fric_jwn = 0, 0, 0
                        m.fric_px, m.fric_py, m.fric_pz = 0, 0, 0
                        m.fric_wx, m.fric_wy, m.fric_wz = 0, 0, 0
                    end
                end
            end
        end
    end

    self._count  = n
    self._fcount = nf
    return n
end

-- resume near last frame's solution: fewer iters, less jitter
function Solver:_warm_start()
    local list = self._c
    for i = 1, self._count do
        local c = list[i]
        local px, py, pz = c.pn * c.nx, c.pn * c.ny, c.pn * c.nz
        apply_impulse(c.bb, px, py, pz, c.rbx, c.rby, c.rbz,
            c.b_im, c.b_Ixx, c.b_Iyy, c.b_Izz, c.b_Ixy, c.b_Ixz, c.b_Iyz)
        apply_impulse(c.ba, -px, -py, -pz, c.rax, c.ray, c.raz,
            c.a_im, c.a_Ixx, c.a_Iyy, c.a_Izz, c.a_Ixy, c.a_Ixz, c.a_Iyz)
    end
    local flist = self._f
    for i = 1, self._fcount do
        local f = flist[i]
        local px = f.jt1 * f.t1x + f.jt2 * f.t2x
        local py = f.jt1 * f.t1y + f.jt2 * f.t2y
        local pz = f.jt1 * f.t1z + f.jt2 * f.t2z
        apply_impulse(f.bb, px, py, pz, f.rbx, f.rby, f.rbz, f.b_im, f.b_Ixx, f.b_Iyy, f.b_Izz, f.b_Ixy, f.b_Ixz, f.b_Iyz)
        apply_impulse(f.ba, -px, -py, -pz, f.rax, f.ray, f.raz, f.a_im, f.a_Ixx, f.a_Iyy, f.a_Izz, f.a_Ixy, f.a_Ixz, f.a_Iyz)
        if f.lever > 0 then
            local ax = f.jw1 * f.t1x + f.jw2 * f.t2x + f.jwn * f.nx
            local ay = f.jw1 * f.t1y + f.jw2 * f.t2y + f.jwn * f.ny
            local az = f.jw1 * f.t1z + f.jw2 * f.t2z + f.jwn * f.nz
            apply_angular_only(f.bb, ax, ay, az, f.b_im)
            apply_angular_only(f.ba, -ax, -ay, -az, f.a_im)
        end
    end
end

-- one sweep: push-only normal + restitution per point, then centroid friction (coulomb-clamped)
function Solver:_solve_normal_velocity()
    local list = self._c
    -- largest impulse delta, so the caller can early-out once converged
    local max_delta = 0
    local i = 1
    while i <= self._count do
        local block_end = list[i].normal_block_end
        local block_delta = block_end and self:_solve_normal_block(i,block_end)
        if block_delta ~= nil and block_delta ~= false then
            max_delta = max(max_delta,block_delta)
            i = block_end + 1
        else
        local c = list[i]
        local nx, ny, nz = c.nx, c.ny, c.nz
        local vn = rel_vel_along(c, nx, ny, nz)
        local lambda = -c.n_mass * (vn - c.rest_target)
        local old_pn = c.pn
        local new_pn = old_pn + lambda
        if new_pn < 0 then new_pn = 0 end
        -- degenerate mass cant inject inf/nan
        new_pn = clamp_finite(new_pn, MAX_IMPULSE)
        local d = new_pn - old_pn
        c.pn = new_pn
        if d ~= 0 then
            if d < 0 then
                if -d > max_delta then max_delta = -d end
            elseif d > max_delta then
                max_delta = d
            end
            apply_impulse(c.bb,d*nx,d*ny,d*nz,c.rbx,c.rby,c.rbz,c.b_im,c.b_Ixx,c.b_Iyy,c.b_Izz,c.b_Ixy,c.b_Ixz,c.b_Iyz)
            apply_impulse(c.ba,-d*nx,-d*ny,-d*nz,c.rax,c.ray,c.raz,c.a_im,c.a_Ixx,c.a_Iyy,c.a_Izz,c.a_Ixy,c.a_Ixz,c.a_Iyz)
        end
            i = i + 1
        end
    end

    return max_delta
end

function Solver:_solve_friction_velocity()
    local list,max_delta=self._c,0
    for i = 1, self._fcount do
        local f = self._f[i]
        local pn_sum = 0
        for k = f.cstart, f.cend do pn_sum = pn_sum + list[k].pn end
        local fmax = f.friction * pn_sum
        local vt1 = rel_vel_along(f, f.t1x, f.t1y, f.t1z)
        local vt2 = rel_vel_along(f, f.t2x, f.t2y, f.t2z)
        local nj1 = f.jt1 - f.tm11*vt1 - f.tm12*vt2
        local nj2 = f.jt2 - f.tm12*vt1 - f.tm22*vt2
        -- project the combined impulse onto the Coulomb disk. Independent axis
        -- clamps made diagonal dragging up to sqrt(2) times harder
        local length2 = nj1*nj1 + nj2*nj2
        if length2 > fmax*fmax then
            local scale = fmax / sqrt(length2)
            nj1, nj2 = nj1*scale, nj2*scale
        end
        local d1, d2 = nj1-f.jt1, nj2-f.jt2
        f.jt1, f.jt2 = nj1, nj2
        -- apply negative deltas even at zero normal load: a rope lifting the
        -- part must undo friction already applied by this step's warm start
        if d1 ~= 0 or d2 ~= 0 then
            local x,y,z=d1*f.t1x+d2*f.t2x,d1*f.t1y+d2*f.t2y,d1*f.t1z+d2*f.t2z
            apply_impulse(f.bb,x,y,z,f.rbx,f.rby,f.rbz,f.b_im,f.b_Ixx,f.b_Iyy,f.b_Izz,f.b_Ixy,f.b_Ixz,f.b_Iyz)
            apply_impulse(f.ba,-x,-y,-z,f.rax,f.ray,f.raz,f.a_im,f.a_Ixx,f.a_Iyy,f.a_Izz,f.a_Ixy,f.a_Ixz,f.a_Iyz)
            max_delta=max(max_delta,abs(d1),abs(d2))
        end
        if f.lever > 0 then
            local a,b=f.ba,f.bb
            local wn=(b.wx-a.wx)*f.nx+(b.wy-a.wy)*f.ny+(b.wz-a.wz)*f.nz
            local limit=fmax*f.lever
            local next_j=math.min(limit,max(-limit,f.jwn-f.wn_mass*wn))
            local delta=next_j-f.jwn; f.jwn=next_j
            if delta ~= 0 then
                local x,y,z=delta*f.nx,delta*f.ny,delta*f.nz
                apply_angular_only(b,x,y,z,f.b_im)
                apply_angular_only(a,-x,-y,-z,f.a_im)
                max_delta=max(max_delta,abs(delta))
            end
        end
    end
    return max_delta
end

-- keep hot normal/friction loops small enough for independent JIT traces
function Solver:_solve_velocity_iteration()
    return max(self:_solve_normal_velocity(),self:_solve_friction_velocity())
end

-- persist impulses for next frame's warm start
function Solver:_writeback_impulses()
    local list = self._c
    for i = 1, self._count do
        local c = list[i]
        local pt = c.pt
        pt.normal_impulse    = c.pn
        pt.tangent_impulse_x = 0   -- friction is per-manifold, per-point tangents unused
        pt.tangent_impulse_y = 0
    end
    local flist = self._f
    for i = 1, self._fcount do
        local f = flist[i]
        local m = f.m
        m.fric_jt1 = f.jt1
        m.fric_jt2 = f.jt2
        m.fric_px = f.jt1*f.t1x + f.jt2*f.t2x
        m.fric_py = f.jt1*f.t1y + f.jt2*f.t2y
        m.fric_pz = f.jt1*f.t1z + f.jt2*f.t2z
        m.fric_wx = f.jw1*f.t1x + f.jw2*f.t2x + f.jwn*f.nx
        m.fric_wy = f.jw1*f.t1y + f.jw2*f.t2y + f.jwn*f.ny
        m.fric_wz = f.jw1*f.t1z + f.jw2*f.t2z + f.jwn*f.nz
        m.fric_jw1 = f.jw1
        m.fric_jw2 = f.jw2
        m.fric_jwn = f.jwn
    end
end

-- ngs angular term, cap avoids over-rotating a low-inertia body
local function apply_pseudo_rotation(b, wx, wy, wz)
    local m2 = wx * wx + wy * wy + wz * wz
    if m2 > MAX_ANGULAR_CORRECTION * MAX_ANGULAR_CORRECTION then
        local s = MAX_ANGULAR_CORRECTION / sqrt(m2)
        wx, wy, wz = wx * s, wy * s, wz * s
    end
    b.qw, b.qx, b.qy, b.qz = Integrate.quat_integrate(b.qw, b.qx, b.qy, b.qz, wx, wy, wz, 1)
end

-- ngs/split-impulse: pseudo-impulse removes penetration, the corrected accumulator makes iters converge
-- angular term un-tilts (symmetric cancels, tilted sums to flat), push divided by point count or a coplanar manifold over-pushes and disintegrates stacks
function Solver:_solve_position_iteration()
    local list = self._c
    local beta = self.baumgarte
    -- shallow penetration is owned by the velocity-level bias (see _prepare), NGS
    -- correcting it too double-pushes and pogo-bounces resting contacts apart
    local slop = ANGULAR_NGS_MIN_PEN
    local pushed = 0 -- 0 = converged, caller stops
    for i = 1, self._count do
        local c = list[i]
        local remaining = c.penetration - c.corrected - (c.separation or 0)
        if remaining > slop then
            pushed = pushed + 1
            local a, b = c.ba, c.bb
            -- inv mass 0 for a sleeping support: only the active body climbs out
            local a_im, b_im = c.a_im, c.b_im
            if (a_im > 0 or b_im > 0) and c.n_mass > 0 then
                local push = beta * (remaining - slop) / (c.np or 1)
                -- cap per iter: deep penetration climbs out over several steps instead of teleporting
                if push > MAX_CORRECTION then push = MAX_CORRECTION end
                local nx, ny, nz = c.nx, c.ny, c.nz
                if remaining > ANGULAR_NGS_MIN_PEN then
                    -- deep: full pseudo-impulse, un-tilts toward flat, n_mass includes angular k for an exact push
                    local j = push * c.n_mass
                    local jx, jy, jz = j * nx, j * ny, j * nz
                    if b_im > 0 then
                        b.com_x = clamp_finite(b.com_x + b_im * jx, 1e9)
                        b.com_y = clamp_finite(b.com_y + b_im * jy, 1e9)
                        b.com_z = clamp_finite(b.com_z + b_im * jz, 1e9)
                        local tx = c.rby * jz - c.rbz * jy
                        local ty = c.rbz * jx - c.rbx * jz
                        local tz = c.rbx * jy - c.rby * jx
                        apply_pseudo_rotation(b,
                            c.b_Ixx * tx + c.b_Ixy * ty + c.b_Ixz * tz,
                            c.b_Ixy * tx + c.b_Iyy * ty + c.b_Iyz * tz,
                            c.b_Ixz * tx + c.b_Iyz * ty + c.b_Izz * tz)
                    end
                    if a_im > 0 then
                        a.com_x = clamp_finite(a.com_x - a_im * jx, 1e9)
                        a.com_y = clamp_finite(a.com_y - a_im * jy, 1e9)
                        a.com_z = clamp_finite(a.com_z - a_im * jz, 1e9)
                        local tx = c.raz * jy - c.ray * jz
                        local ty = c.rax * jz - c.raz * jx
                        local tz = c.ray * jx - c.rax * jy
                        apply_pseudo_rotation(a,
                            c.a_Ixx * tx + c.a_Ixy * ty + c.a_Ixz * tz,
                            c.a_Ixy * tx + c.a_Iyy * ty + c.a_Iyz * tz,
                            c.a_Ixz * tx + c.a_Iyz * ty + c.a_Izz * tz)
                    end
                else
                    -- shallow/resting: linear-only, no rotation drift on piled parts
                    local total = a_im + b_im
                    local move_a = push * (a_im / total)
                    local move_b = push * (b_im / total)
                    if move_b ~= 0 then
                        b.com_x = clamp_finite(b.com_x + nx * move_b, 1e9)
                        b.com_y = clamp_finite(b.com_y + ny * move_b, 1e9)
                        b.com_z = clamp_finite(b.com_z + nz * move_b, 1e9)
                    end
                    if move_a ~= 0 then
                        a.com_x = clamp_finite(a.com_x - nx * move_a, 1e9)
                        a.com_y = clamp_finite(a.com_y - ny * move_a, 1e9)
                        a.com_z = clamp_finite(a.com_z - nz * move_a, 1e9)
                    end
                end
                c.corrected = c.corrected + push
            end
        end
    end
    return pushed
end

-- returns (contacts, velocity_iters, position_iters), 0,0,0 if nothing
-- Positive distance impulses pull A toward B. Ropes are unilateral, rods also
-- resist compression. only continuously active rows retain warm-start impulses
local function rope_mass(r)
    local a,b=r.ba,r.bb
    a:update_world_inertia();b:update_world_inertia()
    local ai=(not a.sleeping) and a.inv_mass or 0
    local bi=(not b.sleeping) and b.inv_mass or 0
    r.aim,r.bim=ai,bi
    local ka=ai>0 and effective_mass(r.rax,r.ray,r.raz,ai,a.wii_xx,a.wii_yy,a.wii_zz,a.wii_xy,a.wii_xz,a.wii_yz,r.nx,r.ny,r.nz) or 0
    local kb=bi>0 and effective_mass(r.rbx,r.rby,r.rbz,bi,b.wii_xx,b.wii_yy,b.wii_zz,b.wii_xy,b.wii_xz,b.wii_yz,r.nx,r.ny,r.nz) or 0
    r.mass=ka+kb>1e-12 and 1/(ka+kb) or 0
end
local function rope_impulse(r,j)
    local a,b=r.ba,r.bb;local x,y,z=r.nx*j,r.ny*j,r.nz*j
    apply_impulse(a,x,y,z,r.rax,r.ray,r.raz,r.aim,a.wii_xx,a.wii_yy,a.wii_zz,a.wii_xy,a.wii_xz,a.wii_yz)
    apply_impulse(b,-x,-y,-z,r.rbx,r.rby,r.rbz,r.bim,b.wii_xx,b.wii_yy,b.wii_zz,b.wii_xy,b.wii_xz,b.wii_yz)
end
local function point_mass_column(b,im,rx,ry,rz,x,y,z)
    if im==0 then return 0,0,0 end
    local tx,ty,tz=ry*z-rz*y,rz*x-rx*z,rx*y-ry*x
    local ax=b.wii_xx*tx+b.wii_xy*ty+b.wii_xz*tz
    local ay=b.wii_xy*tx+b.wii_yy*ty+b.wii_yz*tz
    local az=b.wii_xz*tx+b.wii_yz*ty+b.wii_zz*tz
    return im*x-ry*az+rz*ay,im*y-rz*ax+rx*az,im*z-rx*ay+ry*ax
end
local function point_mass(r)
    local a,b=r.ba,r.bb
    a:update_world_inertia();b:update_world_inertia()
    local ai=not a.sleeping and a.inv_mass or 0;local bi=not b.sleeping and b.inv_mass or 0
    r.aim,r.bim=ai,bi
    local xx,xy,xz=point_mass_column(a,ai,r.rax,r.ray,r.raz,1,0,0)
    local bx,by,bz=point_mass_column(b,bi,r.rbx,r.rby,r.rbz,1,0,0)
    xx,xy,xz=xx+bx,xy+by,xz+bz
    local _,yy,yz=point_mass_column(a,ai,r.rax,r.ray,r.raz,0,1,0)
    _,by,bz=point_mass_column(b,bi,r.rbx,r.rby,r.rbz,0,1,0);yy,yz=yy+by,yz+bz
    local _,_,zz=point_mass_column(a,ai,r.rax,r.ray,r.raz,0,0,1)
    _,_,bz=point_mass_column(b,bi,r.rbx,r.rby,r.rbz,0,0,1);zz=zz+bz
    local cx,cy,cz=yy*zz-yz*yz,xz*yz-xy*zz,xy*yz-xz*yy
    local det=xx*cx+xy*cy+xz*cz
    if det<=0 then return false end
    r.pxx,r.pxy,r.pxz=cx/det,cy/det,cz/det
    r.pyy,r.pyz,r.pzz=(xx*zz-xz*xz)/det,(xy*xz-xx*yz)/det,(xx*yy-xy*xy)/det
    return true
end
local function point_impulse(r,x,y,z,position)
    for side=1,2 do
        local b=side==1 and r.ba or r.bb;local im=side==1 and r.aim or r.bim
        local rx,ry,rz=r.rax,r.ray,r.raz;local sign=1
        if side==2 then rx,ry,rz=r.rbx,r.rby,r.rbz;sign=-1 end
        if im>0 then
            local jx,jy,jz=x*sign,y*sign,z*sign
            if position then
                b.com_x,b.com_y,b.com_z=b.com_x+jx*im,b.com_y+jy*im,b.com_z+jz*im
                local tx,ty,tz=ry*jz-rz*jy,rz*jx-rx*jz,rx*jy-ry*jx
                apply_pseudo_rotation(b,b.wii_xx*tx+b.wii_xy*ty+b.wii_xz*tz,
                    b.wii_xy*tx+b.wii_yy*ty+b.wii_yz*tz,b.wii_xz*tx+b.wii_yz*ty+b.wii_zz*tz)
            else
                apply_impulse(b,jx,jy,jz,rx,ry,rz,im,b.wii_xx,b.wii_yy,b.wii_zz,b.wii_xy,b.wii_xz,b.wii_yz)
            end
        end
    end
end
local function point_solve(r,x,y,z)
    return r.pxx*x+r.pxy*y+r.pxz*z,r.pxy*x+r.pyy*y+r.pyz*z,r.pxz*x+r.pyz*y+r.pzz*z
end
local function angular_mass(b,x,y,z,im)
    if im==0 then return 0 end
    return x*(b.wii_xx*x+b.wii_xy*y+b.wii_xz*z)
        +y*(b.wii_xy*x+b.wii_yy*y+b.wii_yz*z)+z*(b.wii_xz*x+b.wii_yz*y+b.wii_zz*z)
end
local function cone_geometry(r,side,c)
    if r.distance<1e-8 then return false end
    local a,b,anchor,arx,ary,arz,brx,bry,brz,nx,ny,nz,limit,aim,bim
    if side==1 then
        a,b,anchor=r.ba,r.bb,r.a;arx,ary,arz=r.rax,r.ray,r.raz;brx,bry,brz=r.rbx,r.rby,r.rbz
        nx,ny,nz=r.nx,r.ny,r.nz;limit=r.limit0;aim,bim=r.aim,r.bim
    else
        a,b,anchor=r.bb,r.ba,r.b;arx,ary,arz=r.rbx,r.rby,r.rbz;brx,bry,brz=r.rax,r.ray,r.raz
        nx,ny,nz=-r.nx,-r.ny,-r.nz;limit=r.limit1;aim,bim=r.bim,r.aim
    end
    if limit>=math.pi then return false end
    local ux,uy,uz=Integrate.rotate_vec(a.qw,a.qx,a.qy,a.qz,anchor.ux,anchor.uy,anchor.uz)
    local cosine=max(-1,math.min(1,ux*nx+uy*ny+uz*nz))
    c.angle=math.acos(cosine);c.error=c.angle-limit
    local tx,ty,tz=uy*nz-uz*ny,uz*nx-ux*nz,ux*ny-uy*nx
    local sine=math.sqrt(tx*tx+ty*ty+tz*tz)
    if sine<1e-8 then
        if cosine>0 then return false end
        -- Antiparallel axes have no unique correction plane. choose a stable
        -- orthogonal plane rather than dividing by sin(pi)
        if abs(ux)<.9 then tx,ty,tz=0,uz,-uy else tx,ty,tz=-uz,0,ux end
        sine=math.sqrt(tx*tx+ty*ty+tz*tz)
    end
    tx,ty,tz=tx/sine,ty/sine,tz/sine
    -- Gradient of theta wrt the endpoint line. Including its translational
    -- term makes a cone on an anchored endpoint steer the other endpoint too
    local qx,qy,qz=(ty*nz-tz*ny)/r.distance,(tz*nx-tx*nz)/r.distance,(tx*ny-ty*nx)/r.distance
    c.a,c.b,c.aim,c.bim=a,b,aim,bim;c.qx,c.qy,c.qz=qx,qy,qz
    c.jax,c.jay,c.jaz=-(ary*qz-arz*qy)-tx,-(arz*qx-arx*qz)-ty,-(arx*qy-ary*qx)-tz
    c.jbx,c.jby,c.jbz=bry*qz-brz*qy,brz*qx-brx*qz,brx*qy-bry*qx
    local k=(aim+bim)*(qx*qx+qy*qy+qz*qz)
        +angular_mass(a,c.jax,c.jay,c.jaz,aim)+angular_mass(b,c.jbx,c.jby,c.jbz,bim)
    c.mass=k>1e-12 and 1/k or 0
    return c.mass>0
end
local function cone_speed(c)
    local a,b=c.a,c.b
    return c.qx*(b.vx-a.vx)+c.qy*(b.vy-a.vy)+c.qz*(b.vz-a.vz)
        +c.jax*a.wx+c.jay*a.wy+c.jaz*a.wz+c.jbx*b.wx+c.jby*b.wy+c.jbz*b.wz
end
local function cone_impulse(c,j,position)
    for side=1,2 do
        local b=side==1 and c.a or c.b;local im=side==1 and c.aim or c.bim
        if im>0 then
            local sign=side==1 and 1 or -1
            local x,y,z=c.qx*j*im*sign,c.qy*j*im*sign,c.qz*j*im*sign
            local tx,ty,tz=c.jax,c.jay,c.jaz
            if side==2 then tx,ty,tz=c.jbx,c.jby,c.jbz end
            local ax=-(b.wii_xx*tx+b.wii_xy*ty+b.wii_xz*tz)*j
            local ay=-(b.wii_xy*tx+b.wii_yy*ty+b.wii_yz*tz)*j
            local az=-(b.wii_xz*tx+b.wii_yz*ty+b.wii_zz*tz)*j
            if position then
                b.com_x,b.com_y,b.com_z=b.com_x+x,b.com_y+y,b.com_z+z
                apply_pseudo_rotation(b,ax,ay,az)
            else
                b.vx,b.vy,b.vz=b.vx+x,b.vy+y,b.vz+z
                b.wx,b.wy,b.wz=b.wx+ax,b.wy+ay,b.wz+az
            end
        end
    end
end
function Solver:_prepare_ropes(world,dt)
    world.rope_active_rows=0;world.rope_enforced_rows=0;world.rope_impulse_sum=0
    for _,r in ipairs(world.ropes or {}) do
        local previous=r.impulse or 0;local was_active=r.solve
        r.impulse=0;r.solve=false
        if Rope.geometry(r) and (not r.ba.sleeping or not r.bb.sleeping) then
            if r.length==0 then
                -- a zero-length rope is a point constraint. a single radial row
                -- loses its tangent directions at zero and creates anchor jitter
                r.solve=point_mass(r)
                local scale=was_active and math.min(2,dt/(r.previous_dt or dt)) or 0
                r.pjx,r.pjy,r.pjz=(r.pjx or 0)*scale,(r.pjy or 0)*scale,(r.pjz or 0)*scale
                if r.solve then world.rope_active_rows=world.rope_active_rows+3 end
            else
            local speed=rel_vel_along(r,r.nx,r.ny,r.nz)
            local gap=max(0,r.length-r.distance)
            local rod=r.kind=="rod"
            local taut=r.distance>=r.length-Rope.slop
            r.target=rod and 0 or gap/dt
            local impact=not rod and taut and speed>Rope.velocity_slop and r.restitution>0
            if impact then
                r.target=-r.restitution*speed
            end
            if rod or taut or speed>r.target then
                rope_mass(r);r.solve=r.mass>0
                if r.solve then
                    world.rope_active_rows=world.rope_active_rows+1
                    if was_active and (rod or taut) and not impact and r.warm_nx then
                        local alignment=max(0,r.nx*r.warm_nx+r.ny*r.warm_ny+r.nz*r.warm_nz)
                        r.impulse=previous*alignment*math.min(2,dt/(r.previous_dt or dt))
                    end
                end
            end
            end
        end
        r.warm_nx,r.warm_ny,r.warm_nz=r.nx,r.ny,r.nz;r.previous_dt=dt
        if r.limits_enabled then
            r.cones=r.cones or {{},{}}
            for side=1,2 do
                local c=r.cones[side];c.solve=false;c.impulse=0
                if r.solve and cone_geometry(r,side,c) then
                    c.target=max(0,-c.error)/dt
                    c.solve=c.error>=-Rope.angular_slop or cone_speed(c)>c.target
                end
            end
        end
    end
end
function Solver:_warm_start_ropes(world)
    for _,r in ipairs(world.ropes or {}) do
        if r.solve then
            if r.length==0 then point_impulse(r,r.pjx,r.pjy,r.pjz,false)
            elseif r.impulse~=0 then rope_impulse(r,r.impulse) end
        end
    end
end
function Solver:_solve_rope_velocities(world)
    local change=0
    for _,r in ipairs(world.ropes or {}) do
        if r.solve then
            if r.length==0 then
                local a,b=r.ba,r.bb
                local x=b.vx+b.wy*r.rbz-b.wz*r.rby-a.vx-a.wy*r.raz+a.wz*r.ray
                local y=b.vy+b.wz*r.rbx-b.wx*r.rbz-a.vy-a.wz*r.rax+a.wx*r.raz
                local z=b.vz+b.wx*r.rby-b.wy*r.rbx-a.vz-a.wx*r.ray+a.wy*r.rax
                local jx,jy,jz=point_solve(r,x,y,z)
                local nx,ny,nz=clamp_finite(r.pjx+jx,MAX_IMPULSE),clamp_finite(r.pjy+jy,MAX_IMPULSE),clamp_finite(r.pjz+jz,MAX_IMPULSE)
                jx,jy,jz=nx-r.pjx,ny-r.pjy,nz-r.pjz;r.pjx,r.pjy,r.pjz=nx,ny,nz
                point_impulse(r,jx,jy,jz,false);change=max(change,abs(jx),abs(jy),abs(jz))
                r.impulse=math.sqrt(nx*nx+ny*ny+nz*nz)
            else
            local speed=rel_vel_along(r,r.nx,r.ny,r.nz)
            local next_j=math.min(MAX_IMPULSE,max(r.kind=="rod" and -MAX_IMPULSE or 0,r.impulse+(speed-r.target)*r.mass))
            local delta=next_j-r.impulse;r.impulse=next_j
            rope_impulse(r,delta);change=max(change,abs(delta))
            end
        end
        if r.limits_enabled and r.cones then
            for side=1,2 do
                local c=r.cones[side]
                if c.solve then
                    local next_j=math.min(MAX_IMPULSE,max(0,c.impulse+(cone_speed(c)-c.target)*c.mass))
                    local delta=next_j-c.impulse;c.impulse=next_j
                    cone_impulse(c,delta,false);change=max(change,abs(delta))
                end
            end
        end
    end
    return change
end
function Solver:solve_rope_positions(world)
    local started=love.timer.getTime()
    for _=1,self.position_iterations do
        local pushed=false
        for _,r in ipairs(world.ropes or {}) do
            local has_axis=Rope.geometry(r)
            local error=r.distance-r.length
            if r.length==0 and error>Rope.slop and point_mass(r) then
                local scale=math.min(MAX_CORRECTION,error-Rope.slop)/error
                local x,y,z=point_solve(r,r.nx*error*scale,r.ny*error*scale,r.nz*error*scale)
                point_impulse(r,x,y,z,true);pushed=true
            elseif r.length~=0 and has_axis and (error>Rope.slop or (r.kind=="rod" and error < -Rope.slop)) then
                rope_mass(r)
                local sign=error<0 and -1 or 1
                local j=sign*math.min(MAX_IMPULSE,math.min(MAX_CORRECTION,abs(error)-Rope.slop)*r.mass)
                if abs(j)>0 then
                    pushed=true
                    for side=1,2 do
                        local b=side==1 and r.ba or r.bb
                        local im=side==1 and r.aim or r.bim
                        local rx,ry,rz=r.rax,r.ray,r.raz
                        local sign=1;if side==2 then rx,ry,rz=r.rbx,r.rby,r.rbz;sign=-1 end
                        if im>0 then
                            local x,y,z=r.nx*j*sign,r.ny*j*sign,r.nz*j*sign
                            b.com_x=b.com_x+x*im;b.com_y=b.com_y+y*im;b.com_z=b.com_z+z*im
                            local tx,ty,tz=ry*z-rz*y,rz*x-rx*z,rx*y-ry*x
                            apply_pseudo_rotation(b,b.wii_xx*tx+b.wii_xy*ty+b.wii_xz*tz,
                                b.wii_xy*tx+b.wii_yy*ty+b.wii_yz*tz,b.wii_xz*tx+b.wii_yz*ty+b.wii_zz*tz)
                        end
                    end
                end
            end
            if r.limits_enabled then
                r.cones=r.cones or {{},{}}
                for side=1,2 do
                    Rope.geometry(r);rope_mass(r)
                    local c=r.cones[side]
                    if cone_geometry(r,side,c) and c.error>Rope.angular_slop then
                        local j=math.min(MAX_IMPULSE,math.min(MAX_ANGULAR_CORRECTION,c.error-Rope.angular_slop)*c.mass)
                        if j>0 then cone_impulse(c,j,true);pushed=true end
                    end
                end
            end
        end
        if not pushed then break end
    end
    local violation=0
    for _,r in ipairs(world.ropes or {}) do
        Rope.geometry(r)
        local v=r.kind=="rod" and abs(r.distance-r.length) or max(0,r.distance-r.length);violation=max(violation,v)
        r.diagnostic.max_violation=math.max(r.diagnostic.max_violation or 0,v)
        r.diagnostic.impulse=r.impulse
        if abs(r.impulse)>1e-12 then
            world.rope_enforced_rows=world.rope_enforced_rows+1
            world.rope_impulse_sum=world.rope_impulse_sum+abs(r.impulse)
            r.diagnostic.enforced_steps=(r.diagnostic.enforced_steps or 0)+1
        end
    end
    world.rope_max_violation=math.max(world.rope_max_violation or 0,violation)
    world.rope_solve_ms=(world.rope_solve_ms or 0)+(love.timer.getTime()-started)*1000
end

function Solver:solve(cache, step_index, dt, gravity, world)
    if not cache or not cache.manifolds then
        return 0, 0, 0
    end
    local n = self:_prepare(cache, step_index, dt, gravity, world)
    if world then self:_prepare_ropes(world,dt);world.rope_solve_ms=0 end
    if n == 0 and #(world and world.ropes or {}) == 0 then
        return 0, 0, 0
    end

    -- zero iterations leaves contacts available for detection without solving them
    local viters = self.velocity_iterations
    local viters_run = 0
    if viters > 0 then
        self:_warm_start()
        if world then self:_warm_start_ropes(world) end
        for it = 1, viters do
            local max_delta = self:_solve_velocity_iteration()
            if #(world and world.ropes or {})>0 then
                local started=love.timer.getTime()
                max_delta=max(max_delta,self:_solve_rope_velocities(world))
                world.rope_solve_ms=world.rope_solve_ms+(love.timer.getTime()-started)*1000
            end
            viters_run = it
            if it >= 2 and max_delta < 1e-3 then
                break
            end
        end
        self:_writeback_impulses()
    end

    -- Position integration will already remove vn*dt of penetration from a
    -- separating contact. Pushing that part out as well lifted every bounce
    -- by the detection depth, adding energy on each impact
    if dt and dt > 0 then
        local list = self._c
        for i = 1, n do
            local c = list[i]
            local vn = rel_vel_along(c, c.nx, c.ny, c.nz)
            c.separation = vn > 0 and vn * dt or 0
        end
    end

    -- ngs, 0 iters leaves positions untouched, a sweep w/ no correction ends the loop
    local piters = self.position_iterations
    local piters_run = 0
    for it = 1, piters do
        local pushed = self:_solve_position_iteration()
        piters_run = it
        if pushed == 0 then
            break
        end
    end

    return n, viters_run, piters_run
end

return Solver
