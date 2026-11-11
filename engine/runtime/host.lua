---@class Program: Object
---@field pipeline Pipeline
---@field debug Debug
local Program = Object:extend()
-- `Program` and `G` are long-standing public compatibility globals.  keep a
-- single runtime instance, but make the selected project its explicit owner
_G.Program = Program
require('engine/runtime/pipeline') ---@type Pipeline|fun(...): Pipeline
require('engine/runtime/debug')
require('engine/runtime/settings') ---@type Debug|fun(...): Debug

local function sorted_keys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function custom_storage_key(name)
    return 'custom.' .. name
end

local function is_scalar_setting_value(value)
    local kind = type(value)
    return kind == 'boolean' or kind == 'number' or kind == 'string'
end

local function is_finite_number(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function validate_custom_declaration(name, declaration)
    assert(type(declaration) == 'table' and declaration.default ~= nil,
        ("project.custom_settings.%s needs a table with default"):format(name))
    assert(is_scalar_setting_value(declaration.default),
        ("project.custom_settings.%s.default must be a boolean, number, or string"):format(name))
    assert(declaration.title == nil or type(declaration.title) == 'string',
        ("project.custom_settings.%s.title must be a string"):format(name))
    assert(declaration.changed == nil or type(declaration.changed) == 'function',
        ("project.custom_settings.%s.changed must be a function"):format(name))
    assert(declaration.decimal == nil or type(declaration.decimal) == 'boolean',
        ("project.custom_settings.%s.decimal must be a boolean"):format(name))
    assert(declaration.allow_arbitrary == nil or type(declaration.allow_arbitrary) == 'boolean',
        ("project.custom_settings.%s.allow_arbitrary must be a boolean"):format(name))

    if declaration.min ~= nil or declaration.max ~= nil then
        assert(type(declaration.default) == 'number',
            ("project.custom_settings.%s min/max require a numeric default"):format(name))
        assert(declaration.min == nil or is_finite_number(declaration.min),
            ("project.custom_settings.%s.min must be a finite number"):format(name))
        assert(declaration.max == nil or is_finite_number(declaration.max),
            ("project.custom_settings.%s.max must be a finite number"):format(name))
        assert(declaration.min == nil or declaration.max == nil or declaration.min <= declaration.max,
            ("project.custom_settings.%s.min must not exceed max"):format(name))
    end

    if declaration.choices ~= nil then
        assert(type(declaration.choices) == 'table',
            ("project.custom_settings.%s.choices must be an array"):format(name))
        local count = 0
        for index, value in pairs(declaration.choices) do
            assert(type(index) == 'number' and index >= 1 and index % 1 == 0,
                ("project.custom_settings.%s.choices must be an array"):format(name))
            assert(type(value) == type(declaration.default),
                ("project.custom_settings.%s.choices must match the default type"):format(name))
            count = count + 1
        end
        assert(count == #declaration.choices,
            ("project.custom_settings.%s.choices must not contain gaps"):format(name))
    end
end

local run_custom_changed

function Program:init(project)
    assert(type(project) == "table", "wave-engine requires a project configuration table")
    _G.G = self

    self:globals(project)
end

function Program:init_ui_editor()
    require('engine/ui/editor')
end

function Program:globals(project)
    project = project or {}
    local window = project.window or {}
    local assets = project.assets or {}
    local storage = project.storage or {}

    self.project_config           = project
    self.VERSION                  = '0.1.0'
    self.project                  = assert(project.id or project.name,
        "project configuration needs an `id` or `name`")
    self.title                    = project.title or self.project
    self.identity                 = project.identity or self.project
    self.window                   = window
    self.assets                   = assets
    self.asset_root               = assets.root
    self.audio_root               = assets.audio
    self.icon_path                = assets.icon
    self.use_ui_editor            = project.use_ui_editor == true
    self.preferred_orientation    = project.preferred_orientation or 'landscape'

    self.background_color         = project.background_color or { 1, 1, 1 }
    self.WIRELESS                 = project.wireless == true

    self.devbuild                 = project.devbuild == true
    self.splash                   = project.splash == true or type(project.splash) == "table"
    self.system                   = love.system.getOS()
    self.CFG                      = CFG
    self.setting_listeners        = {}

    -- project defaults seed the existing CFG system before saved preferences
    -- are read. they are not hard-coded project-name branches in the engine
    assert(project.settings == nil or type(project.settings) == 'table',
        'project.settings must be a table')
    local setting_defaults = {}
    for name, value in pairs(project.settings or {}) do setting_defaults[name] = value end
    if window.width and window.height and setting_defaults.resolution == nil then
        setting_defaults.resolution = ("%dx%d"):format(window.width, window.height)
    end
    if window.vsync ~= nil and setting_defaults.vsync == nil then setting_defaults.vsync = window.vsync ~= 0 end
    for _, name in ipairs(sorted_keys(setting_defaults)) do
        local value = setting_defaults[name]
        local setting = CFG:getSetting(name)
        assert(setting, ("project.settings.%s is not an engine setting; use project.custom_settings instead")
            :format(tostring(name)))
        local normalized, err = CFG.validate_setting_value(setting, value)
        assert(normalized ~= nil, ("invalid default for project.settings.%s: %s")
            :format(tostring(name), tostring(err)))
        setting.default = normalized
    end

    self.custom_settings         = {}
    self.custom_setting_order    = {}
    self.custom_settings_ready   = false
    self:register_custom_settings(project.custom_settings)

    self.settings_path            = storage.settings or project.settings_path or 'settings.cfg'
    self.data_path                = storage.data or project.data_path or 'game_data.dat'
    self.profile_path             = storage.profile or project.profile_path or 'profile.dat'

    self.no_save_mode             = project.no_save_mode == true

    self.data                     = self.no_save_mode and {} or load_data(self.data_path, {})
    self.profile                  = self.no_save_mode and {} or load_data(self.profile_path, {})

    self.base_resolution          = vec2(window.width or 960, window.height or 600)
    self.ratio_resolution         = vec2(math.floor(self.base_resolution.y * (4 / 3) + 0.5), self.base_resolution.y)
    self.resolution               = self.base_resolution

    self.destretch_design         = vec2(800, 600)
    self.resScaleFactor           = 1
    self.letterbox                = { val = 0 }
    self.canvas                   = nil
    self:recreate_main_canvas()

    self.rateupdate       = 0
    self.min_dt           = 0
    self.delta            = 1
    self.paused           = false
    self.resize_listeners = {}

    self.pipeline         = Pipeline()
    self.debug            = Debug()
end

-- project/UI systems subscribe to content dimensions (virtual in 4:3 mode)
-- instead of replacing love.resize. the third argument is true when a window
-- mode change may have cleared Canvas contents (ordinary drag-resizes pass false)
function Program:add_resize_listener(fn)
    if type(fn) ~= "function" then return nil end
    self.resize_listeners[#self.resize_listeners + 1] = fn
    return fn
end

function Program:remove_resize_listener(fn)
    for i = #self.resize_listeners, 1, -1 do
        if self.resize_listeners[i] == fn then
            table.remove(self.resize_listeners, i)
        end
    end
end

function Program:notify_resized(width, height, graphics_reset)
    -- a listener may remove itself while running, so iterate over a snapshot
    local listeners = {}
    for i = 1, #self.resize_listeners do listeners[i] = self.resize_listeners[i] end
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], width, height, graphics_reset == true)
        if not ok then print("resize listener error: " .. tostring(err)) end
    end
