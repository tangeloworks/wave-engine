-- Bind newly constructed Weld facades to the existing rigid-joint primitive
-- imported joints already own descriptors and are deliberately not registered
-- twice. this module owns only explicit Instance.new("Weld") instances
local Weld = {}
local keys = {Part0 = true, Part1 = true, C0 = true, C1 = true, Enabled = true}

local function in_workspace(node)
    while node do
        if rawget(node, "_destroyed") then return false end
        if rawget(node, "_class_name") == "Workspace" then return true end
        node = rawget(node, "_parent")
    end
    return false
end

function Weld.is_instance(node) return rawget(node, "_runtime_weld") == true end

local function enabled(node)
    local p = rawget(node, "_properties")
    return not rawget(node, "_destroyed") and p.Enabled ~= false and in_workspace(node)
        and p.Part0 and p.Part1 and p.Part0 ~= p.Part1
        and in_workspace(p.Part0) and in_workspace(p.Part1)
        and rawget(p.Part0, "_core_handle") and rawget(p.Part1, "_core_handle")
end

local function unwatch(node)
    local core = rawget(node, "_core")
    for part in pairs(rawget(node, "_runtime_weld_watched") or {}) do
        local list = core._runtime_weld_by_part and core._runtime_weld_by_part[part]
        if list then
            list[node] = nil
            if not next(list) then core._runtime_weld_by_part[part] = nil end
        end
    end
    rawset(node, "_runtime_weld_watched", {})
end

local function watch(node)
    unwatch(node)
    local core, p = rawget(node, "_core"), rawget(node, "_properties")
    core._runtime_weld_by_part = core._runtime_weld_by_part or {}
    for _,key in ipairs({"Part0", "Part1"}) do
        local part = p[key]
        if part then
            local list = core._runtime_weld_by_part[part] or {}
            core._runtime_weld_by_part[part] = list
            list[node] = true
            rawget(node, "_runtime_weld_watched")[part] = true
        end
    end
end

