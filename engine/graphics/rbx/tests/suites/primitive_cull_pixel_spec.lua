-- Real-GPU pixel oracle for closed built-in primitive culling.
--
-- Submission-state mocks can prove that a mode was requested, but not that the
-- requested mode preserves the visible exterior. This suite renders the real
-- primitive vertex tables into a depth-backed Canvas, reads the pixels back, and
-- asks which of LOVE's `front` / `back` modes is pixel-equivalent to `none`.
--
-- Both resource paths are exercised:
--   * Menori owns the base + instance meshes used by drawInstanced.
--   * build_static_mesh CPU-bakes the same instance into the LOVE fallback mesh.
--
-- We also exercise both render-target conventions used by the runtime. Custom
-- projection shaders bypass LOVE's built-in TransformProjectionMatrix, so the
-- runtime uses flip_y=-1 while drawing into a Canvas and flip_y=+1 while drawing
-- directly to the screen. LOVE itself flips the configured front-face winding
-- whenever a Canvas is active. A synchronous window framebuffer readback is not
-- available in LOVE 11.5, so the screen case uses the exact +1 projection in an
-- offscreen target and selects CW user winding to cancel LOVE's automatic Canvas
-- flip. That reproduces the window's effective CCW winding instead of measuring
-- a non-runtime combination of the screen projection and Canvas winding.

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

local SHAPES = {
    "Block",
    "Wedge",
    "CornerWedge",
    "Cylinder",
    "CylinderY",
    "Ball",
    "Truss",
}

local SCALE_CASES = {
    {
        name = "positive",
        size = { 1.25, 1.10, 1.40 },
        parity = 1,
    },
    {
        name = "even_negative",
        size = { -1.25, -1.10, 1.40 },
        parity = 1,
    },
    {
        name = "odd_negative",
        size = { -1.25, 1.10, 1.40 },
        parity = -1,
    },
}

-- Measured runtime-target baseline (effective CCW front-face winding):
--
-- target convention        determinant +1   determinant -1
-- Canvas, flip_y=-1        back             front
-- screen, flip_y=+1        back             front
--
-- Every shape below, on both resource paths, must independently reproduce this
-- table by matching its cull-none image. This is intentionally not derived from
-- RBX:_resolve_cull_mode: that is the behavior under test, not the oracle.
local PROJECTION_CASES = {
    {
        name = "canvas",
        flip_y = -1,
        canvas_winding = "ccw",
        positive_parity_mode = "back",
    },
    {
        name = "screen_target_simulation",
        flip_y = 1,
        canvas_winding = "cw",
        positive_parity_mode = "back",
    },
}

local BASE_VERTEX_FORMAT = {
    { "VertexPosition", "float", 3 },
    { "VertexNormal", "float", 3 },
}

local INSTANCE_VERTEX_FORMAT = {
    { "InstancePosition",    "float", 3 },
    { "InstanceRight",       "float", 3 },
    { "InstanceUp",          "float", 3 },
    { "InstanceBack",        "float", 3 },
    { "InstanceSize",        "float", 3 },
    { "InstanceColor",       "float", 4 },
    { "InstanceReflectance", "float", 1 },
    { "InstanceContactAO",   "float", 4 },
}

local STATIC_VERTEX_FORMAT = {
    { "VertexPosition",    "float", 3 },
    { "VertexNormal",      "float", 3 },
    { "VertexColor",       "float", 4 },
    { "VertexReflectance", "float", 1 },
    { "VertexContactAO",   "float", 1 },
}

local INSTANCED_ORACLE_SHADER = [[
uniform mat4 uViewMatrix;
uniform mat4 uProjectionMatrix;
varying vec3 vOracleNormal;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceSize;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 local_pos = vertex_position.xyz * InstanceSize;
    vec3 world_pos = InstancePosition
        + InstanceRight * local_pos.x
        + InstanceUp * local_pos.y
        + InstanceBack * local_pos.z;

    vec3 safe_size = vec3(
        InstanceSize.x >= 0.0 ? max(InstanceSize.x, 1e-6) : min(InstanceSize.x, -1e-6),
        InstanceSize.y >= 0.0 ? max(InstanceSize.y, 1e-6) : min(InstanceSize.y, -1e-6),
        InstanceSize.z >= 0.0 ? max(InstanceSize.z, 1e-6) : min(InstanceSize.z, -1e-6));
    vec3 local_normal = VertexNormal / safe_size;
    vOracleNormal = normalize(
        InstanceRight * local_normal.x
        + InstanceUp * local_normal.y
        + InstanceBack * local_normal.z);

    return uProjectionMatrix * uViewMatrix * vec4(world_pos, 1.0);
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    return vec4(normalize(vOracleNormal) * 0.45 + 0.5, 1.0);
}
#endif
]]

