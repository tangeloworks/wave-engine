local suite = { needs_graphics = true }
local rbx = require("engine/graphics/rbx")
local V, C = rbx.Vector3, rbx.CFrame

local function with_world(fn)
    local game = assert(rbx.new({ simulate_physics = true, physics_budget_ms = 0,
        allow_remote_assets = false, quality = "balanced", follow_display_settings = false }))
    local ok, err = xpcall(function()
        game.Workspace.Gravity = 100
        local function part(properties)
            properties.Parent = game.Workspace
            properties.TopSurface = rbx.Enum.SurfaceType.Smooth
            properties.BottomSurface = rbx.Enum.SurfaceType.Smooth
            return game.Instance.new("Part", properties)
        end
        part({ Name = "Ground", Anchored = true, Size = V.new(200, 2, 80), CFrame = C.new(0, -1, 0) })
        local actor = part({ Name = "Actor", Anchored = false, Size = V.new(2, 2, 2), CFrame = C.new(0, 1, 0) })
        local visual = part({ Name = "Limb", Anchored = true, Size = V.new(2, 4, 6),
            CanCollide = false, CanQuery = false, CanTouch = false, CFrame = C.new(64, 20, 0) })
        game:update(1 / 60)
        local core = game._core
        local physics = assert(core._physics_world)
        assert(physics.assemblies_built and not physics.assembly_dirty)
        local raw = assert(rawget(visual, "_core_handle"))
        local assembly = assert(physics.part_to_assembly[raw._id])
        local actor_raw = assert(rawget(actor, "_core_handle"))
        local actor_body = assert(physics.part_to_assembly[actor_raw._id].body)
        fn(game, core, physics, visual, raw, assembly, actor, actor_body)
    end, debug.traceback)
    game:Destroy()
    assert(ok, err)
end

local function only(part, respect)
    local params = rbx.RaycastParams.new()
    params.FilterType = rbx.Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { part }
    params.RespectCanCollide = respect == true
    return params
end

local function near(actual, expected, message)
    assert(math.abs(actual - expected) < 1e-8, message .. ": " .. tostring(actual))
end

