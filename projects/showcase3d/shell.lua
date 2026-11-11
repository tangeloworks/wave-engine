-- the frame around the Showcase 3D scene: pausing, the controls card and
-- toasts, input routing, focus handling and the pipeline stages. the scene
-- module (robot64/init.lua) supplies the world and its own pause screen
-- through this interface:
--   Scene.new(shell)                 shell: program, setting, notify, play, is_paused,
--                                    open_menu, close_menu, rebuild
--   scene.title, scene.controls      controls-card rows
--   scene.session                    live state while built, else nil
--   scene.pause_menu                 open(panel, page) / close() / back() / input(action)
--                                    click(x, y, button) / update(dt, mouse_x, mouse_y)
--   scene:build(quality) / scene:destroy()
--   scene:update(dt, frame) / scene:draw() / scene:draw_overlay(w, h, scale, paused)
--   scene:press(action) / scene:release(action) / scene:clear_input()
--   scene:respawn(with_effect) / scene:busy() / scene:set_paused(paused)
--   scene:hides_controls() / scene:free_camera()
local Hud = require("projects/showcase3d/hud")
local Sounds = require("projects/showcase3d/sounds")

local Shell = {}

local GAMEPLAY_ACTIONS = { "jump", "dive", "crouch", "twirl", "dance", "snap_camera" }
-- Directional actions move the pause screen's selection
local MENU_MOVES = { up = "up", down = "down", left = "left", right = "right",
    aimup = "up", aimdown = "down", aimleft = "left", aimright = "right" }

