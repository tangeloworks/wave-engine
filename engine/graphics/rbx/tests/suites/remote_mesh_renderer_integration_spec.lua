-- Renderer-facing regression coverage for the asynchronous remote-mesh path.
--
-- Acquisition and decoding have their own exhaustive unit suites.  This file
-- deliberately injects a tiny manager so it can assert the renderer contract
-- without opening a socket, starting a worker, or depending on wall-clock time.

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
    "surface.lua",
    "lifecycle.lua",
}

local function new_handle(asset_id, status, result)
    local ready = status == "ready" and result ~= nil
    return {
        asset_id = tostring(asset_id),
        variant_key = table.concat({ tostring(asset_id), "mesh", "render" }, "|"),
        asset_type = "mesh",
        decode_policy = "render",
        status = status,
        state = status,
        pending = status == "pending",
        ready = ready,
        revision = ready and 1 or 0,
        result = result,
        consumers = setmetatable({}, { __mode = "k" }),
        consumer_order = setmetatable({}, { __mode = "v" }),
        consumer_order_count = 0,
        consumer_bind_revision = {},
        consumer_result_revision = {},
        consumer_slots = setmetatable({}, { __mode = "k" }),
        _test_bind_sequence = 0,
    }
end

local function new_injected_manager(handles)
    local manager = {
        handles = handles or {},
        requests = {},
        unbinds = {},
    }

    function manager:request(reference, asset_type, decode_policy, consumer, binding)
        local key = tostring(reference)
        local handle = self.handles[key] or self.handles.default
        self.requests[#self.requests + 1] = {
            reference = reference,
            asset_type = asset_type,
            decode_policy = decode_policy,
            consumer = consumer,
            binding = binding,
            handle = handle,
        }
        if handle and consumer ~= nil then
            local slot = handle.consumer_slots[consumer]
            if not slot then
                handle.consumer_order_count = handle.consumer_order_count + 1
                slot = handle.consumer_order_count
                handle._test_bind_sequence = handle._test_bind_sequence + 1
                handle.consumer_order[slot] = consumer
                handle.consumer_slots[consumer] = slot
                handle.consumer_bind_revision[slot] = handle._test_bind_sequence
                handle.consumer_result_revision[slot] = handle.revision or 0
            end
            handle.consumers[consumer] = binding or true
        end
        return handle, handle and handle.status or "missing"
    end

    function manager:unbind(handle, consumer)
        self.unbinds[#self.unbinds + 1] = {
            handle = handle,
            consumer = consumer,
        }
        if handle and handle.consumers then
            handle.consumers[consumer] = nil
            local slot = handle.consumer_slots[consumer]
            if slot then
                handle._test_bind_sequence = handle._test_bind_sequence + 1
                handle.consumer_order[slot] = nil
                handle.consumer_slots[consumer] = nil
                handle.consumer_bind_revision[slot] = handle._test_bind_sequence
                handle.consumer_result_revision[slot] = nil
            end
        end
        return true
    end

    -- The focused helper tests call the acquisition surface directly, while
    -- the yielding-build regression below installs this same manager on a
    -- complete renderer. Supply the lifecycle surface that a real renderer
    -- owns without introducing workers or wall-clock behavior into the suite.
    function manager:pump()
        return 0, 0, false
    end

    function manager:stop()
        return true
    end

    function manager:get_stats()
        return {}
    end

    return manager
end

local function new_renderer(RBX, manager)
    local renderer = setmetatable({
        allow_remote_mesh_fetch = true,
        _remote_mesh_manager = manager,
        _remote_mesh_asset_revision = 0,
        _remote_mesh_wave_revision = 0,
        _remote_mesh_wave_rebuild_count = 0,
        _remote_mesh_wave_notification_count = 0,
        _remote_mesh_promotions_per_pump = 16,
        _remote_mesh_consumer_scans_per_pump = 128,
        _mesh_cache = {},
        _embedded_mesh_by_content = {},
        _embedded_csg_mesh_by_content = {},
        _asset_path_cache = {},
        _canonical_asset_seen = {},
        _load_cache_stats = {},
        unique_mesh_count = 0,
        reused_mesh_count = 0,
    }, { __index = RBX })

    renderer._get_or_parse_local_mesh = function()
        return nil
    end
    renderer._sync_fetch_calls = 0
    renderer._fetch_remote_mesh_asset_bytes = function(self)
        self._sync_fetch_calls = self._sync_fetch_calls + 1
        error("the renderer must not enter the legacy synchronous mesh fetch path")
    end
    return renderer
end

local function decoded_bounds_mesh(min_x, max_x)
    return {
        source_kind = "file_mesh",
        bounds = {
            min_x = min_x,
            min_y = -0.5,
            min_z = -0.5,
            max_x = max_x,
            max_y = 0.5,
            max_z = 0.5,
        },
    }
