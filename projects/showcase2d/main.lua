-- a small room shooter drawn inside an Element so it follows the window size
-- the HUD uses Text and Image, and the synth supplies the game sounds
local project = require("projects/showcase2d/config")

function project.start(program)
    if project.demo and project.demo ~= "game" then
        return require("projects/showcase2d/typography").start(program, project.demo)
    end
    local Shaker = require("engine/services/shake")
    local Synth = require("engine/services/synth")
    local Menu = require("engine/ui/menu")
    local sprites = require("projects/showcase2d/sprites").load()

    -- x is a wall, - is open floor. Positions below are in tiles
    local MAP = {
        "xxxxxxxxxxxxxxxx",
        "x--------------x",
        "x---xx---------x",
        "x----------xx--x",
        "x-----xxxx-----x",
        "x--------------x",
        "xxxxxxxxxxxxxxxx",
    }
    local COLS, ROWS = #MAP[1], #MAP
    local SPAWNS = { { 12.5, 2.5 }, { 14.5, 5.5 }, { 6.5, 5.5 } }
    local PLAYER_START = { 2.5, 2.5 }

    local walls = {}
    for row = 1, ROWS do
        for col = 1, COLS do
            if MAP[row]:sub(col, col) == "x" then
                walls[#walls + 1] = { x = col - 1, y = row - 1, w = 1, h = 1 }
            end
        end
    end

    local player = { speed = 4.8, max_hp = 6 }
    local player_box = sprites.player_box
    local tears, enemies, impacts = {}, {}, {}
    local score, best, wave = 0, 0, 0
    local banner = { text = "", time = 0 }
    local paused = false
    local menu_frame = -1
    local shoot_held = false
    local time = 0
    local view = { scale = 40, x = 0, y = 0 }
    local shake_offset = { x = 0, y = 0 }

    ------------------------------------------------------------------ audio

    Synth.register({
        shoot = { wave = "triangle", freq = 760, freq_end = 520, duration = 0.07, volume = 0.22 },
        hit = {
            { wave = "square", freq = 300, freq_end = 180,  duration = 0.06, volume = 0.16 },
            { wave = "noise",  freq = 1,   duration = 0.05, volume = 0.08,   lowpass = 0.5 },
        },
        pop = {
            { wave = "triangle", freq = 520, freq_end = 1040, duration = 0.12, volume = 0.26 },
            { wave = "noise",    freq = 1,   duration = 0.12, volume = 0.1,    lowpass = 0.7 },
        },
        hurt = { wave = "saw", freq = 220, freq_end = 90, duration = 0.22, volume = 0.22 },
        dash = { wave = "noise", freq = 1, duration = 0.14, volume = 0.16, lowpass = 0.45, attack = 0.02 },
        wave = {
            { wave = "triangle", freq = 523, duration = 0.1, volume = 0.22 },
            { wave = "triangle", freq = 659, duration = 0.1, delay = 0.09, volume = 0.22 },
            { wave = "triangle", freq = 784, duration = 0.2, delay = 0.18, volume = 0.22 },
        },
        lose = {
            { wave = "triangle", freq = 392, freq_end = 196, duration = 0.45, volume = 0.24 },
            { wave = "noise",    freq = 1,   duration = 0.3, volume = 0.08,   lowpass = 0.8 },
        },
        ui_move = { wave = "sine", freq = 1250, duration = 0.035, volume = 0.12, release = 0.03 },
        ui_select = {
            { wave = "triangle", freq = 700,  duration = 0.05, volume = 0.2 },
            { wave = "triangle", freq = 1050, duration = 0.07, delay = 0.04, volume = 0.18 },
        },
    }, "sfx")

    local function play(name, pitch, volume)
        audio:play("sfx", name, { clone = true, pitch = pitch or 1, volume = volume or 1 })
    end

    -- the music file is optional local media (see the README)
    local music = audio.channels.music and audio.channels.music.tracks["breezing-echo"]
    if music then audio:play("music", "breezing-echo", { volume = 0.35, loop = true }) end

    ------------------------------------------------------------------ feel

    local shaker = Shaker.new(function(shake)
        local offset = shake.position or {}
        shake_offset.x, shake_offset.y = offset.x or 0, offset.y or 0
    end, { name = "showcase_shake", mode = "2d", positionScale = 0.8, rotationScale = 0, rumbleScale = 0.55 })
    shaker:Start()

    local function shake(preset)
        if program:getCustomSetting("showcase_screen_shake") == false then return end
        if CFG:getSetting("reduced_motion").value then return end
        shaker:Shake(Shaker.Presets[preset] or Shaker.Presets.Bump)
    end

    local function rumble(intensity, duration, direction)
        input_mgr.vibration.play({ intensity = intensity, duration = duration, direction = direction or "center" })
    end

    ------------------------------------------------------------------ rules

    local function circle_hits_box(x, y, radius, left, top, right, bottom)
        local nearest_x = math.max(left, math.min(x, right))
        local nearest_y = math.max(top, math.min(y, bottom))
        return (x - nearest_x) ^ 2 + (y - nearest_y) ^ 2 <= radius ^ 2
    end

    local function circle_hits_wall(x, y, radius)
        if x - radius < 0 or y - radius < 0 or x + radius > COLS or y + radius > ROWS then return true end
        for _, wall in ipairs(walls) do
            if circle_hits_box(x, y, radius, wall.x, wall.y, wall.x + wall.w, wall.y + wall.h) then return true end
        end
        return false
    end

    -- stop at the nearest tile face along one axis, leaving the other axis free to slide
    local function slide_axis(position, delta, half_size, cross_position, cross_half, axis, cross_axis)
        if delta == 0 then return position end
        local target = position + delta
        for _, wall in ipairs(walls) do
            local cross = wall[cross_axis]
            if cross_position > cross - cross_half and cross_position < cross + 1 + cross_half then
                local near, far = wall[axis] - half_size, wall[axis] + 1 + half_size
                if delta > 0 and position <= near then target = math.min(target, near) end
                if delta < 0 and position >= far then target = math.max(target, far) end
            end
        end
        return target
    end

    local function move_body(body, dx, dy, dt)
        local previous_x, previous_y = body.x, body.y
        if body == player then
            local w, h = player_box.half_width, player_box.half_height
            body.x = slide_axis(body.x, dx, w, body.y, h, "x", "y")
            body.y = slide_axis(body.y, dy, h, body.x, w, "y", "x")
        else
            if dx ~= 0 and not circle_hits_wall(body.x + dx, body.y, body.radius) then body.x = body.x + dx end
            if dy ~= 0 and not circle_hits_wall(body.x, body.y + dy, body.radius) then body.y = body.y + dy end
        end
        local moving = body.x ~= previous_x or body.y ~= previous_y
        if body.x ~= previous_x then body.face_left = body.x < previous_x end
        body.anim_time = moving == body.moving and body.anim_time + dt or 0
        body.moving = moving
    end

    local function show_banner(text)
        banner.text, banner.time = text, 0
    end

    local function spawn_wave()
        wave = wave + 1
        for index, spawn in ipairs(SPAWNS) do
            enemies[#enemies + 1] = {
                x = spawn[1],
                y = spawn[2],
                radius = 0.34,
                hp = 2 + math.floor(wave * 0.35),
                speed = 1.3 + wave * 0.18,
                flash = 0,
                spawn = 0.4 + index * 0.12,
                moving = false,
                anim_time = index * 0.1,
                face_left = spawn[1] > player.x,
            }
        end
        show_banner("Wave " .. wave)
        play("wave")
    end

    local function reset_room()
        tears, enemies, impacts = {}, {}, {}
        player.x, player.y = PLAYER_START[1], PLAYER_START[2]
        player.hp = player.max_hp
        player.inv, player.cooldown, player.dash = 0, 0, 0
        player.dir_x, player.dir_y = 1, 0
        player.aim_x, player.aim_y = 1, 0
        player.moving, player.anim_time, player.face_left = false, 0, false
        score, wave = 0, 0
        spawn_wave()
    end

    local function fire(dx, dy)
        tears[#tears + 1] = {
            x = player.x + dx * 0.5,
            y = player.y + dy * 0.5,
            vx = dx * 10,
            vy = dy * 10,
            radius = 0.13,
            life = 1.2,
            age = 0,
        }
        play("shoot", 1 + (math.random() - 0.5) * 0.08)
        rumble(0.15, 0.04, { x = dx, y = dy })
    end

    ------------------------------------------------------------------ input

    local function unit(x, y)
        local length = math.sqrt(x * x + y * y)
        if length < 0.0001 then return 0, 0, 0 end
        return x / length, y / length, length
    end

    -- Touch: drag on the left half to move, hold on the right half to aim
    -- and fire. Positions go through the same mapping as the mouse
    local touch = {}
    function project.touchpressed(_, id, x, y)
        if paused then return end
        x, y = input_mgr.mouse.to_input_position(x, y)
        if x < program.resolution.x * 0.5 then
            if not touch.move then touch.move = { id = id, ox = x, oy = y, x = x, y = y } end
        elseif not touch.aim then
            touch.aim = { id = id, x = x, y = y }
        end
    end

    function project.touchmoved(_, id, x, y)
        x, y = input_mgr.mouse.to_input_position(x, y)
        for _, point in pairs(touch) do
            if point.id == id then point.x, point.y = x, y end
        end
    end

    function project.touchreleased(_, id)
        for kind, point in pairs(touch) do
            if point.id == id then touch[kind] = nil end
        end
    end

    local function move_input()
        local x, y = input_mgr.controller.get_active_direction_xy()
        local stick = touch.move
        if stick then
            local dx, dy = (stick.x - stick.ox) / 60, (stick.y - stick.oy) / 60
            local length = math.sqrt(dx * dx + dy * dy)
            if length > 1 then dx, dy = dx / length, dy / length end
            x, y = x + dx, y + dy
        end
        return x, y
    end

    local function aim_input()
        local x, y = 0, 0
        local controller = input_mgr.controller
        if controller.is_action_active("aimup") then y = y - 1 end
        if controller.is_action_active("aimdown") then y = y + 1 end
        if controller.is_action_active("aimleft") then x = x - 1 end
        if controller.is_action_active("aimright") then x = x + 1 end
        local stick = controller.active_sticks.stick2
        if stick then x, y = x + (stick[1] or 0), y + (stick[2] or 0) end
        local ux, uy, length = unit(x, y)
        if length > 0.2 then return ux, uy, true end
        if touch.aim then
            ux, uy, length = unit((touch.aim.x - view.x) / view.scale - player.x,
                (touch.aim.y - view.y) / view.scale - player.y)
            if length > 0.3 then return ux, uy, true end
        end
        if shoot_held or controller.is_action_active("shoot") then
            local mouse = input_mgr.mouse.position
            local mx = (mouse.x - view.x) / view.scale
            local my = (mouse.y - view.y) / view.scale
            ux, uy, length = unit(mx - player.x, my - player.y)
            if length > 0.3 then return ux, uy, true end
        end
        return player.aim_x, player.aim_y, false
    end

    input_mgr.add_key_handler("shoot", {
        pressed = function() shoot_held = true end,
        released = function() shoot_held = false end,
    })
    input_mgr.add_key_handler("roll", {
        pressed = function()
            if paused or player.dash > 0 then return end
            player.dash = 0.16
            play("dash")
            rumble(0.4, 0.1, { x = player.dir_x, y = player.dir_y })
            shake("Bump")
        end,
    })

    ------------------------------------------------------------------ menu

    local menu
    local pages = {}
    local open_page

    local function close_menu()
        if not paused then return end
        paused = false
        menu_frame = program.frame_id
        menu:close()
    end

    local function open_menu()
        if paused then return end
        paused = true
        shoot_held = false
        menu_frame = program.frame_id
        open_page("main")
        play("ui_select")
    end

    -- open, go back a page, or close, at most once per frame
    local function toggle_menu()
        if program.frame_id == menu_frame then return end
        menu_frame = program.frame_id
        if not paused then
            open_menu()
        elseif menu.page ~= "main" then
            open_page("main")
        else
            close_menu()
        end
    end

    local function engine_item(name, label, kind, extra)
        local item = {
            label = label,
            kind = kind,
            get = function() return CFG:getSetting(name).value end,
            set = function(value) CFG:getSetting(name).set(value) end,
        }
        for key, value in pairs(extra or {}) do item[key] = value end
        return item
    end

    local function custom_item(name, label, kind, extra)
        local item = {
            label = label,
            kind = kind,
            get = function() return program:getCustomSetting(name) end,
            set = function(value) program:setCustomSetting(name, value) end,
        }
        for key, value in pairs(extra or {}) do item[key] = value end
        return item
    end

    pages.main = {
        title = "Paused",
        items = {
            { label = "Resume",        on_select = close_menu },
            {
                label = "Restart",
                on_select = function()
                    reset_room(); close_menu()
                end
            },
            { label = "Settings",      on_select = function() open_page("settings") end },
            { label = "Accessibility", on_select = function() open_page("access") end },
            { label = "Quit",          on_select = function() love.event.quit() end },
        },
    }
    pages.settings = {
        title = "Settings",
        items = {
            engine_item("maxvol", "Master volume", "range", { min = 0, max = 10, step = 1 }),
            engine_item("musicvol", "Music", "range", { min = 0, max = 10, step = 1 }),
            engine_item("sfxvol", "Sound effects", "range", { min = 0, max = 10, step = 1 }),
            custom_item("showcase_screen_shake", "Screen shake", "toggle"),
            custom_item("showcase_enemy_speed", "Enemy speed", "range", {
                min = 0.5,
                max = 2,
                step = 0.25,
                format = function(value) return ("%.2gx"):format(value) end,
            }),
            engine_item("fullscreen", "Display", "choice", {
                choices = { "windowed", "borderless" }, labels = { "Windowed", "Fullscreen" },
            }),
            engine_item("vsync", "VSync", "toggle"),
            { label = "Back", on_select = function() open_page("main") end },
        },
    }
    pages.access = {
        title = "Accessibility",
        subtitle = "Applied by the engine to the whole frame",
        items = {
            engine_item("colorblind", "Colour-vision assist", "choice", {
                choices = { "none", "protanopia", "deuteranopia", "tritanopia" },
                labels = { "Off", "Protanopia", "Deuteranopia", "Tritanopia" },
            }),
            engine_item("high_contrast", "High contrast", "toggle"),
            engine_item("grayscale", "Grayscale", "toggle"),
            engine_item("brightness", "Brightness", "range", { min = -0.5, max = 0.5, step = 0.1 }),
            engine_item("reduced_motion", "Reduced motion", "toggle"),
            { label = "Back", on_select = function() open_page("main") end },
        },
    }

    menu = Menu.new({
        id = "showcase_pause",
        theme = { font = project.assets.default_font, title_font = project.assets.default_font },
        footer = "Arrows or stick to navigate",
        on_change = function() play("ui_move") end,
        on_activate = function() play("ui_select") end,
        -- Escape reaches both this and the pause action, toggle_menu keeps
        -- them from acting twice in one frame
        on_cancel = function() toggle_menu() end,
    })

    open_page = function(name)
        local page = pages[name]
        menu.page = name
        menu:set_title(page.title, page.subtitle)
        menu:set_items(page.items)
        menu:open(1)
    end

    input_mgr.add_key_handler("pause", { pressed = toggle_menu })
    input_mgr.add_key_handler("quit", { pressed = toggle_menu })
    input_mgr.add_observer("focus", function(focused)
        if not focused and not paused then open_menu() end
    end)

    ------------------------------------------------------------------ scene

    local function draw_room(_, size)
        local margin_top, margin_bottom = 76, 64
        local available_w = size.x - 48
        local available_h = size.y - margin_top - margin_bottom
        local scale = math.max(12, math.min(available_w / COLS, available_h / ROWS))
        view.scale = scale
        view.x = math.floor((size.x - COLS * scale) * 0.5 + shake_offset.x * scale * 0.05)
        view.y = math.floor(margin_top + (available_h - ROWS * scale) * 0.5 + shake_offset.y * scale * 0.05)

        love.graphics.push("all")
        love.graphics.translate(view.x, view.y)
        love.graphics.scale(scale)
        love.graphics.setColor(0.76, 0.73, 0.66, 1)
        love.graphics.rectangle("fill", 0, 0, COLS, ROWS)

        love.graphics.setColor(1, 1, 1, 1)
        for _, enemy in ipairs(enemies) do
            local alpha = enemy.flash > 0 and 0.45 or 1 - math.max(0, enemy.spawn) * 0.65
            love.graphics.setColor(1, 1, 1, alpha)
            sprites:draw_spider(enemy)
        end
        love.graphics.setColor(1, 1, 1, 1)
        if player.inv <= 0 or math.floor(time * 16) % 2 == 0 then sprites:draw_player(player) end
        for _, wall in ipairs(walls) do sprites:draw_block(wall.x, wall.y) end
        for _, tear in ipairs(tears) do sprites:draw_bullet(tear) end
        for _, impact in ipairs(impacts) do sprites:draw_impact(impact) end
        love.graphics.pop()
    end

    local root = Element {
        name = "showcase_root",
        size = { scale = vec2(1, 1) },
        show_fill = true,
        fill_color = { 0.075, 0.082, 0.102, 1 },
    }
    root:add(Element {
        name = "room",
        size = { scale = vec2(1, 1) },
        zindex = 1,
        on_draw = draw_room,
    })

    -- HUD: Text elements for numbers, an Element for hearts
    local hud_label = root:add(Text {
        name = "wave_label", text = "",
        position = { offset = vec2(24, 10) }, size = { offset = vec2(360, 50) },
        zindex = 10, fontSize = 44,
        textAlignX = "left", textAlignY = "center", textScaled = false, clayWrap = false,
        textColor = { 0.96, 0.96, 0.98, 1 },
    })
    local score_label = root:add(Text {
        name = "score_label", text = "",
        position = { scale = vec2(1, 0), offset = vec2(-444, 12) }, size = { offset = vec2(420, 46) },
        zindex = 10, fontSize = 32,
        textAlignX = "right", textAlignY = "center", textScaled = false, clayWrap = false,
        textColor = { 0.86, 0.88, 0.92, 1 },
    })
    root:add(Element {
        name = "hearts",
        position = { offset = vec2(26, 60) }, size = { offset = vec2(220, 22) },
        zindex = 10,
        on_draw = function()
            for index = 1, player.max_hp do
                local x = (index - 1) * 26 + 10
                local full = index <= player.hp
                love.graphics.setColor(full and 0.95 or 0.3, full and 0.33 or 0.3, full and 0.4 or 0.34, 1)
                love.graphics.circle("fill", x - 4, 8, 6)
                love.graphics.circle("fill", x + 4, 8, 6)
                love.graphics.polygon("fill", x - 10, 10, x + 10, 10, x, 21)
            end
        end,
    })
    local banner_label = root:add(Text {
        name = "banner", text = "",
        position = { scale = vec2(0.5, 0.5) }, anchor = { scale = vec2(0.5, 0.5) },
        size = { offset = vec2(900, 150) },
        zindex = 20, fontSize = 104,
        textAlignX = "center", textAlignY = "center", textScaled = false, clayWrap = false,
        textColor = { 0.98, 0.8, 0.3, 0 },
    })

    -- Bottom hint bar: prompt icons for the active device, drawn with the
    -- engine's controller prompt sheets
    local HINTS = {
        keyboard = {
            { "keyboard_w", "Move" }, { "mouse_left", "Shoot" }, { "keyboard_arrows_all", "Aim and shoot" },
            { "keyboard_e", "Dash" }, { "keyboard_escape", "Pause" },
        },
        controller = {
            { "xbox_stick_l", "Move" }, { "xbox_stick_r", "Aim" }, { "xbox_rt", "Shoot" },
            { "xbox_rb",      "Dash" }, { "xbox_button_menu", "Pause" },
        },
    }

    local function draw_hints(width, height, scale)
        local hints = HINTS[input_mgr.state.primary_input_device == "controller" and "controller" or "keyboard"]
        local font = Menu.font(project.assets.default_font, 14 * scale)
        local icon, gap = 24 * scale, 22 * scale
        local total = 0
        for _, hint in ipairs(hints) do total = total + icon + 6 * scale + font:getWidth(hint[2]) + gap end
        local x = math.floor((width - total + gap) * 0.5)
        local y = height - 20 * scale - icon
        love.graphics.setFont(font)
        for _, hint in ipairs(hints) do
            local sheet, quad, w, h = input_mgr.controller.prompt_sprite(hint[1])
            if sheet then
                love.graphics.setColor(1, 1, 1, 0.9)
                love.graphics.draw(sheet, quad, x, y, 0, icon / w, icon / h)
            end
            x = x + icon + 6 * scale
            love.graphics.setColor(0.78, 0.81, 0.87, 1)
            love.graphics.print(hint[2], x, math.floor(y + (icon - font:getHeight()) * 0.5))
            x = x + font:getWidth(hint[2]) + gap
        end
    end

    ------------------------------------------------------------------ frame

    local function damage_player(from_x, from_y)
        player.hp = player.hp - 1
        player.inv = 0.9
        play("hurt")
        rumble(0.8, 0.2, { x = player.x - from_x, y = player.y - from_y })
        shake("Explosion")
        if player.hp <= 0 then
            best = math.max(best, score)
            play("lose")
            shake("BadTrip")
            rumble(1, 0.5)
            reset_room()
        end
    end

    local function bullet_hit(tear)
        if circle_hits_wall(tear.x, tear.y, tear.radius) then return true end
        for index, enemy in ipairs(enemies) do
            if enemy.spawn <= 0 and (tear.x - enemy.x) ^ 2 + (tear.y - enemy.y) ^ 2
                <= (tear.radius + enemy.radius) ^ 2 then
                enemy.hp, enemy.flash = enemy.hp - 1, 0.08
                if enemy.hp <= 0 then
                    table.remove(enemies, index)
                    score = score + 1
                    play("pop", 1 + math.random() * 0.1)
                    shake("Bump")
                    rumble(0.35, 0.08)
                else
                    play("hit")
                end
                return true
            end
        end
        return false
    end

    local function update_bullets(dt)
        for index = #impacts, 1, -1 do
            local impact = impacts[index]
            impact.age = impact.age + dt
            if impact.age >= sprites.pop_duration then table.remove(impacts, index) end
        end

        for index = #tears, 1, -1 do
            local tear = tears[index]
            local flight = math.min(dt, tear.life)
            -- short steps keep a shot from skipping a wall or spider on a slow frame
            local steps = math.max(1, math.ceil(math.max(math.abs(tear.vx), math.abs(tear.vy)) * flight / 0.25))
            local dx, dy = tear.vx * flight / steps, tear.vy * flight / steps
            tear.age, tear.life = tear.age + flight, tear.life - dt
            local hit = false
            for _ = 1, steps do
                tear.x, tear.y = tear.x + dx, tear.y + dy
                if bullet_hit(tear) then
                    impacts[#impacts + 1] = { x = tear.x, y = tear.y, age = 0 }
                    hit = true
                    break
                end
            end
            if hit or tear.life <= 0 then table.remove(tears, index) end
        end
    end

    local function update_game(dt)
        local mx, my = move_input()
        local ux, uy, length = unit(mx, my)
        if length > 0.1 then player.dir_x, player.dir_y = ux, uy end
        local speed = player.speed * (input_mgr.state.active_keys.space and 1.4 or 1)
        if player.dash > 0 then
            player.dash = player.dash - dt
            speed = player.speed * 2.6
            if length <= 0.1 then ux, uy = player.dir_x, player.dir_y end
        end
        local magnitude = math.min(1, length)
        if player.dash > 0 then magnitude = 1 end
        move_body(player, ux * speed * magnitude * dt, uy * speed * magnitude * dt, dt)

        player.inv = math.max(0, player.inv - dt)
        player.cooldown = math.max(0, player.cooldown - dt)
        local ax, ay, firing = aim_input()
        if firing then player.aim_x, player.aim_y = ax, ay end
        if firing and player.cooldown <= 0 then
            fire(ax, ay)
            player.cooldown = 0.17
        end

        update_bullets(dt)

        local enemy_speed = program:getCustomSetting("showcase_enemy_speed") or 1
        for _, enemy in ipairs(enemies) do
            enemy.flash = math.max(0, enemy.flash - dt)
            if enemy.spawn > 0 then
                enemy.spawn = enemy.spawn - dt
                enemy.anim_time = enemy.anim_time + dt
            else
                local dx, dy, distance = unit(player.x - enemy.x, player.y - enemy.y)
                local step = distance > 0.05 and enemy.speed * enemy_speed * dt or 0
                move_body(enemy, dx * step, dy * step, dt)
                if player.inv <= 0 and circle_hits_box(enemy.x, enemy.y, enemy.radius,
                        player.x - player_box.half_width, player.y - player_box.half_height,
                        player.x + player_box.half_width, player.y + player_box.half_height) then
                    damage_player(enemy.x, enemy.y)
                    return
                end
            end
        end
        if #enemies == 0 then spawn_wave() end
    end

    reset_room()

    -- current game state, for debugging and automated checks
    function project.inspect()
        return {
            player = player,
            enemies = enemies,
            tears = tears,
            score = score,
            wave = wave,
            paused = paused,
            menu = menu,
            view = view
        }
    end

    G.pipeline:register("update", "showcase_update", function(dt)
        menu:update(dt)
        if paused then return end
        time = time + dt
        update_game(dt)
        banner.time = banner.time + dt
        local fade = banner.time < 0.25 and banner.time / 0.25 or math.max(0, 1 - (banner.time - 1.2) / 0.4)
        banner_label.textColor = { 0.98, 0.8, 0.3, fade }
        banner_label.text = banner.text
        hud_label.text = "Wave " .. wave
        score_label.text = best > 0 and ("Score %d   Best %d"):format(score, best) or ("Score %d"):format(score)
    end, { priority = 2, after = "INIT" })

    G.pipeline:register("draw", "showcase_draw", function()
        root:draw()
        love.graphics.push("all")
        if touch.move then
            local stick = touch.move
            love.graphics.setColor(1, 1, 1, 0.18)
            love.graphics.circle("fill", stick.ox, stick.oy, 60)
            love.graphics.setColor(1, 1, 1, 0.5)
            local dx, dy = stick.x - stick.ox, stick.y - stick.oy
            local length = math.sqrt(dx * dx + dy * dy)
            if length > 60 then dx, dy = dx / length * 60, dy / length * 60 end
            love.graphics.circle("fill", stick.ox + dx, stick.oy + dy, 26)
        end
        local width, height = program.resolution.x, program.resolution.y
        local scale = math.max(0.75, math.min(2, math.min(width / 960, height / 600)))
        if not paused then draw_hints(width, height, scale) end
        love.graphics.pop()
        menu:draw(width, height, scale)
    end, { priority = 2, after = "INIT" })
end

return project
