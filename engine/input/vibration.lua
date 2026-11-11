local vibration = {}

vibration.default_duration = 0.12
vibration.mobile_repeat_duration = 0.45
vibration.mobile_repeat_interval = 0.42
vibration._active = {}
vibration._next_id = 0
vibration._mobile_next_time = 0
vibration._last_success = false
vibration._last_error = nil

local function clamp(value, min_value, max_value)
    value = tonumber(value) or 0
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function now()
    return love.timer.getTime()
end

function vibration.get_master_strength()
    local value = G:getSetting('rumble').value
    -- the project setting is stored as 0..100, but this also accepts 0..1
    -- in case a game changes it directly from code
    if value > 1 then
        value = value / 100
    end

    return clamp(value, 0, 1)
end

function vibration.set_master_strength(value)
    G:getSetting('rumble').value = value

    if vibration.get_master_strength() <= 0 then
        vibration.stop()
    end
end

local function mobile_supported()
    return input_mgr.mobile.is_mobile
end

local function joystick_supported(joy)
    if not joy then return false end
    if not joy:isConnected() then return false end
    return joy:isVibrationSupported()
end

local function direction_bias(direction)
    if direction == nil then return 0 end

    if type(direction) == 'number' then
        return clamp(direction, -1, 1)
    end

    if type(direction) == 'string' then
        local dir = direction:lower()
        if dir == 'left' or dir == 'west' or dir == 'l' then return -1 end
        if dir == 'right' or dir == 'east' or dir == 'r' then return 1 end
        if dir == 'center' or dir == 'centre' or dir == 'both' or dir == 'middle' then return 0 end
        return 0
    end

    if type(direction) == 'table' then
        local x = direction.x or direction[1] or 0
        return clamp(x, -1, 1)
    end

    return 0
end

local function resolve_levels(opts)
    opts = opts or {}

    local strength = opts.intensity
        or opts.strength
        or opts.amount
        or opts.power
        or 1
    strength = clamp(strength, 0, 1) * vibration.get_master_strength()

    local left = opts.left
    local right = opts.right

    if left ~= nil or right ~= nil then
        left = clamp(left or 0, 0, 1) * strength
        right = clamp(right or 0, 0, 1) * strength
        return left, right
    end

    local bias = direction_bias(opts.direction or opts.dir)

    -- LÖVE exposes two motors. this maps direction onto the two motor values:
    -- -1 = left motor only, 0 = both motors, 1 = right motor only
    left = strength * (bias <= 0 and 1 or (1 - bias))
    right = strength * (bias >= 0 and 1 or (1 + bias))

    return clamp(left, 0, 1), clamp(right, 0, 1)
end

local function resolve_duration(opts)
    local duration = opts.duration
    if duration == nil then duration = opts.time end

    if opts.indefinite == true or duration == 'indefinite' or duration == 'infinite' then
        return -1, true
    end

    if duration == nil then duration = vibration.default_duration end
    duration = tonumber(duration) or vibration.default_duration

    if duration < 0 then
        return -1, true
    end

    return math.max(0, duration), false
end

local function make_id()
    vibration._next_id = vibration._next_id + 1
    return 'vibration_' .. tostring(vibration._next_id)
end

local function controller_matches(ctrl, target)
    if not ctrl or ctrl.type ~= 'joystick' then return false end
    if target == nil or target == 'all' or target == 'controller' or target == 'controllers' or target == 'console' then
        return true
    end
    if target == ctrl or target == ctrl.joy or target == ctrl.name then
        return true
    end
    return false
end

