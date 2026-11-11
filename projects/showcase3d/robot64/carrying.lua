-- Picking up and throwing the props in a map's "picks" folders, and talking
-- to characters and signs (parts with a "tx" StringValue), ported from the
-- port's carrying.lua (credited to zKevin, see NOTICE.md). Twirl near a prop
-- to lift it, twirl again to drop it, or move while dropping to throw it. A
-- thrown bomb (brento) can break rocks (brock) and breakables, and a prop
-- that leaves its folder or falls into the kill plane returns home. Twirl
-- near a character to talk. The campaign's held-item quests (bottles, plugs,
-- honey, homework) are not part of the sandbox.
local Source = require("projects/showcase3d/robot64/source")

local Carrying = {}
Carrying.__index = Carrying

local function child(node, name) return node and node:FindFirstChild(name) end
local function alive(node) return node and Source.live(node, Source.lifetime(node)) and node.Parent ~= nil end

function Carrying.new(rules, app, rbx)
    return setmetatable({ rules = rules, app = app, rbx = rbx, V = rbx.Vector3, C = rbx.CFrame,
        connections = {}, picks = {}, extra_ignore = {} }, Carrying)
end

function Carrying:_set(part)
    self.part = part
    local state = self.app.controller.state
    state.holding = part; state.hold_type = part and part.Name or nil
end

function Carrying:held()
    if self.part and not alive(self.part) then self:_set(nil) end
    return self.part
end

function Carrying:retire()
    for _, connection in ipairs(self.connections) do connection:Disconnect() end
    self:dialogue_finish()
    self.connections, self.picks, self.extra_ignore = {}, {}, {}
    self.near, self.interaction_snapshot = nil, nil
    self:_set(nil)
end

