-- A per-vertex oracle for the optimized material primitive emitter. Comparing
-- all float32 upload lanes catches UV/normal/AO changes before rasterization.
-- Normals/winding use the corrected inverse transpose; the native plane and
-- independent geometric oracle live in material_primitive_normals_spec.
local suite = { needs_graphics = true }

local function release_batches(batch_map)
    for _, batch in pairs(batch_map) do
        if batch.vertices and batch.vertices.vdata then
            batch.vertices.vdata:release()
        end
    end
end

local function oracle_vertices(env, core, part, descriptor)
    local px, py, pz, rx, ry, rz, ux, uy, uz, bx, by, bz, sx, sy, sz =
        env.get_runtime_part_render_basis(part)
    local nsx = sx >= 0 and math.max(sx, 1e-6) or math.min(sx, -1e-6)
    local nsy = sy >= 0 and math.max(sy, 1e-6) or math.min(sy, -1e-6)
    local nsz = sz >= 0 and math.max(sz, 1e-6) or math.min(sz, -1e-6)
    local reverse = env.RBX._basis_handedness_sign(rx, ry, rz, ux, uy, uz, bx, by, bz)
        * env.RBX._axis_sign(sx) * env.RBX._axis_sign(sy) * env.RBX._axis_sign(sz) < 0
    local source = core._primitive_vertices[
        env.get_runtime_part_render_geometry_key(part)] or core._cube_vertices
    local projection = env.MATERIAL_PROJECTION.build_context(
        nil, sx, sy, sz, part._loaded_map_mirror_x == true, false, false)
    local studs = math.max(0.001,
        descriptor.material_variant_surface_active and descriptor.studs_per_tile
            or core.material_studs_per_tile or env.MATERIAL_STUDS_PER_TILE)
    local tiling = math.max(0.001, descriptor.tiling or 1)
    local r, g, b = env.get_runtime_render_color(part, true)
    local a = env.get_runtime_render_alpha(part)
    if descriptor.material_variant_surface_active then
        local SurfaceAppearance = env.runtime_require("surface_appearance.lua")
        local route = SurfaceAppearance.classify_route(
            descriptor.material_variant_surface, 1 - a,
            descriptor.material_variant_surface.color_map_active,
            { depth_prepass_samples_alpha = false })
        a = route.part_alpha
    end
    local reflectance = env.get_runtime_render_reflectance(part)
    local rows = {}
    for first = 1, #source, 3 do
        local va, vb, vc = source[first], source[first + 1], source[first + 2]
        if va and vb and vc then
            local nx = (va[4] or 0) + (vb[4] or 0) + (vc[4] or 0)
            local ny = (va[5] or 0) + (vb[5] or 0) + (vc[5] or 0)
            local nz = (va[6] or 0) + (vb[6] or 0) + (vc[6] or 0)
            local face = env.MATERIAL_PROJECTION.select_face_name(
                nil, nx, ny, nz, projection)
            for offset = 0, 2 do
                local vertex = source[first + (reverse and offset > 0 and 3 - offset or offset)]
                local lx, ly, lz = (vertex[1] or 0) * sx,
                    (vertex[2] or 0) * sy, (vertex[3] or 0) * sz
                local x, y, z = env.transform_local_point(px, py, pz,
                    rx, ry, rz, ux, uy, uz, bx, by, bz, lx, ly, lz)
                local vx, vy, vz = vertex[4] or nx,
                    vertex[5] or ny, vertex[6] or nz
                local wx, wy, wz = env.transform_local_normal(
                    rx, ry, rz, ux, uy, uz, bx, by, bz, vx / nsx, vy / nsy, vz / nsz)
                local u, v = env.MATERIAL_PROJECTION.project_uv(
                    face, projection, lx, ly, lz, studs, tiling)
                local ao = env.contact_ao_for_normal(part._contact_ao_top,
                    part._contact_ao_bottom, part._contact_ao_side,
                    part._contact_ao_max, vx, vy, vz)
                env.push_textured_vertex(rows, x, y, z, wx, wy, wz, u, v,
                    r, g, b, a, reflectance, nil, nil, nil, nil, nil, nil, ao)
            end
        end
    end
    return rows
end

local function with_renderer(env, callback)
    local RBX = env.RBX
    local original_skybox = RBX._load_skybox
    local original_face_axes = RBX._accurate_face_axes
    RBX._load_skybox = function(self) self.sky_loaded = false end
    local game
    local ok, failure = xpcall(function()
        game = assert(RBX.new({
            render_backend = "menori", enable_skybox = false,
            allow_remote_asset_fetch = false, physics_enabled = false,
            mesh_instancing = false, shader_quality = "fast", msaa = 0,
        }))
        callback(game._core)
    end, debug.traceback)
    RBX._load_skybox = original_skybox
    if game then game:Destroy() end
    RBX._accurate_face_axes = original_face_axes
    if not ok then error(failure, 0) end
