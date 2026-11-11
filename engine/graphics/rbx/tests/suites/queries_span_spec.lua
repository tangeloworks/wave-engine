-- Bounded reference comparisons for existing spatial-hash truncation regimes.
-- Known bugs are reported separately from passes; after a fix, promote them to it().
local suite = {}

function suite.run(t, h)
    local World = h.need('physics/world.lua')
    local Assembly = h.need('physics/assembly.lua')
    local Queries = h.need('physics/queries.lua')
    local records = require('engine/graphics/rbx/tests/profile_record')
    local evidence = {scope = 'bounded indexed queries versus the unchanged linear exact-shape query', cases = {}}

    local function part(id, x, y, z, sx, sy, sz, anchored)
        local cf = {x = x, y = y, z = z, r00 = 1, r01 = 0, r02 = 0,
            r10 = 0, r11 = 1, r12 = 0, r20 = 0, r21 = 0, r22 = 1}
        local p = {_id = id, ClassName = 'Part', Shape = 'Block', CanCollide = true,
            CanQuery = true, Anchored = anchored ~= false, CFrame = cf, Size = {x = sx, y = sy, z = sz}}
        local view = {id = id, _part = p, ClassName = p.ClassName, Shape = p.Shape,
            CanCollide = true, Anchored = p.Anchored, Size = p.Size, CFrameRef = cf,
            Position = {x = x, y = y, z = z}}
        return p, view
    end

    local function make(parts, views, edges)
        local world = World.new({enabled = true, collision_enabled = true, budget_ms = 0})
        world:set_assemblies(Assembly.build(views, {edges = edges}))
        world:ensure_static_proxies(); world:refresh_active()
        for _, body in ipairs(world.active_bodies) do world.broadphase:upsert_dynamic(body) end
        return world
    end

    local function long_floor(compound)
        local floor_part, floor_view = part(1, 0, 0, 0, 8192, 2, 2)
        local parts, views, edges = {floor_part}, {floor_view}, {}
        if compound then
            -- These members occupy the queried CELL but not the query itself.
            -- The compound therefore reaches rg_visit_body even though the long
            -- floor's own broadphase registration stopped at the span cap.
            for id = 2, 64 do
                parts[id], views[id] = part(id, 3500, 0, 10, 1, 1, 1)
                edges[#edges + 1] = {a = 1, b = id}
            end
        end
        local world = make(parts, views, edges)
        assert(#world.bodies == 1 and #world.bodies[1].parts == #parts, 'fixture compound binding failed')
        return world, parts, floor_part
    end

    local function ray_check(name, compound, x)
        local world, parts, floor_part = long_floor(compound)
        local reference = Queries.raycast(nil, x, 5, 0, 0, -10, 0, {fallback_parts = parts})
        local indexed = Queries.raycast(world, x, 5, 0, 0, -10, 0, {fallback_parts = parts})
        assert(reference and reference.part == floor_part and reference.distance == 4, 'independent floor witness missed')
        evidence.cases[#evidence.cases + 1] = {name = name, members = #parts, x = x,
            reference_id = reference.part._id, indexed_id = indexed and indexed.part._id or false,
            reference_distance = reference.distance, indexed_distance = indexed and indexed.distance or false}
        world:reset()
        assert(indexed and indexed.part == reference.part and indexed.distance == reference.distance,
            'indexed ray lost the floor beyond its truncated cell registration')
    end

    local function contains(parts, n, expected)
        for i = 1, n do if parts[i] == expected then return true end end
        return false
    end

    t.describe('conservative query span coverage', function()
        t.it('matches the exact ray on the registered side of a long singleton and compound floor', function()
            ray_check('singleton_registered_side', false, -3500)
            ray_check('compound_registered_side', true, -3500)
        end)

        t.it('broadphase STATIC_MAX_SPAN' .. ': ' .. 'retains a long singleton floor at its unregistered positive end', function()
            ray_check('singleton_truncated_side', false, 3500)
        end)

        t.it('broadphase packed-cell STATIC_MAX_SPAN' .. ': ' .. 'retains the long member when another compound member makes its cell reachable', function()
            ray_check('compound_truncated_side', true, 3500)
        end)

        t.it('queries member_grid GRID_MAX_SPAN' .. ': ' .. 'retains a long compound member in a small region beyond its member-grid span', function()
            local world, parts, floor_part = long_floor(true)
            local reached = 0
            world.broadphase:collect_region(3499.75, -.25, -.25, 3500.25, .25, .25,
                function() reached = reached + 1 end)
            assert(reached == 1, 'fixture failed to isolate member-grid truncation from broadphase discovery')
            local reference, rn = Queries.region(nil, 3499.75, -.25, -.25, 3500.25, .25, .25, {fallback_parts = parts})
            local indexed, n = Queries.region(world, 3499.75, -.25, -.25, 3500.25, .25, .25, {fallback_parts = parts})
            assert(rn == 1 and contains(reference, rn, floor_part), 'linear region witness missed')
            evidence.cases[#evidence.cases + 1] = {name = 'compound_small_region', reached_bodies = reached,
                reference_count = rn, indexed_count = n, indexed_contains_floor = contains(indexed, n, floor_part)}
            world:reset()
            assert(contains(indexed, n, floor_part), 'member grid lost a part whose live AABB overlaps the region')
        end)

        t.it('broadphase QUERY_MAX_SPAN' .. ': ' .. 'retains a far singleton within a long thin region', function()
            local a, av = part(1, 0, 0, 0, 1, 1, 1)
            local b, bv = part(2, 9000, 0, 0, 1, 1, 1)
            local parts = {a, b}
            local world = make(parts, {av, bv})
            local reference, rn = Queries.region(nil, -1, -1, -1, 9001, 1, 1, {fallback_parts = parts})
            local indexed, n = Queries.region(world, -1, -1, -1, 9001, 1, 1, {fallback_parts = parts})
            assert(rn == 2 and contains(reference, rn, b), 'linear long-region witness missed')
            evidence.cases[#evidence.cases + 1] = {name = 'long_thin_region', reference_count = rn,
                indexed_count = n, indexed_contains_far = contains(indexed, n, b)}
            world:reset()
            assert(n == rn and contains(indexed, n, b), 'region traversal silently truncated its far endpoint')
        end)
    end)

    local path = os.getenv('RBX_QUERIES_SPAN_OUTPUT')
    if path and path ~= '' then
        local file = assert(io.open(path, 'wb')); file:write(records.encode(evidence)); file:close()
        print('[queries-span] evidence=' .. path)
    end
end

return suite
