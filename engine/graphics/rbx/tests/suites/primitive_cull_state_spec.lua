-- CPU classification, batch metadata, and submission-state regressions for
-- target-aware closed built-in primitive culling.

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

local function with_graphics_capture(callback)
    local graphics = love.graphics
    local names = {
        "setShader",
        "setDepthMode",
        "setMeshCullMode",
        "setBlendMode",
        "setColorMask",
        "draw",
        "drawInstanced",
    }
    local originals = {}
    for index = 1, #names do
        local name = names[index]
        originals[name] = graphics[name]
    end

    local capture = {
        cull_mode = nil,
        cull_modes = {},
        draws = {},
    }
    graphics.setShader = function()
    end
    graphics.setDepthMode = function()
    end
    graphics.setBlendMode = function()
    end
    graphics.setColorMask = function()
    end
    graphics.setMeshCullMode = function(mode)
        capture.cull_mode = mode
        capture.cull_modes[#capture.cull_modes + 1] = mode
    end
    graphics.draw = function(mesh)
        capture.draws[#capture.draws + 1] = {
            mesh = mesh,
            instanced = false,
            cull_mode = capture.cull_mode,
        }
    end
    graphics.drawInstanced = function(mesh, count)
        capture.draws[#capture.draws + 1] = {
            mesh = mesh,
            count = count,
            instanced = true,
            cull_mode = capture.cull_mode,
        }
    end

    local ok, result = xpcall(function()
        return callback(capture)
    end, function(message)
        return debug.traceback(tostring(message), 2)
    end)

    for index = 1, #names do
        local name = names[index]
        graphics[name] = originals[name]
    end

    if not ok then
        error(result, 0)
    end
    return result
end

local function draws_for_mesh(capture, mesh)
    local found = {}
    for index = 1, #capture.draws do
        local draw = capture.draws[index]
        if draw.mesh == mesh then
            found[#found + 1] = draw
        end
    end
    return found
end

local function primitive_row(sx, sy, sz, basis)
    basis = basis or {
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    }
    return {
        0, 0, 0,
        basis[1], basis[2], basis[3],
        basis[4], basis[5], basis[6],
        basis[7], basis[8], basis[9],
        sx, sy, sz,
        1, 1, 1, 1,
        0,
        0, 0, 0, 0,
    }
end

local function new_submission_core(RBX, meshes, flip_y)
    local core = setmetatable({
        enable_face_culling = false,
        enable_closed_primitive_culling = true,
        _projection_flip_y = flip_y,
        enable_local_lights = false,
        local_light_count = 0,
        max_lights_per_batch = 4,
        max_dynamic_shadow_lights = 0,
        collect_hotspot_stats = false,
        collect_detailed_draw_stats = false,
        use_instancing = true,
        disable_cube_pass = false,
        disable_textured_pass = false,
        static_shape_depth_bias = 0,
        transparent_depth_bias = 0,

        _instanced_depth_shader = {},
        _static_depth_shader = {},
        _instanced_shader = {},
        _static_shader = {},
        _culling_stats = {},

        _mega_dynamic_cube_draw_mesh = meshes.dynamic_mega,
        _mega_dynamic_instance_count = 1,
        _mega_dynamic_cube_handedness = "positive",
        _mega_cube_draw_mesh = meshes.static_mega,
        _mega_instance_count = 1,
        _mega_cube_handedness = "positive",
    }, RBX)

    core._update_dirty_local_lights = function()
    end
    core._draw_skybox = function()
    end
    core._is_debug_overlay_enabled = function()
        return false
    end
    core._sort_transparent_draw_items = function()
    end
    core._send_depth_common_uniforms = function()
    end
    core._send_instanced_depth_uniforms = function()
    end
    core._send_static_depth_uniforms = function()
    end
    core._send_common_uniforms = function()
    end
    core._send_instanced_draw_uniforms = function()
    end
    core._send_static_draw_uniforms = function()
    end
    core._send_textured_common_uniforms = function()
    end
    core._send_textured_draw_uniforms = function()
    end
    core._prepare_scene_frame_packet = function()
        return {
            depth_clip_recompute_count = 0,
            opaque_chunks = {},
            opaque_static_items = {
                {
                    kind = "instanced_primitive",
                    key = "Wedge|p",
                    draw_mesh = meshes.instanced_positive,
                    count = 1,
                    closed_primitive_handedness = "positive",
                },
                {
                    kind = "instanced_primitive",
                    key = "Wedge|n",
                    draw_mesh = meshes.instanced_negative,
                    count = 1,
                    closed_primitive_handedness = "negative",
                },
                {
                    kind = "instanced_primitive",
                    key = "Wedge|0",
                    draw_mesh = meshes.instanced_mixed,
                    count = 2,
                    closed_primitive_handedness = "mixed",
                },
                {
                    kind = "static",
                    key = "CornerWedge|p",
                    mesh = meshes.static_positive,
                    closed_primitive_handedness = "positive",
                },
                {
                    kind = "static",
                    key = "CornerWedge|n",
                    mesh = meshes.static_negative,
                    closed_primitive_handedness = "negative",
                },
                {
                    kind = "static",
                    key = "CornerWedge|0",
                    mesh = meshes.static_collapsed,
                    closed_primitive_handedness = "collapsed",
                },
            },
            opaque_textured_batches = {},
            opaque_surface_geometry_batches = {},
            opaque_overlay_textured_batches = {},
            surface_gui_overlay_batches = {},
            transparent_items = {
                {
                    kind = "static",
                    key = "Wedge",
                    mesh = meshes.transparent_static,
                    closed_primitive_handedness = "positive",
                },
            },
            transparent_surface_gui_items = {},
            chunk_cube_draw_list = {
                {
                    cube_draw_mesh = meshes.chunk_instanced,
                    instance_count = 1,
                    closed_primitive_handedness = "positive",
                },
            },
            chunk_static_cube_list = {
                {
                    static_cube_mesh = meshes.chunk_static,
                    closed_primitive_handedness = "positive",
                },
            },
            mega_cube_path_active = true,
            dynamic_mega_active = true,
            surface_gui_update_ms = 0,
            has_opaque = true,
            has_transparent = true,
            active_opaque_depth_prepass_mode = "full",
        }
    end

    return core
end

local function expect_draw_mode(t, capture, mesh, wanted, count)
    local draws = draws_for_mesh(capture, mesh)
    t.expect(#draws):to_be(count or 2)
    for index = 1, #draws do
        t.expect(draws[index].cull_mode):to_be(wanted)
    end
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local RBX = harness.env.RBX
    local expect = t.expect

    t.describe("closed primitive transform handedness", function()
        t.it("classifies basis and scale parity without magnitude overflow", function()
            local classify = RBX._classify_closed_primitive_instance_row
            expect(classify(primitive_row(1, 2, 3))):to_be("positive")
            expect(classify(primitive_row(-1, -2, 3))):to_be("positive")
            expect(classify(primitive_row(-1, 2, 3))):to_be("negative")
            expect(classify(primitive_row(
                -1, 2, 3,
                {
                    -1, 0, 0,
                    0, 1, 0,
                    0, 0, 1,
                }))):to_be("positive")
            expect(classify(primitive_row(1e300, 1e300, 1e-300)))
                :to_be("positive")
            expect(classify(primitive_row(0, 2, 3))):to_be("collapsed")
            expect(classify(primitive_row(
                1, 2, 3,
                {
                    1, 0, 0,
                    2, 0, 0,
                    0, 0, 1,
                }))):to_be("collapsed")
        end)

        t.it("summarizes only homogeneous non-collapsed row sets", function()
            local summarize =
                RBX._summarize_closed_primitive_instance_rows
            local positive = primitive_row(1, 1, 1)
            local even = primitive_row(-1, -1, 1)
            local negative = primitive_row(-1, 1, 1)
            local collapsed = primitive_row(0, 1, 1)
            expect(summarize({ positive, even })):to_be("positive")
            expect(summarize({ negative, primitive_row(1, -1, 1) }))
                :to_be("negative")
            expect(summarize({ positive, negative })):to_be("mixed")
            expect(summarize({ positive, collapsed })):to_be("collapsed")
            expect(summarize({})):to_be("collapsed")

            expect(RBX._closed_primitive_batch_key("CylinderY", "positive"))
                :to_be("CylinderY|p")
            expect(RBX._closed_primitive_batch_key("CylinderY", "negative"))
                :to_be("CylinderY|n")
            expect(RBX._closed_primitive_batch_key("CylinderY", "collapsed"))
                :to_be("CylinderY|0")
            expect(RBX._closed_primitive_shape_name_from_batch_key(
                "CylinderY|n")):to_be("CylinderY")
        end)
    end)

    t.describe("closed primitive cull submission state", function()
        for _, projection in ipairs({
            {
                name = "Canvas",
                flip_y = -1,
                positive = "back",
                negative = "front",
            },
            {
                name = "screen",
                flip_y = 1,
                positive = "back",
                negative = "front",
            },
        }) do
            t.it("uses matching depth/color modes for " .. projection.name,
                function()
                    local meshes = {
                        dynamic_mega = {},
                        static_mega = {},
                        chunk_instanced = {},
                        chunk_static = {},
                        instanced_positive = {},
                        instanced_negative = {},
                        instanced_mixed = {},
                        static_positive = {},
                        static_negative = {},
                        static_collapsed = {},
                        transparent_static = {},
                    }
                    local core = new_submission_core(
                        RBX, meshes, projection.flip_y)

                    -- Arbitrary imported mesh culling stays disabled. Closed
                    -- primitives use their dedicated, default-on option.
                    expect(core:_resolve_cull_mode("back", true))
                        :to_be("none")
                    expect(core:_resolve_closed_primitive_cull_mode(
                        "positive")):to_be(projection.positive)
                    expect(core:_resolve_closed_primitive_cull_mode(
                        "negative")):to_be(projection.negative)
                    expect(core:_resolve_closed_primitive_cull_mode(
                        "mixed")):to_be("none")
                    expect(core:_resolve_closed_primitive_cull_mode(
                        "collapsed")):to_be("none")

                    with_graphics_capture(function(capture)
                        core:_draw_scene_pass()

                        expect_draw_mode(
                            t, capture, meshes.dynamic_mega,
                            projection.positive)
                        expect_draw_mode(
                            t, capture, meshes.static_mega,
                            projection.positive)
                        expect_draw_mode(
                            t, capture, meshes.chunk_instanced,
                            projection.positive)
                        expect_draw_mode(
                            t, capture, meshes.chunk_static,
                            projection.positive)
                        expect_draw_mode(
                            t, capture, meshes.instanced_positive,
                            projection.positive)
                        expect_draw_mode(
                            t, capture, meshes.instanced_negative,
                            projection.negative)
                        expect_draw_mode(
                            t, capture, meshes.instanced_mixed, "none")
                        expect_draw_mode(
                            t, capture, meshes.static_positive,
                            projection.positive)
                        expect_draw_mode(
                            t, capture, meshes.static_negative,
                            projection.negative)
                        expect_draw_mode(
                            t, capture, meshes.static_collapsed, "none")
                        expect_draw_mode(
                            t, capture, meshes.transparent_static, "none", 1)
                    end)
                end)
        end

        t.it("honors the dedicated closed primitive kill switch", function()
            local core = new_submission_core(RBX, {}, -1)
            core.enable_closed_primitive_culling = false
            expect(core:_resolve_closed_primitive_cull_mode("positive"))
                :to_be("none")
            expect(core:_resolve_closed_primitive_cull_mode("negative"))
                :to_be("none")
        end)
    end)
end

return suite
