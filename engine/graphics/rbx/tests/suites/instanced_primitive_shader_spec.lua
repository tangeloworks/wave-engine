-- Regression coverage for the shared primitive-instancing shaders.
--
-- A position uses R*S, but a normal uses inverse-transpose(R*S).  With the
-- orthonormal instance basis uploaded by the renderer this is R*(n/S), not R*n.
-- Blocks hid the bug because each of their normals has only one non-zero component;
-- Wedge, Cylinder and Ball normals expose it immediately under non-uniform scale.

local suite = {}

suite.needs_graphics = true

local RUNTIME_MODULES = {
    "common.lua",
    "geometry.lua",
    "assets.lua",
}

local BASIS = {
    right = { 0.0, 0.0, -1.0 },
    up = { 0.6, 0.8, 0.0 },
    back = { 0.8, -0.6, 0.0 },
}

local function dot(a, b)
    return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function cross(a, b)
    return {
        a[2] * b[3] - a[3] * b[2],
        a[3] * b[1] - a[1] * b[3],
        a[1] * b[2] - a[2] * b[1],
    }
end

local function normalize(v)
    local length = math.sqrt(dot(v, v))
    assert(length > 1e-12, "cannot normalize a zero vector")
    return { v[1] / length, v[2] / length, v[3] / length }
end

local function rotate(v)
    return {
        BASIS.right[1] * v[1] + BASIS.up[1] * v[2] + BASIS.back[1] * v[3],
        BASIS.right[2] * v[1] + BASIS.up[2] * v[2] + BASIS.back[2] * v[3],
        BASIS.right[3] * v[1] + BASIS.up[3] * v[2] + BASIS.back[3] * v[3],
    }
end

local function transform_tangent(v, scale)
    return rotate({
        v[1] * scale[1],
        v[2] * scale[2],
        v[3] * scale[3],
    })
end

local function shader_normal(local_normal, scale)
    return normalize(rotate({
        local_normal[1] / scale[1],
        local_normal[2] / scale[2],
        local_normal[3] / scale[3],
    }))
end

local function legacy_normal(local_normal)
    return normalize(rotate(local_normal))
end

-- Independently derives the transformed surface normal from two transformed
-- tangent vectors.  This is the geometric reference the shader must match.
local function geometric_normal(local_normal, scale)
    local n = normalize(local_normal)
    local ax, ay, az = math.abs(n[1]), math.abs(n[2]), math.abs(n[3])
    local seed
    if ax <= ay and ax <= az then
        seed = { 1, 0, 0 }
    elseif ay <= az then
        seed = { 0, 1, 0 }
    else
        seed = { 0, 0, 1 }
    end
    local tangent = normalize(cross(seed, n))
    local bitangent = normalize(cross(n, tangent))
    return normalize(cross(
        transform_tangent(tangent, scale),
        transform_tangent(bitangent, scale)
    ))
end

local function normal_from_vertex(vertex)
    return { vertex[4], vertex[5], vertex[6] }
end

local function find_normal(vertices, predicate)
    for index = 1, #vertices do
        local normal = normal_from_vertex(vertices[index])
        if predicate(normal) then
            return normal
        end
    end
    return nil
end

local function assert_vec_near(t, actual, expected, tolerance, label)
    tolerance = tolerance or 1e-6
    for axis = 1, 3 do
        t.assert_that(math.abs(actual[axis] - expected[axis]) <= tolerance,
            "%s axis %d: expected %.9f, got %.9f",
            label, axis, expected[axis], actual[axis])
    end
end