end

local function decoded_triangle_mesh()
    return {
        positions = {
            -0.5, -0.5, 0,
             0.5, -0.5, 0,
             0.0,  0.5, 0,
        },
        normals = {
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
        },
        uvs = {
            0, 0,
            1, 0,
            0.5, 1,
        },
        bounds = {
            min_x = -0.5, min_y = -0.5, min_z = 0,
            max_x = 0.5, max_y = 0.5, max_z = 0,
        },
        source_kind = "file_mesh",
        version = "yielding-build-oracle",
    }
end

local function parsed_part(index, class_name, mesh_id)
    return {
        name = "YieldingBuildPart" .. tostring(index),
        class_name = class_name or "Part",
        referent = "yielding-build-" .. tostring(index),
        shape = "Block",
        x = index * 4,
        y = 0,
        z = 0,
        r00 = 1, r01 = 0, r02 = 0,
        r10 = 0, r11 = 1, r12 = 0,
        r20 = 0, r21 = 0, r22 = 1,
        sx = 2,
        sy = 2,
        sz = 2,
        color_r = 255,
        color_g = 255,
        color_b = 255,
        color_a = 255,
        anchored = true,
        can_collide = true,
        cast_shadow = true,
        material = 256,
        mesh_id = mesh_id,
    }
end

local function with_full_renderer(RBX, callback)
    local game
    local original_load_skybox = RBX._load_skybox
    local original_accurate_face_axes = RBX._accurate_face_axes
    local original_parse_invisible_parts = RBX._parse_invisible_parts
    RBX._load_skybox = function(self)
        self.sky_loaded = false
        self.sky_source = "remote_mesh_yielding_build_test"
    end

    local ok, result = xpcall(function()
        local create_error
        game, create_error = RBX.new({
            render_backend = "menori",
            enable_skybox = false,
            disable_skybox = true,
            allow_remote_asset_fetch = false,
            allow_remote_mesh_fetch = false,
            physics_enabled = false,
            enable_local_lights = false,
            mesh_instancing = false,
            global_shadows = false,
            ambient = 1,
            brightness = 1,
            shader_quality = "fast",
            msaa = 0,
            accurate_face_axes = false,
            flip_loaded_map_horizontally = false,
        })
        assert(game ~= nil, "RBX.new failed: " .. tostring(create_error))
        return callback(game, game._core)
    end, function(message)
        return debug.traceback(tostring(message), 2)
    end)

    RBX._load_skybox = original_load_skybox
    RBX._accurate_face_axes = original_accurate_face_axes
    RBX._parse_invisible_parts = original_parse_invisible_parts
    local destroy_ok, destroy_error = true, nil
    if game then
        destroy_ok, destroy_error = pcall(game.Destroy, game)
    end
    collectgarbage("collect")
    if not ok then error(result, 0) end
    if not destroy_ok then
        error("renderer teardown failed: " .. tostring(destroy_error), 0)
    end
    return result
end

