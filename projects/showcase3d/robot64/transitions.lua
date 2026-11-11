-- Iris transitions for portals, respawns and game over, and the damage
-- debris, ported from the port's cinematics.lua (credited to zKevin, see
-- NOTICE.md). The iris closes for 0.4 s, holds while covered, the
-- destination is prepared, and it opens for 0.4 s. Map intros, CPU walk-ins
-- and cutscene cameras are campaign features; the sandbox maps have none.
local Source = require("projects/showcase3d/robot64/source")
local Content = require("projects/showcase3d/robot64/content")

local Transitions = {}
Transitions.__index = Transitions

local function child(node, name) return node and node:FindFirstChild(name) end

function Transitions.new(app, rbx)
    return setmetatable({ app = app, rbx = rbx, V = rbx.Vector3, C = rbx.CFrame, clock = 0, debris = {} }, Transitions)
end

function Transitions:busy() return self.sequence ~= nil end

function Transitions:_phase(name)
    self.sequence.phase, self.sequence.start = name, self.clock
    if name == "close" or name == "gameover_close" then self.app.audio:play_named("load1") end
    if name == "open" or name == "gameover_open" then self.app.audio:play_named("load2") end
    if name == "covered" or name == "gameover_covered" then self.sequence.covered_presented = false end
end

-- The source's locks: input stops, the gameplay clock stops while loading,
-- and an anchored actor stays frozen for the whole sequence.
function Transitions:_begin(sequence, phase)
    local app = self.app
    self.sequence = sequence
    sequence.camera_locked = true
    app.controller:set_input_enabled(false)
    app.session:set_loading(true)
    if sequence.anchor_actor then app.controller:set_frozen(true) end
    app:clear_input()
    self:_phase(phase)
    app.mode = sequence.kind == "gameover" and "gameover" or "transition"
    if phase == "close" then app.hud:iris(true, 0) end
end

function Transitions:request(descriptor)
    if self.sequence then return false end
    local sequence = {}
    for key, value in pairs(descriptor) do sequence[key] = value end
    sequence.kind = sequence.kind or "map"
    self:_begin(sequence, "close")
    return true
end

function Transitions:telemap(part)
    if self.sequence then return false end
    local app = self.app
    local destination = Content.value(part, "to")
    if not app.content.templates[destination] then return false, "Unknown authored destination " .. tostring(destination) end
    -- A "walkto" marker walks the player out along the TeleMap's yaw; its
    -- value is not read (Good edition CharacterScript 1066-1075).
    local walk = self.V.new()
    if child(part, "walkto") then
        local sign = part.Orientation.Y > 0 and -1 or 1
        local rad = math.rad(part.Orientation.Y)
        walk = self.V.new(0.5 * math.abs(math.cos(rad)) * sign, 0, 0.5 * math.abs(math.sin(rad)) * sign)
    end
    local cpu = child(part, "cpu")
    -- Without "where", the destination map's spawn part (1101-1105).
    local where = Content.value(part, "where")
    if not where then
        local spawn = child(app.content.templates[destination], "spawn")
        if not spawn then return false, "The destination map has no spawn part." end
        where = spawn.Position
    end
    self:_begin({ kind = "telemap", destination = destination,
        position = where + walk * 16 + self.V.new(0, cpu and 8 or 0, 0), walkto = walk,
        tofly = child(part, "tofly") ~= nil }, "close")
    app.controller.state.skate = false; app.controller.state.sliding = false
    app.controller:set_frozen(false)
    return true
end

