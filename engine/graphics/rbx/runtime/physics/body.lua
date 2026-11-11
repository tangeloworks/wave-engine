-- rigidbody state only (mass/inertia/com/vel/force), one per assembly

local Body = {}
Body.__index = Body
local Shape = runtime_require("physics/shape.lua")

-- opts: id, is_static, parts/part_count, assembly (back-ref), mass, inertia_x/y/z, com_x/y/z
function Body.new(opts)
    opts = opts or {}
    local is_static = opts.is_static == true

    local self = setmetatable({}, Body)
    self.id = opts.id
    self.is_static = is_static
    self.kind = is_static and "static" or "dynamic"
    self.sleeping = false
    self.sleep_timer = 0

    -- 1-based slot in world.active_bodies, 0 = inactive
    self.active_index = 0
    self.world = nil

    self.parts = opts.parts or {}
    self.part_count = opts.part_count or #self.parts
    self.assembly = opts.assembly

    self.com_x = tonumber(opts.com_x) or 0
    self.com_y = tonumber(opts.com_y) or 0
    self.com_z = tonumber(opts.com_z) or 0

    self.vx, self.vy, self.vz = 0, 0, 0
    self.wx, self.wy, self.wz = 0, 0, 0
    self.force_x, self.force_y, self.force_z = 0, 0, 0
    self.torque_x, self.torque_y, self.torque_z = 0, 0, 0

    -- unit quat, world frame, glue overwrites from root cframe at bind
    self.qw, self.qx, self.qy, self.qz = 1, 0, 0, 0

    -- filled at bind {view,lx,ly,lz,qw,qx,qy,qz}, pose write-back moves welded assembly as one
    self.local_offsets = {}

    -- before mass props: they zero inverse inertia when locked
    self.rotation_locked = opts.rotation_locked == true

    self:set_mass_properties(opts.mass or 0, opts.inertia_x or 0, opts.inertia_y or 0, opts.inertia_z or 0)
    return self
end

-- inv_inertia is body-local, world tensor = r*diag*r^t via update_world_inertia, else tilted boxes spurious-torque/flip
function Body:set_mass_properties(mass, ix, iy, iz)
    self._motion_radius = nil -- also called by in-place Size/shape changes
    mass = tonumber(mass) or 0
    self.mass = mass
    self.inertia_x = tonumber(ix) or 0
    self.inertia_y = tonumber(iy) or 0
    self.inertia_z = tonumber(iz) or 0

    if self.is_static or mass <= 0 then
        self.inv_mass = 0
        self.inv_inertia_x = 0
        self.inv_inertia_y = 0
        self.inv_inertia_z = 0
    else
        self.inv_mass = 1 / mass
        self.inv_inertia_x = self.inertia_x > 0 and 1 / self.inertia_x or 0
        self.inv_inertia_y = self.inertia_y > 0 and 1 / self.inertia_y or 0
        self.inv_inertia_z = self.inertia_z > 0 and 1 / self.inertia_z or 0
    end
    -- rotation-locked (NPC boxes): zero inverse inertia, raw inertia_x/y/z kept so
    -- unlocking restores. every solver/impulse angular term multiplies through the
    -- zero tensor, so the quat never changes -- an unrotated spawn stays exactly
    -- axis-aligned and keeps the cheap aa narrowphase path forever
    if self.rotation_locked then
        self.inv_inertia_x, self.inv_inertia_y, self.inv_inertia_z = 0, 0, 0
    end
    self:update_world_inertia()
end

-- flag lives on the body so assembly rebuilds re-derive it from the part (see
-- Assembly.build), direct writes to wx/wy/wz still rotate -- glue never does that
-- for locked bodies
function Body:set_rotation_locked(locked)
    locked = locked == true
    if (self.rotation_locked == true) == locked then
        return
    end
    self.rotation_locked = locked
    if locked then
        self.wx, self.wy, self.wz = 0, 0, 0
    end
    self:set_mass_properties(self.mass, self.inertia_x, self.inertia_y, self.inertia_z)
end

