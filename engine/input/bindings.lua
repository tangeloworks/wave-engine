--[[
keybind rebinding + persistence + per-action key modes for the input manager

- rebind(action, device, key): change the 'keyboard' or 'joy' binding of a named
  action at runtime (key = love key name, 'mouseN' pseudo-key, or gamepad button;
  nil unbinds). gamepad button caches are rebuilt automatically
- modes: each action dispatches as 'hold' (default: pressed while physically
  down), 'toggle' (a press flips the action's latched state and fires
  pressed/released accordingly, physical releases are swallowed) or 'disabled'
  polling (controller.is_action_active etc.) follows the same semantics
- begin_capture(device, fn): the next physical key/button press on that device
  is captured (swallowed) and handed to fn instead of dispatching. escape
  cancels (fn(nil)). 'mouse1' is never captured so ui stays clickable
- bindings, modes and the mobile button layout persist together to one file in
  the love save directory, written on every change and loaded at startup
  intentionally independent of G.no_save_mode: input config is device-local
  user preference, not game save data
]]

local bindings = {}

bindings.path = 'input_bindings.cfg'
bindings.by_name = {}      -- action name -> live key_mappings entry
bindings.toggle_state = {} -- action name -> true while latched on
bindings.mobile_layout = {} -- button id -> { cx, cy, scale } (normalized center + size multiplier)
bindings.capture = nil
bindings.on_changed = nil  -- optional hook(kind) fired after any change ('binding'|'mode'|'layout'|'reset')

local MODES = { hold = true, toggle = true, disabled = true }
local DEVICES = { keyboard = true, joy = true }

local defaults = {} -- action name -> { keyboard = ..., joy = ..., mode = ... } snapshot

local function copy_binding(b)
    if type(b) == 'table' then
        local t = {}
        for i = 1, #b do t[i] = b[i] end
        return t
    end
    return b
end

function bindings.rebuild_index()
    local idx = {}
    for _, mapping in ipairs(input_mgr.key_mappings) do
        idx[mapping.name] = mapping
    end
    bindings.by_name = idx
end

-- snapshot factory defaults once so reset works even after rebinds were saved
local function snapshot_defaults()
    for _, mapping in ipairs(input_mgr.key_mappings) do
        if not defaults[mapping.name] then
            defaults[mapping.name] = {
                keyboard = copy_binding(mapping.bindings.keyboard),
                joy = copy_binding(mapping.bindings.joy),
                mode = mapping.mode or 'hold',
            }
        end
    end
end

function bindings.mode_of(action)
    local mapping = bindings.by_name[action]
    local mode = mapping and mapping.mode
    if mode and MODES[mode] then return mode end
    return 'hold'
end

-- true when any physical key/button of the mapping is currently held (raw state,
-- ignores modes). used to synthesize releases when a held action is rebound
local function physically_active(mapping)
    local ctrl = input_mgr.controller
    local kbd = ctrl and ctrl.controllers and ctrl.controllers['keyboard1']
    local kb = mapping.bindings.keyboard
    if kb and kbd then
        local list = type(kb) == 'table' and kb or { kb }
        for _, key in ipairs(list) do
            if kbd.active_btns[key] then return true end
        end
    end
    local joy = mapping.bindings.joy
    if joy and ctrl then
        local list = type(joy) == 'table' and joy or { joy }
        for _, btn in ipairs(list) do
            if ctrl.is_gamepad_active(btn) then return true end
        end
    end
    return false
end

-- fire the raw released handler (bypasses mode logic on purpose) so gameplay
-- never sees a stuck hold when a binding/mode changes under a held key
local function settle_action(action)
    local mapping = bindings.by_name[action]
    if not mapping then return end
    local was_latched = bindings.toggle_state[action]
    bindings.toggle_state[action] = nil
    if was_latched or physically_active(mapping) then
        local handler = input_mgr.key_handlers[action]
        if handler and handler.released then handler.released() end
    end
end

