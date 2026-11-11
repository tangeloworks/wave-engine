-- World rules of the sandbox, ported from the port's gameplay.lua and
-- encounters.lua (credited to zKevin, see NOTICE.md): pickups, eggs,
-- batteries and health, ice cream rewards, unlock gates, breakables, doors,
-- bounce pads, teleport pads, portals, lava, Jobb, carrying, out-of-bounds
-- recovery and the 0.06 s interaction query. Campaign systems of the port
-- (dialogue, shops, quests, enemies, bosses, races, saves) are not part of
-- the sandbox and are not imitated.
local Source = require("projects/showcase3d/robot64/source")
local Content = require("projects/showcase3d/robot64/content")
local Carrying = require("projects/showcase3d/robot64/carrying")

local Rules = {}
Rules.__index = Rules

local function child(node, name) return node and node:FindFirstChild(name) end
local function sign(n) return n > 0 and 1 or n < 0 and -1 or 0 end
local egg_scale = { 1, 3, 5, 6, 8, 10, 12, 13 }

function Rules.new(app, rbx)
    local self = setmetatable({ app = app, rbx = rbx, gates = {}, epoch = 0, eggs = 0, maxeggs = 8,
        query_accumulator = 0, actor_accumulator = 0, safe_elapsed = 0, unresolved = {}, tasks = {} }, Rules)
    self.carrying = Carrying.new(self, app, rbx)
    self.body_touch = app.character.Touched:Connect(function(part)
        local map = app.content.active
        if map and part and part.Parent and part:IsDescendantOf(map) then self:touch(part, false) end
    end)
    return self
end

function Rules:report(feature, source, message)
    local key = source .. ":" .. feature
    if not self.unresolved[key] then
        self.unresolved[key] = { feature = feature, source = source, message = message }
        print(("[robot64] %s (%s): %s"):format(feature, source, message))
    end
    return message
end

-- Timers belong to the map they started on.
function Rules:later(seconds, callback, subject)
    local lifetime = subject and Source.lifetime(subject)
    self.tasks[#self.tasks + 1] = { remaining = seconds, epoch = self.epoch, callback = function()
        if subject and not Source.live(subject, lifetime) then return end
        callback()
    end }
end

