-- Menori vendoring smoke test.
--
-- Menori (engine/services/oss/menori) is the rendering backend Stage 6 targets.
-- It was chosen over 3DreamEngine and g3d on evidence:
--
--   engine        lines   updated    shadows  PBR  material  alpha  cull  instancing
--   3DreamEngine  16756   2023-05      28     27     35       30     13      12
--   Menori         8563   2025-08       0      1      9        9      6       7
--   g3d            1235   2025-12       0      0      0        0      0       0
--   (counts are files matching each feature; g3d's single "instanc" hit is a comment)
--
-- Menori is actively maintained AND has the batching/culling/material machinery a
-- 29k-part Roblox map needs. Its real gap is shadow mapping, which Stage 7 adds.
--
-- These tests pin the vendoring itself: the library must load from the oss path
-- with no root-relative requires left, and expose the API the adapter depends on.
-- Menori builds GPU resources at require time, so this suite needs graphics.

local suite = {}

suite.needs_graphics = true

local MENORI = "engine/services/oss/menori"

local function make_triangle_mesh(menori)
    return menori.Mesh({
        vertices = {
            { -0.5, -0.5, 0, 0, 0, 0, 0, 1 },
            {  0.5, -0.5, 0, 1, 0, 0, 0, 1 },
            {  0.0,  0.5, 0, 0.5, 1, 0, 0, 1 },
        },
        mode = "triangles",
    })
end

local function release_instancing_fixture(mesh, instances)
    if instances and instances.release then
        instances:release()
    end
    if mesh and mesh.lg_mesh and mesh.lg_mesh.release then
        mesh.lg_mesh:release()
    end
end

function suite.run(t, harness)
    local expect = t.expect

    local ok, menori = pcall(require, MENORI)

    t.describe("Menori vendoring", function()
        t.it("loads from engine/services/oss/menori", function()
            t.assert_that(ok, "require failed: %s", tostring(menori))
            expect(type(menori)):to_be("table")
        end)

        t.it("has no root-relative requires left after vendoring", function()
            -- Upstream required json by a game-root-relative path, which only
            -- resolves when the library sits at the root. Both sites were repointed
            -- at the vendored copy; this catches a regression on re-vendoring.
            -- Matches only a real require call, so an explanatory comment that
            -- mentions the old path does not trip it.
            local offenders = {}
            for _, rel in ipairs({ "/modules/core3d/gltf.lua", "/modules/spriteloader.lua" }) do
                local contents = love.filesystem.read(MENORI .. rel)
                if contents and contents:find("\n%s*local%s+json%s*=%s*require%s*['\"]libs%.json['\"]") then
                    offenders[#offenders + 1] = rel
                end
            end
            t.assert_that(#offenders == 0,
                "root-relative require 'libs.json' still present in: %s",
                table.concat(offenders, ", "))
        end)

        t.it("bundles its json dependency inside the vendored tree", function()
            t.assert_that(love.filesystem.getInfo(MENORI .. "/modules/libs/json.lua") ~= nil,
                "vendored json.lua is missing")
        end)
    end)

    if not ok then
        t.skip("Menori API surface", "library failed to load")
        return
    end

    t.describe("Menori API surface the adapter depends on", function()
        -- Stage 6 maps the Renderer interface onto these. If any disappears in a
        -- future re-vendor, the adapter breaks here rather than at runtime.
        local required = {
            "PerspectiveCamera", "Environment", "Material", "Mesh",
            "ModelNode", "InstancedMesh", "Node", "Scene", "UniformList",
            "NodeTreeBuilder", "glTFLoader", "ShaderUtils", "ml",
        }
        for _, name in ipairs(required) do
            t.it("exposes " .. name, function()
                t.assert_that(menori[name] ~= nil, "menori.%s is nil", name)
            end)
        end

        t.it("exposes a mat4/vec3/quat math layer", function()
            local ml = menori.ml
            expect(type(ml)):to_be("table")
            for _, name in ipairs({ "mat4", "vec3", "quat" }) do
                t.assert_that(ml[name] ~= nil, "menori.ml.%s is nil", name)
            end
        end)

        t.it("provides GPU instancing, which g3d does not", function()
            -- The single feature that makes a 29k-part map viable.
            expect(type(menori.InstancedMesh)):to_not_be("nil")
        end)
    end)

    t.describe("Menori instancing contract", function()
        t.it("accepts a menori.Mesh on LÖVE 11.5", function()
            local mesh = make_triangle_mesh(menori)
            local instances = menori.InstancedMesh(mesh, nil, 2)
            expect(instances.mesh):to_be(mesh)
            expect(instances.lg_mesh):to_be(mesh.lg_mesh)
            expect(instances:get_capacity()):to_be(2)
            t.assert_that(instances.format_attribute_indices_map.InstancePosition ~= nil,
                "default InstancePosition attribute is missing")
            release_instancing_fixture(mesh, instances)
        end)

        t.it("grows all the way to a large requested count", function()
            local mesh = make_triangle_mesh(menori)
            local instances = menori.InstancedMesh(mesh, nil, 2)
            instances:set_count(1000)
            expect(instances.count):to_be(1000)
            t.assert_that(instances:get_capacity() >= 1000,
                "capacity %d is below requested count", instances:get_capacity())

            instances:set_instance_data(1000, "InstancePosition", 7, 8, 9)
            local attribute_index = instances.format_attribute_indices_map.InstancePosition
            local x, y, z = instances.instanced_mesh_buffer:getVertexAttribute(1000, attribute_index)
            expect(x):to_be_near(7, 1e-6)
            expect(y):to_be_near(8, 1e-6)
            expect(z):to_be_near(9, 1e-6)
            release_instancing_fixture(mesh, instances)
        end)

        t.it("bulk uploads instance data and updates count atomically", function()
            local mesh = make_triangle_mesh(menori)
            local instances = menori.InstancedMesh(mesh, nil, 1)
            instances:set_instances({
                { 1, 2, 3 },
                { 4, 5, 6 },
                { 7, 8, 9 },
            })
            expect(instances.count):to_be(3)
            t.assert_that(instances:get_capacity() >= 3)
            local x, y, z = instances.instanced_mesh_buffer:getVertex(3)
            expect(x):to_be_near(7, 1e-6)
            expect(y):to_be_near(8, 1e-6)
            expect(z):to_be_near(9, 1e-6)
            release_instancing_fixture(mesh, instances)
        end)

        t.it("keeps the live buffer attached when growth allocation fails", function()
            local mesh = make_triangle_mesh(menori)
            local instances = menori.InstancedMesh(mesh, nil, 1)
            instances:set_instances({ { 1, 2, 3 } })
            local original_buffer = instances.instanced_mesh_buffer
            local original_new_mesh = love.graphics.newMesh

            love.graphics.newMesh = function()
                error("injected instance-buffer allocation failure")
            end
            local growth_ok, growth_error = pcall(instances.set_instances, instances, {
                { 4, 5, 6 },
                { 7, 8, 9 },
            })
            love.graphics.newMesh = original_new_mesh

            expect(growth_ok):to_be(false)
            t.assert_that(tostring(growth_error):find(
                "injected instance%-buffer allocation failure") ~= nil,
                "unexpected growth error: %s", tostring(growth_error))
            expect(instances.instanced_mesh_buffer):to_be(original_buffer)
            expect(instances:get_capacity()):to_be(1)
            expect(instances.count):to_be(1)

            local x, y, z = original_buffer:getVertex(1)
            expect(x):to_be_near(1, 1e-6)
            expect(y):to_be_near(2, 1e-6)
            expect(z):to_be_near(3, 1e-6)

            love.graphics.push("all")
            local draw_ok, draw_error = pcall(
                love.graphics.drawInstanced, mesh.lg_mesh, instances.count)
            love.graphics.pop()
            t.assert_that(draw_ok,
                "old instance attachment was not draw-ready: %s", tostring(draw_error))
            release_instancing_fixture(mesh, instances)
        end)

        t.it("compiles and submits the bundled instanced shader", function()
            local mesh = make_triangle_mesh(menori)
            local instances = menori.InstancedMesh(mesh, nil, 1)
            instances:set_instances({ { 0, 0, 0 } })

            local material = menori.Material({
                shader_vertcode = menori.ShaderUtils.cache.instanced_mesh_vert,
                shader_fragcode = menori.ShaderUtils.cache.default_mesh_frag,
            })
            material.attributes = instances.vertexformat
            material.shader = menori.ShaderUtils.create_shader(material, instances)
            material._needs_update = false
            material:set("baseColor", { 1, 1, 1, 1 })

            love.graphics.push("all")
            love.graphics.setShader(material.shader)
            local draw_ok, draw_err = pcall(instances.draw, instances, material)
            love.graphics.pop()
            t.assert_that(draw_ok, "instanced draw failed: %s", tostring(draw_err))
            release_instancing_fixture(mesh, instances)
        end)
    end)

    t.describe("Menori math agrees with the Roblox conventions", function()
        -- The adapter must not silently re-interpret handedness. These pin
        -- Menori's mat4/vec3 against the same conventions coordinate_spec.lua
        -- pins for the runtime, so a mismatch is caught at the seam.
        local ml = menori.ml
        local vec3 = ml.vec3

        t.it("vec3 cross product is right-handed (X cross Y = +Z)", function()
            -- Roblox is right-handed. If Menori's cross were left-handed the
            -- adapter would need a sign flip everywhere; this pins that it does not.
            local c = vec3.cross(vec3(1, 0, 0), vec3(0, 1, 0))
            expect(c.x):to_be_near(0, 1e-9)
            expect(c.y):to_be_near(0, 1e-9)
            expect(c.z):to_be_near(1, 1e-9)
        end)

        t.it("vec3 cross anti-commutes (Y cross X = -Z)", function()
            local c = vec3.cross(vec3(0, 1, 0), vec3(1, 0, 0))
            expect(c.z):to_be_near(-1, 1e-9)
        end)

        t.it("vec3 dot matches the standard definition", function()
            expect(vec3.dot(vec3(1, 2, 3), vec3(4, -5, 6))):to_be_near(1 * 4 + 2 * -5 + 3 * 6, 1e-9)
        end)
    end)
end

return suite
