-- Focused coverage for late-static remote mesh draw substitution.
--
-- The aggregate is deliberately derived: raw one-part chunks remain the
-- authoritative scene/BVH/resource owners and every build failure falls back
-- to those chunks without requesting a full scene rebuild.

local suite = {}

suite.needs_graphics = true

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
}

local function new_renderer(RBX)
    return setmetatable({
        dynamic_mesh_merge = true,
        enable_local_lights = false,
        local_light_count = 0,
        _instance_generation = 9,
        _local_light_revision = 4,
        _local_light_pack_configuration_signature = "lights:v1",
    }, { __index = RBX })
end

local function new_handle(revision)
    return {
        ready = true,
        result = {},
        revision = revision or 3,
        variant_key = "mesh|101|render",
        consumers = setmetatable({}, { __mode = "k" }),
        consumer_order = setmetatable({}, { __mode = "v" }),
        consumer_order_count = 0,
        consumer_bind_revision = {},
        consumer_result_revision = {},
        consumer_slots = setmetatable({}, { __mode = "k" }),
    }
end

local function bind_part(handle, part, result_revision)
    local slot = handle.consumer_order_count + 1
    handle.consumer_order_count = slot
    handle.consumers[part] = {}
    handle.consumer_order[slot] = part
    handle.consumer_slots[part] = slot
    handle.consumer_bind_revision[slot] = slot
    handle.consumer_result_revision[slot] = result_revision or 0
    part._remote_mesh_handle = handle
    part._remote_mesh_variant_key = handle.variant_key
    return slot
end

local function new_remote_part(id, handle)
    local part = {
        _id = id,
        _loaded_from_map = true,
        _appearance_dynamic = true,
        _render_prop_revision = 20 + id,
        _dynamic_dirty_revision = 30 + id,
        Anchored = true,
        ClassName = "MeshPart",
    }
    bind_part(handle, part, 0)
    return part
end

local function new_chunk(part, grid_x, batch_key, pack)
    local item = {
        mesh = {},
        vertex_count = 3,
        key = batch_key or "shared",
        source_kind = "Mesh",
        _test_light_pack = pack,
    }
    return {
        key = "__dynamic_part:" .. tostring(part._id),
        grid_x = grid_x or 0,
        grid_y = 0,
        grid_z = 0,
        dynamic_part = part,
        dynamic_part_id = part._id,
        dynamic_chunk = true,
        _settled_content_revision = 100 + part._id,
        textured_batches = { item },
        overlay_textured_batches = {},
        transparent_draw_items = {},
        surface_gui_batches = {},
        cube_instances = {},
        opaque_static_draw_items = {},
        has_transparent_geometry = false,
    }
end

