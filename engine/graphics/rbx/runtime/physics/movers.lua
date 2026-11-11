-- mover/force-constraint engine, clean-room pd math, drives assembly bodies via force/torque/velocity-target, no topology
-- applied as impulses (j=f*dt) via inv_mass/inv_inertia, inputs finite-guarded + impulses bounded so bad settings cant nan/inf

local Integrate = runtime_require("physics/integrate.lua")

local Movers = {}
Movers.__index = Movers

local sqrt = math.sqrt
local abs  = math.abs
local clamp_finite = Integrate.clamp_finite
local rotate_vec   = Integrate.rotate_vec
local quat_conj    = Integrate.quat_conj
local quat_mul     = Integrate.quat_mul

local BIG = 1e9                 -- finite clamp for inputs / impulses
local DEFAULT_RESPONSIVENESS = 12   -- pd freq (rad/s) for align_* movers
local EPS = 1e-9

-- small numeric helpers

local function num(v,limit) -- finite scalar or 0
    v = tonumber(v)
    if v == nil or v ~= v then return 0 end
    limit=limit or BIG
    if v > limit then return limit elseif v < -limit then return -limit end
    return v
end

-- {x,y,z} or [1..3] -> 3 finite scalars
local function vec3(t,limit)
    if type(t) ~= "table" then return 0, 0, 0 end
    return num(t.x or t.X or t[1],limit), num(t.y or t.Y or t[2],limit), num(t.z or t.Z or t[3],limit)
end

local function force_input_limit(b)
    return math.min(BIG/math.min(1,b.inv_mass),1.7976931348623157e308)
end

local function clampabs(v, m)
    if m <= 0 then return 0 end
    if v > m then return m elseif v < -m then return -m end
    return v
end

-- cap = nil (uncapped), number (magnitude), or {x,y,z} per-axis, caps at cap*dt
local function cap_impulse(jx, jy, jz, cap, dt)
    if cap == nil then
        return jx, jy, jz
    end
    if type(cap) == "number" then
        if cap <= 0 then return 0, 0, 0 end
        local maxj = cap * dt
        local m2 = jx * jx + jy * jy + jz * jz
        if m2 > maxj * maxj and m2 > EPS then
            local s = maxj / sqrt(m2)
            return jx * s, jy * s, jz * s
        end
        return jx, jy, jz
    end
    local cx, cy, cz = vec3(cap)
    return clampabs(jx, cx * dt), clampabs(jy, cy * dt), clampabs(jz, cz * dt)
end

-- impulse application

local function apply_linear(b, jx, jy, jz)
    local im = b.inv_mass
    if im == 0 then return end
    b.vx = clamp_finite(b.vx + jx * im, BIG)
    b.vy = clamp_finite(b.vy + jy * im, BIG)
    b.vz = clamp_finite(b.vz + jz * im, BIG)
end

-- angular impulses use world axes, while the body stores inverse inertia in local axes
-- use the world tensor when available
local function refresh_mover_world_inertia(b)
    if not b.update_world_inertia then return end
    -- several movers can drive one assembly in a single fixed step. the pose
    -- and local tensor stay unchanged until integration, so refresh only when
    -- either actually changes rather than recomputing the tensor per mover
    if b._mover_wi_qw == b.qw and b._mover_wi_qx == b.qx
        and b._mover_wi_qy == b.qy and b._mover_wi_qz == b.qz
        and b._mover_wi_ix == b.inv_inertia_x and b._mover_wi_iy == b.inv_inertia_y
        and b._mover_wi_iz == b.inv_inertia_z then
        return
    end
    b:update_world_inertia()
    b._mover_wi_qw, b._mover_wi_qx, b._mover_wi_qy, b._mover_wi_qz = b.qw, b.qx, b.qy, b.qz
    b._mover_wi_ix, b._mover_wi_iy, b._mover_wi_iz = b.inv_inertia_x, b.inv_inertia_y, b.inv_inertia_z
end

