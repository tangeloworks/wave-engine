CFG = {}

CFG._suppress_window_apply = false

local function get_resolution_choices()
    -- consoles run a fixed display, expose only what the hardware offers
    if platform and not platform.has_window_modes then
        if platform.is_switch then
            return { '1280x720', '1920x1080' }
        end
        local cw, ch = love.graphics.getDimensions()
        return { string.format('%dx%d', cw or 800, ch or 600) }
    end

    local seen, choices = {}, {}

    local function add(sz)
        if sz and not seen[sz] then
            seen[sz] = true
            table.insert(choices, sz)
        end
    end

    local function within_desktop(sz)
        local w, h = sz:match("^(%d+)x(%d+)$")
        w, h = tonumber(w), tonumber(h)
        if not w or not h then return false end
        local dw, dh = love.window.getDesktopDimensions()
        if not dw or not dh then return true end
        return (w <= dw and h <= dh)
    end

    local is43 = CFG:getSetting('ratio4by3').value

    local highlight_sets = is43
        and { '1024x768', '1280x960', '1600x1200', '1920x1440' }
        or { '960x600', '1280x720', '1600x900', '1920x1080', '2560x1440', '3840x2160' }

    for _, sz in ipairs(highlight_sets) do
        if within_desktop(sz) then add(sz) end
    end

    local cw, ch = love.graphics.getDimensions()
    if cw and ch then add(string.format('%dx%d', cw, ch)) end

    add('native')

    return choices
end

local function get_refresh_rate_choices()
    if platform and not platform.has_window_modes then
        return { 30, 60, -1 }
    end

    local choices = {}
    local seen = {}
    local modes = love.window.getFullscreenModes()
    for _, m in ipairs(modes) do
        if m.refresh and not seen[m.refresh] then
            seen[m.refresh] = true
            table.insert(choices, m.refresh)
        end
    end
    table.sort(choices)
    local commons = { 30, 60, 120 }
    for _, r in ipairs(commons) do
        if not seen[r] then table.insert(choices, r) end
    end
    table.insert(choices, -1)
    return choices
end

CFG.settings = {
    ['graphics'] = {
        { default = true,       name = 'fps',                                        title = 'FPS Counter' },
        { default = -1,         choices = get_refresh_rate_choices(),                name = 'rate',              title = 'FPS Limit', allow_arbitrary = true, min = -1, max = 1000 },
        { default = false,      name = 'ratio4by3',                                  title = '4:3 Aspect Ratio' },
        { default = false,      name = 'stretch',                                    title = 'Stretch 4:3 Content' },
        { default = 'windowed', choices = { 'windowed', 'borderless', 'exclusive' }, name = 'fullscreen',        title = 'Display Mode' }, -- borderless means desktop fullscreen
        { default = false,      name = 'vsync',                                      title = 'VSync' },
        { default = '960x600',  choices = get_resolution_choices,                    name = 'resolution',        title = 'Resolution', allow_arbitrary = true },
        { default = false,      name = 'perfstats',                                  title = 'Performance Stats' },
    },
    ['accessibility'] = {
        { default = 'none', choices = { 'none', 'protanopia', 'deuteranopia', 'tritanopia' }, name = 'colorblind',     title = 'Color-vision Assist' },
        { default = false,  name = 'grayscale',                                               title = 'Grayscale' },
        { default = false,  name = 'high_contrast',                                           title = 'High Contrast' },
        { default = 1.0,    min = 0.5,                                                        max = 2.5,               decimal = true,            name = 'gamma',      title = 'Gamma' },
        { default = 0.0,    min = -0.5,                                                       max = 0.5,               decimal = true,            name = 'brightness', title = 'Brightness' },
        { default = false,  name = 'reduced_motion',                                          title = 'Reduced Motion' },
    },
    ['sound'] = {
        { default = 5,     min = 0,             max = 10,            decimal = true, name = 'maxvol',   title = 'Master Volume' },
        { default = 5,     min = 0,             max = 10,            decimal = true, name = 'musicvol', title = 'Music Volume' },
        { default = 5,     min = 0,             max = 10,            decimal = true, name = 'sfxvol',   title = 'SFX Volume' },
        { default = false, name = 'mono_audio', title = 'Mono Audio' },
    },
    ['input'] = {
        { default = 0.3, min = 0.1, max = 1,   decimal = true,  name = 'deadzone',          title = 'Controller Deadzone',      platforms = { 'console' } },
        { default = 65,  min = 0,   max = 100, name = 'rumble', title = 'Rumble Intensity', platforms = { 'console', 'mobile' } },
    },
}
CFG.settingshash = {}
for i, v in pairs(CFG.settings) do
    for index, child in pairs(v) do
        CFG.settingshash[child.name] = { i, index }
    end