function suite.run(t, harness)
    local expect = t.expect
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local RBX = harness.env.RBX
    local CFrame = harness.env.CFrame

    t.describe("async remote mesh renderer integration", function()
        t.it("never enters synchronous acquisition and never false-caches transient states", function()
            local eventual = decoded_bounds_mesh(-1, 1)
            local handle = new_handle("700", "pending")
            local manager = new_injected_manager({ ["700"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = { _id = 17 }

            expect(renderer:_get_or_parse_mesh(
                "rbxassetid://700", "mesh", part)):to_be_nil()
            expect(renderer._sync_fetch_calls):to_be(0)
            expect(next(renderer._mesh_cache)):to_be_nil()

            handle.status = "negative"
            handle.state = "negative"
            handle.pending = false
            expect(renderer:_get_or_parse_mesh(
                "https://www.roblox.com/asset/?id=700", "mesh", part)):to_be_nil()
            expect(renderer._sync_fetch_calls):to_be(0)
            expect(next(renderer._mesh_cache)):to_be_nil()

            handle.status = "ready"
            handle.state = "ready"
            handle.ready = true
            handle.result = eventual
            expect(renderer:_get_or_parse_mesh("700", "mesh", part)):to_be(eventual)
            expect(#manager.requests):to_be(3)
            expect(renderer._sync_fetch_calls):to_be(0)
        end)

        t.it("returns ready results and weak-binds the requesting part", function()
            local decoded = decoded_bounds_mesh(-2, 2)
            local handle = new_handle("701", "ready", decoded)
            local manager = new_injected_manager({ ["701"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = { _id = 71 }

            expect(renderer:_get_or_parse_mesh(
                "rbxassetid://701", "mesh", part)):to_be(decoded)
            expect(#manager.requests):to_be(1)
            expect(manager.requests[1].consumer):to_be(part)
            expect(manager.requests[1].binding.part_id):to_be(71)
            expect(getmetatable(handle.consumers).__mode):to_be("k")
            expect(handle.consumers[part]):to_be_truthy()
            expect(rawget(part, "_remote_mesh_handle")):to_be(handle)
            expect(rawget(part, "_remote_mesh_variant_key")):to_be(handle.variant_key)
        end)

        t.it("releases a stale binding before capped replacement admission", function()
            local old_handle = new_handle("710", "ready",
                decoded_bounds_mesh(-1, 1))
            local new_result = decoded_bounds_mesh(-3, 3)
            local new_handle = new_handle("711", "ready", new_result)
            local manager = new_injected_manager({
                ["710"] = old_handle,
                ["711"] = new_handle,
            })
            local renderer = new_renderer(RBX, manager)
            local part = { _id = 710 }
            expect(renderer:_get_or_parse_mesh(
                "rbxassetid://710", "mesh", part)):to_be(old_handle.result)

            local base_request = manager.request
            manager.replacement_blocked_by_old_binding = false
            function manager:request(reference, asset_type, decode_policy,
                    consumer, binding)
                if tostring(reference) == "711"
                    and old_handle.consumers[consumer] ~= nil then
                    self.replacement_blocked_by_old_binding = true
                    return nil, "source_limit"
                end
                return base_request(self, reference, asset_type,
                    decode_policy, consumer, binding)
            end

            expect(renderer:_get_or_parse_mesh(
                "rbxassetid://711", "mesh", part)):to_be(new_result)
            expect(manager.replacement_blocked_by_old_binding):to_be(false)
            expect(old_handle.consumers[part]):to_be_nil()
            expect(new_handle.consumers[part]):to_be_truthy()
            expect(rawget(part, "_remote_mesh_handle")):to_be(new_handle)
        end)

        t.it("rechecks a cached CSG physics fallback until its MeshId promotes", function()
            local fallback = {
                source_kind = "csg_physics",
                csg_approximated = true,
                bounds = {
                    min_x = -0.5, min_y = -0.5, min_z = -0.5,
                    max_x = 0.5, max_y = 0.5, max_z = 0.5,
                },
            }
            local promoted = decoded_bounds_mesh(-3, 3)
            promoted.source_kind = "csg_mesh"
            local handle = new_handle("702", "pending")
            handle.variant_key = "702|csg_mesh|render"
            local manager = new_injected_manager({ ["702"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = {
                _id = 72,
                ClassName = "UnionOperation",
                MeshId = "rbxassetid://702",
                _embedded_mesh_cache = fallback,
            }

            expect(renderer:_resolve_part_mesh(part)):to_be(fallback)
            expect(#manager.requests):to_be(1)
            expect(part._embedded_mesh_cache):to_be(fallback)

            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.result = promoted
            expect(renderer:_resolve_part_mesh(part)):to_be(promoted)
            expect(#manager.requests):to_be(2)
            expect(handle.consumers[part]):to_be_truthy()
            expect(renderer._sync_fetch_calls):to_be(0)
        end)

        t.it("records a settled wave without invalidating or rebuilding the map", function()
            local renderer = new_renderer(RBX, new_injected_manager())
            renderer._remote_mesh_asset_revision = 11
            renderer._parts_dirty = false
            renderer._parts_dirty_mode = nil

            for index = 1, 512 do
                renderer:_on_remote_mesh_variant_ready(new_handle(
                    tostring(8000 + index), "ready", {}))
            end
            expect(renderer._remote_mesh_asset_revision):to_be(11)
            expect(renderer._remote_mesh_wave_rebuild_count):to_be(0)
            expect(renderer._parts_dirty):to_be(false)

            expect(renderer:_on_remote_mesh_wave_settled({
                id = 9,
                settled = true,
                requested = 512,
                ready = 512,
                failed = 0,
            })):to_be(true)
            expect(renderer._remote_mesh_asset_revision):to_be(11)
            expect(renderer._remote_mesh_wave_revision):to_be(1)
            expect(renderer._remote_mesh_wave_notification_count):to_be(1)
            expect(renderer._remote_mesh_wave_rebuild_count):to_be(0)
            expect(renderer._parts_dirty):to_be(false)
            expect(renderer._parts_dirty_mode):to_be_nil()
        end)

        t.it("time-slices a popular ready mesh without retaining or rebuilding consumers", function()
            local handle = new_handle("704", "pending")
            local manager = new_injected_manager({ ["704"] = handle })
            local renderer = new_renderer(RBX, manager)
            local promoted_ids = {}
            renderer._promote_remote_mesh_part_incrementally = function(_, part)
                promoted_ids[#promoted_ids + 1] = part._id
                part._rb_cache = nil
                return true, "test_incremental"
            end

            for index = 1, 41 do
                local part = {
                    _id = index,
                    ClassName = "MeshPart",
                    MeshId = "rbxassetid://704",
                }
                manager:request("704", "mesh", "render", part, {
                    part_id = index,
                })
                rawset(part, "_remote_mesh_handle", handle)
                rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            end
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-2, 2)

            expect(renderer:_on_remote_mesh_variant_ready(handle)):to_be(true)
            expect(renderer:_on_remote_mesh_wave_settled({
                id = 11, settled = true, requested = 1, ready = 1, failed = 0,
            })):to_be(true)

            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(7, 64)
            expect(promoted):to_be(7)
            expect(depth):to_be(1)
            expect(fell_back):to_be(false)
            expect(renderer._parts_dirty):to_be_nil()
            for slot = 1, 7 do
                expect(handle.consumer_result_revision[slot]):to_be(1)
            end
            expect(handle.consumer_result_revision[8]):to_be(0)

            local guard = 0
            while depth > 0 and guard < 16 do
                promoted, depth, fell_back =
                    renderer:_drain_remote_mesh_ready_consumers(7, 64)
                expect(promoted <= 7):to_be(true)
                expect(fell_back):to_be(false)
                guard = guard + 1
            end
            expect(guard < 16):to_be(true)
            expect(#promoted_ids):to_be(41)
            expect(renderer._remote_mesh_incremental_promotion_count):to_be(41)
            expect(renderer._remote_mesh_wave_rebuild_count):to_be(0)
            expect(renderer._remote_mesh_asset_revision):to_be(0)
            expect(renderer._parts_dirty):to_be_nil()
            expect(handle._renderer_fanout_record):to_be_nil()
            for slot = 1, handle.consumer_order_count do
                expect(handle.consumer_result_revision[slot]):to_be(1)
            end
        end)

        t.it("retires decode-only CSG child consumers without rebuilding the live scene", function()
            local handle = new_handle("714", "pending")
            handle.variant_key = "714|csg_mesh|render"
            handle.asset_type = "csg_mesh"
            local manager = new_injected_manager({ ["714"] = handle })
            local renderer = new_renderer(RBX, manager)
            -- Production renderers always own this authoritative index. CSG
            -- child-data composition deliberately creates negative-id probe
            -- parts that are never inserted into it.
            renderer._runtime_part_by_id = {}
            local decode_probe = {
                _id = -2,
                _map_referent = 1,
                ClassName = "UnionOperation",
                Name = "Union",
                MeshId = "rbxassetid://714",
            }
            manager:request("714", "csg_mesh", "render", decode_probe, {
                part_id = decode_probe._id,
            })
            rawset(decode_probe, "_remote_mesh_handle", handle)
            rawset(decode_probe, "_remote_mesh_variant_key",
                handle.variant_key)
            local promotion_called = false
            renderer._promote_remote_mesh_part_incrementally = function()
                promotion_called = true
                return false, "decode probes are not promotable"
            end
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)

            expect(renderer:_on_remote_mesh_variant_ready(handle)):to_be(true)
            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(16, 128)
            expect(promoted):to_be(0)
            expect(depth):to_be(0)
            expect(fell_back):to_be(false)
            expect(promotion_called):to_be(false)
            expect(renderer._remote_mesh_stale_consumer_count):to_be(1)
            expect(renderer._remote_mesh_incremental_failure_count or 0)
                :to_be(0)
            expect(renderer._remote_mesh_wave_rebuild_count):to_be(0)
            expect(renderer._parts_dirty):to_be_nil()
            expect(handle._renderer_fanout_record):to_be_nil()
        end)

        t.it("does not acknowledge a consumer whose bind token changes during promotion", function()
            local handle = new_handle("709", "pending")
            local manager = new_injected_manager({ ["709"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = {
                _id = 709,
                ClassName = "MeshPart",
                MeshId = "rbxassetid://709",
            }
            manager:request("709", "mesh", "render", part, {
                part_id = 709,
            })
            rawset(part, "_remote_mesh_handle", handle)
            rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            local slot = handle.consumer_slots[part]
            renderer._promote_remote_mesh_part_incrementally = function()
                handle.consumer_bind_revision[slot] =
                    handle.consumer_bind_revision[slot] + 1
                return true
            end
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)

            renderer:_on_remote_mesh_variant_ready(handle)
            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(1, 8)
            expect(promoted):to_be(1)
            expect(depth):to_be(0)
            expect(fell_back):to_be(false)
            expect(handle.consumer_result_revision[slot]):to_be(0)
        end)

        t.it("retires queued publication only at a successful full-build acknowledgement", function()
            local handle = new_handle("712", "pending")
            local manager = new_injected_manager({ ["712"] = handle })
            local renderer = new_renderer(RBX, manager)
            renderer.parts = {}
            for index = 1, 2 do
                local part = {
                    _id = 7120 + index,
                    ClassName = "MeshPart",
                    MeshId = "rbxassetid://712",
                }
                renderer.parts[index] = part
                manager:request("712", "mesh", "render", part, {
                    part_id = part._id,
                })
                rawset(part, "_remote_mesh_handle", handle)
                rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            end
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)
            expect(renderer:_on_remote_mesh_variant_ready(handle)):to_be(true)
            expect(renderer._remote_mesh_ready_queue ~= nil):to_be(true)
            for slot = 1, 2 do
                expect(handle.consumer_result_revision[slot]):to_be(0)
            end

            local acknowledged, retired =
                renderer:_acknowledge_remote_mesh_full_build()
            expect(acknowledged):to_be(2)
            expect(retired):to_be(1)
            expect(renderer._remote_mesh_ready_queue):to_be_nil()
            expect(handle._renderer_fanout_record):to_be_nil()
            expect(handle._renderer_fanout_completed_revision):to_be(1)
            for slot = 1, 2 do
                expect(handle.consumer_result_revision[slot]):to_be(1)
            end
        end)

        t.it("defers a publication that arrives while async scene classification is incomplete", function()
            local handle = new_handle("715", "pending")
            local manager = new_injected_manager({ ["715"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = {
                _id = 715,
                ClassName = "Part",
                MeshId = "rbxassetid://715",
            }
            renderer.parts = { part }
            renderer._runtime_part_by_id = { [part._id] = part }
            manager:request("715", "mesh", "render", part, {
                part_id = part._id,
            })
            rawset(part, "_remote_mesh_handle", handle)
            rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)
            expect(renderer:_on_remote_mesh_variant_ready(handle)):to_be(true)

            local observed = {}
            renderer._remote_mesh_full_build_seen = observed
            local promotion_calls = 0
            renderer._promote_remote_mesh_part_incrementally = function()
                promotion_calls = promotion_calls + 1
                return true, "static_range_promoted"
            end
            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(16, 128)
            expect(promoted):to_be(0)
            expect(depth):to_be(1)
            expect(fell_back):to_be(false)
            expect(promotion_calls):to_be(0)

            -- This part was visited before publication, so the build must not
            -- falsely acknowledge geometry it never consumed.
            local acknowledged, retired =
                renderer:_acknowledge_remote_mesh_full_build(observed)
            expect(acknowledged):to_be(0)
            expect(retired):to_be(0)
            expect(renderer._remote_mesh_ready_queue ~= nil):to_be(true)
            expect(handle.consumer_result_revision[1]):to_be(0)

            renderer._remote_mesh_full_build_seen = nil
            promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(16, 128)
            expect(promoted):to_be(1)
            expect(depth):to_be(0)
            expect(fell_back):to_be(false)
            expect(promotion_calls):to_be(1)
            expect(handle.consumer_result_revision[1]):to_be(1)
            expect(renderer._remote_mesh_wave_rebuild_count):to_be(0)
        end)

        t.it("defers late publication across a real yielding full-scene commit", function()
            local handle = new_handle("718", "pending")
            local manager = new_injected_manager({ ["718"] = handle })

            with_full_renderer(RBX, function(_, core)
                core.allow_remote_mesh_fetch = true
                core._remote_mesh_manager = manager
                core._async_map_load = {
                    phase = "building",
                    apply_started = true,
                }

                -- Cross both runtime-part and scene-part slice boundaries. The
                -- remote MeshPart is first, so its fallback CPU geometry has
                -- already been classified when the chunk checkpoint yields.
                local parsed_parts = {}
                parsed_parts[1] = parsed_part(
                    1, "MeshPart", "rbxassetid://718")
                for index = 2, 49 do
                    parsed_parts[index] = parsed_part(index)
                end

                local checkpoint_count = 0
                local build = coroutine.create(function()
                    core:_load_runtime_parts_from_parsed(
                        parsed_parts,
                        {},
                        function(phase, index, total)
                            checkpoint_count = checkpoint_count + 1
                            coroutine.yield(phase, index, total)
                        end)
                end)

                local saw_runtime_slice = false
                local saw_scene_slice = false
                local reached_late_sync_slice = false
                for _ = 1, 256 do
                    local resumed, phase, index = coroutine.resume(build)
                    assert(resumed, phase)
                    if phase == "runtime_parts" then
                        saw_runtime_slice = true
                    elseif phase == "scene_parts" then
                        saw_scene_slice = true
                    elseif phase == "scene_chunks" and index == 1 then
                        reached_late_sync_slice = true
                        break
                    end
                    if coroutine.status(build) == "dead" then break end
                end
                expect(saw_runtime_slice):to_be(true)
                expect(saw_scene_slice):to_be(true)
                expect(reached_late_sync_slice):to_be(true)
                expect(coroutine.status(build)):to_be("suspended")
                expect(type(core._remote_mesh_full_build_seen)):to_be("table")

                local mesh_part = core.parts[1]
                expect(mesh_part.ClassName):to_be("MeshPart")
                expect(rawget(mesh_part, "_remote_mesh_handle")):to_be(handle)
                local slot = handle.consumer_slots[mesh_part]
                expect(slot ~= nil):to_be(true)
                expect(handle.consumer_result_revision[slot]):to_be(0)

                local original_promote =
                    core._promote_remote_mesh_part_incrementally
                local promotion_calls = 0
                core._promote_remote_mesh_part_incrementally =
                    function(self, part)
                        promotion_calls = promotion_calls + 1
                        return original_promote(self, part)
                    end

                -- Publish after this part's full-build classification. This
                -- revision is absent from the observation ledger and must
                -- survive commit for exactly one incremental promotion.
                handle.status = "ready"
                handle.state = "ready"
                handle.pending = false
                handle.ready = true
                handle.revision = 1
                handle.result = decoded_triangle_mesh()
                expect(core:_on_remote_mesh_variant_ready(handle)):to_be(true)

                local promoted, depth, fell_back =
                    core:_drain_remote_mesh_ready_consumers(16, 128)
                expect(promoted):to_be(0)
                expect(depth):to_be(1)
                expect(fell_back):to_be(false)
                expect(promotion_calls):to_be(0)
                expect(handle.consumer_result_revision[slot]):to_be(0)

                for _ = 1, 256 do
                    if coroutine.status(build) == "dead" then break end
                    local resumed, build_error = coroutine.resume(build)
                    assert(resumed, build_error)
                end
                expect(coroutine.status(build)):to_be("dead")
                core._async_map_load = nil

                expect(core._remote_mesh_full_build_seen):to_be_nil()
                expect(handle.consumer_result_revision[slot]):to_be(0)
                expect(core._remote_mesh_ready_queue ~= nil):to_be(true)

                promoted, depth, fell_back =
                    core:_drain_remote_mesh_ready_consumers(16, 128)
                expect(promoted):to_be(1)
                expect(depth):to_be(0)
                expect(fell_back):to_be(false)
                expect(promotion_calls):to_be(1)
                expect(handle.consumer_result_revision[slot]):to_be(1)
                expect(mesh_part._appearance_dynamic):to_be(true)

                promoted, depth, fell_back =
                    core:_drain_remote_mesh_ready_consumers(16, 128)
                expect(promoted):to_be(0)
                expect(depth):to_be(0)
                expect(fell_back):to_be(false)
                expect(promotion_calls):to_be(1)
                expect(handle._renderer_fanout_record):to_be_nil()
                expect(checkpoint_count > 0):to_be(true)
            end)
        end)

        t.it("acknowledges a ready remote mesh actually consumed by the active full build", function()
            local handle = new_handle("716", "pending")
            -- Earlier suites may have selected the accurate-face-axis decoder
            -- policy. Model the variant the renderer will actually request;
            -- otherwise the production code correctly rebinds this consumer
            -- and the test observes the retired slot rather than the consumed
            -- one. Consumer slot numbers are never an asset-level identity.
            local policy = RBX._accurate_face_axes == true
                and "render_accurate_axes" or "render"
            handle.decode_policy = policy
            local manager = new_injected_manager({ ["716"] = handle })
            local renderer = new_renderer(RBX, manager)
            handle.variant_key = require("engine/graphics/rbx/runtime/remote_mesh").variant_key(
                "716", "mesh", policy, {
                    map_path = renderer._map_build_path or renderer.map_path or RBX._last_parsed_map_path,
                    asset_root = renderer.asset_root,
                })
            local part = {
                _id = 716,
                ClassName = "MeshPart",
                MeshId = "rbxassetid://716",
            }
            renderer.parts = { part }
            renderer._runtime_part_by_id = { [part._id] = part }
            manager:request("716", "mesh", "render", part, {
                part_id = part._id,
            })
            local slot = handle.consumer_slots[part]
            expect(slot ~= nil):to_be(true)
            rawset(part, "_remote_mesh_handle", handle)
            rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)
            expect(renderer:_on_remote_mesh_variant_ready(handle)):to_be(true)

            local observed = {}
            renderer._remote_mesh_full_build_seen = observed
            expect(renderer:_get_or_parse_mesh(
                "rbxassetid://716", "mesh", part)):to_be(handle.result)
            local acknowledged, retired =
                renderer:_acknowledge_remote_mesh_full_build(observed)
            expect(acknowledged):to_be(1)
            expect(retired):to_be(1)
            expect(handle.consumer_result_revision[slot]):to_be(1)
            expect(renderer._remote_mesh_ready_queue):to_be_nil()
            expect(handle._renderer_fanout_record):to_be_nil()
        end)

        t.it("preserves an unordered-manager fallback when a sliced build missed publication", function()
            local handle = new_handle("717", "ready",
                decoded_bounds_mesh(-1, 1))
            handle.consumer_order = nil
            handle.consumer_slots = nil
            handle.consumer_bind_revision = nil
            local renderer = new_renderer(RBX, {})
            local part = {
                _id = 717,
                ClassName = "MeshPart",
                MeshId = "rbxassetid://717",
            }
            renderer.parts = { part }
            rawset(part, "_remote_mesh_handle", handle)
            rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            handle.consumers[part] = true
            renderer._remote_mesh_full_rebuild_pending = true

            local acknowledged, retired =
                renderer:_acknowledge_remote_mesh_full_build({})
            expect(acknowledged):to_be(0)
            expect(retired):to_be(0)
            expect(renderer._remote_mesh_full_rebuild_pending):to_be(true)

            -- Once a later full build really consumes that same revision, the
            -- compatibility fallback is no longer necessary even though the
            -- older manager cannot provide ordered fanout slots.
            acknowledged, retired =
                renderer:_acknowledge_remote_mesh_full_build({
                    [part] = {
                        handle = handle,
                        revision = handle.revision,
                    },
                })
            expect(acknowledged):to_be(0)
            expect(retired):to_be(0)
            expect(renderer._remote_mesh_full_rebuild_pending):to_be(false)
        end)

        t.it("severs fanout ownership when a queued handle becomes invalid", function()
            local handle = new_handle("713", "pending")
            local manager = new_injected_manager({ ["713"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = {
                _id = 713,
                ClassName = "MeshPart",
                MeshId = "rbxassetid://713",
            }
            manager:request("713", "mesh", "render", part, {
                part_id = part._id,
            })
            rawset(part, "_remote_mesh_handle", handle)
            rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)
            expect(renderer:_on_remote_mesh_variant_ready(handle)):to_be(true)
            local entry = handle._renderer_fanout_record
            expect(entry.renderer):to_be(renderer)
            expect(entry.handle):to_be(handle)

            -- Variant eviction/stop clears the weak order before the renderer
            -- gets its next update. The invalid queue cell must not leave a
            -- handle -> entry -> renderer ownership chain behind.
            handle.consumer_order = nil
            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(1, 8)
            expect(promoted):to_be(0)
            expect(depth):to_be(0)
            expect(fell_back):to_be(false)
            expect(renderer._remote_mesh_ready_queue):to_be_nil()
            expect(handle._renderer_fanout_record):to_be_nil()
            expect(entry.queued):to_be(false)
            expect(entry.handle):to_be_nil()
            expect(entry.renderer):to_be_nil()
        end)

        t.it("round-robins unfinished popular handles so smaller variants publish", function()
            local popular = new_handle("706", "pending")
            local small = new_handle("707", "pending")
            local manager = new_injected_manager({
                ["706"] = popular,
                ["707"] = small,
            })
            local renderer = new_renderer(RBX, manager)
            local order = {}
            renderer._promote_remote_mesh_part_incrementally = function(_, part)
                order[#order + 1] = part._id
                return true
            end

            local function bind(handle, asset_id, part_id)
                local part = {
                    _id = part_id,
                    ClassName = "MeshPart",
                    MeshId = "rbxassetid://" .. asset_id,
                }
                manager:request(asset_id, "mesh", "render", part, {
                    part_id = part_id,
                })
                rawset(part, "_remote_mesh_handle", handle)
                rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            end
            bind(popular, "706", 7061)
            bind(popular, "706", 7062)
            bind(popular, "706", 7063)
            bind(small, "707", 7071)
            for _, handle in ipairs({ popular, small }) do
                handle.status = "ready"
                handle.state = "ready"
                handle.pending = false
                handle.ready = true
                handle.revision = 1
                handle.result = decoded_bounds_mesh(-1, 1)
                renderer:_on_remote_mesh_variant_ready(handle)
            end

            renderer:_drain_remote_mesh_ready_consumers(1, 8)
            renderer:_drain_remote_mesh_ready_consumers(1, 8)
            expect(order[1]):to_be(7061)
            expect(order[2]):to_be(7071)
        end)

        t.it("uses one explicit full fallback when live geometry is untracked", function()
            local handle = new_handle("705", "pending")
            local manager = new_injected_manager({ ["705"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = {
                _id = 705,
                ClassName = "MeshPart",
                MeshId = "rbxassetid://705",
            }
            manager:request("705", "mesh", "render", part, { part_id = 705 })
            rawset(part, "_remote_mesh_handle", handle)
            rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            renderer._promote_remote_mesh_part_incrementally = function()
                return false, "full_rebuild_required"
            end
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)

            renderer:_on_remote_mesh_variant_ready(handle)
            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(16, 128)
            expect(promoted):to_be(1)
            expect(depth):to_be(0)
            expect(fell_back):to_be(true)
            expect(renderer._remote_mesh_wave_rebuild_count):to_be(1)
            expect(renderer._remote_mesh_asset_revision):to_be(1)
            expect(renderer._parts_dirty):to_be(true)
            expect(renderer._parts_dirty_mode):to_be("full")
        end)

        t.it("contains an incremental promotion exception behind the same fallback", function()
            local handle = new_handle("708", "pending")
            local manager = new_injected_manager({ ["708"] = handle })
            local renderer = new_renderer(RBX, manager)
            local part = {
                _id = 708,
                ClassName = "MeshPart",
                MeshId = "rbxassetid://708",
            }
            manager:request("708", "mesh", "render", part, { part_id = 708 })
            rawset(part, "_remote_mesh_handle", handle)
            rawset(part, "_remote_mesh_variant_key", handle.variant_key)
            renderer._promote_remote_mesh_part_incrementally = function()
                error("injected promotion failure")
            end
            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded_bounds_mesh(-1, 1)

            renderer:_on_remote_mesh_variant_ready(handle)
            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(1, 8)
            expect(promoted):to_be(1)
            expect(depth):to_be(0)
            expect(fell_back):to_be(true)
            expect(renderer._remote_mesh_incremental_failure_count):to_be(1)
            expect(renderer._remote_mesh_last_incremental_error:find(
                "injected promotion failure", 1, true) ~= nil):to_be(true)
            expect(renderer._parts_dirty_mode):to_be("full")
        end)

        t.it("invalidates same-CFrame render bounds when a remote wave publishes", function()
            local decoded = decoded_bounds_mesh(-2, 2)
            local handle = new_handle("703", "pending")
            local manager = new_injected_manager({ ["703"] = handle })
            local renderer = new_renderer(RBX, manager)
            local cframe = CFrame.new(0, 0, 0)
            local part = {
                _id = 73,
                ClassName = "MeshPart",
                Shape = "Block",
                MeshId = "rbxassetid://703",
                CFrame = cframe,
                Size = { x = 2, y = 2, z = 2 },
                -- Roblox MeshSize makes decoded bounds observable instead of
                -- normalizing every mesh to the Part's exact Size.
                MeshSize = { x = 1, y = 1, z = 1 },
            }

            local fallback_bounds = renderer:_get_part_render_bounds(part)
            expect(fallback_bounds.min_x):to_be_near(-1, 1e-6)
            expect(fallback_bounds.max_x):to_be_near(1, 1e-6)
            expect(part._rb_cache.cf):to_be(cframe)
            expect(part._rb_cache.remote_mesh_revision):to_be(0)

            handle.status = "ready"
            handle.state = "ready"
            handle.pending = false
            handle.ready = true
            handle.revision = 1
            handle.result = decoded
            part._runtime_dynamic = true
            part.Anchored = false
            renderer._mark_runtime_part_transform_dirty = function(self, dirty_part)
                self._test_remote_transform_dirty = dirty_part
            end
            renderer:_on_remote_mesh_variant_ready(handle)
            renderer:_on_remote_mesh_wave_settled({
                id = 10, settled = true, requested = 1, ready = 1, failed = 0,
            })
            local promoted, depth, fell_back =
                renderer:_drain_remote_mesh_ready_consumers(1, 8)
            expect(promoted):to_be(1)
            expect(depth):to_be(0)
            expect(fell_back):to_be(false)
            expect(renderer._test_remote_transform_dirty):to_be(part)

            local promoted_bounds = renderer:_get_part_render_bounds(part)
            expect(part.CFrame):to_be(cframe)
            expect(promoted_bounds.min_x):to_be_near(-4, 1e-6)
            expect(promoted_bounds.max_x):to_be_near(4, 1e-6)
            expect(part._rb_cache.remote_mesh_revision):to_be(0)
        end)
    end)
end

return suite
