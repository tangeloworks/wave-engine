-- Correctness and lifecycle regressions for revision-locked static local-light
-- clusters. These tests use fake batch creation so they can exercise every
-- fallback deterministically without depending on one GPU driver's allocation
-- behaviour.

local suite = {}

suite.needs_graphics = true

local RUNTIME_MODULES = {
    "common.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
    "geometry.lua",
    "assets.lua",
    "render.lua",
}

local unpack_row = table.unpack or unpack

local function instance_row(x)
    return {
        x or 0, 0, 0,
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
        1, 1, 1,
        1, 1, 1, 1,
        0,
        1, 1, 1, 1,
    }
end

local function zero_instance_row()
    local row = {}
    for index = 1, 24 do
        row[index] = 0
    end
    return row
end

local function copy_row(row)
    local copied = {}
    for index = 1, 24 do
        copied[index] = row[index]
    end
    return copied
end

local function row_mesh(rows)
    return {
        getVertex = function(_, index)
            return unpack_row(rows[index], 1, 24)
        end,
    }
end

local function bounds_at(x)
    return {
        min_x = x - 1,
        min_y = -1,
        min_z = -1,
        max_x = x + 1,
        max_y = 1,
        max_z = 1,
    }
end

local function light_pack(key, ambient)
    return {
        key = key,
        ambient = ambient or { 0, 0, 0, 0 },
        count = 0,
        slots = {},
    }
end

local function primitive_source(name, x, pack, row)
    return {
        kind = "instanced_primitive",
        key = "Wedge|positive",
        batch_key = "Wedge|positive",
        shape_name = "Wedge",
        count = 1,
        primitive_count = 1,
        draw_mesh = { name = name .. "-draw" },
        instance_mesh = row_mesh({ row or instance_row(x) }),
        bounds = bounds_at(x),
        closed_primitive_handedness = "positive",
        test_pack = pack,
    }
end

local function static_chunk(name, grid_x, pack, cube_row, primitive)
    local x = grid_x * 4
    return {
        key = name,
        grid_x = grid_x,
        grid_y = 0,
        grid_z = 0,
        dynamic_chunk = false,
        bounds = bounds_at(x),
        cube_instances = cube_row and { cube_row } or {},
        instance_count = cube_row and 1 or 0,
        cube_draw_mesh = cube_row and { name = name .. "-cube-draw" } or nil,
        instance_mesh = cube_row and row_mesh({ cube_row }) or nil,
        closed_primitive_batch_key = "Block|positive",
        closed_primitive_handedness = "positive",
        opaque_static_draw_items = primitive and { primitive } or {},
        test_pack = pack,
    }
end

local function set_chunk_handedness(chunk, handedness)
    chunk.closed_primitive_handedness = handedness
    chunk.closed_primitive_batch_key = "Block|" .. handedness
    return chunk
end