local function apply_angular(b, lx, ly, lz)
    if b.inv_mass == 0 then return end
    refresh_mover_world_inertia(b)
    local xx, yy, zz = b.wii_xx, b.wii_yy, b.wii_zz
    if xx ~= nil and yy ~= nil and zz ~= nil then
        local xy, xz, yz = b.wii_xy or 0, b.wii_xz or 0, b.wii_yz or 0
        b.wx = clamp_finite(b.wx + xx * lx + xy * ly + xz * lz, BIG)
        b.wy = clamp_finite(b.wy + xy * lx + yy * ly + yz * lz, BIG)
        b.wz = clamp_finite(b.wz + xz * lx + yz * ly + zz * lz, BIG)
    else
        b.wx = clamp_finite(b.wx + lx * b.inv_inertia_x, BIG)
        b.wy = clamp_finite(b.wy + ly * b.inv_inertia_y, BIG)
        b.wz = clamp_finite(b.wz + lz * b.inv_inertia_z, BIG)
    end
end

-- torque = r×j about com
local function apply_at(b, jx, jy, jz, px, py, pz)
    local im = b.inv_mass
    if im == 0 then return end
    b.vx = clamp_finite(b.vx + jx * im, BIG)
    b.vy = clamp_finite(b.vy + jy * im, BIG)
    b.vz = clamp_finite(b.vz + jz * im, BIG)
    local rx, ry, rz = px - b.com_x, py - b.com_y, pz - b.com_z
    local tx = ry * jz - rz * jy
    local ty = rz * jx - rx * jz
    local tz = rx * jy - ry * jx
    apply_angular(b, tx, ty, tz)
end

-- nil offset = com
local function apply_point(b, offset)
    if offset == nil then
        return b.com_x, b.com_y, b.com_z, false
    end
    local ox, oy, oz = vec3(offset)
    local rx, ry, rz = rotate_vec(b.qw, b.qx, b.qy, b.qz, ox, oy, oz)
    return b.com_x + rx, b.com_y + ry, b.com_z + rz, true
end

-- rotate into body frame if relative, else passthrough
local function frame_vec(b, x, y, z, relative)
    if relative then
        return rotate_vec(b.qw, b.qx, b.qy, b.qz, x, y, z)
    end
    return x, y, z
end

-- per-kind application

local function do_vector_force(b, m, dt)
    -- Force units scale with mass. a fixed force-input ceiling silently
    -- removed legitimate mass*gravity cancellation on massive source bodies
    -- keep ordinary bounds and cap acceleration for larger bodies instead;
    -- output velocity/torque finite guards remain the application boundary
    local fx, fy, fz = vec3(m.force,force_input_limit(b))
    fx, fy, fz = frame_vec(b, fx, fy, fz, m.relative)
    local jx, jy, jz = fx * dt, fy * dt, fz * dt
    local px, py, pz, has = apply_point(b, m.offset)
    if has then apply_at(b, jx, jy, jz, px, py, pz) else apply_linear(b, jx, jy, jz) end
    return true
end

local function do_torque(b, m, dt)
    local tx, ty, tz = vec3(m.torque)
    tx, ty, tz = frame_vec(b, tx, ty, tz, m.relative)
    apply_angular(b, tx * dt, ty * dt, tz * dt)
    return true
end

local function do_line_force(b, m, dt)
    local px, py, pz, has = apply_point(b, m.offset)
    local gx, gy, gz = vec3(m.point)
    local dx, dy, dz = gx - px, gy - py, gz - pz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 < EPS then return false end
    local inv = num(m.magnitude) / sqrt(d2)
    local jx, jy, jz = dx * inv * dt, dy * inv * dt, dz * inv * dt
    if has then apply_at(b, jx, jy, jz, px, py, pz) else apply_linear(b, jx, jy, jz) end
    return true
end

-- Legacy movers are stiff force controllers. Roblox's defaults (BodyGyro
-- P=3000/D=500, BodyPosition P=10000/D=1250, BodyVelocity P=1250) are often
-- placed on parts light enough that an explicit force step overshoots and
-- diverges at 60 Hz, so neither controller below takes one
--
-- BodyVelocity and BodyAngularVelocity are first-order: over one step their
-- velocity error decays exactly by exp(-P * dt / mass)
local function velocity_impulse(error, p, dt, inverse_mass)
    if inverse_mass <= 0 then return p * error * dt end
    return error * (1 - math.exp(-p * dt * inverse_mass)) / inverse_mass
end

-- BodyPosition and BodyGyro are spring-dampers, integrated implicitly
-- (backward Euler over this step). Soft gains stay close to the explicit
-- force, stiff gains settle instead of oscillating. `resistance` is the
-- controller's force per unit of velocity along the same axis
local function implicit_impulse(force, resistance, dt, inverse_mass)
    return force * dt / (1 + resistance * dt * inverse_mass)