end

local function part_for(env, shape, index, mirror)
    local part = {
        ClassName = "Part", Shape = shape, Material = 816,
        Size = { x = 4.75, y = 2.3, z = 6.125 },
        CFrame = env.CFrame.new(1.25, -0.6, 2.4)
            * env.CFrame.Angles(0.23, -0.71, 0.36),
        Color = { r = 0.71, g = 0.23, b = 0.49 },
        Transparency = index % 2 == 0 and 0.35 or 0,
        Reflectance = 0.37,
        _contact_ao_top = 0.17, _contact_ao_bottom = 0.53,
        _contact_ao_side = 0.21, _contact_ao_max = 0.64,
        _loaded_map_mirror_x = mirror,
    }
    if shape == "CylinderY" then
        part.MeshOwner = "CylinderMesh"
    elseif shape == "CornerWedge" then
        part.ClassName = "CornerWedgePart"
    elseif shape == "Truss" then
        part.ClassName = "TrussPart"
    else
        part.MeshOwner = "SpecialMesh"
        part.SpecialMeshType = shape == "Ball" and "Sphere"
            or (shape == "Block" and "Brick" or shape)
    end
    part.SpecialMeshScale = {
        x = index % 2 == 0 and -0.5 or 0.5,
        y = index % 3 == 0 and -1.7 or 1.7,
        z = index % 4 == 0 and -0.8 or 0.8,
    }
    return part
end

local PIXEL_SHADER = [[
varying vec3 parityNormal;
varying float parityAO;
uniform bool parityCutout;
uniform bool parityFlipV;
#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexContactAO;
vec4 position(mat4 ignored, vec4 p) {
    parityNormal = VertexNormal;
    parityAO = VertexContactAO;
    return vec4((p.x - 1.25) / 4.0, (p.y + 0.6) / 4.0, p.z / 10.0, 1.0);
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen) {
    if (parityFlipV) uv.y = 1.0 - uv.y;
    vec4 texel = Texel(texture, uv);
    if (parityCutout && texel.a < 0.5) discard;
    vec3 shade = 0.3 + 0.7 * abs(parityNormal);
    return vec4(texel.rgb * color.rgb * shade * (1.0 - 0.4 * parityAO),
        texel.a * color.a);
}
#endif
]]

local function pixel_bytes(mesh, shader)
    local canvas = love.graphics.newCanvas(64, 64, { format = "rgba8", msaa = 0 })
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.origin()
    love.graphics.clear(0.04, 0.1, 0.08, 0)
    love.graphics.setShader(shader)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setMeshCullMode("none")
    love.graphics.setDepthMode()
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.draw(mesh)
    love.graphics.pop()
    local image_data = canvas:newImageData()
    local bytes = image_data:getString()
    image_data:release()
    canvas:release()
    return bytes
end

local function compare_upload_lanes(t, rounded, values_at, expected, label)
    for row, values in ipairs(expected) do
        for lane = 1, 20 do
            rounded[0] = values[lane]
            t.assert_that(values_at(row, lane) == tonumber(rounded[0]),
                "%s vertex=%d lane=%d", label, row, lane)
        end
    end
end

local function face_statistics(env, core, part)
    local _, _, _, _, _, _, _, _, _, _, _, _, sx, sy, sz =
        env.get_runtime_part_render_basis(part)
    local projection = env.MATERIAL_PROJECTION.build_context(
        nil, sx, sy, sz, part._loaded_map_mirror_x == true, false, false)
    local source = core._primitive_vertices[
        env.get_runtime_part_render_geometry_key(part)] or core._cube_vertices
    local seen, distinct, triangles, nonadjacent, previous = {}, 0, 0, false
    for first = 1, #source, 3 do
        local a, b, c = source[first], source[first + 1], source[first + 2]
        if a and b and c then
            local face = env.MATERIAL_PROJECTION.select_face_name(nil,
                (a[4] or 0) + (b[4] or 0) + (c[4] or 0),
                (a[5] or 0) + (b[5] or 0) + (c[5] or 0),
                (a[6] or 0) + (b[6] or 0) + (c[6] or 0), projection)
            if not seen[face] then seen[face], distinct = true, distinct + 1
            elseif previous ~= face then nonadjacent = true end
            triangles, previous = triangles + 1, face
        end
    end
    return { faces = distinct, triangles = triangles, nonadjacent = nonadjacent }
