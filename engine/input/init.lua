input_mgr = {}

input_mgr.sources = {}

input_mgr.state = {
    active_keys = {},
    active_pad = {},
    wheel_dir = { 0, 0 },
    devices = {},
    typing = false,
    captured_element = nil,
    primary_input_device = 'keyboard', -- 'keyboard', 'controller', 'mobile'
    device_switch_time = 0,
    last_input_source = nil,
    -- Touch devices start without assuming a hardware keyboard. a real key
    -- event flips this on, allowing keyboard bindings to appear when usable
    keyboard_available = not (love.system.getOS() == 'Android' or love.system.getOS() == 'iOS')
}

-- the runtime is the sole owner of LÖVE callbacks. optional tools can observe
-- input through this small hook registry instead of wrapping `love.*`
input_mgr.observers = {}

---Observe a routed input event without replacing a LÖVE callback. a callback
---may return true from a *pressed event to consume that press after every
---observer has been notified, release and non-pressed events remain advisory
function input_mgr.add_observer(event_name, callback)
    assert(type(event_name) == "string" and event_name ~= "", "input observer needs an event name")
    assert(type(callback) == "function", "input observer needs a callback")
    local observers = input_mgr.observers[event_name] or {}
    input_mgr.observers[event_name] = observers
    observers[#observers + 1] = callback
    return callback
end

function input_mgr.remove_observer(event_name, callback)
    local observers = input_mgr.observers[event_name]
    if not observers then return end
    for index = #observers, 1, -1 do
        if observers[index] == callback then table.remove(observers, index) end
    end
end

local function notify_observers(event_name, ...)
    local observers = input_mgr.observers[event_name]
    if not observers then return false end
    local consumed = false
    for _, callback in ipairs(observers) do
        if callback(...) == true then consumed = true end
    end
    return consumed
end


--[[
action -> physical binding table. `bindings.keyboard` / `bindings.joy` hold a
love key / gamepad button name (or an array of them). optional `mode` per entry:
'hold' (default), 'toggle' (press latches on/off) or 'disabled'. rebinding,
modes and persistence live in engine/input/bindings.lua (input_mgr.bindings)
]]
input_mgr.key_mappings = {
    { name = 'up',         title = 'Forward',             bindings = { keyboard = { 'w', 'up' }, joy = 'dpup' } },
    { name = 'left',       title = 'Left',                bindings = { keyboard = { 'a', 'left' }, joy = 'dpleft' } },
    { name = 'right',      title = 'Right',               bindings = { keyboard = { 'd', 'right' }, joy = 'dpright' } },
    { name = 'down',       title = 'Backward',            bindings = { keyboard = { 's', 'down' }, joy = 'dpdown' } },
    { name = 'aimup',      title = 'Aim Up',              bindings = { keyboard = 'up' } },
    { name = 'aimleft',    title = 'Aim Left',            bindings = { keyboard = 'left' } },
    { name = 'aimright',   title = 'Aim Right',           bindings = { keyboard = 'right' } },
    { name = 'aimdown',    title = 'Aim Downwards',       bindings = { keyboard = 'down' } },
    { name = 'shoot',      title = 'Shoot',               bindings = { keyboard = 'mouse1', joy = 'r2' } },
    { name = 'roll',       title = 'Roll',                bindings = { keyboard = 'e', joy = 'rightshoulder' } },
    { name = 'block',      title = 'Block',               bindings = { keyboard = 'lshift', joy = 'rightshoulder' } },
    { name = 'eat',        title = 'Eat',                 bindings = { keyboard = 'q', joy = 'rightshoulder' } },
    { name = 'item1',      title = 'Item1',               bindings = { keyboard = '1', joy = 'rightshoulder' } },
    { name = 'item2',      title = 'Item2',               bindings = { keyboard = '2', joy = 'rightshoulder' } },
    { name = 'item3',      title = 'Item3',               bindings = { keyboard = '3', joy = 'rightshoulder' } },
    { name = 'pause',      title = 'Pause',               bindings = { keyboard = 'p', joy = 'start' } },
    { name = 'quit',       title = 'Quit',                bindings = { keyboard = 'escape', joy = 'back' } },
    { name = 'fullscreen', title = 'Fullscreen Shortcut', bindings = { keyboard = 'f11' } },
    { name = 'jump',       title = 'Jump',                bindings = { keyboard = 'space', joy = 'a' } },
    { name = 'camrecenter', title = 'Recenter Camera',    bindings = { joy = 'rightstick' } },
    { name = 'rebind_menu', title = 'Keybind Settings',   bindings = { keyboard = 'f6', joy = 'leftstick' } },
}

input_mgr.prompt_keys = {
    accept = { joystick = { "a" }, keyboard = { "space", } },
    decline = { joystick = { "b" }, keyboard = { "backspace", } }
}

-- load mobile first so other modules can check platform status immediately
input_mgr.mobile = require "engine/input/mobile"
-- Mouse next, it depends on mobile to decide whether system cursors exist
input_mgr.mouse = require "engine/input/mouse"
-- Controller follows mouse for shared input-source bookkeeping
input_mgr.controller = require "engine/input/controller"
-- Haptics/rumble support for controllers and mobile devices
input_mgr.vibration = require "engine/input/vibration"
input_mgr.haptics = input_mgr.vibration
input_mgr.rumble = input_mgr.vibration
input_mgr.typing = require "engine/input/typing"
input_mgr.microphone = require "engine/input/microphone"
input_mgr.menuscroll = require "engine/input/menuscroll"
-- rebinding + persistence + key modes (needs controller loaded for cache rebuilds)
input_mgr.bindings = require "engine/input/bindings"
input_mgr.bindings.load()

---add a named action, or replace the default keys of an existing one
---`spec.keyboard` / `spec.joy` take a key or gamepad button name (or a list);
---mouse buttons use the `mouse1`..`mouse5` pseudo-keys. a binding the player
---saved for this action earlier still wins over the default given here
---@param name string
---@param spec { title?: string, keyboard?: string|string[], joy?: string|string[], mode?: string }
function input_mgr.define_action(name, spec)
    assert(type(name) == 'string' and name ~= '', 'input action needs a name')
    assert(type(spec) == 'table', 'input action needs a binding table')
    local mapping = input_mgr.bindings.by_name[name]
    if not mapping then
        mapping = { name = name, bindings = {} }
        input_mgr.key_mappings[#input_mgr.key_mappings + 1] = mapping
    end
    mapping.title = spec.title or mapping.title or name
    mapping.bindings.keyboard = spec.keyboard
    mapping.bindings.joy = spec.joy
    mapping.mode = spec.mode or mapping.mode
    input_mgr.bindings.register_default(name)
    return mapping
end

input_mgr.key_handlers = {}

function input_mgr.add_key_handler(key_name, handlers)
    input_mgr.key_handlers[key_name] = handlers
end

function input_mgr.remove_key_handler(key_name, handlers)
    if handlers == nil or input_mgr.key_handlers[key_name] == handlers then
        input_mgr.key_handlers[key_name] = nil
    end
end

-- Projects may replace this with their own handler
input_mgr.add_key_handler('fullscreen', {
    pressed = function()
        local setting = CFG and CFG:getSetting('fullscreen')
        if not setting or not setting.set then return end
        setting.set(setting.value == 'windowed' and 'borderless' or 'windowed')
    end,
})

--[[
single dispatch funnel for both devices (keyboard/mouse pseudo-keys and gamepad
buttons/triggers all arrive here with clean press/release edges). per-action
modes are applied at this choke point: 'disabled' swallows everything, 'toggle'
turns each physical press into an alternating pressed/released latch and
swallows physical releases
]]
function input_mgr.execute_key_handler(key_name, action, ...)
    local b = input_mgr.bindings
    if b then
        local mode = b.mode_of(key_name)
        if mode == 'disabled' then return end
        if mode == 'toggle' then
            if action ~= 'pressed' then return end
            local latched = not b.toggle_state[key_name]
            b.toggle_state[key_name] = latched or nil
            action = latched and 'pressed' or 'released'
        end
    end
    local handler = input_mgr.key_handlers[key_name]
    if handler and handler[action] then
        handler[action](...)
    end
end

input_mgr.debug_commands = {
    ['0'] = function()
        G.debug.on = not G.debug.on
        if G.debug.on then
            G.pipeline:enable('draw', 'debug')
            G.pipeline:enable('update', 'debug')
        else
            G.pipeline:disable('draw', 'debug')
            G.pipeline:disable('update', 'debug')
        end
    end,
    -- toggle noclip (free-fly, no character/camera collision or raycasts). only meaningful
    -- while debug mode is on, gameplay code reads G.debug.noclip
    ['9'] = function()
        if G.debug then
            G.debug.noclip = not G.debug.noclip
        end
    end,
}

function input_mgr.update_primary_device()
    local current_time = love.timer.getTime()
    local has_controller = input_mgr.controller.has_controller()
    local is_mobile = input_mgr.mobile.is_mobile

    if input_mgr.state.last_input_source then
        local time_since_switch = current_time - input_mgr.state.device_switch_time
        if time_since_switch > 0.5 then
            if input_mgr.state.last_input_source ~= input_mgr.state.primary_input_device then
                input_mgr.state.primary_input_device = input_mgr.state.last_input_source
            end
        end
    end
end

function input_mgr.set_input_source(source)
    if source ~= input_mgr.state.last_input_source then
        input_mgr.state.last_input_source = source
        input_mgr.state.device_switch_time = love.timer.getTime()
    end
end

function input_mgr.focus(focused)
    notify_observers("focus", focused)
    if focused then return end
    -- window lost focus: key/button up events are not delivered while unfocused, so release
    -- everything held to avoid stuck movement/look on return. fires the normal release path
    -- (so 'released' handlers run) then clears the raw held-key set and any mouse-look capture
    local kbd = input_mgr.controller.controllers and input_mgr.controller.controllers['keyboard1']
    if kbd and kbd.btn_release and kbd.active_btns then
        local held = {}
        for btn in pairs(kbd.active_btns) do held[#held + 1] = btn end
        for _, btn in ipairs(held) do kbd:btn_release(btn) end
    end
    for key in pairs(input_mgr.state.active_keys) do
        input_mgr.state.active_keys[key] = nil
    end
    if input_mgr.mouse.set_look_active then input_mgr.mouse.set_look_active(false) end
    for btn in pairs(input_mgr.mouse.state.active) do
        input_mgr.mouse.state.active[btn] = nil
        input_mgr.mouse.state.active_source[btn] = nil
    end
end

function input_mgr.keypressed(key, scancode, isrepeat)
    input_mgr.state.keyboard_available = true
    input_mgr.set_input_source('keyboard')
    if notify_observers("keypressed", key, scancode, isrepeat) then return end
    input_mgr.state.active_keys[key] = 1

    -- rebind capture swallows the press before debug commands / typing / actions
    if input_mgr.bindings and input_mgr.bindings.feed_capture('keyboard', key) then
        return
    end

    if G.devbuild and not isrepeat and not input_mgr.state.typing and input_mgr.debug_commands[key] then
        input_mgr.debug_commands[key]()
    end

    if input_mgr.state.typing then
        if key == 'escape' or (key == 'b' and input_mgr.state.primary_input_device == 'controller') then
            input_mgr.typing.stop_typing()
            return
        end
        input_mgr.typing.handle_key_press(key)
        return
    end

    input_mgr.controller.handle_key_press(key)
end

function input_mgr.keyreleased(key)
    notify_observers("keyreleased", key)
    input_mgr.state.active_keys[key] = nil

    if not input_mgr.state.typing then
        input_mgr.controller.handle_key_release(key)
    end
end

function input_mgr.mousepressed(x, y, button, istouch)
    if notify_observers("mousepressed", x, y, button, istouch) then return end
    if istouch and input_mgr.mobile.is_mobile then
        return
    end

    input_mgr.mouse.handle_press(x, y, button)
end

function input_mgr.mousereleased(x, y, button, istouch)
    notify_observers("mousereleased", x, y, button, istouch)
    if istouch and input_mgr.mobile.is_mobile then
        return
    end

    input_mgr.mouse.handle_release(x, y, button)
end

function input_mgr.mousemoved(x, y, dx, dy, istouch)
    notify_observers("mousemoved", x, y, dx, dy, istouch)
    if istouch and input_mgr.mobile.is_mobile then
        return
    end

    input_mgr.mouse.handle_move(x, y, dx, dy)
end

function input_mgr.wheelmoved(x, y)
    notify_observers("wheelmoved", x, y)
    input_mgr.mouse.handle_wheel(x, y)
end

function input_mgr.textinput(text)
    notify_observers("textinput", text)
    input_mgr.typing.handle_text_input(text)
end

function input_mgr.touchpressed(id, x, y, dx, dy, pressure)
    input_mgr.set_input_source('mobile')
    if notify_observers("touchpressed", id, x, y, dx, dy, pressure) then return end

    input_mgr.mobile.handle_touch_press(id, x, y, dx, dy, pressure)
end

function input_mgr.touchmoved(id, x, y, dx, dy, pressure)
    input_mgr.mobile.handle_touch_move(id, x, y, dx, dy, pressure)
end

function input_mgr.touchreleased(id, x, y, dx, dy, pressure)
    input_mgr.mobile.handle_touch_release(id, x, y, dx, dy, pressure)
end

function input_mgr.joystickadded(joystick)
    input_mgr.controller.handle_joystick_added(joystick)
end

function input_mgr.joystickremoved(joystick)
    input_mgr.controller.handle_joystick_removed(joystick)
end

-- Gamepads report named axes through gamepadaxis, which follows SDL's
-- controller mapping. raw joystickaxis indices differ between devices, so
-- they are only used for joysticks without a gamepad mapping
local GAMEPAD_AXES = { leftx = 1, lefty = 2, rightx = 3, righty = 4, triggerleft = 5, triggerright = 6 }

function input_mgr.gamepadaxis(joystick, axis, value)
    local index = GAMEPAD_AXES[axis]
    if not index then return end
    if math.abs(value) > 0.3 then
        input_mgr.set_input_source('controller')
    end
    if not input_mgr.state.typing then
        input_mgr.controller.handle_gamepad_axis(joystick, index, value)
    end
end

function input_mgr.joystickaxis(joystick, axis, value)
    if joystick.isGamepad and joystick:isGamepad() then return end
    if math.abs(value) > 0.3 then
        input_mgr.set_input_source('controller')
    end
    if not input_mgr.state.typing then
        input_mgr.controller.handle_gamepad_axis(joystick, axis, value)
    end
end

function input_mgr.gamepadpressed(joystick, button)
    input_mgr.set_input_source('controller')
    if notify_observers("gamepadpressed", joystick, button) then return end

    if input_mgr.state.typing and button == 'b' then
        input_mgr.typing.stop_typing()
        return
    end

    if not input_mgr.state.typing then
        input_mgr.controller.handle_gamepad_pressed(joystick, button)
    end
end

function input_mgr.gamepadreleased(joystick, button)
    if not input_mgr.state.typing then
        input_mgr.controller.handle_gamepad_released(joystick, button)
    end
end

-- the runtime owns `love.*` callbacks. Hosts can register this map directly
-- instead of letting the input subsystem replace callbacks behind their back
input_mgr.callbacks = {
    focus = input_mgr.focus,
    keypressed = input_mgr.keypressed,
    keyreleased = input_mgr.keyreleased,
    mousepressed = input_mgr.mousepressed,
    mousereleased = input_mgr.mousereleased,
    mousemoved = input_mgr.mousemoved,
    wheelmoved = input_mgr.wheelmoved,
    textinput = input_mgr.textinput,
    touchpressed = input_mgr.touchpressed,
    touchmoved = input_mgr.touchmoved,
    touchreleased = input_mgr.touchreleased,
    joystickadded = input_mgr.joystickadded,
    joystickremoved = input_mgr.joystickremoved,
    joystickaxis = input_mgr.joystickaxis,
    gamepadaxis = input_mgr.gamepadaxis,
    gamepadpressed = input_mgr.gamepadpressed,
    gamepadreleased = input_mgr.gamepadreleased,
}

function input_mgr.update(dt)
    input_mgr.update_primary_device()
    input_mgr.vibration.update(dt)
end

-- keybind settings overlay (lazy: ui elements are only built on first open)
function input_mgr.open_rebind_menu()
    if not input_mgr.rebind_ui then
        input_mgr.rebind_ui = require "engine/input/rebind_ui"
    end
    input_mgr.rebind_ui.toggle()
end

input_mgr.add_key_handler('rebind_menu', {
    pressed = function() input_mgr.open_rebind_menu() end,
})

return input_mgr