local function notify(kind)
    if bindings.on_changed then bindings.on_changed(kind) end
end

function bindings.get_binding(action, device)
    local mapping = bindings.by_name[action]
    if not mapping then return nil end
    return mapping.bindings[device]
end

-- human-readable label for a binding value ('W', 'Mouse 2', 'RIGHTSHOULDER', '---')
function bindings.binding_label(value)
    if value == nil then return '---' end
    if type(value) == 'table' then
        local parts = {}
        for i = 1, #value do parts[i] = bindings.binding_label(value[i]) end
        return table.concat(parts, ' / ')
    end
    local s = tostring(value)
    local mouse_btn = s:match('^mouse(%d+)$')
    if mouse_btn then return 'Mouse ' .. mouse_btn end
    return s:upper()
end

function bindings.rebind(action, device, key)
    if not DEVICES[device] then return false end
    local mapping = bindings.by_name[action]
    if not mapping then return false end
    settle_action(action)
    mapping.bindings[device] = key
    if input_mgr.controller and input_mgr.controller.rebuild_btn_caches then
        input_mgr.controller.rebuild_btn_caches()
    end
    bindings.save()
    notify('binding')
    return true
end

function bindings.set_mode(action, mode)
    if not MODES[mode] then return false end
    local mapping = bindings.by_name[action]
    if not mapping then return false end
    if (mapping.mode or 'hold') == mode then return true end
    settle_action(action)
    mapping.mode = mode
    bindings.save()
    notify('mode')
    return true
end

-- cycle hold -> toggle -> disabled -> hold (for a one-button ui)
function bindings.cycle_mode(action)
    local order = { hold = 'toggle', toggle = 'disabled', disabled = 'hold' }
    local next_mode = order[bindings.mode_of(action)] or 'hold'
    bindings.set_mode(action, next_mode)
    return next_mode
end

function bindings.reset_action(action)
    local mapping = bindings.by_name[action]
    local def = defaults[action]
    if not (mapping and def) then return false end
    settle_action(action)
    mapping.bindings.keyboard = copy_binding(def.keyboard)
    mapping.bindings.joy = copy_binding(def.joy)
    mapping.mode = def.mode
    if input_mgr.controller and input_mgr.controller.rebuild_btn_caches then
        input_mgr.controller.rebuild_btn_caches()
    end
    bindings.save()
    notify('reset')
    return true
end

function bindings.reset_all()
    for name in pairs(bindings.by_name) do
        local mapping = bindings.by_name[name]
        local def = defaults[name]
        if mapping and def then
            settle_action(name)
            mapping.bindings.keyboard = copy_binding(def.keyboard)
            mapping.bindings.joy = copy_binding(def.joy)
            mapping.mode = def.mode
        end
    end
    bindings.mobile_layout = {}
    if input_mgr.controller and input_mgr.controller.rebuild_btn_caches then
        input_mgr.controller.rebuild_btn_caches()
    end
    bindings.save()
    notify('reset')
end

-- ===================== capture (press-a-key rebinding) =====================

function bindings.begin_capture(device, fn)
    if not DEVICES[device] then return false end
    bindings.capture = { device = device, fn = fn }
    return true
end

function bindings.cancel_capture()
    local cap = bindings.capture
    bindings.capture = nil
    if cap and cap.fn then cap.fn(nil) end
end

function bindings.capture_active()
    return bindings.capture ~= nil
end

--[[
feed a raw press into an active capture. returns true when the press was
consumed. called from the input funnels (love.keypressed for keyboard keys,
controller btn_press for gamepad buttons and mouse pseudo-keys)
]]
function bindings.feed_capture(device, key)
    local cap = bindings.capture
    if not cap then return false end
    if device == 'keyboard' and key == 'escape' then
        bindings.cancel_capture()
        return true
    end
    if device ~= cap.device then return false end
    if key == 'mouse1' then return false end -- reserved for clicking the ui
    bindings.capture = nil
    if cap.fn then cap.fn(key) end
    return true
