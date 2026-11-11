-- private candidate: public API over stable explicit IDs in the live matrix
local Service = {}
local bit = require("bit")
local function matrix(self)
    local core = rawget(self, "_core")
    return core:_get_collision_group_registry(), core
end
local function name(value)
    assert(type(value) == "string" and value ~= "", "Collision group name must be a non-empty string")
    return value
end
function Service:IsCollisionGroupRegistered(value) return matrix(self).groups[value] == true end
function Service:GetMaxCollisionGroups() return 32 end
function Service:RegisterCollisionGroup(value)
    value = name(value)
    local groups, core = matrix(self)
    assert(not groups.groups[value], "Collision group already registered: " .. value)
    core:_register_collision_group(value)
end
function Service:CreateCollisionGroup(value)
    self:RegisterCollisionGroup(value)
    return self:GetCollisionGroupId(value)
end
function Service:GetCollisionGroupId(value)
    local groups = matrix(self)
    name(value)
    local id = groups:id_for_name(value)
    assert(id ~= nil, "Collision group is not registered: " .. value)
    return id
end
function Service:GetCollisionGroupName(id)
    assert(type(id) == "number" and id == id and id % 1 == 0 and id >= 0 and id < 32,
        "Collision group ID must be an integer in 0..31")
    return matrix(self):name_for_id(id) or ""
end
function Service:GetRegisteredCollisionGroups()
    local groups, result = matrix(self), {}
    for value in pairs(groups.groups) do
        local mask = -1
        for other in pairs(groups.groups) do
            if not groups:collidable(value, other) then
                mask = bit.band(mask, bit.bnot(bit.lshift(1, groups:id_for_name(other))))
            end
        end
        result[#result + 1] = { name = value, mask = mask }
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end
function Service:GetCollisionGroups()
    local groups, result = matrix(self), self:GetRegisteredCollisionGroups()
    for i = 1, #result do result[i].id = groups:id_for_name(result[i].name) end
    return result
end
function Service:CollisionGroupSetCollidable(a, b, collidable)
    local groups, core = matrix(self)
    name(a); name(b)
    assert(groups.groups[a] and groups.groups[b], "Collision groups must be registered before filtering")
    assert(type(collidable) == "boolean", "Collidable must be a boolean")
    core:_set_collision_groups_collidable(a, b, collidable)
end
function Service:CollisionGroupsAreCollidable(a, b)
    name(a); name(b)
    return matrix(self):collidable(a, b)
end
function Service:SetPartCollisionGroup(part, value)
    name(value)
    assert(self:IsCollisionGroupRegistered(value), "Collision group is not registered: " .. value)
    local _, core = matrix(self)
    assert(type(part) == "table" and getmetatable(part) == getmetatable(self)
        and rawget(part, "_core") == core
        and rawget(part, "_datamodel") == rawget(self, "_datamodel")
        and rawget(part, "_destroyed") ~= true
        and type(part.IsA) == "function" and part:IsA("BasePart"),
        "Expected a live BasePart facade from this world")
    part.CollisionGroup = value
end
function Service:CollisionGroupContainsPart(value, part)
    name(value)
    assert(self:IsCollisionGroupRegistered(value), "Collision group is not registered: " .. value)
    local _, core = matrix(self)
    assert(type(part) == "table" and getmetatable(part) == getmetatable(self)
        and rawget(part, "_core") == core
        and rawget(part, "_datamodel") == rawget(self, "_datamodel")
        and rawget(part, "_destroyed") ~= true
        and type(part.IsA) == "function" and part:IsA("BasePart"),
        "Expected a live BasePart facade from this world")
    return part.CollisionGroup == value
end
return Service
