-- Robot 64 Engine scene: the good edition of the Robot 64 test place,
-- played with the port of zKevin's Robot 64 (see NOTICE.md). The character,
-- controller, camera, equipment, environment, presentation and world rules
-- are the port's own modules, wired and updated in the order the port's
-- application.lua uses. Everything in this folder stays local.
--
-- Implements the scene interface described in ../shell.lua.
local rbx = require("engine/graphics/rbx")
local Menu = require("engine/ui/menu")
local MeshCollision = require("engine/graphics/rbx/runtime/mesh_collision")
local CollisionOverlay = require("engine/graphics/rbx/collision_overlay")

local PACK = "projects/showcase3d/robot64/"
local Source = require(PACK .. "source")
local Assets = require(PACK .. "assets")
local Session = require(PACK .. "session")
local Audio = require(PACK .. "audio")
local Content = require(PACK .. "content")
local Character = require(PACK .. "character")
local Cosmetics = require(PACK .. "cosmetics")
local Controller = require(PACK .. "ball_controller")
local Camera = require(PACK .. "follow_camera")
local Environment = require(PACK .. "player_environment")
local Moving = require(PACK .. "moving_geometry")
local SourceEffects = require(PACK .. "source_effects")
local Equipment = require(PACK .. "equipment")
local EquipmentVisual = require(PACK .. "equipment_visual")
local Presentation = require(PACK .. "source_presentation")
local HUD = require(PACK .. "hud")
local Transitions = require(PACK .. "transitions")
local Rules = require(PACK .. "sandbox_rules")
local Dialogue = require(PACK .. "dialogue")
local DialogueView = require(PACK .. "dialogue_view")
local Prompts = require(PACK .. "prompts")
local PauseMenu = require(PACK .. "pause_menu")
local Wardrobe = require(PACK .. "wardrobe")
local V = rbx.Vector3

local MAP = PACK .. "assets/Robot-64-Engine-good-edition.rbxl"
local ROOT = PACK .. "assets/rbx"
-- The port's physics step.
local PHYSICS_RATE = 60
-- Physics steps run while a new map is still covered (load screen or iris).
local WARMUP_STEPS = 30
local MAX_CATCHUP_SECONDS = 0.05
local MAX_PHYSICS_BACKLOG = 5
local INITIAL_MAP = "testmap"

local Scene = {}
Scene.__index = Scene
Scene.title = "Robot 64 Engine"

Scene.controls = {
    keyboard = {
        { { { "keyboard_w", "keyboard_a", "keyboard_s", "keyboard_d" }, "Move" },
            { { "keyboard_arrows_all" }, "Camera" }, { { "mouse_right" }, "Hold to look" } },
        { { { "key:Space" }, "Jump, again in the air to double jump" } },
        { { { "key:Shift" }, "Crouch: slide, long jump, backflip, ground pound" } },
        { { { "keyboard_e" }, "Dive; with equipment: fly, ride, flame" } },
        { { { "mouse_left" }, "Twirl, pick up, throw, talk" }, { { "key:Ctrl" }, "Dance" } },
        { { { "keyboard_q" }, "Camera behind" }, { { "mouse_scroll_vertical" }, "Zoom" } },
        { { { "keyboard_escape" }, "Pause" }, { { "keyboard_h" }, "Hide" } },
    },
    gamepad = {
        { { { "xbox_stick_l" }, "Move" }, { { "xbox_stick_r" }, "Camera" } },
        { { { "xbox_button_a" }, "Jump, again in the air to double jump" } },
        { { { "xbox_rt" }, "Crouch: slide, long jump, backflip, ground pound" } },
        { { { "xbox_button_x" }, "Dive; with equipment: fly, ride, flame" } },
        { { { "xbox_button_b" }, "Twirl, pick up, throw, talk" }, { { "xbox_dpad_left" }, "Dance" } },
        { { { "xbox_lb" }, "Camera behind" }, { { "xbox_dpad_vertical" }, "Zoom" } },
        { { { "xbox_button_menu" }, "Pause" }, { { "xbox_button_view" }, "Hide" } },
    },
}

local function child(node, name) return node and node:FindFirstChild(name) end

