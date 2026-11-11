local cpml = require("engine/services/oss/cpml")
local util = require("engine/graphics/rbx/util")

local vec3 = cpml.vec3

local controller = {}
controller.__index = controller

local active_controller
local hooked_input_manager
local raw_mouse_move

local function get_input_manager()
    local manager = rawget(_G, "input_mgr")
    if type(manager) == "table" then
        return manager
    end
    return nil
end

local function install_mouse_hook()
    local manager = get_input_manager()
    local mouse = manager and manager.mouse
    if not mouse or type(mouse.handle_move) ~= "function" then
        return
    end
    if hooked_input_manager == manager and raw_mouse_move then
        return
    end

    hooked_input_manager = manager
    local previous_mouse_move = mouse.handle_move
    raw_mouse_move = previous_mouse_move
    mouse.handle_move = function(x, y, dx, dy)
        previous_mouse_move(x, y, dx, dy)
        if active_controller then
            active_controller.mouseDelta =
                active_controller.mouseDelta + vec3.new(dx or 0, dy or 0, 0)
        end
    end
end

local function clamp(value, min_value, max_value)
    return math.max(min_value, math.min(max_value, value))
end

local function is_down(key)
    local manager = get_input_manager()
    local active_keys = manager and manager.state and manager.state.active_keys
    if active_keys and active_keys[key] then
        return true
    end
    return love.keyboard and love.keyboard.isDown and love.keyboard.isDown(key) or false
end

local function mouse_down(button)
    local manager = get_input_manager()
    local active = manager and manager.mouse
        and manager.mouse.state and manager.mouse.state.active
    if active and active[button] then
        return true
    end
    return love.mouse and love.mouse.isDown and love.mouse.isDown(button) or false
end

local function mouse_position()
    local manager = get_input_manager()
    local position = manager and manager.mouse and manager.mouse.position
    if position then
        return tonumber(position.x) or 0, tonumber(position.y) or 0
    end
    if love.mouse and love.mouse.getPosition then
        return love.mouse.getPosition()
    end
    return 0, 0
end

function controller.new(scene)
    install_mouse_hook()
    local mx, my = mouse_position()
    local self = setmetatable({
        normSpeed = 137,
        maxSpeed = 654,
        lookSensitivity = 0.005,
        panSensitivity = 0.35,
        lastMouse = vec3.new(mx, my, 0),
        mouseDelta = vec3.new(0, 0, 0),
        mouseCaptured = false,
        scenePath = scene and scene.path or "",
        scene = scene,
    }, controller)
    active_controller = self
    self:reset(scene)
    return self
end

function controller:set_mouse_capture(active)
    active = active == true
    if self.mouseCaptured == active then
        return
    end
    self.mouseCaptured = active

    if love.mouse and love.mouse.setRelativeMode then
        love.mouse.setRelativeMode(active)
    end

    -- the engine uses the operating system cursor exclusively.  Relative mode
    -- hides it while this optional free camera owns look input, then restores
    -- the native cursor as soon as capture ends
    if love.mouse and love.mouse.setVisible then
        love.mouse.setVisible(not active)
    end

    local mx, my = mouse_position()
    self.mouseDelta = vec3.new(0, 0, 0)
    self.lastMouse = vec3.new(mx, my, 0)
end

function controller:_apply_camera()
    if not self.scene or type(self.scene.set_camera_pose) ~= "function" then
        return false
    end

    local cos_pitch = math.cos(self.pitch)
    local forward = vec3.new(
        math.cos(self.yaw) * cos_pitch,
        math.sin(self.pitch),
        math.sin(self.yaw) * cos_pitch
    )
    self.scene:set_camera_pose(self.position, forward, vec3.new(0, 1, 0))
    return true
end

function controller:reset(scene)
    self.scene = scene or self.scene
    local bounds = self.scene and self.scene.bounds
        or util.ensure_bounds(nil, 32)
    local center = util.bounds_center(bounds)
    local size = util.bounds_size(bounds)
    local radius = math.max(size.x, size.y, size.z, 64) * 0.5
    local direction = vec3.new(1, 0.14, 0.58):normalize()

    self.position = center
        + direction * math.max(radius * 1.55, 22)
        + vec3.new(0, math.max(size.y * 0.13, 4), 0)
    local delta = center - self.position
    self.yaw = math.atan2(delta.z, delta.x)
    self.pitch = math.atan2(delta.y,
        math.sqrt(delta.x * delta.x + delta.z * delta.z))
    self:_apply_camera()

    local mx, my = mouse_position()
    self.lastMouse = vec3.new(mx, my, 0)