function vibration.get_controller_targets(target)
    local result = {}

    for name, ctrl in pairs(input_mgr.controller.controllers) do
        if controller_matches(ctrl, target) then
            result[#result + 1] = ctrl
        end
    end

    return result
end

local function wants_mobile(target)
    return target == nil
        or target == 'all'
        or target == 'mobile'
        or target == 'phone'
        or target == 'touch'
end

function vibration.is_supported(target)
    if wants_mobile(target) and mobile_supported() then
        return true
    end

    for _, ctrl in ipairs(vibration.get_controller_targets(target)) do
        if joystick_supported(ctrl.joy) then
            return true
        end
    end

    return false
end

local function apply_to_controller(ctrl, left, right, duration)
    if not ctrl or not ctrl.joy then
        return false
    end

    if not joystick_supported(ctrl.joy) then
        return false
    end

    local success
    if duration ~= nil then
        success = ctrl.joy:setVibration(left, right, duration)
    else
        success = ctrl.joy:setVibration(left, right)
    end

    return success ~= false
end

local function stop_controller(ctrl)
    if not ctrl or not ctrl.joy then
        return false
    end

    local success = ctrl.joy:setVibration()
    if success == false then
        success = ctrl.joy:setVibration(0, 0)
    end

    return success ~= false
end

local function mobile_vibrate(duration)
    if not mobile_supported() then return false end

    duration = tonumber(duration) or vibration.default_duration
    if duration <= 0 then return false end

    -- LÖVE mobile vibration has duration, but no intensity or direction
    -- Strength is still respected as an on/off gate and by scaling duration
    local strength = vibration.get_master_strength()
    if strength <= 0 then return false end

    local scaled = math.max(0.02, duration * math.max(0.15, strength))
    love.system.vibrate(scaled)
    return true
end

function vibration.play(opts)
    if type(opts) ~= 'table' then
        opts = { intensity = opts }
    end
    opts = opts or {}

    local left, right = resolve_levels(opts)
    local duration, indefinite = resolve_duration(opts)
    local target = opts.target or opts.device or 'all'
    local id = opts.id
    local success = false
    local targets = vibration.get_controller_targets(target)
    local target_names = {}

    if left <= 0 and right <= 0 then
        return false, id
    end

    for _, ctrl in ipairs(targets) do
        if apply_to_controller(ctrl, left, right, duration) then
            success = true
            target_names[#target_names + 1] = ctrl.name
        end
    end

    local used_mobile = false
    if wants_mobile(target) and mobile_supported() then
        local mobile_duration = duration
        if indefinite then
            mobile_duration = vibration.mobile_repeat_duration
        end
        if mobile_vibrate(mobile_duration) then
            success = true
            used_mobile = true
            vibration._mobile_next_time = now() + vibration.mobile_repeat_interval
        end
    end

    if id or indefinite then
        id = id or make_id()
        vibration._active[id] = {
            id = id,
            target = target,
            target_names = target_names,
            mobile = used_mobile,
            left = left,
            right = right,
            duration = duration,
            indefinite = indefinite,
            remaining = (not indefinite) and duration or nil,
        }
    end

    vibration._last_success = success
    vibration._last_error = success and nil or 'No vibration-capable target was found.'

    return success, id
end

function vibration.pulse(intensity, duration, direction, target)
    if type(intensity) == 'table' then
        return vibration.play(intensity)
    end

    return vibration.play({
        intensity = intensity or 1,
        duration = duration or vibration.default_duration,
        direction = direction,
        target = target or 'all',
    })
end

function vibration.start(id, intensity, direction, target)
    if type(id) == 'table' then
        local opts = id
        opts.indefinite = true
        return vibration.play(opts)
    end

    return vibration.play({
        id = id,
        intensity = intensity or 1,
        direction = direction,
        target = target or 'all',
        indefinite = true,
    })
end

local function has_active_mobile()
    for _, effect in pairs(vibration._active) do
        if effect.mobile and effect.indefinite then
            return true
        end
    end
    return false
end

function vibration.stop(id)
    local stopped = false

    if id ~= nil then
        local effect = vibration._active[id]
        if not effect then return false end

        if effect.target_names then
            for _, name in ipairs(effect.target_names) do
                local ctrl = input_mgr.controller.controllers[name]
                if stop_controller(ctrl) then stopped = true end
            end
        else
            for _, ctrl in ipairs(vibration.get_controller_targets(effect.target)) do
                if stop_controller(ctrl) then stopped = true end
            end
        end

        vibration._active[id] = nil
    else
        for _, ctrl in ipairs(vibration.get_controller_targets('all')) do
            if stop_controller(ctrl) then stopped = true end
        end
        vibration._active = {}
    end

    if mobile_supported() and not has_active_mobile() then
        love.system.vibrate(0)
    end

    return stopped
end

function vibration.update(dt)
    dt = dt or 0

    for id, effect in pairs(vibration._active) do
        if not effect.indefinite and effect.remaining then
            effect.remaining = effect.remaining - dt
            if effect.remaining <= 0 then
                vibration.stop(id)
            end
        end
    end

    if mobile_supported() and has_active_mobile() and now() >= vibration._mobile_next_time then
        mobile_vibrate(vibration.mobile_repeat_duration)
        vibration._mobile_next_time = now() + vibration.mobile_repeat_interval
    end
end

function vibration.get_state()
    local count = 0
    for _ in pairs(vibration._active) do count = count + 1 end

    return {
        supported = vibration.is_supported('all'),
        master_strength = vibration.get_master_strength(),
        active_count = count,
        last_success = vibration._last_success,
        last_error = vibration._last_error,
    }
end

vibration.rumble = vibration.play
vibration.haptic = vibration.play
vibration.haptics = vibration.play

return vibration
