-- Public Atmosphere Instance lifecycle and renderer-state synchronization.

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

local function contains(values, wanted)
    for index = 1, #values do
        if values[index] == wanted then return true end
    end
    return false
end

local function make_fixture(RBX)
    local sky = { source = "facade_sky", SkyboxFt = "rbxassetid://1" }
    local post_effects = {
        bloom = { Enabled = true, Intensity = 0.4, Threshold = 1.2 },
    }
    local state = RBX._build_lighting_state({
        source = "atmosphere_facade_spec",
        ambient = { 0.12, 0.13, 0.14 },
        outdoor_ambient = { 0.42, 0.43, 0.44 },
        brightness = 1.75,
        clock_time = 9.5,
        geographic_latitude = 22,
        global_shadows = true,
        fog_color = { 0.25, 0.35, 0.45 },
        fog_start = 8,
        fog_end = 96,
        shadow_softness = 0.35,
        sky = sky,
        post_effects = post_effects,
    })
    local core = setmetatable({
        parts = {},
        constraints = {},
        lighting_state = state,
        lighting_info = state,
        lighting_loaded = true,
        _lighting_uniform_revision = 7,
        _shadow_casters_built_for_gs = true,
        enable_atmosphere = true,
        atmosphere_distance_scale = 4096,
        sun_direction = { 0, 1, 0 },
        sun_color = { 1, 1, 1 },
        sky_color = { 0, 0, 0 },
        ground_color = { 0, 0, 0 },
        fog_color = { 0, 0, 0 },
        ambient = 1,
        diffuse_strength = 1,
        specular_strength = 1,
        rim_strength = 0,
    }, { __index = RBX })
    core._refresh_sky_environment_average_color = function(self)
        self._test_sky_refresh_count = (self._test_sky_refresh_count or 0) + 1
    end
    core._gui_bridge_link_datamodel = function() end
    core:_rebuild_lighting_uniform_pack()
    local game = core:_create_datamodel_public({})
    return game, core, sky, post_effects
end

local function new_atmosphere(game, properties)
    return game._instance_api.new("Atmosphere", properties)
end