function Carrying:index(root)
    local nodes = { root }
    for _, node in ipairs(root:GetDescendants()) do nodes[#nodes + 1] = node end
    for _, node in ipairs(nodes) do
        if node.Name == "picks" and not self.picks[node] then
            self.picks[node] = true
            for _, part in ipairs(node:GetChildren()) do
                if part:IsA("BasePart") then
                    Source.lifetime(part)
                    if not child(part, "st") then
                        self.app.world.Instance.new("Vector3Value", { Name = "st", Value = part.Position, Parent = part })
                    end
                    part.CollisionGroupId = 2
                    self.connections[#self.connections + 1] = part.Touched:Connect(function(hit)
                        if alive(part) and hit.Name == "kill" then part.CFrame = self.C.new(part.st.Value); part.Velocity = self.V.new() end
                    end)
                end
            end
            self.connections[#self.connections + 1] = node.ChildRemoved:Connect(function(part)
                local token = Source.lifetime(part)
                if part.Name == "snowman1" or part.Name == "snowman2" or part.Name == "brento" then return end
                self.rules:later(0, function()
                    if alive(node) and Source.live(part, token) and child(part, "st") then
                        part.Parent = node; part.CFrame = self.C.new(part.st.Value)
                        part.Velocity = self.V.new(); part.RotVelocity = self.V.new()
                    end
                end, part)
            end)
        end
    end
end

function Carrying:_ignore()
    local app = self.app
    local out = { app.character, app.visual.model }
    for _, name in ipairs({ "debris", "button", "textbox", "snapshotcam" }) do
        local node = child(app.world.Workspace, name)
        if node then out[#out + 1] = node end
    end
    for picks in pairs(self.picks) do
        if alive(picks) then for _, part in ipairs(picks:GetChildren()) do out[#out + 1] = part end end
    end
    for _, part in ipairs(self.extra_ignore) do if alive(part) then out[#out + 1] = part end end
    if self.part then out[#out + 1] = self.part end
    return out
end

function Carrying:_ray(origin, direction, ignore)
    local params = self.rbx.RaycastParams.new()
    params.FilterType = "Exclude"; params.FilterDescendantsInstances = ignore; params.RespectCanCollide = false
    return self.app.world.Workspace:Raycast(origin, direction, params)
end

-- The source's grab box: 4 studs ahead of the feet, 8 x 6 x 8 studs.
function Carrying:nearest()
    local app = self.app
    local mps = app.character.Position - self.V.new(0, 1, 0)
    local center = mps + app.character.CFrame.LookVector * 4
    local radius = self.V.new(4, 3, 4)
    local ignore = { app.character, app.visual.model }
    for _, name in ipairs({ "debris", "button" }) do
        local node = child(app.world.Workspace, name)
        if node then ignore[#ignore + 1] = node end
    end
    local found = app.world.Workspace:FindPartsInRegion3WithIgnoreList(self.rbx.Region3.new(center - radius, center + radius), ignore, math.huge)
    local near, distance = nil, 100
    for _, part in ipairs(found) do
        if self.rules:is_active(part) then
            local d = (part.Position - mps).Magnitude
            if (part.Parent.Name == "picks" and d < 5 or child(part, "tx")) and d < distance then near, distance = part, d end
        end
    end
    self.near = near
    -- What the prompt floats over and what twirl acts on.
    self.interaction_snapshot = near and { target = near, kind = child(near, "tx") and "dialogue" or "pickup", action = "twirl",
        frame = near.CFrame, distance = distance, center = center, radius = radius, source = "CharacterScript:9167-9185",
        generation = app.content.generation, console = input_mgr.state.primary_input_device == "controller" } or nil
    return near
end

-- The snapshot's target, if it is still alive and inside the grab box.
function Carrying:current_target()
    local snapshot = self.interaction_snapshot
    local part = snapshot and snapshot.target
    local content = self.app.content
    if not alive(part) or snapshot.generation ~= content.generation or not self.rules:is_active(part) then
        self.near, self.interaction_snapshot = nil, nil
        return
    end
    local mps = self.app.character.Position - self.V.new(0, 1, 0)
    local distance = (part.Position - mps).Magnitude
    local center = mps + self.app.character.CFrame.LookVector * 4
    local radius = snapshot.radius
    local frame, size = part.CFrame, part.Size * .5
    local x, y, z = frame.RightVector, frame.UpVector, frame.LookVector
    local half = self.V.new(math.abs(x.X) * size.X + math.abs(y.X) * size.Y + math.abs(z.X) * size.Z,
        math.abs(x.Y) * size.X + math.abs(y.Y) * size.Y + math.abs(z.Y) * size.Z,
        math.abs(x.Z) * size.X + math.abs(y.Z) * size.Y + math.abs(z.Z) * size.Z)
    local delta = part.Position - center
    local within = math.abs(delta.X) <= radius.X + half.X and math.abs(delta.Y) <= radius.Y + half.Y
        and math.abs(delta.Z) <= radius.Z + half.Z
    if not within or distance >= 100 or not (child(part, "tx") or part.Parent.Name == "picks" and distance < 5) then
        self.near, self.interaction_snapshot = nil, nil
        return
    end
    snapshot.frame, snapshot.distance, snapshot.center = frame, distance, center
    return part
end

-- Twirling at a character (a part with "tx") starts its dialogue.
function Carrying:grab(part)
    if not alive(part) then return false end
    if child(part, "tx") then
        self:dialogue_finish()
        self.speaker, self.dialogue_values = part, {}
        for _, entry in ipairs({ { "Vector3Value", "sz", part.Size }, { "CFrameValue", "cf", part.CFrame } }) do
            if not child(part, entry[2]) then
                self.dialogue_values[#self.dialogue_values + 1] = self.app.world.Instance.new(entry[1],
                    { Name = entry[2], Value = entry[3], Parent = part })
            end
        end
        self.app.character.Velocity = self.V.new()
        self.app.controller.state.skate = false; self.app.controller.state.flying = false
        self.app:begin_dialogue(part.tx, part, self.rules:dialogue_context(part))
        return true
    end
    self.near = part
    self:_set(part)
    part.Anchored = true; part.CanCollide = false
    return true
end

-- Dropping in front of a wall is refused with the cancel sound.
function Carrying:release()
    local part = self:held()
    if not part then return false end
    local app = self.app
    local facing = app.controller.facing or app.character.CFrame.LookVector
    if self:_ray(app.character.Position, facing * 5, self:_ignore()) then
        app.audio:play_named("cancel")
        return true
    end
    part.Anchored = false; part.CanCollide = true
    local dir = app.controller.movement_direction or self.V.new()
    part.Velocity = part.Velocity + (dir.Magnitude > .9 and facing * 50 or self.V.new())
    local below = self:_ray(part.Position + self.V.new(0, 1, 0), self.V.new(0, -3, 0), { part })
    below = below and below.Instance
    if below and below.Name == "snowman1" and part.Name == "snowman2" then
        local template = child(app.content.rf, "snomang")
        if template then
            local snowman = Source.clone(template, app.world, self.rbx)
            snowman.Parent = part.Parent; snowman.CFrame = part.CFrame; snowman.CollisionGroupId = 2
            self.extra_ignore[#self.extra_ignore + 1] = snowman; part:Destroy(); below:Destroy()
            app.content.triggers[snowman] = true
        end
    elseif part.Name == "crayon" then
        local trail = child(part, "Trail")
        if trail then trail.Enabled = false end
    elseif part.Name == "brento" then
        self:_bomb(part)
    end
    self:_set(nil)
    self.rules.attack_at = app.session.clocks.gameplay
    self.rules.attack_was = app.controller.state.attack == true
    app.controller.state.rolling = false
    return true
end

-- Thrown props lose speed each 1/30 s while held.
function Carrying:tick()
    local part = self:held()
    if part then part.Velocity = part.Velocity * .2 end
end

function Carrying:dialogue_finish()
    for _, node in ipairs(self.dialogue_values or {}) do node:Destroy() end
    self.dialogue_values, self.speaker = {}, nil
end

-- Each frame in play: the nearest grab or talk target (for the prompt and
-- autograb parts), or the held prop between the forearms, turned with the
-- head.
function Carrying:update()
    local app = self.app
    local part = self:held()
    if app.mode ~= "play" then self.near, self.interaction_snapshot = nil, nil; return end
    if not part then
        local near = self:nearest()
        if near and child(near, "autograb") and app.session.clocks.gameplay - (self.rules.attack_at or 0) > .2 then self:grab(near) end
        return
    end
    self.interaction_snapshot = nil
    local vis = app.visual.by_name
    if vis.head and vis.armC and vis.armD then
        local rt = child(part, "rt")
        local angle = rt and self.C.Angles(rt.Value.X, rt.Value.Y, rt.Value.Z) or self.C.new()
        part.CFrame = vis.head.CFrame * angle - vis.head.Position + (vis.armC.Position + vis.armD.Position) / 2
            - (vis.armC.CFrame.UpVector + vis.armD.CFrame.UpVector) / 2 + vis.head.CFrame.UpVector / 3
    end
    if part.Name == "crayon" then
        local trail = child(part, "Trail")
        if trail then trail.Enabled = not not app.controller.state.ground end
        if app.controller.state.ground then part.CFrame = app.character.CFrame * self.C.new(0, -1, -2) * self.C.Angles(math.pi, 0, 0) end
    end
end

function Carrying:_break(part)
    part.Name = "not breakable"; part.CanCollide = false; part.Transparency = 1
    self.rules:_instance_sound(child(part, "Sound"))
    for _, node in ipairs(part:GetChildren()) do if node.Name == "Decal" then node:Destroy() end end
    self.rules:_emit(child(part, "pcl"), 20, "CharacterScript:1723-1735")
    self.rules:later(2, function() part:Destroy() end, part)
end

-- A thrown bomb goes off on the first surface it hits whose parent is one
-- of the source's named groups. The test map's own parts are not among
-- them, so there it only goes off against moving platforms, as in the port.
function Carrying:_bomb(part)
    local triggered = false
    self.connections[#self.connections + 1] = part.Touched:Connect(function(hit)
        if triggered or not alive(part) or not hit.Parent then return end
        local name = hit.Parent.Name
        local map = self.app.content.active
        if (name ~= "candy" and name ~= "Mesh" and name ~= "place" and name ~= "not MAKE" and name ~= "moving")
            or hit.Name == "water" or hit.Name == "Light" then return end
        triggered = true
        if hit.Name == "brock" then
            self.rules:_instance_sound(child(hit, "Sound"))
            self.rules:_emit(child(hit, "pcl"), 10, "CharacterScript:1701-1722")
            for index = 1, 6 do
                local decal = child(hit, "d" .. index)
                if decal then decal:Destroy() end
            end
            hit.Transparency = 1; hit.CanCollide = false; hit.Name = "not brock"
            self.rules:later(.6, function() hit:Destroy() end, hit)
        elseif hit.Name == "breakable" then
            self:_break(hit)
        end
        self.rules:_emit(child(child(part, "expl"), "p"), 30, "CharacterScript:1737-1797")
        part.Parent = map; part.Transparency = 1; part.Anchored = true
        self.rules:later(.4, function() part:Destroy() end, part)
    end)
end

return Carrying
