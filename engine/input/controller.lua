local controller = {}
controller.__index = controller

controller.deadzone = 0.3
controller.stick_names = { 'stick1', 'stick2' }
controller.trigger_names = { 'l2', 'r2' }

local gamepadguesser = require "engine/services/oss/gamepadguesser"

controller.gamepadguesser = gamepadguesser
controller.SPRITES = {}
controller.SHEET_PATH = {}
controller.sprite_assets_enabled = false

function controller.clear_sprite_assets()
    controller.SPRITES = {}
    controller.SHEET_PATH = {}
    controller.sprite_assets_enabled = false
    return controller
end

---configure optional controller-prompt artwork owned by an engine or project
---input itself works without these files, image helpers return nil until a
---project opts in with a sprite manifest and explicit sheet paths
function controller.configure_sprite_assets(options)
    if options == nil or options == false then
        controller.clear_sprite_assets()
        return true
    end
    assert(type(options) == "table", "controller sprite assets must be a table")

    local sprites = options.sprites
    if not sprites and options.module then
        local ok, loaded = pcall(require, options.module)
        if not ok then return nil, "could not load controller sprite manifest: " .. tostring(loaded) end
        sprites = loaded
    end
    if type(sprites) ~= "table" then
        return nil, "controller sprite assets need a sprites table or module"
    end

    local paths = options.paths or options.sheet_paths
    if type(paths) ~= "table" then
        return nil, "controller sprite assets need explicit sheet paths"
    end

    controller.SPRITES = sprites
    controller.SHEET_PATH = {}
    for category, path in pairs(paths) do
        if type(path) == "string" and path ~= "" then
            controller.SHEET_PATH[category] = path
        end
    end
    controller.sprite_assets_enabled = true
    return true
end

controller.configure_sprites = controller.configure_sprite_assets

---Compatibility signal for callers that used the removed shared artwork
function controller.use_legacy_sprite_assets()
    return nil, "the shared legacy prompt artwork was removed; configure project-owned sprite assets explicitly"
end
controller.controllers = {}
controller.active_sticks = {
    stick1 = { 0, 0 },
    stick2 = { 0, 0 },
    l2 = 0,
    r2 = 0
}

local function apply_deadzone(stick, dz)
    local mag = math.sqrt(stick[1] ^ 2 + stick[2] ^ 2)

    if mag <= dz then
        return { 0, 0 }, false
    end

    local scale = math.min(1, mag)

    return {
        (stick[1] / mag) * scale,
        (stick[2] / mag) * scale
    }, true
end

function controller.new(joy, name)
    local self = setmetatable({}, controller)
    self.name = name or joy:getName()
    self.joy = joy
    self.type = 'joystick'
    self.console = gamepadguesser and gamepadguesser.joystickToConsole(joy) or 'xbox'
    self.active_btns = {}
    self.sticks = { { 0, 0 }, { 0, 0 } }
    self.triggers = { 0, 0 }
    self.btn_cache = {}
    self:build_btn_cache()
    return self
end

-- button -> list of action names, several actions may share one button
function controller:build_btn_cache()
    local function add(key, name)
        local actions = self.btn_cache[key]
        if not actions then
            actions = {}
            self.btn_cache[key] = actions
        end
        actions[#actions + 1] = name
    end
    for _, mapping in ipairs(input_mgr.key_mappings) do
        local keys = mapping.bindings.joy
        if type(keys) == 'table' then
            for _, key in ipairs(keys) do add(key, mapping.name) end
        elseif keys then
            add(keys, mapping.name)
        end
    end
end

-- wipe + rebuild every controller's button->action cache (build only adds, so
-- stale entries must be cleared). called by the bindings module after a rebind
function controller.rebuild_btn_caches()
    for _, ctrl in pairs(controller.controllers) do
        if ctrl.build_btn_cache then
            ctrl.btn_cache = {}
            ctrl:build_btn_cache()
        end
    end
end

function controller:get_console_type()
    if self.console then return self.console end
    if controller.gamepadguesser and self.joy then
        self.console = controller.gamepadguesser.joystickToConsole(self.joy)
    end
    return self.console or 'xbox'
end

function controller:btn_press(btn)
    if self.active_btns[btn] then return end
    -- gamepad rebind capture (covers real buttons and l2/r2 trigger edges alike)
    if input_mgr.bindings and input_mgr.bindings.feed_capture('joy', btn) then return end
    self.active_btns[btn] = true
    local prompt = self:get_prompt()
    for _, h in ipairs(G.pipeline.buckets.input_start) do
        h.current_func(btn, prompt, self)
    end
    if input_mgr.state.typing then return end
    local actions = self.btn_cache[btn]
    if actions then
        for index = 1, #actions do
            input_mgr.execute_key_handler(actions[index], 'pressed', btn, self.joy, self)
        end
    end