function suite.run(t, harness)
    for index = 1, #RUNTIME_MODULES do
        harness.runtime_require(RUNTIME_MODULES[index])
    end
    local RBX = harness.env.RBX
    local Color3 = harness.env.Color3
    local expect = t.expect

    t.describe("Atmosphere DataModel facade", function()
        t.it("exposes inheritance, support lists, native defaults, and bounded properties", function()
            local game, core = make_fixture(RBX)
            local atmosphere = new_atmosphere(game)
            expect(atmosphere.ClassName):to_be("Atmosphere")
            expect(atmosphere:IsA("Atmosphere")):to_be(true)
            expect(atmosphere:IsA("Instance")):to_be(true)
            expect(atmosphere.Density):to_be(0.395000011)
            expect(atmosphere.Offset):to_be(0)
            expect(atmosphere.Haze):to_be(0)
            expect(atmosphere.Glare):to_be(0)
            expect(atmosphere.Color.R):to_be(0.7843)
            expect(atmosphere.Decay.B):to_be(0.0549)
            expect(contains(game._instance_api.GetSupportedClasses(), "Atmosphere")):to_be(true)
            expect(contains(core:_build_instance_api().GetSupportedClasses(), "Atmosphere")):to_be(true)
            expect(contains(RBX.Instance.GetSupportedClasses(), "Atmosphere")):to_be(true)

            atmosphere.Density = 4
            atmosphere.Offset = -4
            atmosphere.Haze = 20
            atmosphere.Glare = -3
            atmosphere.Color = Color3.new(2, -1, 0.25)
            expect(atmosphere.Density):to_be(1)
            expect(atmosphere.Offset):to_be(-1)
            expect(atmosphere.Haze):to_be(10)
            expect(atmosphere.Glare):to_be(0)
            expect(atmosphere.Color.R):to_be(1)
            expect(atmosphere.Color.G):to_be(0)
            expect(atmosphere.Color.B):to_be(0.25)
            local finite_density = atmosphere.Density
            local numeric_ok = pcall(function()
                atmosphere.Density = 0 / 0
            end)
            expect(numeric_ok):to_be(false)
            expect(atmosphere.Density):to_be(finite_density)
            local color_ok = pcall(function()
                atmosphere.Decay = { math.huge, 0.5, 0.5 }
            end)
            expect(color_ok):to_be(false)
            expect(atmosphere.Decay.R):to_be(0.3608)
        end)

        t.it("promotes a loaded child without a redundant rebuild, then mutates one live pack", function()
            local game, core, sky, post_effects = make_fixture(RBX)
            core:apply_lighting_settings(RBX._build_lighting_state({
                source = "loaded_atmosphere",
                ambient = { 0.12, 0.13, 0.14 },
                outdoor_ambient = { 0.42, 0.43, 0.44 },
                brightness = 1.75,
                clock_time = 9.5,
                geographic_latitude = 22,
                global_shadows = true,
                fog_color = { 0.25, 0.35, 0.45 },
                fog_start = 8,
                fog_end = 96,
                shadow_softness = 0.35,
                sky = sky,
                post_effects = post_effects,
                atmosphere = {
                    Density = 0.21,
                    Offset = 0.12,
                    Color = { 0.7, 0.6, 0.5 },
                    Decay = { 0.2, 0.3, 0.4 },
                    Haze = 1.5,
                    Glare = 0.75,
                },
            }))
            local revision = core._lighting_uniform_revision
            local source_color = { 0.7, 0.6, 0.5 }
            game:_promote_instance_roots({ {
                ClassName = "Lighting",
                Name = "Lighting",
                Children = { {
                    ClassName = "Atmosphere",
                    Name = "LoadedAtmosphere",
                    Density = 0.21,
                    Offset = 0.12,
                    Color = source_color,
                    Decay = { 0.2, 0.3, 0.4 },
                    Haze = 1.5,
                    Glare = 0.75,
                    Children = {},
                } },
            } })
            expect(core._lighting_uniform_revision):to_be(revision)
            local atmosphere = game.Lighting:GetChildren()[1]
            source_color[1] = 0
            expect(atmosphere.Color.R):to_be(0.7)

            local world_shader = {}
            core._common_lighting_uniform_send_state = {
                [world_shader] = revision,
            }
            core._sky_lighting_uniform_revision = revision
            atmosphere.Haze = 3.25
            expect(core._lighting_uniform_revision):to_be(revision + 1)
            expect(core.lighting_state.atmosphere.haze):to_be(3.25)
            expect(core._atmosphere_uniform_pack[3][1]):to_be(3.25)
            expect(core.lighting_state.sky):to_be(sky)
            expect(core.lighting_state.post_effects):to_be(post_effects)
            expect(core.lighting_state.fog_start):to_be(8)
            expect(core.lighting_state.clock_time):to_be(9.5)
            t.assert_that(core._common_lighting_uniform_send_state[world_shader]
                    ~= core._lighting_uniform_revision,
                "world shader cache was not invalidated by revision")
            t.assert_that(core._sky_lighting_uniform_revision
                    ~= core._lighting_uniform_revision,
                "sky shader cache was not invalidated by revision")

            local pack = core._atmosphere_uniform_pack
            atmosphere.Haze = 3.25
            expect(core._lighting_uniform_revision):to_be(revision + 1)
            expect(core._atmosphere_uniform_pack):to_be(pack)
        end)

        t.it("activates only a direct child and restores deterministic authored order", function()
            local game, core = make_fixture(RBX)
            local folder = game._instance_api.new("Folder")
            folder.Parent = game.Lighting
            local first = new_atmosphere(game, { Density = 0.2 })
            local second = new_atmosphere(game, { Density = 0.7 })
            local nested = new_atmosphere(game, {
                Density = 0.95,
                Parent = folder,
            })
            expect(core.lighting_state.atmosphere):to_be_nil()

            first.Parent = game.Lighting
            second.Parent = game.Lighting
            expect(core.lighting_state.atmosphere.density):to_be(0.2)
            expect(rawget(game, "_effective_atmosphere_instance")):to_be(first)
            nested.Density = 0.1
            expect(core.lighting_state.atmosphere.density):to_be(0.2)

            first.Parent = folder
            expect(core.lighting_state.atmosphere.density):to_be(0.7)
            expect(rawget(game, "_effective_atmosphere_instance")):to_be(second)
            second.Parent = nil
            expect(core.lighting_state.atmosphere):to_be_nil()
            expect(core.lighting_state.fog_enabled):to_be(true)

            first.Parent = game.Lighting
            expect(core.lighting_state.atmosphere.density):to_be(0.2)
        end)

        t.it("destroy reveals the next child and finally restores legacy fog", function()
            local game, core = make_fixture(RBX)
            local first = new_atmosphere(game, {
                Density = 0.15,
                Parent = game.Lighting,
            })
            local second = new_atmosphere(game, {
                Density = 0.65,
                Parent = game.Lighting,
            })
            expect(core.lighting_state.atmosphere.density):to_be(0.15)
            expect(core.lighting_state.fog_enabled):to_be(false)
            first:Destroy()
            expect(core.lighting_state.atmosphere.density):to_be(0.65)
            second:Destroy()
            expect(core.lighting_state.atmosphere):to_be_nil()
            expect(core.lighting_state.atmosphere_present):to_be(false)
            expect(core.lighting_state.fog_enabled):to_be(true)
            expect(core._atmosphere_uniform_pack[3][4]):to_be(0)
        end)

        t.it("clones value-owned properties but remains inactive until parented", function()
            local game, core = make_fixture(RBX)
            local source = new_atmosphere(game, {
                Density = 0.42,
                Offset = 0.3,
                Color = Color3.new(0.1, 0.2, 0.3),
                Decay = Color3.new(0.4, 0.5, 0.6),
                Haze = 2,
                Glare = 1,
            })
            local clone = source:Clone()
            expect(clone.Parent):to_be_nil()
            expect(clone.Density):to_be(0.42)
            expect(clone.Color.R):to_be(0.1)
            expect(clone.Decay.B):to_be(0.6)
            expect(clone.Color == source.Color):to_be(true)
            expect(core.lighting_state.atmosphere):to_be_nil()
            source.Density = 0.1
            expect(clone.Density):to_be(0.42)
            clone.Parent = game.Lighting
            expect(core.lighting_state.atmosphere.density):to_be(0.42)
        end)
    end)
end

return suite
