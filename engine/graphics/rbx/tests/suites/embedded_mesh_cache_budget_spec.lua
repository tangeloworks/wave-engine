-- Bounded embedded-payload cache ownership, pressure, and map-generation tests.

local suite = {}

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
    "geometry.lua",
    "assets.lua",
    "render.lua",
    "surface.lua",
    "lifecycle.lua",
}

local function synth_mesh_v1(x)
    local vert = string.format("[%f,0,0][0,1,0][0,0,0]", x)
    return "version 1.01\n1\n" .. vert:rep(3)
end

local function fake_decoded_mesh(seed)
    return {
        source_kind = "mesh",
        vertex_count = 3,
        index_count = 3,
        positions = { seed, 0, 0, seed + 1, 0, 0, seed, 1, 0 },
        normals = { 0, 1, 0, 0, 1, 0, 0, 1, 0 },
        uvs = { 0, 0, 1, 0, 0, 1 },
        bounds = {
            min_x = seed, min_y = 0, min_z = 0,
            max_x = seed + 1, max_y = 1, max_z = 0,
        },
    }
end

local function new_game(runtime)
    local game, create_error = runtime.new({
        render_backend = "love",
        enable_skybox = false,
        allow_remote_asset_fetch = false,
        allow_remote_mesh_fetch = false,
        physics_enabled = false,
        shader_quality = "fast",
        msaa = 0,
    })
    assert(game, create_error)
    return game, game._core
end

local function with_game(runtime, callback)
    local game, core = new_game(runtime)
    local ok, result = xpcall(function() return callback(game, core) end,
        debug.traceback)
    if not game._destroyed then pcall(game.Destroy, game) end
    if not ok then error(result, 0) end
    return result
end

