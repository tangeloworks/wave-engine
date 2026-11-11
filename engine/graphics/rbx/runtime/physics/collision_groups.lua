-- private candidate only, no live import has been qualified
local Data = runtime_require("physics/collision_group_data.lua")
local CollisionGroups = {}
CollisionGroups.__index = CollisionGroups
local DEFAULT_GROUP = "Default"
CollisionGroups.DEFAULT_GROUP = DEFAULT_GROUP
local function group_name(name)
    if name == nil or name == "" then return DEFAULT_GROUP end
    return tostring(name)
end
local function valid_id(id)
    return type(id) == "number" and id == id and id % 1 == 0 and id >= 0 and id < 32
end
function CollisionGroups.new()
    return setmetatable({
        groups = { [DEFAULT_GROUP] = true }, blocked = {}, blocked_count = 0,
        public_ids = { [DEFAULT_GROUP] = 0 }, public_names = { [0] = DEFAULT_GROUP },
        public_count = 1,
    }, CollisionGroups)
end
-- IDs are assigned at registration, never by lookup/enumeration. explicit
-- source IDs retain sparse values and do not depend on serialized row order
function CollisionGroups:register(name, id)
    name = group_name(name)
    local old = self.public_ids[name]
    if old ~= nil then
        assert(id == nil or id == old, "Collision group name already owns another ID")
        return name
    end
    if id ~= nil then
        assert(valid_id(id), "Collision group ID must be an integer in 0..31")
        assert(self.public_names[id] == nil, "Collision group ID already registered")
    else
        for candidate = 1, 31 do
            if self.public_names[candidate] == nil then id = candidate; break end
        end
        assert(id ~= nil, "Maximum collision group count exceeded")
    end
    assert(self.public_count < 32, "Maximum collision group count exceeded")
    self.groups[name], self.public_ids[name], self.public_names[id] = true, id, name
    self.public_count = self.public_count + 1
    return name
end
function CollisionGroups:id_for_name(name) return self.public_ids[group_name(name)] end
function CollisionGroups:name_for_id(id)
    if not valid_id(id) then return nil end
    return self.public_names[id]
end
function CollisionGroups:set_collidable(a, b, collidable)
    a, b = self:register(a), self:register(b)
    local row = self.blocked[a]
    local was_blocked = row ~= nil and row[b] == true
    if collidable == false then
        if not was_blocked then
            if row == nil then row = {}; self.blocked[a] = row end
            row[b] = true
            local mirror = self.blocked[b]
            if mirror == nil then mirror = {}; self.blocked[b] = mirror end
            mirror[a] = true
            self.blocked_count = self.blocked_count + 1
            return true
        end
    elseif was_blocked then
        row[b] = nil
        local mirror = self.blocked[b]
        if mirror then mirror[a] = nil end
        self.blocked_count = self.blocked_count - 1
        return true
    end
    return false
end
-- existing allocation-free physical hot path remains name-based
function CollisionGroups:collidable(a, b)
    if self.blocked_count == 0 then return true end
    if a == nil or a == "" then a = DEFAULT_GROUP end
    local row = self.blocked[a]
    if row == nil then return true end
    if b == nil or b == "" then b = DEFAULT_GROUP end
    return row[b] ~= true
end
function CollisionGroups.from_descriptor(desc)
    assert(Data.is_validated(desc), "Strict module-owned collision group descriptor required")
    assert(desc.pair_convention == nil and desc.pair_semantics_inferred == false
        and desc.collidable_by_id == nil, "Names-only import refuses an inferred pair descriptor")
    local default = desc.by_id[0]
    assert(default and default.name == DEFAULT_GROUP, "Serialized Default must own ID 0")
    local matrix = CollisionGroups.new()
    local rows = {}
    for index, row in ipairs(desc.groups) do
        matrix:register(row.name, row.id)
        rows[index] = { id=row.id, name=row.name, mask_hex_le=row.mask_hex_le,
            mask_le_u32=row.mask_le_u32, mask_le_i32=row.mask_le_i32 }
    end
    -- these masks remain audit data. no bit-to-pair interpretation is applied
    -- the current default-all-collidable matrix is retained until independently
    -- qualified pair semantics are provided, name/ID import is a separate fix
    matrix.source_policy = {
        raw_data=desc.raw_data, raw_hex=desc.raw_hex, rows=rows,
        pair_interpretation="not-applied", pair_semantics_inferred=false,
        source_pair_collidability_qualified=false,
        native_collision_semantics_verified=false,
        historical_collision_parity_verified=false,
    }
    return matrix
end
function CollisionGroups:reset()
    self.groups, self.blocked, self.blocked_count = { [DEFAULT_GROUP] = true }, {}, 0
    self.public_ids, self.public_names, self.public_count = { [DEFAULT_GROUP] = 0 }, { [0] = DEFAULT_GROUP }, 1
    self.source_policy = nil
end
return CollisionGroups
