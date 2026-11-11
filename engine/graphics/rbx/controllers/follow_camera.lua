-- Third-person orbit camera for an RBX workspace
--
-- the camera follows a focus point (usually a character part), orbits with
-- mouse or stick input, zooms, and pulls in when geometry blocks the view
-- like the character controller it owns no input handlers: a project passes
-- look deltas in, so mouse capture and bindings stay project decisions

local rbx = require("engine/graphics/rbx")

local FollowCamera = {}
FollowCamera.__index = FollowCamera

local function clamp(value, lower, upper)
    if value < lower then return lower end
    if value > upper then return upper end
    return value
end

-- Frame-rate independent exponential approach
local function approach(current, target, sharpness, dt)
    return current + (target - current) * (1 - math.exp(-sharpness * dt))
end

local function wrap_angle(angle)
    return (angle + math.pi) % (math.pi * 2) - math.pi
end

local DEFAULTS = {
    yaw = 0,
    pitch = -0.32,
    distance = 18,
    min_distance = 6,
    max_distance = 40,
    min_pitch = -1.25,
    max_pitch = 0.55,
    -- Focus height above the target position
    height = 2.5,
    -- Radians per pixel of mouse motion at sensitivity 1
    mouse_speed = 0.0045,
    -- Radians per second at full stick deflection
    stick_speed = 3.2,
    sensitivity = 1,
    invert_y = false,
    zoom_step = 2.5,
    follow_sharpness = 14,
    vertical_follow_sharpness = 7,
    zoom_sharpness = 10,
    -- how far the camera stays in front of an obstruction
    collision_padding = 0.6,
    -- optional gentle swing behind the movement direction (radians/second)
    auto_rotate = 0,
    fov = 70,
}

---@param workspace RBXLXWorkspace
---@param options table|nil see DEFAULTS above; `ignore` lists parts the
---collision ray skips (the character and its visual rig)
function FollowCamera.new(workspace, options)
    assert(workspace and workspace.CurrentCamera, "FollowCamera needs an RBX workspace")
    local self = setmetatable({ workspace = workspace }, FollowCamera)
    for key, value in pairs(DEFAULTS) do self[key] = value end
    for key, value in pairs(options or {}) do self[key] = value end
    self.ignore = self.ignore or {}
    self.goal_distance = self.distance
    self.current_distance = self.distance
    self.focus = nil
    self.target = nil
    local camera = workspace.CurrentCamera
    camera.CameraType = rbx.Enum.CameraType.Scriptable
    if self.fov and camera.FieldOfView ~= nil then camera.FieldOfView = self.fov end
    return self
end

---Follow a part, or a function returning a Vector3 each frame
function FollowCamera:set_target(target)
    self.target = target
end

function FollowCamera:_target_position()
    local target = self.target
    if type(target) == "function" then return target() end
    if target and target.Position then return target.Position end
    return nil
end

---rotate from a mouse delta in pixels
function FollowCamera:add_mouse(dx, dy)
    local speed = self.mouse_speed * self.sensitivity
    self.yaw = wrap_angle(self.yaw - (dx or 0) * speed)
    local vertical = (dy or 0) * speed
    if self.invert_y then vertical = -vertical end
    self.pitch = clamp(self.pitch - vertical, self.min_pitch, self.max_pitch)
end

---rotate from a stick (-1..1 per axis) over `dt` seconds
function FollowCamera:add_stick(x, y, dt)
    local speed = self.stick_speed * dt
    self.yaw = wrap_angle(self.yaw - (x or 0) * speed)
    local vertical = (y or 0) * speed * 0.75
    if self.invert_y then vertical = -vertical end
    self.pitch = clamp(self.pitch - vertical, self.min_pitch, self.max_pitch)
end

---Zoom by wheel notches, positive moves closer
function FollowCamera:zoom(steps)
    self.goal_distance = clamp(self.goal_distance - (steps or 0) * self.zoom_step,
        self.min_distance, self.max_distance)
end

function FollowCamera:set_distance(distance)
    self.goal_distance = clamp(distance, self.min_distance, self.max_distance)
end

---turn to look along a horizontal direction (for example after a respawn)
function FollowCamera:face(direction)
    if direction and (direction.x ~= 0 or direction.z ~= 0) then
        self.yaw = math.atan2(direction.x, direction.z)
    end
end

---skip smoothing on the next update, e.g. after teleporting the target
function FollowCamera:snap()
    self.focus = nil
    self.current_distance = self.goal_distance
end

function FollowCamera:get_yaw()
    return self.yaw
end

function FollowCamera:look_vector()
    local cosine = math.cos(self.pitch)
    return rbx.Vector3.new(math.sin(self.yaw) * cosine, math.sin(self.pitch), math.cos(self.yaw) * cosine)
end

---Swing toward a movement direction when the player is not steering the
---camera. `strength` is 0..1 (usually the move input magnitude)
function FollowCamera:follow_direction(direction, strength, dt)
    if self.auto_rotate <= 0 or not direction then return end
    local length = math.sqrt(direction.x * direction.x + direction.z * direction.z)
    if length < 0.01 then return end
    local goal = math.atan2(direction.x, direction.z)
    local delta = wrap_angle(goal - self.yaw)
    -- only swing for sideways motion, walking at the camera stays readable
    local weight = math.abs(math.sin(delta)) * (strength or 1)
    self.yaw = wrap_angle(self.yaw + clamp(delta, -1, 1) * self.auto_rotate * weight * dt)
end

function FollowCamera:update(dt)
    local position = self:_target_position()
    if not position then return end
    local Vector3 = rbx.Vector3
    local goal_focus = position + Vector3.new(0, self.height, 0)
    if not self.focus then
        self.focus = goal_focus
    else
        local focus = self.focus
        self.focus = Vector3.new(
            approach(focus.x, goal_focus.x, self.follow_sharpness, dt),
            approach(focus.y, goal_focus.y, self.vertical_follow_sharpness, dt),
            approach(focus.z, goal_focus.z, self.follow_sharpness, dt))
    end

    local look = self:look_vector()
    local desired = self.goal_distance
    local hit = self.workspace:Raycast(self.focus, look * -(desired + self.collision_padding), {
        "Blacklist", self.ignore, RespectCanCollide = true,
    })
    local allowed = desired
    if hit then allowed = math.max(self.min_distance * 0.35, hit.Distance - self.collision_padding) end
    if allowed < self.current_distance then
        -- Pull in immediately so walls never cover the character
        self.current_distance = allowed
    else
        self.current_distance = approach(self.current_distance, allowed, self.zoom_sharpness, dt)
    end

    local eye = self.focus - look * self.current_distance
    local camera = self.workspace.CurrentCamera
    camera.CFrame = rbx.CFrame.lookAt(eye, self.focus, Vector3.new(0, 1, 0))
    camera.Focus = rbx.CFrame.new(self.focus)
end

return FollowCamera
