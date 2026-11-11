-- semi-implicit euler + quat utils, no table alloc in the hot loop
-- conventions: row-major, gravity -y, w world-frame. order: velocity(gravity) -> position -> orientation, quat renormalized + nan-guarded every substep

local Integrate = {}

local sqrt = math.sqrt

local QUAT_DRIFT_EPS = 1e-12
local MAX_SPEED = 1e6
local MAX_OMEGA = 1e6

-- zero-norm/nan -> identity, so degenerate input cant poison downstream
function Integrate.quat_normalize(qw, qx, qy, qz)
    local n2 = qw * qw + qx * qx + qy * qy + qz * qz
    if n2 < QUAT_DRIFT_EPS or n2 ~= n2 then
        return 1, 0, 0, 0
    end
    local inv = 1.0 / sqrt(n2)
    return qw * inv, qx * inv, qy * inv, qz * inv
end

-- shoemake, identity on degenerate/nan
-- det<0 (loaded-map parts, flip_loaded_map_horizontally negates row 1): flip col 1 back to nearest proper rotation, collision-equivalent for a box
function Integrate.quat_from_matrix(r00, r01, r02, r10, r11, r12, r20, r21, r22)
    local det = r00 * (r11 * r22 - r12 * r21)
        - r01 * (r10 * r22 - r12 * r20)
        + r02 * (r10 * r21 - r11 * r20)
    if det < 0 then
        r00, r10, r20 = -r00, -r10, -r20
    end
    local t = r00 + r11 + r22
    local qw, qx, qy, qz
    if t > 0 then
        local s = sqrt(t + 1.0) * 2 -- s = 4*qw
        qw = 0.25 * s
        qx = (r21 - r12) / s
        qy = (r02 - r20) / s
        qz = (r10 - r01) / s
    elseif r00 > r11 and r00 > r22 then
        local s = sqrt(1.0 + r00 - r11 - r22) * 2 -- s = 4*qx
        qw = (r21 - r12) / s
        qx = 0.25 * s
        qy = (r01 + r10) / s
        qz = (r02 + r20) / s
    elseif r11 > r22 then
        local s = sqrt(1.0 + r11 - r00 - r22) * 2 -- s = 4*qy
        qw = (r02 - r20) / s
        qx = (r01 + r10) / s
        qy = 0.25 * s
        qz = (r12 + r21) / s
    else
        local s = sqrt(1.0 + r22 - r00 - r11) * 2 -- s = 4*qz
        qw = (r10 - r01) / s
        qx = (r02 + r20) / s
        qy = (r12 + r21) / s
        qz = 0.25 * s
    end
    return Integrate.quat_normalize(qw, qx, qy, qz)
end

-- in cframe.from_matrix arg order
function Integrate.quat_to_matrix(qw, qx, qy, qz)
    local x, y, z, w = qx, qy, qz, qw
    local xx, yy, zz = x * x, y * y, z * z
    local xy, xz, yz = x * y, x * z, y * z
    local wx, wy, wz = w * x, w * y, w * z
    return 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy),
        2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx),
        2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)
end

-- hamilton product a*b
function Integrate.quat_mul(aw, ax, ay, az, bw, bx, by, bz)
    return aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw
end

-- = inverse rotation for unit quat
function Integrate.quat_conj(qw, qx, qy, qz)
    return qw, -qx, -qy, -qz
end

-- pass conj(q) to go world->body
function Integrate.rotate_vec(qw, qx, qy, qz, vx, vy, vz)
    -- t = 2 * (q_vec x v)
    local tx = 2 * (qy * vz - qz * vy)
    local ty = 2 * (qz * vx - qx * vz)
    local tz = 2 * (qx * vy - qy * vx)
    -- v' = v + qw * t + q_vec x t
    return vx + qw * tx + (qy * tz - qz * ty),
        vy + qw * ty + (qz * tx - qx * tz),
        vz + qw * tz + (qx * ty - qy * tx)
end

-- q' = q + 0.5*(0,w)*q*dt, w is world-frame
function Integrate.quat_integrate(qw, qx, qy, qz, wx, wy, wz, dt)
    local hx, hy, hz = wx * 0.5, wy * 0.5, wz * 0.5
    -- (0,h) * q
    local dqw = -(hx * qx + hy * qy + hz * qz)
    local dqx = hx * qw + hy * qz - hz * qy
    local dqy = hy * qw + hz * qx - hx * qz
    local dqz = hz * qw + hx * qy - hy * qx
    return Integrate.quat_normalize(
        qw + dqw * dt, qx + dqx * dt, qy + dqy * dt, qz + dqz * dt)
end

-- nan -> 0, guards pathological force/velocity
local function clamp_finite(value, limit)
    if value ~= value then -- nan
        return 0
    end
    if value > limit then
        return limit
    end
    if value < -limit then
        return -limit
    end
    return value
end
Integrate.clamp_finite = clamp_finite

-- split so the solver runs between: gravity must land in velocity so the normal impulse cancels approach vel same step, else resting bodies sink

-- phase 1: gravity into velocity, positions untouched, active/count = dense array + valid count (dont use #active), gravity is +magnitude applied as -y
function Integrate.integrate_velocity(active, count, gravity, dt, max_lin)
    gravity = gravity or 0
    local cap = max_lin or MAX_SPEED
    if cap > MAX_SPEED then cap = MAX_SPEED end
    for i = 1, count do
        local b = active[i]
        if b.inv_mass > 0 then
            b.vx = clamp_finite(b.vx, cap)
            local previous_y = b.vy
            b.vy = clamp_finite(previous_y - gravity * dt, cap)
            b._step_gravity_vy = b.vy - previous_y
            b.vz = clamp_finite(b.vz, cap)
        end
    end
end

-- phase 2: position from solver-corrected velocity, then orientation, max_lin/max_ang catch solver runaway (distinct from the 1e6 finiteness guard)
function Integrate.integrate_position(active, count, dt, max_lin, max_ang)
    local lcap = max_lin or MAX_SPEED
    if lcap > MAX_SPEED then lcap = MAX_SPEED end
    local acap = max_ang or MAX_OMEGA
    if acap > MAX_OMEGA then acap = MAX_OMEGA end
    for i = 1, count do
        local b = active[i]
        if b.inv_mass > 0 then
            -- clamp linear (solver mightve bumped it) then advance
            local vx = clamp_finite(b.vx, lcap)
            local vy = clamp_finite(b.vy, lcap)
            local vz = clamp_finite(b.vz, lcap)
            b.vx, b.vy, b.vz = vx, vy, vz
            b.com_x = b.com_x + vx * dt
            b.com_y = b.com_y + vy * dt
            b.com_z = b.com_z + vz * dt

            -- clamp angular (catches exponential spin) then advance
            local wx = clamp_finite(b.wx, acap)
            local wy = clamp_finite(b.wy, acap)
            local wz = clamp_finite(b.wz, acap)
            b.wx, b.wy, b.wz = wx, wy, wz
            if wx ~= 0 or wy ~= 0 or wz ~= 0 then
                b.qw, b.qx, b.qy, b.qz =
                    Integrate.quat_integrate(b.qw, b.qx, b.qy, b.qz, wx, wy, wz, dt)
            end
        end
    end
end

-- one substep, no contact solving, force_* not read here, impulse api writes velocity directly
function Integrate.step(active, count, gravity, dt)
    Integrate.integrate_velocity(active, count, gravity, dt)
    Integrate.integrate_position(active, count, dt)
end

return Integrate
