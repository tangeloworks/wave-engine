-- Renderer integration and real-GPU coverage for SurfaceAppearance.

local suite = {}

suite.needs_graphics = true

local SurfaceAppearance = require(
    "engine/graphics/rbx/runtime/surface_appearance")

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

local IDENTITY_MATRIX = {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
}

local function near(t, actual, expected, epsilon, message)
    t.assert_that(math.abs((actual or 0) - expected) <= (epsilon or 1e-5),
        "%s: got %.9f, expected %.9f",
        message or "value mismatch", tonumber(actual) or 0, expected)
end

local function first_batch(batch_map)
    for _, batch in pairs(batch_map or {}) do return batch end
    return nil
end

local function first_vertex(batch)
    local vertices = batch and batch.vertices
    if type(vertices) ~= "table" then return nil end
    if vertices.vbuf ~= nil then
        local vertex = {}
        for index = 0, 19 do
            vertex[index + 1] = tonumber(vertices.vbuf[index])
        end
        return vertex
    end
    return vertices[1]
end

local function simple_mesh_data()
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
            0.2, 0.3,
            0.8, 0.3,
            0.5, 0.9,
        },
        colors = {
            0.5, 0.5, 0.5, 0.5,
            1.0, 1.0, 1.0, 1.0,
            1.0, 1.0, 1.0, 1.0,
        },
        use_vertex_colors = true,
        tangents = {
            1, 0, 0, 1,
            1, 0, 0, 1,
            1, 0, 0, 1,
        },
        bounds = {
            min_x = -0.5, min_y = -0.5, min_z = 0,
            max_x = 0.5, max_y = 0.5, max_z = 0,
        },
        source_kind = "mesh",
    }
end

local function identity_mesh_transform(mesh_data)
    return {
        px = 0, py = 0, pz = 0,
        rx = 1, ry = 0, rz = 0,
        ux = 0, uy = 1, uz = 0,
        bx = 0, by = 0, bz = 1,
        scale_x = 1, scale_y = 1, scale_z = 1,
        local_scale_x = 1, local_scale_y = 1, local_scale_z = 1,
        normal_sign_x = 1, normal_sign_y = 1, normal_sign_z = 1,
        uv_mirror_u = true,
        uv_mirror_v = true,
        cull_swap = false,
        bounds = mesh_data.bounds,
    }
end

local function new_resolver_core(RBX)
    local captures = {}
    local core = setmetatable({
        _white_texture = "white-fallback",
        _flat_normal_texture = "flat-normal-fallback",
        _roughness_half_texture = "roughness-half-fallback",
        _black_texture = "black-fallback",
        _surface_appearance_stats_build_token = 1,
        _surface_appearance_stats = {},
    }, RBX)
    function core:_get_or_load_texture(reference, options)
        captures[#captures + 1] = {
            reference = reference,
            options = options,
        }
        return "texture:" .. tostring(reference),
            "resource:" .. tostring(reference), nil
    end
    return core, captures
end

local function find_capture(captures, reference)
    for index = 1, #captures do
        if captures[index].reference == reference then
            return captures[index]
        end
    end
    return nil
end

local function fake_mesh()
    local mesh = { set_texture_calls = 0 }
    function mesh:setTexture(texture)
        self.texture = texture
        self.set_texture_calls = self.set_texture_calls + 1
    end
    return mesh
end

local function new_binding_renderer(RBX)
    return setmetatable({
        _remote_texture_binding_generation = 0,
        _instance_generation = 7,
        _parts_dirty = false,
        _parts_dirty_mode = nil,
    }, RBX)
end

local function new_handle(revision)
    return {
        source = { revision = revision },
        revision = revision,
    }
end

local function surface_binding_item(handles)
    return {
        surface_appearance = true,
        surface_signature = "complete-surface-signature",
        surface_uniform_state_key_base = "complete-uniform-base",
        surface_texture_group_key_base = "complete-group-base",
        uniform_state_key = "complete-uniform-base",
        texture_group_key = "complete-group-base",
        surface_color_key = "color-pending",
        normal_key = "normal-pending",
        roughness_key = "roughness-pending",
        metalness_key = "metalness-pending",
        emissive_key = "emissive-pending",
        shader_variant_id = "surface_appearance_full",
        resolved_cull_mode = "back",
        depth_compare = "less",
        surface_remote_handles = handles,
        mesh = fake_mesh(),
    }
end

local function vec4(x, y, z, w)
    return { x or 0, y or 0, z or 0, w or 0 }
end

local function neutral_frame_pack()
    return {
        vec4(0, 0, 1, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 1),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 100, 0),
        vec4(0, 0, 0, 1),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(1, 1, 1, 4),
        vec4(0, 0, 0, 0),
    }
end

local function empty_local_lights()
    local values = {}
    for index = 1, 25 do values[index] = vec4() end
    return values
end