-- The pack and a battery fly off the rig when it is hurt.
function Transitions:damage_debris(previous_health)
    local app = self.app
    app.audio:psound(app.visual.by_name.torso, "damage")
    local trs = child(child(app.content.rf, "vis"), "trs")
    local live = app.visual.by_name
    local point = self.C.lookAt(self.V.new(), app.controller.facing or self.V.new(0, 0, -1))
    local function spawn(name, copy_material)
        local template = child(trs, name)
        if not template or not live.pack then return end
        local part = Source.clone(template, app.world, self.rbx)
        -- finish the moving part before publishing it, so it gets its own render chunk
        part.CFrame = live.pack.CFrame
        part.Anchored = false; part.CanCollide = true
        part.Velocity = -point.LookVector * 10 + self.V.new(0, 20, 0); part.RotVelocity = point.RightVector * 10
        if copy_material then
            part.TextureId = live.pack.TextureId; part.Material = live.pack.Material; part.Reflectance = live.pack.Reflectance
        end
        part.Parent = child(app.world.Workspace, "debris")
        self.debris[#self.debris + 1] = { part = part, until_time = self.clock + 10 }
    end
    if previous_health == 4 then spawn("pack", true) end
    spawn("bt1")
end

function Transitions:gameover()
    if self.sequence then
        if self.sequence.kind == "respawn" then self.sequence.terminal_gameover = true; return true end
        return false
    end
    self:_begin({ kind = "gameover" }, "close")
    self.app.controller.state.skate = false; self.app.controller.state.sliding = false
    return true
end

-- The source's game over scene: the "gameover" model with its own sky,
-- seen from a fixed camera.
function Transitions:_gameover_scene()
    local app = self.app
    app.rules:retire(); app.environment:retire(); app.equipment_visual:retire(); app.equipment:retire(); app.content:retire()
    app.hud:screen("UI", false)
    app.controller:set_frozen(true); app.character.CFrame = self.C.new(0, 200, 0); app.character.Velocity = self.V.new()
    local template = child(app.content.rf, "gameover")
    if template then
        self.scene = Source.clone(template, app.world, self.rbx); self.scene.Parent = app.world.Workspace
        local sky = child(self.scene, "copy")
        if sky then sky.Parent = app.world.Lighting; self.scene_sky = sky end
    end
    app.audio:play_named("gameover")
    self.fixed_camera = self.C.new(0, 0, -10) * self.C.Angles(0, math.pi, 0)
end

function Transitions:_remove_scene()
    if self.scene then self.scene:Destroy(); self.scene = nil end
    if self.scene_sky then self.scene_sky:Destroy(); self.scene_sky = nil end
    self.fixed_camera = nil
end

function Transitions:_handoff(sequence, frame)
    if sequence.handed_off then return end
    sequence.handed_off = true
    self.fixed_camera = nil; sequence.camera_locked = false
    self.app.camera:handoff(frame)
end

-- The covered moment: activate the destination, or run the request's own
-- preparation, then wait for the arrival frames.
function Transitions:_activate()
    local app, sequence = self.app, self.sequence
    self:_remove_scene()
    local map
    if sequence.prepare then
        map = sequence.prepare(sequence)
    else
        local destination = sequence.kind == "gameover" and app.initial_map or sequence.destination
        map = app:activate(destination, { position = sequence.position, tofly = sequence.tofly })
    end
    if self.sequence ~= sequence then return end
    app.mode = sequence.kind == "gameover" and "gameover" or "transition"
    app.session:set_loading(true)
    app.controller:set_input_enabled(false); app.controller:set_frozen(sequence.anchor_actor == true)
    if sequence.kind == "gameover" then app.session.health = 4 end
    self.walkto = sequence.walkto
    self:_handoff(sequence, app.world.Workspace.CurrentCamera.CFrame)
    sequence.readiness = { presented = 0 }
    self:_phase("arrival_wait")
    return map
end

function Transitions:_finish()
    local app, sequence = self.app, self.sequence
    self.sequence, self.walkto, self.fixed_camera = nil, nil, nil
    app.mode = "play"
    app.session:set_loading(false)
    app.controller:set_frozen(false)
    app.controller:set_input_enabled(true)
    app.hud:screen("UI", true)
    app.hud:caption(nil)
    app.hud:hide_iris()
    return sequence
end

-- Called once per drawn frame; arrival waits for two of them.
function Transitions:presented()
    local sequence = self.sequence
    if not sequence then return end
    if sequence.phase == "covered" or sequence.phase == "gameover_covered" then sequence.covered_presented = true end
    if sequence.readiness and sequence.phase == "arrival_wait" then
        sequence.readiness.presented = sequence.readiness.presented + 1
    end
end

function Transitions:update(dt)
    self.clock = self.clock + dt
    for index = #self.debris, 1, -1 do
        local entry = self.debris[index]
        if not entry.part.Parent or self.clock >= entry.until_time then
            if entry.part.Parent then entry.part:Destroy() end
            table.remove(self.debris, index)
        end
    end
    local sequence = self.sequence
    if not sequence then return end
    local hud = self.app.hud
    local elapsed, phase = self.clock - sequence.start, sequence.phase
    if phase == "close" then
        hud:iris(true, elapsed / .4)
        if elapsed >= .4 then self:_phase("covered") end
    elseif phase == "covered" then
        if sequence.covered_presented and elapsed >= (sequence.kind == "gameover" and .4 or .6) then
            if sequence.kind == "gameover" then self:_gameover_scene(); self:_phase("gameover_open")
            else self:_activate() end
        end
    elseif phase == "gameover_open" then
        hud:iris(false, elapsed / .4)
        if elapsed >= .4 then hud:hide_iris(); self:_phase("gameover_hold") end
    elseif phase == "gameover_hold" then
        if elapsed >= 4 then self:_phase("gameover_close") end
    elseif phase == "gameover_close" then
        hud:iris(true, elapsed / .4)
        if elapsed >= .4 then self:_phase("gameover_covered") end
    elseif phase == "gameover_covered" then
        if sequence.covered_presented and elapsed >= .4 then self:_activate() end
    elseif phase == "arrival_wait" then
        local minimum = sequence.arrival_wait or (sequence.kind == "gameover" and .4 or .6)
        if sequence.readiness.presented >= 2 and elapsed >= math.max(minimum, .4) then
            if sequence.before_reveal then sequence.before_reveal(sequence) end
            if sequence.terminal_gameover then
                -- The covered respawn hands its screen straight to game over.
                self.sequence = nil
                self:_begin({ kind = "gameover" }, "covered")
                hud:iris(true, 1)
            else
                self.walkto = nil
                self:_phase("open")
            end
        end
    elseif phase == "open" then
        hud:iris(false, elapsed / .4)
        if elapsed >= .4 then self:_finish() end
    end
end

-- Writes the fixed camera of the game over scene after the follow camera.
function Transitions:publish()
    if self.fixed_camera then self.app.world.Workspace.CurrentCamera.CFrame = self.fixed_camera end
end

function Transitions:camera_locked()
    return self.sequence ~= nil and self.sequence.camera_locked == true
end

function Transitions:retire()
    self.sequence, self.walkto = nil, nil
    self:_remove_scene()
    self.app.hud:hide_iris()
end

function Transitions:destroy()
    self:retire()
    for _, entry in ipairs(self.debris) do if entry.part.Parent then entry.part:Destroy() end end
    self.debris = {}
end

return Transitions