local function align_component(adjacency, part)
    local queue, visited, at = {part}, {[part] = true}, 1
    while at <= #queue do
        local from = queue[at]
        at = at + 1
        for joint in pairs(adjacency[from] or {}) do
            if enabled(joint) then
                local p = rawget(joint, "_properties")
                local to = from == p.Part0 and p.Part1 or p.Part0
                if not visited[to] then
                    visited[to] = true
                    local c0, c1 = p.C0 or CFrame.new(), p.C1 or CFrame.new()
                    to.CFrame = from == p.Part0 and from.CFrame * c0 * c1:Inverse()
                        or from.CFrame * c1 * c0:Inverse()
                    queue[#queue + 1] = to
                end
            end
        end
    end
end

-- apply a frame edit to a connected component once, before the solver rebuilds
-- its mass/offset snapshot. Simulation publication never invokes this path
-- every part CFrame write reaches the early returns below, so this function
-- owns no closure (closure upvalue close is not JIT-compilable)
local function align_from(part)
    local core = rawget(part, "_core")
    if not core or core._runtime_weld_aligning then return end
    local adjacency = core._runtime_weld_by_part
    if not adjacency or not adjacency[part] then return end
    core._runtime_weld_aligning = true
    local ok, err = pcall(align_component, adjacency, part)
    core._runtime_weld_aligning = nil
    if not ok then error(err, 0) end
end

local function alignment_origin(part)
    local core = rawget(part, "_core")
    local adjacency = core and core._runtime_weld_by_part or {}
    local queue, visited, at = {part}, {[part] = true}, 1
    while at <= #queue do
        local from = queue[at]
        at = at + 1
        if from.Anchored then return from end
        for joint in pairs(adjacency[from] or {}) do
            if enabled(joint) then
                local p = rawget(joint, "_properties")
                local to = from == p.Part0 and p.Part1 or p.Part0
                if not visited[to] then visited[to] = true; queue[#queue + 1] = to end
            end
        end
    end
    return part
end

local function sync(node, align)
    local core = rawget(node, "_core")
    if not core or not core._add_physics_joint then return end
    local old = rawget(node, "_runtime_weld_record")
    if old then core:_remove_physics_joint(old); rawset(node, "_runtime_weld_record", nil) end
    if not enabled(node) then return end
    local p = rawget(node, "_properties")
    if align or not old then
        align_from(alignment_origin(p.Part0))
    end
    local record = core:_add_physics_joint("Weld", rawget(p.Part0, "_core_handle"),
        rawget(p.Part1, "_core_handle"), {name = node.Name, c0 = p.C0, c1 = p.C1})
    rawset(node, "_runtime_weld_record", record)
end

function Weld.initialize(node)
    if rawget(node, "_class_name") ~= "Weld" then return end
    rawset(node, "_runtime_weld", true)
    local core, p = rawget(node, "_core"), rawget(node, "_properties")
    core._runtime_weld_instances = core._runtime_weld_instances or {}
    core._runtime_weld_instances[node] = true
    p.C0, p.C1, p.Enabled = CFrame.new(), CFrame.new(), true
end

function Weld.clone_property(source, clone, key, value)
    if not Weld.is_instance(source) or not keys[key] then return false end
    -- these are immutable value types or Instance references, not arbitrary
    -- DOM tables. Endpoint references are remapped after the whole tree exists
    rawget(clone, "_properties")[key] = value
    return true
end

function Weld.finish_clones(clones)
    for source, clone in pairs(clones) do
        if Weld.is_instance(source) then
            local p = rawget(clone, "_properties")
            p.Part0 = clones[p.Part0] or p.Part0
            p.Part1 = clones[p.Part1] or p.Part1
            watch(clone)
        end
    end
end

function Weld.write(node, key, value)
    if not Weld.is_instance(node) or not keys[key] then return false end
    if key == "Part0" or key == "Part1" then
        if value ~= nil and (type(value) ~= "table" or not rawget(value, "_core_handle")
            or rawget(value, "_datamodel") ~= rawget(node, "_datamodel")) then
            error(key .. " must be a BasePart in this DataModel or nil", 3)
        end
    elseif key == "Enabled" then
        if type(value) ~= "boolean" then error("Weld.Enabled must be boolean", 3) end
    else
        if getmetatable(value) ~= CFrame then error("Weld." .. key .. " must be CFrame", 3) end
        for _,lane in ipairs({"x","y","z","r00","r01","r02","r10","r11","r12","r20","r21","r22"}) do
            local number = value[lane]
            if type(number) ~= "number" or number ~= number or math.abs(number) == math.huge then
                error("Weld." .. key .. " must be finite", 3)
            end
        end
    end
    local p = rawget(node, "_properties")
    if p[key] == value then return true end
    p[key] = value
    watch(node)
    sync(node, true)
    return true
end

function Weld.ancestry_changed(node, subtree)
    local core = rawget(node, "_core")
    if not core or not core._runtime_weld_instances then return end
    -- only the moved joints/endpoints can change activation. Unrelated UI or
    -- decorative reparenting must not rescan map constraints or wake bodies
    local affected, adjacency = {}, core._runtime_weld_by_part or {}
    for _,member in ipairs(subtree or {node}) do
        if Weld.is_instance(member) then affected[member] = true end
        for joint in pairs(adjacency[member] or {}) do affected[joint] = true end
    end
    for joint in pairs(affected) do
        local was_active = rawget(joint, "_runtime_weld_record") ~= nil
        local is_active = enabled(joint) and true or false
        if was_active ~= is_active then sync(joint, false) end
    end
end

function Weld.part_transform_changed(node)
    align_from(node)
end

function Weld.destroy(node)
    if not Weld.is_instance(node) then return false end
    local core, record = rawget(node, "_core"), rawget(node, "_runtime_weld_record")
    if record and core._remove_physics_joint then core:_remove_physics_joint(record) end
    rawset(node, "_runtime_weld_record", nil)
    unwatch(node)
    if core._runtime_weld_instances then core._runtime_weld_instances[node] = nil end
    return true
end

return Weld
