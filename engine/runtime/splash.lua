-- Config-driven adapter around the preserved MIT Splashy implementation
--
-- `project.splash` may name a project-owned logo, but the fallback is an
-- engine-owned icon so a normal project never has to ship basic startup art
-- all drawing happens in the normal presentation pipeline, after content and
-- before the final accessibility shader/ratio composite
local Splashy = require("engine/services/oss/splashy")

local Splash = {}
local State = {}
State.__index = State

local DEFAULT_LOGO = require("engine/root") .. "/assets/img/iconimg.png"
local DEFAULT_FADE = 1.25
local DEFAULT_HOLD = 0.35
local DEFAULT_EXTRA_DELAY = 0.35
local DEFAULT_BACKGROUND_FADE = 0.60
local TRANSITION_EPSILON = 0.0001

local function finite_number(value, fallback, label)
    if value == nil then return fallback end
    value = tonumber(value)
    assert(value ~= nil and value == value and value ~= math.huge and value ~= -math.huge,
        (label or "value") .. " must be a finite number")
    return value
end

local function nonnegative(value, fallback, label)
    value = finite_number(value, fallback, label)
    assert(value >= 0, (label or "value") .. " must be non-negative")
    return value
end

local function first_option(options, ...)
    for index = 1, select("#", ...) do
        local key = select(index, ...)
        if options[key] ~= nil then return options[key] end
    end
    return nil
end

local function normalise_color(color, label)
    if color == nil then return { 0, 0, 0, 1 } end
    label = label or "project.splash.background"
    assert(type(color) == "table", label .. " must be a color table")
    local result = {}
    for index = 1, 4 do
        local fallback = index == 4 and 1 or 0
        local value = finite_number(color[index], fallback, label .. "[" .. index .. "]")
        result[index] = math.max(0, math.min(1, value))
    end
    return result
end

local function is_drawable(value)
    local kind = type(value)
    return (kind == "userdata" or kind == "table")
        and type(value.getWidth) == "function"
        and type(value.getHeight) == "function"
end

local function load_logo(source)
    source = source or DEFAULT_LOGO
    if type(source) == "string" then
        assert(source ~= "", "project.splash.logo cannot be an empty path")
        local ok, image_or_error = pcall(love.graphics.newImage, source)
        assert(ok, ("could not load project.splash.logo '%s': %s"):format(source, tostring(image_or_error)))
        image_or_error:setFilter("linear", "linear")
        return image_or_error, source
    end
    assert(is_drawable(source), "project.splash.logo must be an image path or LÖVE drawable")
    return source, nil
end

local function reduced_motion_enabled()
    local setting = CFG and CFG.getSetting and CFG:getSetting("reduced_motion")
    return setting and setting.value == true
end

function State:is_active()
    return self.enabled and not self.finished
end

---whether the runtime should suppress gameplay input while this splash owns
---the screen. this remains true for a non-skippable splash
function State:blocks_input()
    return self:is_active()
end

---whether the project lifecycle must remain suspended while this startup
---screen owns presentation. this is deliberately separate from input routing:
---the launcher uses it to defer project startup and all project updates, so a
---configured splash never requires project-specific pause code
function State:blocks_gameplay()
    return self:is_active()
end

local function is_guarded(guards, event, ...)
    if event == "keypressed" then
        return guards.keys[select(1, ...)] == true
    elseif event == "keyreleased" then
        local key = select(1, ...)
        local guarded = guards.keys[key] == true
        guards.keys[key] = nil
        return guarded
    elseif event == "mousepressed" then
        return guards.mouse_buttons[select(3, ...)] == true
    elseif event == "mousereleased" then
        local button = select(3, ...)
        local guarded = guards.mouse_buttons[button] == true
        guards.mouse_buttons[button] = nil
        return guarded
    elseif event == "mousemoved" then
        return next(guards.mouse_buttons) ~= nil
    elseif event == "touchpressed" then
        return guards.touches[select(1, ...)] == true
    elseif event == "touchmoved" then
        return guards.touches[select(1, ...)] == true
    elseif event == "touchreleased" then
        local id = select(1, ...)
        local guarded = guards.touches[id] == true
        guards.touches[id] = nil
        return guarded
    elseif event == "gamepadpressed" then
        local joystick, button = select(1, ...), select(2, ...)
        return guards.gamepad[joystick] and guards.gamepad[joystick][button] == true
    elseif event == "gamepadreleased" then
        local joystick, button = select(1, ...), select(2, ...)
        local by_button = guards.gamepad[joystick]
        local guarded = by_button and by_button[button] == true
        if by_button then
            by_button[button] = nil
            if next(by_button) == nil then guards.gamepad[joystick] = nil end
        end
        return guarded
    end
    return false
