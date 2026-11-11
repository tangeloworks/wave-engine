-- Pure Atmosphere transport/property semantics.  The renderer GPU suite owns
-- final material/sky integration; these tests remain worker/headless safe.

local suite = {}

local function luminance(r, g, b)
    return r * 0.2126 + g * 0.7152 + b * 0.0722
end

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

function suite.run(t, harness)
    local Atmosphere = harness.runtime_require("atmosphere.lua")
    local expect = t.expect

    t.describe("bounded Atmosphere model", function()
        t.it("normalizes hostile values into a value-owned descriptor", function()
            local raw = {
                Density = 4,
                Offset = -5,
                Color = { 2, -1, 0.25 },
                Decay = { 0.1, 0.2, 0 / 0 },
                Haze = math.huge,
                Glare = -3,
                DistanceScale = 1,
            }
            local descriptor = Atmosphere.normalize(raw)
            expect(descriptor.density):to_be(1)
            expect(descriptor.offset):to_be(-1)
            expect(descriptor.color[1]):to_be(1)
            expect(descriptor.color[2]):to_be(0)
            expect(descriptor.color[3]):to_be(0.25)
            expect(descriptor.decay[3]):to_be(Atmosphere.DEFAULTS.Decay[3])
            expect(descriptor.haze):to_be(0)
            expect(descriptor.glare):to_be(0)
            expect(descriptor.distance_scale):to_be(32)
            raw.Color[1] = 0
            expect(descriptor.color[1]):to_be(1)
        end)

        t.it("shares current construction defaults with parser and facade paths", function()
            local descriptor = Atmosphere.normalize({})
            expect(descriptor.density):to_be(0.395000011)
            expect(descriptor.offset):to_be(0)
            expect(descriptor.color[1]):to_be(0.7843)
            expect(descriptor.color[2]):to_be(0.6667)
            expect(descriptor.color[3]):to_be(0.4235)
            expect(descriptor.decay[1]):to_be(0.3608)
            expect(descriptor.decay[2]):to_be(0.2353)
            expect(descriptor.decay[3]):to_be(0.0549)
            expect(descriptor.haze):to_be(0)
            expect(descriptor.glare):to_be(0)
        end)

        t.it("leaves world and sky samples unchanged when absent", function()
            local descriptor = Atmosphere.normalize(nil)
            expect(descriptor.enabled):to_be(false)
            local r, g, b, transmission, depth = Atmosphere.evaluate_world(
                { 2, 0.5, 0.25 }, { 10000, 0, 0 }, { 0, 0, 0 },
                { 0, 1, 0 }, descriptor)
            expect(r):to_be(2)
            expect(g):to_be(0.5)
            expect(b):to_be(0.25)
            expect(transmission):to_be(1)
            expect(depth):to_be(0)
            local sr, sg, sb = Atmosphere.evaluate_sky(
                { 0.2, 0.3, 0.4 }, { 0, 0, 1 }, { 0, 1, 0 }, descriptor)
            expect(sr):to_be(0.2)
            expect(sg):to_be(0.3)
            expect(sb):to_be(0.4)
            local repacked = Atmosphere.pack(descriptor, {
                distance_scale = 2048,
            })
            expect(repacked[3][4]):to_be(0)
        end)

        t.it("uses monotonic Beer-Lambert extinction for distance and density", function()
            local thin = Atmosphere.normalize({ Density = 0.15 })
            local thick = Atmosphere.normalize({ Density = 0.6 })
            local _, _, _, near_transmission = Atmosphere.evaluate_world(
                { 0, 0, 0 }, { 512, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, thin)
            local _, _, _, far_transmission = Atmosphere.evaluate_world(
                { 0, 0, 0 }, { 4096, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, thin)
            local _, _, _, thick_transmission = Atmosphere.evaluate_world(
                { 0, 0, 0 }, { 4096, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, thick)
            t.assert_that(near_transmission > far_transmission,
                "distance did not increase extinction")
            t.assert_that(far_transmission > thick_transmission,
                "density did not increase extinction")
            t.assert_that(thick_transmission >= 0 and near_transmission <= 1,
                "transmission escaped [0,1]")
        end)

        t.it("makes positive Offset retain detail and negative Offset blend sooner", function()
            local positive = Atmosphere.normalize({ Density = 0.35, Offset = 0.5 })
            local negative = Atmosphere.normalize({ Density = 0.35, Offset = -0.5 })
            local _, _, _, positive_transmission = Atmosphere.evaluate_world(
                { 1, 1, 1 }, { 2048, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, positive)
            local _, _, _, negative_transmission = Atmosphere.evaluate_world(
                { 1, 1, 1 }, { 2048, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, negative)
            t.assert_that(positive_transmission > negative_transmission,
                "Offset direction is reversed")
        end)

        t.it("does not let Offset create particles from a zero-load atmosphere", function()
            local descriptor = Atmosphere.normalize({
                Density = 0,
                Haze = 0,
                Offset = -1,
                Color = { 1, 0, 0 },
            })
            local wr, wg, wb, transmission, depth =
                Atmosphere.evaluate_world({ 0.2, 0.3, 0.4 },
                    { 8192, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 },
                    descriptor)
            expect(wr):to_be(0.2)
            expect(wg):to_be(0.3)
            expect(wb):to_be(0.4)
            expect(transmission):to_be(1)
            expect(depth):to_be(0)
            local sr, sg, sb = Atmosphere.evaluate_sky(
                { 0.15, 0.25, 0.35 }, { 1, 0, 0 }, { 0, 1, 0 },
                descriptor)
            expect(sr):to_be(0.15)
            expect(sg):to_be(0.25)
            expect(sb):to_be(0.35)
        end)

        t.it("keeps Density off the skybox while Haze controls sky coverage", function()
            local dense = Atmosphere.normalize({
                Density = 1,
                Haze = 0,
                Color = { 1, 0, 0 },
            })
            local hazy = Atmosphere.normalize({
                Density = 0,
                Haze = 8,
                Color = { 1, 0, 0 },
            })
            local dr, dg, db = Atmosphere.evaluate_sky(
                { 0.1, 0.2, 0.3 }, { 1, 0, 0 }, { 0, 1, 0 }, dense)
            expect(dr):to_be(0.1)
            expect(dg):to_be(0.2)
            expect(db):to_be(0.3)
            local hr, hg, hb = Atmosphere.evaluate_sky(
                { 0.1, 0.2, 0.3 }, { 1, 0, 0 }, { 0, 1, 0 }, hazy)
            t.assert_that(hr > dr and hg < dg and hb < db,
                "Haze did not own sky coverage independently of Density")
        end)

        t.it("concentrates haze at the horizon", function()
            local descriptor = Atmosphere.normalize({
                Density = 0,
                Haze = 6,
                Color = { 0.8, 0.7, 0.6 },
            })
            local hr, hg, hb = Atmosphere.evaluate_sky(
                { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, descriptor)
            local zr, zg, zb = Atmosphere.evaluate_sky(
                { 0, 0, 0 }, { 0, 1, 0 }, { 0, 1, 0 }, descriptor)
            t.assert_that(luminance(hr, hg, hb) > luminance(zr, zg, zb),
                "horizon haze was not stronger than zenith haze")
        end)

        t.it("gates sun glare and Decay behind both Haze and Glare", function()
            local function sky(haze, glare, direction)
                return Atmosphere.evaluate_sky({ 0.1, 0.1, 0.1 }, direction,
                    { 0, 0, 1 }, Atmosphere.normalize({
                        Density = 0,
                        Haze = haze,
                        Glare = glare,
                        Color = { 1, 0.2, 0.1 },
                        Decay = { 0.1, 0.2, 1 },
                    }))
            end
            local gated_r, gated_g, gated_b = sky(8, 0, { 0, 0, 1 })
            local sun_r, sun_g, sun_b = sky(8, 8, { 0, 0, 1 })
            local away_r, away_g, away_b = sky(8, 8, { 0, 0, -1 })
            t.assert_that(luminance(sun_r, sun_g, sun_b)
                    > luminance(gated_r, gated_g, gated_b) + 0.1,
                "Glare appeared without the documented Haze+Glare coupling")
            t.assert_that(away_b > away_r,
                "Decay did not become the away-from-sun hue")
        end)

        t.it("uses the shader-matched fallback threshold for tiny directions", function()
            local descriptor = Atmosphere.normalize({
                Density = 0,
                Haze = 8,
                Glare = 8,
                Color = { 1, 0.2, 0.1 },
                Decay = { 0.1, 0.2, 1 },
            })
            local zero_r, zero_g, zero_b = Atmosphere.evaluate_sky(
                { 0.1, 0.1, 0.1 }, { 0, 0, 0 }, { 0, 0, 1 }, descriptor)
            local tiny_r, tiny_g, tiny_b = Atmosphere.evaluate_sky(
                { 0.1, 0.1, 0.1 }, { 1e-6, 0, 0 }, { 0, 0, 1 }, descriptor)
            expect(tiny_r):to_be_near(zero_r, 1e-12)
            expect(tiny_g):to_be_near(zero_g, 1e-12)
            expect(tiny_b):to_be_near(zero_b, 1e-12)
        end)

        t.it("packs one bounded three-vec4 shader update", function()
            local packed = Atmosphere.pack({
                Density = 0.4,
                Offset = 0.2,
                Color = { 0.1, 0.2, 0.3 },
                Decay = { 0.4, 0.5, 0.6 },
                Haze = 2,
                Glare = 3,
            }, { distance_scale = 8192 })
            expect(#packed):to_be(3)
            expect(packed[1][4]):to_be(0.4)
            expect(packed[2][4]):to_be(0.2)
            expect(packed[3][1]):to_be(2)
            expect(packed[3][2]):to_be(3)
            expect(packed[3][3]):to_be(1 / 8192)
            expect(packed[3][4]):to_be(1)
            t.assert_that(Atmosphere.FRAME_GLSL:find(
                "uniform vec4 uAtmosphere[3]", 1, true) ~= nil,
                "shader contract lost its single array pack")
            t.assert_that(Atmosphere.FRAME_GLSL:find("for (", 1, true) == nil,
                "Atmosphere shader introduced an unbounded loop")
        end)

        t.it("makes authored-to-GPU color conversion explicit and value-owned", function()
            local source = Atmosphere.normalize({
                Density = 0.4,
                Color = { 0.5, 0.25, 0.75 },
                Decay = { 0.2, 0.4, 0.6 },
            })
            local packed = Atmosphere.pack(source, {
                color_transform = function(r, g, b)
                    return r * r, g * g, b * b
                end,
            })
            expect(packed[1][1]):to_be_near(0.25, 1e-12)
            expect(packed[1][2]):to_be_near(0.0625, 1e-12)
            expect(packed[2][3]):to_be_near(0.36, 1e-12)
            expect(source.color[1]):to_be(0.5)
            expect(source.decay[3]):to_be(0.6)
        end)

        t.it("stays finite over adversarial camera and property inputs", function()
            local descriptor = Atmosphere.normalize({
                Density = 1,
                Offset = -1,
                Color = { 1, 1, 1 },
                Decay = { 0, 0, 0 },
                Haze = 10,
                Glare = 10,
            })
            local samples = {
                { 0, 0, 0 },
                { 1e12, -1e12, 1e12 },
                { -1e12, 1e12, -1e12 },
                { 1e308, -1e308, 1e308 },
            }
            for index = 1, #samples do
                local r, g, b, transmission, depth = Atmosphere.evaluate_world(
                    { 1e6, 0, 1 }, samples[index], { 0, 0, 0 },
                    { 0, 0, 0 }, descriptor)
                for _, value in ipairs({ r, g, b, transmission, depth }) do
                    t.assert_that(finite(value),
                        "non-finite atmosphere result at sample %d", index)
                end
            end
        end)
    end)
end

return suite