end

local function do_linear_velocity(b, m, dt)
    local im = b.inv_mass
    if im == 0 then return false end
    local tx, ty, tz = vec3(m.velocity)
    if m.compat_teleport then              -- legacy hard-set, opt-in
        b.vx, b.vy, b.vz = clamp_finite(tx, BIG), clamp_finite(ty, BIG), clamp_finite(tz, BIG)
        return true
    end
    -- Legacy BodyVelocity is a force controller, rather than a direct
    -- velocity assignment: P multiplies the velocity error and MaxForce caps
    -- the resulting force independently on each world axis
    local p = math.max(0, num(m.p))
    local jx = velocity_impulse(tx - b.vx, p, dt, im)
    local jy = velocity_impulse(ty - b.vy, p, dt, im)
    local jz = velocity_impulse(tz - b.vz, p, dt, im)
    jx, jy, jz = cap_impulse(jx, jy, jz, m.max_force, dt)
    apply_linear(b, jx, jy, jz)
    return true
end

local function do_angular_velocity(b, m, dt)
    if b.inv_mass == 0 then return false end
    local tx, ty, tz = vec3(m.angular_velocity)
    -- BodyAngularVelocity has the same P-controlled force-controller shape as
    -- BodyVelocity, in torque space.  its documented MaxTorque axes are world
    -- axes, so cap before transforming the angular impulse through inertia
    local p = math.max(0, num(m.p))
    refresh_mover_world_inertia(b)
    local lx = velocity_impulse(tx - b.wx, p, dt, b.wii_xx or b.inv_inertia_x)
    local ly = velocity_impulse(ty - b.wy, p, dt, b.wii_yy or b.inv_inertia_y)
    local lz = velocity_impulse(tz - b.wz, p, dt, b.wii_zz or b.inv_inertia_z)
    lx, ly, lz = cap_impulse(lx, ly, lz, m.max_torque, dt)
    apply_angular(b, lx, ly, lz)
    return true
end

local function do_align_position(b, m, dt)
    local im = b.inv_mass
    if im == 0 then return false end
    local gx, gy, gz = vec3(m.goal)
    if m.p ~= nil or m.d ~= nil then
        -- Legacy BodyPosition exposes the force gains directly: P amplifies
        -- position error and D damps present velocity.  MaxForce is a
        -- per-world-axis force cap, not a velocity or impulse cap
        -- the position error also shrinks by dt * velocity during the
        -- step, so P adds P * dt to the velocity resistance
        local p, d = math.max(0, num(m.p)), math.max(0, num(m.d))
        local resistance = d + p * dt
        local jx = implicit_impulse(p * (gx - b.com_x) - resistance * b.vx, resistance, dt, im)
        local jy = implicit_impulse(p * (gy - b.com_y) - resistance * b.vy, resistance, dt, im)
        local jz = implicit_impulse(p * (gz - b.com_z) - resistance * b.vz, resistance, dt, im)
        jx, jy, jz = cap_impulse(jx, jy, jz, m.max_force, dt)
        apply_linear(b, jx, jy, jz)
        return true
    end
    local w = num(m.responsiveness)
    if w <= 0 then w = DEFAULT_RESPONSIVENESS end
    local mass = 1 / im
    -- critically-damped pd: a = w²·err − 2w·v, impulse = mass·a·dt
    local ax = w * w * (gx - b.com_x) - 2 * w * b.vx
    local ay = w * w * (gy - b.com_y) - 2 * w * b.vy
    local az = w * w * (gz - b.com_z) - 2 * w * b.vz
    local jx, jy, jz = mass * ax * dt, mass * ay * dt, mass * az * dt
    jx, jy, jz = cap_impulse(jx, jy, jz, m.max_force, dt)
    apply_linear(b, jx, jy, jz)
    return true
end

