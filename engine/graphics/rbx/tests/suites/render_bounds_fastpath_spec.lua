-- The render-bounds fast path must skip mesh resolution only for parts whose
-- exact bounds are already described by the primitive render basis.

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

local BOUND_FIELDS = {
    "min_x", "min_y", "min_z", "max_x", "max_y", "max_z",
}

local function make_rng(seed)
    return function()
        seed = (seed * 48271) % 2147483647
        return seed / 2147483647
    end
end

local function part(CFrame, fields)
    local result = {
        ClassName = "Part",
        Shape = "Block",
        CFrame = CFrame.new(13, -7, 29),
        Size = { x = 6, y = 4, z = 10 },
    }
    for key, value in pairs(fields or {}) do
        result[key] = value
    end
    return result
end

function suite.run(t, harness)
    local expect = t.expect
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local runtime = harness.env.RBX
    local CFrame = harness.env.CFrame

    t.describe("render-bounds exact transform", function()
        t.it("matches generic arbitrary mesh bounds bit-for-bit", function()
            local random = make_rng(982451653)
            for sample = 1, 750 do
                local values = {}
                for index = 1, 15 do
                    values[index] = (random() * 2 - 1) * 75
                end
                for index = 13, 15 do
                    if math.abs(values[index]) < 0.01 then
                        values[index] = index % 2 == 0 and -0.01 or 0.01
                    end
                end

                local bounds = {}
                for _, axis in ipairs({ "x", "y", "z" }) do
                    local first = (random() * 2 - 1) * 20
                    local second = (random() * 2 - 1) * 20
                    bounds["min_" .. axis] = math.min(first, second)
                    bounds["max_" .. axis] = math.max(first, second)
                end

                local generic = harness.env.transform_local_bounds(
                    values[1], values[2], values[3],
                    values[4], values[5], values[6],
                    values[7], values[8], values[9],
                    values[10], values[11], values[12],
                    bounds,
                    values[13], values[14], values[15])
                local exact = runtime._transform_bounds_exact(
                    values[1], values[2], values[3],
                    values[4], values[5], values[6],
                    values[7], values[8], values[9],
                    values[10], values[11], values[12],
                    bounds,
                    values[13], values[14], values[15])

                for field_index = 1, #BOUND_FIELDS do
                    local field = BOUND_FIELDS[field_index]
                    t.assert_that(exact[field] == generic[field],
                        string.format("mesh bound mismatch sample=%d field=%s",
                            sample, field))
                end
            end
        end)
    end)

    t.describe("render-bounds mesh-source gate", function()
        t.it("matches the legacy basis bounds for every primitive owner", function()
            local game, create_error = runtime.new({
                render_backend = "menori",
                enable_skybox = false,
                allow_remote_asset_fetch = false,
                physics_enabled = false,
                shader_quality = "fast",
                msaa = 0,
            })
            assert(game, create_error)
            local core = game._core
            local original_has_source = runtime._part_has_renderable_mesh_source
            local parse_calls = 0
            core._get_or_parse_part_mesh = function()
                parse_calls = parse_calls + 1
                return nil
            end

            local primitive_parts = {
                part(CFrame, { Shape = "Block" }),
                part(CFrame, { Shape = "Ball" }),
                part(CFrame, { Shape = "Cylinder" }),
                part(CFrame, { ClassName = "WedgePart" }),
                part(CFrame, { ClassName = "CornerWedgePart" }),
                part(CFrame, { ClassName = "TrussPart" }),
                part(CFrame, {
                    MeshOwner = "CylinderMesh",
                    SpecialMeshScale = { x = 1.25, y = 0.75, z = 1.5 },
                    SpecialMeshOffset = { x = 2, y = -1, z = 3 },
                }),
                part(CFrame, {
                    MeshOwner = "SpecialMesh",
                    SpecialMeshType = "Sphere",
                    SpecialMeshScale = { x = 1.25, y = 0.75, z = 1.5 },
                    SpecialMeshOffset = { x = 2, y = -1, z = 3 },
                }),
                part(CFrame, {
                    MeshOwner = "SpecialMesh",
                    SpecialMeshType = "Brick",
                    SpecialMeshScale = { x = 1.25, y = 0.75, z = 1.5 },
                    SpecialMeshOffset = { x = 2, y = -1, z = 3 },
                }),
                part(CFrame, {
                    MeshOwner = "SpecialMesh",
                    SpecialMeshType = "Wedge",
                    SpecialMeshScale = { x = 1.25, y = 0.75, z = 1.5 },
                    SpecialMeshOffset = { x = 2, y = -1, z = 3 },
                }),
                part(CFrame, {
                    MeshOwner = "SpecialMesh",
                    SpecialMeshType = "Cylinder",
                    SpecialMeshScale = { x = 1.25, y = 0.75, z = 1.5 },
                    SpecialMeshOffset = { x = 2, y = -1, z = 3 },
                }),
            }

            local ok, failure = xpcall(function()
                for index = 1, #primitive_parts do
                    local primitive = primitive_parts[index]
                    expect(original_has_source(primitive)):to_be(false)

                    runtime._part_has_renderable_mesh_source = function(candidate)
                        if candidate == primitive then return true end
                        return original_has_source(candidate)
                    end
                    primitive._rb_cache = nil
                    local legacy = core:_get_part_render_bounds(primitive)

                    runtime._part_has_renderable_mesh_source = original_has_source
                    primitive._rb_cache = nil
                    local optimized = core:_get_part_render_bounds(primitive)
                    local cached = core:_get_part_render_bounds(primitive)
                    expect(cached == optimized):to_be(true)
                    expect(primitive._rb_cache == optimized):to_be(true)
                    for field_index = 1, #BOUND_FIELDS do
                        local field = BOUND_FIELDS[field_index]
                        expect(optimized[field]):to_be_near(legacy[field], 1e-9)
                    end
                end

                expect(parse_calls):to_be(#primitive_parts)
                local mesh_sources = {
                    part(CFrame, {
                        ClassName = "MeshPart",
                        MeshId = "rbxassetid://123",
                    }),
                    part(CFrame, {
                        MeshOwner = "SpecialMesh",
                        SpecialMeshType = "FileMesh",
                        MeshId = "rbxassetid://456",
                    }),
                    part(CFrame, {
                        EmbeddedMeshData = "version 1.00\n",
                    }),
                    part(CFrame, {
                        MeshOwner = "SpecialMesh",
                        SpecialMeshType = "Head",
                    }),
                }
                local before_sources = parse_calls
                for index = 1, #mesh_sources do
                    local mesh_source = mesh_sources[index]
                    expect(original_has_source(mesh_source)):to_be(true)
                    mesh_source._rb_cache = nil
                    core:_get_part_render_bounds(mesh_source)
                end
                expect(parse_calls - before_sources):to_be(#mesh_sources)
            end, debug.traceback)

            runtime._part_has_renderable_mesh_source = original_has_source
            game:Destroy()
            if not ok then error(failure, 0) end
        end)
    end)
end

return suite
