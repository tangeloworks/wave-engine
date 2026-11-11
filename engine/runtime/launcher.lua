-- the launcher owns the LÖVE callbacks and starts each system in dependency order
-- projects add their own work through the pipeline

local Launcher = {}
local Surface = require("engine/graphics/surface")
local MIN_YIELDING_FRAME_SECONDS = 0.004

local ENGINE_ASSET_ROOT = require("engine/root") .. "/assets"
local ENGINE_IMAGE_ROOT = ENGINE_ASSET_ROOT .. "/img"
local ENGINE_FONT_ROOT = ENGINE_ASSET_ROOT .. "/fonts"
local ENGINE_ICON = ENGINE_IMAGE_ROOT .. "/iconimg.png"
local ENGINE_CONTROLLER_SPRITES = {
    module = "engine/assets/img/inputsprites/spitesheet",
    paths = {
        flairs = "inputsprites/flairs.png",
        keyboard = "inputsprites/keyboard.png",
        xbox = "inputsprites/xbox.png",
        playstation = "inputsprites/playstation.png",
    },
}

local INPUT_EVENTS = {
    "focus", "keypressed", "keyreleased", "mousepressed", "mousereleased",
    "mousemoved", "wheelmoved", "textinput", "touchpressed", "touchmoved",
    "touchreleased", "joystickadded", "joystickremoved", "joystickaxis",
    "gamepadaxis", "gamepadpressed", "gamepadreleased",
}

-- the startup splash owns interactive input while it covers the project. keep
-- device hot-plug notifications flowing, but do not let a focus callback,
-- dismissal press, pointer movement, held stick, or text input reach project
-- callbacks and re-enable gameplay input behind the cover
local SPLASH_BLOCKED_INPUT_EVENTS = {
    focus = true,
    keypressed = true,
    keyreleased = true,
    mousepressed = true,
    mousereleased = true,
    mousemoved = true,
    wheelmoved = true,
    textinput = true,
    touchpressed = true,
    touchmoved = true,
    touchreleased = true,
    joystickaxis = true,
    gamepadaxis = true,
    gamepadpressed = true,
    gamepadreleased = true,
}

local function assert_project_name(name)
    assert(type(name) == "string" and name:match("^[%w_-]+$"),
        "project name must contain only letters, digits, underscores, or hyphens")
end

local function validate_project(project)
    assert(type(project) == "table", "project descriptor must be a table")
    assert(type(project.id or project.name) == "string",
        "project descriptor needs an `id` or `name`")
    return project
end

local function load_module(module_name, label)
    local ok, value = pcall(require, module_name)
    if not ok then
        error(("Could not load %s (%s): %s"):format(label, module_name, tostring(value)), 0)
    end
    return value
end

local function load_project(name)
    assert_project_name(name)
    local prefix = "projects/" .. name
    local config = load_module(prefix .. "/config", "project configuration")
    assert(type(config) == "table", "project configuration must return a table")
    assert(config.id == nil or config.id == name,
        "project configuration id must match the selected project")
    config.id = config.id or name
    return validate_project(config), prefix .. "/main"
end