local function do_body_gyro(b, m, dt, gw, gx, gy, gz)
    -- Error and torque are calculated in the body frame so BodyGyro's vector
    -- MaxTorque remains an independent per-axis limit while the part rotates
    -- the actual angular impulse is then rotated back to world space and
    -- transformed by the body's world inverse-inertia tensor
    local cw, cx, cy, cz = quat_conj(b.qw, b.qx, b.qy, b.qz)
    -- inverse(current) * goal is the target rotation in the body's local
    -- coordinates, matching the frame in which legacy BodyGyro's vector cap
    -- is applied
    local ew, ex, ey, ez = quat_mul(cw, cx, cy, cz, gw, gx, gy, gz)
    if ew < 0 then ex, ey, ez = -ex, -ey, -ez end
    local erx, ery, erz = 2 * ex, 2 * ey, 2 * ez
    local wx, wy, wz = rotate_vec(cw, cx, cy, cz, b.wx, b.wy, b.wz)
    local p, d = math.max(0, num(m.p)), math.max(0, num(m.d))
    local resistance = d + p * dt
    local lx = implicit_impulse(p * erx - resistance * wx, resistance, dt, b.inv_inertia_x)
    local ly = implicit_impulse(p * ery - resistance * wy, resistance, dt, b.inv_inertia_y)
    local lz = implicit_impulse(p * erz - resistance * wz, resistance, dt, b.inv_inertia_z)
    lx, ly, lz = cap_impulse(lx, ly, lz, m.max_torque, dt)
    lx, ly, lz = rotate_vec(b.qw, b.qx, b.qy, b.qz, lx, ly, lz)
    apply_angular(b, lx, ly, lz)
    return true
end

local function do_align_orientation(b, m, dt)
    if b.inv_mass == 0 then return false end
    local gw, gx, gy, gz
    if m.goal_quat then
        gw, gx, gy, gz = num(m.goal_quat.qw or m.goal_quat[1] or 1),
            num(m.goal_quat.qx or m.goal_quat[2] or 0),
            num(m.goal_quat.qy or m.goal_quat[3] or 0),
            num(m.goal_quat.qz or m.goal_quat[4] or 0)
        gw, gx, gy, gz = Integrate.quat_normalize(gw, gx, gy, gz)
    else
        gw, gx, gy, gz = 1, 0, 0, 0
    end
    if m.p ~= nil or m.d ~= nil then
        return do_body_gyro(b, m, dt, gw, gx, gy, gz)
    end
    -- modern AlignOrientation keeps its existing responsiveness contract
    local cw, cx, cy, cz = quat_conj(b.qw, b.qx, b.qy, b.qz)
    local ew, ex, ey, ez = quat_mul(gw, gx, gy, gz, cw, cx, cy, cz)
    local s = ew < 0 and -2 or 2
    local erx, ery, erz = s * ex, s * ey, s * ez   -- bounded in [-2, 2]
    local w = num(m.responsiveness)
    if w <= 0 then w = DEFAULT_RESPONSIVENESS end
    local iix, iiy, iiz = b.inv_inertia_x, b.inv_inertia_y, b.inv_inertia_z
    -- α = w²·e − 2w·ω. the body stores inertia diagonally in local
    -- coordinates, so build that torque impulse locally and rotate it back to
    -- world space before applying the world inverse-inertia tensor
    local ax = w * w * erx - 2 * w * b.wx
    local ay = w * w * ery - 2 * w * b.wy
    local az = w * w * erz - 2 * w * b.wz
    local lax, lay, laz = rotate_vec(cw, cx, cy, cz, ax, ay, az)
    local lx = (iix > 0) and (lax / iix * dt) or 0
    local ly = (iiy > 0) and (lay / iiy * dt) or 0
    local lz = (iiz > 0) and (laz / iiz * dt) or 0
    lx, ly, lz = cap_impulse(lx, ly, lz, m.max_torque, dt)
    lx, ly, lz = rotate_vec(b.qw, b.qx, b.qy, b.qz, lx, ly, lz)
    apply_angular(b, lx, ly, lz)
    return true
end

local APPLY = {
    vector_force      = do_vector_force,
    torque            = do_torque,
    line_force        = do_line_force,
    linear_velocity   = do_linear_velocity,
    angular_velocity  = do_angular_velocity,
    align_position    = do_align_position,
    align_orientation = do_align_orientation,
}

-- legacy bodymover -> modern kinds

-- Creator Hub's current legacy BodyMover defaults. keep these here as plain
-- records because parsed places can omit a property while a live Instance
-- always exposes one. each fallback vector is freshly allocated so an in-place
-- runtime re-sync cannot mutate a shared default
local function legacy_vec(value, x, y, z)
    if type(value) == "table" then return value end
    return { x = x, y = y, z = z }
