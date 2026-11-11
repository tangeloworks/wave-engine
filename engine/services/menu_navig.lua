--[[
    menu_navig

    a small, portable menu navigation service for this LÖVE framework
    it listens to the framework's global input pipeline, so keyboard and any
    connected controller can control the same menu without binding to a device

    Basic use:

        local MenuNavig = require "engine/services/menu_navig"
        local menu = MenuNavig.new({
            items = {
                { label = "back", on_select = close_menu },
                { label = "music on/off", on_select = toggle_music },
                { label = "quit", on_select = love.event.quit },
            },
            active = false,
            on_change = function(menu, index, item) end,
            on_cancel = close_menu,
        })

        menu:open()
        menu:close()
        menu:destroy()

    an item with `on_adjust(item, direction, menu)` also reacts to the cross
    axis (left/right in a vertical menu), for sliders and option pickers
]]

local MenuNavig = {}
local Menu = {}
Menu.__index = Menu

local next_id = 0
local function now()
    return love.timer.getTime()
end

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function safe_call(fn, ...)
    if fn then return fn(...) end
end

local function source_kind(source)
    if type(source) == "table" and source.type == "joystick" then
        return "controller"
    end
    if type(source) == "table" and source.type == "keyboard" then
        return "keyboard"
    end
    return nil
end

local function item_label(item)
    if type(item) == "table" then return item.label or item.name or tostring(item) end
    return tostring(item)
end

local KEYBOARD_NAV_KEYS = {
    w = "up", up = "up",
    s = "down", down = "down",
    a = "left", left = "left",
    d = "right", right = "right",
}

local CONTROLLER_NAV_KEYS = {
    dpup = "up",
    dpdown = "down",
    dpleft = "left",
    dpright = "right",
}

local KEYBOARD_ACCEPT_KEYS = {
    space = true,
    ["return"] = true,
    kpenter = true,
}

local CONTROLLER_ACCEPT_KEYS = {
    a = true,
    start = true,
}

local KEYBOARD_CANCEL_KEYS = {
    escape = true,
    backspace = true,
}

local CONTROLLER_CANCEL_KEYS = {
    b = true,
    back = true,
}

local MOUSE_KEYS = {
    mouse1 = true,
    mouse2 = true,
    mouse3 = true,
}

local function direction_from_key(key, axis, kind)
    local dir
    if kind == "controller" then
        dir = CONTROLLER_NAV_KEYS[key]
    elseif kind == "keyboard" then
        dir = KEYBOARD_NAV_KEYS[key]
    else
        dir = KEYBOARD_NAV_KEYS[key] or CONTROLLER_NAV_KEYS[key]
    end

    if axis == "x" then
        if dir == "left" then return -1 end
        if dir == "right" then return 1 end
    else
        if dir == "up" then return -1 end
        if dir == "down" then return 1 end
    end
    return 0
end

local function is_accept_key(key, prompt, kind)
    if prompt == "accept" then return true end
    if kind == "controller" then return CONTROLLER_ACCEPT_KEYS[key] == true end
    if kind == "keyboard" then return KEYBOARD_ACCEPT_KEYS[key] == true end
    return KEYBOARD_ACCEPT_KEYS[key] == true or CONTROLLER_ACCEPT_KEYS[key] == true
end

local function is_cancel_key(key, prompt, kind)
    if prompt == "decline" then return true end
    if kind == "controller" then return CONTROLLER_CANCEL_KEYS[key] == true end
    if kind == "keyboard" then return KEYBOARD_CANCEL_KEYS[key] == true end
    return KEYBOARD_CANCEL_KEYS[key] == true or CONTROLLER_CANCEL_KEYS[key] == true
end

local function key_is_down(key)
    return input_mgr and input_mgr.state and input_mgr.state.active_keys and input_mgr.state.active_keys[key] ~= nil
end

local function gamepad_button_down(btn)
    if not input_mgr or not input_mgr.controller or not input_mgr.controller.controllers then
        return false
    end

    for _, ctrl in pairs(input_mgr.controller.controllers) do
        if ctrl.type == "joystick" and ctrl.active_btns and ctrl.active_btns[btn] then
            return true
        end
    end

    return false
end