local function roots_with_engine(project_roots, engine_root, label)
    assert(project_roots == nil or type(project_roots) == "table",
        (label or "asset") .. " roots must be an array")
    local roots = {}
    for _, root in ipairs(project_roots or {}) do roots[#roots + 1] = root end
    roots[#roots + 1] = engine_root
    return roots
end

local function configure_project_assets(project)
    local assets = project.assets or {}
    if Image and Image.set_asset_roots then
        -- project roots win by order, then every project gets the explicit
        -- engine default pack (icon/prompt sheets) as fallback
        Image.set_asset_roots(roots_with_engine(assets.image_roots, ENGINE_IMAGE_ROOT, "image asset"))
    end
    local fonts = require("engine/graphics/font_manager")
    fonts.set_asset_roots(roots_with_engine(assets.font_roots, ENGINE_FONT_ROOT, "font asset"), assets.default_font)
    if fonts.default_path then
        local default_font = fonts.get(nil, 12)
        love.graphics.setFont(default_font)
    end
    if Text and Text.set_shader_roots then
        Text.set_shader_roots(assets.shader_roots or {})
    end
    if input_mgr.controller then
        if project.controller_sprites == false then
            input_mgr.controller.clear_sprite_assets()
        else
            input_mgr.controller.configure_sprite_assets(project.controller_sprites or ENGINE_CONTROLLER_SPRITES)
        end
    end
    if assets.audio and assets.audio ~= "" then
        audio:configure({ root = assets.audio, autoload = true })
    end
end

-- `project.actions` adds or rebinds named input actions before start runs
local function configure_project_actions(project)
    local actions = project.actions
    if actions == nil then return end
    assert(type(actions) == "table", "project.actions must be a table of action bindings")
    local names = {}
    for name in pairs(actions) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do input_mgr.define_action(name, actions[name]) end
end

local function configure_splash(program, project)
    if not program.splash then return end
    local Splash = require("engine/runtime/splash")
    local options = type(project.splash) == "table" and project.splash or {}
    local splash = Splash.new(options)
    if not splash.enabled then return end

    program.splash_screen = splash

    -- Gameplay has not started yet, but clear raw state rather than
    -- dispatching synthetic releases. That prevents a held key, pointer,
    -- touch, or stick from becoming an action on the first gameplay frame
    -- after the splash is gone
    local function suppress_splash_input()
        if input_mgr.mouse then
            if input_mgr.mouse.set_look_active then input_mgr.mouse.set_look_active(false) end
            if input_mgr.mouse.consume_look_delta then input_mgr.mouse.consume_look_delta() end
            if input_mgr.mouse.consume_wheel then input_mgr.mouse.consume_wheel() end
            for button in pairs(input_mgr.mouse.state.active or {}) do
                input_mgr.mouse.state.active[button] = nil
                input_mgr.mouse.state.active_source[button] = nil
            end
        end

        for key in pairs(input_mgr.state.active_keys or {}) do input_mgr.state.active_keys[key] = nil end

        local controller = input_mgr.controller
        if controller then
            for _, device in pairs(controller.controllers or {}) do
                for button in pairs(device.active_btns or {}) do device.active_btns[button] = nil end
                for _, stick in ipairs(device.sticks or {}) do stick[1], stick[2] = 0, 0 end
                for index in ipairs(device.triggers or {}) do device.triggers[index] = 0 end
            end
            local active = controller.active_sticks or {}
            for _, name in ipairs({ "stick1", "stick2" }) do
                local stick = active[name] or {}
                stick[1], stick[2] = 0, 0
                active[name] = stick
            end
            active.l2, active.r2 = 0, 0
        end

        local mobile = input_mgr.mobile
        if mobile then
            mobile.touch_points = {}
            mobile.touch_captures = {}
            mobile.primary_touch_id = nil
        end
    end

    -- the launcher invokes this outside the normal update pipeline while a
    -- splash is active. keeping it separate is what prevents registered
    -- project stages, descriptor.update, timers, and simulation from running
    -- under the startup screen
    suppress_splash_input()
    program._update_startup_splash = function(dt)
        if splash:blocks_input() then suppress_splash_input() end
        splash:update(dt)
        if splash:blocks_input() then suppress_splash_input() end
    end
    -- Composite after game/UI stages but before ratio and post-process
    -- finalization, so this generic engine screen is affected by the same
    -- accessibility shader as every project pixel
    program.pipeline:register("draw", "splash", function()
        splash:draw(program.resolution.x, program.resolution.y)
    end, { phase = "composite", priority = 1000 })

    local function block_or_skip_splash()
        if not splash:blocks_input() then return false end
        if splash.skippable then splash:skip() end
        suppress_splash_input()
        -- do not leak a dismissal press into gameplay (e.g. opening a pause
        -- menu with Escape or jumping/shooting with a face button). a locked
        -- splash consumes presses too, it simply waits for its timeline
        return true
    end
    input_mgr.add_observer("keypressed", block_or_skip_splash)
    input_mgr.add_observer("mousepressed", block_or_skip_splash)
    input_mgr.add_observer("touchpressed", block_or_skip_splash)
    input_mgr.add_observer("gamepadpressed", block_or_skip_splash)
    input_mgr.add_observer("focus", function()
        if splash:blocks_input() then suppress_splash_input() end
    end)
end

local function bootstrap_engine(project)
    platform = require("engine/platform")
    require("engine/services/task")
    require("engine/services/vector")
    require("engine/services/object")
    require("engine/services/oss/tween")
    MenuNavig = require("engine/services/menu_navig")
    require("engine/services/utils")
    require("engine/services/timer")

    -- Program establishes G before graphics modules load: Element, Image, and
    -- Text keep the historical compatibility globals, but no project is baked
    -- into their initialization
    local ProgramClass = require("engine/runtime/host")
    assert(type(ProgramClass) == "table", "engine/runtime/host must return Program")
    local program = ProgramClass(project)

    if project.services and project.services.shake then
        require("engine/services/shake")
    end

    require("engine/graphics/shader_compat")
    require("engine/graphics/element")
    require("engine/graphics/image")
    require("engine/graphics/text")
    require("engine/graphics/particles")

    require("engine/input")
    require("engine/audio")

    configure_project_assets(project)
    configure_project_actions(project)
    local configured_icon = (project.assets or {}).icon
    program.icon_path = configured_icon or ENGINE_ICON
    return program
end

local function register_input_callbacks()
    assert(type(input_mgr.callbacks) == "table", "engine/input must expose input_mgr.callbacks")
    return input_mgr.callbacks
end

local function call_callback(callbacks, name, ...)
    local callback = callbacks[name]
    if callback then return callback(...) end
end

local function invalidate_ui_after_resize(graphics_reset)
    local roots = {}
    for i, element in ipairs(AllElements) do roots[i] = element end
    for _, root in ipairs(roots) do
        root.isdrawn = false
        root._needs_update = true
        root._canvas_dirty = true
        if graphics_reset and root.invalidate_graphics_reset then root:invalidate_graphics_reset() end
        if root.mark_dirty then root:mark_dirty() end
        if root.refresh_layout_recursive then root:refresh_layout_recursive() end
        if root.invalidateTree then root:invalidateTree() end
    end
end

local function force_landscape(width, height)
    if height > width then return height, width end
    return width, height
end

local function configure_runtime(project, load_descriptor)
    project = validate_project(project)
    assert(type(load_descriptor) == "function", "project entrypoint loader must be a function")
    local program = bootstrap_engine(project)
    local input_callbacks = register_input_callbacks()
    local last_dpi
    local project_descriptor
    local last_resize
    local descriptor_draw_registered = false
    local frame_deadline
    local project_started = false

    local function notify_project_resize(width, height, graphics_reset)
        last_resize = { width = width, height = height, graphics_reset = graphics_reset == true }
        if type(project_descriptor) == "table" and type(project_descriptor.resize) == "function" then
            project_descriptor.resize(program, width, height, graphics_reset == true)
        end
    end

    -- Settings such as 4:3 and stretch change a project's virtual draw size
    -- without causing a native love.resize callback. Subscribe once so those
    -- changes reach descriptor.resize just like a real window resize
    program:add_resize_listener(notify_project_resize)

    local function start_project()
        local loaded = load_descriptor()
        project_descriptor = loaded
        if type(loaded) == "function" then
            loaded(program, project)
        elseif type(loaded) == "table" and type(loaded.start) == "function" then
            loaded.start(program, project)
        end
        -- Descriptor-owned drawing belongs inside the render pipeline so final
        -- presentation settings (ratio compositing and accessibility effects)
        -- cover it just like project stages registered directly on G.pipeline
        if not descriptor_draw_registered and type(loaded) == "table"
            and type(loaded.draw) == "function" then
            descriptor_draw_registered = true
            program.pipeline:register("draw", "project_descriptor_draw", function()
                -- Descriptor code is project-owned. preserve engine rendering
                -- state so an accidental Canvas/shader/scissor/blend change
                -- cannot bypass or corrupt later overlay/composite stages
                local target = Surface.capture_render_target()
                love.graphics.push("all")
                local ok, err = pcall(loaded.draw, program)
                love.graphics.pop()
                Surface.restore_render_target(target)
                if not ok then error(err, 0) end
            end, { phase = "content", priority = 0 })
        end
    end

    local function splash_blocks_gameplay()
        local splash = program.splash_screen
        return splash and splash.blocks_gameplay and splash:blocks_gameplay()
    end

    -- project modules may create worlds, register simulation callbacks, start
    -- music, and capture camera input during `start`. defer that one-shot
    -- activation until the engine-owned splash is fully finished so every
    -- configured splash pauses gameplay by default, without project code
    local function start_project_if_ready()
        if project_started then return true end
        if splash_blocks_gameplay() then return false end

        start_project()
        project_started = true
        program:apply_custom_settings()
        if last_resize then
            notify_project_resize(last_resize.width, last_resize.height, last_resize.graphics_reset)
        end
        return true
    end

    -- Pace each frame to a deadline one interval after the previous one
    -- Measuring from this frame's update instead would leave out present(),
    -- event polling and LÖVE's own 1 ms sleep, and a 60 FPS cap would run at
    -- about 50
    local function pace_frame()
        local minimum = tonumber(program.min_dt) or 0
        if minimum <= 0 then
            frame_deadline = nil
            return
        end
        local now = love.timer.getTime()
        local deadline = (frame_deadline or now) + minimum
        if deadline <= now then
            -- Late: restart the cadence here rather than rushing the
            -- following frames to catch up
            frame_deadline = now
            return
        end
        local remaining = deadline - now

        -- Timed sleeps can overshoot by several milliseconds on desktop
        -- schedulers. Learn that overshoot, sleep for the coarse portion, then
        -- wait only for the short remainder so a selected 60/120 Hz cap is not
        -- silently converted into a much lower rate
        local margin = program._frame_sleep_margin or 0.001
        local nap = remaining - margin
        if nap > 0.001 then
            local sleep_started = love.timer.getTime()
            love.timer.sleep(nap)
            local overshoot = math.max(0, love.timer.getTime() - sleep_started - nap)
            program._frame_sleep_margin = math.max(0.00025, math.min(0.008,
                margin * 0.75 + overshoot * 0.25))
        end
        while love.timer.getTime() < deadline do end
        frame_deadline = deadline
    end

    function love.run()
        if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
        if love.timer then love.timer.step() end
        local dt = 0
        return function()
            local frame_started = love.timer and love.timer.getTime()
            if love.event then
                love.event.pump()
                for name, a, b, c, d, e, f in love.event.poll() do
                    if name == "quit" then
                        if not love.quit or not love.quit() then
                            return a or 0
                        end
                    end
                    love.handlers[name](a, b, c, d, e, f)
                end
            end
            if love.timer then dt = love.timer.step() end
            if love.update then love.update(dt) end
            if love.graphics and love.graphics.isActive() then
                love.graphics.origin()
                love.graphics.clear(love.graphics.getBackgroundColor())
                if love.draw then love.draw() end
                love.graphics.present()
            end
            if love.timer and love.timer.getTime() - frame_started < MIN_YIELDING_FRAME_SECONDS then
                love.timer.sleep(0.001)
            end
        end
    end

    function love.load()
        love.graphics.setDefaultFilter("nearest", "nearest")
        math.randomseed(os.time())
        program:load()
        configure_splash(program, project)
        if program.icon_path and love.window.setIcon then
            local ok, icon = pcall(love.image.newImageData, program.icon_path)
            if ok then love.window.setIcon(icon) end
        end
        love.resize()
        start_project_if_ready()
    end

    function love.resize(width, height, graphics_reset)
        local dpi = love.graphics.getDPIScale()
        graphics_reset = graphics_reset == true or (last_dpi ~= nil and dpi ~= last_dpi)
        last_dpi = dpi
        width, height = width or love.graphics.getDimensions()

        local mobile = input_mgr.mobile and input_mgr.mobile.is_mobile
        local landscape = mobile and program.preferred_orientation ~= "portrait"
        if landscape then width, height = force_landscape(width, height) end

        local draw_width, draw_height = love.graphics.getDimensions()
        if landscape then draw_width, draw_height = force_landscape(draw_width, draw_height) end
        program.resolution = program:getSetting("ratio4by3").value
            and program:get_ratio_resolution() or vec2(draw_width, draw_height)
        program.resScaleFactor = (draw_width / 1920 + draw_height / 1080) / 2

        if graphics_reset and program.canvas then
            program:recreate_main_canvas()
        elseif program:getSetting("ratio4by3").value then
            local target = program:get_ratio_resolution()
            if not program.canvas or program.canvas:getWidth() ~= target.x or program.canvas:getHeight() ~= target.y then
                program:recreate_main_canvas()
            end
        end

        CFG.on_window_resized(draw_width, draw_height, graphics_reset)
        invalidate_ui_after_resize(graphics_reset)
        if input_mgr.mouse and input_mgr.mouse.update_display_offsets then input_mgr.mouse.update_display_offsets() end
        program:notify_resized(program.resolution.x, program.resolution.y, graphics_reset)
    end

    function love.update(dt)
        if last_dpi and love.graphics.getDPIScale() ~= last_dpi then love.resize() end
        if CFG.flush_deferred_presentation then CFG.flush_deferred_presentation() end
        program.delta = dt
        program.frame_id = (program.frame_id or 0) + 1
        if not project_started then
            if splash_blocks_gameplay() then
                -- Even the final frame which completes the splash cannot run
                -- gameplay. Activation begins on the following frame
                local update_splash = program._update_startup_splash
                if update_splash then
                    update_splash(dt)
                else
                    program.splash_screen:update(dt)
                end
            else
                start_project_if_ready()
            end
            return
        end
        for _, item in ipairs(program.pipeline.buckets.update) do item.current_func(dt) end
        if input_mgr.update then input_mgr.update(dt) end
        if input_mgr.typing and input_mgr.typing.update then input_mgr.typing.update(dt) end
        if type(project_descriptor) == "table" and type(project_descriptor.update) == "function" then
            project_descriptor.update(program, dt)
        end
    end

    function love.draw()
        program.current_screen = screen or "default"
        program._drawing_frame = true
        local ok, err = pcall(function()
            for _, item in ipairs(program.pipeline.buckets.draw) do item.current_func() end
        end)
        program._drawing_frame = false
        if not ok then
            -- a project error may arrive after the engine has entered an
            -- off-screen ratio/post-process pass. unwind those owned pushes
            -- before LÖVE renders its error screen
            if program.abort_presentation_frame then
                pcall(program.abort_presentation_frame)
            end
            program._presentation_target = nil
            pcall(love.graphics.setCanvas)
            pcall(love.graphics.setShader)
            error(err, 0)
        end
        program._presentation_target = nil
        love.graphics.setShader()
        pace_frame()
    end

    for _, event_name in ipairs(INPUT_EVENTS) do
        local name_copy = event_name
        love[name_copy] = function(...)
            -- Snapshot this before input_mgr sees the event: a skippable
            -- splash becomes inactive while consuming its dismissal press,
            -- but that same press must still never reach project callbacks
            local splash = program.splash_screen
            local splash_owned_event = SPLASH_BLOCKED_INPUT_EVENTS[name_copy]
                and splash and ((splash.blocks_input_event and splash:blocks_input_event(name_copy, ...))
                    or (splash.blocks_input and splash:blocks_input()))
            local result = call_callback(input_callbacks, name_copy, ...)
            if splash_owned_event then return result end
            if type(project_descriptor) == "table" and type(project_descriptor[name_copy]) == "function" then
                return project_descriptor[name_copy](program, ...)
            end
            return result
        end
    end

    function love.quit(...)
        if type(project_descriptor) == "table" and type(project_descriptor.quit) == "function" then
            if project_descriptor.quit(program, ...) then return true end
        end
        program:save_all()
    end

    return program
end

---run a project-owned descriptor directly. this is the public path used by
---projects that consume wave-engine as a pinned submodule
---@param project table
---@return Program
function Launcher.run(project)
    assert(type(project) == "table" and type(project.start) == "function",
        "Launcher.run(project) needs a descriptor table with project.start")
    return configure_runtime(project, function() return project end)
end

---start a workspace project chosen by conf.lua's static local selector
---@param name string
---@return Program
function Launcher.start(name)
    local project, project_module = load_project(name)
    return configure_runtime(project, function()
        return load_module(project_module, "project entrypoint")
    end)
end

return Launcher
