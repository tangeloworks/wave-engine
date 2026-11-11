-- Procedural sound effects: short tones and noise bursts rendered into a
-- LÖVE SoundData, for UI feedback and prototypes without audio files
--
--     local Synth = require("engine/services/synth")
--     audio.channels.sfx:add_sound("blip", Synth.render({ wave = "square", freq = 880, duration = 0.08 }))
--     audio:play("sfx", "blip", { clone = true })
--
-- a sound is one layer or a list of layers mixed together. Layer fields:
--   wave      "sine" | "square" | "triangle" | "saw" | "noise"
--   freq      start frequency in Hz, freq_end sweeps exponentially to it
--   duration  seconds, delay offsets the layer inside the sound
--   attack, release   envelope edges in seconds (linear in, exponential out)
--   volume    0..1 layer gain
--   vibrato   { rate = Hz, depth = semitones }
--   lowpass   0..1 smoothing for noise (higher is duller)

local Synth = {}

local SAMPLE_RATE = 44100

local function oscillator(wave, phase, rng)
    if wave == "square" then
        return phase % 1 < 0.5 and 1 or -1
    elseif wave == "triangle" then
        local t = phase % 1
        return t < 0.5 and (t * 4 - 1) or (3 - t * 4)
    elseif wave == "saw" then
        return (phase % 1) * 2 - 1
    elseif wave == "noise" then
        return rng() * 2 - 1
    end
    return math.sin(phase * math.pi * 2)
end

local function layer_length(layer)
    return (layer.delay or 0) + (layer.duration or 0.1)
end

---render one layer or a list of layers into mono 16-bit SoundData
function Synth.render(spec, sample_rate)
    sample_rate = sample_rate or SAMPLE_RATE
    local layers = spec[1] and spec or { spec }
    local total = 0
    for _, layer in ipairs(layers) do total = math.max(total, layer_length(layer)) end
    local samples = math.max(1, math.floor(total * sample_rate))
    local mix = {}
    for index = 1, samples do mix[index] = 0 end

    local seed = 1
    local function rng()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end

    for _, layer in ipairs(layers) do
        local first = math.floor((layer.delay or 0) * sample_rate)
        local count = math.floor((layer.duration or 0.1) * sample_rate)
        local attack = math.max(1, math.floor((layer.attack or 0.004) * sample_rate))
        local release = math.max(1, math.floor((layer.release or (layer.duration or 0.1) * 0.6) * sample_rate))
        local freq, freq_end = layer.freq or 440, layer.freq_end or layer.freq or 440
        local vibrato = layer.vibrato
        local volume = layer.volume or 0.5
        local smooth = layer.lowpass or 0
        local phase, filtered = 0, 0
        for index = 0, count - 1 do
            local t = index / math.max(1, count - 1)
            local f = freq * (freq_end / freq) ^ t
            if vibrato then
                f = f * 2 ^ ((vibrato.depth or 0.3) * math.sin(index / sample_rate * math.pi * 2 * (vibrato.rate or 6)) / 12)
            end
            phase = phase + f / sample_rate
            local value = oscillator(layer.wave, phase, rng)
            if smooth > 0 then
                filtered = filtered + (value - filtered) * (1 - smooth)
                value = filtered
            end
            local envelope = 1
            if index < attack then envelope = index / attack end
            local remaining = count - index
            if remaining < release then envelope = envelope * (remaining / release) ^ 2 end
            local target = first + index + 1
            if target <= samples then mix[target] = mix[target] + value * envelope * volume end
        end
    end

    local data = love.sound.newSoundData(samples, sample_rate, 16, 1)
    for index = 1, samples do
        local value = mix[index]
        if value > 1 then value = 1 elseif value < -1 then value = -1 end
        data:setSample(index - 1, value)
    end
    return data
end

---render a table of named specs into an audio channel (default "sfx")
function Synth.register(sounds, channel_name)
    local channel = audio and audio.channels and audio.channels[channel_name or "sfx"]
    if not channel then return false end
    for name, spec in pairs(sounds) do
        channel:add_sound(name, Synth.render(spec))
    end
    return true
end

return Synth