end

function Program:get_ratio_resolution()
    return self.ratio_resolution or self.base_resolution
end

-- Content dimensions differ from window dimensions when using a virtual canvas
function Program:get_draw_dimensions()
    if self:getSetting('ratio4by3').value then
        local resolution = self:get_ratio_resolution()
        return resolution.x, resolution.y
    end
    return self.resolution.x, self.resolution.y
end

function Program:get_active_virtual_resolution()
    local ratio_setting = self:getSetting('ratio4by3')
    if ratio_setting and ratio_setting.value then
        return self:get_ratio_resolution()
    end
    return self.base_resolution
end

function Program:recreate_main_canvas()
    local target = self:get_active_virtual_resolution()
    local width = math.max(1, math.floor(((target and target.x) or self.base_resolution.x) + 0.5))
    local height = math.max(1, math.floor(((target and target.y) or self.base_resolution.y) + 0.5))
    self.canvas = require("engine/graphics/surface").new_canvas(width, height)
    if self.canvas and self.canvas.setFilter then
        self.canvas:setFilter('nearest', 'nearest')
    end
end

function Program:getSetting(name, fallback)
    return CFG:getSetting(name, fallback)
end

---Observe a live engine setting without replacing the engine's own callback
---by default the observer receives the current value immediately, which lets a
---project build its state first and then synchronize its own presentation or
---gameplay state exactly once. Final-frame accessibility settings are handled
---by the engine shader and do not require project listeners
---@param name string
---@param callback fun(value:any, previous:any|nil, program:Program)
---@param call_immediately boolean|nil
---@return function
function Program:add_setting_listener(name, callback, call_immediately)
    local setting = CFG:getSetting(name)
    assert(setting, ("unknown engine setting '%s'"):format(tostring(name)))
    assert(type(callback) == 'function', 'setting listener must be a function')
    local listeners = self.setting_listeners[name]
    if not listeners then
        listeners = {}
        self.setting_listeners[name] = listeners
    end
    listeners[#listeners + 1] = callback
    if call_immediately ~= false then
        local current = setting.value
        if current == nil then current = setting.default end
        callback(current, nil, self)
    end
    return callback
end

Program.onSettingChanged = Program.add_setting_listener
Program.observe_setting = Program.add_setting_listener

function Program:remove_setting_listener(name, callback)
    local listeners = self.setting_listeners and self.setting_listeners[name]
    if not listeners then return false end
    for index = #listeners, 1, -1 do
        if listeners[index] == callback then
            table.remove(listeners, index)
            return true
        end
    end
    return false
end

function Program:_notify_setting_listeners(name, value, previous)
    local listeners = self.setting_listeners and self.setting_listeners[name]
    if not listeners then return end
    -- a listener may unregister itself while running, preserve deterministic
    -- delivery to the listeners that were present for this setting change
    local snapshot = {}
    for index = 1, #listeners do snapshot[index] = listeners[index] end
    for index = 1, #snapshot do snapshot[index](value, previous, self) end
end

---register settings owned by the selected project rather than the engine
---Declarations are keyed by a safe identifier and use the same scalar schema
---as CFG settings: default, choices, min, max, decimal, and changed
function Program:register_custom_settings(declarations)
    if declarations == nil then return self.custom_settings end
    assert(type(declarations) == 'table', 'project.custom_settings must be a table')

    for _, name in ipairs(sorted_keys(declarations)) do
        local declaration = declarations[name]
        assert(type(name) == 'string' and name:match('^[%a_][%w_]*$'),
            'custom setting names must use letters, digits, and underscores')
        assert(not CFG:getSetting(name),
            ("project.custom_settings.%s collides with an engine setting"):format(name))
        assert(not self.custom_settings[name],
            ("custom setting '%s' is already registered"):format(name))
        validate_custom_declaration(name, declaration)

        local setting = {
            name = name,
            title = declaration.title or name,
            default = declaration.default,
            choices = declaration.choices,
            min = declaration.min,
            max = declaration.max,
            decimal = declaration.decimal == true,
            allow_arbitrary = declaration.allow_arbitrary == true,
            changed = declaration.changed,
        }
        local normalized, err = CFG.validate_setting_value(setting, setting.default)
        assert(normalized ~= nil, ("invalid default for custom setting '%s': %s")
            :format(name, tostring(err)))
        setting.default = normalized
        setting.value = normalized
        setting.set = function(first, second)
            local goal
            if second == nil then goal = first else goal = second end
            return self:setCustomSetting(name, goal)
        end
        self.custom_settings[name] = setting
        self.custom_setting_order[#self.custom_setting_order + 1] = name

        -- Startup declarations are applied together after project.start. a
        -- deliberate late registration is still safe and takes effect now
        if self.custom_settings_ready and not self._applying_custom_settings then
            local ok, callback_err = run_custom_changed(self, setting, nil)
            if not ok then
                self.custom_settings[name] = nil
                table.remove(self.custom_setting_order, #self.custom_setting_order)
                error(callback_err, 0)
            end
        end
    end

    return self.custom_settings
end

function Program:getCustomSetting(name, fallback)
    local setting = self.custom_settings and self.custom_settings[name]
    if setting and setting.value ~= nil then return setting.value end
    return fallback
end

Program.get_custom_setting = Program.getCustomSetting

run_custom_changed = function(program, setting, old_value)
    if type(setting.changed) ~= 'function' then return true end
    local ok, err = pcall(setting.changed, setting.value, old_value, program)
    if not ok then
        return nil, ("custom setting '%s' callback failed: %s"):format(setting.name, tostring(err))
    end
    return true
end

---apply callbacks after project.start has created its game state
function Program:apply_custom_settings()
    if self.custom_settings_ready then return true end
    self._applying_custom_settings = true
    self._custom_settings_applied = {}
    for _, name in ipairs(self.custom_setting_order) do
        local setting = self.custom_settings[name]
        self._custom_settings_applied[name] = true
        local ok, err = run_custom_changed(self, setting, nil)
        if not ok then
            self._applying_custom_settings = false
            error(err, 0)
        end
    end
    self._applying_custom_settings = false
    self.custom_settings_ready = true
    return true
end

function Program:setCustomSetting(name, value)
    local setting = self.custom_settings and self.custom_settings[name]
    if not setting then
        return nil, ("unknown custom setting '%s'"):format(tostring(name))
    end
    local normalized, err = CFG.validate_setting_value(setting, value)
    if normalized == nil then
        return nil, ("invalid value for custom setting '%s': %s"):format(name, tostring(err))
    end

    local old_value = setting.value
    if old_value == normalized then return normalized end
    setting.value = normalized
    local callback_is_live = self.custom_settings_ready
        or (self._applying_custom_settings and self._custom_settings_applied and self._custom_settings_applied[name])
    if callback_is_live then
        local ok, callback_err = run_custom_changed(self, setting, old_value)
        if not ok then
            setting.value = old_value
            return nil, callback_err
        end
    end
    if not self.no_save_mode and not self._applying_custom_settings then self:save_settings() end
    return normalized
end

Program.set_custom_setting = Program.setCustomSetting

function Program:setPause(bool)
    self.paused = bool
    timers.paused = self.paused
end

function Program:halted()
    return self.paused
end

function Program:get_window_flags(vsync, mode)
    -- the selected project owns static window capabilities, the user's
    -- vsync/fullscreen preference remains authoritative at runtime
    local vsync_value = vsync and 1 or 0
    local window = self.window or {}
    local fullscreen = mode == 'exclusive' or mode == 'borderless'
    local flags = {
        minwidth = window.minwidth,
        minheight = window.minheight,
        resizable = window.resizable ~= false,
        -- same default as conf.lua, so applying a saved mode keeps DPI scaling
        usedpiscale = window.usedpiscale ~= false,
        depth = window.depth or 24,
        stencil = window.stencil or 8,
        vsync = vsync_value,
        msaa = window.msaa or 0,
        highdpi = window.highdpi == true,
        -- LÖVE's `borderless` flag only removes decorations from a *windowed*
        -- window. a borderless fullscreen mode is `fullscreen = true` with
        -- the desktop fullscreen type
        fullscreen = fullscreen,
        fullscreentype = (mode == 'exclusive') and 'exclusive' or 'desktop',
        borderless = not fullscreen and window.borderless == true,
    }
    if window.maximized == true then
        flags.maximized = true
    end
    return flags
end

function Program:load()
    local loaded_settings = {}
    if not self.no_save_mode then
        local s, _ = love.filesystem.read(self.settings_path)
        if s and #s > 0 then
            for line in s:gmatch("[^\r\n]+") do
                local name, val = line:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
                if name and val then loaded_settings[name] = val end
            end
        end
    end

    for _, category in pairs(self.CFG.settings) do
        for _, setting in ipairs(category) do
            if not setting.changed then setting.changed = function() end end

            local saved = loaded_settings[setting.name]
            if saved ~= nil and not self.no_save_mode then
                local value = CFG.coerce_setting_value(setting, saved)
                -- `false` is a valid persisted value. do not use Lua's
                -- `value ~= nil and value or default` pseudo-ternary here:
                -- it accidentally replaced a saved false with the default
                if value ~= nil then
                    setting.value = value
                else
                    setting.value = setting.default
                end
            else
                setting.value = setting.default
            end

            local setting_ref = setting
            setting.set = function(first, second)
                local goal
                if second == nil then goal = first else goal = second end
                local value, err = CFG.validate_setting_value(setting_ref, goal)
                if value == nil then
                    return nil, ("invalid value for setting '%s': %s"):format(setting_ref.name, tostring(err))
                end
                local old_value = setting_ref.value
                if old_value == value then return value end
                setting_ref.value = value
                setting_ref.changed(value, old_value)
                self:_notify_setting_listeners(setting_ref.name, value, old_value)
                if not self.no_save_mode then self:save_settings() end
                return value
            end
        end
    end

    for _, name in ipairs(self.custom_setting_order) do
        local setting = self.custom_settings[name]
        local saved = loaded_settings[custom_storage_key(name)]
        if saved ~= nil and not self.no_save_mode then
            local value = CFG.coerce_setting_value(setting, saved)
            -- Custom booleans share the same persistence contract as engine
            -- settings, including a deliberate saved false
            if value ~= nil then
                setting.value = value
            else
                setting.value = setting.default
            end
        else
            setting.value = setting.default
        end
    end

    --[[ consoles have a fixed display, window mode/resolution management is
    a desktop-only concern (see engine/platform.lua) ]]
    if platform.has_window_modes then
        local initial_mode = self:getSetting('fullscreen').value or 'windowed'
        local initial_vsync = self:getSetting('vsync').value
        local initial_resolution = self:getSetting('resolution').value or '960x600'

        local initial_w = self.window.width or self.base_resolution.x or 960
        local initial_h = self.window.height or self.base_resolution.y or 600

        if initial_resolution == 'native' then
            initial_w, initial_h = love.window.getDesktopDimensions()
        else
            local res = {}
            for num in initial_resolution:gmatch("%d+") do
                table.insert(res, tonumber(num))
            end
            if #res == 2 then
                initial_w, initial_h = res[1], res[2]
            end
        end

        if initial_mode == 'borderless' then
            initial_w, initial_h = love.window.getDesktopDimensions()
        end

        love.window.setMode(initial_w, initial_h, self:get_window_flags(initial_vsync, initial_mode))
    end

    self.pipeline:register_all()

    for cat_name, category in pairs(self.CFG.settings) do
        for _, setting in ipairs(category) do
            if setting.value ~= nil then
                if setting.name ~= 'fullscreen' and setting.name ~= 'vsync' and setting.name ~= 'resolution' then
                    setting.changed(setting.value)
                    self:_notify_setting_listeners(setting.name, setting.value, nil)
                end
            end
        end
    end
end

function Program:save_settings()
    if self.no_save_mode then return end
    local lines = {}
    for _, category in pairs(self.CFG.settings) do
        for _, setting in ipairs(category) do
            if setting.value ~= nil then
                local v = setting.value
                local vs
                if type(v) == 'boolean' then
                    vs = v and 'true' or 'false'
                else
                    vs = tostring(v)
                end
                lines[#lines + 1] = string.format('%s=%s', setting.name, vs)
            end
        end
    end
    for _, name in ipairs(self.custom_setting_order or {}) do
        local setting = self.custom_settings[name]
        if setting and setting.value ~= nil then
            local value = setting.value
            local serialized = type(value) == 'boolean' and (value and 'true' or 'false') or tostring(value)
            lines[#lines + 1] = string.format('%s=%s', custom_storage_key(name), serialized)
        end
    end
    love.filesystem.write(self.settings_path, table.concat(lines, '\n'))
end

function Program:save_data()
    if self.no_save_mode then return end
    local serializedTable = serialize_table(self.data)
    local base64Data = base64.encode(serializedTable)
    love.filesystem.write(self.data_path, base64Data)
end

function Program:save_profile()
    if self.no_save_mode then return end
    local has_any = false
    for _ in pairs(self.profile) do
        has_any = true; break
    end
    if not has_any then
        if love.filesystem.getInfo(self.profile_path) then
            love.filesystem.remove(self.profile_path)
        end
        return
    end
    local serializedTable = serialize_table(self.profile)
    local base64Data = base64.encode(serializedTable)
    love.filesystem.write(self.profile_path, base64Data)
end

function Program:save_all()
    if self.no_save_mode then return end
    self:save_settings()
    self:save_data()
    self:save_profile()
end

function Program:copy_data_to_clipboard()
    local serializedTable = serialize_table(self.data)
    local base64Data = base64.encode(serializedTable)
    love.system.setClipboardText(base64Data)
    return base64Data
end

function Program:paste_data_from_clipboard()
    local clipboardText = love.system.getClipboardText()
    if not clipboardText or clipboardText == "" then
        return false, "Clipboard is empty"
    end

    local success, result = pcall(function()
        local decoded = base64.decode(clipboardText)
        local data = deserialize_table(decoded)
        return data
    end)

    if success then
        self.data = result
        if not self.no_save_mode then
            self:save_data()
        end
        return true, "Data pasted successfully"
    else
        return false, "Invalid data format"
    end
end

function Program:copy_profile_to_clipboard()
    local serializedTable = serialize_table(self.profile)
    local base64Data = base64.encode(serializedTable)
    love.system.setClipboardText(base64Data)
    return base64Data
end

function Program:paste_profile_from_clipboard()
    local clipboardText = love.system.getClipboardText()
    if not clipboardText or clipboardText == "" then
        return false, "Clipboard is empty"
    end

    local success, result = pcall(function()
        local decoded = base64.decode(clipboardText)
        local profile = deserialize_table(decoded)
        return profile
    end)

    if success then
        self.profile = result
        if not self.no_save_mode then
            self:save_profile()
        end
        return true, "Profile pasted successfully"
    else
        return false, "Invalid profile format"
    end
end

return Program