function Shell.run(project, program, Scene)
    Sounds.load()
    local hud = Hud.new()
    local paused = false
    local menu_frame = -1
    local scene

    local function setting(name)
        return program:getCustomSetting(name)
    end

    local function ui_scale()
        local width, height = program.resolution.x, program.resolution.y
        return math.max(0.7, math.min(2.2, math.min(width / 1280, height / 720)))
    end

    local function gameplay_active()
        return scene ~= nil and scene.session ~= nil and not paused and not scene:busy()
    end

    local function pause_menu()
        return scene and scene.session and scene.pause_menu or nil
    end

    local shell = {
        program = program,
        setting = setting,
        play = Sounds.play,
        notify = function(text) hud:notify(text) end,
        is_paused = function() return paused end,
    }

    local function start_scene()
        scene = Scene.new(shell)
        hud:set_rows(scene.controls)
        scene:build(setting("s3d_quality"))
        -- expose the active scene to the project's own menus and callbacks
        project.session = scene.session
        project.scene = scene
    end

    -------------------------------------------------------------------- pausing

    local function close_menu()
        if not paused then return end
        paused = false
        menu_frame = program.frame_id
        local menu = pause_menu()
        if menu then menu:close() end
        scene:set_paused(false)
        Sounds.play("ui_close")
    end

    local function open_menu(panel, page)
        if paused or not scene or not scene.session then return end
        paused = true
        menu_frame = program.frame_id
        input_mgr.mouse.set_look_active(false)
        scene:clear_input()
        scene:set_paused(true)
        local menu = pause_menu()
        if menu then menu:open(panel, page) end
        Sounds.play("ui_open")
    end
    shell.close_menu = close_menu
    shell.open_menu = open_menu

    -- a new graphics quality is fixed when a world is created: rebuild the
    -- scene and come back to the same settings page
    function shell.rebuild(quality, page)
        program:setCustomSetting("s3d_quality", quality)
        scene:destroy()
        scene:build(quality)
        project.session = scene.session
        scene:set_paused(true)
        local menu = pause_menu()
        if menu then menu:open("settings", page) end
        hud:notify("Graphics quality: " .. quality)
    end

    -- Escape or Start: open the pause screen, back out of a panel, or resume
    -- at most once per frame (the key and the screen's own button can both
    -- fire)
    local function handle_back()
        if program.frame_id == menu_frame then return end
        if not paused then
            open_menu()
            return
        end
        menu_frame = program.frame_id
        local menu = pause_menu()
        if menu then menu:back() else close_menu() end
    end

    -------------------------------------------------------------------- input

    local function menu_input(action)
        local menu = paused and pause_menu()
        if not menu then return false end
        local result = menu:input(action)
        Sounds.play(action == "accept" and "ui_select" or "ui_move")
        return result ~= nil
    end

    for _, action in ipairs(GAMEPLAY_ACTIONS) do
        input_mgr.add_key_handler(action, {
            pressed = function()
                if gameplay_active() then
                    scene:press(action)
                elseif paused and (action == "jump") then
                    menu_input("accept")
                elseif paused and action == "twirl" and not love.mouse.isDown(1) then
                    -- B or right shift, a left click is handled by position
                    handle_back()
                end
            end,
            released = function()
                if scene and scene.session then scene:release(action) end
            end,
        })
    end
    for action, move in pairs(MENU_MOVES) do
        input_mgr.add_key_handler(action, { pressed = function() menu_input(move) end })
    end
    input_mgr.add_key_handler("accept", { pressed = function() menu_input("accept") end })
    local function on_press(button, x, y)
        local menu = paused and pause_menu()
        if menu and (button == 1 or button == 2) and menu:click(x, y, button) then Sounds.play("ui_select") end
    end
    input_mgr.mouse.add_press_listener(on_press)
    input_mgr.add_key_handler("camera_look", {
        pressed = function()
            if gameplay_active() or (scene and scene.session and scene:free_camera()) then
                input_mgr.mouse.set_look_active(true)
            end
        end,
        released = function() input_mgr.mouse.set_look_active(false) end,
    })
    input_mgr.add_key_handler("menu", { pressed = function() handle_back() end })
    input_mgr.add_key_handler("controls_help", {
        pressed = function()
            if paused then return end
            program:setCustomSetting("s3d_show_controls", not setting("s3d_show_controls"))
        end,
    })
    input_mgr.add_key_handler("respawn", {
        pressed = function()
            if gameplay_active() then scene:respawn(true) end
        end,
    })
    local function on_focus(focused)
        -- Losing focus releases held keys, pausing keeps the player safe
        if not focused and scene and scene.session and not paused then open_menu() end
    end
    input_mgr.add_observer("focus", on_focus)

    local controller = input_mgr.controller
    local function axis(positive, negative)
        return (controller.is_action_active(positive) and 1 or 0) - (controller.is_action_active(negative) and 1 or 0)
    end

    -- one frame of player input, in the conventions the scene reads:
    -- move_y is forward, look_y follows the right stick (down is positive)
    -- the snapshot camera reads it while paused
    local frame = {}
    local stick_was = 0
    local function read_frame(dt)
        local active = gameplay_active() or (scene ~= nil and scene.session ~= nil and scene:free_camera())
        frame.active = active
        frame.dt = dt
        local mx, my = controller.get_active_direction_xy()
        frame.move_x, frame.move_y = mx, -my
        local dx, dy = input_mgr.mouse.consume_look_delta()
        local wheel = input_mgr.mouse.consume_wheel()
        -- the arrow keys turn the camera, the right stick adds to them
        local lx, ly = axis("aimright", "aimleft"), axis("aimdown", "aimup")
        local stick = controller.active_sticks.stick2
        if stick then lx, ly = lx + (stick[1] or 0), ly + (stick[2] or 0) end
        local length = math.sqrt(lx * lx + ly * ly)
        if length > 1 then lx, ly = lx / length, ly / length end
        -- the left stick steps the pause selection when pushed past 0.8, as
        -- the source's paused RenderStepped does
        local push = math.sqrt(mx * mx + my * my)
        if paused and not active and push >= 0.8 and stick_was < 0.8 and input_mgr.state.primary_input_device == "controller" then
            menu_input(math.abs(mx) > math.abs(my) and (mx > 0 and "right" or "left") or (my > 0 and "down" or "up"))
        end
        stick_was = push
        if active then
            frame.mouse_dx, frame.mouse_dy, frame.wheel = dx, dy, wheel
            frame.look_x, frame.look_y = lx, ly
            frame.zoom = axis("zoom_in", "zoom_out")
            frame.up = (controller.is_action_active("jump") and 1 or 0) - (controller.is_action_active("crouch") and 1 or 0)
        else
            frame.move_x, frame.move_y = 0, 0
            frame.mouse_dx, frame.mouse_dy, frame.wheel = 0, 0, 0
            frame.look_x, frame.look_y = 0, 0
            frame.zoom, frame.up = 0, 0
        end
        frame.look_held = input_mgr.mouse.look_active == true
        return frame
    end

    -------------------------------------------------------------------- frame

    start_scene()

    G.pipeline:register("update", "showcase3d_update", function(dt)
        if not scene or not scene.session then return end
        hud:update(dt, setting("s3d_show_controls") and not paused and not scene:hides_controls())
        local menu = paused and pause_menu()
        if menu then
            local x, y = love.mouse.getPosition()
            menu:update(dt, x, y)
        end
        scene:update(dt, read_frame(dt))
    end, { priority = 2, after = "INIT" })

    G.pipeline:register("draw", "showcase3d_world", function()
        if scene and scene.session then scene:draw() end
    end, { phase = "content", priority = 50 })

    G.pipeline:register("draw", "showcase3d_interface", function()
        local width, height = program.resolution.x, program.resolution.y
        local scale = ui_scale()
        if scene and scene.session then
            scene:draw_overlay(width, height, scale, paused)
            hud:draw(width, height, scale)
        end
    end, { phase = "interface", priority = 30 })

    function project.quit()
        input_mgr.mouse.remove_press_listener(on_press)
        if scene then scene:destroy() end
        scene = nil
        project.session = nil
        input_mgr.remove_observer("focus", on_focus)
        G.pipeline:remove("update", "showcase3d_update")
        G.pipeline:remove("draw", "showcase3d_world")
        G.pipeline:remove("draw", "showcase3d_interface")
        return false
    end
end

return Shell