end

function CFG:getSetting(name, fallback)
    local hash = CFG.settingshash[name]
    if hash then
        return CFG.settings[hash[1]][hash[2]]
    else
        return fallback
    end
end

---read the live value of an engine setting without treating false as absent
---this is shared by the presentation pipeline and final post-process so they
---cannot drift into disagreeing about whether an effect is active
function CFG.setting_value(name, fallback)
    local setting = CFG:getSetting(name)
    if setting and setting.value ~= nil then return setting.value end
    if setting and setting.default ~= nil then return setting.default end
    return fallback
end

---whether any setting requires the final presentation post-process
---every valid gamma/brightness delta is meaningful, tiny values must not be
---saved successfully yet silently become inert because of an activation
---dead-zone
function CFG.postfx_active()
    local cb = CFG.setting_value('colorblind', 'none')
    local grayscale = CFG.setting_value('grayscale', false) == true
    local high_contrast = CFG.setting_value('high_contrast', false) == true
    local gamma = tonumber(CFG.setting_value('gamma', 1.0)) or 1.0
    local brightness = tonumber(CFG.setting_value('brightness', 0.0)) or 0.0
    return cb ~= 'none' or grayscale or high_contrast or gamma ~= 1.0 or brightness ~= 0.0
end

local function finite_number(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function allowed_choice(setting, value)
    if setting.allow_arbitrary or type(setting.choices) ~= 'table' then
        return true
    end
    for _, choice in ipairs(setting.choices) do
        if choice == value then return true end
    end
    return false
end

---validate a value without changing runtime state. both global and
---project-defined settings use this scalar schema
---@return any|nil, string|nil
function CFG.validate_setting_value(setting, value)
    assert(type(setting) == 'table' and setting.default ~= nil,
        'setting must declare a scalar default')

    local expected = type(setting.default)
    if type(value) ~= expected then
        return nil, ("expected %s, got %s"):format(expected, type(value))
    end
    if expected == 'number' and not finite_number(value) then
        return nil, 'must be a finite number'
    end
    if expected == 'string' and value:find('[\r\n]') then
        return nil, 'must not contain a newline'
    end
    if setting.min ~= nil and value < setting.min then
        return nil, ('must be at least %s'):format(tostring(setting.min))
    end
    if setting.max ~= nil and value > setting.max then
        return nil, ('must be at most %s'):format(tostring(setting.max))
    end
    if not allowed_choice(setting, value) then
        return nil, 'is not one of this setting\'s supported choices'
    end
    if setting.name == 'resolution' and value ~= 'native' then
        local width, height = value:match('^(%d+)x(%d+)$')
        width, height = tonumber(width), tonumber(height)
        if not width or not height then
            return nil, 'must be native or WIDTHxHEIGHT'
        end
        -- LÖVE cannot create a zero-sized drawable. keep accidental or corrupt
        -- settings from requesting pathological window dimensions as well
        if width < 1 or height < 1 or width > 16384 or height > 16384 then
            return nil, 'must be between 1x1 and 16384x16384'
        end
    end
    return value
end

---convert an on-disk settings.cfg string to a validated typed value
---@return any|nil, string|nil
function CFG.coerce_setting_value(setting, raw)
    local value = raw
    local expected = type(setting.default)
    if expected == 'boolean' then
        if type(raw) ~= 'string' then return nil, 'saved boolean must be text' end
        local lower = raw:lower()
        if lower == 'true' or lower == '1' or lower == 'yes' or lower == 'on' then
            value = true
        elseif lower == 'false' or lower == '0' or lower == 'no' or lower == 'off' then
            value = false
        else
            return nil, 'saved value is not a boolean'
        end
    elseif expected == 'number' then
        value = tonumber(raw)
        if value == nil then return nil, 'saved value is not a number' end
    elseif expected ~= 'string' then
        return nil, 'unsupported setting value type'
    end
    return CFG.validate_setting_value(setting, value)
end

CFG:getSetting('fps').changed = function(val)
    if val then
        G.pipeline:enable('draw', 'fpsdraw')
    else
        G.pipeline:disable('draw', 'fpsdraw')
    end
end

-- the pipeline binds this stage to the live setting even when a project
-- registers it after the boot-time callback has already run
CFG:getSetting('perfstats').changed = function(val)
    if val then
        G.pipeline:enable('draw', 'perfstats')
    else
        G.pipeline:disable('draw', 'perfstats')
    end
end

local function reset_elements()
    for _, root in ipairs(AllElements) do
        if root then
            root.isdrawn = false
            root._needs_update = true
            root._canvas_dirty = true

            if root._canvas then
                root._canvas = nil
            end

            root:mark_dirty()
            root:refresh_layout_recursive()
            root:invalidateTree()
        end
    end
end

-- a draw frame contains matched render-pass pairs: ratioclear/ratiofin and
-- postfx_start/postfx_end. Changing their membership halfway through the pair
-- can leave a Canvas or graphics stack unbalanced. the setting value changes
-- immediately, but its structural presentation work is applied at the next
-- update before a new frame begins
local pending_presentation = {
    ratio_pending = false,
    stretch_pending = false,
    postfx_pending = false,
}

local function drawing_frame_active()
    return G and G._drawing_frame == true
end

local function apply_ratio4by3(val)
    if val then
        G.pipeline:enable('draw', 'ratioclear')
        G.pipeline:enable('draw', 'ratiofin')
        G.resolution = G:get_ratio_resolution()
    else
        G.pipeline:disable('draw', 'ratioclear')
        G.pipeline:disable('draw', 'ratiofin')
        local window_w, window_h = love.graphics.getDimensions()
        G.resolution = vec2(window_w, window_h)
    end
    G:recreate_main_canvas()

    reset_elements()

    input_mgr.mouse.update_display_offsets()
    G:notify_resized(G.resolution.x, G.resolution.y, false)
end

local function apply_stretch()
    reset_elements()
    input_mgr.mouse.update_display_offsets()
    G:notify_resized(G.resolution.x, G.resolution.y, false)
end

local pending_window_changes = {}
local window_change_timer = nil

local function apply_window_changes(force)
    if platform and not platform.has_window_modes then
        pending_window_changes = {}
        return
    end
    if next(pending_window_changes) or force then
        local w, h = love.graphics.getDimensions()
        local display_mode = pending_window_changes.fullscreen
        local vsync = pending_window_changes.vsync
        local resolution = pending_window_changes.resolution

        if display_mode == nil and CFG:getSetting('fullscreen') then
            display_mode = CFG:getSetting('fullscreen').value
        end
        display_mode = display_mode or 'windowed'

        if vsync == nil then
            vsync = CFG:getSetting('vsync').value
        end

        if resolution then
            if resolution == 'native' then
                w, h = love.window.getDesktopDimensions()
            else
                local res = {}
                for num in resolution:gmatch("%d+") do
                    table.insert(res, tonumber(num))
                end
                if #res == 2 then
                    w, h = res[1], res[2]
                end
            end
        elseif display_mode == 'windowed' then
            local res_setting = CFG:getSetting('resolution')
            if res_setting and res_setting.value and res_setting.value ~= 'native' then
                local res = {}
                for num in res_setting.value:gmatch("%d+") do
                    table.insert(res, tonumber(num))
                end
                if #res == 2 then
                    w, h = res[1], res[2]
                end
            end
        end

        if display_mode == 'borderless' then
            w, h = love.window.getDesktopDimensions()
        end

        -- updateMode preserves unspecified window state and avoids the full
        -- setMode reset. love.resize's refresh pass owns all Canvas/layout
        -- invalidation so the graphics context is handled exactly once
        local ok, success, err = pcall(love.window.updateMode, w, h,
            G:get_window_flags(vsync, display_mode))
        pending_window_changes = {}
        if not ok or success == false then
            print(("[window] could not set %s at %dx%d: %s")
                :format(display_mode, w, h, tostring(ok and err or success)))
            return false
        end

        love.resize(nil, nil, true)
        return true
    end
end

CFG.apply_window_changes = apply_window_changes

local function trigger_window_changes()
    if next(pending_window_changes) then
        apply_window_changes()
    end
end

CFG:getSetting('fullscreen').changed = function(val)
    if CFG._suppress_window_apply then return end
    pending_window_changes.fullscreen = val
    if window_change_timer then
        window_change_timer:stop()
    end
    window_change_timer = timers.after(0.1, trigger_window_changes)
end

CFG:getSetting('vsync').changed = function(val)
    if CFG._suppress_window_apply then return end
    if platform and not platform.has_window_modes then return end
    -- setVSync flips the swap interval in place. Routing this through updateMode
    -- recreated window state, wiped every Canvas (pause backdrop, cached element
    -- canvases went blank) and, with the old rate override, never actually changed
    -- the swap interval at all
    if love.window.setVSync then
        love.window.setVSync(val and 1 or 0)
    else
        pending_window_changes.vsync = val
        if window_change_timer then
            window_change_timer:stop()
        end
        window_change_timer = timers.after(0.1, trigger_window_changes)
    end
end

CFG:getSetting('resolution').changed = function(val)
    if CFG._suppress_window_apply then return end
    pending_window_changes.resolution = val
    if window_change_timer then
        window_change_timer:stop()
    end
    window_change_timer = timers.after(0.1, trigger_window_changes)
end

CFG:getSetting('rate').changed = function(val)
    if G then
        -- FPS Limit: <=0 means uncapped, the run loop paces to G.min_dt
        local cap = tonumber(val) or 0
        G.min_dt = cap > 0 and (1 / cap) or 0
        G._frame_sleep_margin = nil
    end
end

CFG:getSetting('maxvol').changed = function(val)
    audio:set_max_volume(val / 10)
end

CFG:getSetting('musicvol').changed = function(val)
    audio:set_volume('music', val / 10)
end

CFG:getSetting('sfxvol').changed = function(val)
    audio:set_volume('sfx', val / 10)
end

do
    local s = CFG:getSetting('mono_audio')
    s.changed = function(val)
        audio:set_force_mono(val)
    end
end

do
    local s = CFG:getSetting('rumble')
    s.changed = function(val)
        input_mgr.vibration.set_master_strength(val)
    end
end

do
    local s = CFG:getSetting('deadzone')
    s.changed = function(val)
        -- the controller reads this value for every analog-axis update. keep
        -- the live input threshold in sync with the persisted setting
        if input_mgr and input_mgr.controller then
            input_mgr.controller.deadzone = val
        end
    end
end

local function update_postfx_pipeline()
    local enabled = CFG.postfx_active()
    if CFG:getSetting('ratio4by3') and CFG:getSetting('ratio4by3').value then
        -- handled inside ratiofin stage, no offscreen pass needed
        G.pipeline:disable('draw', 'postfx_start')
        G.pipeline:disable('draw', 'postfx_end')
    else
        if enabled then
            G.pipeline:enable('draw', 'postfx_start')
            G.pipeline:enable('draw', 'postfx_end')
        else
            G.pipeline:disable('draw', 'postfx_start')
            G.pipeline:disable('draw', 'postfx_end')
        end
    end
end

local function request_postfx_pipeline_update()
    if drawing_frame_active() then
        pending_presentation.postfx_pending = true
        return false
    end
    update_postfx_pipeline()
    return true
end

local function ratio4by3_changed(val)
    if drawing_frame_active() then
        pending_presentation.ratio_pending = true
        pending_presentation.ratio_value = val == true
        pending_presentation.postfx_pending = true
        return
    end
    apply_ratio4by3(val)
    update_postfx_pipeline()
end

local function stretch_changed()
    if drawing_frame_active() then
        pending_presentation.stretch_pending = true
        return
    end
    apply_stretch()
end

---commit graphics-structural setting changes after the prior draw completes
---called by the launcher before update stages, and public for custom loops
function CFG.flush_deferred_presentation()
    if drawing_frame_active() then return false end

    local ratio_pending = pending_presentation.ratio_pending
    local stretch_pending = pending_presentation.stretch_pending
    local postfx_pending = pending_presentation.postfx_pending
    local ratio_value = pending_presentation.ratio_value
    pending_presentation.ratio_pending = false
    pending_presentation.stretch_pending = false
    pending_presentation.postfx_pending = false
    pending_presentation.ratio_value = nil

    if ratio_pending then
        -- Ratio application already recalculates input/layout and notifies
        -- resize listeners, so a simultaneous stretch change needs no second
        -- invalidation pass
        apply_ratio4by3(ratio_value)
    elseif stretch_pending then
        apply_stretch()
    end
    if postfx_pending or ratio_pending then update_postfx_pipeline() end
    return ratio_pending or stretch_pending or postfx_pending
end

if CFG.settings.accessibility then
    for _, n in ipairs({ 'colorblind', 'grayscale', 'high_contrast', 'gamma', 'brightness' }) do
        local s = CFG:getSetting(n)
        if s then
            s.changed = function()
                request_postfx_pipeline_update()
            end
        end
    end
end

CFG:getSetting('ratio4by3').changed = ratio4by3_changed
CFG:getSetting('stretch').changed = stretch_changed

timers.after(0, request_postfx_pipeline_update)

function CFG.on_window_resized(w, h, refresh)
    if refresh then return end
    -- Entering fullscreen must not replace the windowed resolution preference
    -- with desktop dimensions, returning to windowed uses that preference
    if CFG:getSetting('fullscreen').value ~= 'windowed' then return end

    local s = CFG:getSetting('resolution')
    if not s then return end

    local dw, dh = love.window.getDesktopDimensions()
    local newval
    if (dw and dh) and (w == dw and h == dh) then
        newval = 'native'
    else
        newval = string.format('%dx%d', w, h)
    end

    if s.value ~= newval then
        CFG._suppress_window_apply = true
        s.set(newval)
        CFG._suppress_window_apply = false
    end
end