function Scene.available()
    return love.filesystem.getInfo(MAP, "file") ~= nil
        and love.filesystem.getInfo(MAP .. ".assets", "directory") ~= nil
end

function Scene.new(shell)
    return setmetatable({ shell = shell, held = {}, pending = {}, move_x = 0, move_z = 0 }, Scene)
end

-------------------------------------------------------------------- building

-- The sandbox is the test map and the maps its own portals lead to.
local function reachable_maps(content)
    local keep, queue = { [INITIAL_MAP] = true }, { INITIAL_MAP }
    while #queue > 0 do
        local template = content.templates[table.remove(queue)]
        for _, node in ipairs(template and template:GetDescendants() or {}) do
            if node.Name == "TeleMap" then
                local to = Content.value(node, "to")
                if to and content.templates[to] and not keep[to] then keep[to] = true; queue[#queue + 1] = to end
            end
        end
    end
    for name in pairs(content.templates) do
        if not keep[name] then content.templates[name] = nil end
    end
end

function Scene:build(quality)
    local world = assert(rbx.new({
        map_path = MAP,
        asset_root = ROOT,
        quality = quality or "balanced",
        simulate_physics = true,
        physics_rate = PHYSICS_RATE,
        physics_budget_ms = 0,
        async_loading = false,
        allow_remote_assets = false,
        follow_display_settings = false,
        fov_degrees = 70,
        use_authored_gui_fonts = true,
    }))
    local app = { world = world, rbx = rbx, mode = "play", initial_map = INITIAL_MAP, scene = self }
    self.session = app
    app.assets = Assets.new(MAP, ROOT)
    app.session = Session.new()
    app.audio = Audio.new(world, app.assets)
    app.content = Content.new(world, rbx, app.session, app.assets)
    app.content.audio = app.audio
    reachable_maps(app.content)
    local effect_random = love.math.newRandomGenerator(64064)
    app.source_effects = SourceEffects.new(world, rbx, app.assets, {
        random = function(...) return effect_random:random(...) end,
        on_unresolved = function(record)
            if app.rules then app.rules:report(record.feature, record.path or "source-effects", record.reason) end
        end,
    })
    app.hud = HUD.new(world, app.assets, rbx)
    self:_character(app)
    app.transitions = Transitions.new(app, rbx)
    app.wardrobe = Wardrobe.new(app, rbx)
    self:_dialogue(app)
    self.pause_menu = PauseMenu.new(app, self.shell.program, {
        resume = function() self.shell.close_menu() end,
        quit = function() love.event.quit() end,
        -- The Good edition sends players back only after the tutorial ice
        -- cream; the sandbox starts in the hub, so it is always open.
        hub = function()
            self.shell.close_menu()
            if app.mode == "play" then app.transitions:request({ kind = "pause-hub", destination = INITIAL_MAP }) end
        end,
        snapshot = function(active) self:_snapshot(active) end,
        set_quality = function(value) self.shell.rebuild(value, self.pause_menu and self.pause_menu.settings_page) end,
    })

    function app.simulating()
        return not self.shell.is_paused() and (app.mode == "play" or app.mode == "dialogue" or app.mode == "reward"
            or app.mode == "door" or app.mode == "transition" or app.mode == "gameover")
    end
    function app.activate(_, name, options) return self:_activate(name, options) end
    function app.after_teleport()
        app.previous_frame = app.character.CFrame
    end
    function app.clear_input() self:clear_input() end

    app.fixed_connection = world.RunService.FixedHeartbeat:Connect(function(dt) self:_fixed_step(dt) end)
    self:_activate(INITIAL_MAP)
end

-- The character and everything bound to it, as the port's _character().
function Scene:_character(app)
    local world = app.world
    local body, force, visual = Character.create(world, rbx, { visual = "vis", public_source = true, assets = app.assets })
    app.character, app.visual = body, visual
    for _, sound in ipairs(visual.model:GetDescendants()) do
        if sound.ClassName == "Sound" then app.assets:preload_sound(sound.SoundId) end
    end
    app.cosmetics = Cosmetics.new(app, rbx)
    app.source_effects:register(visual.model, { scope = "character" })
    app.camera = Camera.new(world, body, rbx, {
        source_follow = true,
        still_camera = function() return self.shell.setting("s3d_still_camera") == true end,
        snapshot_template = child(app.content.rf, "snapcam"),
        source_context = function() return self:_camera_context() end,
    })
    app.controller = Controller.new(world, body, force, rbx, {
        visual = visual.model,
        animation_templates = visual.templates,
        visual_torso = visual.by_name.torso,
        read_actions = function() return app.step_actions or {} end,
        on_impact = function(part, context) if app.rules then return app.rules:impact(part, context) end end,
        on_surface_sound = function(sound, pitch) if sound then app.audio:play_sound(sound, { pitch = pitch }) end end,
        hooks = {
            actions = function(...)
                if app.presentation then app.presentation:actions(...) end
                if app.equipment then return app.equipment:actions(...) end
            end,
            steer = function(...)
                if app.equipment then return app.equipment:steer(...) end
            end,
            force = function(...)
                local force_value, damping, speed
                if app.equipment then force_value, damping, speed = app.equipment:force(...) end
                if force_value and app.camera then
                    local controller, dt, dir, held = ...
                    force_value, damping = app.camera:force(controller, dt, dir, held, force_value, damping)
                end
                return force_value, damping, speed
            end,
            event = function(...) if app.presentation then app.presentation:event(...) end end,
        },
    })
    app.rules = Rules.new(app, rbx)
    app.equipment = Equipment.new(app.content, app.controller, rbx, {
        canmove = function() return app.mode == "play" end,
        game_time = function() return app.session.clocks.gameplay end,
        set_health = function(value) app.session.health = value end,
        gotice = function() return app.rules.reward ~= nil end,
        on_event = function(name, data)
            if name == "cadence" then
                app.hud:cadence(data.counter + 1, app.session, app.session.paused,
                    function() app.audio:play_named("candy") end)
            end
        end,
    })
    app.moving = Moving.new(app.content, app.controller, rbx, {})
    app.environment = Environment.new(app.content, app.controller, rbx, {
        canmove = function() return app.mode == "play" end,
        game_time = function() return app.session.clocks.gameplay end,
        holding = function() return app.controller.state.holding end,
        region_multiplier = function() return app.rules:_attacking() and 2.5 or 1 end,
        actions = function(...) return app.equipment:actions(...) end,
        force_modifier = function(...)
            local force_value, damping, speed = app.equipment:force(...)
            local controller, dt, dir, held = ...
            force_value, damping = app.camera:force(controller, dt, dir, held, force_value, damping)
            return force_value, damping, speed
        end,
    })
    local visual_random = love.math.newRandomGenerator(641964)
    local function presentation_random(...) return visual_random:random(...) end
    app.equipment_visual = EquipmentVisual.new(app.content, app.controller, visual, app.equipment, rbx, {
        assets = app.assets,
        source_effects = app.source_effects,
        random = presentation_random,
        on_sound = function(sound) if sound then app.audio:play_sound(sound) end end,
        on_unresolved = function(record) app.rules:report(record.feature, record.source, record.reason) end,
    })
    app.presentation = Presentation.new(app.content, app.controller, visual, rbx, {
        assets = app.assets,
        source_effects = app.source_effects,
        character_flare = true,
        equipment = app.equipment,
        random = presentation_random,
        game_time = function() return app.session.clocks.gameplay end,
        context = function() return self:_presentation_context() end,
        regions = function() return self:_source_regions() end,
        cast = function(origin, direction) return app.camera:_source_cast(origin, direction, self:_camera_context()) end,
        particle = function(...) return app.equipment_visual:particle(...) end,
        on_sound = function(sound) if sound then app.audio:play_sound(sound) end end,
        on_unresolved = function(record) app.rules:report(record.feature, record.source, record.reason) end,
    })
end

-- A freshly loaded map spends its first second waking and settling every
-- loose part, and the renderer then merges the settled ones into static
-- batches: tens of milliseconds a frame. Run that second now, while the map
-- is still covered, with the game's own step paused and Beebo held still.
function Scene:_warm_up()
    local app = self.session
    local core = rawget(app.world, "_core")
    local anchored = app.character.Anchored
    app.character.Anchored = true
    self.warming = true
    for step = 1, WARMUP_STEPS do
        app.world:update(1 / PHYSICS_RATE)
        if core and core._prepare_frame_state and step % 10 == 0 then core:_prepare_frame_state() end
    end
    self.warming = false
    app.character.Anchored = anchored
    app.previous_frame = app.character.CFrame
end

-- Conversations, as the port's application.lua wires dialogue.lua and
-- dialogue_view.lua: the voice blips are CharacterScript's text/text2
-- sounds, the textbox is ReplicatedFirst/textbox.
function Scene:_dialogue(app)
    local world = app.world
    app.dialogue = Dialogue.new({ console = false,
        on_action = function(...) return app.rules:dialogue_action(...) end,
        on_sound = function(sound)
            app.audio:play_named(sound.voice, { volume = sound.volume, pitch = sound.pitch or 1 })
        end,
        on_finish = function()
            app.rules:dialogue_finish()
            if app.mode == "dialogue" then app.mode = "play"; app.controller:set_frozen(false) end
        end })
    local scripts = child(Source.service(world, "StarterPlayer"), "StarterPlayerScripts")
    local script = child(scripts, "CharacterScript")
    local textbox = Source.clone(assert(child(app.content.rf, "textbox"), "ReplicatedFirst/textbox missing"), world, rbx)
    local size = textbox.Size
    local spin = assert(child(child(textbox, "SurfaceGui"), "spin"), "textbox spin image missing")
    local templates = {
        text = assert(child(script, "tx"), "CharacterScript/tx missing"),
        icon = assert(child(script, "im"), "CharacterScript/im missing"),
        spin = { Image = spin.Image },
    }
    local view, err = DialogueView.new(app.assets, app.dialogue, {
        physical_size = size, templates = templates,
        fov = function() return world.Workspace.CurrentCamera.FieldOfView end,
        game_time = function() return app.session.clocks.gameplay end,
        on_error = function(message) self.shell.notify(message) end,
    })
    textbox:Destroy()
    app.dialogue_view = assert(view, err)
    function app.begin_dialogue(_, tx, speaker, context) return self:_begin_dialogue(tx, speaker, context) end
end

function Scene:_begin_dialogue(tx, speaker, context)
    local app = self.session
    app.mode = "dialogue"; app.controller:set_frozen(true); self:clear_input()
    app.dialogue_speaker = speaker; app.camera:begin_dialogue(speaker)
    app.presentation:begin_dialogue(speaker)
    local ok, message = app.dialogue:start(tx, speaker, context)
    if not ok then self.shell.notify(message) end
    if not app.dialogue.active and app.mode == "dialogue" then
        app.mode = "play"; app.controller:set_frozen(false)
    end
    return ok
end

-- The prompt over the current grab or talk target, as the port's
-- world_ui:interaction: created on the first target, hidden otherwise.
function Scene:_prompt(dt)
    local app = self.session
    local carrying = app.rules.carrying
    local snapshot = carrying.interaction_snapshot
    if not app.prompts and snapshot and snapshot.target then
        app.prompts = Prompts.new(app.world, rbx, app.assets)
    end
    if not app.prompts then return end
    app.prompts:update(dt, snapshot, {
        camera_frame = app.world.Workspace.CurrentCamera.CFrame, gtick = app.session.clocks.gameplay,
        mode = app.mode, paused = self.shell.is_paused(), loading = app.session.loading,
        talkto = app.dialogue.active, anicam = app.transitions:camera_locked(), held = carrying:held(),
        anchored = app.character.Anchored, pound = app.controller.state.pound,
    })
end

-- Map activation in the port's order: retire the old map's owners, clone
-- the new one, place the player, publish collision, then activate the
-- rules, environment, equipment, presentation, audio and HUD.
function Scene:_activate(name, options)
    local app = self.session
    options = options or {}
    self.physics_backlog = 0
    app.dialogue:cancel(); app.dialogue_speaker = nil
    if app.prompts then app.prompts:clear() end
    app.environment:retire(); app.rules:retire()
    app.presentation:retire(); app.equipment_visual:retire(); app.equipment:retire()
    app.source_effects:retireMap()
    local map, position = app.content:activate(name, options)
    app.source_effects:register(map, { scope = "map" })
    local debris = child(app.world.Workspace, "debris")
    if debris then app.source_effects:register(debris, { scope = "map" }) end
    app.controller:set_frozen(false)
    app.controller.onejump = app.content.onejump
    app.controller:teleport(position, options.direction or app.content.spawn and app.content.spawn.LookVector)
    app.camera:prepare_follow(app.controller.facing)
    app.controller.spawn = app.content.spawn or app.character.CFrame
    app.content.safe = app.character.CFrame
    app.camera.position = nil
    app.previous_frame = app.character.CFrame
    -- Meshes and unions collide as the place authored them; see
    -- engine/graphics/rbx/runtime/mesh_collision.lua.
    app.collision_rows = MeshCollision.prepare(app.world, map)
    if app.overlay then app.overlay:refresh(map, app.collision_rows) end
    local core = rawget(app.world, "_core")
    if core and core._rebuild_physics_assemblies then core:_rebuild_physics_assemblies() end
    app.rules:activate()
    app.environment:activate(map, app.session.clocks.gameplay)
    app.equipment:activate(map, options)
    app.presentation:activate(map)
    app.audio:activate(map)
    app.audio:bind_slide(child(app.visual.by_name.torso, "slide"))
    app.hud:activate(map, app.session, app.content.onejump)
    -- Build the prompt's geometry now, while loading or covered, as the port
    -- does; its first appearance would otherwise stall a frame.
    if not app.prompts then app.prompts = Prompts.new(app.world, rbx, app.assets) end
    app.prompts:prepare()
    self:_warm_up()
    -- Loading leaves a heap full of garbage. Collect it now, while the
    -- screen is loading or covered by the iris, rather than in play.
    collectgarbage("collect")
    return map
end

function Scene:destroy()
    local app = self.session
    if not app then return end
    input_mgr.mouse.set_look_active(false)
    app.fixed_connection:Disconnect()
    if self.pause_menu then self.pause_menu:destroy(); self.pause_menu = nil end
    app.dialogue:cancel()
    app.dialogue_view:destroy()
    if app.prompts then app.prompts:destroy() end
    app.transitions:destroy()
    app.rules:destroy()
    app.presentation:destroy()
    app.equipment_visual:destroy()
    app.equipment:destroy()
    app.environment:destroy()
    app.moving:destroy()
    app.camera:destroy()
    app.controller:destroy()
    app.cosmetics:destroy()
    app.wardrobe:destroy()
    app.visual:destroy()
    app.source_effects:destroy()
    app.hud:destroy()
    if app.overlay then app.overlay:destroy() end
    app.content:destroy()
    app.audio:destroy()
    app.assets:destroy()
    app.world:Destroy()
    self.session = nil
end

-------------------------------------------------------------------- contexts

function Scene:_source_regions()
    local app = self.session
    local regions = app.environment and app.environment.source_regions
    if regions and regions.map == app.content.active then return regions end
    return app.camera and app.camera.source_regions or {}
end

function Scene:_camera_context()
    local app = self.session
    local controller, rules = app.controller, app.rules
    local paused = self.shell.is_paused()
    return {
        state = controller and controller.state or {},
        animation = controller and controller.animation or {},
        visual = app.visual and app.visual.model,
        map = app.content.active,
        gtick = app.session.clocks.gameplay,
        paused = paused, pause_visible = paused,
        gotice = rules and rules.reward ~= nil,
        watertick = app.environment and app.environment.water_tick or -10,
        lockcam = app.transitions and app.transitions:camera_locked() or false,
        regions = app.environment and app.environment.source_regions,
        region_multiplier = rules and rules:_attacking() and 2.5 or 1,
        body_frame = app.body_frame,
        speaker = app.mode == "dialogue" and app.dialogue_speaker or nil,
    }
end

function Scene:_presentation_context()
    local app = self.session
    return {
        paused = app.session.paused,
        canmove = app.mode == "play",
        gotice = app.rules and app.rules.reward ~= nil,
        damage_time = app.rules and app.rules.damage_time,
        water_tick = app.environment and app.environment.water_tick,
        firstperson = app.camera and app.camera.firstperson,
        talkto = app.mode == "dialogue" and app.dialogue_speaker or nil,
        talking = app.dialogue.active and app.dialogue.status == "revealing",
        textbox_background = app.dialogue.background_asset,
    }
end

function Scene:_audio_context()
    local app = self.session
    local controller = app.controller
    local state, animation = controller.state, controller.animation
    local hit = controller.ground_hit
    local torso = app.visual.by_name.torso
    local sequence = app.transitions.sequence
    local phase = sequence and sequence.phase
    local presentation = app.presentation
    return {
        paused = app.session.paused,
        gotice = app.rules.reward ~= nil,
        trdo = (phase == "close" or phase == "covered" or phase == "gameover_close" or phase == "gameover_covered") and 0 or 1,
        flying = state.flying, skate = state.skate, swimming = state.swimming,
        silent_region = self:_source_regions().silent,
        listener_position = app.world.Workspace.CurrentCamera.CFrame.Position,
        sliderp = animation.sliderp, swimerp = animation.swimerp,
        ground_y = presentation.shadow_position and presentation.shadow_position.Y or hit and hit.Position.Y,
        torso_y = torso and torso.Position.Y,
    }
end

-------------------------------------------------------------------- input

function Scene:press(action)
    local app = self.session
    if action == "twirl" then
        local x, y = love.mouse.getPosition()
        if not input_mgr.mouse.look_active and app.hud:pause_hit(x, y) then
            self.shell.open_menu()
            return
        end
    end
    -- Jump or twirl reveals the rest of a line, then moves on.
    if app.mode == "dialogue" then
        if action == "jump" or action == "twirl" then app.dialogue:advance() end
        return
    end
    if action == "twirl" then
        if app.mode == "play" and app.rules:interact() then return end
    elseif action == "dance" then
        if app.mode == "play" then app.presentation:dance() end
        return
    end
    self.pending[action] = true
    self.held[action] = true
end

function Scene:release(action)
    self.held[action] = nil
end

function Scene:clear_input()
    self.pending, self.held = {}, {}
    self.move_x, self.move_z = 0, 0
end

-- Edges are consumed by the first physics step that sees them.
function Scene:_consume()
    local pending, held = self.pending, self.held
    local actions = {
        x = self.move_x, z = self.move_z,
        jump = pending.jump == true, jump_held = held.jump == true,
        dive = pending.dive == true, twirl = pending.twirl == true,
        crouch = held.crouch == true, crouch_pressed = pending.crouch == true,
    }
    pending.jump, pending.dive, pending.twirl, pending.crouch = nil, nil, nil, nil
    return actions
end

-------------------------------------------------------------------- frame

-- One physics step, as the port's PreSimulation handler.
function Scene:_fixed_step(dt)
    local app = self.session
    if self.warming then return end
    if app.mode == "snapshot" then app.camera:snapshot_step(dt); return end
    app.previous_frame = app.character.CFrame
    if not app.simulating() then return end
    local clock = app.session.clocks.gameplay
    if app.mode == "play" then
        app.moving:step(dt, clock)
        local camera_frame = app.world.Workspace.CurrentCamera.CFrame
        local actions = self:_consume()
        actions.x, actions.z = app.camera:movement_axes(actions.x, actions.z)
        app.equipment:update(dt, actions, camera_frame, clock)
        local handled, filtered = app.environment:step(dt, actions, camera_frame, clock)
        app.step_actions = filtered
        app.controller.movement_direction = V.new(filtered.x or 0, 0, filtered.z or 0)
        app.controller.jump_held = filtered.jump_held == true
        if not handled then
            app.controller:step(dt)
            app.environment:after_classic(dt)
        end
        app.rules:step(dt)
        app.step_actions = nil
    else
        if app.mode == "door" then app.controller:cinematic_step(dt, app.rules.walkto) end
        if app.mode == "transition" then app.controller:cinematic_step(dt, app.transitions.walkto) end
        app.rules:step(dt)
    end
end

function Scene:busy()
    local mode = self.session.mode
    return mode ~= "play" and mode ~= "dialogue"
end

-- Snapshot Mode (the pause screen's "snap"): the menu and HUD hide, the
-- camera flies free on the place's snapcam body, and Close or Escape
-- returns to the pause screen, as the source's snap textbutton and skip.
function Scene:_snapshot(active)
    local app = self.session
    local hud, menu = app.hud, self.pause_menu
    if active then
        if app.mode == "snapshot" then return end
        self.snapshot_mode_was = app.mode
        app.mode = "snapshot"
        app.camera:set_free(true)
        menu:close()
        menu.snapshot_active = true
        hud:screen("UI", false)
        hud:screen("skip", true)
        hud:text("skip", "Close")
    else
        if app.mode ~= "snapshot" then return end
        app.mode = self.snapshot_mode_was or "play"
        app.camera:set_free(false)
        menu.snapshot_active = false
        hud:screen("skip", false)
        hud:screen("UI", true)
        menu:open("pause")
    end
end

function Scene:free_camera()
    return self.session ~= nil and self.session.mode == "snapshot"
end

-- The controls card would cover the textbox.
function Scene:hides_controls()
    return self.session ~= nil and self.session.mode == "dialogue"
end

function Scene:set_paused(paused)
    local app = self.session
    if app then app.session.paused = paused == true end
end

function Scene:apply_settings() end

function Scene:respawn()
    local app = self.session
    if app and app.mode == "play" then app.rules:respawn(true) end
end

function Scene:update(dt, frame)
    local app = self.session
    if not app then return end
    if self.shell.is_paused() then
        app.session:update(dt)
        if app.mode == "snapshot" then
            local sensitivity = self.shell.setting("s3d_mouse_sensitivity") or 1
            app.camera:read_input(dt, {
                x = frame.move_x, z = -frame.move_y, up = frame.up,
                source_mouse_x = frame.mouse_dx * sensitivity, source_mouse_y = frame.mouse_dy * sensitivity,
                mouse_look = frame.look_held, source_stick_x = frame.look_x, source_stick_y = -frame.look_y,
            })
            local batches = math.max(1, math.ceil(dt / .1))
            for _ = 1, batches do app.world:update(dt / batches) end
            app.camera:update(dt)
        end
        app.presentation:update(dt, app.session.clocks.gameplay)
        app.audio:update(dt, self:_audio_context())
        app.cosmetics:update(true)
        return
    end
    self.move_x, self.move_z = frame.move_x, -frame.move_y
    if app.mode == "play" then
        local setting = self.shell.setting
        local sensitivity = setting("s3d_mouse_sensitivity") or 1
        local invert = setting("s3d_invert_y") == true and -1 or 1
        local stick = setting("s3d_stick_speed") or 1
        local sx, sy = frame.look_x, -frame.look_y * invert
        if math.sqrt(sx * sx + sy * sy) <= 0.3 then sx, sy = 0, 0 end
        app.camera:read_input(dt, {
            source_mouse_x = frame.mouse_dx * sensitivity, source_mouse_y = frame.mouse_dy * sensitivity * invert,
            source_stick_x = sx * stick, source_stick_y = sy * stick, mouse_look = frame.look_held,
            wheel = frame.wheel, zoom_in = frame.zoom > 0, zoom_out = frame.zoom < 0,
            snap_camera = self.pending.snap_camera == true,
        })
    end
    self.pending.snap_camera = nil
    app.session:update(dt)
    app.dialogue:update(dt)
    if app.mode == "dialogue" and not app.dialogue.active then
        app.rules:dialogue_finish()
        app.mode = "play"; app.controller:set_frozen(false)
        if app.dialogue.last_error then self.shell.notify(app.dialogue.last_error) end
    end
    app.dialogue_view:update(dt)
    app.transitions:update(dt)
    if app.simulating() then
        local clock = app.session.clocks.gameplay
        app.equipment:advance_cadence(dt, clock)
        local pending = (self.physics_backlog or 0) + dt
        local batches = math.max(1, math.ceil(pending / .1))
        local step = pending / batches
        local catchup_deadline = love.timer.getTime() + MAX_CATCHUP_SECONDS
        local completed = 0
        repeat
            app.world:update(step)
            completed = completed + 1
        until completed >= batches or love.timer.getTime() >= catchup_deadline
        self.physics_backlog = math.min((batches - completed) * step, MAX_PHYSICS_BACKLOG)
        app.content:update_presentation(dt, app.world.Workspace.CurrentCamera.CFrame.Position)
        local previous = app.previous_frame or app.character.CFrame
        app.body_frame = previous:Lerp(app.character.CFrame, app.world:get_physics_alpha())
        app.camera:update(dt)
        app.controller.animation.gotice = app.rules.reward ~= nil
        local facing, spin, animation = app.controller:visual_state()
        app.visual:update_visual(facing, spin, animation, app.body_frame)
        app.cosmetics:update()
        app.wardrobe:update(app.camera:visual_alpha() > 0 and 1 or 0)
        app.equipment_visual:update(dt, clock, app.camera:visual_alpha(), app.body_frame)
    end
    app.presentation:update(dt, app.session.clocks.gameplay)
    app.rules:update(dt)
    self:_prompt(dt)
    app.transitions:publish()
    app.source_effects:update(dt)
    app.audio:update(dt, self:_audio_context())
    app.hud:equipment(app.equipment, app.rules.reward ~= nil)
end

function Scene:draw()
    local app = self.session
    app.source_effects:prepare()
    app.world:draw()
    app.transitions:presented()
end

local STATE_NAMES = {
    { "flying", "Jetpack" }, { "skate", "Skateboard" },
    { "swimming", "Swimming" }, { "pole", "Pole" }, { "rope", "Rope" }, { "ledge", "Ledge" },
    { "wall", "Wall slide" }, { "pound", "Ground pound" }, { "sliding", "Slide" },
    { "longjump", "Long jump" }, { "rolling", "Roll" }, { "attack", "Twirl" }, { "skid", "Skid" },
    { "crouch", "Crouch" }, { "dancing", "Dance" },
}

local function describe(state)
    for _, entry in ipairs(STATE_NAMES) do
        if state[entry[1]] then return entry[2] end
    end
    return state.ground and "Ground" or "Air"
end

-- Developer readout, off unless "Show Stats" is on.
function Scene:_draw_stats(width, scale)
    local app = self.session
    local stats = love.graphics.getStats()
    local velocity = app.character.Velocity
    local lines = {
        ("%d FPS  %.1f ms"):format(love.timer.getFPS(), love.timer.getAverageDelta() * 1000),
        ("Physics %d Hz  gravity %d"):format(PHYSICS_RATE, app.world.Workspace.Gravity),
        ("State %s  speed %.1f"):format(describe(app.controller.state), V.new(velocity.X, 0, velocity.Z).Magnitude),
        ("Draw calls %d"):format(stats.drawcalls),
    }
    local font = Menu.font("Poppins-Regular", 13 * scale)
    local pad = 10 * scale
    local w = 0
    for _, line in ipairs(lines) do w = math.max(w, font:getWidth(line)) end
    local h = #lines * font:getHeight() + pad * 2
    local x = width - w - pad * 2 - 16 * scale
    love.graphics.setColor(0.05, 0.06, 0.08, 0.55)
    love.graphics.rectangle("fill", x, 16 * scale, w + pad * 2, h, 8 * scale, 8 * scale)
    love.graphics.setFont(font)
    love.graphics.setColor(0.94, 0.95, 0.97, 1)
    for index, line in ipairs(lines) do
        love.graphics.print(line, math.floor(x + pad), math.floor(16 * scale + pad + (index - 1) * font:getHeight()))
    end
end

function Scene:draw_overlay(width, height, scale)
    local app = self.session
    app.dialogue_view:draw(width, height)
    if self.shell.setting("s3d_collision_debug") then
        if not app.overlay then
            app.overlay = CollisionOverlay.new(app.world, rbx)
            app.overlay:refresh(app.content.active, app.collision_rows)
        end
        app.overlay:draw(width, height, app.character.Position, 70, Menu.font("Poppins-Regular", 12 * scale))
    end
    if not self.shell.setting("s3d_show_stats") then return end
    love.graphics.push("all")
    love.graphics.origin()
    self:_draw_stats(width, scale)
    love.graphics.pop()
end

return Scene