-- Keep the production vertex stage, reading its normal and AO varyings back
-- directly. This exercises the real 27-float repeated-mesh instance ABI.
local function projected_material_pixel(source, primitive)
    local fragment_start = assert(source:find("#ifdef PIXEL\nvec3 decodeNormal", 1, true))
    local shader = love.graphics.newShader(source:sub(1, fragment_start - 1) .. [[
        #ifdef PIXEL
        vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen) {
            return vec4(normalize(vNormal) * 0.5 + 0.5, vContactAO);
        }
        #endif
    ]])
    local mesh = love.graphics.newMesh({
        { "VertexPosition", "float", 3 },
        { "VertexNormal", "float", 3 },
        { "VertexTexCoord", "float", 2 },
        { "VertexColor", "float", 4 },
        { "VertexFaceId", "float", 1 },
    }, {
        { -0.8, -0.8, 0, 2, 1, 1, 0, 0, 1, 1, 1, 1, 0 },
        { 0.8, -0.8, 0, 2, 1, 1, 0, 0, 1, 1, 1, 1, 0 },
        { 0, 0.8, 0, 2, 1, 1, 0, 0, 1, 1, 1, 1, 0 },
    }, "triangles", "static")
    local instance_format = {
        { "InstancePosition", "float", 3 },
        { "InstanceRight", "float", 3 },
        { "InstanceUp", "float", 3 },
        { "InstanceBack", "float", 3 },
        { "InstanceScale", "float", 3 },
        { "InstanceColor", "float", 4 },
        { "InstanceMisc", "float", 4 },
        { "InstanceContactAO", "float", 4 },
    }
    local instances = love.graphics.newMesh(instance_format, {
        { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 4, 0.5, 2,
          1, 1, 1, 1, 0, 0, 0, 0, 0.17, 0.29, 0.53, 0.10 },
    }, "points", "static")
    for _, attribute in ipairs(instance_format) do
        mesh:attachAttribute(attribute[1], instances, "perinstance")
    end
    shader:send("uViewRotationMatrix", {
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
    })
    shader:send("uProjectionMatrix", {
        0.25, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 1,
    })
    shader:send("uCameraPos", { 0, 0, 0 })
    shader:send("uDepthBias", 0)
    shader:send("uPrimitiveMaterial", primitive and 1 or 0)
    local canvas = love.graphics.newCanvas(16, 16, { format = "rgba16f", msaa = 0 })
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setStencilTest()
    love.graphics.setWireframe(false)
    love.graphics.setColorMask(true, true, true, true)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(shader)
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.setDepthMode()
    love.graphics.setMeshCullMode("none")
    love.graphics.drawInstanced(mesh, 1)
    love.graphics.pop()
    local data = canvas:newImageData()
    local pixel = { data:getPixel(8, 8) }
    data:release()
    canvas:release()
    mesh:release()
    instances:release()
    shader:release()
    return pixel
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end

    local env = harness.env
    local shaders = {
        full = env.INSTANCED_SHADER,
        fast = env.FAST_INSTANCED_SHADER,
        depth = env.INSTANCED_DEPTH_SHADER,
        material_projected = env.INSTANCED_MESH_MATERIAL_SHADER,
    }

    t.describe("shared primitive instancing shader source", function()
        t.it("uses inverse-transpose scale in full and fast variants", function()
            for _, name in ipairs({ "full", "fast" }) do
                local source = shaders[name]
                t.assert_that(type(source) == "string", "%s shader source is missing", name)
                t.expect(source):to_contain("vec3 scaledNormal = VertexNormal / safeSize;")
                t.expect(source):to_contain("(InstanceRight * scaledNormal.x)")
                t.expect(source):to_contain("selectContactAO(VertexNormal, InstanceContactAO)")
                t.assert_that(
                    source:find("(InstanceRight * VertexNormal.x)", 1, true) == nil,
                    "%s shader still rotates the unscaled local normal", name)
            end
        end)

        t.it("keeps the depth prepass camera-relative and clip-bias identical to color", function()
            local source = shaders.depth
            t.expect(source):to_contain("uniform vec3 uCameraPos;")
            t.expect(source):to_contain("vec4(worldPos - uCameraPos, 1.0)")
            t.expect(source):to_contain("clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);")
        end)
    end)

    t.describe("shared primitive instancing shader compilation", function()
        for _, name in ipairs({ "full", "fast", "depth", "material_projected" }) do
            t.it("compiles the " .. name .. " variant", function()
                local ok, shader_or_error = pcall(love.graphics.newShader, shaders[name])
                t.assert_that(ok, "%s shader failed to compile: %s", name, tostring(shader_or_error))
                if ok and shader_or_error and shader_or_error.release then
                    shader_or_error:release()
                end
            end)
        end

        t.it("keeps geometric material normals and distinct authored contact lanes on GPU", function()
            -- Two independent surface tangents orthogonal to authored (2,1,1).
            -- Their scaled cross product gives the expected lighting normal.
            local scale = { 4, 0.5, 2 }
            local a, b = { -1, 2, 0 }, { -1, 0, 2 }
            for axis = 1, 3 do
                a[axis] = a[axis] * scale[axis]
                b[axis] = b[axis] * scale[axis]
            end
            local normal = normalize(cross(a, b))
            local primitive = projected_material_pixel(shaders.material_projected, true)
            local imported = projected_material_pixel(shaders.material_projected, false)
            for axis = 1, 3 do
                t.expect(primitive[axis]):to_be_near(normal[axis] * 0.5 + 0.5, 0.001)
                t.expect(imported[axis]):to_be_near(primitive[axis], 0.001)
            end
            t.expect(primitive[4]):to_be_near(0.53, 0.001)
            t.expect(imported[4]):to_be_near(0.17, 0.001)
        end)
    end)

    local primitives = env.build_primitive_vertices()
    local cases = {
        {
            name = "Wedge",
            scale = { 4.0, 0.5, 2.0 },
            predicate = function(n)
                return math.abs(n[2]) > 0.2 and math.abs(n[3]) > 0.2
            end,
        },
        {
            name = "Cylinder",
            scale = { 3.0, 0.7, 2.5 },
            predicate = function(n)
                return math.abs(n[2]) > 0.2 and math.abs(n[3]) > 0.2
            end,
        },
        {
            name = "Ball",
            scale = { 0.5, 4.0, 1.5 },
            predicate = function(n)
                return math.abs(n[1]) > 0.15
                    and math.abs(n[2]) > 0.15
                    and math.abs(n[3]) > 0.15
            end,
        },
    }

    t.describe("non-uniform primitive normal parity", function()
        for _, case in ipairs(cases) do
            t.it("matches transformed geometry for " .. case.name, function()
                local normal = find_normal(primitives[case.name], case.predicate)
                t.assert_that(normal ~= nil, "%s fixture has no representative curved/sloped normal", case.name)

                local actual = shader_normal(normal, case.scale)
                local expected = geometric_normal(normal, case.scale)
                assert_vec_near(t, actual, expected, 1e-6, case.name)
                t.expect(dot(actual, expected)):to_be_near(1.0, 1e-6)

                -- Prove this fixture exercises the fixed path: rotating the raw
                -- local normal must disagree materially with the transformed plane.
                local old = legacy_normal(normal)
                t.assert_that(dot(old, expected) < 0.995,
                    "%s fixture does not distinguish inverse-transpose from legacy rotation",
                    case.name)
            end)
        end

        t.it("leaves every Block face normal unchanged", function()
            local scale = { 7.0, 0.25, 3.0 }
            for index = 1, #primitives.Block do
                local normal = normal_from_vertex(primitives.Block[index])
                assert_vec_near(
                    t,
                    shader_normal(normal, scale),
                    legacy_normal(normal),
                    1e-7,
                    "Block vertex " .. tostring(index)
                )
            end
        end)
    end)
end

return suite