local function point_local_lights(options)
    options = options or {}
    local values = empty_local_lights()
    local ambient = options.ambient or { 0, 0, 0 }
    local count = options.count
    if count == nil then count = 1 end
    values[1] = vec4(ambient[1], ambient[2], ambient[3], count)
    local source = options.source or { 0, 0, 0.5 }
    values[2] = vec4(
        source[1], source[2], source[3], options.light_type or 1)
    local direction = options.direction or { 0, 0, -1 }
    values[3] = vec4(
        direction[1], direction[2], direction[3], options.range or 4)
    local light_color = options.color or { 1, 1, 1 }
    values[4] = vec4(
        light_color[1], light_color[2], light_color[3],
        options.brightness or 0.25)
    local axis_u = options.axis_u or { 1, 0, 0 }
    local axis_v = options.axis_v or { 0, 1, 0 }
    values[5] = vec4(
        axis_u[1], axis_u[2], axis_u[3], options.half_u or 0)
    values[6] = vec4(
        axis_v[1], axis_v[2], axis_v[3], options.half_v or 0)
    values[7] = vec4(
        options.cone_cos or 0.5, options.inv_cone_denominator or 2, 0, 0)
    return values
end

local function new_float_texture(r, g, b, a)
    local pixels = love.image.newImageData(1, 1)
    pixels:setPixel(0, 0, r, g, b, a)
    local texture = love.graphics.newImage(pixels, { linear = true })
    pixels:release()
    texture:setFilter("nearest", "nearest")
    return texture
end

local function surface_vertex(x, y, z, color)
    return {
        x, y, z,
        0, 0, 1,
        0.5, 0.5,
        color[1], color[2], color[3], color[4],
        0,
        1, 0, 0,
        0, 1, 0,
        0,
    }
end

local function surface_quad(z, color)
    return {
        surface_vertex(-0.8, -0.8, z, color),
        surface_vertex( 0.8, -0.8, z, color),
        surface_vertex( 0.8,  0.8, z, color),
        surface_vertex(-0.8, -0.8, z, color),
        surface_vertex( 0.8,  0.8, z, color),
        surface_vertex(-0.8,  0.8, z, color),
    }
end

local pixel_sequence = 0
local pixel_item

local function send_surface_pixel_uniforms(core, shader, item, options)
    options = options or {}
    shader:send("uViewRotationMatrix", IDENTITY_MATRIX)
    shader:send("uProjectionMatrix", IDENTITY_MATRIX)
    shader:send("uCameraPos", options.camera or { 0, 0, 0 })
    shader:send("uLightingDebugView", 0)
    shader:send("uLightingDebugLightType", options.debug_light_type or 0)
    local pack = options.frame_pack or neutral_frame_pack()
    for index = 1, #pack do
        shader:send("uLighting" .. tostring(index - 1), pack[index])
    end
    shader:send("uLocalLights", unpack(
        options.local_lights or empty_local_lights()))
    pixel_sequence = pixel_sequence + 1
    item.uniform_state_key = "surface-pixel-" .. tostring(pixel_sequence)
    core:_send_textured_draw_uniforms(item, shader)
end

local function draw_material_light_pixel(core, options)
    options = options or {}
    local base = options.base or { 0.25, 0.5, 0.8 }
    local color_texture = new_float_texture(1, 1, 1, 1)
    local roughness_texture = new_float_texture(
        options.roughness or 0.5, 0, 0, 1)
    local metalness_texture = new_float_texture(
        options.metalness or 0, 0, 0, 1)
    local mesh = love.graphics.newMesh(
        core._textured_vertex_format,
        surface_quad(-0.5, { base[1], base[2], base[3], 1 }),
        "triangles", "static")
    mesh:setTexture(color_texture)
    -- An odd-sized target puts pixel (4, 4) exactly on NDC (0, 0).  That
    -- keeps the point source, geometric normal, view vector, and half-vector
    -- truly collinear for the narrow-roughness GGX assertion below.
    local output = love.graphics.newCanvas(9, 9, {
        format = "rgba16f", readable = true, msaa = 0,
    })
    local item = pixel_item(
        core, SurfaceAppearance.ALPHA_OPAQUE, "opaque", -1)
    item.surface_appearance = options.surface_appearance ~= false
    item.surface_color_map_active = false
    item.light_influence = 1
    item.use_normal_map = false
    item.roughness_texture = roughness_texture
    item.metalness_texture = metalness_texture

    local frame_pack = neutral_frame_pack()
    -- uLighting7.w is the shared specular-strength ABI component.
    frame_pack[8][4] = options.specular_strength or 0
    love.graphics.push("all")
    local ok, draw_error = xpcall(function()
        love.graphics.setCanvas(output)
        love.graphics.origin()
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setDepthMode()
        love.graphics.setMeshCullMode("none")
        love.graphics.setBlendMode("replace", "premultiplied")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setShader(core._textured_shader)
        send_surface_pixel_uniforms(core, core._textured_shader, item, {
            frame_pack = frame_pack,
            local_lights = options.local_lights or empty_local_lights(),
            debug_light_type = options.debug_light_type,
        })
        love.graphics.draw(mesh)
    end, debug.traceback)
    love.graphics.pop()
    if not ok then
        mesh:release(); color_texture:release()
        roughness_texture:release(); metalness_texture:release()
        output:release()
        error(draw_error, 0)
    end
    local pixels = output:newImageData()
    local result = { pixels:getPixel(4, 4) }
    pixels:release(); mesh:release(); color_texture:release()
    roughness_texture:release(); metalness_texture:release()
    output:release()
    return result
