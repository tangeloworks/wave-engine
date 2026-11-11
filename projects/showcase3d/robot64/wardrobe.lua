-- The Good edition's cosmetics: hats, skins and antennas picked up from a
-- map's "cosmetic" parts and worn from the pause screen's Clothing panel.
-- Follows CharacterScript toskin, toantenna, hatpage, the hatm/wearing
-- textbuttons and the per-frame hat follow (see NOTICE.md). The sandbox keeps
-- ownership for the run only.
local Source = require("projects/showcase3d/robot64/source")

local Wardrobe = {}
Wardrobe.__index = Wardrobe

local function child(node, name) return node and node:FindFirstChild(name) end
local function value(node, name)
    local item = child(node, name)
    return item and item.Value
end

function Wardrobe.new(app, rbx)
    local rf = app.content.rf
    local self = setmetatable({ app = app, rbx = rbx, rf = rf,
        owned = { H = {}, S = {}, A = {} }, hat = 0, skin = nil, antenna = nil }, Wardrobe)
    return self
end

-- Folder entry for an item id. The source finds hats by name (hat<id>) and
-- skins and antennas by their "id" value; this place's one hat is named
-- "beebo", where the source's lookup fails, so hats also match by "id".
function Wardrobe:_entry(kind, id)
    local hats = child(self.rf, "hats")
    if kind == "H" and child(hats, "hat" .. tostring(id)) then return child(hats, "hat" .. tostring(id)) end
    local folder = kind == "H" and hats or child(self.rf, kind == "S" and "skins" or "antennas")
    for _, item in ipairs(folder and folder:GetChildren() or {}) do
        if value(item, "id") == id then return item end
    end
end

function Wardrobe:is_owned(kind, id) return self.owned[kind][id] == true end
function Wardrobe:unlock(kind, id) self.owned[kind][id] = true end

-- hatpage(): owned hats, then skins, then antennas, each by id.
function Wardrobe:owned_list()
    local list = {}
    for _, kind in ipairs({ "H", "S", "A" }) do
        local ids = {}
        for id in pairs(self.owned[kind]) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local entry = self:_entry(kind, id)
            local icon = entry and value(entry, "icon")
            if icon then list[#list + 1] = { key = kind .. id, icon = "rbxassetid://" .. tostring(icon) } end
        end
    end
    return list
end

function Wardrobe:worn_icon(slot)
    local kind, id = slot == 1 and "H" or slot == 2 and "S" or slot == 3 and "A", nil
    if kind == "H" then id = self.hat ~= 0 and self.hat or nil
    elseif kind == "S" then id = self.skin
    elseif kind == "A" then id = self.antenna end
    local entry = kind and id and self:_entry(kind, id)
    local icon = entry and value(entry, "icon")
    return icon and ("rbxassetid://" .. tostring(icon)) or nil
end

-- The hatm textbutton: a hat toggles, a skin or antenna is worn.
function Wardrobe:equip(key)
    local kind, id = key:sub(1, 1), tonumber(key:sub(2))
    if not id then return end
    if kind == "H" then self:equip_hat(self.hat == id and 0 or id)
    elseif kind == "S" then self:apply_skin(id)
    elseif kind == "A" then self:apply_antenna(id) end
end

function Wardrobe:equip_hat(id)
    self.hat = id or 0
    if self.hat_part then self.hat_part:Destroy(); self.hat_part = nil end
    if self.hat == 0 then return end
    local template = self:_entry("H", self.hat)
    if not template then return end
    local hat = Source.clone(template, self.app.world, self.rbx)
    hat.Name = "hat"
    for _, part in ipairs(hat:GetDescendants()) do
        if part:IsA("BasePart") then part.Anchored = true; part.CanCollide = false; part.CanQuery = false; part.CanTouch = false end
    end
    hat.Anchored = true; hat.CanCollide = false; hat.CanQuery = false; hat.CanTouch = false
    hat.Parent = child(self.app.visual.model, "trs") or self.app.visual.model
    self.hat_part, self.hat_size = hat, hat.Size
    self.hat_scale = nil
end

-- toskin(): every rig MeshPart (and the pack) takes the skin's texture on
-- grey Sand; the antenna dot takes the skin's colour.
function Wardrobe:apply_skin(id)
    local visual = self.app.visual
    local entry = self:_entry("S", id) or child(child(self.rf, "skins"), "backup")
    if not entry then return end
    self.skin = id
    local grey = self.rbx.Color3.new(163 / 255, 162 / 255, 165 / 255)
    for _, part in ipairs(visual.model:GetDescendants()) do
        if part.ClassName == "MeshPart" and (part.Parent == visual.model or part.Name == "pack") and part ~= visual.by_name.dot then
            part.TextureID = entry.TextureID
            part.Material = self.rbx.Enum.Material.Sand
            part.Reflectance = 0
            part.Color = grey
        end
    end
    local dot = visual.by_name.dot
    local mesh = child(dot, "Mesh")
    if mesh then mesh.TextureId = "" end
    dot.Reflectance = 0
    local colour = value(entry, "dot")
    if colour then
        dot.Color = colour
        local light = child(dot, "L1")
        if light then light.Color = colour end
    end
end

-- toantenna(): the dot's mesh and scale.
function Wardrobe:apply_antenna(id)
    local entry = self:_entry("A", id) or child(child(self.rf, "antennas"), "default")
    local mesh = child(self.app.visual.by_name.dot, "Mesh")
    if not entry or not mesh then return end
    self.antenna = id
    mesh.MeshId = entry.MeshId
    mesh.Scale = entry.Scale
end

-- The worn hat follows the head each frame, scaled with Beebo, and copies
-- the body's look when it is a "skin" hat.
function Wardrobe:update(alpha)
    local hat = self.hat_part
    if not hat or not hat.Parent then return end
    local visual = self.app.visual
    local head = visual.by_name.head
    local off = child(hat, "off")
    local scale = self.app.controller and self.app.controller.animation.scale or self.rbx.Vector3.new(1, 1, 1)
    local C = self.rbx.CFrame
    if off then
        local p, o = off.Position, off.Orientation
        hat.CFrame = head.CFrame * C.new(p.X * scale.X, p.Y * scale.Y, p.Z * scale.Z)
            * C.Angles(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
    else
        hat.CFrame = head.CFrame
    end
    if not self.hat_scale or self.hat_scale.X ~= scale.X or self.hat_scale.Y ~= scale.Y or self.hat_scale.Z ~= scale.Z then
        hat.Size = self.hat_size * scale; self.hat_scale = scale
    end
    if child(hat, "skin") then
        local torso = visual.by_name.torso
        hat.TextureID, hat.Material, hat.Reflectance = torso.TextureID, torso.Material, torso.Reflectance
    end
    hat.Transparency = alpha or 0
end

function Wardrobe:destroy()
    if self.hat_part then self.hat_part:Destroy(); self.hat_part = nil end
end

return Wardrobe