function Rules:advance_tasks(dt)
    local tasks = self.tasks
    self.tasks = {}
    for _, task in ipairs(tasks) do
        if task.epoch == self.epoch then
            task.remaining = task.remaining - dt
            if task.remaining <= 0 then task.callback() else self.tasks[#self.tasks + 1] = task end
        end
    end
end

function Rules:is_active(node)
    return node ~= nil and node.Parent ~= nil and Source.live(node) and self.app.content:is_active(node)
end

function Rules:_instance_sound(sound, pitch)
    if sound then self.app.audio:play_sound(sound, { pitch = pitch }) end
end

function Rules:_emit(emitter, count, source)
    if not emitter then return 0 end
    local admitted, message = self.app.source_effects:emit(emitter, count)
    if type(admitted) ~= "number" or admitted < count then
        self:report("ParticleEmitter:Emit(" .. count .. ")", source, message or "The source effect adapter did not admit the full authored burst.")
    end
    return admitted
end

function Rules:_attacking()
    if self.impact_context and self.impact_context.attack ~= nil then return self.impact_context.attack end
    local now = self.app.session.clocks.gameplay
    if self.app.controller.state.attack and not self.attack_was then self.attack_at = now; self.attack_was = true end
    return self.attack_at ~= nil and now - self.attack_at < .2
end

function Rules:_pounding()
    if self.impact_context then return self.impact_context.pound == true end
    return self.app.controller.state.pound == true
end

function Rules:retire()
    self.epoch = self.epoch + 1
    self.tasks = {}
    self.carrying:retire()
    if self.door and self.door.part.Parent then
        self.door.part.CFrame = self.door.origin; self.door.part.CanCollide = true
    end
    self.gates, self.reward, self.door, self.walkto, self.telemap_overlap = {}, nil, nil, nil, nil
    self.cosmetics = {}
    self.previous_ground, self.last_land_serial, self.activated_map = nil, nil, nil
    self.attack_at, self.attack_was, self.impact_serial, self.impact_context = nil, false, nil, nil
    self.query_accumulator, self.actor_accumulator, self.safe_elapsed = 0, 0, 0
end

-- Gate thresholds are authored on each unlock part's SurfaceGui.
function Rules:activate()
    self:retire()
    local app = self.app
    self.eggs, self.maxeggs = 0, 8
    self.last_land_serial = app.controller.land_serial
    local map = app.content.active
    local nodes = { map }
    for _, node in ipairs(map:GetDescendants()) do nodes[#nodes + 1] = node end
    for _, part in ipairs(nodes) do
        if part:IsA("BasePart") then
            if part.Name:sub(1, 6) == "unlock" then
                local threshold = child(child(part, "SurfaceGui"), "t1")
                local required = threshold and tonumber(threshold.Text)
                local progress = tonumber(part.Name:sub(7))
                if required and progress then
                    self.gates[part] = { required = required, progress = progress }
                    app.content.triggers[part] = true
                else
                    self:report("unlock-metadata", "CharacterScript:2484-2502", "The authored unlock threshold/progression metadata is missing.")
                end
            elseif part.Name == "breakable" or part.Name == "jobb" then
                app.content.triggers[part] = true
            elseif part.Name == "cosmetic" then
                self:_setup_cosmetic(part)
            end
        end
    end
    self.carrying:index(map)
    self.activated_map = map
end

-- Good edition loadmap (CharacterScript 2015-2062): a "cosmetic" part becomes
-- its item spinning in place: the hat, the skin's preview, or the antenna
-- dot with the antenna's mesh. An owned item shows dimmed as "notcosmetic".
function Rules:_setup_cosmetic(part)
    local app = self.app
    local rf = app.content.rf
    local kind = child(part, "hat") and "H" or child(part, "skin") and "S" or "A"
    local id = Content.value(part, "id")
    local entry = app.wardrobe:_entry(kind, id)
    if not id or not entry then
        self:report("cosmetic-" .. tostring(id), "CharacterScript:2015-2040", "The authored cosmetic item is missing.")
        return
    end
    local preview
    if kind == "A" then
        preview = Source.clone(assert(child(child(rf, "vis"), "dot"), "vis dot missing"), app.world, self.rbx)
        for _, node in ipairs(preview:GetChildren()) do node:Destroy() end
        local mesh = Source.clone(entry, app.world, self.rbx)
        mesh.Name = "Mesh"
        mesh.Parent = preview
    else
        preview = Source.clone(entry, app.world, self.rbx)
    end
    preview.Anchored, preview.CanCollide, preview.CanQuery, preview.CanTouch = true, false, true, true
    preview.Parent = part.Parent
    preview.CFrame = part.CFrame
    local data = child(part, kind == "H" and "hat" or kind == "S" and "skin" or "antenna")
    local name = data and data.Value
    if type(name) ~= "string" or name == "" then name = entry.Name end
    if app.wardrobe:is_owned(kind, id) then
        preview.Transparency = 0.5
        if not child(preview, "Mesh") then preview.TextureID = "" end
        preview.Material = self.rbx.Enum.Material.SmoothPlastic
        preview.Color = self.rbx.Color3.new(39 / 255, 57 / 255, 79 / 255)
        preview.Name = "notcosmetic"
    else
        preview.Name = "cosmetic"
        self.cosmetics[preview] = { kind = kind, id = id, name = name }
        app.content.triggers[preview] = true
    end
    app.content.spin[#app.content.spin + 1] = { part = preview, origin = preview.CFrame }
    part:Destroy()
end

function Rules:_consume_pickup(part, after_name)
    local content = self.app.content
    for index, item in ipairs(content.spin) do
        if item.part == part then table.remove(content.spin, index); break end
    end
    content.triggers[part] = nil
    part.Transparency = 1; part.Name = after_name
    self:_emit(child(child(part, "pcl"), "candy"), 1, "CharacterScript:2199-2272")
    self:later(.3, function() if part.Parent then part:Destroy() end end, part)
end

-- Beebo holds the ice cream up for three seconds while the reward camera,
-- face and caption play.
function Rules:_reward_presentation(part, caption, award, subtitle)
    local app = self.app
    local origin = part.CFrame
    self.reward = part; app.mode = "reward"; app.controller:set_frozen(true)
    app.audio:play_named("iced")
    for index = #app.content.spin, 1, -1 do
        if app.content.spin[index].part == part then table.remove(app.content.spin, index) end
    end
    local V, C = self.rbx.Vector3, self.rbx.CFrame
    local frame = app.character.CFrame
    local look = frame.LookVector
    local heading = V.new(look.X, 0, look.Z)
    if heading.Magnitude < 1e-8 then heading = app.controller.facing or V.new(0, 0, -1) end
    heading = V.new(heading.X, 0, heading.Z)
    if heading.Magnitude < 1e-8 then heading = V.new(0, 0, -1) end
    local position = frame.Position + V.new(0, 4, 0)
    part.CFrame = C.new(position, position + heading)
    app.hud:caption(caption, subtitle or Content.value(part, "desc", ""))
    local accepted = not award
    self:later(2, function()
        app.session.health = 4
        if award then accepted = award() end
    end)
    self:later(3, function()
        if accepted then part:Destroy()
        elseif Source.live(part, Source.lifetime(part)) then
            part.CFrame = origin; app.content.spin[#app.content.spin + 1] = { part = part, origin = origin }
        end
        self.reward = nil
        app.camera:handoff(app.world.Workspace.CurrentCamera.CFrame)
        app.hud:caption(nil); app.controller:set_frozen(false); app.mode = "play"
    end)
    return true
end

-- The controller reports each landing and wall contact here.
function Rules:impact(part, context)
    context = context or {}
    if self.app.mode ~= "play" or not self:is_active(part) then return { handled = false } end
    if context.serial and context.serial == self.impact_serial then return { handled = false } end
    self.impact_serial = context.serial
    if context.attack == nil then context.attack = self:_attacking() end
    local result = { handled = true }
    self.impact_context, self.impact_result = context, result
    if context.pound then
        local pound = child(part, "pound")
        if part.Name == "cactus" or pound and pound.Value then
            local delta = -part.CFrame.UpVector * 2
            part.CFrame = part.CFrame + delta; self.app.character.CFrame = self.app.character.CFrame + delta
            result.ground_delta = delta
        end
    end
    self:touch(part, false, context)
    self.impact_context, self.impact_result = nil, nil
    local cloud = part.Name == "cloudy" or part.Name == "weakcloudy"
    result.remove_support = not part.Parent or (part.CanCollide == false and not cloud) or result.velocity ~= nil
    return result
end

function Rules:_ground_hazard(part)
    if not part or not part.Parent or self.app.controller.state.skate then return false end
    local name = part.Name
    if name ~= "lava" and name ~= "lava2" then return false end
    if name == "lava" or (self.app.session.health or 4) > 1 then self:damage() end
    local velocity = self.app.character.Velocity
    self.app.controller:cvt(self.rbx.Vector3.new(velocity.X, 40, velocity.Z))
    return true
end

function Rules:damage(force)
    local app = self.app
    local now = app.session.clocks.gameplay
    if not force and now < (self.invulnerable_until or -1) then return end
    self.invulnerable_until = now + 2
    self.damage_time = now
    local previous_health = app.session.health or 4
    app.transitions:damage_debris(previous_health)
    app.session.health = previous_health - 1
    app.equipment:damage()
    if app.session.health <= 0 then
        app.environment:reset_player()
        app.transitions:gameover()
    end
end

-- Out of bounds: an iris to the last safe spot, or the map's start when on
-- the last battery, then one point of damage unless the floor was bounds2.
function Rules:respawn(no_damage)
    local app = self.app
    if app.mode ~= "play" then return end
    app.equipment:reset_player()
    self.last_land_serial = app.controller.land_serial
    self.previous_ground = nil
    app.environment:reset_player()
    local last_health = app.session.health == 1
    app.transitions:request({ kind = "respawn", anchor_actor = true, arrival_wait = last_health and .5 or 1,
        prepare = function()
            local target = last_health and app.content.rf.char.CFrame or app.content.safe or app.controller.spawn
            app.environment:reset_player(); app.equipment:reset_player()
            app.controller:teleport(target.Position); app.character.CFrame = target
            app:after_teleport()
            return app.content.active
        end,
        before_reveal = function()
            app.environment:reset_player(); app.equipment:reset_player()
            app.controller.pheight = nil; app.character.Velocity = self.rbx.Vector3.new()
            self.last_land_serial = app.controller.land_serial
            app.controller:set_frozen(false)
            if not no_damage then self:damage(true) end
        end })
end

-- Doors swing open, walk Beebo through and close behind him.
function Rules:_open_door(part)
    local app = self.app
    local s = app.controller.state
    local animation = app.controller.animation or {}
    if self.door or s.skate or s.sliding or s.swimming or not s.ground or s.crouch or s.skid
        or (animation.swiperp or 0) >= .1 or app.transitions:busy() then return end
    local origin = part.CFrame
    local offset = origin.Position - (app.character.Position - self.rbx.Vector3.new(0, 1, 0))
    local side = offset.Magnitude > 0 and sign(offset.Unit:Dot(origin.LookVector)) or 0
    if child(part, "load") then
        return self:report("door-room", "CharacterScript:2291", "Doors into rooms are campaign content.")
    end
    self.door = { part = part, origin = origin, side = side, elapsed = 0, accumulator = 0 }
    part.CanCollide = false
    if self.carrying:held() then self.carrying:release() end
    app.character.Velocity = self.rbx.Vector3.new()
    app.mode = "door"; app.controller:set_input_enabled(false); app:clear_input()
    if app.controller.force then app.controller.force.Force = self.rbx.Vector3.new() end
    self:_instance_sound(child(part, "open"))
    return true
end

function Rules:_update_door(dt)
    local door = self.door
    if not door then return end
    local app = self.app
    local V, C = self.rbx.Vector3, self.rbx.CFrame
    if not door.part.Parent then
        self.door, self.walkto = nil, nil
        app.mode = "play"; app.controller:set_input_enabled(true)
        return
    end
    door.elapsed = door.elapsed + dt
    local t = door.elapsed
    local factor = t < .3 and t / .3 or t < .9 and 1 or t < 1.2 and (1.2 - t) / .3 or 0
    door.part.CFrame = door.origin * C.new(-1.8, 0, 0) * C.Angles(0, factor * 2 * door.side, 0) * C.new(1.8, 0, 0)
    self.walkto = t >= .3 and t < .6 and door.origin.LookVector * door.side or nil
    door.accumulator = door.accumulator + dt
    while door.accumulator >= 1 / 30 do
        door.accumulator = door.accumulator - 1 / 30
        local tick = t - door.accumulator
        if tick < .3 or (tick >= .9 and tick < 1.2) then
            local goal = door.origin.Position + door.origin.LookVector * (tick < .3 and -2 or 5.5) * door.side
            local delta = goal - app.character.Position
            app.character.Velocity = app.character.Velocity + V.new(delta.X, 0, delta.Z) * 2
        end
    end
    if t >= 1.2 and not door.closed then
        door.closed = true; door.part.CFrame = door.origin; door.part.CanCollide = true
        self:_instance_sound(child(door.part, "close"))
        local goal = door.origin.Position + door.origin.LookVector * door.side * 5.5
        local current = app.character.Position
        app.character.CFrame = app.character.CFrame + V.new(goal.X - current.X, 0, goal.Z - current.Z)
        app.controller.support, app.controller.ground_hit = nil, nil
        app.mode = "play"; app.controller:set_input_enabled(true)
    end
    if t >= 1.8 then self.door, self.walkto = nil, nil end
end

-- Jobb: twirl into him and he is knocked away, with a new line each time.
function Rules:_jobb(part)
    local app = self.app
    local timer, count = child(part, "debounce"), child(part, "var")
    local now = love.timer.getTime()
    if not timer or not count or not self:_attacking() or now - timer.Value <= 2 then return false end
    local direction = part.Position - (app.character.Position - self.rbx.Vector3.new(0, 1, 0))
    part.Velocity = (direction.Magnitude > 1e-8 and direction.Unit or app.controller.facing) * 50
    timer.Value = now; count.Value = count.Value + 1
    local shout = child(part, "shout")
    if shout then shout.Enabled = count.Value <= 8 end
    if count.Value <= 8 then
        local saying = child(child(part, "sayings"), "t" .. count.Value)
        local label = child(child(shout, "pc"), "TextLabel")
        if label and saying then label.Text = saying.Value end
    end
    return true
end

function Rules:touch(part, from_region, context)
    local app = self.app
    if not self:is_active(part) then return end
    local name = part.Name
    if from_region == nil then from_region = true end
    if app.mode ~= "play" then return end
    if name == "jobb" then return self:_jobb(part) end
    local handled = app.equipment:touch(part)
    if handled ~= nil then return handled end
    if (name == "candy" or name == "hcandy") and from_region then
        self:_consume_pickup(part, "not candy"); app.session:add_candy(1)
    elseif name == "battery" and (app.session.health or 4) < 4 then
        self:_consume_pickup(part, "not battery"); app.audio:play_named("heal")
        app.session.health = math.min(4, (app.session.health or 4) + 1)
    elseif name == "egg" and from_region then
        self.eggs = math.min(self.maxeggs, self.eggs + 1)
        self:_consume_pickup(part, "not egg"); app.audio:play_named("egg", { pitch = 2 ^ (egg_scale[self.eggs] / 12) })
        app.hud:eggs(self.eggs, self.maxeggs)
    elseif name == "lava" and not from_region and not app.controller.state.skate then
        self:damage()
    elseif self.gates[part] and part.CanCollide then
        local gate = self.gates[part]
        if (app.session.icedcream or 0) < gate.required then return end
        app.session:set_progress(gate.progress)
        app.audio:play_named("unlockdoor")
        local removed = {}
        for index, node in ipairs(part:GetChildren()) do removed[index] = node end
        for _, node in ipairs(removed) do node:Destroy() end
        part.CanCollide = false; part.Transparency = 1
        local template = child(app.content.rf, "unlockpcl")
        if template then
            local emitter = Source.clone(template, app.world, self.rbx); emitter.Parent = part
            app.source_effects:register(emitter, { scope = "map" })
            self:_emit(emitter, 40, "CharacterScript:2484-2498")
        end
        self:later(2, function() part:Destroy() end, part)
    elseif name == "breakable" and (self:_attacking() or self:_pounding()) then
        part.Name = "not breakable"; part.CanCollide = false; part.Transparency = 1
        self:_instance_sound(child(part, "Sound"))
        for _, node in ipairs(part:GetChildren()) do if node.Name == "Decal" then node:Destroy() end end
        self:_emit(child(part, "pcl"), 20, "CharacterScript:2507-2520")
        self:later(2, function() part:Destroy() end, part)
    elseif name == "cosmetic" and self.cosmetics[part] then
        local item = self.cosmetics[part]
        self.cosmetics[part] = nil
        local caption = item.kind == "H" and "YOU GOT A HAT!" or item.kind == "S" and "YOU GOT A SKIN!" or "YOU GOT AN ANTENNA!"
        return self:_reward_presentation(part, caption, function()
            app.wardrobe:unlock(item.kind, item.id)
            return true
        end, item.name)
    elseif name == "icedcream" or name == "notcream" then
        local id = Content.value(part, "id")
        if name == "icedcream" then
            return self:_reward_presentation(part, "YOU GOT ICE CREAM!", function() return app.session:collect(id) end)
        end
        app.session:collect(id); part:Destroy(); app.session.health = 4
    elseif name == "door" then
        return self:_open_door(part)
    elseif name == "TeleMap" then
        local overlap = self.telemap_overlap
        if overlap and overlap.part == part and overlap.generation == app.content.generation then return false end
        self.telemap_overlap = { part = part, generation = app.content.generation }
        local admitted, reason = app.transitions:telemap(part)
        if not admitted then
            self.telemap_overlap = nil
            self:report("TeleMap " .. tostring(Content.value(part, "to")), "CharacterScript:2005-2198", reason or "Not admitted.")
        end
        return admitted, reason
    elseif child(part, "tx") then
        if not app.controller.state.ground then
            local velocity = app.character.Velocity
            app.character.Velocity = self.rbx.Vector3.new(velocity.X, 30, velocity.Z)
            self:_instance_sound(child(part, "stomp"))
        end
    elseif name:sub(1, 3) == "TPa" then
        local target = child(part.Parent, "TPb" .. name:sub(4))
        if not target then return self:report("TPa-pair", "CharacterScript:2471-2478", "Authored teleport destination is missing.") end
        local shift = target.Position - app.character.Position
        app.character.CFrame = app.character.CFrame + shift
        if app.controller.pheight then app.controller.pheight = app.controller.pheight + shift.Y end
        app.controller.support, app.controller.ground_hit = nil, nil
        local flat = self.rbx.Vector3.new(shift.X, 0, shift.Z)
        if app.camera.position then app.camera.position = app.camera.position + flat end
        if app.camera.follow_target then app.camera.follow_target = app.camera.follow_target + flat end
        return true
    end
end

function Rules:interactions()
    local app = self.app
    local V = self.rbx.Vector3
    local mps = app.character.Position - V.new(0, 1, 0)
    local held = self.carrying:held()
    local multiplier = self:_attacking() and 2.5 or 1
    local lower = V.new(1.6, held and held.Name == "crayon" and 2 or 0, 1.6) * multiplier
    local upper = V.new(1.600000023841858, 2, 1.600000023841858) * multiplier
    local nearby = app.world.Workspace:FindPartsInRegion3WithIgnoreList(self.rbx.Region3.new(mps - lower, mps + upper),
        { app.character }, math.huge)
    local overlap = self.telemap_overlap
    if overlap then
        local inside = false
        if overlap.generation == app.content.generation and self:is_active(overlap.part) then
            for _, part in ipairs(nearby) do if part == overlap.part then inside = true; break end end
        end
        if not inside then self.telemap_overlap = nil end
    end
    for _, part in ipairs(nearby) do
        if app.content.triggers[part] and self:is_active(part) then
            if self:touch(part, true) then break end
        end
    end
end

-- Twirl lifts or drops a prop, or talks to a character, before it reaches
-- the controller.
function Rules:interact()
    if self.app.mode ~= "play" then return false end
    if self.carrying:held() then return self.carrying:release() end
    local snapshot = self.carrying.interaction_snapshot
    local near = snapshot and self.carrying:current_target() or self.carrying:nearest()
    return near and self.carrying:grab(near) or false
end

-------------------------------------------------------------------- dialogue

function Rules:dialogue_context(speaker)
    local map = self.app.content.active
    return { generation = self.app.content.generation, map = map,
        minor = child(child(map, "settings"), "minor") ~= nil }
end

-- The Good edition's end-of-conversation INTs (CharacterScript totext):
-- 3 sets health to one battery and deals a hit. The cosmetics shop (1) and
-- saving (2) are not part of the sandbox; they are reported and the
-- conversation ends.
function Rules:dialogue_action(descriptor, speaker, context)
    local app = self.app
    context = context or {}
    if context.generation and context.generation ~= app.content.generation then return false, "Dialogue belongs to a retired map." end
    local name = descriptor.name
    if name == "knockout" then
        app.session.health = 1
        self:later(0, function() self:damage() end)
        return true
    elseif name == "good_edition_shop" then
        self:report("good-edition-shop", "CharacterScript totext INT 1", "Rusty's cosmetics shop is not part of the sandbox.")
        return false, "Rusty's cosmetics shop is not part of this sandbox."
    elseif name == "save_game" then
        self:report("good-edition-save", "CharacterScript totext INT 2", "The sandbox keeps no save game.")
        return false, "This sandbox has no save game."
    end
    return false, "Unknown dialogue action " .. tostring(name)
end

function Rules:dialogue_finish()
    self.carrying:dialogue_finish()
end

-- Runs once per physics step, after the controller.
function Rules:step(dt)
    local app = self.app
    local map = app.content.active
    if not map or self.activated_map ~= map then return end
    local body = app.character
    local ground = app.controller.ground_hit and app.controller.ground_hit.Instance
    self.actor_accumulator = self.actor_accumulator + dt
    while self.actor_accumulator >= 1 / 30 do
        self.actor_accumulator = self.actor_accumulator - 1 / 30
        self.carrying:tick()
    end
    if app.mode ~= "play" then return end
    self:_ground_hazard(ground)
    self.previous_ground = ground
    if app.mode ~= "play" then return end
    if app.controller.state.attack and not self.attack_was then self.attack_at = app.session.clocks.gameplay end
    self.attack_was = app.controller.state.attack == true
    if ground and ground.Name ~= "Slide" and ground.Name ~= "soap" and ground.Name ~= "bounds" and ground.Name ~= "bounds2"
        and ground.Parent and ground.Parent.Name ~= "moving" then
        self.safe_elapsed = self.safe_elapsed + dt
        if self.safe_elapsed >= 2 then app.content.safe = body.CFrame end
    else
        self.safe_elapsed = 0
    end
    local kill = child(map, "kill")
    if body.Position.Y - 1 < (kill and kill.Position.Y or -400) or (ground and (ground.Name == "bounds" or ground.Name == "bounds2")) then
        self:respawn(ground and ground.Name == "bounds2")
        return
    end
    self.query_accumulator = self.query_accumulator + dt
    while self.query_accumulator >= .06 do
        self.query_accumulator = self.query_accumulator - .06
        self:interactions()
    end
end

function Rules:update(dt)
    local app = self.app
    self:advance_tasks(dt)
    if not app.content.active or self.activated_map ~= app.content.active then return end
    self.carrying:update()
    self:_update_door(dt)
end

function Rules:destroy()
    self:retire()
    if self.body_touch then self.body_touch:Disconnect(); self.body_touch = nil end
end

return Rules