local function new_fake_core(RBX, chunks)
    local created = {
        cubes = {},
        primitives = {},
        released = {},
    }
    local core = setmetatable({
        enable_static_local_light_clusters = true,
        enable_local_lights = true,
        enable_local_light_pack_sorting = true,
        use_instancing = true,
        constant_fragment_shader = false,
        render_backend_name = "menori",
        _render_backend = {},
        enable_occlusion_culling = false,
        local_light_count = 5,
        max_lights_per_batch = 4,
        local_light_cluster_supercell_span = 2,
        _local_light_revision = 7,
        _instance_generation = 8,
        _static_scene_revision = 9,
        _scene_static_chunks = chunks or {},
    }, RBX)

    core._get_local_light_pack_for_item = function(_, item)
        return item.test_pack
    end
    core._create_menori_cube_batch = function(_, rows)
        local copied = {}
        for index = 1, #rows do copied[index] = copy_row(rows[index]) end
        local batch = {
            draw_mesh = { category = "cube" },
            instance_mesh = row_mesh(copied),
            instance_count = #copied,
            instance_capacity = #copied,
            vertex_count = 24,
            index_count = 36,
            indices_tsize = 2,
            batch_key = "Block|positive",
            closed_primitive_handedness = "positive",
            test_rows = copied,
        }
        created.cubes[#created.cubes + 1] = batch
        return batch
    end
    core._create_menori_primitive_batch = function(_, shape_name, rows)
        local copied = {}
        for index = 1, #rows do copied[index] = copy_row(rows[index]) end
        local batch = {
            draw_mesh = { category = shape_name },
            instance_mesh = row_mesh(copied),
            instance_count = #copied,
            instance_capacity = #copied,
            vertex_count = 18,
            index_count = 24,
            indices_tsize = 2,
            batch_key = shape_name .. "|positive",
            closed_primitive_handedness = "positive",
            test_rows = copied,
        }
        created.primitives[#created.primitives + 1] = batch
        return batch
    end
    core._release_opaque_cube_batch = function(_, batch)
        if batch.test_released then
            return false
        end
        batch.test_released = true
        created.released[#created.released + 1] = batch
        return true
    end

    return core, created
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local RBX = harness.env.RBX
    local expect = t.expect

    t.describe("static local-light cluster composition", function()
        t.it("substitutes an ordered contiguous run and clears a reused buffer", function()
            local core = setmetatable({}, RBX)
            local a, b, plain = {}, {}, {}
            local cluster = {
                source_order_by_item = {
                    [a] = 1,
                    [b] = 2,
                },
            }
            local mapping = {
                [a] = cluster,
                [b] = cluster,
            }
            local buffer = { "stale", "stale" }

            local result, saved, draws =
                core:_compose_static_local_light_cluster_draw_list(
                    { a, b, plain }, mapping, buffer)
            expect(result):to_be(buffer)
            expect(#result):to_be(2)
            expect(result[1]):to_be(cluster)
            expect(result[2]):to_be(plain)
            expect(saved):to_be(1)
            expect(draws):to_be(1)

            result, saved, draws =
                core:_compose_static_local_light_cluster_draw_list(
                    { a }, mapping, buffer)
            expect(#result):to_be(1)
            expect(result[1]):to_be(a)
            expect(saved):to_be(0)
            expect(draws):to_be(0)
        end)

        t.it("preserves noncontiguous and reversed source order exactly", function()
            local core = setmetatable({}, RBX)
            local a, b, plain = {}, {}, {}
            local cluster = {
                source_order_by_item = {
                    [a] = 1,
                    [b] = 2,
                },
            }
            local mapping = {
                [a] = cluster,
                [b] = cluster,
            }

            local separated, separated_saved =
                core:_compose_static_local_light_cluster_draw_list(
                    { a, plain, b }, mapping, {})
            expect(#separated):to_be(3)
            expect(separated[1]):to_be(a)
            expect(separated[2]):to_be(plain)
            expect(separated[3]):to_be(b)
            expect(separated_saved):to_be(0)

            local reversed, reversed_saved =
                core:_compose_static_local_light_cluster_draw_list(
                    { b, a }, mapping, {})
            expect(#reversed):to_be(2)
            expect(reversed[1]):to_be(b)
            expect(reversed[2]):to_be(a)
            expect(reversed_saved):to_be(0)
        end)
    end)

    t.describe("static local-light cluster validity", function()
        t.it("rejects every build-sensitive runtime boundary", function()
            local core = new_fake_core(RBX)
            core._static_local_light_clusters = {
                light_revision = 7,
                instance_generation = 8,
                static_scene_revision = 9,
            }
            expect(core:_static_local_light_clusters_invalid_reason()):to_be_nil()

            local cases = {
                { "enable_static_local_light_clusters", false, "disabled" },
                { "enable_local_lights", false, "local_lights_disabled" },
                { "enable_local_light_pack_sorting", false, "pack_sorting_disabled" },
                { "use_instancing", false, "instancing_unavailable" },
                { "constant_fragment_shader", true, "constant_shader" },
                { "render_backend_name", "love", "backend_unavailable" },
                { "enable_occlusion_culling", true, "occlusion_active" },
                { "_local_light_revision", 10, "light_revision_changed" },
                { "_instance_generation", 10, "instance_generation_changed" },
                { "_static_scene_revision", 10, "static_scene_revision_changed" },
            }
            for index = 1, #cases do
                local key, value, reason =
                    cases[index][1], cases[index][2], cases[index][3]
                local old = core[key]
                core[key] = value
                expect(core:_static_local_light_clusters_invalid_reason())
                    :to_be(reason)
                core[key] = old
            end

            core._dynamic_scene_revision = 999
            expect(core:_static_local_light_clusters_invalid_reason()):to_be_nil()
            core.local_light_count=4
            expect(core:_static_local_light_clusters_invalid_reason()):to_be_nil()
            core._static_local_light_clusters = nil
            expect(core:_static_local_light_clusters_invalid_reason()):to_be('light_slots_sufficient')
            core.local_light_count=5
            expect(core:_static_local_light_clusters_invalid_reason())
                :to_be("not_built")
        end)
    end)

    t.describe("static local-light cluster build", function()
        t.it("combines exact cube and primitive buckets in source-row order", function()
            local pack = light_pack("7:1:2:3:4:0:0:0")
            local p1 = primitive_source("p1", 0, pack, instance_row(10))
            local p2 = primitive_source("p2", 4, pack, instance_row(20))
            local c1 = static_chunk("0:0:0", 0, pack, instance_row(1), p1)
            local c2 = static_chunk("1:0:0", 1, pack, instance_row(2), p2)
            p1._scene_chunk_key, p1._scene_chunk_grid_x =
                c1.key, c1.grid_x
            p2._scene_chunk_key, p2._scene_chunk_grid_x =
                c2.key, c2.grid_x
            p1._scene_chunk_grid_y, p1._scene_chunk_grid_z = 0, 0
            p2._scene_chunk_grid_y, p2._scene_chunk_grid_z = 0, 0
            local core, created = new_fake_core(RBX, { c1, c2 })

            local clusters = core:_rebuild_static_local_light_clusters()

            expect(clusters):to_be_type("table")
            expect(#clusters.cube_items):to_be(1)
            expect(#clusters.primitive_items):to_be(1)
            expect(clusters.cube_by_source[c1]):to_be(clusters.cube_items[1])
            expect(clusters.cube_by_source[c2]):to_be(clusters.cube_items[1])
            expect(clusters.primitive_by_source[p1])
                :to_be(clusters.primitive_items[1])
            expect(clusters.primitive_by_source[p2])
                :to_be(clusters.primitive_items[1])
            expect(created.cubes[1].test_rows[1][1]):to_be(1)
            expect(created.cubes[1].test_rows[2][1]):to_be(2)
            expect(created.primitives[1].test_rows[1][1]):to_be(10)
            expect(created.primitives[1].test_rows[2][1]):to_be(20)
            expect(clusters.cube_items[1]._local_light_pack):to_be(pack)
            expect(clusters.cube_items[1]._local_light_pack_revision):to_be(7)
            expect(clusters.cube_items[1].bounds.min_x):to_be(-1)
            expect(clusters.cube_items[1].bounds.max_x):to_be(5)
            expect(clusters.stats.covered_cube_draw_count):to_be(2)
            expect(clusters.stats.covered_primitive_draw_count):to_be(2)
            expect(clusters.stats.clustered_instance_count):to_be(4)
            expect(clusters.stats.theoretical_draws_saved):to_be(2)
            expect(clusters.stats.uploaded_bytes > 0):to_be(true)
        end)

        t.it("keeps sub-millesimal ambient payloads in separate buckets", function()
            local pack_a = light_pack(
                "7:1:2:3:4:0:0:0",
                { 0.00011, 0, 0, 0 })
            local pack_b = light_pack(
                "7:1:2:3:4:0:0:0",
                { 0.00012, 0, 0, 0 })
            local chunks = {
                static_chunk("a0", 0, pack_a, instance_row(1)),
                static_chunk("a1", 1, pack_a, instance_row(2)),
                static_chunk("b0", 0, pack_b, instance_row(3)),
                static_chunk("b1", 1, pack_b, instance_row(4)),
            }
            local core = new_fake_core(RBX, chunks)

            local clusters = core:_rebuild_static_local_light_clusters()

            expect(#clusters.cube_items):to_be(2)
            expect(clusters.cube_by_source[chunks[1]])
                :to_not_be(clusters.cube_by_source[chunks[3]])
            expect(RBX._local_light_pack_payload_key(pack_a))
                :to_not_be(RBX._local_light_pack_payload_key(pack_b))
        end)

        t.it("reads live cube rows so an incremental zero cannot resurrect", function()
            local pack = light_pack("pack")
            local first = static_chunk(
                "a", 0, pack, instance_row(99))
            local second = static_chunk(
                "b", 1, pack, instance_row(88))
            first.instance_mesh = row_mesh({ instance_row(1) })
            second.instance_mesh = row_mesh({ instance_row(2) })
            local core, created =
                new_fake_core(RBX, { first, second })

            core:_rebuild_static_local_light_clusters()

            expect(created.cubes[1].test_rows[1][1]):to_be(1)
            expect(created.cubes[1].test_rows[2][1]):to_be(2)
        end)

        t.it("rejects malformed GPU rows without hiding source geometry", function()
            local pack = light_pack("pack")
            local good = primitive_source("good", 0, pack)
            local bad_row = instance_row(4)
            bad_row[12] = "bad"
            local bad = primitive_source("bad", 4, pack, bad_row)
            local c1 = static_chunk("a", 0, pack, nil, good)
            local c2 = static_chunk("b", 1, pack, nil, bad)
            local core = new_fake_core(RBX, { c1, c2 })

            local clusters = core:_rebuild_static_local_light_clusters()

            expect(clusters):to_be_nil()
            expect(core._static_local_light_cluster_last_build_stats
                .source_read_failure_count):to_be(1)
            local fallback, saved =
                core:_compose_static_local_light_cluster_draw_list(
                    { good, bad }, {}, {})
            expect(#fallback):to_be(2)
            expect(fallback[1]):to_be(good)
            expect(fallback[2]):to_be(bad)
            expect(saved):to_be(0)
        end)

        t.it("records backend failures and leaves all sources mapped to fallback", function()
            local pack = light_pack("pack")
            local c1 = static_chunk("a", 0, pack, instance_row(1))
            local c2 = static_chunk("b", 1, pack, instance_row(2))
            local core = new_fake_core(RBX, { c1, c2 })
            core._create_menori_cube_batch = function()
                return nil
            end

            local clusters = core:_rebuild_static_local_light_clusters()

            expect(clusters):to_be_nil()
            local stats = core._static_local_light_cluster_last_build_stats
            expect(stats.backend_failure_count):to_be(1)
            expect(stats.cube_cluster_count):to_be(0)
            expect(stats.covered_cube_draw_count):to_be(0)
        end)

        t.it("reads only profitable buckets and bounds deferred upload work", function()
            local pack = light_pack("pack")
            local chunks = {}
            local read_count = 0
            for index = 1, 20 do
                local row = instance_row(index)
                local chunk = static_chunk(
                    "chunk-" .. index,
                    index - 1,
                    pack,
                    row)
                chunk.instance_mesh = {
                    getVertex = function()
                        read_count = read_count + 1
                        return unpack_row(row, 1, 24)
                    end,
                }
                chunks[index] = chunk
            end
            local core, created = new_fake_core(RBX, chunks)
            core.local_light_cluster_maintenance_max_batches = 3
            core.local_light_cluster_maintenance_max_duplicate_instance_bytes =
                1024 * 1024

            local clusters = core:_rebuild_static_local_light_clusters({
                maintenance = true,
            })

            expect(#clusters.cube_items):to_be(3)
            expect(#created.cubes):to_be(3)
            -- Ten two-source supercell buckets are profitable, but the deferred
            -- budget materializes rows only for the three it can upload.
            expect(read_count):to_be(6)
            expect(clusters.stats.profitable_bucket_count):to_be(10)
            expect(clusters.stats.budget_skipped_bucket_count):to_be(7)
            expect(clusters.stats.budget_skipped_instance_count):to_be(14)
            expect(clusters.stats.maintenance_budgeted):to_be(true)
            expect(clusters.stats.duplicate_instance_bytes):to_be(6 * 24 * 4)
        end)

        t.it("enforces the total duplicate-byte cap with exact source fallback", function()
            local pack = light_pack("pack")
            local chunks = {}
            for index = 1, 8 do
                chunks[index] = static_chunk(
                    "chunk-" .. index,
                    index - 1,
                    pack,
                    instance_row(index))
            end
            local core = new_fake_core(RBX, chunks)
            core.local_light_cluster_max_batches = 100
            -- Two rows cost 192 bytes, so only one of the four profitable
            -- buckets may allocate; all skipped sources remain unmapped.
            core.local_light_cluster_max_duplicate_instance_bytes = 200

            local clusters = core:_rebuild_static_local_light_clusters()

            expect(#clusters.cube_items):to_be(1)
            expect(clusters.stats.budget_skipped_bucket_count):to_be(3)
            expect(clusters.stats.duplicate_instance_bytes):to_be(192)
            local mapped_source_count = 0
            for index = 1, #chunks do
                if clusters.cube_by_source[chunks[index]] then
                    mapped_source_count = mapped_source_count + 1
                end
            end
            expect(mapped_source_count):to_be(2)
        end)
    end)

    t.describe("static local-light cluster release", function()
        t.it("retires cluster resources exactly once and never source resources", function()
            local pack = light_pack("pack")
            local p1 = primitive_source("p1", 0, pack)
            local p2 = primitive_source("p2", 4, pack)
            local c1 = static_chunk("a", 0, pack, instance_row(1), p1)
            local c2 = static_chunk("b", 1, pack, instance_row(2), p2)
            local source_cube_draw = c1.cube_draw_mesh
            local source_primitive_draw = p1.draw_mesh
            local core, created = new_fake_core(RBX, { c1, c2 })
            local clusters = core:_rebuild_static_local_light_clusters()
            local cube_cluster = clusters.cube_items[1]
            local primitive_cluster = clusters.primitive_items[1]

            expect(core:_release_static_local_light_clusters(true)):to_be(2)
            expect(#created.released):to_be(2)
            expect(core._static_local_light_clusters):to_be_nil()
            expect(cube_cluster.cube_draw_mesh):to_be_nil()
            expect(cube_cluster.instance_mesh):to_be_nil()
            expect(primitive_cluster.draw_mesh):to_be_nil()
            expect(primitive_cluster.instance_mesh):to_be_nil()
            expect(c1.cube_draw_mesh):to_be(source_cube_draw)
            expect(p1.draw_mesh):to_be(source_primitive_draw)
            expect(core:_release_static_local_light_clusters(true)):to_be(0)
            expect(#created.released):to_be(2)
        end)

        t.it("clears aliases without double-releasing before a backend reset", function()
            local pack = light_pack("pack")
            local c1 = static_chunk("a", 0, pack, instance_row(1))
            local c2 = static_chunk("b", 1, pack, instance_row(2))
            local core, created = new_fake_core(RBX, { c1, c2 })
            local clusters = core:_rebuild_static_local_light_clusters()
            local item = clusters.cube_items[1]

            expect(core:_release_static_local_light_clusters(false)):to_be(0)
            expect(#created.released):to_be(0)
            expect(item.cube_draw_mesh):to_be_nil()
            expect(item.instance_mesh):to_be_nil()
            expect(core._static_local_light_clusters):to_be_nil()
        end)

        t.it("severs composed packet state and every retired generation mapping", function()
            local pack = light_pack("pack")
            local p1 = primitive_source("p1", 0, pack)
            local p2 = primitive_source("p2", 4, pack)
            local c1 = static_chunk("a", 0, pack, instance_row(1), p1)
            local c2 = static_chunk("b", 1, pack, instance_row(2), p2)
            local core = new_fake_core(RBX, { c1, c2 })
            local clusters = core:_rebuild_static_local_light_clusters()
            local cube_item = clusters.cube_items[1]
            local primitive_item = clusters.primitive_items[1]

            core._scene_frame_packet = { cube_item }
            core._clustered_opaque_static_items_buffer = { primitive_item }
            core._chunk_cube_draw_list_buffer = { cube_item }
            core._local_light_cluster_visible_count_scratch = {
                [cube_item] = 2,
            }
            core._compose_light_cluster_generation = clusters
            core._compose_sig1 = {}
            core._opaque_split_valid = true

            expect(core:_release_static_local_light_clusters(true)):to_be(2)
            expect(core._scene_frame_packet):to_be_nil()
            expect(core._clustered_opaque_static_items_buffer):to_be_nil()
            expect(core._chunk_cube_draw_list_buffer):to_be_nil()
            expect(core._local_light_cluster_visible_count_scratch):to_be_nil()
            expect(core._compose_light_cluster_generation):to_be_nil()
            expect(core._compose_sig1):to_be_nil()
            expect(core._opaque_split_valid):to_be(false)
            expect(next(clusters.cube_by_source or {})):to_be_nil()
            expect(next(clusters.primitive_by_source or {})):to_be_nil()
            expect(cube_item.source_items):to_be_nil()
            expect(cube_item.source_order_by_item):to_be_nil()
            expect(primitive_item.source_items):to_be_nil()
            expect(primitive_item.source_order_by_item):to_be_nil()
            expect(#(clusters.cube_items or {})):to_be(0)
            expect(#(clusters.primitive_items or {})):to_be(0)
        end)
    end)

    t.describe("static local-light cluster maintenance", function()
        t.it("rebuilds an explicitly retired same-signature generation", function()
            local pack = light_pack("pack")
            local first = static_chunk(
                "a", 0, pack, instance_row(1))
            local second = static_chunk(
                "b", 1, pack, instance_row(2))
            local core, created =
                new_fake_core(RBX, { first, second })
            core.local_light_cluster_rebuild_delay = 0
            local signature =
                core:_static_local_light_cluster_build_signature()

            expect(core:_rebuild_static_local_light_clusters())
                :to_be_type("table")
            expect(core._static_local_light_cluster_last_attempt_signature)
                :to_be(signature)
            expect(core:_release_static_local_light_clusters(true)):to_be(1)
            expect(core._static_local_light_cluster_last_attempt_signature)
                :to_be_nil()

            -- The first maintenance pass arms the zero-delay stable-signature
            -- gate; the second performs the replacement allocation.
            expect(core:_maintain_static_local_light_clusters()):to_be(false)
            expect(core:_maintain_static_local_light_clusters()):to_be(true)
            expect(core._static_local_light_clusters.build_signature)
                :to_be(signature)
            expect(#created.cubes):to_be(2)
            expect(#created.released):to_be(1)
        end)

        t.it("refreshes exact light selections while retaining geometry and source fallback", function()
            local pack = light_pack("pack")
            local first = static_chunk(
                "a", 0, pack, instance_row(1))
            local second = static_chunk(
                "b", 1, pack, instance_row(2))
            local core, created =
                new_fake_core(RBX, { first, second })
            core.local_light_cluster_rebuild_delay = 0
            local initial = core:_rebuild_static_local_light_clusters()
            expect(initial.light_revision):to_be(7)

            core._local_light_revision = 8
            expect(core:_maintain_static_local_light_clusters()):to_be(false)
            expect(core._static_local_light_clusters):to_be(initial)
            expect(initial.light_revision):to_be(8)
            expect(#created.cubes):to_be(1)
            expect(#created.released):to_be(0)
            expect(initial.cube_items[1].light_payload_valid):to_be(true)

            second.test_pack=light_pack('changed-selection')
            core._local_light_revision=9
            core:_maintain_static_local_light_clusters()
            expect(initial.cube_items[1].light_payload_valid):to_be(false)
            local list,saved=core:_compose_static_local_light_cluster_draw_list(
                {first,second},initial.cube_by_source,{})
            expect(#list):to_be(2);expect(list[1]):to_be(first);expect(list[2]):to_be(second);expect(saved):to_be(0)
            first.test_pack=second.test_pack;core._local_light_revision=10
            core:_maintain_static_local_light_clusters()
            expect(initial.cube_items[1].light_payload_valid):to_be(true)
            expect(initial.cube_items[1]._local_light_pack):to_be(second.test_pack)

            -- The stable signature neither allocates nor releases again.
            expect(core:_maintain_static_local_light_clusters()):to_be(false)
            expect(#created.cubes):to_be(1)
            expect(#created.released):to_be(0)
        end)

        t.it("retires and rebuilds across backend identity and generation changes", function()
            local pack = light_pack("pack")
            local first = static_chunk(
                "a", 0, pack, instance_row(1))
            local second = static_chunk(
                "b", 1, pack, instance_row(2))
            local core, created =
                new_fake_core(RBX, { first, second })
            core.local_light_cluster_rebuild_delay = 0
            core._render_backend.generation = 3
            local initial = core:_rebuild_static_local_light_clusters()
            expect(initial.backend):to_be(core._render_backend)
            expect(initial.backend_generation):to_be(3)

            local replacement_backend = { generation = 11 }
            core._render_backend = replacement_backend
            expect(core:_static_local_light_clusters_invalid_reason())
                :to_be("backend_generation_changed")
            expect(core:_maintain_static_local_light_clusters()):to_be(false)
            expect(core._static_local_light_clusters):to_be_nil()
            expect(#created.released):to_be(1)
            expect(core:_maintain_static_local_light_clusters()):to_be(true)
            expect(core._static_local_light_clusters.backend)
                :to_be(replacement_backend)
            expect(core._static_local_light_clusters.backend_generation)
                :to_be(11)

            replacement_backend.generation = 12
            expect(core:_static_local_light_clusters_invalid_reason())
                :to_be("backend_generation_changed")
            expect(core:_maintain_static_local_light_clusters()):to_be(false)
            expect(core._static_local_light_clusters):to_be_nil()
            expect(#created.released):to_be(2)
            expect(core:_maintain_static_local_light_clusters()):to_be(true)
            expect(core._static_local_light_clusters.backend)
                :to_be(replacement_backend)
            expect(core._static_local_light_clusters.backend_generation)
                :to_be(12)
            expect(#created.cubes):to_be(3)
        end)

        t.it("retries a same-signature transient allocation failure", function()
            local pack = light_pack("pack")
            local first = static_chunk(
                "a", 0, pack, instance_row(1))
            local second = static_chunk(
                "b", 1, pack, instance_row(2))
            local core, created =
                new_fake_core(RBX, { first, second })
            core.local_light_cluster_failure_retry_delay = 0
            core.local_light_cluster_failure_max_retry_delay = 0
            core.local_light_cluster_failure_retry_limit = 2
            local create_cube = core._create_menori_cube_batch
            local attempts = 0
            core._create_menori_cube_batch = function(self, ...)
                attempts = attempts + 1
                if attempts == 1 then
                    return nil
                end
                return create_cube(self, ...)
            end

            expect(core:_rebuild_static_local_light_clusters()):to_be_nil()
            expect(attempts):to_be(1)
            expect(core._static_local_light_cluster_failure_count):to_be(1)
            expect(core:_maintain_static_local_light_clusters()):to_be(true)
            expect(attempts):to_be(2)
            expect(#created.cubes):to_be(1)
            expect(core._static_local_light_cluster_failure_signature)
                :to_be_nil()
            expect(core._static_local_light_cluster_failure_count):to_be_nil()
            expect(core._static_local_light_cluster_retry_at):to_be_nil()
        end)

        t.it("retires every ineligible toggle and rebuilds when re-enabled", function()
            local cases = {
                { "enable_static_local_light_clusters", false, true },
                { "enable_local_lights", false, true },
                { "enable_local_light_pack_sorting", false, true },
                { "use_instancing", false, true },
                { "constant_fragment_shader", true, false },
                { "render_backend_name", "love", "menori" },
                { "enable_occlusion_culling", true, false },
                { "local_light_count", 4, 5 },
            }

            for case_index = 1, #cases do
                local field, ineligible, eligible =
                    cases[case_index][1],
                    cases[case_index][2],
                    cases[case_index][3]
                local pack = light_pack("pack-" .. field)
                local first = static_chunk(
                    "a", 0, pack, instance_row(1))
                local second = static_chunk(
                    "b", 1, pack, instance_row(2))
                local core, created =
                    new_fake_core(RBX, { first, second })
                core.local_light_cluster_rebuild_delay = 0
                local clusters =
                    core:_rebuild_static_local_light_clusters()
                local cluster_item = clusters.cube_items[1]

                core[field] = ineligible
                expect(core:_maintain_static_local_light_clusters())
                    :to_be(false)
                if field=='local_light_count'then
                    expect(core._static_local_light_clusters):to_be(clusters)
                    expect(#created.released):to_be(0)
                    core[field]=eligible
                    expect(core:_maintain_static_local_light_clusters()):to_be(false)
                    expect(#created.cubes):to_be(1)
                else
                expect(core._static_local_light_clusters):to_be_nil()
                expect(#created.released):to_be(1)
                expect(next(clusters.cube_by_source or {})):to_be_nil()
                expect(cluster_item.source_items):to_be_nil()
                expect(cluster_item.source_order_by_item):to_be_nil()

                core[field] = eligible
                expect(core:_maintain_static_local_light_clusters())
                    :to_be(false)
                expect(core:_maintain_static_local_light_clusters())
                    :to_be(true)
                expect(core._static_local_light_clusters)
                    :to_be_type("table")
                expect(#created.cubes):to_be(2)
                end
            end
        end)

        t.it("preserves source handedness after retired rows are zeroed", function()
            local pack = light_pack("pack")
            local positive_first = set_chunk_handedness(
                static_chunk("p0", 0, pack, instance_row(1)),
                "positive")
            local positive_second = set_chunk_handedness(
                static_chunk("p1", 1, pack, instance_row(2)),
                "positive")
            local negative_first = set_chunk_handedness(
                static_chunk("n0", 0, pack, instance_row(3)),
                "negative")
            local negative_second = set_chunk_handedness(
                static_chunk("n1", 1, pack, instance_row(4)),
                "negative")
            local core = new_fake_core(RBX, {
                positive_first,
                positive_second,
                negative_first,
                negative_second,
            })

            expect(core:_rebuild_static_local_light_clusters())
                :to_be_type("table")
            expect(core:_release_static_local_light_clusters(true)):to_be(2)
            positive_first.instance_mesh = row_mesh({ zero_instance_row() })
            negative_first.instance_mesh = row_mesh({ zero_instance_row() })

            local rebuilt = core:_rebuild_static_local_light_clusters()
            local positive =
                rebuilt.cube_by_source[positive_first]
            local negative =
                rebuilt.cube_by_source[negative_first]
            expect(positive):to_not_be(negative)
            expect(positive.closed_primitive_handedness):to_be("positive")
            expect(positive.closed_primitive_batch_key)
                :to_be("Block|positive")
            expect(negative.closed_primitive_handedness):to_be("negative")
            expect(negative.closed_primitive_batch_key)
                :to_be("Block|negative")
            expect(core:_resolve_closed_primitive_cull_mode(
                positive.closed_primitive_handedness)):to_be("back")
            expect(core:_resolve_closed_primitive_cull_mode(
                negative.closed_primitive_handedness)):to_be("front")
            expect(positive._cube_instance_batch.test_rows[1][4]):to_be(0)
            expect(negative._cube_instance_batch.test_rows[1][4]):to_be(0)
        end)
    end)
end

return suite
