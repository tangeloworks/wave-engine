-- music and sound behavior ported from Robot 64's audio script
-- credited to zKevin, see NOTICE.md
-- available music layers start together and fade with the player's current state
-- sounds attached to parts get quieter with distance from the camera
local Source = require("projects/showcase3d/robot64/source")

local Audio = {}
Audio.__index = Audio

local MAP_TRACKS = { "bgm", "bgmW", "bgmA", "bgmC", "bgmP" }

local function child(node, name) return node and node:FindFirstChild(name) end

function Audio.new(world, assets)
    local scripts = child(Source.service(world, "StarterPlayer"), "StarterPlayerScripts")
    local self = setmetatable({ assets = assets, named = {}, tracks = {}, voices = 0, selected = "bgm" }, Audio)
    for _, node in ipairs(child(scripts, "CharacterScript") and scripts.CharacterScript:GetChildren() or {}) do
        if node.ClassName == "Sound" then self.named[node.Name] = node end
    end
    return self
end

function Audio:activate(map)
    self:retire()
    local settings = child(map, "settings")
    for _, name in ipairs(MAP_TRACKS) do
        local template, value = self.named[name], child(settings, name)
        local track = template and value and self.assets:play("music:" .. name, "rbxassetid://" .. tostring(value.Value),
            0, true, template.PlaybackSpeed or 1, "music")
        self.tracks[name] = { current = 0, track = track or nil, absent = track == nil }
    end
    self.selected = "bgm"
end

function Audio.select(context, tracks)
    local function present(name) return tracks[name] and not tracks[name].absent end
    if context.paused then return present("bgmP") and "bgmP" or "bgm" end
    local selected = (context.gotice or context.trdo == 0) and "nothing"
        or context.flying and present("bgmA") and "bgmA"
        or context.skate and present("bgmC") and "bgmC"
        or context.swimming and present("bgmW") and "bgmW"
        or "bgm"
    if context.silent_region then selected = "nothing" end
    return selected
end

function Audio.attenuation(sound, position, listener)
    if not position or not listener then return 1 end
    local distance = (position - listener).Magnitude
    local minimum, maximum = sound.RollOffMinDistance or 10, sound.RollOffMaxDistance or 10000
    if distance >= maximum then return 0 end
    return distance <= minimum and 1 or minimum / distance
end

local function spatial_parent(sound)
    local parent = sound.Parent
    if not parent then return nil end
    if parent.ClassName == "Attachment" then return parent.WorldPosition end
    if parent:IsA("BasePart") then return parent.Position end
end

-- one-shots use the distance gain at playback, each play gets its own source
function Audio:play_sound(sound, options)
    if not sound or not sound.SoundId or sound.SoundId == "" then return false end
    options = options or {}
    local volume = options.volume or sound.Volume or 1
    local gain = Audio.attenuation(sound, options.position or spatial_parent(sound), self.listener)
    return self.assets:play_sound(sound.SoundId, volume * gain, options.pitch or sound.PlaybackSpeed or 1)
end

function Audio:play_named(name, options)
    return self:play_sound(self.named[name], options)
end

function Audio:psound(torso, name)
    local sound = child(torso, name)
    local vol = child(sound, "vol")
    return self:play_sound(sound, { volume = vol and vol.Value or 1 })
end

-- the slide loop follows the player's movement each frame
function Audio:bind_slide(sound)
    self.assets:stop("robot64:slide")
    self.slide = sound
    if sound then self.assets:play("robot64:slide", sound.SoundId, 0, true, sound.PlaybackSpeed or 1) end
end

function Audio:update(dt, context)
    self.listener = context.listener_position
    local selected = Audio.select(context, self.tracks)
    self.selected = selected
    local target = context.paused and .8 or 1
    for _, name in ipairs(MAP_TRACKS) do
        local entry = self.tracks[name]
        if entry and entry.track then
            -- match the original fade in steps of at most 0.1 seconds
            local remaining = math.max(0, dt)
            while remaining > 0 do
                local step = math.min(.1, remaining)
                remaining = remaining - step
                entry.current = entry.current + ((selected == name and target or 0) - entry.current) * step * 2
            end
            entry.track:set_volume(math.max(0, entry.current))
        end
    end
    if self.slide and not context.paused then
        local volume = 0
        if context.sliderp and context.swimerp and context.ground_y and context.torso_y then
            volume = context.sliderp * (1 - context.swimerp) * math.min(1, context.ground_y - context.torso_y + 2.6)
        end
        self.assets:set_volume("robot64:slide", math.max(0, volume))
    elseif self.slide then
        self.assets:set_volume("robot64:slide", 0)
    end
    return selected
end

function Audio:retire()
    for _, name in ipairs(MAP_TRACKS) do self.assets:stop("music:" .. name) end
    self.tracks = {}
end

function Audio:destroy()
    self:retire()
    self:bind_slide(nil)
end

return Audio