function suite.run(t)
    t.describe("decorative singleton pose publication", function()
        t.it("moves current bounds without mass, contact or unrelated sleep work", function()
            with_world(function(game, core, physics, visual, raw, assembly, actor, actor_body)
                local body, view = assembly.body, assembly.parts[1]
                local old_size, old_mass = view.Size, body.mass
                local actor_frame, actor_velocity = actor.CFrame, actor.Velocity
                physics:park_body(actor_body)
                assert(actor_body.sleeping and physics.broadphase.sleeping_proxies[actor_body.id])
                local contact_clears = physics.contact_cache_clears_from_filter_change or 0
                local collision_dirty = physics.collision_dirty
                local mass_calls = 0
                local set_mass = body.set_mass_properties
                body.set_mass_properties = function(self, ...)
                    mass_calls = mass_calls + 1
                    return set_mass(self, ...)
                end
                -- A quarter turn swaps X/Y extents. The sleeper is inside the
                -- visual's wake bounds, but this part could never support it.
                visual.CFrame = C.new(0, 3, 0, 0, -1, 0, 1, 0, 0, 0, 0, 1)
                assert(physics.part_to_assembly[raw._id] == assembly and assembly.body == body)
                assert(assembly.parts[1] == view and view.Size == old_size)
                assert(body.mass == old_mass and mass_calls == 0, "rigid pose recomputed mass/inertia")
                assert((physics.contact_cache_clears_from_filter_change or 0) == contact_clears,
                    "noninteracting pose cleared contacts")
                assert(physics.collision_dirty == collision_dirty and not physics.assembly_dirty)
                assert(actor_body.sleeping, "decorative motion woke an unrelated sleeper")
                assert(actor.CFrame == actor_frame and actor.Velocity == actor_velocity,
                    "visual publication changed the collision body")
                assert(view.CFrameRef == raw.CFrame)
                near(view.Position.x, 0, "view x"); near(view.Position.y, 3, "view y")
                near(visual.AssemblyCenterOfMass.Y, 3, "public COM")
                near(body.com_y, 3, "body COM")
                local proxy = assert(physics.broadphase.static_proxies[assembly.id])
                local expected = { -2, 2, -3, 2, 4, 3 }
                for i = 1, 6 do near(proxy.aabb[i], expected[i], "proxy extent " .. i) end
                assert(proxy.members[1][7] == view, "proxy lost its current member view")
                visual.Position = V.new(4, 6, 0)
                near(physics.broadphase.static_proxies[assembly.id].aabb[1], 2, "Position proxy x")
                near(physics.broadphase.static_proxies[assembly.id].aabb[5], 7, "Position proxy y")
                assert(mass_calls == 0 and actor_body.sleeping)
                body.set_mass_properties = nil
            end)
        end)
        t.it("invalidates cached ray cells and honors later CanQuery changes immediately", function()
            with_world(function(game, core, physics, visual)
                local params = only(visual)
                visual.CanQuery = true
                local hit = game.Workspace:Raycast(V.new(64, 30, 0), V.new(0, -20, 0), params)
                assert(hit and hit.Instance == visual)
                near(hit.Distance, 8, "initial ray distance")
                visual.CanQuery = false
                visual.CFrame = C.new(96, 30, 0, 0, -1, 0, 1, 0, 0, 0, 0, 1)
                assert(game.Workspace:Raycast(V.new(96, 40, 0), V.new(0, -20, 0), params) == nil)
                visual.CanQuery = true
                assert(game.Workspace:Raycast(V.new(64, 30, 0), V.new(0, -20, 0), params) == nil,
                    "old cached ray cell retained the moved visual")
                hit = game.Workspace:Raycast(V.new(96, 40, 0), V.new(0, -20, 0), params)
                assert(hit and hit.Instance == visual, "CanQuery enabled against stale spatial bounds")
                near(hit.Distance, 9, "rotated ray distance"); near(hit.Position.Y, 31, "rotated ray height")
                visual.CanQuery = false
                visual.Position = V.new(-64, 15, 0)
                visual.CanQuery = true
                hit = game.Workspace:Raycast(V.new(-64, 25, 0), V.new(0, -20, 0), params)
                assert(hit and hit.Instance == visual); near(hit.Distance, 9, "Position ray distance")
            end)
        end)
        t.it("refreshes same-cell static bounds and cached ray slabs in place", function()
            with_world(function(game, core, physics, visual, raw, assembly)
                visual.CanQuery = true
                local params = only(visual)
                local initial = game.Workspace:Raycast(V.new(63.05, 30, 0), V.new(0, -20, 0), params)
                assert(initial and initial.Instance == visual, "initial same-cell ray missed")
                local bp = physics.broadphase
                local proxy = assert(bp.static_proxies[assembly.id])
                local cells = #proxy.cells
                local refreshed = bp.static_same_cell_refresh_count or 0
                -- The 2x4x6 visual remains in the same x/y/z 32-stud cell spans.
                visual.Position = V.new(64.3, 20, 0)
                proxy = assert(bp.static_proxies[assembly.id])
                assert(#proxy.cells == cells, "same-cell pose rewrote static membership")
                assert((bp.static_same_cell_refresh_count or 0) == refreshed + 1,
                    "same-cell singleton did not use the bounded proxy refresh")
                assert(game.Workspace:Raycast(V.new(63.05, 30, 0), V.new(0, -20, 0), params) == nil,
                    "cached ray slab retained old same-cell bounds")
                local moved = game.Workspace:Raycast(V.new(65.2, 30, 0), V.new(0, -20, 0), params)
                assert(moved and moved.Instance == visual, "same-cell ray slab missed new bounds")
            end)
        end)

        t.it("publishes the moved collider before CanCollide is enabled", function()
            with_world(function(game, core, physics, visual, raw, assembly, actor)
                visual.CFrame = C.new(0, 2, 0)
                visual.CanCollide = true
                visual.CanQuery = true
                local hit = game.Workspace:Raycast(V.new(0, 10, 0), V.new(0, -12, 0), only(visual, true))
                assert(hit and hit.Instance == visual); near(hit.Position.Y, 4, "enabled collider top")
                actor.CFrame = C.new(0, 8, 0)
                actor.Velocity = V.new()
                -- Isolate collider publication from balancing a rotating cube
                -- on an equally narrow ledge; rolling is tested independently.
                core:_set_runtime_part_rotation_locked(rawget(actor,"_core_handle"),true)
                for _ = 1, 90 do game:update(1 / 60) end
                -- This checks publication of the moved support, not exact PGS
                -- settling depth on a platform the same width as the actor.
                assert(actor.Position.Y > 4.9 and actor.Position.Y < 5.15,
                    "actor did not land on the latest visual collider: " .. actor.Position.Y)
                assert(physics.part_to_assembly[raw._id] == assembly)
            end)
        end)
        t.it("retains geometry refresh for Size and publishes queryable rigid poses in place", function()
            with_world(function(game, core, physics, visual, raw, assembly)
                local old_mass = assembly.body.mass
                visual.Size = V.new(4, 4, 6)
                near(assembly.body.mass, old_mass * 2, "resized mass")
                assert(assembly.parts[1].Size == raw.Size, "resized view is stale")
                local proxy = assert(physics.broadphase.static_proxies[assembly.id])
                near(proxy.aabb[1], 62, "resized proxy minimum")
                near(proxy.aabb[4], 66, "resized proxy maximum")
                visual.CanQuery = true
                visual.CFrame = C.new(80, 20, 0)
                assert(not physics.assembly_dirty and physics.part_to_assembly[raw._id] == assembly,
                    "queryable rigid pose rebuilt unchanged topology")
                local hit = game.Workspace:Raycast(V.new(80, 30, 0), V.new(0, -20, 0), only(visual))
                assert(hit and hit.Instance == visual); near(hit.Distance, 8, "queryable pose distance")
            end)
        end)
        t.it("keeps compound and kinematic assemblies on their existing fallback", function()
            with_world(function(game, core, physics, visual, raw, assembly)
                -- Exercise the guard with an actual two-member rigid assembly.
                local companion = game.Instance.new("Part", { Name = "Companion", Anchored = true,
                    CanCollide = false, CanQuery = false, CanTouch = false,
                    Size = V.new(1, 1, 1), CFrame = C.new(66, 20, 0), Parent = game.Workspace })
                -- Runtime joint registration uses the same supported core seam
                -- as physics_follower_publication_spec; the Instance facade only
                -- publishes lifecycle changes for already registered joints.
                local companion_raw = assert(rawget(companion, "_core_handle"))
                local weld = core:_add_physics_joint("WeldConstraint", raw, companion_raw)
                game:update(1 / 60)
                local compound = assert(physics.part_to_assembly[raw._id])
                assert(#compound.parts == 2, "fixture did not build a compound")
                visual.Position = V.new(65, 20, 0)
                assert(physics.assembly_dirty, "compound pose incorrectly took singleton path")
                game:update(1 / 60)
                assert(core:_remove_physics_joint(weld))
                -- Only an unanchored follower needs exclusion from integration.
                -- Anchored RotateV followers correctly retain static bodies.
                visual.Anchored = false
                local rotate = core:_add_physics_joint("RotateV", companion_raw, raw,
                    { c0 = C.new(), c1 = C.new() })
                rotate.surface_input, rotate.param_b = 11, 2
                game:update(1 / 60)
                local singleton = assert(physics.part_to_assembly[raw._id])
                assert(#singleton.parts == 1 and singleton.body.kinematic,
                    "fixture did not build a kinematic follower")
                visual.Position = V.new(67, 20, 0)
                assert(physics.assembly_dirty, "kinematic pose incorrectly took decorative path")
            end)
        end)
    end)
end

return suite
