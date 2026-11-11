local suite = {}

local SurfaceAppearance = require(
    "engine/graphics/rbx/runtime/surface_appearance")

local function expect_near(t, actual, expected)
    t.expect(actual):to_be_near(expected, 1e-9)
end

local function descriptor(alpha_mode, extra)
    local value = {
        alpha_mode = alpha_mode,
        color_map = "rbxassetid://100",
        color = { 0.5, 0.25, 1 },
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return SurfaceAppearance.normalize_descriptor(value)
end

function suite.run(t, harness)
    t.describe("SurfaceAppearance semantic core", function()
        t.it("normalizes current defaults and value-owns every renderer field", function()
            local source = {
                ColorMapContent = " rbxassetid://10 ",
                ColorMap = "rbxassetid://11",
                NormalMap = "rbxassetid://12",
                EmissiveMaskContent = "rbxassetid://13",
                TexturePackContent = "rbxassetid://14",
                TexturePack = "rbxassetid://15",
                Color = { 0.25, 0.5, 0.75 },
                EmissiveTint = { r = 1, g = 0.5, b = 0.25 },
            }
            local normalized = SurfaceAppearance.normalize_descriptor(source)
            t.expect(normalized.alpha_mode):to_be(SurfaceAppearance.ALPHA_OVERLAY)
            t.expect(normalized.color_map):to_be("rbxassetid://10")
            t.expect(normalized.normal_map):to_be("rbxassetid://12")
            t.expect(normalized.emissive_mask):to_be("rbxassetid://13")
            t.expect(normalized.texture_pack):to_be("rbxassetid://14")
            t.expect(normalized.emissive_strength):to_be(1)
            t.expect(normalized.resample_mode):to_be(0)
            t.expect(normalized.color):to_not_be(source.Color)
            t.expect(normalized.emissive_tint):to_not_be(source.EmissiveTint)
            source.Color[1] = 1
            source.EmissiveTint.g = 1
            expect_near(t, normalized.color[1], 0.25)
            expect_near(t, normalized.emissive_tint[2], 0.5)
        end)

        t.it("handles enum wrappers, cycles, malformed colors, and empty assets safely", function()
            local enum_cycle = {}
            enum_cycle.EnumItem = enum_cycle
            t.expect(SurfaceAppearance.normalize_alpha_mode(enum_cycle))
                :to_be(SurfaceAppearance.ALPHA_OVERLAY)
            t.expect(SurfaceAppearance.normalize_alpha_mode(
                { EnumItem = { Name = "Enum.AlphaMode.TintMask" } }))
                :to_be(SurfaceAppearance.ALPHA_TINT_MASK)
            t.expect(SurfaceAppearance.normalize_alpha_mode("3"))
                :to_be(SurfaceAppearance.ALPHA_OPAQUE)
            t.expect(SurfaceAppearance.normalize_alpha_mode(1.5))
                :to_be(SurfaceAppearance.ALPHA_OVERLAY)

            local content_cycle = {}
            content_cycle.Content = content_cycle
            local normalized = SurfaceAppearance.normalize_descriptor({
                color_map = content_cycle,
                normal_map = "rbxassetid://0",
                color = { 0 / 0, math.huge, -5 },
                emissive_strength = -4,
            })
            t.expect(normalized.color_map):to_be_nil()
            t.expect(normalized.normal_map):to_be_nil()
            t.expect(normalized.color[1]):to_be(1)
            t.expect(normalized.color[2]):to_be(1)
            t.expect(normalized.color[3]):to_be(0)
            t.expect(normalized.emissive_strength):to_be(0)
        end)

        t.it("evaluates Overlay, Transparency, TintMask, and Opaque exactly", function()
            local map = { 0.8, 0.6, 0.4, 0.5 }
            local underlying = { 0.2, 0.4, 0.6, 0.8 }
            local expected = {
                [SurfaceAppearance.ALPHA_OVERLAY] = { 0.3, 0.275, 0.5, 0.8 },
                [SurfaceAppearance.ALPHA_TRANSPARENCY] = { 0.4, 0.15, 0.4, 0.4 },
                [SurfaceAppearance.ALPHA_TINT_MASK] = { 0.6, 0.375, 0.4, 0.8 },
                [SurfaceAppearance.ALPHA_OPAQUE] = { 0.4, 0.15, 0.4, 0.8 },
            }
            for mode = 0, 3 do
                local actual = {
                    SurfaceAppearance.evaluate_base_color(
                        descriptor(mode), map, underlying, true),
                }
                for component = 1, 4 do
                    expect_near(t, actual[component], expected[mode][component])
                end
            end
        end)

        t.it("preserves the legacy value byte-for-value when no color map is active", function()
            local underlying = { -0.25, 1.25, 0.123456789, 0.375 }
            local actual = {
                SurfaceAppearance.evaluate_base_color(
                    descriptor(SurfaceAppearance.ALPHA_TRANSPARENCY),
                    { 1, 0, 0, 0 }, underlying, false),
            }
            for index = 1, 4 do
                t.expect(actual[index]):to_be(underlying[index])
            end
        end)

        t.it("adds emissive contribution before the albedo multiplication", function()
            local normalized = SurfaceAppearance.normalize_descriptor({
                emissive_mask = "rbxassetid://20",
                emissive_strength = 2,
                emissive_tint = { 0.5, 0.25, 1 },
            })
            local r, g, b = SurfaceAppearance.evaluate_emissive_lighting(
                normalized, { 0.1, 0.2, 0.3 }, 0.5)
            expect_near(t, r, 0.6)
            expect_near(t, g, 0.45)
            expect_near(t, b, 1.3)

            local defaults = SurfaceAppearance.normalize_descriptor({
                emissive_mask = "rbxassetid://21",
            })
            r, g, b = SurfaceAppearance.evaluate_emissive_lighting(
                defaults, { 0.1, 0.2, 0.3 }, 0.5)
            expect_near(t, r, 0.6)
            expect_near(t, g, 0.7)
            expect_near(t, b, 0.8)
        end)

        t.it("routes native transparency cutout and blend thresholds explicitly", function()
            local transparency = descriptor(SurfaceAppearance.ALPHA_TRANSPARENCY)
            local cutout = SurfaceAppearance.classify_route(transparency, 0, true)
            t.expect(cutout.route):to_be("opaque_cutout")
            t.expect(cutout.alpha_discard):to_be(true)
            t.expect(cutout.depth_write):to_be(true)
            t.expect(cutout.depth_prepass):to_be(false)
            t.expect(cutout.blend):to_be(false)

            t.expect(SurfaceAppearance.classify_route(
                transparency, 0.01, true).route):to_be("opaque_cutout")
            local blend = SurfaceAppearance.classify_route(
                transparency, 0.02, true)
            t.expect(blend.route):to_be("transparent_blend")
            t.expect(blend.blend):to_be(true)
            t.expect(blend.depth_write):to_be(false)
            t.expect(blend.sorted):to_be(true)
            t.expect(SurfaceAppearance.classify_route(
                transparency, 1, true).route):to_be("invisible")

            local sampled_depth = SurfaceAppearance.classify_route(
                transparency, 0, true, { depth_prepass_samples_alpha = true })
            t.expect(sampled_depth.depth_prepass):to_be(true)
            t.expect(SurfaceAppearance.classify_route(
                descriptor(SurfaceAppearance.ALPHA_OVERLAY), 0, true).route)
                :to_be("opaque")
            t.expect(SurfaceAppearance.classify_route(
                descriptor(SurfaceAppearance.ALPHA_OVERLAY), 0.01, true).route)
                :to_be("transparent_blend")
        end)

        t.it("separates color and data sampling while honoring ResampleMode", function()
            local overlay = descriptor(SurfaceAppearance.ALPHA_OVERLAY)
            local color = SurfaceAppearance.sampler_options("color", overlay)
            t.expect(color.color_space):to_be("srgb_color")
            t.expect(color.alpha_bleed):to_be(true)
            t.expect(color.min_filter):to_be("linear")
            local normal = SurfaceAppearance.sampler_options("normal", overlay, {
                wrap_mode = "repeat",
            })
            t.expect(normal.color_space):to_be("linear_data")
            t.expect(normal.alpha_bleed):to_be(false)
            t.expect(normal.remote_pending_placeholder):to_be("neutral_data")
            t.expect(normal.wrap_mode):to_be("repeat")

            local pixelated = SurfaceAppearance.normalize_descriptor({
                color_map = "rbxassetid://22",
                resample_mode = "Enum.ResamplerMode.Pixelated",
            })
            t.expect(SurfaceAppearance.sampler_options(
                "color", pixelated).mag_filter):to_be("nearest")
            t.expect(SurfaceAppearance.sampler_options(
                "roughness", pixelated).mipmap_filter):to_be("nearest")
            t.expect(SurfaceAppearance.sampler_options(
                "color", descriptor(SurfaceAppearance.ALPHA_TINT_MASK)).alpha_bleed)
                :to_be(false)
            t.expect(SurfaceAppearance.sampler_options(
                "color", descriptor(SurfaceAppearance.ALPHA_OPAQUE)).alpha_bleed)
                :to_be(false)
        end)

        t.it("builds deterministic complete signatures without nil-field truncation", function()
            local base = descriptor(SurfaceAppearance.ALPHA_OVERLAY, {
                normal_map = "rbxassetid://30",
                roughness_map = "rbxassetid://31",
                metalness_map = "rbxassetid://32",
                emissive_mask = "rbxassetid://33",
                emissive_strength = 3,
            })
            local resources = {
                color = { resource_key = "color|ready", revision = 1 },
                normal = { resource_key = "normal|ready", revision = 1 },
                revision = 4,
            }
            local signature = SurfaceAppearance.build_signature(base, resources, {
                wrap_mode = "repeat",
            })
            t.expect(SurfaceAppearance.build_signature(base, resources, {
                wrap_mode = "repeat",
            })):to_be(signature)

            local variants = {
                SurfaceAppearance.build_signature(
                    descriptor(SurfaceAppearance.ALPHA_OPAQUE), resources),
                SurfaceAppearance.build_signature(base, {
                    color = { resource_key = "color|other", revision = 1 },
                    normal = resources.normal,
                    revision = 4,
                }),
                SurfaceAppearance.build_signature(base, {
                    color = resources.color,
                    normal = resources.normal,
                    revision = 5,
                }),
                SurfaceAppearance.build_signature(base, resources, {
                    wrap_mode = "clamp",
                }),
                SurfaceAppearance.build_signature(
                    descriptor(SurfaceAppearance.ALPHA_OVERLAY, {
                        color = { 0.51, 0.25, 1 },
                    }), resources),
            }
            for index = 1, #variants do
                t.expect(variants[index]):to_not_be(signature)
                for other = index + 1, #variants do
                    t.expect(variants[index]):to_not_be(variants[other])
                end
            end
        end)

        t.it("conservatively excludes SurfaceAppearance from legacy mesh instancing", function()
            t.expect(SurfaceAppearance.instancing_eligibility(nil)):to_be(true)
            local eligible, reason = SurfaceAppearance.instancing_eligibility({})
            t.expect(eligible):to_be(false)
            t.expect(reason):to_be("surface_appearance_requires_baked_shader")
        end)
    end)
end

return suite
