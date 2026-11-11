-- Focused contract tests for the RBX-specific Menori batch backend.

local suite = {}

suite.needs_graphics = true

local BACKEND_MODULE = "engine/graphics/rbx/runtime/backend/menori"

local BASE_FORMAT = {
    { "VertexPosition", "float", 3 },
    { "VertexNormal", "float", 3 },
}

local BASE_VERTICES = {
    { -0.5, -0.5, 0, 0, 0, 1 },
    {  0.5, -0.5, 0, 0, 0, 1 },
    {  0.0,  0.5, 0, 0, 0, 1 },
}

local INSTANCE_FORMAT = {
    { "InstancePosition", "float", 3 },
    { "InstanceColor", "float", 4 },
}

local function row(x, r, g, b, a)
    return { x, 0, 0, r, g, b, a }
end

local function pack_base_vertices(vertices)
    local chunks = {}
    for index = 1, #vertices do
        chunks[index] = love.data.pack(
            "string", "<ffffff", unpack(vertices[index]))
    end
    return love.data.newByteData(table.concat(chunks))
end

function suite.run(t, harness)
    local expect = t.expect
    local Backend = require(BACKEND_MODULE)

    t.describe("RBX Menori backend identity", function()
        t.it("advertises the renderer seam it implements", function()
            local backend = Backend.new()
            local identity = backend:get_identity()

            expect(backend.id):to_be("menori")
            expect(backend.name):to_be("menori")
            expect(identity.id):to_be("menori")
            expect(identity.name):to_be("Menori")
            expect(identity.opaque_instancing):to_be(true)
            expect(identity.static_mesh_resources):to_be(true)
            expect(identity.static_mesh_updates):to_be(true)
            expect(identity.raw_mesh_adoption):to_be(true)
            expect(identity.indexed_geometry):to_be(true)
            expect(identity.uint16_indices):to_be(true)
            expect(identity.uint32_indices):to_be(true)
            expect(identity.legacy_raw_meshes):to_be(true)
        end)
    end)

    t.describe("RBX Menori static mesh resource batches", function()
        t.it("owns indexed textured geometry and reports exact live/upload bytes", function()
            local backend = Backend.new()
            local vertices = {
                { -0.5, -0.5, 0, 0, 0, 1 },
                {  0.5, -0.5, 0, 0, 0, 1 },
                {  0.5,  0.5, 0, 0, 0, 1 },
                { -0.5,  0.5, 0, 0, 0, 1 },
            }
            local indices = { 1, 2, 3, 1, 3, 4 }
            local authoritative_bound = { tag = "renderer-owned-bound" }
            local batch = backend:create_static_mesh_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = vertices,
                indices = indices,
                indices_tsize = 2,
                textured = true,
                kind = "static_textured_test",
                bound = authoritative_bound,
            })

            expect(batch.static_mesh):to_be(true)
            expect(batch.kind):to_be("static_textured_test")
            expect(batch.textured):to_be(true)
            expect(batch.base_mesh.lg_mesh):to_be(batch.draw_mesh)
            expect(batch.raw_draw_mesh):to_be_nil()
            expect(batch.instance_mesh):to_be_nil()
            expect(batch.base_mesh.bound):to_be(authoritative_bound)
            expect(batch.bound):to_be(authoritative_bound)
            expect(batch.vertex_count):to_be(4)
            expect(batch.vertex_capacity):to_be(4)
            expect(batch.vertex_stride_bytes):to_be(24)
            expect(batch.index_count):to_be(6)
            expect(batch.indices_tsize):to_be(2)
            expect(batch.vertex_bytes):to_be(96)
            expect(batch.index_bytes):to_be(12)
            local gpu_map = batch.draw_mesh:getVertexMap()
            expect(#gpu_map):to_be(6)

            local stats = backend:get_stats()
            expect(stats.created_batches):to_be(1)
            expect(stats.created_static_batches):to_be(1)
            expect(stats.created_textured_batches):to_be(1)
            expect(stats.live_static_batches):to_be(1)
            expect(stats.live_textured_batches):to_be(1)
            expect(stats.live_static_vertex_bytes):to_be(96)
            expect(stats.live_static_index_bytes):to_be(12)
            expect(stats.live_static_bytes):to_be(108)
            expect(stats.live_textured_bytes):to_be(108)
            expect(stats.peak_live_static_bytes):to_be(108)
            expect(stats.peak_live_textured_bytes):to_be(108)
            expect(stats.static_uploads):to_be(1)
            expect(stats.uploaded_static_vertex_bytes):to_be(96)
            expect(stats.uploaded_static_index_bytes):to_be(12)
            expect(stats.uploaded_static_bytes):to_be(108)
            expect(stats.uploaded_textured_bytes):to_be(108)
            expect(stats.live_base_vertices):to_be(4)
            expect(stats.live_base_indices):to_be(6)

            expect(batch:release()):to_be(true)
            expect(batch:release()):to_be(false)
            stats = backend:get_stats()
            expect(stats.released_static_batches):to_be(1)
            expect(stats.released_textured_batches):to_be(1)
            expect(stats.live_static_batches):to_be(0)
            expect(stats.live_textured_batches):to_be(0)
            expect(stats.live_static_bytes):to_be(0)
            expect(stats.live_textured_bytes):to_be(0)
        end)

        t.it("uploads packed stream capacity without calculating a mesh bound", function()
            local backend = Backend.new()
            local packed = pack_base_vertices(BASE_VERTICES)
            local batch = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                vertex_data = packed,
                vertex_count = 3,
                vertex_capacity = 5,
                usage = "stream",
                skip_bound_calculation = true,
            })
            packed:release()

            expect(batch.usage):to_be("stream")
            expect(batch.base_mesh.usage):to_be("stream")
            expect(batch.base_mesh.bound):to_be_nil()
            expect(batch.vertex_count):to_be(3)
            expect(batch.vertex_capacity):to_be(5)
            expect(batch.draw_mesh:getVertexCount()):to_be(5)
            local x = batch.draw_mesh:getVertex(2)
            expect(x):to_be_near(0.5, 1e-6)

            local stats = backend:get_stats()
            -- Five vertices are allocated, but only the three-vertex payload is
            -- uploaded. The two counters deliberately describe different facts.
            expect(stats.live_static_vertex_bytes):to_be(120)
            expect(stats.uploaded_static_vertex_bytes):to_be(72)
            expect(stats.uploaded_static_bytes):to_be(72)

            local original = batch.draw_mesh
            local expanded_vertices = {
                BASE_VERTICES[1], BASE_VERTICES[2], BASE_VERTICES[3],
                { 0, -0.75, 0, 0, 0, 1 },
            }
            local expanded = pack_base_vertices(expanded_vertices)
            expect(batch:update({
                vertex_data = expanded,
                vertex_count = 4,
            })):to_be(batch)
            expanded:release()
            expect(batch.draw_mesh):to_be(original)
            expect(batch.vertex_count):to_be(4)
            expect(batch.vertex_capacity):to_be(5)
            local fourth_x, fourth_y = batch.draw_mesh:getVertex(4)
            expect(fourth_x):to_be_near(0, 1e-6)
            expect(fourth_y):to_be_near(-0.75, 1e-6)
            stats = backend:get_stats()
            expect(stats.static_updates):to_be(1)
            expect(stats.static_replacements):to_be(0)
            expect(stats.live_static_vertex_bytes):to_be(120)
            expect(stats.uploaded_static_vertex_bytes):to_be(168)
            backend:release()
        end)

        t.it("hides the raw draw alias while a stream batch has zero vertices", function()
            local backend = Backend.new()
            local batch = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                vertex_capacity = 5,
                usage = "stream",
            })
            local resource = batch.draw_mesh

            expect(batch:update({ vertex_count = 0 })):to_be(batch)
            expect(batch.vertex_count):to_be(0)
            expect(batch.count):to_be(0)
            expect(batch.draw_count):to_be(0)
            expect(batch.drawable):to_be(false)
            expect(batch.draw_mesh):to_be_nil()
            expect(batch.resource_mesh):to_be(resource)
            expect(batch.base_mesh.lg_mesh):to_be(resource)
            expect(batch.base_mesh.vertex_count):to_be(0)
            expect(backend:get_stats().live_base_vertices):to_be(0)

            expect(batch:update({
                base_vertices = { BASE_VERTICES[1], BASE_VERTICES[2] },
                vertex_count = 2,
            })):to_be(batch)
            expect(batch.vertex_count):to_be(2)
            expect(batch.count):to_be(2)
            expect(batch.draw_count):to_be(2)
            expect(batch.drawable):to_be(true)
            expect(batch.draw_mesh):to_be(resource)
            local first, count = resource:getDrawRange()
            expect(first):to_be(1)
            expect(count):to_be(2)
            expect(backend:get_stats().static_updates):to_be(2)
            backend:release()
        end)

        t.it("rejects a stride change on an in-place static update", function()
            local backend = Backend.new()
            local batch = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                usage = "dynamic",
            })
            local original = batch.draw_mesh
            local ok, update_error = pcall(batch.update, batch, {
                base_vertices = BASE_VERTICES,
                vertex_stride_bytes = 12,
            })

            expect(ok):to_be(false)
            t.assert_that(tostring(update_error):find(
                "cannot change vertex_stride_bytes", 1, true) ~= nil,
                "unexpected stride validation error: %s", tostring(update_error))
            expect(batch.draw_mesh):to_be(original)
            expect(batch.vertex_stride_bytes):to_be(24)
            expect(backend:get_stats().static_updates):to_be(0)
            backend:release()
        end)

        t.it("adopts a raw LOVE mesh without taking unrequested ownership", function()
            local backend = Backend.new()
            local raw = love.graphics.newMesh(
                BASE_FORMAT, BASE_VERTICES, "triangles", "dynamic")
            local authoritative_bound = { min_x = -0.5, max_x = 0.5 }
            local batch = backend:create_static_batch({
                draw_mesh = raw,
                owns_draw_mesh = false,
                vertex_count = 3,
                usage = "dynamic",
                bound = authoritative_bound,
                textured = true,
            })

            expect(batch.adopted):to_be(true)
            expect(batch.owns_draw_mesh):to_be(false)
            expect(batch.raw_draw_mesh):to_be(raw)
            expect(batch.draw_mesh):to_be(raw)
            expect(batch.base_mesh.lg_mesh):to_be(raw)
            expect(batch.base_mesh.adopted):to_be(true)
            expect(batch.base_mesh.bound):to_be(authoritative_bound)
            local stats = backend:get_stats()
            expect(stats.adopted_static_batches):to_be(1)
            expect(stats.live_adopted_static_batches):to_be(1)
            expect(stats.live_static_vertex_bytes):to_be(72)
            expect(stats.uploaded_static_bytes):to_be(0)

            expect(batch:release()):to_be(true)
            if raw.isReleased then
                expect(raw:isReleased()):to_be(false)
            end
            expect(backend:get_stats().live_adopted_static_batches):to_be(0)
            raw:release()
        end)

        t.it("updates equal-size payloads and atomically replaces changed capacity", function()
            local backend = Backend.new()
            local batch = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                usage = "dynamic",
            })
            local original = batch.draw_mesh
            local updated = {
                { -2, -0.5, 0, 0, 0, 1 },
                {  2, -0.5, 0, 0, 0, 1 },
                {  0,  2.0, 0, 0, 0, 1 },
            }
            expect(batch:update(updated)):to_be(batch)
            expect(batch.draw_mesh):to_be(original)
            local x = batch.draw_mesh:getVertex(1)
            expect(x):to_be_near(-2, 1e-6)

            local replacement_vertices = {
                updated[1], updated[2], updated[3],
                { 0, -2, 0, 0, 0, 1 },
            }
            expect(batch:update({
                base_vertices = replacement_vertices,
                vertex_count = 4,
            })):to_be(batch)
            expect(batch.draw_mesh):to_not_be(original)
            expect(batch.vertex_count):to_be(4)
            expect(batch.vertex_capacity):to_be(4)
            if original.isReleased then
                expect(original:isReleased()):to_be(true)
            end

            local stats = backend:get_stats()
            expect(stats.static_updates):to_be(1)
            expect(stats.static_replacements):to_be(1)
            expect(stats.static_uploads):to_be(3)
            expect(stats.updated_static_vertex_bytes):to_be(72)
            expect(stats.replacement_static_vertex_bytes):to_be(96)
            expect(stats.uploaded_static_vertex_bytes):to_be(240)
            expect(stats.live_static_vertex_bytes):to_be(96)
            expect(stats.live_base_vertices):to_be(4)
            backend:reset()
        end)

        t.it("keeps the old resource live when replacement validation fails", function()
            local backend = Backend.new()
            local batch = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
            })
            local original = batch.draw_mesh
            local too_short = love.data.newByteData(4)
            local ok = pcall(batch.replace, batch, {
                base_vertex_format = BASE_FORMAT,
                vertex_data = too_short,
                vertex_count = 4,
            })
            too_short:release()
            expect(ok):to_be(false)
            expect(batch.draw_mesh):to_be(original)
            expect(batch.released):to_be(false)
            expect(backend:get_stats().static_replacement_errors):to_be(1)
            backend:release()
        end)

        t.it("releases a newly built mesh when replacement commit fails", function()
            local menori = require("engine/services/oss/menori")
            local captured_mesh
            local implementation = {}
            for key, value in pairs(menori) do
                implementation[key] = value
            end
            implementation.Mesh = function(spec)
                local owner = menori.Mesh(spec)
                captured_mesh = owner.lg_mesh
                return owner
            end

            local backend = Backend.new({ menori = implementation })
            local batch = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
            })
            local original = batch.resource_mesh
            captured_mesh = nil

            -- Fault-inject the first commit-time counter operation, after the
            -- replacement resource has been constructed but before the batch
            -- descriptor has changed.
            local live_static_batches = backend.stats.live_static_batches
            backend.stats.live_static_batches = {}
            local ok = pcall(batch.replace, batch, {
                base_vertices = {
                    BASE_VERTICES[1], BASE_VERTICES[2], BASE_VERTICES[3],
                    { 0, -1, 0, 0, 0, 1 },
                },
            })
            backend.stats.live_static_batches = live_static_batches

            expect(ok):to_be(false)
            expect(batch.resource_mesh):to_be(original)
            expect(batch.draw_mesh):to_be(original)
            t.assert_that(captured_mesh ~= nil,
                "replacement never constructed its candidate mesh")
            expect(captured_mesh):to_not_be(original)
            if captured_mesh.isReleased then
                expect(captured_mesh:isReleased()):to_be(true)
            end
            expect(backend:get_stats().static_replacement_errors):to_be(1)
            backend:release()
        end)

        t.it("accounts externally selected textured fallbacks without inventing uploads", function()
            local backend = Backend.new()
            local bytes = backend:note_static_fallback({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                indices = { 1, 2, 3 },
                indices_tsize = 2,
                textured = true,
            }, "injected backend failure")
            expect(bytes):to_be(78)
            local stats = backend:get_stats()
            expect(stats.static_fallback_count):to_be(1)
            expect(stats.textured_fallback_count):to_be(1)
            expect(stats.fallback_static_vertex_bytes):to_be(72)
            expect(stats.fallback_static_index_bytes):to_be(6)
            expect(stats.fallback_static_bytes):to_be(78)
            expect(stats.fallback_textured_bytes):to_be(78)
            expect(stats.uploaded_static_bytes):to_be(0)
            expect(stats.static_fallback_reasons["injected backend failure"]):to_be(1)

            stats.static_fallback_reasons["injected backend failure"] = 99
            expect(backend:get_stats().static_fallback_reasons[
                "injected backend failure"]):to_be(1)
        end)

        t.it("resets mixed static owners exactly once and remains reusable", function()
            local backend = Backend.new()
            local generated = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
            })
            local raw = love.graphics.newMesh(
                BASE_FORMAT, BASE_VERTICES, "triangles", "static")
            local adopted = backend:create_static_batch({
                draw_mesh = raw,
                owns_draw_mesh = true,
                vertex_count = 3,
            })

            expect(backend:reset()):to_be(2)
            expect(backend:reset()):to_be(0)
            expect(generated.released):to_be(true)
            expect(adopted.released):to_be(true)
            if raw.isReleased then
                expect(raw:isReleased()):to_be(true)
            end
            local stats = backend:get_stats()
            expect(stats.released_static_batches):to_be(2)
            expect(stats.live_static_batches):to_be(0)
            expect(stats.live_static_bytes):to_be(0)
            expect(stats.release_errors):to_be(0)

            local replacement = backend:create_static_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                usage = "stream",
            })
            expect(replacement.released):to_be(false)
            expect(backend:get_stats().live_static_batches):to_be(1)
            backend:release()
        end)
    end)

    t.describe("RBX Menori opaque instanced batches", function()
        t.it("publishes raw LOVE handles alongside Menori owners", function()
            local backend = Backend()
            local batch = backend:create_opaque_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                instance_format = INSTANCE_FORMAT,
                instance_rows = {
                    row(1, 1, 0, 0, 1),
                    row(2, 0, 1, 0, 1),
                },
                initial_capacity = 2,
            })

            expect(batch.backend_id):to_be("menori")
            expect(batch.kind):to_be("opaque_instanced")
            expect(batch.draw_mesh):to_be(batch.base_mesh.lg_mesh)
            expect(batch.instance_mesh):to_be(batch.instances.instanced_mesh_buffer)
            t.assert_that(batch.draw_mesh:typeOf("Mesh"), "draw_mesh is not a LOVE Mesh")
            t.assert_that(batch.instance_mesh:typeOf("Mesh"), "instance_mesh is not a LOVE Mesh")
            expect(batch.instance_count):to_be(2)

            local x = batch.instance_mesh:getVertex(2)
            expect(x):to_be_near(2, 1e-6)

            love.graphics.push("all")
            love.graphics.setShader()
            local draw_ok, draw_error = pcall(
                love.graphics.drawInstanced, batch.draw_mesh, batch.instance_count)
            love.graphics.pop()
            t.assert_that(draw_ok, "legacy raw-handle draw failed: %s", tostring(draw_error))
            batch:release()
        end)

        t.it("grows through Menori and refreshes the raw instance alias", function()
            local backend = Backend.new()
            local batch = backend:create_opaque_batch(
                BASE_FORMAT,
                BASE_VERTICES,
                INSTANCE_FORMAT,
                { row(1, 1, 1, 1, 1) },
                { initial_capacity = 1 })
            local original_instance_mesh = batch.instance_mesh

            batch:update({
                row(10, 1, 0, 0, 1),
                row(20, 0, 1, 0, 1),
                row(30, 0, 0, 1, 1),
                row(40, 1, 1, 0, 1),
                row(50, 1, 0, 1, 1),
            })

            expect(batch.instance_count):to_be(5)
            expect(batch.instances.count):to_be(5)
            expect(batch.instance_mesh):to_be(batch.instances.instanced_mesh_buffer)
            expect(batch.instance_mesh):to_not_be(original_instance_mesh)
            t.assert_that(batch.instance_capacity >= 5,
                "capacity %d is below the uploaded row count", batch.instance_capacity)
            local x = batch.instance_mesh:getVertex(5)
            expect(x):to_be_near(50, 1e-6)

            local stats = backend:get_stats()
            expect(stats.created_batches):to_be(1)
            expect(stats.live_batches):to_be(1)
            expect(stats.live_instances):to_be(5)
            expect(stats.instance_uploads):to_be(2)
            expect(stats.uploaded_instance_rows):to_be(6)
            expect(stats.buffer_reallocations):to_be(1)
            backend:release()
        end)

        t.it("owns uint16 vertex maps and accounts their resources", function()
            local backend = Backend.new()
            local vertices = {
                { -0.5, -0.5, 0, 0, 0, 1 },
                {  0.5, -0.5, 0, 0, 0, 1 },
                {  0.5,  0.5, 0, 0, 0, 1 },
                { -0.5,  0.5, 0, 0, 0, 1 },
            }
            local indices = { 1, 2, 3, 1, 3, 4 }
            local batch = backend:create_opaque_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = vertices,
                vertex_count = #vertices,
                source_vertex_count = #indices,
                indices = indices,
                indices_tsize = 2,
                instance_format = INSTANCE_FORMAT,
                instance_rows = { row(1, 1, 1, 1, 1) },
            })

            expect(batch.indexed):to_be(true)
            expect(batch.indices_tsize):to_be(2)
            expect(batch.vertex_count):to_be(4)
            expect(batch.source_vertex_count):to_be(6)
            expect(batch.index_count):to_be(6)
            local gpu_map = batch.draw_mesh:getVertexMap()
            expect(#gpu_map):to_be(6)
            for index = 1, #indices do
                expect(gpu_map[index]):to_be(indices[index])
            end

            local live = backend:get_stats()
            expect(live.live_base_vertices):to_be(4)
            expect(live.live_base_indices):to_be(6)
            expect(live.live_indexed_batches):to_be(1)
            expect(live.created_indexed_batches):to_be(1)
            expect(live.uploaded_base_vertices):to_be(4)
            expect(live.uploaded_base_indices):to_be(6)

            expect(batch:release()):to_be(true)
            local released = backend:get_stats()
            expect(released.live_base_vertices):to_be(0)
            expect(released.live_base_indices):to_be(0)
            expect(released.live_indexed_batches):to_be(0)
        end)

        t.it("adopts an existing LOVE base mesh for non-Block instance groups", function()
            local backend = Backend.new()
            local raw_draw_mesh = love.graphics.newMesh(
                BASE_FORMAT, BASE_VERTICES, "triangles", "static")
            local batch = backend:create_instanced_batch({
                draw_mesh = raw_draw_mesh,
                owns_draw_mesh = true,
                vertex_count = #BASE_VERTICES,
                instance_format = INSTANCE_FORMAT,
                instance_rows = {
                    row(1, 1, 0, 0, 1),
                    row(2, 0, 1, 0, 1),
                },
                kind = "opaque_mesh_group",
            })

            expect(batch.kind):to_be("opaque_mesh_group")
            expect(batch.base_mesh):to_be_nil()
            expect(batch.raw_draw_mesh):to_be(raw_draw_mesh)
            expect(batch.draw_mesh):to_be(raw_draw_mesh)
            expect(batch.instance_mesh):to_be(batch.instances.instanced_mesh_buffer)
            expect(batch.vertex_count):to_be(#BASE_VERTICES)
            expect(batch.instance_count):to_be(2)

            expect(batch:release()):to_be(true)
            if raw_draw_mesh.isReleased then
                expect(raw_draw_mesh:isReleased()):to_be(true)
            end
            expect(backend:get_stats().live_batches):to_be(0)
        end)

        t.it("releases safely, idempotently, and remains reusable", function()
            local backend = Backend.new()
            local first = backend:create_opaque_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                instance_format = INSTANCE_FORMAT,
                instance_rows = { row(1, 1, 1, 1, 1) },
            })
            local second = backend:create_opaque_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                instance_format = INSTANCE_FORMAT,
                instance_rows = { row(2, 1, 1, 1, 1) },
            })

            expect(first:release()):to_be(true)
            expect(first:release()):to_be(false)
            expect(first.draw_mesh):to_be_nil()
            expect(first.instance_mesh):to_be_nil()
            expect(backend:release()):to_be(1)
            expect(backend:release()):to_be(0)
            expect(second.released):to_be(true)

            local replacement = backend:create_opaque_batch({
                base_vertex_format = BASE_FORMAT,
                base_vertices = BASE_VERTICES,
                instance_format = INSTANCE_FORMAT,
                instance_rows = { row(3, 1, 1, 1, 1) },
            })
            expect(replacement.released):to_be(false)
            expect(replacement.instance_count):to_be(1)

            local stats = backend:get_stats()
            expect(stats.created_batches):to_be(3)
            expect(stats.released_batches):to_be(2)
            expect(stats.live_batches):to_be(1)
            expect(stats.live_instances):to_be(1)
            expect(stats.release_errors):to_be(0)
            backend:reset()
        end)
    end)
end

return suite
