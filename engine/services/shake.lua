-- adds short camera offsets to the 2D draw pass
local Shake = {}
Shake.__index = Shake

local function vec(x, y)
    if vec2 then return vec2(x, y) end
    return { x = x or 0, y = y or 0 }
end

local function component(value, name, fallback)
    if type(value) ~= "table" then return fallback or 0 end
    return value[name] or value[name:upper()] or value[name == "x" and 1 or 2] or fallback or 0
end

local function reduced_motion_enabled()
    local setting = CFG and CFG.getSetting and CFG:getSetting('reduced_motion')
    return setting and setting.value == true
end

local function new_instance(magnitude, roughness, fade_in, fade_out, position, rotation, rumble)
    local instance = {
        magnitude = magnitude or 1,
        roughness = roughness or 1,
        fade_in = math.max(0, fade_in or 0),
        fade_out = math.max(0, fade_out or 0),
        position = position or { x = 0.15, y = 0.15 },
        rotation = rotation or { z = 1 },
        rumble = rumble or 0,
        time = 0,
        fade = (fade_in or 0) > 0 and 0 or 1,
        sustaining = (fade_in or 0) > 0,
        finished = false,
        phase = math.random() * math.pi * 2,
    }

    function instance:StartFadeOut(duration)
        self.fade_out = math.max(0, duration or self.fade_out or self.fade_in)
        self.sustaining = false
        if self.fade_out == 0 then self.finished = true end
    end

    return instance
end

local function preset(magnitude, roughness, fade_in, fade_out, position, rotation, rumble)
    return function()
        return new_instance(magnitude, roughness, fade_in, fade_out, position, rotation, rumble)
    end
end

Shake.Presets = setmetatable({}, {
    __index = function(_, name)
        local makers = {
            Bump = preset(7.5, 3, 0.1, 0.2, { x = 0.15, y = 0.15 }, { z = 1 }, 0.20),
            Explosion = preset(5, 10, 0, 1.5, { x = 0.25, y = 0.25 }, { z = 1 }, 0.55),
            Earthquake = preset(0.6, 3.5, 2, 10, { x = 0.25, y = 0.25 }, { z = 4 }, 0.30),
            BadTrip = preset(10, 0.15, 5, 10, { x = 0.05, y = 0.05 }, { z = 4 }, 0.16),
            Vibration = preset(0.4, 20, 2, 2, { x = 0, y = 0.15 }, { z = 4 }, 0.35),
        }
        local maker = makers[name]
        return maker and maker() or nil
    end,
})

function Shake.new(callback, options)
    assert(type(callback) == "function", "Shake.new needs a callback")
    options = options or {}
    return setmetatable({
        callback = callback,
        name = options.name or "wave_shake",
        position_scale = options.positionScale or 1,
        rotation_scale = options.rotationScale or 1,
        rumble_scale = options.rumbleScale or 1,
        instances = {},
        running = false,
    }, Shake)
end

function Shake:Start()
    if self.running then return self end
    self.running = true
    if G and G.pipeline then
        G.pipeline:register("update", self.name, function(dt)
            self:Update(dt)
        end, { priority = 50, after = "INIT" })
    end
    return self
end

function Shake:Stop()
    self.running = false
    if G and G.pipeline then G.pipeline:remove("update", self.name) end
end

function Shake:reset_motion()
    self.instances = {}
    self.callback({
        position = vec(0, 0),
        offset = vec(0, 0),
        rotation = 0,
        rumble = { intensity = 0, duration = 0, direction = "center" },
    })
end

function Shake:Shake(instance)
    assert(type(instance) == "table", "Shake expects a shake instance")
    if reduced_motion_enabled() then
        instance.finished = true
        self:reset_motion()
        return instance
    end
    self.instances[#self.instances + 1] = instance
    return instance
end

function Shake:ShakeOnce(magnitude, roughness, fade_in, fade_out, position, rotation, rumble)
    return self:Shake(new_instance(magnitude, roughness, fade_in, fade_out, position, rotation, rumble))
end

function Shake:ShakeSustain(instance)
    assert(type(instance) == "table", "ShakeSustain expects a shake instance")
    instance.sustaining = true
    instance.finished = false
    return self:Shake(instance)
end

function Shake:Update(dt)
    dt = math.max(0, dt or 0)
    if reduced_motion_enabled() then
        if #self.instances > 0 then self:reset_motion() end
        return
    end
    local x, y, angle, rumble = 0, 0, 0, 0
    for index = #self.instances, 1, -1 do
        local instance = self.instances[index]
        instance.time = instance.time + dt
        if instance.sustaining and instance.fade < 1 then
            instance.fade = math.min(1, instance.fade + dt / math.max(instance.fade_in, 0.0001))
        elseif not instance.sustaining then
            instance.fade = instance.fade - dt / math.max(instance.fade_out, 0.0001)
            if instance.fade <= 0 then instance.finished = true end
        end

        if instance.finished then
            table.remove(self.instances, index)
        else
            -- two distinct sinusoids give readable, deterministic motion
            -- without a bundled noise implementation
            local oscillation = (math.sin(instance.phase + instance.time * instance.roughness * 7)
                + math.sin(instance.phase * 0.63 + instance.time * instance.roughness * 11) * 0.5) / 1.5
            local amount = instance.magnitude * instance.fade * oscillation
            x = x + amount * component(instance.position, "x", 0)
            y = y + amount * component(instance.position, "y", 0)
            angle = angle + amount * component(instance.rotation, "z", 0) * math.pi / 180
            rumble = math.max(rumble, math.min(1, math.abs(amount) * instance.rumble))
        end
    end

    self.callback({
        position = vec(x * self.position_scale, y * self.position_scale),
        offset = vec(x * self.position_scale, y * self.position_scale),
        rotation = angle * self.rotation_scale,
        rumble = { intensity = rumble * self.rumble_scale, duration = 0.06, direction = "center" },
    })
end

return Shake
