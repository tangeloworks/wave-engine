-- Showcase 3D's settings, one page per topic, for the pause menu. each item:
--   { label, kind = "toggle" | "choice" | "range", get(), set(value),
--     choices, labels (choice), min, max, step (range), preview() }
-- Custom settings are saved per player, engine settings go through CFG
local Sounds = require("projects/showcase3d/sounds")

local Settings = {}

-- hooks.set_quality(value) rebuilds the world for a new quality preset
function Settings.pages(program, hooks)
    hooks = hooks or {}
    local function custom(name, kind, extra)
        local definition = program.custom_settings[name]
        local item = {
            label = definition.title, kind = kind, choices = definition.choices,
            min = definition.min, max = definition.max,
            get = function() return program:getCustomSetting(name) end,
            set = function(value) program:setCustomSetting(name, value) end,
        }
        for key, value in pairs(extra or {}) do item[key] = value end
        return item
    end
    local function engine(name, label, kind, extra)
        local item = {
            label = label, kind = kind,
            get = function() return CFG:getSetting(name).value end,
            set = function(value) CFG:getSetting(name).set(value) end,
        }
        for key, value in pairs(extra or {}) do item[key] = value end
        return item
    end
    local volume = { min = 0, max = 10, step = 1 }
    local function with(base, extra)
        local out = {}
        for key, value in pairs(base) do out[key] = value end
        for key, value in pairs(extra) do out[key] = value end
        return out
    end
    return {
        { title = "Graphics", items = {
            custom("s3d_quality", "choice", { labels = { "Performance", "Balanced", "Quality" },
                set = hooks.set_quality or function(value) program:setCustomSetting("s3d_quality", value) end }),
            engine("fullscreen", "Display", "choice",
                { choices = { "windowed", "borderless" }, labels = { "Windowed", "Fullscreen" } }),
            engine("vsync", "VSync", "toggle"),
            engine("rate", "FPS Limit", "choice", {
                choices = { -1, 30, 60, 120, 144, 165, 240 },
                labels = { "Unlimited", "30", "60", "120", "144", "165", "240" } }),
            custom("s3d_show_stats", "toggle"),
        } },
        { title = "Audio", items = {
            engine("maxvol", "Master Volume", "range", with(volume, { preview = function() Sounds.preview("sfx") end })),
            engine("musicvol", "Music Volume", "range", with(volume, { preview = function() Sounds.preview("music") end })),
            engine("sfxvol", "Effects Volume", "range", with(volume, { preview = function() Sounds.preview("sfx") end })),
            engine("mono_audio", "Mono Audio", "toggle"),
        } },
        { title = "Controls", items = {
            custom("s3d_mouse_sensitivity", "range", { step = 0.05 }),
            custom("s3d_stick_speed", "range", { step = 0.1 }),
            custom("s3d_invert_y", "toggle"),
            custom("s3d_still_camera", "toggle"),
            custom("s3d_show_controls", "toggle"),
        } },
        { title = "Accessibility", items = {
            engine("reduced_motion", "Reduced Motion", "toggle"),
            engine("colorblind", "Color Assist", "choice", {
                choices = { "none", "protanopia", "deuteranopia", "tritanopia" },
                labels = { "Off", "Protanopia", "Deuteranopia", "Tritanopia" } }),
            engine("high_contrast", "High Contrast", "toggle"),
            engine("brightness", "Brightness", "range", { min = -0.5, max = 0.5, step = 0.1 }),
            engine("gamma", "Gamma", "range", { min = 0.5, max = 2.5, step = 0.1 }),
        } },
        { title = "Developer", items = {
            custom("s3d_collision_debug", "toggle"),
        } },
    }
end

local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-6 end
    return a == b
end

---the value as the row shows it
function Settings.value_text(item)
    local value = item.get()
    if item.kind == "toggle" then return value and "On" or "Off" end
    if item.kind == "choice" then
        for index, choice in ipairs(item.choices or {}) do
            if same(choice, value) then return (item.labels and item.labels[index]) or tostring(choice) end
        end
        return tostring(value)
    end
    local step = item.step or 1
    if step >= 1 then return ("%d"):format(math.floor((tonumber(value) or 0) + 0.5)) end
    local places = step >= 0.1 and 1 or 2
    return ("%." .. places .. "f"):format(tonumber(value) or 0)
end

---Step `item` in `direction` (-1 or 1). Choices and toggles wrap, ranges
---stop at their ends unless `wrap`. returns true when the value changed
function Settings.adjust(item, direction, wrap)
    local value = item.get()
    if item.kind == "toggle" then
        item.set(not value)
    elseif item.kind == "choice" then
        local choices = item.choices or {}
        local index = 1
        for position, choice in ipairs(choices) do if same(choice, value) then index = position end end
        index = ((index - 1 + direction) % #choices) + 1
        if same(choices[index], value) then return false end
        item.set(choices[index])
    elseif item.kind == "range" then
        local step = item.step or 1
        local low, high = item.min or 0, item.max or 1
        local current = tonumber(value) or low
        local next_value = current + step * direction
        if next_value > high + 1e-6 then next_value = wrap and low or high end
        if next_value < low - 1e-6 then next_value = wrap and high or low end
        next_value = math.floor(next_value / step + 0.5) * step
        if same(next_value, current) then return false end
        item.set(next_value)
    else
        return false
    end
    if item.preview then item.preview() end
    return true
end

return Settings
