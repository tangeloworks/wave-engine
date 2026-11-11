-- Source-load-only admission and exact-owner rollback, no normal-play scan
local Data = runtime_require("physics/collision_group_data.lua")
local Groups = runtime_require("physics/collision_groups.lua")
local M = { SCHEMA = 3 }
local prepared = setmetatable({}, { __mode = "k" })
local transactions = setmetatable({}, { __mode = "k" })
local PART_CLASSES = {
    Part=true, MeshPart=true, WedgePart=true, CornerWedgePart=true,
    UnionOperation=true, PartOperation=true, TrussPart=true, Seat=true,
    VehicleSeat=true, SpawnLocation=true,
}
local function first(a, b) if a ~= nil then return a end; return b end
local function id_value(value)
    if value == nil then return 0 end
    assert(type(value) == "number" and value == value and value % 1 == 0
        and value >= 0 and value < 32, "Authored CollisionGroupId must be an integer in 0..31")
    return value
end
local function source_fields(source)
    return first(source.CollisionGroup, source.collisiongroup),
        first(source.CollisionGroupId, source.collisiongroupid)
end
local function resolve(matrix, present, modern, legacy)
    if modern ~= nil then
        assert(type(modern) == "string" and modern ~= "", "Authored CollisionGroup must be a non-empty string")
        -- modern explicit names take priority even when unregistered. Part
        -- assignment cannot create a service registration or consume an ID
        return modern
    end
    local id = id_value(legacy)
    if not present then matrix:register(id == 0 and "Default" or "Group" .. id, id) end
    local name = matrix:name_for_id(id)
    assert(name ~= nil, "Authored collision group ID absent from serialized policy: " .. id)
    return name
end
local function visit_sources(roots, fn, checkpoint)
    local visited = 0
    local function visit(node)
        if type(node) ~= "table" then return end
        if (SUPPORTED_PART_CLASSES or PART_CLASSES)[node.ClassName] then fn(node) end
        visited = visited + 1
        if checkpoint and visited % 256 == 0 then checkpoint("collision_groups:sources", visited) end
        for _, child in ipairs(node.Children or {}) do visit(child) end
    end
    for _, root in ipairs(roots or {}) do visit(root) end
end
function M.decorate(parts, settings)
    assert(type(parts) == "table", "Parsed parts array required")
    settings = settings or {}
    parts._collision_group_schema = M.SCHEMA
    parts._collision_group_data = settings.CollisionGroupData
    parts._touches_use_collision_groups = settings.TouchesUseCollisionGroups == true
