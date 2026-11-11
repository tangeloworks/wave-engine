-- optional RBX third-person character controller
--
-- the controller owns locomotion of one dynamic part: ground probing, slope
-- and step handling, moving supports, jumps, launches and holds. a project
-- feeds camera-relative input and calls `pre_simulation` from the RBX
-- RunService.FixedHeartbeat hook. Rendering, animation, abilities and camera
-- stay project-owned. Movement uses a BodyForce and ray queries, positions
-- are never rewritten, so contacts and Touched events stay physical

local rbx = require("engine/graphics/rbx")
local Vector3
local CFrame
local UP
local ZERO

local Character = {}
Character.__index = Character

local function ensure_runtime_types()
    if Vector3 then return end
    -- Accessing RBX public types initializes the optional runtime. Delaying it
    -- until construction lets ordinary 2D projects require metadata without
    -- paying for the renderer or its physics backend
    Vector3 = rbx.Vector3
    CFrame = rbx.CFrame
    UP = Vector3.new(0, 1, 0)
    ZERO = Vector3.new(0, 0, 0)
end

local function clamp(value, lower, upper)
    if value < lower then return lower end
    if value > upper then return upper end
    return value
end

local function horizontal_length(vector)
    return math.sqrt(vector.x * vector.x + vector.z * vector.z)
end

local function horizontal_unit(vector)
    local length = horizontal_length(vector)
    if length <= 0.00001 then return ZERO, 0 end
    return Vector3.new(vector.x / length, 0, vector.z / length), length
end

local function project_on_plane(vector, normal)
    return vector - normal * (vector.x * normal.x + vector.y * normal.y + vector.z * normal.z)
end

local function part_mass(part)
    if not part then return 1 end
    if type(part.GetMass) == "function" then
        local ok, mass = pcall(part.GetMass, part)
        if ok and type(mass) == "number" and mass > 0 then return mass end
    end
    local mass = tonumber(part.Mass)
    return mass and mass > 0 and mass or 1
end

local function property_number(properties, lower_name, upper_name, fallback)
    if type(properties) ~= "table" then return fallback end
    local value = tonumber(properties[lower_name] or properties[upper_name])
    return value and value == value and value or fallback
end

-- matches the runtime contact-material policy: material weights blend each
-- surface's friction. the controller uses this only to budget enough drive
-- force to overcome static traction, contact resolution remains entirely in
-- the physics solver
local function combined_friction(first, second)
    local first_friction = clamp(property_number(first, "friction", "Friction", 0.3), 0, 2)
    local second_friction = clamp(property_number(second, "friction", "Friction", 0.3), 0, 2)
    local first_weight = clamp(property_number(first, "friction_weight", "FrictionWeight", 1), 0, 100)
    local second_weight = clamp(property_number(second, "friction_weight", "FrictionWeight", 1), 0, 100)
    local weight = first_weight + second_weight
    if weight <= 0 then return (first_friction + second_friction) * 0.5 end
    return (first_friction * first_weight + second_friction * second_weight) / weight
end

-- Ground probes include peripheral rays for stable seam/edge detection. a
-- peripheral vertical hit lies on the same slope plane but not necessarily
-- below the body's centre, so project its plane to the requested X/Z before
-- deriving a support height
local function plane_height_at(hit, x, z)
    if not hit or not hit.Position or not hit.Normal then return nil end
    local normal = hit.Normal
    local normal_y = tonumber(normal.y) or 0
    if math.abs(normal_y) < 0.00001 then return nil end
    local point = hit.Position
    return point.y - ((normal.x or 0) * (x - point.x) + (normal.z or 0) * (z - point.z)) / normal_y
end

local function find_child(parent, name)
    if parent and type(parent.FindFirstChild) == "function" then
        local ok, child = pcall(parent.FindFirstChild, parent, name)
        if ok then return child end
    end
    return parent and parent[name] or nil
end