local STATIC_ORACLE_SHADER = [[
uniform mat4 uViewMatrix;
uniform mat4 uProjectionMatrix;
varying vec3 vOracleNormal;

#ifdef VERTEX
attribute vec3 VertexNormal;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vOracleNormal = normalize(VertexNormal);
    return uProjectionMatrix * uViewMatrix * vertex_position;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    return vec4(normalize(vOracleNormal) * 0.45 + 0.5, 1.0);
}
#endif
]]

local function opposite_mode(mode)
    return mode == "front" and "back" or "front"
end

local function expected_mode(projection, parity)
    if parity < 0 then
        return opposite_mode(projection.positive_parity_mode)
    end
    return projection.positive_parity_mode
end

local function primitive_row(size)
    return {
        0, 0, 0,
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
        size[1], size[2], size[3],
        1, 1, 1, 1,
        0,
        0, 0, 0, 0,
    }
end

local function new_minimal_core(RBX, Backend, primitive_vertices)
    return setmetatable({
        render_backend_name = "menori",
        _render_backend = Backend.new(),
        _primitive_vertices = primitive_vertices,
        _cube_vertices = primitive_vertices.Block,
        _cube_vertex_format = BASE_VERTEX_FORMAT,
        _instance_vertex_format = INSTANCE_VERTEX_FORMAT,
        _static_vertex_format = STATIC_VERTEX_FORMAT,
        use_instancing = true,
        constant_fragment_shader = false,
        accurate_mesh_normals = true,
    }, RBX)
end

local function image_metrics(reference, candidate)
    local width, height = reference:getDimensions()
    local changed = 0
    local foreground = 0
    local absolute_error = 0
    local max_error = 0

    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local rr, rg, rb, ra = reference:getPixel(x, y)
            local cr, cg, cb, ca = candidate:getPixel(x, y)
            if ra > 0.5 then
                foreground = foreground + 1
            end
            local error = math.abs(rr - cr)
                + math.abs(rg - cg)
                + math.abs(rb - cb)
                + math.abs(ra - ca)
            if error > (2.5 / 255) then
                changed = changed + 1
            end
            absolute_error = absolute_error + error
            max_error = math.max(max_error, error)
        end
    end

    return {
        changed = changed,
        foreground = foreground,
        absolute_error = absolute_error,
        max_error = max_error,
    }
end

local function release_resource(resource)
    if resource and resource.release then
        pcall(resource.release, resource)
    end
end

local function render_pixels(canvas, shader, view_matrix, projection_matrix,
                             front_face_winding, cull_mode, draw)
    love.graphics.push("all")
    local ok, result = xpcall(function()
        love.graphics.setCanvas({ canvas, depth = true })
        love.graphics.clear(0, 0, 0, 0, true, true)
        love.graphics.setBlendMode("replace", "premultiplied")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setDepthMode("less", true)
        love.graphics.setFrontFaceWinding(front_face_winding or "ccw")
        love.graphics.setMeshCullMode(cull_mode)
        love.graphics.setShader(shader)
        shader:send("uViewMatrix", view_matrix)
        shader:send("uProjectionMatrix", projection_matrix)
        draw()
        love.graphics.setShader()
        love.graphics.setCanvas()
        return canvas:newImageData()
    end, function(message)
        return debug.traceback(tostring(message), 2)
    end)
    love.graphics.pop()
    if not ok then
        error(result, 0)
    end
    return result
end

local function measure_path(canvas, shader, view_matrix, projection_matrix,
                            front_face_winding, cull_draw, release_draw)
    local none = render_pixels(
        canvas, shader, view_matrix, projection_matrix,
        front_face_winding, "none", cull_draw)
    local front = render_pixels(
        canvas, shader, view_matrix, projection_matrix,
        front_face_winding, "front", cull_draw)
    local back = render_pixels(
        canvas, shader, view_matrix, projection_matrix,
        front_face_winding, "back", cull_draw)

    local front_metrics = image_metrics(none, front)
    local back_metrics = image_metrics(none, back)
    release_resource(none)
    release_resource(front)
    release_resource(back)
    if release_draw then release_draw() end
    return front_metrics, back_metrics
end