local function read_axis(axis, stick_id)
    if not input_mgr or not input_mgr.controller then return 0, nil end

    local x, y = 0, 0
    local used = nil

    -- Keyboard arrows and WASD are read directly so menu navigation does not
    -- need a named gameplay action
    if key_is_down("w") or key_is_down("up") then y = y - 1; used = "keyboard" end
    if key_is_down("s") or key_is_down("down") then y = y + 1; used = "keyboard" end
    if key_is_down("a") or key_is_down("left") then x = x - 1; used = "keyboard" end
    if key_is_down("d") or key_is_down("right") then x = x + 1; used = "keyboard" end

    -- D-pad from any controller
    if gamepad_button_down("dpup") then y = y - 1; used = "controller" end
    if gamepad_button_down("dpdown") then y = y + 1; used = "controller" end
    if gamepad_button_down("dpleft") then x = x - 1; used = "controller" end
    if gamepad_button_down("dpright") then x = x + 1; used = "controller" end

    -- Sticks are stored globally by engine/input/controller.lua. this keeps the
    -- service device-agnostic while still supporting hot-swap between pads
    local sticks = input_mgr.controller.active_sticks or {}
    local stick_name = stick_id == 2 and "stick2" or "stick1"
    local stick = sticks[stick_name]
    if stick then
        local sx = tonumber(stick[1]) or 0
        local sy = tonumber(stick[2]) or 0
        if math.abs(sx) > 0.01 or math.abs(sy) > 0.01 then
            x = x + sx
            y = y + sy
            used = "controller"
        end
    end

    if axis == "x" then
        return clamp(x, -1, 1), used
    end
    return clamp(y, -1, 1), used
end

local function normalize_axis(axis)
    axis = tostring(axis or "y"):lower()
    if axis == "x" then return "x" end
    return "y"
end