-- Velocity of a support part at a world point, including its rotation
-- Script-driven anchored platforms report the Velocity they were given
local function point_velocity(part, point)
    if not part then return ZERO end
    local linear = part.AssemblyLinearVelocity or part.Velocity
    local angular = part.AssemblyAngularVelocity or part.RotVelocity
    if not linear then return ZERO end
    if angular and (angular.x ~= 0 or angular.y ~= 0 or angular.z ~= 0) and part.Position then
        local r = point - part.Position
        linear = linear + Vector3.new(
            angular.y * r.z - angular.z * r.y,
            angular.z * r.x - angular.x * r.z,
            angular.x * r.y - angular.y * r.x)
    end
    return linear
end

local function camera_direction(yaw, input_x, input_y)
    local forward = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
    local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
    local direction = right * (tonumber(input_x) or 0) + forward * (tonumber(input_y) or 0)
    local unit, length = horizontal_unit(direction)
    -- input APIs sometimes expose analog values longer than one when keyboard
    -- and a stick are both active. preserve the desired analog magnitude while
    -- never giving diagonal motion a speed advantage
    return unit * math.min(1, length), math.min(1, length)
end

local function default_options(part)
    local size = part and part.Size
    local radius = math.max(
        (size and tonumber(size.x) or 2) * 0.5,
        (size and tonumber(size.y) or 2) * 0.5,
        (size and tonumber(size.z) or 2) * 0.5
    )
    return {
        radius = radius,
        walk_speed = 30,
        run_speed = 40,
        ground_acceleration = 18,
        ground_deceleration = 24,
        air_acceleration = 6,
        air_deceleration = 2,
        -- this is a desired net horizontal acceleration, not an arbitrary
        -- force multiplier. Ground traction is added separately below so an
        -- ordinary material can never cancel all player input before motion
        max_force_multiplier = 42,
        jump_speed = 48,
        jump_buffer = 0.12,
        coyote_time = 0.10,
        jump_cooldown = 0.08,
        max_slope_angle = math.rad(50),
        ground_probe = 0.38,
        ground_snap_distance = 0.45,
        ground_snap_spring = 72,
        ground_snap_damping = 12,
        ground_snap_max_acceleration = 245,
        ground_upward_velocity_tolerance = 1.0,
        jump_ground_ignore_time = 0.12,
        step_height = math.max(0.6, radius * 0.72),
        step_probe_distance = radius + 0.9,
        step_lift_speed = 18,
        step_cooldown = 0.13,
        wall_probe_height = math.max(0.4, radius * 0.65),
        wall_probe_distance = radius + 0.22,
        -- a wall is any hit whose normal is steeper than this
        wall_max_normal_y = 0.3,
        orientation_torque = 250000,
        orientation_p = 18000,
        orientation_d = 850,
        -- Inherit the velocity of the part being stood on (moving platforms)
        carry_support = true,
        gravity_scale = 1,
        -- optional terminal fall speed in studs/s, nil leaves falls uncapped
        max_fall_speed = nil,
        hold_spring = 160,
        hold_damping = 24,
        hold_max_acceleration = 900,
        -- Traction model for a frictionless body (Friction 0 with a high
        -- FrictionWeight). when set, grounded acceleration is limited to
        -- min_traction + gravity * surface friction * surface_traction, so
        -- ice is slippery and rubber grips, and slopes are compensated. Nil
        -- keeps the default model: body friction plus max_force_multiplier
        surface_traction = nil,
        min_traction = 8,
    }
end

local function merged_options(part, supplied)
    local options = default_options(part)
    for key, value in pairs(supplied or {}) do options[key] = value end
    options.radius = math.max(0.2, tonumber(options.radius) or 1)
    options.walk_speed = math.max(0, tonumber(options.walk_speed) or 0)
    options.run_speed = math.max(options.walk_speed, tonumber(options.run_speed) or options.walk_speed)
    options.max_slope_angle = clamp(tonumber(options.max_slope_angle) or math.rad(50), 0, math.rad(89))
    options.min_ground_normal = math.cos(options.max_slope_angle)
    return options
