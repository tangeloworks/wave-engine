-- Runtime selection for validated v4+ mesh LOD ranges. The decoder owns the
-- streams; this suite pins projected-size policy, hysteresis, bounded scanning,
-- and the no-resize bounds invariant used by MeshPart transforms.

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

local function lod_mesh()
    local bounds = {
        min_x = -2, min_y = -1, min_z = -0.5,
        max_x = 2, max_y = 1, max_z = 0.5,
    }
    local base = {
        source_kind = "mesh",
        bounds = bounds,
        lod_metadata = {
            runtime_selection_supported = true,
            runtime_selection_enabled = true,
        },
        positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 },
        normals = { 0, 0, 1, 0, 0, 1, 0, 0, 1 },
        uvs = { 0, 0, 1, 0, 0, 1 },
    }
    base.render_lods = {
        { positions = base.positions, bounds = bounds },
        {
            source_kind = "mesh",
            bounds = bounds,
            positions = { 0, 0, 0, 0.5, 0, 0, 0, 0.5, 0 },
            normals = { 0, 0, 1, 0, 0, 1, 0, 0, 1 },
            uvs = { 0, 0, 1, 0, 0, 1 },
        },
        {
            source_kind = "mesh",
            bounds = bounds,
            positions = { 0, 0, 0, 0.25, 0, 0, 0, 0.25, 0 },
            normals = { 0, 0, 1, 0, 0, 1, 0, 0, 1 },
            uvs = { 0, 0, 1, 0, 0, 1 },
        },
    }
    return base
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end

    local RBX = harness.env.RBX
    local expect = t.expect

    t.describe("mesh projected LOD policy", function()
        t.it("maps Automatic, Performance, and Precise with stable hysteresis", function()
            expect(RBX._compute_mesh_render_lod_index(
                220, 3, "automatic", nil, 180, 0.15)):to_be(1)
            expect(RBX._compute_mesh_render_lod_index(
                100, 3, "automatic", nil, 180, 0.15)):to_be(2)
            expect(RBX._compute_mesh_render_lod_index(
                40, 3, "automatic", nil, 180, 0.15)):to_be(3)
            expect(RBX._compute_mesh_render_lod_index(
                200, 3, "performance", nil, 180, 0.15)):to_be(2)
            expect(RBX._compute_mesh_render_lod_index(
                0, 3, "precise", 3, 180, 0.15)):to_be(1)

            -- Boundary is 180px: [153,207] retains the current side.
            expect(RBX._compute_mesh_render_lod_index(
                160, 2, "automatic", 1, 180, 0.15)):to_be(1)
            expect(RBX._compute_mesh_render_lod_index(
                150, 2, "automatic", 1, 180, 0.15)):to_be(2)
            expect(RBX._compute_mesh_render_lod_index(
                200, 2, "automatic", 2, 180, 0.15)):to_be(2)
            expect(RBX._compute_mesh_render_lod_index(
                210, 2, "automatic", 2, 180, 0.15)):to_be(1)
        end)

        t.it("selects a compact stream without changing authoritative bounds", function()
            local base = lod_mesh()
            local part = {
                RenderFidelity = "Automatic",
                _runtime_dynamic = true,
            }
            local core = {
                enable_mesh_lod = true,
                mesh_lod_threshold_pixels = 180,
                mesh_lod_hysteresis = 0.15,
                _estimate_mesh_projected_pixels = function()
                    return 40
                end,
                _desired_mesh_render_lod = RBX._desired_mesh_render_lod,
            }
            local selected = RBX._select_mesh_render_lod(core, part, base)
            expect(selected):to_be(base.render_lods[3])
            expect(part._mesh_lod_index):to_be(3)
            expect(selected.bounds):to_be(base.bounds)

            part.RenderFidelity = "Precise"
            selected = RBX._select_mesh_render_lod(core, part, base)
            expect(selected):to_be(base)
            expect(part._mesh_lod_index):to_be(1)
        end)

        t.it("keeps untouched loaded statics precise instead of destroying batching", function()
            local base = lod_mesh()
            local part = {
                _loaded_from_map = true,
                Anchored = true,
                RenderFidelity = "Performance",
            }
            local core = {
                enable_mesh_lod = true,
                mesh_lod_threshold_pixels = 180,
                mesh_lod_hysteresis = 0.15,
                _estimate_mesh_projected_pixels = function() return 1 end,
                _desired_mesh_render_lod = RBX._desired_mesh_render_lod,
            }
            expect(RBX._select_mesh_render_lod(core, part, base)):to_be(base)
            expect(part._mesh_lod_index):to_be_nil()
            expect(part._mesh_lod_base_mesh):to_be_nil()
        end)

        t.it("refuses retained streams without validated publication metadata", function()
            local base = lod_mesh()
            base.lod_metadata = nil
            local part = {
                RenderFidelity = "Performance",
                _runtime_dynamic = true,
                _mesh_lod_base_mesh = base,
                _mesh_lod_count = 3,
                _mesh_lod_index = 3,
            }
            local core = {
                enable_mesh_lod = true,
                _estimate_mesh_projected_pixels = function() return 1 end,
            }
            expect(RBX._select_mesh_render_lod(core, part, base)):to_be(base)
            expect(part._mesh_lod_base_mesh):to_be_nil()
            expect(part._mesh_lod_count):to_be_nil()
            expect(part._mesh_lod_index):to_be_nil()
        end)

        t.it("drops stale decoded LOD ownership on nil resolution and remote unbind", function()
            local old_graph = lod_mesh()
            local part = {
                _mesh_lod_base_mesh = old_graph,
                _mesh_lod_count = 3,
                _mesh_lod_index = 2,
                _mesh_lod_fidelity = "automatic",
                _mesh_lod_projected_pixels = 40,
            }
            local nil_core = {
                _resolve_part_mesh = function() return nil end,
            }
            expect(RBX._get_or_parse_part_mesh(nil_core, part)):to_be_nil()
            expect(part._mesh_lod_base_mesh):to_be_nil()
            expect(part._mesh_lod_count):to_be_nil()
            expect(part._mesh_lod_index):to_be_nil()
            expect(part._mesh_lod_fidelity):to_be_nil()
            expect(part._mesh_lod_projected_pixels):to_be_nil()

            local handle = { variant_key = "7|mesh|render" }
            part._remote_mesh_handle = handle
            part._remote_mesh_variant_key = handle.variant_key
            part._mesh_lod_base_mesh = old_graph
            part._mesh_lod_count = 3
            part._mesh_lod_index = 2
            local unbound_consumer
            local unbind_core = {
                _remote_mesh_manager = {
                    unbind = function(_, seen_handle, consumer)
                        expect(seen_handle):to_be(handle)
                        unbound_consumer = consumer
                        return true
                    end,
                },
            }
            expect(RBX._unbind_remote_mesh_consumer(unbind_core, part))
                :to_be(true)
            expect(unbound_consumer):to_be(part)
            expect(part._remote_mesh_handle):to_be_nil()
            expect(part._remote_mesh_variant_key):to_be_nil()
            expect(part._mesh_lod_base_mesh):to_be_nil()
            expect(part._mesh_lod_count):to_be_nil()
            expect(part._mesh_lod_index):to_be_nil()
        end)

        t.it("invalidates a bounded scan when an LOD-capable part moves", function()
            local part = {
                _id = 9,
                _mesh_lod_count = 3,
                _runtime_dynamic = true,
            }
            local core = { _mesh_lod_view_revision = 7 }
            RBX._mark_runtime_part_transform_dirty(core, part)
            expect(core._mesh_lod_view_revision):to_be(8)
            expect(core._mesh_lod_rescan_pending):to_be(true)
            expect(core._transform_dirty_parts[9]):to_be(part)
        end)

        t.it("scans a large prefix incrementally and eventually reaches the tail", function()
            local parts = {}
            for index = 1, 299 do
                parts[index] = { _id = index }
            end
            local base = lod_mesh()
            local tail = {
                _id = 300,
                _mesh_lod_base_mesh = base,
                _mesh_lod_count = 3,
                _mesh_lod_index = 1,
                _runtime_dynamic = true,
                RenderFidelity = "Automatic",
            }
            parts[300] = tail
            local promoted = 0
            local core = {
                enable_mesh_lod = true,
                parts = parts,
                mesh_lod_scans_per_frame = 64,
                mesh_lod_switches_per_frame = 2,
                _mesh_lod_scan_cursor = 1,
                _mesh_lod_scan_completed_revision = -1,
                _mesh_lod_view_revision = 0,
                _mesh_lod_rescan_pending = true,
                is_map_loading = function() return false end,
                _desired_mesh_render_lod = function(_, _, _, current)
                    return current == 1 and 3 or current, 20
                end,
                _promote_remote_mesh_part_incrementally = function(_, part)
                    promoted = promoted + 1
                    expect(part):to_be(tail)
                    return true
                end,
            }

            for _ = 1, 5 do
                RBX._update_mesh_render_lods(core)
                expect(core._mesh_lod_last_scan_count <= 64):to_be(true)
            end
            expect(promoted):to_be(1)
            expect(tail._mesh_lod_index):to_be(3)
            expect(core._mesh_lod_scan_completed_revision):to_be(0)
        end)
    end)
end

return suite
