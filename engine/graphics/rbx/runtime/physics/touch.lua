-- Listener-scoped sensor contacts. Physics manifolds deliberately exclude
-- CanCollide=false parts, Touched must still see those trigger volumes
local Queries = runtime_require("physics/queries.lua")
local Narrowphase = runtime_require("physics/narrowphase.lua")
local CFrameMath = runtime_require("physics/cframe_math.lua")
local Touch = {}
local ca, cb, va, vb, contact = {}, {}, {}, {}, {}

local function collider(out, view, part)
    local cf = part.CFrame
    view.Size, view.Shape, view.ClassName = part.Size, part.Shape, part.ClassName
    view._nc_cached = nil
    return Narrowphase.make_collider(out, view, cf.x, cf.y, cf.z, CFrameMath.to_quat(cf))
end

function Touch.collect(core, world, current, previous, queue, key_for)
    local listeners = core._touch_listener_ids
    if not listeners then return end
    local scratch = core._touch_query_scratch or {}
    core._touch_query_scratch = scratch
    local opts = core._touch_query_opts or { ignore_can_query = true }
    core._touch_query_opts = opts
    local tested = {}
    for id, part in pairs(listeners) do
        if type(part) ~= "table" or part._destroyed or part._physics_excluded then
            listeners[id] = nil
        elseif part.CanTouch ~= false then
            -- Anchored sensors cannot generate anchored/anchored touches
            -- reject those candidates before their per-part bounds calculation
            opts.exclude_anchored = part.Anchored == true
            local minx, miny, minz, maxx, maxy, maxz = Queries.part_world_aabb(part)
            local found, count = core:_physics_region_parts(minx, miny, minz, maxx, maxy, maxz, opts, scratch)
            local source_ready = false
            for i = 1, count do
                local other = found[i]
                if other ~= part and other.CanTouch ~= false and not other._destroyed
                    and not (part.Anchored and other.Anchored) then
                    local key = key_for(id, other._id)
                    local group_ok = not core._workspace_touches_use_collision_groups
                        or world.collision_groups:collidable(part.CollisionGroup, other.CollisionGroup)
                    if not current[key] and not tested[key] and group_ok then
                        tested[key] = true
                        if not source_ready then collider(ca, va, part); source_ready = true end
                        collider(cb, vb, other)
                        if Narrowphase.collide(ca, cb, contact) > 0 then
                            local pair = previous[key] or { a = part, b = other }
                            current[key] = pair
                            if not previous[key] then
                                queue[#queue + 1] = { a = part, b = other, phase = "Touched" }
                            end
                        end
                    end
                end
            end
        end
    end
    for i = #scratch, 1, -1 do scratch[i] = nil end
end

return Touch