end

pixel_item = function(core, alpha_mode, route, cutout_threshold)
    return {
        surface_appearance = true,
        surface_alpha_mode = alpha_mode,
        surface_route = route,
        surface_cutout_threshold = cutout_threshold,
        surface_color_map_active = true,
        surface_color = { 0.5, 0.25, 1 },
        surface_emissive_strength = 0,
        surface_emissive_tint = { 1, 1, 1 },
        use_material_maps = true,
        use_normal_map = true,
        use_textured_lighting = true,
        light_influence = 0,
        brightness = 1,
        normal_texture = core._flat_normal_texture,
        roughness_texture = core._roughness_half_texture,
        metalness_texture = core._black_texture,
        emissive_texture = core._black_texture,
        detail_normal_texture = core._flat_normal_texture,
        detail_normal_mix = 0,
        detail_contrast = 1,
        texture_color_mix = 1,
    }
end

local function with_renderer(RBX, callback)
    local game
    local ok, result = xpcall(function()
        local create_error
        game, create_error = RBX.new({
            render_backend = "love",
            enable_skybox = false,
            allow_remote_asset_fetch = false,
            physics_enabled = false,
            shader_quality = "full",
            msaa = 0,
        })
        assert(game, "RBX.new failed: " .. tostring(create_error))
        return callback(game._core)
    end, debug.traceback)
    if game then pcall(game.Destroy, game) end
    if not ok then error(result, 0) end
    return result
end

local function draw_surface_pixel(core, alpha_mode, route, part_alpha,
                                  map_rgba, cutout_threshold)
    local texture = new_float_texture(
        map_rgba[1], map_rgba[2], map_rgba[3], map_rgba[4])
    local mesh = love.graphics.newMesh(
        core._textured_vertex_format,
        surface_quad(0, { 0.2, 0.4, 0.6, part_alpha }),
        "triangles", "static")
    mesh:setTexture(texture)
    local output = love.graphics.newCanvas(8, 8, {
        format = "rgba16f", readable = true, msaa = 0,
    })
    love.graphics.push("all")
    local ok, draw_error = xpcall(function()
        love.graphics.setCanvas(output)
        love.graphics.origin()
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setDepthMode()
        love.graphics.setMeshCullMode("none")
        love.graphics.setBlendMode("replace", "premultiplied")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setShader(core._textured_shader)
        send_surface_pixel_uniforms(core, core._textured_shader,
            pixel_item(core, alpha_mode, route, cutout_threshold))
        love.graphics.draw(mesh)
    end, debug.traceback)
    love.graphics.pop()
    if not ok then
        mesh:release(); texture:release(); output:release()
        error(draw_error, 0)
    end
    local pixels = output:newImageData()
    local result = { pixels:getPixel(4, 4) }
    pixels:release(); mesh:release(); texture:release(); output:release()
    return result
end