-- r*diag*r^t, cheap, once per body per step
function Body:update_world_inertia()
    local dx, dy, dz = self.inv_inertia_x or 0, self.inv_inertia_y or 0, self.inv_inertia_z or 0
    if dx == 0 and dy == 0 and dz == 0 then
        self.wii_xx, self.wii_yy, self.wii_zz = 0, 0, 0
        self.wii_xy, self.wii_xz, self.wii_yz = 0, 0, 0
        return
    end
    local w, x, y, z = self.qw or 1, self.qx or 0, self.qy or 0, self.qz or 0
    local xx, yy, zz = x * x, y * y, z * z
    local xy, xz, yz = x * y, x * z, y * z
    local wx, wy, wz = w * x, w * y, w * z
    local r00, r01, r02 = 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)
    local r10, r11, r12 = 2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)
    local r20, r21, r22 = 2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)
    self.wii_xx = r00 * r00 * dx + r01 * r01 * dy + r02 * r02 * dz
    self.wii_yy = r10 * r10 * dx + r11 * r11 * dy + r12 * r12 * dz
    self.wii_zz = r20 * r20 * dx + r21 * r21 * dy + r22 * r22 * dz
    self.wii_xy = r00 * r10 * dx + r01 * r11 * dy + r02 * r12 * dz
    self.wii_xz = r00 * r20 * dx + r01 * r21 * dy + r02 * r22 * dz
    self.wii_yz = r10 * r20 * dx + r11 * r21 * dy + r12 * r22 * dz
end

-- impulses wake the assembly; a zero inverse mass leaves its velocity unchanged

function Body:apply_impulse(ix, iy, iz)
    if self.inv_mass == 0 then
        return
    end
    self.vx = self.vx + ix * self.inv_mass
    self.vy = self.vy + iy * self.inv_mass
    self.vz = self.vz + iz * self.inv_mass
    self:wake()
end

-- angular dw = i^-1*(r x j), r = pos-com
function Body:apply_impulse_at(ix, iy, iz, px, py, pz)
    if self.inv_mass == 0 then
        return
    end
    self.vx = self.vx + ix * self.inv_mass
    self.vy = self.vy + iy * self.inv_mass
    self.vz = self.vz + iz * self.inv_mass
    local rx, ry, rz = px - self.com_x, py - self.com_y, pz - self.com_z
    local tx = ry * iz - rz * iy
    local ty = rz * ix - rx * iz
    local tz = rx * iy - ry * ix
    self:update_world_inertia()
    self.wx = self.wx + self.wii_xx * tx + self.wii_xy * ty + self.wii_xz * tz
    self.wy = self.wy + self.wii_xy * tx + self.wii_yy * ty + self.wii_yz * tz
    self.wz = self.wz + self.wii_xz * tx + self.wii_yz * ty + self.wii_zz * tz
    self:wake()
end

function Body:apply_angular_impulse(ix, iy, iz)
    if self.inv_mass == 0 then
        return
    end
    self:update_world_inertia()
    self.wx = self.wx + self.wii_xx * ix + self.wii_xy * iy + self.wii_xz * iz
    self.wy = self.wy + self.wii_xy * ix + self.wii_yy * iy + self.wii_yz * iz
    self.wz = self.wz + self.wii_xz * ix + self.wii_yz * iy + self.wii_zz * iz
    self:wake()
end

-- cold wake (impulse/setters/movers): flags world active_dirty for next-step reconcile
-- hot path uses world:sleep_body/wake_body, not this
function Body:wake()
    if self.is_static then
        return
    end
    -- reset idle timer even if already awake, only flag world on the flip
    self.sleep_timer = 0
    self.deep_timer, self.deep_ref_x, self.deep_ref_qw, self.deep_slept = 0, nil, nil, false
    if not self.sleeping then
        return
    end
    self.sleeping = false
    self._step_gravity_vy = 0
    local w = self.world
    if w then
        w.active_dirty = true
        w.wake_event_count = (w.wake_event_count or 0) + 1
    end
end

function Body:sleep()
    if self.sleeping then
        return
    end
    self.sleeping = true
    self.sleep_timer = 0
    self.vx, self.vy, self.vz = 0, 0, 0
    self.wx, self.wy, self.wz = 0, 0, 0
    local w = self.world
    if w then w.active_dirty = true end
end

function Body:is_active()
    return not self.is_static and not self.sleeping
end

-- conservative assembly radius, shared by sleep and connected-neighbour wake
-- checks. Mass/shape/topology changes invalidate this cache
function Body:bounding_radius()
    if self._motion_radius then return self._motion_radius end
    local radius = 0
    for _, o in ipairs(self.local_offsets or {}) do
        local x,y,z = Shape.half_extents(o.view)
        local r = math.sqrt(x*x+y*y+z*z) + math.sqrt(o.lx*o.lx+o.ly*o.ly+o.lz*o.lz)
        if r > radius then radius = r end
    end
    self._motion_radius = radius > 0 and radius or 1
    return self._motion_radius
end

return Body