end

function controller:btn_release(btn)
    if not self.active_btns[btn] then return end
    for _, h in ipairs(G.pipeline.buckets.input_end) do
        h.current_func(btn, self)
    end
    local actions = self.btn_cache[btn]
    if actions then
        for index = 1, #actions do
            input_mgr.execute_key_handler(actions[index], 'released', btn, self.joy, self)
        end
    end
    self.active_btns[btn] = nil
end

function controller:axis_move(axis, val)
    for _, h in ipairs(G.pipeline.buckets.input_change) do
        h.current_func(axis, val)
    end
    if axis <= 4 then
        local stick_idx = math.floor((axis - 1) / 2) + 1
        local axis_idx = (axis - 1) % 2 + 1
        self.sticks[stick_idx][axis_idx] = val
        self.sticks[stick_idx] = apply_deadzone(self.sticks[stick_idx], controller.deadzone)
        local stick_name = controller.stick_names[stick_idx]
        if stick_name then
            controller.active_sticks[stick_name] = { unpack(self.sticks[stick_idx]) }
        end
    elseif axis >= 5 then
        local trig_idx = axis - 4
        local trig_name = controller.trigger_names[trig_idx]
        self.triggers[trig_idx] = val
        if trig_name then
            controller.active_sticks[trig_name] = val
        end
        if val > 0.7 then
            self:btn_press(trig_name)
        elseif val < 0.3 then
            self:btn_release(trig_name)
        end
    end
end

function controller:get_prompt()
    for pname, pdata in pairs(input_mgr.prompt_keys) do
        local joy_keys = pdata.joystick or {}
        for _, key in ipairs(joy_keys) do
            if self.active_btns[key] then return pname end
        end
    end
    return nil
end

function controller:is_active(action)
    local b = input_mgr.bindings
    if b then
        local mode = b.mode_of(action)
        if mode == 'disabled' then return false end
        if mode == 'toggle' then return b.toggle_state[action] == true end
    end
    for _, mapping in ipairs(input_mgr.key_mappings) do
        if mapping.name == action then
            for inp_type, keys in pairs(mapping.bindings) do
                if inp_type == 'joy' then
                    local keylist = type(keys) == 'table' and keys or { keys }
                    for _, key in ipairs(keylist) do
                        if self.active_btns[key] then return true end
                    end
                end
            end
        end
    end
    return false
end

local function controller_rumble_scale()
    return input_mgr.vibration.get_master_strength()
end

function controller:supports_vibration()
    if not self.joy then return false end
    if not self.joy:isConnected() then return false end
    return self.joy:isVibrationSupported()
end

function controller:set_vibration(l, r, duration)
    if not self.joy then return false end
    if not self:supports_vibration() then return false end

    local scale = controller_rumble_scale()
    local left = math.max(0, math.min(1, tonumber(l) or 0)) * scale
    local right = math.max(0, math.min(1, tonumber(r) or 0)) * scale

    local success
    if duration ~= nil then
        success = self.joy:setVibration(left, right, duration)
    else
        success = self.joy:setVibration(left, right)
    end

    return success ~= false
end

function controller:destroy()
    self.active_btns = {}
    if self.joy then
        self:set_vibration(0, 0)
        self.joy:release()
    end
end

-- load keyboard mapping and create keyboard1 controller at module load
do
    local ok, data = pcall(love.filesystem.read, require('engine/root') .. '/services/oss/gamepadguesser/db/gamecontrollerdb.txt')
    if ok and data then pcall(love.joystick.loadGamepadMappings, data) end
    controller.controllers['keyboard1'] = {
        name = 'keyboard1',
        type = 'keyboard',
        active_btns = {},
        btn_press = function(self, key)
            if self.active_btns[key] then return end
            -- mouse pseudo-keys ('mouse2'...) reach the capture here, real keys are
            -- already captured earlier in love.keypressed
            if key:sub(1, 5) == 'mouse'
                and input_mgr.bindings and input_mgr.bindings.feed_capture('keyboard', key) then
                return
            end
            self.active_btns[key] = true
            local prompt = controller.get_keyboard_prompt(self)
            for _, h in ipairs(G.pipeline.buckets.input_start) do
                h.current_func(key, prompt, self)
            end
            if input_mgr.state.typing then return end
            controller.exec_keyboard_action(key, 'pressed')
        end,
        btn_release = function(self, key)
            if not self.active_btns[key] then return end
            for _, h in ipairs(G.pipeline.buckets.input_end) do
                h.current_func(key, self)
            end
            controller.exec_keyboard_action(key, 'released')
            self.active_btns[key] = nil
        end
    }
    input_mgr.sources['keyboard1'] = controller.controllers['keyboard1']
end