end

local function remember_input(guards, event, ...)
    if event == "keypressed" then
        guards.keys[select(1, ...)] = true
    elseif event == "mousepressed" then
        guards.mouse_buttons[select(3, ...)] = true
    elseif event == "touchpressed" then
        guards.touches[select(1, ...)] = true
    elseif event == "gamepadpressed" then
        local joystick, button = select(1, ...), select(2, ...)
        local by_button = guards.gamepad[joystick] or {}
        guards.gamepad[joystick] = by_button
        by_button[button] = true
    end
end

---Claim an input event before the input subsystem sees it.  when a press
---dismisses the splash its matching release (and held pointer/touch motion)
---remains claimed too, so a project never receives half of that gesture
function State:blocks_input_event(event, ...)
    if self:is_active() then
        remember_input(self.input_guards, event, ...)
        return true
    end
    return is_guarded(self.input_guards, event, ...)
end

function State:_fit_logo(width, height)
    local image_width = self.logo:getWidth()
    local image_height = self.logo:getHeight()
    assert(image_width > 0 and image_height > 0, "project.splash.logo has invalid dimensions")
    return math.min(width * self.fit_width / image_width, height * self.fit_height / image_height)
        * self.logo_scale
end

function State:_resize(width, height)
    width = math.max(1, finite_number(width, love.graphics.getWidth(), "splash width"))
    height = math.max(1, finite_number(height, love.graphics.getHeight(), "splash height"))
    if self.width == width and self.height == height then return end
    self.width, self.height = width, height
    Splashy.setScreenSize(width, height)
    -- the adapter adds exactly one splash at index 1. Re-fit on every virtual
    -- resolution change so 4:3/stretch/high-DPI presentation stays centered
    Splashy.scaleList[1] = self:_fit_logo(width, height)
end

function State:_finish(skipped)
    if self.finished then return false end
    self.finished = true
    self.skipped = skipped == true
    Splashy.skipAll()
    return true
end

function State:skip()
    if not self.skippable then return false end
    return self:_finish(true)
end

function State:update(dt)
    if not self:is_active() then return end
    if reduced_motion_enabled() then
        self:_finish(false)
        return
    end
    dt = math.max(0, finite_number(dt, 0, "splash dt"))
    Splashy.update(dt)
    if Splashy.finished then self.finished = true end
end

function State:draw(width, height)
    if not self:is_active() then return end
    self:_resize(width, height)

    local graphics = love.graphics
    graphics.push("all")
    graphics.origin()
    graphics.setShader()
    graphics.setScissor()
    graphics.setStencilTest()
    graphics.setColorMask(true, true, true, true)
    graphics.setDepthMode("always", false)
    graphics.setMeshCullMode("none")
    graphics.setBlendMode("alpha", "alphamultiply")
    Splashy.draw()
    graphics.pop()
end

