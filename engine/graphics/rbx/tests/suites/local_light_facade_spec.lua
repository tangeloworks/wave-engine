-- Public PointLight / SpotLight / SurfaceLight lifecycle and their live
-- renderer-grid ownership bridge.

local suite = {}
suite.needs_graphics = true

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
    "geometry.lua",
    "assets.lua",
    "render.lua",
}

local function contains(values, wanted)
    for index = 1, #values do
        if values[index] == wanted then return true end
    end
    return false
end

local function count_keys(values)
    local count = 0
    for _ in pairs(values or {}) do count = count + 1 end
    return count
end

local function make_fixture(RBX)
    local core = setmetatable({
        parts = {},
        constraints = {},
        _loaded_part_count = 0,
        _runtime_part_storage_initialized = true,
        _runtime_live_part_count = 0,
        _next_part_id = 1,
        _part_proxy_by_id = {},
        _runtime_part_by_id = {},
        _runtime_part_by_name = {},
        _runtime_part_by_referent = {},
        _transform_dirty_parts = {},
        _appearance_promoted_parts = {},
        _appearance_promoted_count = 0,
        _debug_dirty_marks = { full = 0, transform = 0 },

        enable_local_lights = true,
        max_lights_per_batch = 4,
        local_light_grid_cell_size = 64,
        local_light_cluster_supercell_span = 2,
        local_lights = {},
        local_light_count = 0,
        local_light_invalid_count = 0,
        local_light_shadow_request_count = 0,
        _local_light_revision = 5,
        _local_light_grid_revision = 5,
        _local_light_grid = {},
        _local_lights_by_part_id = {},
        _local_light_stats = {},
        _instanced_mesh_requires_light_partition = false,
        _instanced_mesh_light_partition_size = 128,
    }, { __index = RBX })
    core._refresh_runtime_part_mass = function() end
    core._refresh_physics_part_registration = function() end
    core._invalidate_settled_merge_for_part = function() end
    core._remove_dynamic_scene_chunk_for_part = function() return true end
    core._gui_bridge_link_datamodel = function() end
    local game = core:_create_datamodel_public({})
    return game, core
end

local function new_part(game, CFrame, name)
    return game._instance_api.new("Part", {
        Name = name or "LightCarrier",
        CFrame = CFrame,
        Size = { X = 4, Y = 2, Z = 6 },
        Anchored = true,
        Parent = game.Workspace,
    })
end

local function reset_scene_dirty(core)
    core._parts_dirty = false
    core._parts_dirty_mode = nil
    core._transform_dirty_parts = {}
    core._debug_dirty_marks = { full = 0, transform = 0 }
end

