-- Direct receiver-pixel equivalence for the optional lazy next-cascade PCF
-- path. This compiles both source forms in one graphics process so it does not
-- depend on an unrelated map or a timed App run.
local suite = { needs_graphics = true }

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
    "geometry.lua",
    "assets.lua",
}

local LEGACY_NEXT_SAMPLE = [[
        float nextVisibility = sampleDirectionalShadowCascade(
            cascade + 1.0, worldPos, receiverNormal, ndotl);
        visibility = mix(visibility, nextVisibility, blend);
]]

local LAZY_NEXT_SAMPLE = [[
        if (blend > 0.0) {
            float nextVisibility = sampleDirectionalShadowCascade(
                cascade + 1.0, worldPos, receiverNormal, ndotl);
            visibility = mix(visibility, nextVisibility, blend);
        }
]]

local function replace_once(source, needle, replacement)
    local first = assert(source:find(needle, 1, true),
        "receiver source did not contain the expected next-cascade block")
    assert(not source:find(needle, first + #needle, true),
        "receiver source contains more than one next-cascade block")
    return source:sub(1, first - 1) .. replacement
        .. source:sub(first + #needle)
end

local function source_variants(source)
    if source:find(LAZY_NEXT_SAMPLE, 1, true) then
        return replace_once(source, LAZY_NEXT_SAMPLE, LEGACY_NEXT_SAMPLE), source
    end
    assert(source:find(LEGACY_NEXT_SAMPLE, 1, true),
        "receiver source is neither the legacy nor lazy cascade form")
    return source, replace_once(source, LEGACY_NEXT_SAMPLE, LAZY_NEXT_SAMPLE)
end

local function receiver_shader(source)
    return love.graphics.newShader([[ 
uniform vec3 uCameraPos;
uniform vec3 uTestWorldPos;
]] .. source .. [[
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen)
{
    float visibility = computeDirectionalShadow(
        uTestWorldPos, vec3(0.0, 1.0, 0.0));
    return vec4(visibility, visibility, visibility, 1.0);
}
]])
end

local function make_atlas()
    local data = love.image.newImageData(12, 4, "rgba8")
    for y = 0, 3 do
        for x = 0, 11 do
            -- Cascade 0 and 2 contain an occluding comparison depth; cascade
            -- 1 contains a fully lit depth. That makes both transition bands
            -- and the far fade observable instead of proving two all-white rows.
            local red = x >= 4 and x < 8 and 1 or 0
            data:setPixel(x, y, red, 0, 0, 1)
        end
    end
    local atlas = love.graphics.newImage(data, { linear = true, mipmaps = false })
    data:release()
    atlas:setFilter("nearest", "nearest")
    return atlas
end

local IDENTITY = {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
}

local function configure(shader, atlas)
    shader:send("uShadowAtlas", atlas)
    shader:send("uShadowMatrix0", IDENTITY)
    shader:send("uShadowMatrix1", IDENTITY)
    shader:send("uShadowMatrix2", IDENTITY)
    shader:send("uShadowCameraForward", { 0, 0, -1 })
    shader:send("uShadowSunDirection", { 0, 1, 0 })
    shader:send("uShadowCascadeBias", { 0, 0, 0 })
    shader:send("uShadowCascadeTexelDepth", { 0, 0, 0 })
    shader:send("uShadowBiasRight", { 1, 0, 0 })
    shader:send("uShadowBiasUp", { 0, 0, 1 })
    shader:send("uShadowCascadeSplits", { 0.2, 0.4, 0.6, 0.6 })
    shader:send("uShadowAtlasInfo", { 1 / 12, 1 / 4, 1 / 3, 1 })
    shader:send("uShadowParams", { 0, 0, 0.12, 0.16 })
    shader:send("uShadowCascadeDebug", 0)
    shader:send("uCameraPos", { 0, 0, 0 })
end

local function render_samples(shader, atlas, depths)
    local graphics = love.graphics
    local canvas = graphics.newCanvas(#depths, 1, {
        format = "rgba8", readable = true, msaa = 0,
    })
    graphics.push("all")
    local ok, bytes_or_error, values = xpcall(function()
        configure(shader, atlas)
        graphics.origin()
        graphics.setCanvas(canvas)
        graphics.clear(0, 0, 0, 0)
        graphics.setShader(shader)
        graphics.setBlendMode("replace", "alphamultiply")
        graphics.setColor(1, 1, 1, 1)
        for index, depth in ipairs(depths) do
            shader:send("uTestWorldPos", { 0, 0, -depth })
            graphics.rectangle("fill", index - 1, 0, 1, 1)
        end
        graphics.setShader()
        graphics.setCanvas()
        local pixels = canvas:newImageData()
        local values = {}
        for index = 1, #depths do
            values[index] = select(1, pixels:getPixel(index - 1, 0))
        end
        local bytes = pixels:getString()
        pixels:release()
        return bytes, values
    end, debug.traceback)
    graphics.pop()
    canvas:release()
    if not ok then error(bytes_or_error, 0) end
    return bytes_or_error, values
end

function suite.run(t, harness)
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local legacy_source, lazy_source = source_variants(assert(
        harness.env.DIRECTIONAL_SHADOW_FRAME_GLSL,
        "assets module did not publish the directional-shadow receiver source"))

    t.describe("lazy directional-shadow cascade receiver", function()
        t.it("keeps exact pixels at zero blend, both transition bands, and the far fade", function()
            local atlas = make_atlas()
            local legacy = receiver_shader(legacy_source)
            local lazy = receiver_shader(lazy_source)
            local depths = { 0.05, 0.17, 0.19, 0.21, 0.34, 0.39, 0.41, 0.55, 0.59 }
            local ok, failure = xpcall(function()
                local legacy_bytes, legacy_values = render_samples(legacy, atlas, depths)
                local lazy_bytes, lazy_values = render_samples(lazy, atlas, depths)
                assert(legacy_bytes == lazy_bytes,
                    "lazy next-cascade receiver output differed from the legacy PCF path")
                for index = 1, #depths do
                    assert(legacy_values[index] == lazy_values[index],
                        "sample value differed at depth " .. tostring(depths[index]))
                end

                -- These literals cover the zero-weight fast path, the two
                -- nonzero cross-cascade blends, and cascade 2's existing far fade.
                assert(legacy_values[1] < 0.3 and legacy_values[2] < 0.3,
                    "cascade-zero zero-blend samples did not receive real shadowing")
                assert(legacy_values[3] > 0.3 and legacy_values[3] < 0.9,
                    "first cascade blend band was not exercised")
                assert(legacy_values[4] > 0.95 and legacy_values[5] > 0.95,
                    "cascade-one zero-blend samples did not remain fully lit")
                assert(legacy_values[6] > 0.3 and legacy_values[6] < 0.9,
                    "second cascade blend band was not exercised")
                assert(legacy_values[7] < 0.3 and legacy_values[8] < 0.3,
                    "cascade-two zero-blend samples did not receive real shadowing")
                assert(legacy_values[9] > 0.3 and legacy_values[9] < 0.9,
                    "last-cascade far fade was not exercised")
            end, debug.traceback)
            lazy:release()
            legacy:release()
            atlas:release()
            if not ok then error(failure, 0) end
        end)
    end)
end

return suite