function MenuNavig.new(args)
    args = args or {}
    next_id = next_id + 1

    local self = setmetatable({
        id = args.id or ("menu_navig_" .. next_id),
        axis = normalize_axis(args.axis),
        stick = args.stick or 1,
        items = args.items or {},
        index = args.index or 1,
        wrap = args.wrap ~= false,
        active = args.active == true,
        visible = args.visible ~= false,
        deadzone = args.deadzone or 0.55,
        repeat_delay = args.repeat_delay or 0.36,
        repeat_rate = args.repeat_rate or 0.10,
        on_change = args.on_change,
        on_accept = args.on_accept,
        on_cancel = args.on_cancel,
        on_open = args.on_open,
        on_close = args.on_close,
        on_input_mode = args.on_input_mode,
        on_render = args.on_render,
        _last_source = input_mgr and input_mgr.state and input_mgr.state.primary_input_device or "keyboard",
        _loaded = false,
        _held_dir = 0,
        _repeat_at = 0,
        _held_adjust = 0,
        _adjust_repeat_at = 0,
        _pipe = {},
    }, Menu)

    self.index = clamp(self.index, 1, math.max(1, #self.items))

    if args.autoload ~= false then
        self:load()
    end

    if self.active then
        self:_sync_selection(nil, true)
    end

    return self
end

function Menu:load()
    if self._loaded then return self end
    self._loaded = true

    local uid = self.id
    self._pipe.start = uid .. ":input_start"
    self._pipe.change = uid .. ":input_change"
    self._pipe.update = uid .. ":update"

    G.pipeline:register("input_start", self._pipe.start, function(key, prompt, source)
        self:_handle_input_start(key, prompt, source)
    end, { priority = 50 })

    G.pipeline:register("input_change", self._pipe.change, function(axis, value)
        self:_handle_input_change(axis, value)
    end, { priority = 50 })

    G.pipeline:register("update", self._pipe.update, function(dt)
        self:update(dt)
    end, { priority = 50 })

    return self
end

function Menu:destroy()
    self:close()
    if self._pipe then
        if self._pipe.start then G.pipeline:remove("input_start", self._pipe.start) end
        if self._pipe.change then G.pipeline:remove("input_change", self._pipe.change) end
        if self._pipe.update then G.pipeline:remove("update", self._pipe.update) end
    end
    self._pipe = nil
end

function Menu:get_selected()
    return self.items[self.index], self.index
end

function Menu:set_items(items, keep_index)
    local old_item = self.items[self.index]
    if old_item then self:_set_item_selected(old_item, false) end

    self.items = items or {}
    if keep_index then
        self.index = clamp(self.index, 1, math.max(1, #self.items))
    else
        self.index = 1
    end

    self:_sync_selection(nil, true)
end

function Menu:set_active(active)
    if active then
        self:open()
    else
        self:close()
    end
end

function Menu:open(index)
    local was_active = self.active
    self.active = true
    if index then self.index = clamp(index, 1, math.max(1, #self.items)) end
    self._held_dir = 0
    self._repeat_at = 0
    self:_sync_selection(nil, true)
    if not was_active then safe_call(self.on_open, self) end
end

function Menu:close()
    if not self.active then return end
    local item = self.items[self.index]
    if item then self:_set_item_selected(item, false) end
    self.active = false
    self._held_dir = 0
    self._repeat_at = 0
    safe_call(self.on_close, self)
end

function Menu:_set_source(source)
    local kind = source_kind(source)
    if kind and kind ~= self._last_source then
        self._last_source = kind
        safe_call(self.on_input_mode, self, kind)
    end
end

function Menu:_set_item_selected(item, selected)
    if type(item) ~= "table" then return end
    item.selected = selected

    if item.element then
        item.element.menu_selected = selected
    end

    if selected then
        safe_call(item.on_enter, item, self)
    else
        safe_call(item.on_leave, item, self)
    end
end

function Menu:_sync_selection(old_index, force)
    if #self.items == 0 then return end
    self.index = clamp(self.index, 1, #self.items)

    if old_index and old_index ~= self.index then
        self:_set_item_selected(self.items[old_index], false)
    end

    if force or old_index ~= self.index then
        local item = self.items[self.index]
        self:_set_item_selected(item, true)
        safe_call(self.on_change, self, self.index, item, item_label(item))
    end
end

function Menu:move(delta)
    if #self.items == 0 or delta == 0 then return self.index end

    local old = self.index
    local next_index = self.index + delta

    if self.wrap then
        next_index = ((next_index - 1) % #self.items) + 1
    else
        next_index = clamp(next_index, 1, #self.items)
    end

    if next_index ~= self.index then
        self.index = next_index
        self:_sync_selection(old)
    end

    return self.index
end

function Menu:accept()
    if #self.items == 0 then return end
    local item = self.items[self.index]
    safe_call(self.on_accept, self, self.index, item, item_label(item))
    if type(item) == "table" then
        safe_call(item.on_select, item, self)
    end
end

function Menu:cancel()
    safe_call(self.on_cancel, self)
end

---Adjust the selected item along the cross axis (-1 or 1)
function Menu:adjust(direction)
    local item = self.items[self.index]
    if type(item) == "table" and item.on_adjust and direction ~= 0 then
        item.on_adjust(item, direction, self)
        return true
    end
    return false
end

function Menu:_begin_hold(dir)
    if dir == 0 then return end
    self._held_dir = dir
    self._repeat_at = now() + self.repeat_delay
end

function Menu:_handle_input_start(key, prompt, source)
    if not self.active or not self.visible then return end
    if input_mgr and input_mgr.state and input_mgr.state.typing then return end

    local kind = source_kind(source)
    self:_set_source(source)

    if MOUSE_KEYS[key] then
        return
    end

    local dir = direction_from_key(key, self.axis, kind)
    if dir ~= 0 then
        self:move(dir)
        self:_begin_hold(dir)
        return
    end

    local cross = direction_from_key(key, self.axis == "y" and "x" or "y", kind)
    if cross ~= 0 and self:adjust(cross) then
        self._held_adjust = cross
        self._adjust_repeat_at = now() + self.repeat_delay
        return
    end

    if is_accept_key(key, prompt, kind) then
        self:accept()
        return
    end

    if is_cancel_key(key, prompt, kind) then
        self:cancel()
    end
end

function Menu:_handle_input_change(axis, value)
    if not self.active or not self.visible then return end
    if math.abs(value or 0) > self.deadzone then
        self:_set_source({ type = "joystick" })
    end
end

function Menu:update(dt)
    if not self.active or not self.visible then return end

    local axis_value, source = read_axis(self.axis, self.stick)
    if source and source ~= self._last_source then
        self._last_source = source
        safe_call(self.on_input_mode, self, source)
    end

    local dir = 0
    if axis_value <= -self.deadzone then
        dir = -1
    elseif axis_value >= self.deadzone then
        dir = 1
    end

    if dir == 0 then
        self._held_dir = 0
        self._repeat_at = 0
    elseif self._held_dir ~= dir then
        self:move(dir)
        self:_begin_hold(dir)
    elseif now() >= self._repeat_at then
        self:move(dir)
        self._repeat_at = now() + self.repeat_rate
    end

    -- Held left/right repeats adjustments, like a held up/down repeats moves
    local cross_value = read_axis(self.axis == "y" and "x" or "y", self.stick)
    local cross = cross_value <= -self.deadzone and -1 or (cross_value >= self.deadzone and 1 or 0)
    if cross == 0 then
        self._held_adjust = 0
    elseif self._held_adjust ~= cross then
        if self:adjust(cross) then
            self._held_adjust = cross
            self._adjust_repeat_at = now() + self.repeat_delay
        end
    elseif now() >= self._adjust_repeat_at then
        self:adjust(cross)
        self._adjust_repeat_at = now() + self.repeat_rate
    end

    safe_call(self.on_render, self, dt)
end

function MenuNavig.create(args)
    return MenuNavig.new(args)
end

MenuNavig.Menu = Menu
MenuNavig._VERSION = "1.0.0"

return MenuNavig