local function draw_depth_transition(core, transparency)
    local is_cutout = transparency < 0.02
    local route = is_cutout and "opaque_cutout" or "transparent_blend"
    local red = new_float_texture(1, 0, 0, 0.8)
    local blue = new_float_texture(0, 0, 1, 1)
    local front = love.graphics.newMesh(
        core._textured_vertex_format,
        surface_quad(0, { 1, 1, 1, 1 - transparency }),
        "triangles", "static")
    local back = love.graphics.newMesh(
        core._textured_vertex_format,
        surface_quad(0.5, { 1, 1, 1, 1 }),
        "triangles", "static")
    front:setTexture(red)
    back:setTexture(blue)
    local output = love.graphics.newCanvas(8, 8, {
        format = "rgba8", readable = true, msaa = 0,
    })
    love.graphics.push("all")
    local ok, draw_error = xpcall(function()
        love.graphics.setCanvas({ output, depth = true })
        love.graphics.origin()
        love.graphics.clear(0, 0, 0, 0, true, true)
        love.graphics.setMeshCullMode("none")
        love.graphics.setBlendMode("replace", "premultiplied")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setShader(core._textured_shader)

        love.graphics.setDepthMode("less", is_cutout)
        send_surface_pixel_uniforms(core, core._textured_shader,
            pixel_item(core, SurfaceAppearance.ALPHA_TRANSPARENCY,
                route, 0.5))
        love.graphics.draw(front)

        love.graphics.setDepthMode("less", false)
        send_surface_pixel_uniforms(core, core._textured_shader,
            pixel_item(core, SurfaceAppearance.ALPHA_OPAQUE,
                "opaque", -1))
        love.graphics.draw(back)
    end, debug.traceback)
    love.graphics.pop()
    if not ok then
        front:release(); back:release(); red:release(); blue:release()
        output:release()
        error(draw_error, 0)
    end
    local pixels = output:newImageData()
    local result = { pixels:getPixel(4, 4) }
    pixels:release(); front:release(); back:release()
    red:release(); blue:release(); output:release()
    return result
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local RBX = harness.env.RBX
    local coords = harness.runtime_require("coords.lua")
    local expect = t.expect

    t.describe("SurfaceAppearance renderer integration", function()
        t.it("accepts only native MeshParts with successfully parsed mesh data", function()
            local raw = {
                ColorMap = "rbxassetid://10",
                AlphaMode = SurfaceAppearance.ALPHA_TRANSPARENCY,
            }
            local mesh_part = {
                ClassName = "MeshPart",
                MeshId = "rbxassetid://1",
                SurfaceAppearance = raw,
                Transparency = 0.01,
            }
            expect(RBX._get_native_mesh_surface_appearance(mesh_part))
                :to_not_be(nil)
            local union = {
                ClassName = "UnionOperation",
                MeshId = "rbxassetid://1",
                SurfaceAppearance = raw,
            }
            expect(RBX._get_native_mesh_surface_appearance(union)):to_be_nil()

            local failed = setmetatable({
                _get_or_parse_part_mesh = function() return nil end,
            }, RBX)
            expect(select(1, RBX._classify_part_surface_appearance_route(
                mesh_part, failed))):to_be_nil()
            local parsed = setmetatable({
                _get_or_parse_part_mesh = function() return simple_mesh_data() end,
            }, RBX)
            local route = RBX._classify_part_surface_appearance_route(
                mesh_part, parsed)
            expect(route.route):to_be("opaque_cutout")
        end)

        t.it("resolves individual maps with semantic samplers and never loads TexturePack", function()
            local core, captures = new_resolver_core(RBX)
            local descriptor = SurfaceAppearance.normalize_descriptor({
                ColorMap = "color-map",
                NormalMap = "normal-map",
                RoughnessMap = "rough-map",
                MetalnessMap = "metal-map",
                EmissiveMaskContent = "emissive-map",
                TexturePack = "ignored-pack",
                ResampleMode = "Enum.ResamplerMode.Pixelated",
            })
            local part = { _id = 1, Name = "Mapped", Transparency = 0 }
            local info = core:_resolve_mesh_part_surface_appearance_info(
                part, simple_mesh_data(), descriptor)
            expect(#captures):to_be(5)
            expect(find_capture(captures, "ignored-pack")):to_be_nil()
            local color = find_capture(captures, "color-map")
            expect(color.options.color_space):to_be("srgb_color")
            expect(color.options.min_filter):to_be("nearest")
            for _, reference in ipairs({
                "normal-map", "rough-map", "metal-map", "emissive-map",
            }) do
                local captured = find_capture(captures, reference)
                expect(captured.options.color_space):to_be("linear_data")
                expect(captured.options.mag_filter):to_be("nearest")
            end
            expect(info.texture):to_be("texture:color-map")
            expect(info.roughness_texture):to_be("texture:rough-map")
            t.assert_that(info.batch_key:find("ignored%-pack") ~= nil,
                "complete Surface batch identity dropped TexturePack diagnostics")
        end)

        t.it("uses all semantic fallbacks and diagnoses none/partial/full pack coverage", function()
            local core, captures = new_resolver_core(RBX)
            local mesh_data = simple_mesh_data()
            local pack_only = SurfaceAppearance.normalize_descriptor({
                TexturePack = "pack-none",
            })
            local first = core:_resolve_mesh_part_surface_appearance_info(
                { _id = 1, Name = "None", Transparency = 0 },
                mesh_data, pack_only)
            expect(first.texture):to_be("white-fallback")
            expect(first.normal_texture):to_be("flat-normal-fallback")
            expect(first.roughness_texture):to_be("roughness-half-fallback")
            expect(first.metalness_texture):to_be("black-fallback")
            expect(first.emissive_texture):to_be("black-fallback")
            expect(#captures):to_be(0)

            core:_resolve_mesh_part_surface_appearance_info(
                { _id = 2, Name = "NormalOnly", Transparency = 0 },
                mesh_data, SurfaceAppearance.normalize_descriptor({
                    TexturePack = "pack-partial",
                    NormalMap = "normal-only",
                }))
            core:_resolve_mesh_part_surface_appearance_info(
                { _id = 3, Name = "Full", Transparency = 0 },
                mesh_data, SurfaceAppearance.normalize_descriptor({
                    TexturePack = "pack-full",
                    ColorMap = "full-color",
                    NormalMap = "full-normal",
                    RoughnessMap = "full-roughness",
                    MetalnessMap = "full-metalness",
                    EmissiveMaskContent = "full-emissive",
                }))
            local diagnostics = core:get_surface_appearance_diagnostics()
            expect(diagnostics.texture_pack_unsupported_count):to_be(3)
            expect(diagnostics.unsupported_texture_pack_only_count):to_be(1)
            expect(diagnostics.texture_pack_unsupported_examples[1]
                .individual_coverage):to_be("none")
            expect(diagnostics.texture_pack_unsupported_examples[2]
                .individual_coverage):to_be("partial")
            expect(diagnostics.texture_pack_unsupported_examples[2]
                .individual_map_count):to_be(1)
            expect(diagnostics.texture_pack_unsupported_examples[3]
                .individual_coverage):to_be("full")
            diagnostics.texture_pack_unsupported_examples[1].name = "mutated"
            expect(core._surface_appearance_stats
                .texture_pack_unsupported_examples[1].name):to_be("None")
        end)

        t.it("bakes Surface precedence, raw Glass values, vertex color, and mirrored TBN", function()
            local mesh_data = simple_mesh_data()
            local core, captures = new_resolver_core(RBX)
            core.disable_material_maps = true
            core.disable_normal_maps = true
            core.mesh_texture_atlas = true
            core.material_studs_per_tile = 4
            core.mesh_depth_bias = 0
            core.mesh_diagnostics_enabled = false
            core._mesh_atlas_built = false
            core._get_or_parse_part_mesh = function() return mesh_data end
            core._get_mesh_render_transform = function()
                return identity_mesh_transform(mesh_data)
            end
            core._add_load_stage_time = function() end
            core._register_mesh_atlas_candidate = function(self)
                self.atlas_registration_count =
                    (self.atlas_registration_count or 0) + 1
            end

            local part = {
                _id = 42,
                Name = "SurfaceGlass",
                ClassName = "MeshPart",
                MeshId = "rbxassetid://1",
                TextureID = "rbxassetid://999",
                Material = 1536,
                Reflectance = 1,
                Transparency = 0.3,
                Color = { r = 0.25, g = 0.5, b = 0.75 },
                SurfaceAppearance = {
                    AlphaMode = SurfaceAppearance.ALPHA_TRANSPARENCY,
                    ColorMap = "surface-color",
                    NormalMap = "surface-normal",
                    RoughnessMap = "surface-roughness",
                    MetalnessMap = "surface-metalness",
                    EmissiveMaskContent = "surface-emissive",
                    TexturePack = "ignored-pack",
                },
            }
            local batch_map = {}
            expect(core:_append_mesh_part_batch(batch_map, part)):to_be(true)
            local batch = first_batch(batch_map)
            expect(batch):to_not_be(nil)
            expect(batch.surface_appearance):to_be(true)
            expect(batch.source_kind):to_be("SurfaceAppearance")
            expect(batch.legacy_textured):to_be(false)
            expect(batch.use_material_maps):to_be(true)
            expect(batch.use_normal_map):to_be(true)
            expect(batch.skip_depth_prepass):to_be(true)
            expect(batch.surface_route):to_be("transparent_blend")
            expect(batch.surface_texture_pack_unsupported):to_be(true)
            expect(batch.is_glass_part):to_not_be(true)
            expect(core.atlas_registration_count):to_be_nil()
            expect(find_capture(captures, "rbxassetid://999")):to_be_nil()
            expect(find_capture(captures, "ignored-pack")):to_be_nil()

            local vertex = first_vertex(batch)
            expect(vertex):to_not_be(nil)
            local pr, pg, pb = coords.color3_to_gpu(0.25, 0.5, 0.75)
            local vr, vg, vb = coords.color3_to_gpu(0.5, 0.5, 0.5)
            near(t, vertex[7], 0.8, 1e-6, "mirrored U")
            near(t, vertex[8], 0.7, 1e-6, "mirrored V")
            near(t, vertex[9], pr * vr, 1e-5, "part/vertex red")
            near(t, vertex[10], pg * vg, 1e-5, "part/vertex green")
            near(t, vertex[11], pb * vb, 1e-5, "part/vertex blue")
            near(t, vertex[12], 0.35, 1e-6, "raw part/vertex alpha")
            near(t, vertex[13], 0, 1e-6, "Surface reflectance bypass")
            near(t, vertex[14], -1, 1e-6, "mirrored tangent")
            near(t, vertex[18], -1, 1e-6, "mirrored bitangent")
        end)

        t.it("forces the full shader in every performance/debug quality mode", function()
            local shaders = {
                full = {}, fast = {}, alpha = {}, overlay = {}, constant = {},
            }
            local core = setmetatable({
                textured_shader_quality = "fast",
                high_fps_shaders = true,
                target_fps_mode = true,
                constant_fragment_shader = true,
                disable_material_maps = true,
                disable_normal_maps = true,
                _textured_shader = shaders.full,
                _fast_textured_shader = shaders.fast,
                _opaque_fast_textured_shader = shaders.fast,
                _alpha_fast_textured_shader = shaders.alpha,
                _surface_overlay_fast_textured_shader = shaders.fast,
                _overlay_textured_shader = shaders.overlay,
                _constant_textured_shader = shaders.constant,
            }, RBX)
            local item = {
                surface_appearance = true,
                surface_route = "opaque_cutout",
            }
            expect(core:_select_textured_shader_for_batch(item, true))
                :to_be(shaders.full)
            expect(item.shader_variant_id):to_be("surface_appearance_full")
            expect(item.uniform_layout_id):to_be("full")
            expect(item.uses_shader_discard):to_be(true)
        end)

        t.it("promotes all five live roles deterministically without dirtying the scene", function()
            local function promote(order)
                local renderer = new_binding_renderer(RBX)
                local handles = {
                    color = new_handle(11),
                    normal = new_handle(12),
                    roughness = new_handle(13),
                    metalness = new_handle(14),
                    emissive = new_handle(15),
                }
                local item = surface_binding_item(handles)
                expect(renderer:_bind_surface_appearance_item_consumers(item))
                    :to_be(5)
                local replacement_mesh = fake_mesh()
                item.mesh = replacement_mesh
                for index = 1, #order do
                    local role = order[index]
                    renderer:_publish_remote_texture_handle(
                        handles[role], "texture:" .. role, "ready:" .. role)
                end
                expect(item.texture):to_be("texture:color")
                expect(item.normal_texture):to_be("texture:normal")
                expect(item.roughness_texture):to_be("texture:roughness")
                expect(item.metalness_texture):to_be("texture:metalness")
                expect(item.emissive_texture):to_be("texture:emissive")
                expect(item.texture_group_key):to_be("complete-group-base")
                expect(renderer._parts_dirty):to_be(false)
                expect(renderer._parts_dirty_mode):to_be_nil()
                expect(replacement_mesh.texture):to_be("texture:color")
                expect(replacement_mesh.set_texture_calls):to_be(1)
                return item.uniform_state_key
            end
            local forward = promote({
                "color", "normal", "roughness", "metalness", "emissive",
            })
            local reverse = promote({
                "emissive", "metalness", "roughness", "normal", "color",
            })
            expect(reverse):to_be(forward)
        end)

        t.it("unlinks a superseded live handle before an old republish", function()
            local renderer = new_binding_renderer(RBX)
            local old = new_handle(1)
            local replacement = new_handle(2)
            local target = { texture = "placeholder" }
            expect(renderer:_bind_remote_texture_consumer(old, target, {
                role = "surface-test-slot",
                texture_field = "texture",
            })):to_be(true)
            renderer:_publish_remote_texture_handle(old, "old-v1", "old-key-1")
            expect(target.texture):to_be("old-v1")
            expect(renderer:_bind_remote_texture_consumer(replacement, target, {
                role = "surface-test-slot",
                texture_field = "texture",
            })):to_be(true)
            expect(old.live_bindings[target]):to_be_nil()
            renderer:_publish_remote_texture_handle(old, "old-v2", "old-key-2")
            expect(target.texture):to_be("old-v1")
            renderer:_publish_remote_texture_handle(
                replacement, "replacement", "replacement-key")
            expect(target.texture):to_be("replacement")
        end)

        t.it("renders all four alpha modes and cutout survivors on the real shader", function()
            with_renderer(RBX, function(core)
                local map = { 0.8, 0.6, 0.4, 0.5 }
                local expected_alpha = {
                    [SurfaceAppearance.ALPHA_OVERLAY] = 0.8,
                    [SurfaceAppearance.ALPHA_TRANSPARENCY] = 0.4,
                    [SurfaceAppearance.ALPHA_TINT_MASK] = 0.8,
                    [SurfaceAppearance.ALPHA_OPAQUE] = 0.8,
                }
                for mode = 0, 3 do
                    local pixel = draw_surface_pixel(
                        core, mode, "transparent_blend", 0.8, map, -1)
                    near(t, pixel[4], expected_alpha[mode], 0.003,
                        "GPU alpha mode " .. tostring(mode))
                end
                local hole = draw_surface_pixel(
                    core, SurfaceAppearance.ALPHA_TRANSPARENCY,
                    "opaque_cutout", 0.981, { 1, 0, 0, 0.49 }, 0.5)
                near(t, hole[4], 0, 5e-4, "cutout hole")
                local survivor = draw_surface_pixel(
                    core, SurfaceAppearance.ALPHA_TRANSPARENCY,
                    "opaque_cutout", 0.981, { 1, 0, 0, 0.51 }, 0.5)
                near(t, survivor[4], 1, 5e-4,
                    "cutout survivor must be opaque")
            end)
        end)

        t.it("switches from cutout depth-write at .019 to sorted blend at .02", function()
            local cutout = SurfaceAppearance.classify_route(
                SurfaceAppearance.normalize_descriptor({
                    AlphaMode = SurfaceAppearance.ALPHA_TRANSPARENCY,
                    ColorMap = "map",
                }), 0.019, true)
            local blend = SurfaceAppearance.classify_route(
                SurfaceAppearance.normalize_descriptor({
                    AlphaMode = SurfaceAppearance.ALPHA_TRANSPARENCY,
                    ColorMap = "map",
                }), 0.02, true)
            expect(cutout.route):to_be("opaque_cutout")
            expect(cutout.depth_write):to_be(true)
            expect(cutout.depth_prepass):to_be(false)
            expect(blend.route):to_be("transparent_blend")
            expect(blend.depth_write):to_be(false)
            expect(blend.sorted):to_be(true)

            with_renderer(RBX, function(core)
                local cutout_pixel = draw_depth_transition(core, 0.019)
                local blend_pixel = draw_depth_transition(core, 0.02)
                t.assert_that(cutout_pixel[1] > 0.4
                        and cutout_pixel[3] < 0.25,
                    ".019 cutout survivor did not preserve front red coverage "
                        .. string.format("(rgb=%.3f,%.3f,%.3f)",
                            cutout_pixel[1], cutout_pixel[2], cutout_pixel[3]))
                t.assert_that(blend_pixel[3] > 0.75
                        and blend_pixel[1] < 0.25,
                    ".02 blend unexpectedly wrote depth before the blue plane")
            end)
        end)

        t.it("renders roughness and metalness against the actual packed local-light direction", function()
            with_renderer(RBX, function(core)
                local local_lights = point_local_lights()
                local smooth = draw_material_light_pixel(core, {
                    local_lights = local_lights,
                    roughness = 0.22,
                    metalness = 0,
                    specular_strength = 1,
                })
                local rough = draw_material_light_pixel(core, {
                    local_lights = local_lights,
                    roughness = 1,
                    metalness = 0,
                    specular_strength = 1,
                })
                local smooth_luma = smooth[1] + smooth[2] + smooth[3]
                local rough_luma = rough[1] + rough[2] + rough[3]
                t.assert_that(smooth_luma > rough_luma + 0.12,
                    "local GGX roughness did not broaden/reduce the aligned "
                        .. "highlight (smooth=%.5f rough=%.5f)",
                    smooth_luma, rough_luma)

                local dielectric = draw_material_light_pixel(core, {
                    local_lights = local_lights,
                    roughness = 0.5,
                    metalness = 0,
                    specular_strength = 1,
                })
                local metal = draw_material_light_pixel(core, {
                    local_lights = local_lights,
                    roughness = 0.5,
                    metalness = 1,
                    specular_strength = 1,
                })
                t.assert_that(metal[3] > dielectric[3] + 0.12
                        and metal[3] > metal[1] * 2.4,
                    "local Schlick F0 did not acquire the colored metal albedo "
                        .. "(dielectric=%.5f metal=%.5f/%.5f)",
                    dielectric[3], metal[1], metal[3])

                local darkness = draw_material_light_pixel(core, {
                    local_lights = empty_local_lights(),
                    roughness = 0.22,
                    metalness = 0,
                    specular_strength = 1,
                })
                t.assert_that(darkness[1] < 0.0005
                        and darkness[2] < 0.0005
                        and darkness[3] < 0.0005,
                    "zero local/global lights produced Surface energy: %.6f %.6f %.6f",
                    darkness[1], darkness[2], darkness[3])

                local overflow_lights = point_local_lights({
                    count = 0,
                    ambient = { 0.2, 0.1, 0.05 },
                })
                local overflow_dielectric = draw_material_light_pixel(core, {
                    local_lights = overflow_lights,
                    roughness = 0.5,
                    metalness = 0,
                })
                local overflow_metal = draw_material_light_pixel(core, {
                    local_lights = overflow_lights,
                    roughness = 0.5,
                    metalness = 1,
                })
                t.assert_that(overflow_dielectric[1] > 0.04
                        and overflow_metal[1] < 0.0005,
                    "overflow ambient is not directionless energy-aware diffuse "
                        .. "(dielectric=%.6f metal=%.6f)",
                    overflow_dielectric[1], overflow_metal[1])

                -- With the legacy directional specular strength disabled,
                -- roughness maps must not alter a point light. This pins the
                -- pre-Surface diffuse-only local-light result numerically and
                -- proves the new BRDF call cannot leak out of the Surface branch.
                local legacy_smooth = draw_material_light_pixel(core, {
                    surface_appearance = false,
                    local_lights = local_lights,
                    roughness = 0.22,
                    metalness = 0,
                    specular_strength = 0,
                })
                local legacy_rough = draw_material_light_pixel(core, {
                    surface_appearance = false,
                    local_lights = local_lights,
                    roughness = 1,
                    metalness = 0,
                    specular_strength = 0,
                })
                local expected_legacy = {
                    0.25 * 0.25 * 0.9375,
                    0.50 * 0.25 * 0.9375,
                    0.80 * 0.25 * 0.9375,
                }
                for component = 1, 3 do
                    near(t, legacy_smooth[component],
                        expected_legacy[component], 0.003,
                        "legacy local-light oracle")
                    near(t, legacy_rough[component],
                        legacy_smooth[component], 0.001,
                        "legacy local-light roughness isolation")
                end
            end)
        end)

        t.it("preserves packed range, cone, face rectangle, and debug filtering in Surface PBR", function()
            with_renderer(RBX, function(core)
                local function draw(local_lights, debug_light_type)
                    return draw_material_light_pixel(core, {
                        local_lights = local_lights,
                        roughness = 0.5,
                        metalness = 0,
                        specular_strength = 1,
                        debug_light_type = debug_light_type,
                    })
                end
                local function luma(pixel)
                    return pixel[1] + pixel[2] + pixel[3]
                end

                local point = draw(point_local_lights({ brightness = 0.5 }))
                local out_of_range = draw(point_local_lights({
                    brightness = 0.5,
                    range = 0.5,
                }))
                t.assert_that(luma(point) > 0.2 and luma(out_of_range) < 0.001,
                    "Surface point-light range response changed "
                        .. "(inside=%.6f outside=%.6f)",
                    luma(point), luma(out_of_range))

                local spot_facing = draw(point_local_lights({
                    light_type = 2,
                    brightness = 0.5,
                    direction = { 0, 0, -1 },
                }))
                local spot_away = draw(point_local_lights({
                    light_type = 2,
                    brightness = 0.5,
                    direction = { 0, 0, 1 },
                }))
                t.assert_that(luma(spot_facing) > 0.2 and luma(spot_away) < 0.001,
                    "Surface spot-light cone response changed "
                        .. "(facing=%.6f away=%.6f)",
                    luma(spot_facing), luma(spot_away))

                local surface_face = draw(point_local_lights({
                    light_type = 3,
                    brightness = 0.5,
                    source = { 0.6, 0, 0.5 },
                    range = 1.05,
                    half_u = 0.6,
                    half_v = 0.6,
                }))
                local surface_point = draw(point_local_lights({
                    light_type = 3,
                    brightness = 0.5,
                    source = { 0.6, 0, 0.5 },
                    range = 1.05,
                }))
                t.assert_that(luma(surface_face) > 0.015
                        and luma(surface_point) < 0.001,
                    "SurfaceLight no longer uses the closest emitting-face point "
                        .. "(face=%.6f point=%.6f)",
                    luma(surface_face), luma(surface_point))

                local filtered = draw(point_local_lights({ brightness = 0.5 }), 2)
                t.assert_that(luma(filtered) < 0.001,
                    "Surface PBR ignored the local-light debug type filter: %.6f",
                    luma(filtered))
            end)
        end)

        t.it("keeps shader PBR/data-map and legacy sampling contracts together", function()
            local source = harness.env.TEXTURED_SHADER
            t.assert_that(source:find(
                "vec3 normal = sampleColor.rgb * 2.0 - 1.0", 1, true),
                "normal map is no longer decoded in OpenGL convention")
            t.assert_that(source:find(
                "roughness = clamp(rough_sample.r", 1, true),
                "Surface roughness is no longer sourced from red")
            t.assert_that(source:find(
                "metalness = clamp(metal_sample.r", 1, true),
                "Surface metalness is no longer sourced from red")
            t.assert_that(source:find("surfaceDistributionGGX", 1, true),
                "GGX distribution missing")
            t.assert_that(source:find("surfaceGeometrySmith", 1, true),
                "Smith geometry term missing")
            t.assert_that(source:find("surfaceFresnelSchlick", 1, true),
                "Schlick Fresnel missing")
            local pbr_start = assert(source:find(
                "vec3 surfaceEvaluatePackedLocalLightPbr", 1, true))
            local pbr_stop = assert(source:find(
                "vec3 surfaceComputeLocalLightPbr", pbr_start, true))
            local packed_pbr = source:sub(pbr_start, pbr_stop - 1)
            for _, contract in ipairs({
                "abs(lightType - uLightingDebugLightType)",
                "if (lightType > 2.5)",
                "source += axisU * clamp(dot(rel, axisU)",
                "dot(worldPos - source, axisV)",
                "if (dist >= range || dist <= 0.000001)",
                "clamp(1.0 - t * t, 0.0, 1.0)",
                "if (lightType > 1.5)",
                "clamp((coneDot - f.x) * f.y, 0.0, 1.0)",
                "c.w * uLocalLightResponseScale",
                "surfaceDistributionGGX",
                "surfaceGeometrySmith",
                "surfaceFresnelSchlick",
            }) do
                t.assert_that(packed_pbr:find(contract, 1, true),
                    "Surface packed-light PBR lost ABI/BRDF contract: %s",
                    contract)
            end
            local dispatch_start = assert(source:find(
                "vec3 surfaceComputeLocalLightPbr", 1, true))
            local dispatch_stop = assert(source:find(
                "vec4 effect", dispatch_start, true))
            local dispatch = source:sub(dispatch_start, dispatch_stop - 1)
            for index = 1, 24 do
                t.assert_that(dispatch:find(
                    "uLocalLights[" .. tostring(index) .. "]", 1, true),
                    "Surface local-light slot %d is not constant-indexed", index)
            end
            t.assert_that(dispatch:find(
                "base * overflowDiffuseEnergy", 1, true),
                "overflow ambient lost energy-aware diffuse handling")
            local surface_branch = assert(source:find(
                "if (uUseSurfaceAppearance > 0.5) {", pbr_stop, true))
            local local_pbr_call = assert(source:find(
                "vec3 localPbr = surfaceComputeLocalLightPbr", 1, true))
            t.assert_that(local_pbr_call > surface_branch,
                "local-light GGX work escaped the SurfaceAppearance branch")
            t.assert_that(source:find(
                "max(max(rough_sample.r, rough_sample.g), rough_sample.b)",
                1, true), "legacy roughness max-RGB path changed")
            t.assert_that(source:find(
                "max(max(metal_sample.r, metal_sample.g), metal_sample.b)",
                1, true), "legacy metalness max-RGB path changed")
        end)
    end)
end

return suite
