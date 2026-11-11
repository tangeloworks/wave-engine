-- Menu sounds for Showcase 3D, generated at startup with
-- engine/services/synth.lua. Volume follows the engine SFX/master settings
local Synth = require("engine/services/synth")

local Sounds = {}

local DEFINITIONS = {
    ui_move = { wave = "sine", freq = 1250, duration = 0.035, volume = 0.12, release = 0.03 },
    ui_select = {
        { wave = "triangle", freq = 700, duration = 0.05, volume = 0.2 },
        { wave = "triangle", freq = 1050, duration = 0.07, delay = 0.04, volume = 0.18 },
    },
    ui_open = { wave = "sine", freq = 520, freq_end = 780, duration = 0.09, volume = 0.18 },
    ui_close = { wave = "sine", freq = 780, freq_end = 520, duration = 0.09, volume = 0.16 },
}

-- Played after a volume change on the channel that setting controls, so it
-- is heard at the new level. Registered on both channels
local PREVIEW = {
    ui_volume = {
        { wave = "triangle", freq = 523, duration = 0.12, volume = 0.35 },
        { wave = "triangle", freq = 784, duration = 0.16, delay = 0.06, volume = 0.3 },
    },
}

function Sounds.load()
    Synth.register(DEFINITIONS, "sfx")
    Synth.register(PREVIEW, "sfx")
    Synth.register(PREVIEW, "music")
end

function Sounds.play(name, pitch, volume)
    if not DEFINITIONS[name] then return end
    audio:play("sfx", name, { clone = true, pitch = pitch or 1, volume = volume or 1 })
end

---Play the volume preview on `channel` ("sfx" or "music")
function Sounds.preview(channel)
    audio:play(channel, "ui_volume", { clone = true })
end

return Sounds