end

---create a force-driven character controller
---
---Options (all optional): radius, walk_speed, run_speed, ground/air
---acceleration and deceleration rates, jump_speed, coyote_time, jump_buffer,
---max_slope_angle, step_height, carry_support, gravity_scale,
---max_fall_speed, orientation (true holds the body upright with a BodyGyro,
---false never does, by default every shape except a Ball is held), and the
---callbacks on_land(controller, impact_speed, ground_hit), on_leave_ground
---(controller) and on_jump(controller). `controller.options` stays mutable,
---so a project can retune speeds per movement state
---@param workspace RBXLXWorkspace
---@param part RBXLXPart
---@param options table|nil
---@return table
function Character.new(workspace, part, options)
    ensure_runtime_types()
    assert(workspace and type(workspace.Raycast) == "function", "Character controller needs an RBX workspace")
    assert(part, "Character controller needs a dynamic RBX part")

    local config = merged_options(part, options)
    local self = setmetatable({
        workspace = workspace,
        part = part,
        options = config,
        enabled = true,
        input_x = 0,
        input_y = 0,
        camera_yaw = 0,
        running = false,
        desired_direction = ZERO,
        desired_magnitude = 0,
        facing = Vector3.new(0, 0, 1),
        facing_locked = false,
        target_velocity = nil,
        grounded = false,
        ground = nil,
        ground_normal = UP,
        ground_distance = nil,
        support_velocity = ZERO,
        air_time = 0,
        ground_time = 0,
        coyote_remaining = 0,
        jump_buffer_remaining = 0,
        jump_cooldown_remaining = 0,
        jump_ground_ignore_remaining = 0,
        step_cooldown_remaining = 0,
        hold = nil,
        _ray_ignore = { part },
        _ground_offsets = {
            Vector3.new(0, 0, 0),
            Vector3.new(config.radius * 0.56, 0, 0),
            Vector3.new(-config.radius * 0.56, 0, 0),
            Vector3.new(0, 0, config.radius * 0.56),
            Vector3.new(0, 0, -config.radius * 0.56),
        },
        _created_force = false,
        _created_gyro = false,
    }, Character)

    local force = options and options.body_force or find_child(part, "WaveCharacterForce")
    if not force then
        force = rbx.Instance.new("BodyForce", {
            Name = "WaveCharacterForce",
            Parent = part,
            Force = Vector3.new(0, 0, 0),
        })
        self._created_force = true
    end
    self.force = force

    -- a RotationLocked body cannot turn, so it needs no orientation mover
    -- a ball rolls: held upright it would slide against surface friction
    local orientation = options and options.orientation
    local wants_gyro = part.RotationLocked ~= true and orientation ~= false
        and (orientation == true or tostring(part.Shape):match("Ball") == nil)
    if wants_gyro then
        local gyro = options and options.body_gyro or find_child(part, "WaveCharacterUpright")
        if not gyro then
            gyro = rbx.Instance.new("BodyGyro", {
                Name = "WaveCharacterUpright",
                Parent = part,
                MaxTorque = Vector3.new(config.orientation_torque, config.orientation_torque,
                    config.orientation_torque),
                P = config.orientation_p,
                D = config.orientation_d,
                CFrame = CFrame.lookAt(part.Position, part.Position + self.facing, UP),
            })
            self._created_gyro = true
        end
        self.gyro = gyro
    end

    return self
end

---set camera-relative movement input. `forward` means the direction the
---camera faces on the XZ plane, the controller owns no keyboard or mouse
---handlers, avoiding conflicts with project UI/camera ownership
function Character:set_input(x, forward, yaw, running)
    self.input_x = clamp(tonumber(x) or 0, -1, 1)
    self.input_y = clamp(tonumber(forward) or 0, -1, 1)
    if yaw ~= nil then self.camera_yaw = tonumber(yaw) or self.camera_yaw end
    self.running = running == true