end

local function checked_projection_emission(t, env, rounded, core, part, label)
    -- The reference builds its own context and evaluates every vertex without
    -- reading the renderer's shared projection scratch or emitted UV values.
    local descriptor = core:_get_material_descriptor(part.Material, part.MaterialVariant)
    local expected = oracle_vertices(env, core, part, descriptor)
    local stats = face_statistics(env, core, part)
    local batches = {}
    local ok, failure = xpcall(function()
        local success, key = core:_append_part_material_batch(batches, part)
        t.expect(success):to_be(true)
        t.assert_that(#expected >= 3 and stats.faces > 0 and stats.triangles > 0,
            "%s is an empty projection oracle", label)
        local batch = assert(batches[key])
        t.expect(batch.vertices.vbuf_n):to_be(#expected * 20)
        compare_upload_lanes(t, rounded, function(row, lane)
            return batch.vertices.vbuf[(row - 1) * 20 + lane - 1]
        end, expected, label)
    end, debug.traceback)
    release_batches(batches)
    if not ok then error(failure, 0) end
    return stats
end

local function with_nonadjacent_block(core, callback)
    local original = core._primitive_vertices
    local replacement = {}
    for key, value in pairs(original) do replacement[key] = value end
    local source, shuffled = assert(original.Block), {}
    -- Emit the odd triangles, then the even triangles: a normal box's two
    -- triangles per face no longer sit next to one another. Face projection
    -- must remain correct independently of adjacency in the source stream.
    for parity = 1, 2 do
        for triangle = parity, #source / 3, 2 do
            for corner = 1, 3 do
                shuffled[#shuffled + 1] = source[(triangle - 1) * 3 + corner]
            end
        end
    end
    replacement.Block = shuffled
    core._primitive_vertices = replacement
    local ok, failure = xpcall(callback, debug.traceback)
    core._primitive_vertices = original
    if not ok then error(failure, 0) end
end

function suite.run(t, harness)
    for _, name in ipairs({ "common.lua", "gui.lua", "parser.lua",
        "scene.lua", "datamodel.lua", "geometry.lua", "assets.lua",
        "render.lua", "lifecycle.lua" }) do
        harness.runtime_require(name)
    end
    local env = harness.env
    local ffi = require("ffi")
    local rounded = ffi.new("float[1]")
    t.describe("material primitive projection", function()
        t.it("preserves every upload lane across shapes, mirrors and nonuniform scales", function()
            with_renderer(env, function(core)
                local shapes = { "Block", "Wedge", "CornerWedge",
                    "Cylinder", "CylinderY", "Ball", "Truss" }
                local descriptor = core:_get_material_descriptor(816)
                local old_studs, old_tiling = core.material_studs_per_tile,
                    descriptor.tiling
                core.material_studs_per_tile, descriptor.tiling = 3.7, 1.375
                local checked = 0
                for _, accurate_axes in ipairs({ true, false }) do
                    env.RBX._accurate_face_axes = accurate_axes
                    for _, shape in ipairs(shapes) do
                        for index = 1, 8 do
                            local part = part_for(env, shape, index, index > 4)
                            t.expect(env.get_runtime_part_render_geometry_key(part))
                                :to_be(shape)
                            local batches = {}
                            local success, key = core:_append_part_material_batch(batches, part)
                            t.expect(success):to_be(true)
                            local batch = assert(batches[key])
                            local expected = oracle_vertices(env, core, part, descriptor)
                            t.expect(batch.vertices.vbuf_n):to_be(#expected * 20)
                            compare_upload_lanes(t, rounded, function(row, lane)
                                return batch.vertices.vbuf[(row - 1) * 20 + lane - 1]
                            end, expected, string.format("%s mirror=%s case=%d accurate_axes=%s",
                                shape, tostring(part._loaded_map_mirror_x), index, tostring(accurate_axes)))
                            checked = checked + #expected
                            release_batches(batches)
                        end
                    end
                end
                core.material_studs_per_tile, descriptor.tiling = old_studs, old_tiling
                print(string.format("        exact float32 parity: %d vertices / %d lanes; accurate_face_axes=true/false",
                    checked, checked * 20))
            end)
        end)

        t.it("preserves MaterialVariant alpha routes, GPU uploads and patterned pixels", function()
            with_renderer(env, function(core)
                local texture_data = love.image.newImageData(8, 8)
                texture_data:mapPixel(function(x, y)
                    return (x + 1) / 8, (y + 1) / 8, (x + y) % 2,
                        (x + y) % 3 == 0 and 0 or 0.85
                end)
                local texture = love.graphics.newImage(texture_data)
                texture_data:release()
                texture:setWrap("repeat", "repeat")
                texture:setFilter("nearest", "nearest")
                local original_texture = core._get_or_load_texture
                core._get_or_load_texture = function(self, reference, options)
                    if reference == "projection-spec-color" then
                        return texture, "projection-spec-color"
                    end
                    return original_texture(self, reference, options)
                end
                local Variants = env.runtime_require("material_variants.lua")
                local variants = {}
                for mode = 0, 3 do
                    variants[#variants + 1] = {
                        ClassName = "MaterialVariant", Name = "Projection" .. mode,
                        BaseMaterial = 816, AlphaMode = mode,
                        ColorMap = "projection-spec-color", StudsPerTile = 2.75,
                    }
                end
                core._material_variant_catalog = assert(Variants.extract_from_roots({
                    { ClassName = "MaterialService", Children = variants },
                }))
                local shader = love.graphics.newShader(PIXEL_SHADER)
                local pixel_cases, uploaded_vertices = 0, 0
                for mode = 0, 3 do
                    for index, shape in ipairs({ "Block", "Wedge", "Cylinder", "Ball" }) do
                        local part = part_for(env, shape, index + 4, true)
                        part.MaterialVariant = "Projection" .. mode
                        local descriptor = core:_get_material_descriptor(816, part.MaterialVariant)
                        t.expect(descriptor.material_variant_surface_active):to_be(true)
                        t.expect(descriptor.studs_per_tile):to_be(2.75)
                        local batches = {}
                        local success, key = core:_append_part_material_batch(batches, part)
                        t.expect(success):to_be(true)
                        local batch = assert(batches[key])
                        local blended = part.Transparency >= 0.02
                        local cutout = mode == 1 and not blended
                        local route = blended and "transparent_blend"
                            or (cutout and "opaque_cutout" or "opaque")
                        t.expect(batch.surface_route):to_be(route)
                        t.expect(batch.surface_depth_write):to_be(not blended)
                        t.expect(batch.surface_depth_prepass):to_be(not blended and not cutout)
                        local expected = oracle_vertices(env, core, part, descriptor)
                        local items = core:_build_textured_batches_from_map(batches)
                        t.expect(#items):to_be(1)
                        local item = items[1]
                        t.expect(item.mesh:getVertexCount()):to_be(#expected)
                        t.expect(item.surface_route):to_be(route)
                        local uploaded = {}
                        for row = 1, #expected do
                            uploaded[row] = { item.mesh:getVertex(row) }
                        end
                        compare_upload_lanes(t, rounded, function(row, lane)
                            return uploaded[row][lane]
                        end, expected, part.MaterialVariant .. "/" .. shape)
                        local reference_mesh = love.graphics.newMesh(
                            core._textured_vertex_format, expected, "triangles", "static")
                        reference_mesh:setTexture(texture)
                        shader:send("parityCutout", cutout)
                        shader:send("parityFlipV", item.flip_v)
                        local actual_pixels = pixel_bytes(item.mesh, shader)
                        local expected_pixels = pixel_bytes(reference_mesh, shader)
                        t.assert_that(actual_pixels == expected_pixels,
                            "%s/%s rendered pixels differ from per-vertex projection oracle",
                            part.MaterialVariant, shape)
                        local coverage = 0
                        for offset = 4, #actual_pixels, 4 do
                            if actual_pixels:byte(offset) > 0 then coverage = coverage + 1 end
                        end
                        t.assert_that(coverage > 30, "%s/%s empty pixel oracle (%d pixels)",
                            part.MaterialVariant, shape, coverage)
                        uploaded_vertices = uploaded_vertices + #expected
                        pixel_cases = pixel_cases + 1
                        item.mesh:release()
                        reference_mesh:release()
                        release_batches(batches)
                    end
                end
                print(string.format("        GPU parity: %d uploaded vertices / %d nonempty pixel cases",
                    uploaded_vertices, pixel_cases))
                shader:release()
                core._get_or_load_texture = original_texture
                texture:release()
            end)
        end)

        t.it("preserves every upload lane when repeated faces are nonadjacent", function()
            with_renderer(env, function(core)
                with_nonadjacent_block(core, function()
                    local part = part_for(env, "Block", 3, false)
                    local stats = checked_projection_emission(
                        t, env, rounded, core, part, "nonadjacent Block")
                    t.expect(stats.nonadjacent):to_be(true)
                    t.assert_that(stats.triangles > stats.faces, "nonadjacent fixture contains no repeated face")
                    print(string.format("        nonadjacent face parity: faces=%d triangles=%d",
                        stats.faces, stats.triangles))
                end)
            end)
        end)

        t.it("preserves projection values across sizes, signs, mirrors and face-axis conventions on shared scratch", function()
            with_renderer(env, function(core)
                with_nonadjacent_block(core, function()
                    local part = part_for(env, "Block", 1, false)
                    local scratch
                    for index, state in ipairs({
                        { { 4.75, 2.3, 6.125 }, { .5, 1.7, .8 }, false, true },
                        { { 9.25, .875, 3.125 }, { .5, 1.7, .8 }, false, true },
                        { { 9.25, .875, 3.125 }, { -.5, -1.7, .8 }, false, true },
                        { { 9.25, .875, 3.125 }, { -.5, -1.7, -.8 }, true, true },
                        { { 2.125, 7.375, .625 }, { .75, -2.3, -.6 }, true, false },
                        { { 4.75, 2.3, 6.125 }, { .5, 1.7, .8 }, false, true },
                    }) do
                        part.Size = { x = state[1][1], y = state[1][2], z = state[1][3] }
                        part.SpecialMeshScale = { x = state[2][1], y = state[2][2], z = state[2][3] }
                        part._loaded_map_mirror_x = state[3]
                        env.RBX._accurate_face_axes = state[4]
                        -- Consecutive emissions must use the current part's
                        -- inputs, with no extra emitter call to refresh state.
                        checked_projection_emission(t, env, rounded, core, part,
                            "shared projection scratch case " .. index)
                        if scratch then t.expect(core._material_projection_scratch):to_be(scratch)
                        else scratch = core._material_projection_scratch end
                    end
                    -- A different geometry visits a different subset/order of
                    -- faces but shares the same renderer-owned scratch.
                    for index, shape in ipairs({ "Wedge", "CornerWedge", "Cylinder", "CylinderY", "Ball", "Truss" }) do
                        checked_projection_emission(t, env, rounded, core,
                            part_for(env, shape, index + 2, index % 2 == 0),
                            "shared projection scratch " .. shape)
                        t.expect(core._material_projection_scratch):to_be(scratch)
                    end
                end)
            end)
        end)

        t.it("keeps projection values and scratch state independent between alternating renderers", function()
            with_renderer(env, function(first)
                with_renderer(env, function(second)
                    local a = part_for(env, "Block", 1, false)
                    local b = part_for(env, "Block", 6, true)
                    b.Size = { x = 17.25, y = .375, z = 11.125 }
                    checked_projection_emission(t, env, rounded, first, a, "first renderer projection")
                    local first_scratch = first._material_projection_scratch
                    local first_bounds = {}
                    for key, value in pairs(first_scratch.bounds) do first_bounds[key] = value end
                    env.RBX._accurate_face_axes = false
                    checked_projection_emission(t, env, rounded, second, b, "second renderer projection")
                    t.assert_that(first_scratch ~= second._material_projection_scratch, "renderers share projection scratch")
                    t.assert_that(first_scratch.bounds ~= second._material_projection_scratch.bounds,
                        "renderers share projection bounds")
                    for key, value in pairs(first_bounds) do t.expect(first_scratch.bounds[key]):to_be(value) end
                    env.RBX._accurate_face_axes = true
                    checked_projection_emission(t, env, rounded, first, a, "first renderer revisited projection")
                    t.expect(first._material_projection_scratch):to_be(first_scratch)
                end)
            end)
        end)

        if os.getenv("RBX_MATERIAL_EMISSION_BENCH") == "1" then
            t.it("reports warmed material emission cost", function()
                with_renderer(env, function(core)
                    local parts = {}
                    for index = 1, 2048 do
                        local shape = index % 16 == 0 and "Wedge" or "Block"
                        parts[index] = part_for(env, shape, index, index % 2 == 0)
                    end
                    local batches = {}
                    for _, part in ipairs(parts) do core:_append_part_material_batch(batches, part) end
                    local timings = {}
                    for repeat_index = 1, 7 do
                        for _, batch in pairs(batches) do batch.vertices.vbuf_n = 0 end
                        local started = love.timer.getTime()
                        for _, part in ipairs(parts) do core:_append_part_material_batch(batches, part) end
                        timings[repeat_index] = (love.timer.getTime() - started) * 1000
                    end
                    table.sort(timings)
                    print(string.format("        2048 material parts: median %.3f ms range %.3f-%.3f ms",
                        timings[4], timings[1], timings[7]))
                    release_batches(batches)
                end)
            end)

        end
    end)
end

return suite