local function assert_oracle_result(t, context, expected, expected_metrics,
                                    rejected_metrics)
    t.assert_that(expected_metrics.foreground >= 80,
        "%s: reference covered only %d pixels", context,
        expected_metrics.foreground)
    t.assert_that(expected_metrics.changed <= 2,
        "%s: expected cull-%s to match cull-none, but %d pixels changed "
            .. "(absolute error %.6f, max %.6f)",
        context, expected, expected_metrics.changed,
        expected_metrics.absolute_error, expected_metrics.max_error)
    t.assert_that(rejected_metrics.changed >= 24,
        "%s: opposite cull mode was not distinguishable from cull-none "
            .. "(only %d pixels changed, absolute error %.6f)",
        context, rejected_metrics.changed, rejected_metrics.absolute_error)
    t.assert_that(
        rejected_metrics.absolute_error
            > math.max(0.05, expected_metrics.absolute_error * 20),
        "%s: expected mode did not win decisively (expected error %.6f, "
            .. "opposite %.6f)",
        context, expected_metrics.absolute_error,
        rejected_metrics.absolute_error)
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end

    local RBX = harness.env.RBX
    local Backend = require("engine/graphics/rbx/runtime/backend/menori")
    local primitive_vertices = harness.env.build_primitive_vertices()
    local core = new_minimal_core(RBX, Backend, primitive_vertices)
    local canvas = love.graphics.newCanvas(96, 96, {
        format = "rgba8",
        dpiscale = 1,
        readable = true,
        msaa = 0,
    })
    canvas:setFilter("nearest", "nearest")

    local instanced_shader = love.graphics.newShader(INSTANCED_ORACLE_SHADER)
    local static_shader = love.graphics.newShader(STATIC_ORACLE_SHADER)
    local view_matrix = RBX._make_view_matrix(
        2.35, 1.80, 3.15,
        0, 0, 0,
        0, 1, 0)

    local ok, result = xpcall(function()
        t.describe("closed primitive GPU cull pixel oracle", function()
            t.it("matches cull-none for Menori and static LOVE at every scale parity", function()
                for projection_index = 1, #PROJECTION_CASES do
                    local projection = PROJECTION_CASES[projection_index]
                    local projection_matrix = RBX._make_projection_matrix(
                        math.rad(52), 0.1, 20, 1, projection.flip_y)

                    for scale_index = 1, #SCALE_CASES do
                        local scale_case = SCALE_CASES[scale_index]
                        local wanted = expected_mode(
                            projection, scale_case.parity)

                        for shape_index = 1, #SHAPES do
                            local shape = SHAPES[shape_index]
                            local row = primitive_row(scale_case.size)

                            local instanced_item =
                                core:_build_opaque_primitive_draw_item(
                                    shape, { row }, nil, {})
                            t.assert_that(
                                instanced_item
                                    and instanced_item.kind
                                        == "instanced_primitive",
                                "%s/%s/%s: Menori item was not instanced",
                                projection.name, scale_case.name, shape)
                            local instanced_front, instanced_back =
                                measure_path(
                                    canvas,
                                    instanced_shader,
                                    view_matrix,
                                    projection_matrix,
                                    projection.canvas_winding,
                                    function()
                                        love.graphics.drawInstanced(
                                            instanced_item.draw_mesh, 1)
                                    end,
                                    function()
                                        local batch =
                                            instanced_item
                                                ._instance_resource_batch
                                        if batch then batch:release() end
                                    end)
                            local instanced_expected =
                                wanted == "front"
                                    and instanced_front or instanced_back
                            local instanced_rejected =
                                wanted == "front"
                                    and instanced_back or instanced_front
                            assert_oracle_result(
                                t,
                                string.format(
                                    "Menori %s/%s/%s",
                                    projection.name,
                                    scale_case.name,
                                    shape),
                                wanted,
                                instanced_expected,
                                instanced_rejected)

                            local static_item =
                                core:_build_opaque_primitive_draw_item(
                                    shape, { row }, nil,
                                    { allow_instancing = false })
                            t.assert_that(
                                static_item
                                    and static_item.kind == "static",
                                "%s/%s/%s: LOVE fallback item was not static",
                                projection.name, scale_case.name, shape)
                            local static_front, static_back =
                                measure_path(
                                    canvas,
                                    static_shader,
                                    view_matrix,
                                    projection_matrix,
                                    projection.canvas_winding,
                                    function()
                                        love.graphics.draw(static_item.mesh)
                                    end,
                                    function()
                                        release_resource(static_item.mesh)
                                    end)
                            local static_expected =
                                wanted == "front"
                                    and static_front or static_back
                            local static_rejected =
                                wanted == "front"
                                    and static_back or static_front
                            assert_oracle_result(
                                t,
                                string.format(
                                    "LOVE static %s/%s/%s",
                                    projection.name,
                                    scale_case.name,
                                    shape),
                                wanted,
                                static_expected,
                                static_rejected)
                        end
                    end
                end
            end)
        end)
    end, function(message)
        return debug.traceback(tostring(message), 2)
    end)

    pcall(core._render_backend.release, core._render_backend)
    release_resource(instanced_shader)
    release_resource(static_shader)
    release_resource(canvas)

    if not ok then
        error(result, 0)
    end
end

return suite