end

-- ===================== mobile layout store =====================

function bindings.get_button_layout(id)
    return bindings.mobile_layout[id]
end

function bindings.set_button_layout(id, cx, cy, scale)
    local entry = bindings.mobile_layout[id]
    if not entry then
        entry = {}
        bindings.mobile_layout[id] = entry
    end
    entry.cx, entry.cy, entry.scale = cx, cy, scale
    bindings.save()
    notify('layout')
end

function bindings.clear_button_layout(id)
    if id then
        bindings.mobile_layout[id] = nil
    else
        bindings.mobile_layout = {}
    end
    bindings.save()
    notify('layout')
end

-- ===================== persistence =====================

function bindings.save()
    local payload = { version = 1, bindings = {}, modes = {}, mobile_layout = bindings.mobile_layout }
    for name, mapping in pairs(bindings.by_name) do
        payload.bindings[name] = {
            keyboard = copy_binding(mapping.bindings.keyboard),
            joy = copy_binding(mapping.bindings.joy),
        }
        if mapping.mode and mapping.mode ~= 'hold' then
            payload.modes[name] = mapping.mode
        end
    end
    local ok, err = pcall(function()
        love.filesystem.write(bindings.path, serialize_table(payload))
    end)
    if not ok then
        print('[input] failed to save bindings: ' .. tostring(err))
    end
end

local function valid_binding_value(v)
    if v == nil or type(v) == 'string' then return true end
    if type(v) == 'table' then
        for _, item in ipairs(v) do
            if type(item) ~= 'string' then return false end
        end
        return true
    end
    return false
end

-- apply one action's saved binding/mode from the last loaded payload
local function apply_saved(name)
    local payload = bindings._saved
    local mapping = bindings.by_name[name]
    if not payload or not mapping then return end
    local saved = type(payload.bindings) == 'table' and payload.bindings[name]
    if type(saved) == 'table' and valid_binding_value(saved.keyboard) and valid_binding_value(saved.joy) then
        mapping.bindings.keyboard = copy_binding(saved.keyboard)
        mapping.bindings.joy = copy_binding(saved.joy)
    end
    local mode = type(payload.modes) == 'table' and payload.modes[name]
    if mode and MODES[mode] then mapping.mode = mode end
end

---record an action added after startup (input_mgr.define_action): its
---current keys become the reset default and a saved rebinding is applied
function bindings.register_default(name)
    bindings.rebuild_index()
    local mapping = bindings.by_name[name]
    if not mapping then return end
    defaults[name] = {
        keyboard = copy_binding(mapping.bindings.keyboard),
        joy = copy_binding(mapping.bindings.joy),
        mode = mapping.mode or 'hold',
    }
    apply_saved(name)
    if input_mgr.controller and input_mgr.controller.rebuild_btn_caches then
        input_mgr.controller.rebuild_btn_caches()
    end
end

function bindings.load()
    bindings.rebuild_index()
    snapshot_defaults()
    if not love.filesystem.getInfo(bindings.path) then return end
    local raw = love.filesystem.read(bindings.path)
    if not raw or #raw == 0 then return end
    local ok, payload = pcall(deserialize_table, raw)
    if not ok or type(payload) ~= 'table' then
        print('[input] ignoring corrupt ' .. bindings.path)
        return
    end
    bindings._saved = payload
    for name in pairs(bindings.by_name) do apply_saved(name) end
    if type(payload.mobile_layout) == 'table' then
        for id, entry in pairs(payload.mobile_layout) do
            if type(entry) == 'table'
                and type(entry.cx) == 'number' and type(entry.cy) == 'number' then
                bindings.mobile_layout[id] = {
                    cx = entry.cx, cy = entry.cy,
                    scale = type(entry.scale) == 'number' and entry.scale or 1,
                }
            end
        end
    end
    if input_mgr.controller and input_mgr.controller.rebuild_btn_caches then
        input_mgr.controller.rebuild_btn_caches()
    end
end

return bindings