end

local function legacy_num(value, fallback)
    return value == nil and fallback or value
end

-- nil if unknown class
function Movers.from_legacy(src, part_id, id)
    if type(src) ~= "table" then return nil end
    local cls = src.class_name
    local base = { id = id, enabled = src.enabled ~= false, part_id = part_id }
    if cls == "BodyForce" then
        base.kind = "vector_force"; base.force = legacy_vec(src.force, 0, 1, 0); base.relative = false
    elseif cls == "BodyThrust" then
        base.kind = "vector_force"; base.force = legacy_vec(src.force, 0, 1, 0); base.relative = true
        base.offset = legacy_vec(src.location, 0, 0, 0)
    elseif cls == "BodyVelocity" then
        base.kind = "linear_velocity"; base.velocity = legacy_vec(src.velocity, 0, 2, 0)
        base.max_force = legacy_vec(src.max_force, 4000, 4000, 4000)
        base.p = legacy_num(src.p, 1250); base.compat_teleport = src.compat_teleport == true
    elseif cls == "BodyAngularVelocity" then
        base.kind = "angular_velocity"; base.angular_velocity = legacy_vec(src.angular_velocity, 0, 2, 0)
        base.max_torque = legacy_vec(src.max_torque, 4000, 4000, 4000)
        base.p = legacy_num(src.p, 1250)
    elseif cls == "BodyPosition" then
        base.kind = "align_position"; base.goal = legacy_vec(src.position, 0, 50, 0)
        base.max_force = legacy_vec(src.max_force, 4000, 4000, 4000)
        base.responsiveness = src.responsiveness
        base.p, base.d = legacy_num(src.p, 10000), legacy_num(src.d, 1250)
    elseif cls == "BodyGyro" then
        base.kind = "align_orientation"; base.max_torque = legacy_vec(src.max_torque, 400000, 0, 400000)
        base.responsiveness = src.responsiveness
        base.goal_quat = src.goal_quat   -- glue derives this from bodygyro.cframe
        base.p, base.d = legacy_num(src.p, 3000), legacy_num(src.d, 500)
    else
        return nil
    end
    return base
end

-- mutates in place when both tables, no per-frame alloc
local function adopt_vec(rec, field, value)
    local current = rec[field]
    if type(value) == "table" and type(current) == "table" then
        current.x = value.x or value.X or value[1] or 0
        current.y = value.y or value.Y or value[2] or 0
        current.z = value.z or value.Z or value[3] or 0
    else
        rec[field] = value
    end
end

local function adopt_legacy_vec(rec, field, value, x, y, z)
    adopt_vec(rec, field, legacy_vec(value, x, y, z))
end

-- re-sync in place from live legacy props, false if kind no longer matches class -> caller redoes from_legacy+add
function Movers.update_legacy(rec, class_name, props, part_id)
    if type(rec) ~= "table" or type(props) ~= "table" then return false end
    local kind = rec.kind
    if class_name == "BodyForce" then
        if kind ~= "vector_force" or rec.relative then return false end
        adopt_legacy_vec(rec, "force", props.force, 0, 1, 0)
    elseif class_name == "BodyThrust" then
        if kind ~= "vector_force" or not rec.relative then return false end
        adopt_legacy_vec(rec, "force", props.force, 0, 1, 0)
        adopt_legacy_vec(rec, "offset", props.location, 0, 0, 0)
    elseif class_name == "BodyVelocity" then
        if kind ~= "linear_velocity" then return false end
        adopt_legacy_vec(rec, "velocity", props.velocity, 0, 2, 0)
        adopt_legacy_vec(rec, "max_force", props.max_force, 4000, 4000, 4000)
        rec.p = legacy_num(props.p, 1250)
        rec.compat_teleport = props.compat_teleport == true
    elseif class_name == "BodyAngularVelocity" then
        if kind ~= "angular_velocity" then return false end
        adopt_legacy_vec(rec, "angular_velocity", props.angular_velocity, 0, 2, 0)
        adopt_legacy_vec(rec, "max_torque", props.max_torque, 4000, 4000, 4000)
        rec.p = legacy_num(props.p, 1250)
    elseif class_name == "BodyPosition" then
        if kind ~= "align_position" then return false end
        adopt_legacy_vec(rec, "goal", props.position, 0, 50, 0)
        adopt_legacy_vec(rec, "max_force", props.max_force, 4000, 4000, 4000)
        rec.responsiveness = props.responsiveness
        rec.p, rec.d = legacy_num(props.p, 10000), legacy_num(props.d, 1250)
    elseif class_name == "BodyGyro" then
        if kind ~= "align_orientation" then return false end
        rec.goal_quat = props.goal_quat
        rec.p, rec.d = legacy_num(props.p, 3000), legacy_num(props.d, 500)
        adopt_legacy_vec(rec, "max_torque", props.max_torque, 400000, 0, 400000)
        rec.responsiveness = props.responsiveness
    else
        return false
    end
    rec.part_id = part_id
    rec.enabled = props.enabled ~= false
    return true