-- every action bound to the key is dispatched, matching gamepad buttons
function controller.exec_keyboard_action(key, action)
    local keyboard = controller.controllers['keyboard1']
    for _, mapping in ipairs(input_mgr.key_mappings) do
        local kbd_keys = mapping.bindings.keyboard
        local matched = kbd_keys == key
        if not matched and type(kbd_keys) == 'table' then
            for _, mapped in ipairs(kbd_keys) do
                if mapped == key then
                    matched = true
                    break
                end
            end
        end
        if matched then
            input_mgr.execute_key_handler(mapping.name, action, key, nil, keyboard)
        end
    end
end

function controller.get_keyboard_prompt(kbd)
    for pname, pdata in pairs(input_mgr.prompt_keys) do
        local kbd_keys = pdata.keyboard or {}
        for _, key in ipairs(kbd_keys) do
            if kbd.active_btns[key] then return pname end
        end
    end
    return nil
end

function controller.handle_joy_added(joy)
    if input_mgr.mobile.is_mobile then return end
    local name = joy:getName()
    local idx = 1
    while controller.controllers[name .. idx] do idx = idx + 1 end
    local full = name .. idx
    local ctrl = controller.new(joy, full)
    ctrl.console = controller.gamepadguesser and controller.gamepadguesser.joystickToConsole(joy) or ctrl.console
    controller.controllers[full] = ctrl
    input_mgr.sources[full] = ctrl
    input_mgr.set_input_source('controller')
end

function controller.handle_joy_removed(joy)
    for name, ctrl in pairs(controller.controllers) do
        if ctrl.joy == joy then
            ctrl:destroy()
            controller.controllers[name] = nil
            input_mgr.sources[name] = nil
            if not controller.has_controller() then
                input_mgr.set_input_source('keyboard')
            end
            break
        end
    end

    for name, ctrl in pairs(controller.controllers) do
        if ctrl.joy == joy then
            return
        end
    end
end

controller.handle_joystick_added = controller.handle_joy_added
controller.handle_joystick_removed = controller.handle_joy_removed

function controller.create_input_image(category, name, args)
    if not Image then return nil end
    local cat = controller.SPRITES and controller.SPRITES[category]
    local entry = cat and cat[name]
    if not entry then return nil end
    local src = controller.SHEET_PATH[category]
    if not src then return nil end
    local opts = {}
    if args then for k, v in pairs(args) do opts[k] = v end end
    opts.source = src
    opts.imageRectOffset = entry.pos
    opts.imageRectSize = entry.size
    if not opts.size then opts.size = { offset = entry.size:clone() } end
    return Image(opts)
end

local prompt_sheets, prompt_quads = {}, {}

---Image, quad and pixel size of a prompt sprite such as "keyboard_space",
---"mouse_left" or "xbox_button_a", for drawing prompts with love.graphics
---returns nil when no sprite assets are configured or the name is unknown
function controller.prompt_sprite(name)
    local category = type(name) == 'string' and name:match('^(%a+)_')
    if category == 'mouse' then category = 'keyboard' end
    local sprites = controller.SPRITES and controller.SPRITES[category]
    local entry = sprites and sprites[name]
    local path = controller.SHEET_PATH and controller.SHEET_PATH[category]
    if not entry or not path then return nil end
    local sheet = prompt_sheets[category]
    if sheet == nil then
        local resolved = Image and Image._resolve_path and Image._resolve_path(path) or path
        local ok, image = pcall(love.graphics.newImage, resolved, { mipmaps = true })
        sheet = ok and image or false
        if sheet then sheet:setFilter('linear', 'linear') end
        prompt_sheets[category] = sheet
    end
    if not sheet then return nil end
    local quad = prompt_quads[name]
    if not quad then
        quad = love.graphics.newQuad(entry.pos.x, entry.pos.y, entry.size.x, entry.size.y,
            sheet:getWidth(), sheet:getHeight())
        prompt_quads[name] = quad
    end
    return sheet, quad, entry.size.x, entry.size.y
end

function controller.create_controller_image(sprite, ctrlOrType, args)
    if not Image then return nil end
    local category
    if type(ctrlOrType) == 'string' then
        category = ctrlOrType
    elseif type(ctrlOrType) == 'table' and ctrlOrType.get_console_type then
        category = ctrlOrType:get_console_type()
    elseif type(ctrlOrType) == 'userdata' and ctrlOrType.typeOf and ctrlOrType:typeOf('Joystick') then
        category = gamepadguesser and gamepadguesser.joystickToConsole(ctrlOrType) or 'xbox'
    else
        category = 'xbox'
    end

    local key = sprite
    local pref = category .. '_'
    local sprites = controller.SPRITES or {}
    if not sprites[category] then category = 'xbox' end
    if not sprites[category] then return nil end
    if not sprites[category][key] then
        -- try prefixing with the category if not found
        key = pref .. tostring(sprite)
    end
    if not sprites[category][key] then return nil end
    return controller.create_input_image(category, key, args)
