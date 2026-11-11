-- union-find over rigid-joint edges -> assemblies (clumps), picks root, aggregates mass/com/inertia
-- topology only, never moves parts. no edges = every part a singleton

local Body = runtime_require("physics/body.lua")
local Materials = runtime_require("physics/materials.lua")

local Assembly = {}

local function position_of(part)
    local p = part and part.Position or nil
    return p and (p.x or p.X) or 0,
        p and (p.y or p.Y) or 0,
        p and (p.z or p.Z) or 0
end

-- rootpriority, then anchored, then lowest id
local function choose_root_part(parts)
    local best = nil
    for index = 1, #parts do
        local part = parts[index]
        if best == nil then
            best = part
        else
            local best_priority = tonumber(best.RootPriority) or 0
            local part_priority = tonumber(part.RootPriority) or 0
            if part_priority > best_priority then
                best = part
            elseif part_priority == best_priority then
                local best_anchored = best.Anchored == true
                local part_anchored = part.Anchored == true
                if part_anchored and not best_anchored then
                    best = part
                elseif part_anchored == best_anchored then
                    if (tonumber(part.id) or math.huge) < (tonumber(best.id) or math.huge) then
                        best = part
                    end
                end
            end
        end
    end
    return best
end

local function aggregate_props(members, root_part)
    local anchored = false
    local total_mass = 0
    local cx, cy, cz = 0, 0, 0
    for index = 1, #members do
        local part = members[index]
        if part.Anchored == true then
            anchored = true
        end
        local mass = Materials.assembly_mass_of(part, part == root_part)
        local px, py, pz = position_of(part)
        total_mass = total_mass + mass
        cx = cx + px * mass
        cy = cy + py * mass
        cz = cz + pz * mass
    end
    if total_mass > 0 then
        cx, cy, cz = cx / total_mass, cy / total_mass, cz / total_mass
    else
        -- all-massless: com = root pos
        local root = choose_root_part(members)
        cx, cy, cz = position_of(root)
    end
    return anchored, total_mass, cx, cy, cz
end

-- parts: {id,size,position,anchored,cancollide,massless,customphysicalproperties,rootpriority}, opts.edges: {a=id,b=id}
function Assembly.build(parts, opts)
    opts = opts or {}
    parts = parts or {}
    local edges = opts.edges or {}

    local parent = {}
    local parts_by_id = {}
    for index = 1, #parts do
        local part = parts[index]
        if part and part.id ~= nil then
            parent[part.id] = part.id
            parts_by_id[part.id] = part
        end
    end

    local function find(id)
        local root = parent[id]
        if root == nil then
            return id
        end
        if root ~= id then
            root = find(root)
            parent[id] = root
        end
        return root
    end

    local function union(a, b)
        if a == nil or b == nil or parent[a] == nil or parent[b] == nil then
            return
        end
        local ra, rb = find(a), find(b)
        if ra ~= rb then
            if tostring(ra) < tostring(rb) then
                parent[rb] = ra
            else
                parent[ra] = rb
            end
        end
    end

    for index = 1, #edges do
        local edge = edges[index]
        if edge then
            union(edge.a, edge.b)
        end
    end

    -- group by root, keep discovery order
    local groups = {}
    local group_order = {}
    for index = 1, #parts do
        local part = parts[index]
        if part and part.id ~= nil then
            local root = find(part.id)
            local group = groups[root]
            if not group then
                group = {}
                groups[root] = group
                group_order[#group_order + 1] = root
            end
            group[#group + 1] = part
        end
    end

    local result = {
        assemblies = {},
        assemblies_by_id = {},
        part_to_assembly = {},
        bodies = {},
    }

    for order_index = 1, #group_order do
        local members = groups[group_order[order_index]]
        local root_part = choose_root_part(members)
        local assembly_id = (root_part and root_part.id) or group_order[order_index]

        local anchored, total_mass, cx, cy, cz = aggregate_props(members, root_part)

        local inertia_x, inertia_y, inertia_z = 0, 0, 0
        if root_part and not anchored then
            local inertia = #members == 1 and Materials.part_inertia or Materials.box_inertia
            inertia_x, inertia_y, inertia_z = inertia(root_part, total_mass)
        end

        local body = Body.new({
            id = assembly_id,
            is_static = anchored,
            parts = members,
            part_count = #members,
            mass = total_mass,
            inertia_x = inertia_x,
            inertia_y = inertia_y,
            inertia_z = inertia_z,
            com_x = cx, com_y = cy, com_z = cz,
            -- Rotation locking remains owned by the existing assembly root
            rotation_locked = root_part ~= nil and root_part.RotationLocked == true,
        })

        local assembly = {
            id = assembly_id,
            parts = members,
            part_count = #members,
            root_part = root_part,
            anchored = anchored,
            mass = total_mass,
            com_x = cx, com_y = cy, com_z = cz,
            body = body,
        }
        body.assembly = assembly

        result.assemblies[#result.assemblies + 1] = assembly
        result.assemblies_by_id[assembly_id] = assembly
        result.bodies[#result.bodies + 1] = body
        for index = 1, #members do
            result.part_to_assembly[members[index].id] = assembly
        end
    end

    return result
end

-- in place, doesnt re-group parts
function Assembly.recompute_mass(assembly)
    if not assembly then
        return
    end
    local members = assembly.parts or {}
    local anchored, total_mass, cx, cy, cz = aggregate_props(members, assembly.root_part)
    assembly.anchored = anchored
    assembly.mass = total_mass
    assembly.com_x, assembly.com_y, assembly.com_z = cx, cy, cz

    local body = assembly.body
    if body then
        body.is_static = anchored
        body.kind = anchored and "static" or "dynamic"
        body.com_x, body.com_y, body.com_z = cx, cy, cz
        local ix, iy, iz = 0, 0, 0
        if assembly.root_part and not anchored then
            local inertia = #members == 1 and Materials.part_inertia or Materials.box_inertia
            ix, iy, iz = inertia(assembly.root_part, total_mass)
        end
        -- re-read: the view may have been refreshed in place since bind
        body.rotation_locked = assembly.root_part ~= nil
            and assembly.root_part.RotationLocked == true
        body:set_mass_properties(total_mass, ix, iy, iz)
    end
end

return Assembly