end

-- registry

function Movers.new()
    return setmetatable({
        list = {},      -- dense array
        by_id = {},     -- id -> record
        active_count = 0,
        applied_count = 0,
    }, Movers)
end

-- rec._slot caches array index so per-frame re-syncs are O(1) not O(#movers)
function Movers:add(rec)
    if type(rec) ~= "table" then return nil end
    if rec.enabled == nil then rec.enabled = true end
    if rec.id == nil then
        rec.id = "mover#" .. (#self.list + 1)
    end
    local existing = self.by_id[rec.id]
    if existing then
        local slot = existing._slot
        if slot == nil or self.list[slot] ~= existing then
            -- self-heal a stale slot, shouldnt happen
            for i = 1, #self.list do
                if self.list[i] == existing then slot = i; break end
            end
        end
        self.list[slot] = rec
        rec._slot = slot
    else
        local slot = #self.list + 1
        self.list[slot] = rec
        rec._slot = slot
    end
    self.by_id[rec.id] = rec
    return rec
end

function Movers:get(id)
    return self.by_id[id]
end

-- swap-remove, order doesnt matter (impulses are independent)
function Movers:remove(id)
    local rec = self.by_id[id]
    if not rec then return false end
    self.by_id[id] = nil
    local list = self.list
    local slot = rec._slot
    if slot == nil or list[slot] ~= rec then
        for i = 1, #list do
            if list[i] == rec then slot = i; break end
        end
    end
    if slot and list[slot] == rec then
        local last = #list
        local tail = list[last]
        list[slot] = tail
        list[last] = nil
        if tail ~= rec then
            tail._slot = slot
        end
    end
    return true
end

function Movers:set_enabled(id, enabled)
    local rec = self.by_id[id]
    if not rec then return false end
    rec.enabled = enabled ~= false
    return true
end

-- glue re-syncs the "parsed:" namespace each step, leaves api-added movers alone, plain-find avoids :sub garbage
function Movers:clear_prefix(prefix)
    local list = self.list
    for i = #list, 1, -1 do
        local rec = list[i]
        if type(rec.id) == "string" and string.find(rec.id, prefix, 1, true) == 1 then
            self.by_id[rec.id] = nil
            local last = #list
            local tail = list[last]
            list[i] = tail
            list[last] = nil
            if tail ~= rec then
                tail._slot = i
            end
        end
    end
end

function Movers:clear()
    self.list = {}
    self.by_id = {}
    self.active_count = 0
    self.applied_count = 0
end

function Movers:count()
    return #self.list
end

-- Destruction fast-path guard. Disabled movers still count as dependencies: they may be
-- re-enabled later and must not retain a part id whose assembly was removed in place
function Movers:has_part(part_id)
    if part_id == nil then return false end
    local list = self.list
    for i = 1, #list do
        if list[i].part_id == part_id then return true end
    end
    return false
end

-- a recently removed mover can leave one-frame wake signatures keyed by body. the
-- singleton-removal path has already proved no live mover targets the body, scrub only
-- these retained wake records so they cannot keep the dead body reachable
function Movers:forget_body(body)
    if body == nil then return end
    if self._body_sigs then self._body_sigs[body] = nil end
    if self._body_sigs_spare then self._body_sigs_spare[body] = nil end
end

local function resolve_body(world, m)
    local map = world.part_to_assembly
    if not map then return nil end
    local asm = map[m.part_id]
    return asm and asm.body or nil
end

-- cheap param signature: detects add/remove/param change w/o per-record state, collision = miss one wake, harmless
local KIND_SALT = {
    vector_force = 3, linear_velocity = 5, angular_velocity = 7,
    align_position = 11, align_orientation = 13,
}
local function mover_signature(m,b)
    local s = (KIND_SALT[m.kind] or 17) * 1.0001
    local fx, fy, fz = vec3(m.force,m.kind=='vector_force' and force_input_limit(b)or nil)
    if m.kind=='vector_force' then
        -- normalize the same effective force before weighting: large-body
        -- edits must wake their target without overflowing the wake key
        local scale=math.min(1,b.inv_mass)
        fx,fy,fz=fx*scale,fy*scale,fz*scale
    end
    local vx, vy, vz = vec3(m.velocity)
    local ax, ay, az = vec3(m.angular_velocity)
    local gx, gy, gz = vec3(m.goal)
    local ox, oy, oz = vec3(m.offset)
    s = s + fx * 1.03 + fy * 1.07 + fz * 1.11
        + vx * 1.13 + vy * 1.17 + vz * 1.19
        + ax * 1.23 + ay * 1.29 + az * 1.31
        + gx * 1.37 + gy * 1.41 + gz * 1.43
        + ox * 1.47 + oy * 1.51 + oz * 1.53
    if type(m.goal_quat) == "table" then
        s = s + num(m.goal_quat.qw) * 1.61 + num(m.goal_quat.qx) * 1.67
            + num(m.goal_quat.qy) * 1.71 + num(m.goal_quat.qz) * 1.73
    end
    if type(m.max_force) == "table" then
        local mx, my, mz = vec3(m.max_force)
        s = s + mx * 1.79 + my * 1.83 + mz * 1.87
    else
        s = s + num(m.max_force) * 1.79
    end
    if type(m.max_torque) == "table" then
        local mx, my, mz = vec3(m.max_torque)
        s = s + mx * 1.91 + my * 1.93 + mz * 1.97
    else
        s = s + num(m.max_torque) * 1.91
    end
    s = s + num(m.responsiveness) * 2.01 + num(m.p) * 2.03 + num(m.d) * 2.09
    if m.relative then s = s + 0.5 end
    return s
end

-- deep_slept target stays asleep, else parked movers re-run narrowphase forever, sig change wakes once so param edits take effect
-- call before world:refresh_active, sole wake authority for movers (apply never wakes)
function Movers:wake_targets(world)
    local prev = self._body_sigs or {}
    local cur = self._body_sigs_spare or {}
    for k in pairs(cur) do cur[k] = nil end

    local list = self.list
    for i = 1, #list do
        local m = list[i]
        if m.enabled ~= false then
            local b = resolve_body(world, m)
            if b and not b.is_static then
                cur[b] = (cur[b] or 0) + mover_signature(m,b)
            end
        end
    end

    -- world:wake_body not Body:wake: O(1) active-array append instead of flagging
    -- active_dirty (a full refresh_active scan + sleeping-proxy rebuild -- ruinous
    -- once far NPCs park-sleep in bulk). runs pre-refresh_active, same as before
    for b, sig in pairs(cur) do
        if b.sleeping and b.wake
            and (not b.deep_slept or b._mover_sig ~= sig) then
            world:wake_body(b)
        end
        b._mover_sig = sig
    end
    -- lost all its movers this step: wake once (gravity resumes)
    for b in pairs(prev) do
        if cur[b] == nil and b._mover_sig ~= nil then
            b._mover_sig = nil
            if b.sleeping and b.wake and not b.is_static then
                world:wake_body(b)
            end
        end
    end

    self._body_sigs = cur
    self._body_sigs_spare = prev
end

-- -> active_count (resolved to dynamic body), applied_count (actually drove it)
function Movers:apply(world, dt)
    local list = self.list
    local active, applied = 0, 0
    for i = 1, #list do
        local m = list[i]
        if m.enabled ~= false then
            local b = resolve_body(world, m)
            -- sleeping targets skipped, never woken here (wake_targets is sole authority)
            if b and not b.is_static and b.inv_mass > 0 and not b.sleeping then
                active = active + 1
                local fn = APPLY[m.kind]
                if fn and fn(b, m, dt) then
                    applied = applied + 1
                end
            end
        end
    end
    self.active_count = active
    self.applied_count = applied
    return active, applied
end

return Movers