local function member_count(members)
    local count = 0
    for _ in pairs(members or {}) do count = count + 1 end
    return count
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end

    local RBX = harness.env.RBX
    local expect = t.expect

    t.describe("settled remote merge planning", function()
        t.it("selects only bound, applied, opaque anchored remote chunks", function()
            local renderer = new_renderer(RBX)
            local handle = new_handle(5)
            handle._renderer_fanout_completed_revision = 5
            local first = new_remote_part(1, handle)
            local second = new_remote_part(2, handle)
            local first_chunk = new_chunk(first, 7, "same")
            local second_chunk = new_chunk(second, 7, "same")
            first._scene_chunk_key = first_chunk.key
            second._scene_chunk_key = second_chunk.key
            local raw = { first_chunk, second_chunk }

            local groups, members =
                renderer:_collect_settled_merge_plan(raw)
            expect(#groups):to_be(1)
            expect(member_count(members)):to_be(2)
            expect(members[first._id].part):to_be(first)
            expect(members[first._id].chunk):to_be(first_chunk)
            expect(members[first._id].chunk_revision)
                :to_be(first_chunk._settled_content_revision)
            expect(members[first._id].dirty_revision)
                :to_be(first._dynamic_dirty_revision)
            expect(members[first._id].render_revision)
                :to_be(first._render_prop_revision)
            expect(members[first._id].handle):to_be(handle)
            expect(members[first._id].handle_revision):to_be(5)
            expect(members[first._id].instance_generation):to_be(9)
            expect(groups[1].source_draw_count):to_be(2)
            expect(groups[1].batch_key_count):to_be(1)
            -- Planning is read-only and never steals authoritative ownership.
            expect(first._scene_chunk_key):to_be(first_chunk.key)
            expect(renderer._scene_chunk_map):to_be_nil()

            second._kinematic_dynamic = true
            groups, members = renderer:_collect_settled_merge_plan(raw)
            expect(#groups):to_be(0)
            expect(next(members)):to_be_nil()
            second._kinematic_dynamic = nil

            second_chunk.transparent_draw_items = { { kind = "textured" } }
            groups, members = renderer:_collect_settled_merge_plan(raw)
            expect(#groups):to_be(0)
            expect(next(members)):to_be_nil()
            second_chunk.transparent_draw_items = {}

            handle._renderer_fanout_completed_revision = nil
            groups, members = renderer:_collect_settled_merge_plan(raw)
            expect(#groups):to_be(0)
            expect(next(members)):to_be_nil()

            -- A consumer bound after publication is already using this result
            -- even when no renderer fanout walk was necessary.
            for slot = 1, handle.consumer_order_count do
                handle.consumer_result_revision[slot] = handle.revision
            end
            groups, members = renderer:_collect_settled_merge_plan(raw)
            expect(#groups):to_be(1)
            expect(member_count(members)):to_be(2)
        end)

        t.it("partitions by spatial cell and exact local-light payload", function()
            local renderer = new_renderer(RBX)
            renderer.enable_local_lights = true
            renderer.local_light_count = 2
            renderer._get_local_light_pack_for_item = function(_, item)
                return item._test_light_pack
            end
            local handle = new_handle(2)
            handle._renderer_fanout_completed_revision = 2
            local pack_a = { key = "pack-a", count = 0, ambient = { 0, 0, 0 } }
            local pack_b = { key = "pack-b", count = 0, ambient = { 0, 0, 0 } }
            local first = new_remote_part(11, handle)
            local second = new_remote_part(12, handle)
            local third = new_remote_part(13, handle)
            local chunks = {
                new_chunk(first, 4, "same", pack_a),
                new_chunk(second, 4, "same", pack_a),
                new_chunk(third, 4, "same", pack_b),
            }

            local groups, members =
                renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(1)
            expect(member_count(members)):to_be(2)
            expect(members[first._id] ~= nil):to_be(true)
            expect(members[second._id] ~= nil):to_be(true)
            expect(members[third._id]):to_be_nil()
            expect(groups[1].light_pack):to_be(pack_a)

            chunks[2].grid_x = 5
            groups, members = renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(0)
            expect(next(members)):to_be_nil()
        end)

        t.it("waits for simulated sleep before merging at high presentation rates", function()
            local renderer = new_renderer(RBX)
            local handle = new_handle(3)
            local p = new_remote_part(14, handle)
            p.Anchored = false
            local chunks = { new_chunk(p) }
            local body = { is_static = false, sleeping = true, _sleep_step = 100 }
            local world = { step_index = 100, config = { fixed_dt = 1/60 },
                part_to_assembly = { [14] = { body = body } } }
            renderer._physics_world = world
            -- A hundred presentation frames do not advance simulated sleep.
            for _ = 1, 100 do
                expect(#renderer:_collect_settled_merge_plan(chunks)):to_be(0)
            end
            world.step_index = 115
            expect(#renderer:_collect_settled_merge_plan(chunks)):to_be(1)
            body.sleeping = false
            expect(#renderer:_collect_settled_merge_plan(chunks)):to_be(0)
            body.sleeping, body._sleep_step = true, 115
            expect(#renderer:_collect_settled_merge_plan(chunks)):to_be(0)
        end)

        t.it("keeps physics sleepers in exact spatial local-light buckets", function()
            local renderer = new_renderer(RBX)
            renderer.enable_local_lights = true
            renderer.local_light_count = 6
            renderer._get_local_light_pack_for_item = function(_, item)
                return item._test_light_pack
            end
            local handle = new_handle(3)
            local pack_a = { key = "physics-a", count = 4 }
            local pack_b = { key = "physics-b", count = 4 }
            local first = new_remote_part(14, handle)
            local second = new_remote_part(15, handle)
            local third = new_remote_part(16, handle)
            local chunks = {
                new_chunk(first, 8, "same", pack_a),
                new_chunk(second, 8, "same", pack_a),
                new_chunk(third, 8, "same", pack_b),
            }
            renderer._physics_world = { part_to_assembly = {} }
            for _, part in ipairs({ first, second, third }) do
                renderer._physics_world.part_to_assembly[part._id] = {
                    body = { is_static = false, sleeping = true },
                }
            end

            local groups, members =
                renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(2)
            expect(member_count(members)):to_be(3)
            local by_pack = {}
            for index = 1, #groups do
                local group = groups[index]
                by_pack[group.light_pack] = #group.records
                for record_index = 1, #group.records do
                    local record = group.records[record_index]
                    expect(record.light_pack):to_be(group.light_pack)
                    expect(record.grid_x):to_be(group.grid_x)
                end
            end
            expect(by_pack[pack_a]):to_be(2)
            expect(by_pack[pack_b]):to_be(1)

            chunks[2].grid_x = 9
            groups = renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(3)

            renderer.enable_local_lights = false
            renderer.local_light_count = 0
            groups = renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(2)
            for index = 1, #groups do
                local group = groups[index]
                for record_index = 1, #group.records do
                    expect(group.records[record_index].grid_x)
                        :to_be(group.grid_x)
                end
            end
        end)

        t.it("enforces per-group and whole-plan work caps", function()
            local renderer = new_renderer(RBX)
            renderer.settled_merge_max_group_parts = 2
            renderer.settled_merge_max_total_groups = 2
            renderer.settled_merge_max_total_parts = 20
            renderer.settled_merge_max_total_vertices = 100
            local handle = new_handle(7)
            handle._renderer_fanout_completed_revision = 7
            local chunks = {}
            for id = 21, 26 do
                chunks[#chunks + 1] = new_chunk(
                    new_remote_part(id, handle), 1, "same")
            end

            local groups, members =
                renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(2)
            expect(#groups[1].records):to_be(2)
            expect(#groups[2].records):to_be(2)
            expect(member_count(members)):to_be(4)
            expect(members[25]):to_be_nil()
            expect(members[26]):to_be_nil()
        end)

        t.it("bounds raw scanning and candidate materialization", function()
            local renderer = new_renderer(RBX)
            renderer.settled_merge_max_scan_chunks = 32
            renderer.settled_merge_max_candidate_records = 128
            renderer.settled_merge_max_group_parts = 4
            renderer.settled_merge_max_total_parts = 12
            local handle = new_handle(9)
            handle._renderer_fanout_completed_revision = 9
            local chunks = {}
            for id = 1001, 1256 do
                chunks[#chunks + 1] = new_chunk(
                    new_remote_part(id, handle), 1, "same")
            end

            local _, members = renderer:_collect_settled_merge_plan(chunks)
            expect(renderer._settled_merge_last_scan_count):to_be(32)
            expect(renderer._settled_merge_last_candidate_count):to_be(32)
            expect(renderer._settled_merge_last_scan_truncated):to_be(true)
            expect(renderer._settled_merge_max_observed_scan_count):to_be(32)
            expect(member_count(members)):to_be(12)

            renderer.settled_merge_max_scan_chunks = 64
            renderer.settled_merge_max_candidate_records = 12
            renderer:_collect_settled_merge_plan(chunks)
            expect(renderer._settled_merge_last_scan_count):to_be(12)
            expect(renderer._settled_merge_last_candidate_count):to_be(12)
            expect(renderer._settled_merge_last_scan_truncated):to_be(true)
            expect(renderer._settled_merge_max_observed_scan_count):to_be(32)
        end)

        t.it("advances bounded windows past an ineligible prefix", function()
            local renderer = new_renderer(RBX)
            renderer.settled_merge_max_scan_chunks = 16
            renderer.settled_merge_max_candidate_records = 16
            local handle = new_handle(10)
            handle._renderer_fanout_completed_revision = 10
            local chunks = {}
            for id = 2001, 2020 do
                local part = new_remote_part(id, handle)
                if id <= 2016 then part._kinematic_dynamic = true end
                chunks[#chunks + 1] = new_chunk(part, 3, "same")
            end

            local groups, members =
                renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(0)
            expect(next(members)):to_be_nil()
            expect(renderer._settled_merge_last_scan_count):to_be(16)
            expect(renderer._settled_merge_scan_cursor):to_be(17)

            groups, members = renderer:_collect_settled_merge_plan(chunks)
            expect(#groups):to_be(1)
            expect(member_count(members)):to_be(4)
            expect(renderer._settled_merge_last_scan_count):to_be(16)
            expect(renderer._settled_merge_scan_cursor):to_be(17)

            -- The selected window remains stable while the eight-frame token
            -- gate observes it; it does not rotate a committed plan every frame.
            local again_groups, again_members =
                renderer:_collect_settled_merge_plan(chunks)
            expect(#again_groups):to_be(1)
            expect(member_count(again_members)):to_be(4)
            expect(renderer._settled_merge_scan_cursor):to_be(17)
        end)
    end)

    t.describe("settled remote merge invalidation and fallback", function()
        t.it("cancels pending and committed ownership once while preserving raw chunks", function()
            local renderer = new_renderer(RBX)
            local handle = new_handle(3)
            handle._renderer_fanout_completed_revision = 3
            local part = new_remote_part(31, handle)
            local raw_chunk = new_chunk(part, 0, "same")
            local committed_chunk = { textured_batches = {} }
            local pending_final = { textured_batches = {} }
            local pending_current = { textured_batches = {} }
            local pending_group = {
                chunk = pending_current,
                records = { { part = part } },
                parts = { part },
            }
            local token = {
                part = part,
                chunk = raw_chunk,
            }
            local pending = {
                chunks = { pending_final },
                current_chunk = pending_current,
                groups = { pending_group },
                members = { [part._id] = token },
                ids = { [part._id] = true },
            }
            renderer._scene_dynamic_chunks = { raw_chunk }
            renderer._scene_dynamic_chunks_drawn = { committed_chunk }
            renderer._settled_merge_chunks = { committed_chunk }
            renderer._settled_merge_chunk = committed_chunk
            renderer._settled_merge_members = { [part._id] = token }
            renderer._settled_merge_ids = { [part._id] = true }
            renderer._settled_merge_pending = pending
            renderer._settled_merge_last_members = { [part._id] = token }
            local released = {}
            renderer._release_scene_chunk_meshes = function(_, chunk)
                released[chunk] = (released[chunk] or 0) + 1
                return 1
            end
            renderer._invalidate_dynamic_visible_cache = function(self)
                self._test_dynamic_invalidations =
                    (self._test_dynamic_invalidations or 0) + 1
            end

            renderer:_mark_runtime_part_transform_dirty(part)

            expect(released[raw_chunk]):to_be_nil()
            expect(released[committed_chunk]):to_be(1)
            expect(released[pending_final]):to_be(1)
            expect(released[pending_current]):to_be(1)
            expect(renderer._scene_dynamic_chunks_drawn)
                :to_be(renderer._scene_dynamic_chunks)
            expect(renderer._settled_merge_chunks):to_be_nil()
            expect(renderer._settled_merge_members):to_be_nil()
            expect(renderer._settled_merge_pending):to_be_nil()
            expect(renderer._settled_merge_last_members):to_be_nil()
            expect(renderer._test_dynamic_invalidations):to_be(1)
            expect(renderer._parts_dirty_mode):to_be("transform")
            expect(renderer._parts_dirty):to_be(true)
            expect(part._dynamic_dirty_revision):to_be(62)
            expect(pending.members):to_be_nil()
            expect(pending_group.records):to_be_nil()
        end)

        t.it("restarts a pending build when a handle publication changes", function()
            local renderer = new_renderer(RBX)
            local handle = new_handle(8)
            handle._renderer_fanout_completed_revision = 8
            local first = new_remote_part(41, handle)
            local second = new_remote_part(42, handle)
            local raw = {
                new_chunk(first, 2, "same"),
                new_chunk(second, 2, "same"),
            }
            renderer._scene_dynamic_chunks = raw
            renderer._scene_dynamic_chunks_drawn = raw
            renderer._release_scene_chunk_meshes = function() return 0 end
            local _, old_members =
                renderer:_collect_settled_merge_plan(raw)
            renderer._settled_merge_pending = {
                groups = {},
                chunks = {},
                members = old_members,
                ids = { [41] = true, [42] = true },
            }
            renderer._settled_merge_last_members = old_members
            renderer._settled_merge_stable_frames = 8

            handle.revision = 9
            handle._renderer_fanout_completed_revision = 9
            renderer:_apply_settled_dynamic_merge()

            expect(renderer._settled_merge_pending):to_be_nil()
            expect(renderer._settled_merge_cancel_count):to_be(1)
            expect(renderer._settled_merge_last_cancel_reason)
                :to_be("pending_membership_changed")
            expect(renderer._settled_merge_last_members[41].handle_revision)
                :to_be(9)
            expect(renderer._settled_merge_stable_frames):to_be(0)
            expect(renderer._scene_dynamic_chunks_drawn):to_be(raw)
            expect(renderer._parts_dirty_mode):to_be_nil()
        end)

        t.it("keeps raw drawing and cools down after an aggregate build failure", function()
            local renderer = new_renderer(RBX)
            local handle = new_handle(4)
            handle._renderer_fanout_completed_revision = 4
            local raw = {
                new_chunk(new_remote_part(51, handle), 3, "same"),
                new_chunk(new_remote_part(52, handle), 3, "same"),
            }
            renderer._scene_dynamic_chunks = raw
            renderer._scene_dynamic_chunks_drawn = raw
            renderer._release_scene_chunk_meshes = function() return 0 end
            local _, members = renderer:_collect_settled_merge_plan(raw)
            renderer._settled_merge_last_members = members
            renderer._settled_merge_stable_frames = 8
            local create_attempts = 0
            renderer._create_scene_chunk = function()
                create_attempts = create_attempts + 1
                error("injected aggregate allocation failure")
            end

            renderer:_apply_settled_dynamic_merge()
            expect(create_attempts):to_be(1)
            expect(renderer._settled_merge_failure_count):to_be(1)
            expect(renderer._settled_merge_pending):to_be_nil()
            expect(renderer._scene_dynamic_chunks_drawn):to_be(raw)
            expect(renderer._parts_dirty):to_not_be(true)
            expect(renderer._parts_dirty_mode):to_be_nil()

            renderer:_apply_settled_dynamic_merge()
            expect(create_attempts):to_be(1)
            expect(renderer._scene_dynamic_chunks_drawn):to_be(raw)
        end)
    end)
end

return suite
