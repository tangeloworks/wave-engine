-- one physical write path shared by current string and legacy numeric properties
local M = {}
function M.name(core, value)
    assert(type(value) == "string" and value ~= "", "Part.CollisionGroup must be a non-empty string")
    -- a property assignment is not a PhysicsService registration. Unknown
    -- names retain their string value and expose legacy ID -1
    return value
end
function M.name_for_id(core, id)
    local name = core:_get_collision_group_registry():name_for_id(id)
    assert(name ~= nil, "Part.CollisionGroupId is not a registered integer ID")
    return name
end
function M.get_id(core, part)
    local id = core:_get_collision_group_registry():id_for_name(part.CollisionGroup)
    return id ~= nil and id or -1
end
function M.set_name(core, part, value, invalidate)
    local name = M.name(core, value)
    if part.CollisionGroup == name then return true end
    part.CollisionGroup = name
    if invalidate then
        invalidate(part, "CollisionGroup")
        invalidate(part, "CollisionGroupId")
    end
    core:_on_runtime_part_collision_changed(part)
end
function M.set_id(core, part, id, invalidate)
    local name = M.name_for_id(core, id)
    return M.set_name(core, part, name, invalidate)
end
function M.set_passive(core, props, key, value)
    local name
    if key == "CollisionGroupId" then name = M.name_for_id(core, value)
    else name = M.name(core, value) end
    -- no core part, collider, wake, manifold or render allocation. Clone later
    -- uses the resolved named property with this same world registry
    props.CollisionGroup = name
    props.CollisionGroupId = M.get_id(core, props)
end
return M