end

function Character:set_camera_yaw(yaw)
    self.camera_yaw = tonumber(yaw) or self.camera_yaw
end

function Character:set_enabled(enabled)
    self.enabled = enabled == true
    if not self.enabled then
        self.jump_buffer_remaining = 0
        self.jump_ground_ignore_remaining = 0
        if self.force then self.force.Force = Vector3.new(0, 0, 0) end
    end
end

function Character:queue_jump()
    if self.enabled then
        self.jump_buffer_remaining = self.options.jump_buffer
    end
end

function Character:is_grounded()
    return self.grounded == true
end

function Character:get_ground()
    return self.ground
end

---true while grounded or inside the coyote window after walking off a ledge
function Character:can_ground_jump()
    return self.grounded == true or self.coyote_remaining > 0
end

---Override the horizontal velocity the controller steers toward. pass nil to
---return to input-driven movement. the vector is relative to the support
function Character:set_target_velocity(velocity)
    self.target_velocity = velocity
end

function Character:set_gravity_scale(scale)
    self.options.gravity_scale = tonumber(scale) or 1
end

---Face a horizontal direction. With `lock`, input no longer turns the body
function Character:set_facing(direction, lock)
    local unit, length = horizontal_unit(direction)
    if length > 0.0001 then self.facing = unit end
    if lock ~= nil then self.facing_locked = lock == true end
end

---replace the body's velocity (jumps, pads, abilities) and leave the ground
---Ground snapping is suspended briefly so the launch is not cancelled
function Character:launch(velocity, ignore_ground_time)
    self.part.Velocity = velocity
    self.jump_ground_ignore_remaining = ignore_ground_time or self.options.jump_ground_ignore_time
    self.coyote_remaining = 0
    self.jump_buffer_remaining = 0
    if self.grounded then
        self.grounded = false
        self.ground = nil
        self.air_time = 0
        if self.options.on_leave_ground then self.options.on_leave_ground(self) end
    end
end

---Hold the body at a world point with a damped spring that also cancels
---gravity (ledge hangs, short hovers). With `part`, the point follows it
function Character:set_hold(position, part)
    if not position then
        self.hold = nil
        return
    end
    local hold = { position = position }
    if part and part.CFrame then
        hold.part = part
        hold.local_point = part.CFrame:PointToObjectSpace(position)
    end
    self.hold = hold
end

function Character:clear_hold()
    self.hold = nil
end

function Character:get_velocity()
    return self.part.Velocity
end

function Character:get_state()
    return {
        grounded = self.grounded == true,
        ground = self.ground,
        ground_normal = self.ground_normal,
        ground_distance = self.ground_distance,
        support_velocity = self.support_velocity,
        air_time = self.air_time,
        ground_time = self.ground_time,
        coyote_remaining = self.coyote_remaining,
        jump_ground_ignore_remaining = self.jump_ground_ignore_remaining,
        desired_direction = self.desired_direction,
        facing = self.facing,
        holding = self.hold ~= nil,
    }
end

function Character:_raycast(origin, direction)
    return self.workspace:Raycast(origin, direction, {
        "Blacklist",
        self._ray_ignore,
        RespectCanCollide = true,
        _rbx_filter_static = true,
    })
end