end
function M.prepare_map(map, checkpoint)
    local parts = assert(map.parsed_parts, "Parsed parts required")
    assert(parts._collision_group_schema == M.SCHEMA, "Collision group cache schema absent; reparse original map")
    local settings = map.workspace_settings or {}
    assert(parts._collision_group_data == settings.CollisionGroupData, "Serialized group metadata disagreement")
    assert(parts._touches_use_collision_groups == (settings.TouchesUseCollisionGroups == true),
        "Serialized touch-policy metadata disagreement")
    local raw, desc = parts._collision_group_data
    local present = raw ~= nil
    local matrix
    if present then
        local reason
        desc, reason = Data.decode(raw)
        assert(desc, "Invalid present CollisionGroupData: " .. tostring(reason))
        matrix = Groups.from_descriptor(desc)
    else
        matrix = Groups.new()
    end
    -- only absent-data compatibility uses GroupN. Reserve every authored
    -- numeric ID before assigning explicit new string names, including RF
    -- templates, this is a load-only ordered source traversal, not world scan
    if not present then
        visit_sources(map.instance_roots, function(source)
            local modern, legacy = source_fields(source)
            if modern == nil then resolve(matrix, false, nil, legacy) end
        end, checkpoint)
        for _, part in ipairs(parts) do
            if part.collision_group_source_name == nil then
                resolve(matrix, false, nil, part.collision_group_legacy_id)
            end
        end
    end
    visit_sources(map.instance_roots, function(source)
        local modern, legacy = source_fields(source)
        resolve(matrix, present, modern, legacy)
    end, checkpoint)
    local resolved = {}
    for index, part in ipairs(parts) do
        resolved[index] = resolve(matrix, present,
            part.collision_group_source_name, part.collision_group_legacy_id)
        if checkpoint and index % 256 == 0 then checkpoint("collision_groups:parts", index, #parts) end
    end
    -- no world/registry publication on failure above, including partial decode,
    -- conflicting IDs, malformed layouts or absent authored numeric IDs
    for index, name in ipairs(resolved) do parts[index].collision_group = name end
    local token = {}
    prepared[token] = {
        matrix=matrix, descriptor=desc, raw=raw,
        present=present, touches=parts._touches_use_collision_groups,
    }
    return token
end
local function service_workspace(datamodel)
    local services = datamodel and rawget(datamodel, "_services_by_name")
    return services and services.Workspace
end
local function workspace_props(core, tx)
    if tx.workspace == nil then
        assert(tx.datamodel == nil and core._datamodel == nil,
            "Policy transaction has not claimed a newly created Workspace")
        return nil
    end
    assert(core._datamodel == tx.datamodel
        and service_workspace(core._datamodel) == tx.workspace
        and rawget(tx.workspace, "_destroyed") ~= true
        and rawget(tx.workspace, "_properties") == tx.workspace_props,
        "Policy transaction refuses replacement Workspace or property storage")
    return tx.workspace_props
end
function M.bind_workspace(core, workspace)
    local owner = core._collision_group_load
    if not owner then return end
    local tx = assert(transactions[owner], "Exact Workspace policy owner required")
    assert(tx.core == core and core._physics_world == tx.world and tx.committed
        and tx.world.collision_groups == tx.prepared.matrix,
        "Stale Workspace policy binding rejected")
    if tx.workspace == nil then
        -- Initial construction can have no DataModel at begin/commit. Claim
        -- only at its actual source Workspace merge, before incoming copy
        assert(tx.datamodel == nil and core._datamodel
            and rawget(workspace, "_datamodel") == core._datamodel
            and service_workspace(core._datamodel) == workspace,
            "Initial Workspace is not this owned source-merge service")
        tx.datamodel, tx.workspace = core._datamodel, workspace
        tx.workspace_props = rawget(workspace, "_properties")
        assert(type(tx.workspace_props) == "table", "Workspace property storage required")
        tx.old_raw = tx.workspace_props.CollisionGroupData
        tx.old_touches_property = tx.workspace_props.TouchesUseCollisionGroups
    end
    assert(workspace == tx.workspace, "Source-merge policy hook refuses a different Workspace")
    workspace_props(core, tx)
end
function M.begin(core, token)
    local p = assert(prepared[token], "Module-owned prepared policy required")
    assert(core._collision_group_load == nil, "Prior collision policy transaction still owned")
    local matrix = core:_get_collision_group_registry()
    local world = assert(core._physics_world)
    local workspace = service_workspace(core._datamodel)
    local props = workspace and rawget(workspace, "_properties")
    assert(workspace == nil or type(props) == "table", "Saved Workspace property storage required")
    local owner = {}
    transactions[owner] = {
        core=core, world=world, previous=matrix, prepared=p,
        datamodel=core._datamodel, workspace_props=props,
        old_source=core._collision_group_source,
        old_touches=core._workspace_touches_use_collision_groups,
        old_raw=props and props.CollisionGroupData,
        old_touches_property=props and props.TouchesUseCollisionGroups,
        workspace=workspace,
        committed=false,
    }
    prepared[token] = nil
    core._collision_group_load = owner
    return owner
end
function M.commit(core, owner)
    local tx = assert(transactions[owner], "Exact policy transaction required")
    assert(tx.core == core and core._collision_group_load == owner
        and core._physics_world == tx.world and tx.world.collision_groups == tx.previous
        and not tx.committed, "Stale policy commit rejected")
    local props = workspace_props(core, tx)
    tx.world.collision_groups = tx.prepared.matrix
    tx.world.collision_dirty = true
    core._workspace_touches_use_collision_groups = tx.prepared.touches
    if props then
        props.CollisionGroupData = tx.prepared.raw
        props.TouchesUseCollisionGroups = tx.prepared.touches
    end
    core._collision_group_source = {
        raw_data=tx.prepared.raw, policy_present=tx.prepared.present,
        names_and_ids_imported=tx.prepared.present,
        raw_rows=tx.prepared.matrix.source_policy and tx.prepared.matrix.source_policy.rows,
        pair_interpretation="not-applied", pair_semantics_inferred=false,
        source_pair_collidability_qualified=false,
        native_collision_semantics_verified=false,
        historical_collision_parity_verified=false,
    }
    tx.committed = true
end
function M.resolve_source(core, source)
    local matrix = core:_get_collision_group_registry()
    local modern, legacy = source_fields(source)
    local present = core._collision_group_source and core._collision_group_source.policy_present == true
    return resolve(matrix, present, modern, legacy)
end
function M.recovery_guard(core, owner)
    local tx = transactions[owner]
    local ok, reason = pcall(function()
        assert(tx and tx.core == core and core._collision_group_load == owner,
            "Recovery refuses a foreign or retired policy owner")
        assert(core._physics_world == tx.world,
            "Recovery refuses a replacement physical world")
        assert(tx.world.collision_groups == (tx.committed and tx.prepared.matrix or tx.previous),
            "Recovery refuses a replacement registry")
        workspace_props(core, tx)
    end)
    if not ok then
        -- never release a newer current owner. a failed load can retire only
        -- its saved module-owned ledger, even if another scope replaced it
        if tx and tx.core == core then
            if core._collision_group_load == owner then core._collision_group_load = nil end
            transactions[owner] = nil
        end
        return false, tostring(reason)
    end
    return true
end
function M.finish(core, owner)
    local tx = assert(transactions[owner], "Exact policy transaction required")
    assert(tx.core == core and core._collision_group_load == owner
        and core._physics_world == tx.world and tx.committed
        and tx.world.collision_groups == tx.prepared.matrix, "Stale policy finish rejected")
    workspace_props(core, tx)
    core._collision_group_load = nil
    transactions[owner] = nil
end
function M.retire(core, owner)
    local tx = transactions[owner]
    assert(core._tearing_down == true and tx and tx.core == core
        and core._collision_group_load == owner,
        "Only the exact tearing-down world can abandon its policy transaction")
    -- full-world teardown owns the physical world. release the preparation
    -- ledger without changing any replacement registry or restoring flags
    core._collision_group_load = nil
    transactions[owner] = nil
    assert(core._physics_world == tx.world,
        "Retired owned policy ledger, but physical world identity changed")
end

function M.rollback(core, owner)
    local tx = transactions[owner]
    assert(tx and tx.core == core and core._collision_group_load == owner,
        "Stale policy rollback rejected")
    local ok, props = pcall(function()
        assert(core._physics_world == tx.world, "Rollback refuses replacement physical world")
        assert(tx.world.collision_groups == (tx.committed and tx.prepared.matrix or tx.previous),
            "Rollback refuses replacement registry")
        return workspace_props(core, tx)
    end)
    if not ok then
        -- the owner ledger is ours, but the current service/world/storage is
        -- not. release only that exact ledger, report the failed rollback and
        -- permit a later explicit Retry, never publish into a replacement
        core._collision_group_load = nil
        transactions[owner] = nil
        error(props, 0)
    end
    tx.world.collision_groups = tx.previous
    tx.world.collision_dirty = true
    core._collision_group_source = tx.old_source
    core._workspace_touches_use_collision_groups = tx.old_touches
    -- map recovery retires the partial scene, not a reconstruction of its old
    -- generation. restore only this transaction's saved filter metadata
    if props then
        props.CollisionGroupData = tx.old_raw
        props.TouchesUseCollisionGroups = tx.old_touches_property
    end
    core._collision_group_load = nil
    transactions[owner] = nil
end
return M
