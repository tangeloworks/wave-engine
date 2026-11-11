-- Regression coverage for runtime-property no-ops and map-generation cleanup.
--
-- Replication/gameplay code frequently assigns the last observed value again.
-- These writes must not promote a static map part, mark the whole scene dirty,
-- invalidate render caches, or advance its render-property revision.

local suite = {}

suite.needs_graphics = true

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
}

local function make_part(CFrame)
    return {
        _id = 17,
        _destroyed = false,
        _loaded_from_map = true,
        _render_prop_revision = 41,
        Name = "IdempotentPart",
        ClassName = "MeshPart",
        Shape = "Block",
        CFrame = CFrame.new(10, 20, 30),
        Size = { x = 4, y = 5, z = 6 },
        Color = { r = 0.25, g = 0.5, b = 0.75 },
        Transparency = 0.25,
        Reflectance = 0.1,
        Anchored = true,
        Material = 256,
        TopSurface = "Smooth",
        TopSurfaceInput = 3,
        TopParamA = 0.5,
        MeshId = "rbxassetid://123",
        TextureContent = "rbxassetid://456",
        TextureId = nil,
        UsePartColor = true,
        DoubleSided = false,
        SmoothingAngle = 30,
        RenderFidelity = "Automatic",
        TriangleCount = 12,
        MaterialVariant = "VariantA",
    }
end