end

function controller.handle_key_press(key)
    local kbd = controller.controllers['keyboard1']
    if kbd and kbd.btn_press then kbd:btn_press(key) end
end

function controller.handle_key_release(key)
    local kbd = controller.controllers['keyboard1']
    if kbd and kbd.btn_release then kbd:btn_release(key) end
end

function controller.handle_gamepad_pressed(joy, btn)
    for _, ctrl in pairs(controller.controllers) do
        if ctrl.joy == joy then
            ctrl:btn_press(btn)
            break
        end
    end
end

function controller.handle_gamepad_released(joy, btn)
    for _, ctrl in pairs(controller.controllers) do
        if ctrl.joy == joy then
            ctrl:btn_release(btn)
            break
        end
    end
end

function controller.handle_gamepad_axis(joy, axis, val)
    for _, ctrl in pairs(controller.controllers) do
        if ctrl.joy == joy then
            ctrl:axis_move(axis, val)
            break
        end
    end
end

function controller.has_controller()
    for _, ctrl in pairs(controller.controllers) do
        if ctrl.type == 'joystick' then return true end
    end
    return false
end

function controller.is_gamepad_active(btn)
    for _, ctrl in pairs(controller.controllers) do
        if ctrl.type == 'joystick' and ctrl.active_btns then
            if ctrl.active_btns[btn] then return true end
        end
    end
    return false
end

function controller.is_action_active(action)
    local b = input_mgr.bindings
    if b then
        local mode = b.mode_of(action)
        if mode == 'disabled' then return false end
        if mode == 'toggle' then return b.toggle_state[action] == true end
    end
    local kbd = controller.controllers['keyboard1']
    for _, mapping in ipairs(input_mgr.key_mappings) do
        if mapping.name == action then
            local kbd_keys = mapping.bindings.keyboard
            if kbd_keys then
                local keylist = type(kbd_keys) == 'table' and kbd_keys or { kbd_keys }
                for _, key in ipairs(keylist) do
                    -- keyboard1.active_btns also holds mouse pseudo-keys ('mouse1'...),
                    -- which never land in state.active_keys
                    if input_mgr.state.active_keys[key]
                        or (kbd and kbd.active_btns[key]) then
                        return true
                    end
                end
            end
            local joy_keys = mapping.bindings.joy
            if joy_keys then
                local keylist = type(joy_keys) == 'table' and joy_keys or { joy_keys }
                for _, key in ipairs(keylist) do
                    if controller.is_gamepad_active(key) then return true end
                end
            end
            break
        end
    end
    return false
end

-- is any keyboard key of this mapping physically held? (allocation-free)
local function mapping_keyboard_down(mapping, active_btns)
    local keys = mapping.bindings.keyboard
    if not keys then return false end
    if type(keys) == 'table' then
        for i = 1, #keys do
            if active_btns[keys[i]] then return true end
        end
        return false
    end
    return active_btns[keys] ~= nil
end

-- movement action state, respecting rebinds and per-action modes
local function move_action_down(name, active_btns)
    local b = input_mgr.bindings
    local mapping = b and b.by_name[name]
    if not mapping then return false end
    local mode = mapping.mode
    if mode == 'disabled' then return false end
    if mode == 'toggle' then return b.toggle_state[name] == true end
    return mapping_keyboard_down(mapping, active_btns)
end

-- normalized movement direction from the up/down/left/right actions + left stick,
-- returned as two scalars (no table allocation -- safe to call every frame)
-- +x = right, +y = backward. follows rebinds via input_mgr.bindings
function controller.get_active_direction_xy()
    local x, y = 0, 0
    local kbd = controller.controllers['keyboard1']
    if kbd then
        local a = kbd.active_btns
        if input_mgr.bindings then
            if move_action_down('up', a) then y = y - 1 end
            if move_action_down('down', a) then y = y + 1 end
            if move_action_down('left', a) then x = x - 1 end
            if move_action_down('right', a) then x = x + 1 end
        else
            if a['w'] or a['up'] then y = y - 1 end
            if a['s'] or a['down'] then y = y + 1 end
            if a['a'] or a['left'] then x = x - 1 end
            if a['d'] or a['right'] then x = x + 1 end
        end
    end
    local s = controller.active_sticks.stick1
    if s then
        x = x + (s[1] or 0)
        y = y + (s[2] or 0)
    end
    local mag = math.sqrt(x * x + y * y)
    if mag > 1 then
        x = x / mag
        y = y / mag
    end
    return x, y
end

function controller.get_active_direction()
    local x, y = controller.get_active_direction_xy()
    return { x, y }
end

return controller