function suite.run(t, harness)
    local expect = t.expect
    local EmbeddedMeshCache = require(
        "engine/graphics/rbx/runtime/embedded_mesh_cache")

    local runtime = nil
    if love.graphics then
        for _, module_name in ipairs(RUNTIME_MODULES) do
            harness.runtime_require(module_name)
        end
        runtime = harness.env.RBX
    end

    t.describe("bounded embedded decoded-mesh content cache", function()
        t.it("budgets ordinary and CSG values under one deterministic LRU", function()
            local mesh_values, csg_values = {}, {}
            local cache = EmbeddedMeshCache.new(mesh_values, csg_values, {
                max_bytes = 1024 * 1024,
                max_entries = 7,
            })

            for index = 1, 128 do
                local is_csg = index % 2 == 0
                local admitted = cache:publish(
                    is_csg, "payload-" .. index, fake_decoded_mesh(index))
                expect(admitted):to_be(true)
            end

            local stats = cache:snapshot()
            expect(stats.resident_entries):to_be(7)
            expect(stats.resident_peak_entries):to_be(7)
            expect(stats.admissions):to_be(128)
            expect(stats.evictions):to_be(121)
            expect(stats.positive_evictions):to_be(121)
            expect(stats.negative_evictions):to_be(0)
            expect(stats.oldest_key):to_be("payload-122")
            expect(stats.newest_key):to_be("payload-128")
            expect(stats.over_budget):to_be(false)
            t.assert_that(stats.resident_bytes <= stats.max_bytes,
                "combined embedded cache exceeded its byte ceiling")

            local direct_count = 0
            for _ in pairs(mesh_values) do direct_count = direct_count + 1 end
            for _ in pairs(csg_values) do direct_count = direct_count + 1 end
            expect(direct_count):to_be(7)
        end)

        t.it("retires transient negatives and map-context CSG while retaining direct geometry", function()
            local cache = EmbeddedMeshCache.new({}, {}, {
                max_bytes = 1024 * 1024,
                max_entries = 8,
            })
            local direct = fake_decoded_mesh(11)
            local contextual = fake_decoded_mesh(12)
            contextual.source_kind = "csg_child_parts"
            expect(cache:publish(false, "direct", direct)):to_be(true)
            expect(cache:publish(false, "negative", false)):to_be(true)
            expect(cache:publish(true, "contextual", contextual)):to_be(true)

            expect(cache:retire_generation()):to_be(true)
            local retained, retained_hit = cache:get(false, "direct")
            expect(retained_hit):to_be(true)
            expect(retained):to_be(direct)
            local _, negative_hit = cache:get(false, "negative")
            expect(negative_hit):to_be(false)
            local _, contextual_hit = cache:get(true, "contextual")
            expect(contextual_hit):to_be(false)

            local stats = cache:snapshot()
            expect(stats.retirement_negative_drops):to_be(1)
            expect(stats.retirement_context_drops):to_be(1)
            expect(stats.retained_hits):to_be(1)
            expect(stats.retained_entry_hits):to_be(1)
            expect(stats.resident_entries):to_be(1)
            expect(stats.resident_negative_entries):to_be(0)
        end)

        t.it("reuses ChildData only inside its exact decode context", function()
            local cache = EmbeddedMeshCache.new({}, {}, {
                max_bytes = 1024 * 1024,
                max_entries = 8,
            })
            local child_mesh = fake_decoded_mesh(13)
            child_mesh.source_kind = "csg_child_parts"
            expect(cache:publish(
                true, "child", child_mesh, false, "map-a\0mirror-x:1"))
                :to_be(true)
            expect(cache:retire_generation()):to_be(true)

            local same, same_hit = cache:get(
                true, "child", false, "map-a\0mirror-x:1")
            expect(same_hit):to_be(true)
            expect(same):to_be(child_mesh)
            local _, wrong_hit = cache:get(
                true, "child", false, "map-b\0mirror-x:1")
            expect(wrong_hit):to_be(false)
            local stats = cache:snapshot()
            expect(stats.retained_hits):to_be(1)
            expect(stats.resident_entries):to_be(0)
        end)

        t.it("strips projection ephemera, reaccounts growth, and trims newly unpinned entries", function()
            local cache = EmbeddedMeshCache.new({}, {}, {
                max_bytes = 1024 * 1024,
                max_entries = 2,
            })
            local first = fake_decoded_mesh(21)
            local second = fake_decoded_mesh(22)
            expect(cache:publish(false, "first", first)):to_be(true)
            expect(cache:publish(false, "second", second)):to_be(true)
            expect(cache:pin(false, "first", cache.generation)):to_be(true)
            expect(cache:pin(false, "second", cache.generation)):to_be(true)

            -- These fields are derived after admission in the live renderer.
            first._gpu_colors = { 1, 1, 1, 1, 1, 1, 1, 1, 1 }
            second._gpu_colors = { 1, 1, 1, 1, 1, 1, 1, 1, 1 }
            first._proj_face_ids_cache = { ["2,10,4"] = { 1, 2, 3 } }
            second._proj_face_ids_cache = { ["4,6,3"] = { 3, 2, 1 } }

            expect(cache:reconfigure({ max_entries = 1 })):to_be(false)
            expect(cache:unpin(false, "first", cache.generation)):to_be(true)
            expect(cache:unpin(false, "second", cache.generation)):to_be(true)
            expect(cache:retire_generation()):to_be(true)

            local stats = cache:snapshot()
            expect(first._proj_face_ids_cache):to_be_nil()
            expect(second._proj_face_ids_cache):to_be_nil()
            expect(stats.retirement_ephemeral_clears):to_be(2)
            expect(stats.retirement_reaccounted_entries):to_be(2)
            expect(stats.retirement_trim_evictions):to_be(1)
            expect(stats.resident_entries):to_be(1)
            expect(stats.pinned_bindings):to_be(0)
            expect(stats.over_budget):to_be(false)
        end)

        if not runtime then
            t.skip("embedded cache assets/lifecycle integration",
                "runtime/assets.lua needs graphics; 128-entry pressure core ran headless")
            return
        end

        t.it("borrows canonical embedded candidates and rebuilds mutated lists", function()
            local collect = runtime._get_part_embedded_mesh_candidates
            expect(collect):to_be_type("function")
            expect(collect({ ClassName = "MeshPart" })):to_be_nil()

            local primary_only = collect({
                ClassName = "MeshPart",
                EmbeddedMeshData = "primary",
            })
            expect(#primary_only):to_be(1)
            expect(primary_only[1]):to_be("primary")

            local canonical = { "first", "second", "third" }
            expect(collect({
                ClassName = "UnionOperation",
                EmbeddedMeshDataCandidates = canonical,
            })):to_be(canonical)
            expect(collect({
                ClassName = "UnionOperation",
                EmbeddedMeshData = "first",
                EmbeddedMeshDataCandidates = canonical,
            })):to_be(canonical)

            local reordered = { "second", "first", "third" }
            local rebuilt = collect({
                ClassName = "UnionOperation",
                EmbeddedMeshData = "first",
                EmbeddedMeshDataCandidates = reordered,
            })
            t.assert_that(rebuilt ~= reordered,
                "primary-order mismatch incorrectly borrowed authored storage")
            expect(table.concat(rebuilt, ",")):to_be("first,second,third")

            local malformed = { "first", "", "first", 17, "second" }
            rebuilt = collect({
                ClassName = "UnionOperation",
                EmbeddedMeshData = "first",
                EmbeddedMeshDataCandidates = malformed,
            })
            t.assert_that(rebuilt ~= malformed,
                "malformed runtime list incorrectly borrowed authored storage")
            expect(table.concat(rebuilt, ",")):to_be("first,second")

            -- A list that was canonical on an earlier lookup must be validated
            -- again after a direct runtime mutation.
            canonical[2] = "first"
            rebuilt = collect({
                ClassName = "UnionOperation",
                EmbeddedMeshData = "first",
                EmbeddedMeshDataCandidates = canonical,
            })
            t.assert_that(rebuilt ~= canonical,
                "duplicate introduced by mutation escaped validation")
            expect(table.concat(rebuilt, ",")):to_be("first,third")
        end)

        t.it("keeps admitted active parts pinned and fails open under pinned pressure", function()
            local renderer = setmetatable({}, { __index = runtime })
            renderer:configure_embedded_mesh_cache({
                max_bytes = 1024 * 1024,
                max_entries = 2,
            })
            local a = { ClassName = "MeshPart", EmbeddedMeshData = synth_mesh_v1(1) }
            local b = { ClassName = "MeshPart", EmbeddedMeshData = synth_mesh_v1(2) }
            local c = { ClassName = "MeshPart", EmbeddedMeshData = synth_mesh_v1(3) }

            local mesh_a = renderer:_resolve_part_mesh(a)
            local mesh_b = renderer:_resolve_part_mesh(b)
            local mesh_c = renderer:_resolve_part_mesh(c)
            t.assert_that(mesh_a and mesh_b and mesh_c, "synthetic meshes did not decode")

            local stats = renderer:get_embedded_mesh_cache_stats()
            expect(stats.resident_entries):to_be(2)
            expect(stats.pinned_entries):to_be(2)
            expect(stats.pinned_bindings):to_be(2)
            expect(stats.pressure_rejections):to_be(1)
            expect(stats.untracked_bindings):to_be(1)
            expect(stats.over_budget):to_be(false)

            -- The rejected third result remains valid and hot from its owning
            -- part even though no shared lookup entry could be retained.
            expect(renderer:_resolve_part_mesh(c)):to_be(mesh_c)
            expect(renderer.unique_mesh_count):to_be(3)

            renderer:_release_part_embedded_mesh_cache(a)
            local d = { ClassName = "MeshPart", EmbeddedMeshData = synth_mesh_v1(4) }
            t.assert_that(renderer:_resolve_part_mesh(d) ~= nil,
                "released capacity did not admit a new active part")
            stats = renderer:get_embedded_mesh_cache_stats()
            expect(stats.resident_entries):to_be(2)
            expect(stats.pinned_entries):to_be(2)
            expect(stats.evictions):to_be(1)
            expect(a._embedded_mesh_cache):to_be_nil()
            expect(stats.over_budget):to_be(false)
        end)

        t.it("deduplicates live parts by content without merging CSG semantics", function()
            local renderer = setmetatable({}, { __index = runtime })
            renderer:configure_embedded_mesh_cache({
                max_bytes = 1024 * 1024,
                max_entries = 8,
            })
            local payload = synth_mesh_v1(7)
            local a = { ClassName = "MeshPart", EmbeddedMeshData = payload }
            local b = { ClassName = "MeshPart", EmbeddedMeshData = payload }
            local union = { ClassName = "UnionOperation", EmbeddedMeshData = payload }

            local mesh_a = renderer:_resolve_part_mesh(a)
            local mesh_b = renderer:_resolve_part_mesh(b)
            local mesh_union = renderer:_resolve_part_mesh(union)
            expect(mesh_b):to_be(mesh_a)
            t.assert_that(mesh_union ~= nil and not rawequal(mesh_union, mesh_a),
                "ordinary and CSG content namespaces were incorrectly merged")
            expect(renderer.unique_mesh_count):to_be(2)

            local stats = renderer:get_embedded_mesh_cache_stats()
            expect(stats.resident_entries):to_be(2)
            expect(stats.pinned_entries):to_be(2)
            expect(stats.pinned_bindings):to_be(3)
            expect(stats.hits):to_be(1)
        end)

        t.it("frames arbitrary multi-payload keys and isolates them from single payloads", function()
            local first_key, first_multi = runtime._embedded_mesh_content_key({
                "a\0b", "c",
            })
            local second_key, second_multi = runtime._embedded_mesh_content_key({
                "a", "b\0c",
            })
            expect(first_multi):to_be(true)
            expect(second_multi):to_be(true)
            t.assert_that(first_key ~= second_key,
                "binary candidate boundaries aliased in the content key")

            local single_key, single_multi =
                runtime._embedded_mesh_content_key({ first_key })
            expect(single_key):to_be(first_key)
            expect(single_multi):to_be(false)

            local cache = EmbeddedMeshCache.new({}, {}, {
                max_bytes = 1024 * 1024,
                max_entries = 4,
            })
            local single_mesh = fake_decoded_mesh(31)
            local multi_mesh = fake_decoded_mesh(32)
            expect(cache:publish(false, first_key, single_mesh, false)):to_be(true)
            expect(cache:publish(false, first_key, multi_mesh, true)):to_be(true)
            local single_result = cache:get(false, first_key, false)
            local multi_result = cache:get(false, first_key, true)
            expect(single_result):to_be(single_mesh)
            expect(multi_result):to_be(multi_mesh)
            expect(cache:snapshot().resident_entries):to_be(2)
        end)

        t.it("releases short-lived CSG child probe pins after composition", function()
            with_game(runtime, function(_, core)
                core:configure_embedded_mesh_cache({
                    max_bytes = 1024 * 1024,
                    max_entries = 8,
                })
                local parsed_child = {
                    name = "EmbeddedChild",
                    class_name = "MeshPart",
                    x = 0, y = 0, z = 0,
                    r00 = 1, r01 = 0, r02 = 0,
                    r10 = 0, r11 = 1, r12 = 0,
                    r20 = 0, r21 = 0, r22 = 1,
                    sx = 2, sy = 2, sz = 2,
                    color_r = 255, color_g = 255,
                    color_b = 255, color_a = 255,
                    embedded_mesh_data = synth_mesh_v1(41),
                }
                local composed = core:_build_mesh_from_parsed_csg_child_parts({
                    parsed_child,
                })
                expect(composed):to_be_type("table")
                expect(composed.source_kind):to_be("csg_child_parts")
                local stats = core:get_embedded_mesh_cache_stats()
                expect(stats.resident_entries):to_be(1)
                expect(stats.pinned_entries):to_be(0)
                expect(stats.pinned_bindings):to_be(0)
                expect(stats.pin_acquires):to_be(1)
                expect(stats.pin_releases):to_be(1)
            end)
        end)

        t.it("bounds 128 unique payloads and reparses an evicted payload", function()
            local renderer = setmetatable({}, { __index = runtime })
            renderer:configure_embedded_mesh_cache({
                max_bytes = 1024 * 1024,
                max_entries = 8,
            })
            local first_payload = synth_mesh_v1(101)
            local first_mesh

            for index = 1, 128 do
                local payload = index == 1 and first_payload
                    or synth_mesh_v1(100 + index)
                local part = { ClassName = "MeshPart", EmbeddedMeshData = payload }
                local decoded = renderer:_resolve_part_mesh(part)
                t.assert_that(decoded ~= nil, "payload " .. index .. " did not decode")
                if index == 1 then first_mesh = decoded end
                renderer:_release_part_embedded_mesh_cache(part)

                local during = renderer:get_embedded_mesh_cache_stats()
                t.assert_that(during.resident_entries <= 8,
                    "entry ceiling exceeded during churn")
                t.assert_that(during.resident_bytes <= during.max_bytes,
                    "byte ceiling exceeded during churn")
            end

            local after_churn = renderer:get_embedded_mesh_cache_stats()
            expect(after_churn.resident_entries):to_be(8)
            expect(after_churn.evictions):to_be(120)
            expect(after_churn.pin_acquires):to_be(128)
            expect(after_churn.pin_releases):to_be(128)
            expect(after_churn.pinned_bindings):to_be(0)
            expect(renderer.unique_mesh_count):to_be(128)

            local replacement_part = {
                ClassName = "MeshPart",
                EmbeddedMeshData = first_payload,
            }
            local reparsed = renderer:_resolve_part_mesh(replacement_part)
            t.assert_that(reparsed ~= nil and not rawequal(reparsed, first_mesh),
                "the oldest evicted payload did not reparse")
            expect(renderer.unique_mesh_count):to_be(129)

            local final = renderer:get_embedded_mesh_cache_stats()
            expect(final.misses):to_be(129)
            expect(final.admissions):to_be(129)
            expect(final.evictions):to_be(121)
            expect(final.resident_entries):to_be(8)
            expect(final.pinned_entries):to_be(1)
            expect(final.over_budget):to_be(false)
        end)

        t.it("severs old parts while retaining bounded immutable results across reload", function()
            with_game(runtime, function(game, core)
                core:configure_embedded_mesh_cache({
                    max_bytes = 1024 * 1024,
                    max_entries = 8,
                })
                local payload_a = synth_mesh_v1(301)
                local payload_b = synth_mesh_v1(302)
                local a = core:_create_runtime_part("MeshPart")
                local b = core:_create_runtime_part("MeshPart")
                a.EmbeddedMeshData = payload_a
                b.EmbeddedMeshData = payload_b
                local mesh_a = core:_resolve_part_mesh(a)
                local mesh_b = core:_resolve_part_mesh(b)
                t.assert_that(mesh_a and mesh_b, "runtime embedded meshes did not decode")

                local before = core:get_embedded_mesh_cache_stats()
                expect(before.pinned_bindings):to_be(2)
                expect(core:_destroy_runtime_part(a)):to_be(true)
                expect(a._embedded_mesh_cache):to_be_nil()
                expect(a._embedded_mesh_cache_bound):to_be_nil()
                local after_destroy = core:get_embedded_mesh_cache_stats()
                expect(after_destroy.pinned_bindings):to_be(1)
                expect(after_destroy.pin_releases):to_be(1)

                local generation = after_destroy.generation
                core:_reset_runtime_parts()
                expect(b._destroyed):to_be(true)
                expect(b._embedded_mesh_cache):to_be_nil()
                expect(b._embedded_mesh_cache_bound):to_be_nil()
                local after_reset = core:get_embedded_mesh_cache_stats()
                expect(after_reset.generation):to_be(generation + 1)
                expect(after_reset.retirements):to_be(1)
                expect(after_reset.retirement_fallback_clears):to_be(0)
                expect(after_reset.clears):to_be(0)
                expect(after_reset.resident_entries):to_be(2)
                t.assert_that(after_reset.resident_bytes > 0,
                    "reload retired the decoded content instead of retaining it")
                expect(after_reset.pinned_bindings):to_be(0)

                local c = core:_create_runtime_part("MeshPart")
                c.EmbeddedMeshData = payload_b
                local reloaded = core:_resolve_part_mesh(c)
                t.assert_that(rawequal(reloaded, mesh_b),
                    "same-content reload did not reuse the bounded decoded result")
                local after_reload = core:get_embedded_mesh_cache_stats()
                expect(after_reload.resident_entries):to_be(2)
                expect(after_reload.pinned_bindings):to_be(1)
                game:Destroy()
                expect(c._embedded_mesh_cache):to_be_nil()
                local after_game_destroy = core:get_embedded_mesh_cache_stats()
                expect(after_game_destroy.resident_entries):to_be(0)
                expect(after_game_destroy.resident_bytes):to_be(0)
                expect(after_game_destroy.pinned_bindings):to_be(0)
                expect(after_game_destroy.clears):to_be(1)
            end)
        end)

        t.it("fails closed when generation retirement observes a live pin", function()
            local mesh_values, csg_values = {}, {}
            local cache = EmbeddedMeshCache.new(mesh_values, csg_values, {
                max_bytes = 1024 * 1024,
                max_entries = 4,
            })
            expect(cache:publish(false, "live", fake_decoded_mesh(1))):to_be(true)
            expect(cache:pin(false, "live", cache.generation)):to_be(true)

            local retired, reason = cache:retire_generation()
            expect(retired):to_be(false)
            expect(reason):to_be("pinned_bindings_remain")
            local stats = cache:snapshot()
            expect(stats.retirement_fallback_clears):to_be(1)
            expect(stats.clears):to_be(1)
            expect(stats.resident_entries):to_be(0)
            expect(stats.pinned_bindings):to_be(0)
        end)
    end)
end

return suite