end

function controller:focus_bounds(bounds, options)
    if not bounds then
        return false
    end
    options = options or {}
    local center = util.bounds_center(bounds)
    local size = util.bounds_size(bounds)
    local radius = math.max(size.x, size.y, size.z,
        options.min_radius or 4) * 0.5
    local direction = options.direction or vec3.new(-1, 0.45, -1)
    if direction:len2() <= 1e-8 then
        direction = vec3.new(-1, 0.45, -1)
    end
    direction = direction:normalize()

    local distance = math.max(
        radius * (options.distance_scale or 3.5),
        options.min_distance or 8)
    local lift = options.lift
    if lift == nil then
        lift = math.max(radius * 0.9, 1.5)
    end
    self.position = center + direction * distance + vec3.new(0, lift, 0)

    local delta = center - self.position
    self.yaw = math.atan2(delta.z, delta.x)
    self.pitch = math.atan2(delta.y,
        math.sqrt(delta.x * delta.x + delta.z * delta.z))
    self:_apply_camera()
    return true
end

function controller:update(dt)
    local look_active = mouse_down(2)
    local pan_active = mouse_down(3)
    self:set_mouse_capture(look_active or pan_active)

    local mouse_delta
    if self.mouseCaptured then
        mouse_delta = vec3.new(-self.mouseDelta.x, self.mouseDelta.y, 0)
        self.mouseDelta = vec3.new(0, 0, 0)
    else
        local mx, my = mouse_position()
        local current = vec3.new(mx, my, 0)
        mouse_delta = current - self.lastMouse
        self.lastMouse = current
    end

    local pose_changed = false
    if look_active then
        local yaw = self.yaw - mouse_delta.x * self.lookSensitivity
        local pitch = clamp(
            self.pitch - mouse_delta.y * self.lookSensitivity,
            -math.pi * 0.49,
            math.pi * 0.49)
        pose_changed = yaw ~= self.yaw or pitch ~= self.pitch
        self.yaw, self.pitch = yaw, pitch
    end

    local cos_pitch = math.cos(self.pitch)
    local forward = vec3.new(
        math.cos(self.yaw) * cos_pitch,
        math.sin(self.pitch),
        math.sin(self.yaw) * cos_pitch)
    local right = vec3.new(-math.sin(self.yaw), 0, math.cos(self.yaw))
    local up = vec3.new(0, 1, 0)
    local view_up = vec3.new(
        -math.cos(self.yaw) * math.sin(self.pitch),
        cos_pitch,
        -math.sin(self.yaw) * math.sin(self.pitch))
    local fast = is_down("lshift") or is_down("rshift") or is_down("q")
    local speed = (fast and self.maxSpeed or self.normSpeed)
        * ((is_down("lctrl") or is_down("rctrl")) and 3 or 1)
    local movement = vec3.new(0, 0, 0)

    if is_down("w") then movement = movement + forward end
    if is_down("s") then movement = movement - forward end
    if is_down("d") then movement = movement + right end
    if is_down("a") then movement = movement - right end
    if is_down("space") or is_down("e") then movement = movement + up end
    if movement:len2() > 0 then
        self.position = self.position + movement:normalize() * speed * (dt or 0)
        pose_changed = true
    end

    if pan_active and (mouse_delta.x ~= 0 or mouse_delta.y ~= 0) then
        local scale = speed * self.panSensitivity * (dt or 0)
        self.position = self.position
            - right * mouse_delta.x * scale
            + view_up * mouse_delta.y * scale
        pose_changed = true
    end
    if pose_changed then
        self:_apply_camera()
    end
end

function controller:destroy()
    if active_controller == self then
        active_controller = nil
    end
    self:set_mouse_capture(false)
    self.scene = nil
end

return controller