---exclude more parts (visual rig, held items) from every controller probe
function Character:ignore(part)
    self._ray_ignore[#self._ray_ignore + 1] = part
end

---Cast horizontally from the body for a steep surface. returns the ray hit,
---or nil when nothing wall-like is within `distance`
function Character:probe_wall(direction, distance, height)
    local unit, length = horizontal_unit(direction)
    if length <= 0.0001 then return nil end
    local origin = self.part.Position + UP * (height or 0)
    local hit = self:_raycast(origin, unit * (distance or self.options.wall_probe_distance))
    if hit and hit.Normal and math.abs(hit.Normal.y) <= self.options.wall_max_normal_y then
        return hit
    end
    return nil
end

---look for a walkable top above a wall hit. `reach` is how far above the
---body centre a top may be, returns { position, normal, part } or nil
function Character:probe_ledge(wall_hit, reach, inset)
    if not wall_hit then return nil end
    local config = self.options
    reach = reach or config.radius * 2.5
    inset = inset or 0.5
    local body = self.part.Position
    local normal = wall_hit.Normal
    local start = Vector3.new(wall_hit.Position.x, body.y + reach, wall_hit.Position.z)
        - Vector3.new(normal.x, 0, normal.z) * inset
    -- the space in front of the wall at the top must be open to climb into
    if self:_raycast(Vector3.new(body.x, body.y + reach, body.z), start - Vector3.new(body.x, body.y + reach, body.z)) then
        return nil
    end
    local top = self:_raycast(start, Vector3.new(0, -(reach + config.radius), 0))
    if not top or not top.Normal or top.Normal.y < config.min_ground_normal then return nil end
    if top.Position.y < body.y - config.radius * 0.25 then return nil end
    return { position = top.Position, normal = top.Normal, part = top.Instance, wall_normal = normal }
end

function Character:_refresh_ground()
    local part = self.part
    local config = self.options
    local radius = config.radius
    local position = part.Position
    local velocity = part.Velocity
    -- a ray can still reach the floor for a few substeps after a jump. treat
    -- that as air time rather than immediately restoring ground snap/damping
    -- the same rule keeps external upward launches from being glued to slopes
    local relative_vy = velocity and (velocity.y - self.support_velocity.y) or 0
    if self.jump_ground_ignore_remaining > 0
        or relative_vy > config.ground_upward_velocity_tolerance then
        self.ground = nil
        self.grounded = false
        self.ground_normal = UP
        self.ground_distance = nil
        return
    end
    local reach = radius + config.ground_probe + config.ground_snap_distance
    local down = Vector3.new(0, -reach, 0)
    local best

    -- Centre plus four peripheral probes make a ball/capsule approximation
    -- stable on the edges of steps and modest slopes without allocating a
    -- collider proxy or depending on game-specific map geometry
    for index = 1, #self._ground_offsets do
        local origin = position + self._ground_offsets[index]
        local hit = self:_raycast(origin, down)
        if hit and hit.Normal and hit.Normal.y >= config.min_ground_normal then
            if not best or hit.Distance < best.Distance then best = hit end
        end
    end

    self.ground = best
    self.grounded = best ~= nil
    self.ground_normal = best and best.Normal or UP
    self.ground_distance = best and best.Distance or nil
    if self.grounded then self.coyote_remaining = config.coyote_time end
end

function Character:_resolve_wall_direction(direction)
    local config = self.options
    local unit, length = horizontal_unit(direction)
    if length <= 0.0001 then return direction end
    local origin = self.part.Position + UP * config.wall_probe_height
    local hit = self:_raycast(origin, unit * config.wall_probe_distance)
    if not hit or not hit.Normal or hit.Normal.y >= config.min_ground_normal then
        return direction
    end
    local into = direction.x * hit.Normal.x + direction.z * hit.Normal.z
    if into < 0 then
        local slide = Vector3.new(
            direction.x - hit.Normal.x * into,
            0,
            direction.z - hit.Normal.z * into
        )
        local result, result_length = horizontal_unit(slide)
        if result_length > 0.0001 then return result * length end
        return Vector3.new(0, 0, 0)
    end
    return direction
end

function Character:_try_step(direction)
    if not self.grounded or self.step_cooldown_remaining > 0 then return false end
    local config = self.options
    local unit, speed = horizontal_unit(direction)
    if speed <= 0.0001 then return false end

    local position = self.part.Position
    local forward = unit * config.step_probe_distance
    -- probe just above the current support at two heights. a probe from the
    -- middle of the sphere passes over short steps entirely, so the contact
    -- would already be wedged into the vertical face before a lift
    local ground_y = plane_height_at(self.ground, position.x, position.z)
    if type(ground_y) ~= "number" then return false end
    local obstruction
    local probe_heights = { math.min(0.08, config.step_height * 0.25), config.step_height * 0.5 }
    for index = 1, #probe_heights do
        local low_origin = Vector3.new(position.x, ground_y + probe_heights[index], position.z)
        local hit = self:_raycast(low_origin, forward)
        if hit and hit.Normal and hit.Normal.y < config.min_ground_normal then
            obstruction = hit
            break
        end
    end
    if not obstruction then return false end

    -- Clearance at head/step height and a walkable surface ahead prove this is
    -- a small ledge, rather than a wall. a short upward velocity is a physics
    -- impulse, not a per-frame position teleport
    local high_origin = position + UP * (config.radius + config.step_height + 0.1)
    if self:_raycast(high_origin, forward) then return false end
    local top_origin = position + forward + UP * (config.radius + config.step_height + 0.16)
    local top = self:_raycast(top_origin,
        Vector3.new(0, -(config.radius + config.step_height + config.ground_probe + 0.25), 0))
    if not top or top.Normal.y < config.min_ground_normal or not self.ground then return false end

    local top_y = plane_height_at(top, position.x + forward.x, position.z + forward.z)
    if type(top_y) ~= "number" then return false end
    local rise = top_y - ground_y
    if rise < 0.06 or rise > config.step_height then return false end
    local velocity = self.part.Velocity
    local lift = math.max(velocity.y, config.step_lift_speed * (0.45 + rise / config.step_height))
    self.part.Velocity = Vector3.new(velocity.x, lift, velocity.z)
    self.step_cooldown_remaining = config.step_cooldown
    self.grounded = false
    self.coyote_remaining = 0
    return true
end

function Character:_try_jump()
    if self.jump_buffer_remaining <= 0 or self.jump_cooldown_remaining > 0 then return false end
    if self.coyote_remaining <= 0 then return false end
    local velocity = self.part.Velocity
    self:launch(Vector3.new(velocity.x, self.support_velocity.y + self.options.jump_speed, velocity.z))
    self.jump_cooldown_remaining = self.options.jump_cooldown
    if self.options.on_jump then self.options.on_jump(self) end
    return true
end

function Character:_apply_orientation(direction)
    if not self.facing_locked then
        local unit, length = horizontal_unit(direction)
        if length > 0.001 then self.facing = unit end
    end
    if not self.gyro then return end
    local position = self.part.Position
    self.gyro.CFrame = CFrame.lookAt(position, position + self.facing, UP)
end

function Character:_apply_hold(mass, gravity)
    local hold = self.hold
    local target = hold.position
    local support = ZERO
    if hold.part then
        if hold.part.Parent == nil then
            self.hold = nil
            return false
        end
        target = hold.part.CFrame:PointToWorldSpace(hold.local_point)
        hold.position = target
        support = point_velocity(hold.part, target)
    end
    local config = self.options
    local position = self.part.Position
    local velocity = self.part.Velocity - support
    local acceleration = (target - position) * config.hold_spring - velocity * config.hold_damping
    local length = acceleration.Magnitude
    if length > config.hold_max_acceleration then
        acceleration = acceleration * (config.hold_max_acceleration / length)
    end
    self.force.Force = acceleration * mass + UP * (gravity * mass)
    return true
end

---Advance controller state once from the RBX FixedHeartbeat hook. the method
---is frame-rate independent: acceleration derives from velocity error and
---actual `dt`, while the physics world performs integration/collision
---@param dt number
function Character:pre_simulation(dt)
    dt = clamp(tonumber(dt) or 0, 0, 1 / 15)
    local part = self.part
    if not part or not self.force then return end
    if not self.enabled or part.Anchored == true then
        self.force.Force = Vector3.new(0, 0, 0)
        return
    end
    local config = self.options

    self.jump_buffer_remaining = math.max(0, self.jump_buffer_remaining - dt)
    self.coyote_remaining = math.max(0, self.coyote_remaining - dt)
    self.jump_cooldown_remaining = math.max(0, self.jump_cooldown_remaining - dt)
    self.jump_ground_ignore_remaining = math.max(0, self.jump_ground_ignore_remaining - dt)
    self.step_cooldown_remaining = math.max(0, self.step_cooldown_remaining - dt)

    local was_grounded = self.grounded
    local velocity = part.Velocity
    local landing_speed = -(velocity.y - self.support_velocity.y)
    self:_refresh_ground()
    -- in the air the body already carries its support's momentum, so the
    -- reference frame returns to the world. keeping a stale support velocity
    -- made a body that left a moving part look "launched" forever
    if self.grounded and config.carry_support and self.ground.Instance then
        self.support_velocity = point_velocity(self.ground.Instance, self.ground.Position)
    else
        self.support_velocity = ZERO
    end

    if self.grounded then
        self.ground_time = self.ground_time + dt
        if not was_grounded then
            self.air_time = 0
            if config.on_land then config.on_land(self, math.max(0, landing_speed), self.ground) end
        end
    else
        self.air_time = self.air_time + dt
        if was_grounded then
            self.ground_time = 0
            if config.on_leave_ground then config.on_leave_ground(self) end
        end
    end

    local mass = part_mass(part)
    local gravity = math.abs(tonumber(self.workspace.Gravity) or 196.2)
    if self.hold and self:_apply_hold(mass, gravity) then
        self:_apply_orientation(ZERO)
        return
    end

    local desired, magnitude = camera_direction(self.camera_yaw, self.input_x, self.input_y)
    self.desired_direction, self.desired_magnitude = desired, magnitude

    local ground_normal = self.grounded and self.ground_normal or nil
    if ground_normal then
        local planar = project_on_plane(desired, ground_normal)
        local planar_unit, planar_length = horizontal_unit(planar)
        desired = planar_unit * planar_length
    end
    desired = self:_resolve_wall_direction(desired)

    self:_try_jump()
    if self.grounded and self.jump_cooldown_remaining <= 0 and not self.target_velocity then
        self:_try_step(desired)
    end

    local support = self.support_velocity
    velocity = part.Velocity
    local horizontal_velocity = Vector3.new(velocity.x - support.x, 0, velocity.z - support.z)
    local target_velocity
    local has_input
    if self.target_velocity then
        local target = self.target_velocity
        target_velocity = Vector3.new(target.x, 0, target.z)
        has_input = true
    else
        local speed = self.running and config.run_speed or config.walk_speed
        target_velocity = desired * speed
        has_input = horizontal_length(desired) > 0.001
    end
    local velocity_error = target_velocity - horizontal_velocity
    local rate
    if self.grounded then
        rate = has_input and config.ground_acceleration or config.ground_deceleration
    else
        rate = has_input and config.air_acceleration or config.air_deceleration
    end

    local raw_force = velocity_error * (mass * rate)
    local max_acceleration = config.max_force_multiplier
    local traction = 0
    local ground_part = self.grounded and self.ground and self.ground.Instance
    if ground_part then
        local ground_properties = ground_part.CurrentPhysicalProperties
        local normal_y = math.max(0, self.ground_normal.y)
        if config.surface_traction then
            -- the body is frictionless, grip comes from the surface alone
            traction = gravity * clamp(property_number(ground_properties, "friction", "Friction", 0.3), 0, 2)
                * normal_y
            max_acceleration = config.min_traction + traction * config.surface_traction
        else
            -- on a slope the support load falls with its up component. this
            -- is a force budget only, the solver still decides the actual
            -- friction impulse and wall/edge contacts
            traction = gravity * combined_friction(part.CurrentPhysicalProperties, ground_properties)
                * normal_y
            max_acceleration = max_acceleration + traction
        end
    end
    local horizontal_max_force = mass * max_acceleration
    local force_length = math.sqrt(raw_force.x * raw_force.x + raw_force.z * raw_force.z)
    local fx, fz = raw_force.x, raw_force.z
    if force_length > horizontal_max_force and force_length > 0 then
        local scale = horizontal_max_force / force_length
        fx, fz = fx * scale, fz * scale
    end
    local fy = 0
    if self.grounded and self.ground and self.jump_cooldown_remaining <= 0 then
        -- the support ray is vertical. on a slope, a sphere whose centre is
        -- one radius along the contact normal is `radius / normal.y` above the
        -- ray hit, not `radius * normal.y`, the latter pulled the player into
        -- uphill surfaces and caused contact/floor sticking
        local support_y = math.max(0.05, self.ground_normal.y)
        local plane_y = plane_height_at(self.ground, part.Position.x, part.Position.z)
        local target_y = (plane_y or self.ground.Position.y) + config.radius / support_y
        local error_y = target_y - part.Position.y
        if math.abs(error_y) <= config.ground_snap_distance then
            local vertical_max_force = mass * config.ground_snap_max_acceleration
            fy = clamp((error_y * config.ground_snap_spring
                - (velocity.y - support.y) * config.ground_snap_damping) * mass,
                -vertical_max_force, vertical_max_force)
        end
    elseif not self.grounded then
        local scale = tonumber(config.gravity_scale) or 1
        if scale ~= 1 then fy = fy + mass * gravity * (1 - scale) end
        local max_fall = tonumber(config.max_fall_speed)
        if max_fall and velocity.y < -max_fall then
            -- Drag toward the terminal speed instead of clamping velocity
            fy = fy + mass * math.min(gravity * 3, (-max_fall - velocity.y) * 20)
        end
    end
    if ground_part and config.surface_traction then
        -- without friction, the contact normal on a slope pushes the body
        -- downhill with (weight - lift) * n_horizontal / n_y. Cancel it so a
        -- standing body stays put and speeds match on slopes
        local normal = self.ground_normal
        local load = math.max(0, mass * gravity - fy) / math.max(0.2, normal.y)
        fx = fx - load * normal.x
        fz = fz - load * normal.z
    end
    self.force.Force = Vector3.new(fx, fy, fz)
    self:_apply_orientation(self.target_velocity and target_velocity or desired)
end

Character.update = Character.pre_simulation

function Character:stop()
    self:set_input(0, 0)
    self.target_velocity = nil
    self.hold = nil
    self.jump_buffer_remaining = 0
    self.jump_ground_ignore_remaining = 0
    if self.force then self.force.Force = Vector3.new(0, 0, 0) end
end

---move the body to a spawn point and clear all motion and timers
function Character:teleport(position, facing)
    self:stop()
    self.part.CFrame = CFrame.new(position)
    self.part.Velocity = Vector3.new(0, 0, 0)
    if self.part.RotVelocity then self.part.RotVelocity = Vector3.new(0, 0, 0) end
    self.grounded = false
    self.ground = nil
    self.support_velocity = ZERO
    self.coyote_remaining = 0
    self.air_time = 0
    self.ground_time = 0
    if facing then self:set_facing(facing) end
end

function Character:destroy()
    self:stop()
    if self._created_gyro and self.gyro and type(self.gyro.Destroy) == "function" then
        self.gyro:Destroy()
    end
    if self._created_force and self.force and type(self.force.Destroy) == "function" then
        self.force:Destroy()
    end
    self.gyro = nil
    self.force = nil
    self.part = nil
    self.workspace = nil
end

return Character