local function make_renderer()
    local renderer = {
        _parts_dirty = false,
        _parts_dirty_mode = nil,
        _debug_dirty_marks = { full = 0, transform = 0 },
        _static_release_attempts = 0,
    }
    renderer._release_static_part_geometry = function(self)
        self._static_release_attempts =
            self._static_release_attempts + 1
        return false
    end
    return renderer
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end

    local RBX = harness.env.RBX
    local CFrame = harness.env.CFrame
    local Vector3 = harness.env.Vector3
    local set_property = harness.env.set_runtime_part_property
    local expect = t.expect

    t.describe("runtime draw-property idempotency", function()
        t.it("does no dirty, promotion, cache, or revision work for effective no-ops", function()
            local part = make_part(CFrame)
            local renderer = make_renderer()
            local bounds_cache = { generation = "bounds" }
            local mesh_transform_cache = { generation = "mesh_transform" }

            local cases = {
                { "Shape", 1 },
                { "CFrame", part.CFrame:clone() },
                { "Position", Vector3.new(10, 20, 30) },
                { "Size", Vector3.new(4, 5, 6) },
                { "Color", { r = 0.25, g = 0.5, b = 0.75 } },
                { "Transparency", "0.25" },
                { "Reflectance", 0.1 },
                { "Anchored", true },
                { "Material", "256" },
                { "TopSurface", 0 },
                { "TopSurfaceInput", "3" },
                { "TopParamA", "0.5" },
                { "MeshId", "  rbxassetid://123  " },
                { "TextureContent", " rbxassetid://456 " },
                { "TextureId", "   " },
                { "UsePartColor", 1 },
                { "DoubleSided", false },
                { "SmoothingAngle", "30" },
                { "RenderFidelity", "Automatic" },
                { "TriangleCount", "12" },
                { "MaterialVariant", " VariantA " },
            }

            for index = 1, #cases do
                local property_name = cases[index][1]
                part._rb_cache = bounds_cache
                part._mesh_xf_cache = mesh_transform_cache

                expect(set_property(
                    renderer, part, property_name, cases[index][2]))
                    :to_be(true)
                expect(renderer._parts_dirty):to_be(false)
                expect(renderer._parts_dirty_mode):to_be_nil()
                expect(renderer._debug_dirty_marks.full):to_be(0)
                expect(renderer._debug_dirty_marks.transform):to_be(0)
                expect(renderer._static_release_attempts):to_be(0)
                expect(part._render_prop_revision):to_be(41)
                expect(part._rb_cache):to_be(bounds_cache)
                expect(part._mesh_xf_cache):to_be(mesh_transform_cache)
            end
        end)

        t.it("still dirties and invalidates once when the effective value changes", function()
            local part = make_part(CFrame)
            local renderer = make_renderer()
            part._rb_cache = {}
            part._mesh_xf_cache = {}

            expect(set_property(renderer, part, "Material", 512))
                :to_be(false)
            expect(part.Material):to_be(512)
            expect(renderer._parts_dirty):to_be(true)
            expect(renderer._parts_dirty_mode):to_be("full")
            expect(renderer._debug_dirty_marks.full):to_be(1)
            expect(renderer._static_release_attempts):to_be(1)
            expect(part._render_prop_revision):to_be(42)
            expect(part._rb_cache):to_be_nil()
            expect(part._mesh_xf_cache):to_be_nil()

            -- Replaying the new value must not queue a second full rebuild.
            expect(set_property(renderer, part, "Material", "512"))
                :to_be(true)
            expect(renderer._debug_dirty_marks.full):to_be(1)
            expect(renderer._static_release_attempts):to_be(1)
            expect(part._render_prop_revision):to_be(42)
        end)
    end)

    t.describe("runtime map-generation reset", function()
        t.it("drops every strong reference held by promotion/deferred state", function()
            local promoted = make_part(CFrame)
            promoted._mesh_lod_base_mesh = { render_lods = { {}, {} } }
            promoted._mesh_lod_count = 2
            promoted._mesh_lod_index = 2
            promoted._mesh_lod_fidelity = "automatic"
            local appearance = make_part(CFrame)
            appearance._id = 18
            appearance._appearance_dynamic = true
            promoted._runtime_part_slot = 1
            promoted._runtime_part_order_next = appearance
            appearance._runtime_part_slot = 2
            appearance._runtime_part_order_prev = promoted

            local core = {
                parts = { promoted, appearance },
                constraints = {},
                _next_part_id = 19,
                _promoted_loaded_parts = { [promoted._id] = promoted },
                _promoted_loaded_part_count = 1,
                _appearance_promoted_parts = {
                    [appearance._id] = appearance,
                },
                _appearance_promoted_count = 1,
                _transform_dirty_parts = {
                    [promoted._id] = promoted,
                },
                _settled_merge_pending = {
                    parts = { promoted, appearance },
                },
            }

            RBX._reset_runtime_parts(core)

            expect(promoted._destroyed):to_be(true)
            expect(appearance._destroyed):to_be(true)
            expect(#core.parts):to_be(0)
            expect(core._next_part_id):to_be(1)
            expect(core._promoted_loaded_parts):to_be_nil()
            expect(core._promoted_loaded_part_count):to_be(0)
            expect(core._appearance_promoted_parts):to_be_nil()
            expect(core._appearance_promoted_count):to_be(0)
            expect(next(core._transform_dirty_parts)):to_be_nil()
            expect(core._settled_merge_pending):to_be_nil()
            expect(promoted._mesh_lod_base_mesh):to_be_nil()
            expect(promoted._mesh_lod_count):to_be_nil()
            expect(promoted._mesh_lod_index):to_be_nil()
            expect(promoted._mesh_lod_fidelity):to_be_nil()
            expect(promoted._runtime_part_slot):to_be_nil()
            expect(promoted._runtime_part_order_next):to_be_nil()
            expect(appearance._runtime_part_slot):to_be_nil()
            expect(appearance._runtime_part_order_prev):to_be_nil()
        end)
    end)

    t.describe("dense runtime-part lifetime storage", function()
        t.it("stays bounded by live parts through 100000 destroys without reindexing loaded parts", function()
            local loaded_a = make_part(CFrame)
            loaded_a._id = 1
            loaded_a._loaded_part_index = 1
            loaded_a.Name = "LoadedA"
            loaded_a.CFrame = CFrame.new(1, 2, 3)

            local loaded_b = make_part(CFrame)
            loaded_b._id = 2
            loaded_b._loaded_part_index = 2
            loaded_b.Name = "LoadedB"
            loaded_b.CFrame = CFrame.new(10, 20, 30)

            local remote_unbind_count = 0
            local core = setmetatable({
                parts = { loaded_a, loaded_b },
                constraints = {},
                _loaded_part_count = 2,
                _runtime_part_storage_initialized = true,
                _runtime_live_part_count = 0,
                _runtime_part_storage_peak_slots = 0,
                _runtime_part_storage_removal_count = 0,
                _next_part_id = 3,
                _part_proxy_by_id = {},
                _runtime_part_by_id = {
                    [loaded_a._id] = loaded_a,
                    [loaded_b._id] = loaded_b,
                },
                _runtime_part_by_name = {
                    [loaded_a.Name] = loaded_a,
                    [loaded_b.Name] = loaded_b,
                },
                _runtime_part_by_referent = {},
                _transform_dirty_parts = {},
                _appearance_promoted_parts = {},
                _appearance_promoted_count = 0,
                _debug_dirty_marks = { full = 0, transform = 0 },
                flip_loaded_map_horizontally = false,
            }, { __index = RBX })

            -- Keep this focused on the storage seam while still exercising the
            -- production create/destroy entrypoints and all of their ownership
            -- cleanup.  GPU/datamodel/physics side effects are independently
            -- covered by their integration suites.
            core._refresh_runtime_part_mass = function() end
            core._refresh_physics_part_registration = function() end
            core._attach_runtime_part_to_datamodel = function() end
            core._invalidate_settled_merge_for_part = function() end
            -- datamodel.lua intentionally overrides the scene-only proxy
            -- factory when the full suite has already loaded it. Pin this
            -- focused core to the legacy explorer proxy contract under test.
            core._get_or_create_part_proxy = function(self, part)
                local cached = self._part_proxy_by_id[part._id]
                if cached then
                    rawset(cached, "_part", part)
                    return cached
                end
                local proxy = setmetatable({
                    _renderer = self,
                    _part = part,
                }, harness.env.part_proxy_mt)
                self._part_proxy_by_id[part._id] = proxy
                return proxy
            end
            core._remove_dynamic_scene_chunk_for_part = function()
                return true
            end
            core._unbind_remote_mesh_consumer = function()
                remote_unbind_count = remote_unbind_count + 1
            end
            core._part_explorer = setmetatable(
                { _renderer = core }, harness.env.part_explorer_mt)

            local first_id, first_proxy
            local churn_count = 100000
            for index = 1, churn_count do
                local part = core:_create_runtime_part("Part", {
                    Name = "Transient" .. tostring(index),
                })
                local proxy = core:_get_or_create_part_proxy(part)
                if index == 1 then
                    first_id = part._id
                    first_proxy = proxy
                end
                expect(core:_destroy_runtime_part(part)):to_be(true)
                expect(#core.parts):to_be(2)
            end

            local empty_stats = core:_get_runtime_part_storage_stats()
            expect(empty_stats.loaded_slot_count):to_be(2)
            expect(empty_stats.scan_slot_count):to_be(2)
            expect(empty_stats.runtime_dense_slot_count):to_be(0)
            expect(empty_stats.live_runtime_part_count):to_be(0)
            expect(empty_stats.runtime_explorer_order_count):to_be(0)
            expect(empty_stats.peak_runtime_slot_count):to_be(1)
            expect(empty_stats.runtime_removal_count):to_be(churn_count)
            expect(empty_stats.next_part_id):to_be(3 + churn_count)
            expect(core.parts[1]):to_be(loaded_a)
            expect(core.parts[2]):to_be(loaded_b)
            expect(core._part_proxy_by_id[first_id]):to_be_nil()
            expect(core._runtime_part_by_id[first_id]):to_be_nil()
            expect(next(core._transform_dirty_parts)):to_be_nil()
            expect(next(core._appearance_promoted_parts)):to_be_nil()
            expect(remote_unbind_count):to_be(churn_count)

            -- Dense swap-delete is intentionally independent from public
            -- explorer order.  Removing B moves C's storage slot but the facade
            -- remains LoadedA, LoadedB, A, C, D (creation order among runtimes).
            local part_a = core:_create_runtime_part("Part", { Name = "RuntimeA" })
            local proxy_a = core:_get_or_create_part_proxy(part_a)
            local part_b = core:_create_runtime_part("Part", { Name = "RuntimeB" })
            local proxy_b = core:_get_or_create_part_proxy(part_b)
            local part_c = core:_create_runtime_part("Part", { Name = "RuntimeC" })
            local proxy_c = core:_get_or_create_part_proxy(part_c)
            core._mesh_lod_scan_cursor = #core.parts + 1
            core._mesh_lod_rescan_pending = false
            local removed_slot = part_b._runtime_part_slot
            expect(core:_destroy_runtime_part(part_b)):to_be(true)
            expect(core._mesh_lod_scan_cursor):to_be(removed_slot)
            expect(core._mesh_lod_rescan_pending):to_be(true)
            local part_d = core:_create_runtime_part("Part", { Name = "RuntimeD" })
            local proxy_d = core:_get_or_create_part_proxy(part_d)

            local all = core._part_explorer:GetAll()
            expect(#all):to_be(5)
            expect(all[1].Name):to_be("LoadedA")
            expect(all[2].Name):to_be("LoadedB")
            expect(all[3]):to_be(proxy_a)
            expect(all[4]):to_be(proxy_c)
            expect(all[5]):to_be(proxy_d)
            expect(core._part_explorer:Get(3)):to_be(proxy_a)
            expect(core._part_explorer:Get(4)):to_be(proxy_c)
            expect(core._part_explorer:Get(5)):to_be(proxy_d)
            expect(proxy_b.Name):to_be_nil()
            expect(first_proxy.Name):to_be_nil()
            expect(first_proxy == proxy_a):to_be(false)
            expect(part_a._id > first_id):to_be(true)
            expect(part_c._id > part_b._id):to_be(true)
            expect(part_d._id > part_c._id):to_be(true)

            local x, y, z = core:_resolve_constraint_attachment_world_point({
                parent_part_index = 2,
                local_x = 1,
                local_y = 2,
                local_z = 3,
            })
            expect(x):to_be(11)
            expect(y):to_be(22)
            expect(z):to_be(33)
            expect(core.parts[2]):to_be(loaded_b)

            expect(core:_destroy_runtime_part(part_a)):to_be(true)
            expect(core:_destroy_runtime_part(part_c)):to_be(true)
            expect(core:_destroy_runtime_part(part_d)):to_be(true)
            local final_stats = core:_get_runtime_part_storage_stats()
            expect(final_stats.scan_slot_count):to_be(2)
            expect(final_stats.runtime_dense_slot_count):to_be(0)
            expect(final_stats.live_runtime_part_count):to_be(0)
            expect(final_stats.runtime_explorer_order_count):to_be(0)
            expect(core.parts[1]):to_be(loaded_a)
            expect(core.parts[2]):to_be(loaded_b)
            expect(remote_unbind_count):to_be(churn_count + 4)
        end)

        t.it("kill-plane core destruction retires the public DataModel facade", function()
            local remote_unbind_count = 0
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
            }, { __index = RBX })
            core._refresh_runtime_part_mass = function() end
            core._refresh_physics_part_registration = function() end
            core._invalidate_settled_merge_for_part = function() end
            core._remove_dynamic_scene_chunk_for_part = function()
                return true
            end
            core._unbind_remote_mesh_consumer = function()
                remote_unbind_count = remote_unbind_count + 1
            end

            local game = core:_create_datamodel_public({})
            local instance = game._instance_api.new("Part", {
                Name = "FallingPart",
                Parent = game.Workspace,
            })
            local part = rawget(instance, "_core_handle")
            local part_id = part._id
            local destroying_count = 0
            instance.Destroying:Connect(function()
                destroying_count = destroying_count + 1
            end)

            expect(#core.parts):to_be(1)
            expect(game._instance_by_core_id[part_id]):to_be(instance)
            expect(core:_destroy_runtime_part(part)):to_be(true)
            expect(instance._destroyed):to_be(true)
            expect(part._destroyed):to_be(true)
            expect(destroying_count):to_be(1)
            expect(game._instance_by_core_id[part_id]):to_be_nil()
            expect(core._runtime_part_by_id[part_id]):to_be_nil()
            expect(#core.parts):to_be(0)
            expect(core._runtime_part_order_head):to_be_nil()
            expect(core._runtime_part_order_tail):to_be_nil()
            expect(remote_unbind_count):to_be(1)
            expect(core:_destroy_runtime_part(part)):to_be(false)
            expect(remote_unbind_count):to_be(1)
        end)
    end)
end

return suite