function suite.run(t, harness)
    for index = 1, #RUNTIME_MODULES do
        harness.runtime_require(RUNTIME_MODULES[index])
    end
    local RBX = harness.env.RBX
    local CFrame = harness.env.CFrame
    local Color3 = harness.env.Color3
    local Vector3 = harness.env.Vector3
    local expect = t.expect

    t.describe("Local Light DataModel facade", function()
        t.it("exposes native hierarchy, defaults, bounded types, and support lists", function()
            local game, core = make_fixture(RBX)
            local point = game._instance_api.new("PointLight")
            local spot = game._instance_api.new("SpotLight")
            local surface = game._instance_api.new("SurfaceLight")
            local attachment = game._instance_api.new("Attachment")

            expect(point:IsA("PointLight")):to_be(true)
            expect(point:IsA("Light")):to_be(true)
            expect(point:IsA("Instance")):to_be(true)
            expect(spot:IsA("Light")):to_be(true)
            expect(surface:IsA("Light")):to_be(true)
            expect(attachment:IsA("Attachment")):to_be(true)
            expect(point.Enabled):to_be(true)
            expect(point.Brightness):to_be(1)
            expect(point.Color):to_be(Color3.new(1, 1, 1))
            expect(point.Range):to_be(8)
            expect(point.Shadows):to_be(false)
            expect(point.Angle):to_be_nil()
            expect(point.Face):to_be_nil()
            expect(spot.Range):to_be(16)
            expect(spot.Angle):to_be(90)
            expect(spot.Face):to_be(RBX.Enum.NormalId.Front)
            expect(surface.Angle):to_be(90)
            expect(surface.Face):to_be(RBX.Enum.NormalId.Front)
            expect(attachment.CFrame):to_be(CFrame.new())
            expect(attachment.Position):to_be(Vector3.zero)

            point.Brightness = 100
            point.Range = -5
            spot.Angle = 250
            spot.Face = RBX.Enum.NormalId.Top
            point.Color = Color3.new(2, -1, 0.25)
            expect(point.Brightness):to_be(40)
            expect(point.Range):to_be(0)
            expect(spot.Angle):to_be(180)
            expect(spot.Face):to_be(RBX.Enum.NormalId.Top)
            expect(point.Color):to_be(Color3.new(1, 0, 0.25))
            expect(#core.local_lights):to_be(0)

            expect(function() point.Enabled = 1 end):to_error("must be boolean")
            expect(function() point.Brightness = 0 / 0 end):to_error("finite number")
            expect(function() point.Color = { math.huge, 0, 0 } end):to_error("finite Color3")
            expect(function() spot.Face = "Diagonal" end):to_error("valid NormalId")
            expect(function() point.Angle = 30 end):to_error("not a valid property")

            expect(contains(game._instance_api.GetSupportedClasses(),
                "PointLight")):to_be(true)
            expect(contains(core:_build_instance_api().GetSupportedClasses(),
                "SpotLight")):to_be(true)
            expect(contains(RBX.Instance.GetSupportedClasses(),
                "SurfaceLight")):to_be(true)
            expect(contains(RBX.Instance.GetSupportedClasses(),
                "Attachment")):to_be(true)
            expect(point:GetPropertySchema().Color):to_be("Color3")
        end)

        t.it("binds one live entry and mutates only the light grid revision", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, CFrame.new(10, 20, 30))
            local handle = rawget(part, "_core_handle")
            local point = game._instance_api.new("PointLight")
            reset_scene_dirty(core)
            local revision = core._local_light_revision

            point.Parent = part
            expect(#core.local_lights):to_be(1)
            expect(core.local_light_count):to_be(1)
            expect(core._local_light_revision):to_be(revision + 1)
            expect(core._local_light_grid_revision):to_be(revision + 1)
            expect(count_keys(core._local_light_grid) > 0):to_be(true)
            local entry = core.local_lights[1]
            expect(rawget(point, "_local_light_entry")):to_be(entry)
            expect(entry.parent_part):to_be(handle)
            expect(entry.x):to_be(10)
            expect(entry.y):to_be(20)
            expect(entry.z):to_be(30)
            expect(core._local_lights_by_part_id[handle._id][1]):to_be(entry)
            expect(core._parts_dirty):to_be(false)

            revision = core._local_light_revision
            point.Brightness = 1
            point.Color = Color3.new(1, 1, 1)
            point.Enabled = true
            expect(core._local_light_revision):to_be(revision)
            expect(core._local_light_grid_revision):to_be(revision)

            point.Brightness = 2.5
            expect(core._local_light_revision):to_be(revision + 1)
            expect(entry.brightness):to_be(2.5)
            expect(core._parts_dirty):to_be(false)
            revision = core._local_light_revision
            point.Shadows = true
            expect(core.local_light_shadow_request_count):to_be(1)
            expect(core._local_light_revision):to_be(revision + 1)

            revision = core._local_light_revision
            point.Enabled = false
            expect(core.local_light_count):to_be(0)
            expect(count_keys(core._local_light_grid)):to_be(0)
            expect(core._local_lights_by_part_id[handle._id]):to_be_nil()
            expect(core._local_light_revision):to_be(revision + 1)
            point.Enabled = true
            expect(core.local_light_count):to_be(1)
            expect(core._local_lights_by_part_id[handle._id][1]):to_be(entry)

            revision = core._local_light_revision
            part.CFrame = CFrame.new(140, 3, -7)
            core:_mark_local_lights_dirty_for_parts({ handle })
            core:_update_dirty_local_lights()
            expect(core._local_light_revision):to_be(revision + 1)
            expect(entry.x):to_be(140)
            expect(entry.y):to_be(3)
            expect(entry.z):to_be(-7)
            expect(core._local_light_grid_revision):to_be(
                core._local_light_revision)
        end)

        t.it("tracks Attachment transforms and reparents without stale bindings", function()
            local game, core = make_fixture(RBX)
            local first = new_part(game, CFrame.new(0, 0, 0), "First")
            local second = new_part(game, CFrame.new(100, 0, 0), "Second")
            local first_handle = rawget(first, "_core_handle")
            local second_handle = rawget(second, "_core_handle")
            local attachment = game._instance_api.new("Attachment", {
                Position = Vector3.new(2, 3, 4),
                Parent = first,
            })
            local spot = game._instance_api.new("SpotLight", {
                Face = RBX.Enum.NormalId.Front,
                Parent = attachment,
            })
            local entry = rawget(spot, "_local_light_entry")
            expect(entry.parent_kind):to_be("Attachment")
            expect(entry.parent_part):to_be(first_handle)
            expect(entry.x):to_be(2)
            expect(entry.y):to_be(3)
            expect(entry.z):to_be(4)

            local revision = core._local_light_revision
            attachment.Position = Vector3.new(2, 3, 4)
            expect(core._local_light_revision):to_be(revision)
            attachment.Position = Vector3.new(8, 9, 10)
            expect(core._local_light_revision):to_be(revision + 1)
            expect(entry.x):to_be(8)
            expect(entry.y):to_be(9)
            expect(entry.z):to_be(10)

            revision = core._local_light_revision
            attachment.Parent = second
            expect(core._local_light_revision):to_be(revision + 1)
            expect(entry.parent_part):to_be(second_handle)
            expect(entry.x):to_be(108)
            expect(core._local_lights_by_part_id[first_handle._id]):to_be_nil()
            expect(core._local_lights_by_part_id[second_handle._id][1])
                :to_be(entry)

            local folder = game._instance_api.new("Folder", {
                Parent = second,
            })
            revision = core._local_light_revision
            attachment.Parent = folder
            expect(core._local_light_revision):to_be(revision + 1)
            expect(core.local_light_count):to_be(0)
            expect(#core.local_lights):to_be(0)
            spot.Brightness = 4
            expect(core._local_light_revision):to_be(revision + 1)

            attachment.Parent = first
            expect(#core.local_lights):to_be(1)
            expect(core.local_light_count):to_be(1)
            expect(core.local_lights[1]):to_be(entry)
            expect(entry.brightness):to_be(4)
            revision = core._local_light_revision
            attachment:Destroy()
            expect(core.local_light_count):to_be(0)
            expect(#core.local_lights):to_be(0)
            expect(core._local_light_revision):to_be(revision + 1)
            expect(rawget(spot, "_destroyed")):to_be(true)
        end)

        t.it("reparents SurfaceLight modes and clones value-owned entries", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, CFrame.new(0, 0, 0))
            local attachment = game._instance_api.new("Attachment", {
                CFrame = CFrame.new(1, 2, 3) * CFrame.Angles(0, math.pi / 2, 0),
                Parent = part,
            })
            local surface = game._instance_api.new("SurfaceLight", {
                Brightness = 3,
                Range = 24,
                Angle = 70,
                Face = RBX.Enum.NormalId.Right,
                Color = Color3.new(0.1, 0.2, 0.3),
                Shadows = true,
                Parent = attachment,
            })
            local entry = rawget(surface, "_local_light_entry")
            local attachment_type = entry.type_id
            surface.Parent = part
            expect(entry.parent_kind):to_be("Part")
            t.assert_that(entry.type_id ~= attachment_type,
                "SurfaceLight kept its Attachment spot-type override")

            local clone = surface:Clone()
            expect(clone.Parent):to_be_nil()
            expect(clone.Brightness):to_be(3)
            expect(clone.Range):to_be(24)
            expect(clone.Angle):to_be(70)
            expect(clone.Face):to_be(RBX.Enum.NormalId.Right)
            expect(clone.Color):to_be(Color3.new(0.1, 0.2, 0.3))
            expect(clone.Shadows):to_be(true)
            t.assert_that(rawget(clone, "_local_light_entry") ~= entry,
                "clone shared the renderer entry")
            expect(#core.local_lights):to_be(1)

            surface.Color = Color3.new(0.8, 0.7, 0.6)
            expect(clone.Color):to_be(Color3.new(0.1, 0.2, 0.3))
            clone.Parent = part
            expect(#core.local_lights):to_be(2)
            expect(core.local_light_count):to_be(2)
            local clone_entry = rawget(clone, "_local_light_entry")
            t.assert_that(clone_entry.color ~= entry.color,
                "clone shared mutable renderer color storage")

            local revision = core._local_light_revision
            surface:Destroy()
            expect(#core.local_lights):to_be(1)
            expect(core.local_lights[1]):to_be(clone_entry)
            expect(core._local_light_revision):to_be(revision + 1)
            revision = core._local_light_revision
            surface:Destroy()
            expect(core._local_light_revision):to_be(revision)
        end)

        t.it("promotes the loaded facade onto the parsed entry revision-free", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, CFrame.new(12, 4, -6), "LoadedCarrier")
            local handle = rawget(part, "_core_handle")
            handle._map_referent = "RBX_P"
            core._runtime_part_by_referent.RBX_P = handle
            rawset(part, "_referent", "RBX_P")

            local parsed = RBX._make_local_light_entry("PointLight", {
                Name = "LoadedPoint",
                Referent = "RBX_L",
                Enabled = true,
                Brightness = 2.25,
                Color = { 0.2, 0.4, 0.6 },
                Range = 18,
                Shadows = true,
            })
            parsed.parent_kind = "Part"
            parsed.parent_class = "Part"
            parsed.parent_name = "LoadedCarrier"
            parsed.parent_part_index = handle._runtime_part_slot
            parsed.parent_referent = "RBX_P"
            core:_load_local_lights_from_parsed({ parsed }, 0)
            local loaded_entry = core.local_lights[1]
            local revision = core._local_light_revision
            local source_color = { 0.2, 0.4, 0.6 }

            game:_promote_instance_roots({ {
                ClassName = "Workspace",
                Name = "Workspace",
                Children = { {
                    ClassName = "Part",
                    Name = "LoadedCarrier",
                    Referent = "RBX_P",
                    CFrame = CFrame.new(12, 4, -6),
                    Size = { X = 4, Y = 2, Z = 6 },
                    Children = { {
                        ClassName = "PointLight",
                        Name = "LoadedPoint",
                        Referent = "RBX_L",
                        Enabled = true,
                        Brightness = 2.25,
                        Color = source_color,
                        Range = 18,
                        Shadows = true,
                        Children = {},
                    } },
                } },
            } })

            local promoted_part = game.Workspace:FindFirstChild("LoadedCarrier")
            local light = promoted_part:FindFirstChild("LoadedPoint")
            expect(rawget(light, "_local_light_entry")):to_be(loaded_entry)
            expect(#core.local_lights):to_be(1)
            expect(core.local_light_count):to_be(1)
            expect(core._local_light_revision):to_be(revision)
            expect(core._local_light_grid_revision):to_be(revision)
            expect(light.Brightness):to_be(2.25)
            expect(light.Color):to_be(Color3.new(0.2, 0.4, 0.6))
            source_color[1] = 1
            expect(light.Color.R):to_be(0.2)

            light.Range = 22
            expect(core._local_light_revision):to_be(revision + 1)
            expect(loaded_entry.range):to_be(22)
        end)

        t.it("repairs swap-moved runtime parent slots without a false revision", function()
            local game, core = make_fixture(RBX)
            local first = new_part(game, CFrame.new(0, 0, 0), "Disposable")
            local second = new_part(game, CFrame.new(50, 0, 0), "Survivor")
            local second_handle = rawget(second, "_core_handle")
            local point = game._instance_api.new("PointLight", {
                Parent = second,
            })
            local entry = rawget(point, "_local_light_entry")
            local old_slot = second_handle._runtime_part_slot
            local revision = core._local_light_revision
            t.assert_that(old_slot > 1, "fixture did not create a swappable suffix")

            first:Destroy()
            expect(second_handle._runtime_part_slot):to_be(1)
            expect(entry.parent_part_index):to_be(1)
            expect(entry.parent_part):to_be(second_handle)
            expect(core._local_light_revision):to_be(revision)
            entry.dirty = true
            core._local_lights_dirty = true
            core:_update_dirty_local_lights()
            expect(entry.parent_part):to_be(second_handle)
            expect(entry.x):to_be(50)
        end)

        t.it("retires a multi-light owner subtree with one grid transaction", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, CFrame.new(0, 0, 0), "ManyLights")
            game._instance_api.new("PointLight", { Parent = part })
            game._instance_api.new("SpotLight", { Parent = part })
            game._instance_api.new("SurfaceLight", { Parent = part })
            expect(#core.local_lights):to_be(3)
            expect(core.local_light_count):to_be(3)
            local revision = core._local_light_revision

            part:Destroy()
            expect(#core.local_lights):to_be(0)
            expect(core.local_light_count):to_be(0)
            expect(count_keys(core._local_light_grid)):to_be(0)
            expect(core._local_light_revision):to_be(revision + 1)
        end)
    end)
end

return suite