---create a one-logo startup splash
---
---Recognized fields deliberately mirror the recovered Splashy integration:
---`logo`, `duration`, `fade_in`, `fade_out`, `delay_init`, `hold`,
---`extra_delay`, `background_fade`, `background`, `end_color`, `logo_scale`,
---`fit_width`, `fit_height`, `animation`, and `skippable`. CamelCase legacy
---Splashy names are accepted as aliases for the timing fields
function Splash.new(options)
    if options == true then options = {} end
    options = options or {}
    assert(type(options) == "table", "project.splash must be true, false, or a table")

    local enabled = options.enabled ~= false
    local duration = nonnegative(options.duration, DEFAULT_FADE, "project.splash.duration")
    local fade_in = nonnegative(first_option(options, "fade_in", "fadeIn"), duration,
        "project.splash.fade_in")
    local fade_out = nonnegative(first_option(options, "fade_out", "fadeOut"), duration,
        "project.splash.fade_out")
    local delay_init = nonnegative(first_option(options, "delay_init", "delayInit"), 0,
        "project.splash.delay_init")
    local hold = nonnegative(first_option(options, "hold", "delay_finish", "delayFinish"), DEFAULT_HOLD,
        "project.splash.hold")
    local extra_delay = nonnegative(first_option(options, "extra_delay", "extraDelay"), DEFAULT_EXTRA_DELAY,
        "project.splash.extra_delay")
    local background_fade = nonnegative(first_option(options, "background_fade", "color_fade", "colorFade"),
        DEFAULT_BACKGROUND_FADE, "project.splash.background_fade")
    local background = normalise_color(first_option(options, "background", "color"), "project.splash.background")
    -- keep startup presentation opaque by default. Splashy previously faded
    -- this color to transparent, which exposed the engine clear color (often
    -- white) for a frame before deferred project startup. Projects can opt
    -- into any finish color, including an alpha-zero legacy reveal
    local end_color = normalise_color(first_option(options, "end_color", "endColor") or background,
        "project.splash.end_color")
    local logo_scale = finite_number(first_option(options, "logo_scale", "scale"), 1,
        "project.splash.logo_scale")
    local fit_width = finite_number(options.fit_width, 0.55, "project.splash.fit_width")
    local fit_height = finite_number(options.fit_height, 0.50, "project.splash.fit_height")
    assert(logo_scale > 0, "project.splash.logo_scale must be positive")
    assert(fit_width > 0 and fit_height > 0, "project.splash fit bounds must be positive")

    -- preserve the runtime's duration=0 opt-out. Projects that intentionally
    -- want an instant logo followed by a hold/background phase can opt in by
    -- naming any phase explicitly
    local explicit_phase = first_option(options, "fade_in", "fadeIn", "fade_out", "fadeOut",
        "delay_init", "delayInit", "hold", "delay_finish", "delayFinish", "extra_delay", "extraDelay",
        "background_fade", "color_fade", "colorFade") ~= nil
    local phase_time = delay_init + fade_in + hold + fade_out + extra_delay + background_fade
    local total_time = phase_time
    if duration == 0 and not explicit_phase then total_time = 0 end
    local state = setmetatable({
        enabled = enabled,
        finished = not enabled or total_time <= 0 or reduced_motion_enabled(),
        skipped = false,
        skippable = options.skippable ~= false,
        input_guards = { keys = {}, mouse_buttons = {}, touches = {}, gamepad = {} },
        logo_scale = logo_scale,
        fit_width = fit_width,
        fit_height = fit_height,
        background = background,
        end_color = end_color,
    }, State)
    if state.finished then return state end

    state.logo, state.logo_path = load_logo(first_option(options, "logo", "image"))
    state:_resize(love.graphics.getWidth(), love.graphics.getHeight())

    -- Splashy's tween implementation requires strictly positive durations
    -- a configured zero is still supported here as an effectively instant
    -- transition while preserving its expected phase ordering
    Splashy.reset()
    Splashy.setScreenSize(state.width, state.height)
    Splashy.addSplash(
        state.logo,
        math.max(fade_in, fade_out, TRANSITION_EPSILON),
        1,
        state.background,
        state:_fit_logo(state.width, state.height),
        delay_init,
        hold,
        extra_delay,
        background_fade,
        options.animation,
        {
            fade_in = math.max(fade_in, TRANSITION_EPSILON),
            fade_out = math.max(fade_out, TRANSITION_EPSILON),
        },
        state.end_color
    )
    Splashy.onComplete(function() state.finished = true end)
    return state
end

return Splash
