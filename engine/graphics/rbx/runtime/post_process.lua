-- Frame-level HDR post processing for the RBX renderer
--
-- Material shaders leave their lit result linear while this object is active
-- the world and sky render into one floating-point scene target, then this
-- module performs the spatial BloomEffect and the one-and-only exposure,
-- tone-map, and ColorCorrectionEffect pass. ScreenGui/debug overlays are drawn
-- by render.lua after resolve(), so authored UI colours are never double graded

local coords = runtime_require("coords.lua")

local PostProcess = {}
PostProcess.__index = PostProcess

local FLOAT_SCENE_FORMATS = {
    rgba16f = true,
    rgba32f = true,
}

local BRIGHT_PASS_SHADER = [[
uniform float uExposure;
uniform float uThreshold;
uniform vec2 uSourceTexel;

vec4 extractBloom(vec4 sampleColor)
{
    float alpha = clamp(sampleColor.a, 0.0, 1.0);
    if (alpha <= 0.00001) {
        return vec4(0.0);
    }
    vec3 straightColor = max(sampleColor.rgb / alpha, vec3(0.0));
    vec3 exposed = straightColor * uExposure;
    float brightness = max(max(exposed.r, exposed.g), exposed.b);
    float contribution = max(brightness - uThreshold, 0.0)
        / max(brightness, 0.00001);
    return vec4(exposed * contribution * alpha,
        contribution * alpha);
}

vec4 effect(vec4 color, Image texture, vec2 textureCoords, vec2 screenCoords)
{
    // Four source taps make the half-resolution bright pass a real bounded
    // downsample and keep a one-pixel highlight from falling between samples.
    vec2 offset = uSourceTexel * 0.5;
    vec4 bloom = extractBloom(Texel(texture,
        textureCoords + vec2(-offset.x, -offset.y)));
    bloom += extractBloom(Texel(texture,
        textureCoords + vec2( offset.x, -offset.y)));
    bloom += extractBloom(Texel(texture,
        textureCoords + vec2(-offset.x,  offset.y)));
    bloom += extractBloom(Texel(texture,
        textureCoords + vec2( offset.x,  offset.y)));
    return bloom * 0.25 * color;
}
]]

local BLUR_SHADER = [[
uniform vec2 uDirection;

vec4 effect(vec4 color, Image texture, vec2 textureCoords, vec2 screenCoords)
{
    // Fixed nine-tap Gaussian. Bloom.Size only changes tap spacing, keeping
    // shader work constant and bounded even for the Roblox maximum radius.
    vec4 result = Texel(texture, textureCoords) * 0.2270270270;
    result += Texel(texture, textureCoords + uDirection * 1.0) * 0.1945945946;
    result += Texel(texture, textureCoords - uDirection * 1.0) * 0.1945945946;
    result += Texel(texture, textureCoords + uDirection * 2.0) * 0.1216216216;
    result += Texel(texture, textureCoords - uDirection * 2.0) * 0.1216216216;
    result += Texel(texture, textureCoords + uDirection * 3.0) * 0.0540540541;
    result += Texel(texture, textureCoords - uDirection * 3.0) * 0.0540540541;
    result += Texel(texture, textureCoords + uDirection * 4.0) * 0.0162162162;
    result += Texel(texture, textureCoords - uDirection * 4.0) * 0.0162162162;
    return result * color;
}
]]

local FINAL_SHADER = [[
uniform Image uBloomTexture;
uniform float uBloomEnabled;
uniform float uBloomIntensity;
uniform float uExposure;
uniform float uBrightness;
uniform float uContrast;
uniform float uSaturation;
uniform vec3 uTintColor;

vec3 toneAndGrade(vec3 hdr)
{
    vec3 outColor = max(hdr, vec3(0.0));
    // Neutral exponential shoulder: continuous and strictly increasing for
    // finite values, with no above-white hard clip. Mid-gray 0.2 maps to
    // 0.181269 (-9.37% linear drift), leaving deliberate highlight headroom;
    // 2 and 20 remain ordered at 0.864665 and ~1 respectively.
    outColor = vec3(1.0) - exp(-outColor);
    float luma = dot(outColor, vec3(0.2126, 0.7152, 0.0722));
    outColor = mix(vec3(luma), outColor,
        1.0 + clamp(uSaturation, -1.0, 4.0));
    outColor = (outColor - vec3(0.5))
        * (1.0 + clamp(uContrast, -1.0, 4.0)) + vec3(0.5);
    outColor += vec3(clamp(uBrightness, -1.0, 1.0));
    outColor *= clamp(uTintColor, vec3(0.0), vec3(4.0));
    return clamp(outColor, 0.0, 1.0);
}

vec4 effect(vec4 color, Image texture, vec2 textureCoords, vec2 screenCoords)
{
    vec4 scene = Texel(texture, textureCoords);
    float sceneAlpha = clamp(scene.a, 0.0, 1.0);
    vec4 bloomSample = vec4(0.0);
    float bloomScale = 0.0;
    if (uBloomEnabled > 0.5) {
        bloomSample = Texel(uBloomTexture, textureCoords);
        bloomScale = max(uBloomIntensity, 0.0);
    }
    // Bloom is emissive coverage. Use its blurred alpha outside transparent
    // source geometry rather than clipping the halo to the local scene alpha;
    // never divide bloom energy by a tiny unrelated destination alpha.
    float bloomAlpha = clamp(bloomSample.a * bloomScale, 0.0, 1.0);
    float outputAlpha = max(sceneAlpha, bloomAlpha);
    if (outputAlpha <= 0.00001) {
        return vec4(0.0);
    }
    // Both inputs are premultiplied energy. Combine first, convert to straight
    // colour using the combined coverage, grade once, then premultiply once.
    vec3 premultipliedHdr = max(scene.rgb, vec3(0.0)) * uExposure
        + max(bloomSample.rgb, vec3(0.0)) * bloomScale;
    vec3 hdr = premultipliedHdr / outputAlpha;
    vec3 graded = toneAndGrade(hdr);
    return vec4(graded * outputAlpha, outputAlpha) * color;
}
]]

local function clamp_number(value, minimum, maximum, fallback)
    value = tonumber(value)
    if value == nil or value ~= value
        or value == math.huge or value == -math.huge then
        value = fallback
    end
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function round_dimension(value)
    value = tonumber(value)
    if value == nil or value ~= value then return nil end
    return math.max(1, math.floor(value + 0.5))
end

local function release_resource(resource)
    if not resource then return false end
    -- a released LÃ–VE userdata can throw while merely looking up a method, so
    -- keep both lookup and invocation inside protected calls
    local method_ok, release = pcall(function()
        return resource.release
    end)
    if not method_ok or type(release) ~= "function" then return false end
    return pcall(release, resource)
end

local function resource_is_released_method(resource)
    return resource.isReleased
end

local function resource_is_released(resource)
    if not resource then return false end
    local method_ok, is_released = pcall(resource_is_released_method, resource)
    -- LÃ–VE 11.5 release() may make any subsequent method lookup throw. That
    -- state is just as definitively released as isReleased() returning true
    if not method_ok then return true end
    if type(is_released) ~= "function" then return false end
    local call_ok, released = pcall(is_released, resource)
    return not call_ok or released == true
end

local function safe_canvas_formats(graphics)
    if type(graphics) ~= "table"
        or type(graphics.getCanvasFormats) ~= "function" then
        return {}
    end
    local ok, formats = pcall(graphics.getCanvasFormats)
    return ok and type(formats) == "table" and formats or {}
end

local function append_unique(array, seen, value)
    if value ~= nil and not seen[value] then
        seen[value] = true
        array[#array + 1] = value
    end
end

local function color_component(value, index, lower, upper, fallback)
    if type(value) ~= "table" then return fallback end
    return clamp_number(
        value[index] or value[lower] or value[upper], 0, 1, fallback)
end

local function effect_enabled(effect)
    return type(effect) == "table" and effect.Enabled ~= false
end

function PostProcess.new(options)
    options = options or {}
    local self = setmetatable({}, PostProcess)
    self.enabled = options.enabled ~= false
    self.graphics = options.graphics or love.graphics
    self.formats = safe_canvas_formats(self.graphics)
    self._force_scene_format = options._force_scene_format
    self._required_scene_format = options._required_scene_format
    self._required_samples = options._required_samples
    self.available = false
    self.failure_reason = self.enabled and nil or "disabled_by_option"
    self.output_premultiplied = true
    self.frame_count = 0
    self.resolve_failure_count = 0
    self.target_allocation_count = 0
    self.target_release_count = 0
    self.hdr_fallback_count = 0
    self.bloom_target_failure_count = 0
    self.last_resolve_ms = 0
    self.last_pass_count = 0
    self.last_bloom_active = false
    self._source_texel = { 0, 0 }
    self._blur_direction = { 0, 0 }
    self._tint_uniform = { 1, 1, 1 }

    if not self.enabled then
        return self
    end
    if type(self.graphics) ~= "table"
        or type(self.graphics.newShader) ~= "function"
        or type(self.graphics.newCanvas) ~= "function" then
        self.failure_reason = "graphics_post_capability_unavailable"
        return self
    end

    local shaders = {}
    local sources = {
        BRIGHT_PASS_SHADER,
        BLUR_SHADER,
        FINAL_SHADER,
    }
    for index = 1, #sources do
        local ok, shader = pcall(self.graphics.newShader, sources[index])
        if not ok or not shader then
            for release_index = 1, #shaders do
                release_resource(shaders[release_index])
            end
            self.failure_reason = "post_shader_compile_failed:"
                .. tostring(shader)
            return self
        end
        shaders[index] = shader
    end
    self.bright_shader = shaders[1]
    self.blur_shader = shaders[2]
    self.final_shader = shaders[3]
    self.available = true
    return self
end

function PostProcess:is_available()
    return self.enabled == true and self.available == true
        and self.released ~= true
end

function PostProcess:can_attempt_hdr()
    if not self:is_available() then return false end
    if self._force_scene_format then
        return FLOAT_SCENE_FORMATS[self._force_scene_format] == true
    end
    return self.formats.rgba16f == true
        or self.formats.rgba32f == true
end

function PostProcess:_new_canvas(width, height, options)
    local ok, canvas = pcall(
        self.graphics.newCanvas, width, height, options)
    if not ok or not canvas then
        return nil, tostring(canvas)
    end
    return canvas
end

function PostProcess:_release_bloom_targets()
    local released = 0
    for _, field in ipairs({ "bloom_a", "bloom_b" }) do
        local resource = self[field]
        if resource and not resource_is_released(resource) then
            release_resource(resource)
            self._released_resources = self._released_resources or {}
            self._released_resources[resource] = true
            released = released + 1
        end
        self[field] = nil
    end
    self.bloom_width = nil
    self.bloom_height = nil
    self.bloom_format = nil
    self.target_release_count = self.target_release_count + released
    return released
end

function PostProcess:_release_targets()
    local released = 0
    self:_release_bloom_targets()
    if self.sun_rays then self.sun_rays:retire() end
    for _, field in ipairs({ "scene_canvas", "scene_depth" }) do
        local resource = self[field]
        if resource and not resource_is_released(resource) then
            release_resource(resource)
            self._released_resources = self._released_resources or {}
            self._released_resources[resource] = true
            released = released + 1
        end
        self[field] = nil
    end
    self.scene_width = nil
    self.scene_height = nil
    self.scene_samples = nil
    self.scene_format = nil
    self.scene_is_hdr = nil
    self.depth_format = nil
    self.target_release_count = self.target_release_count + released
    return released
end

function PostProcess:_scene_format_candidates(require_hdr)
    local candidates, seen = {}, {}
    if self._force_scene_format then
        if not require_hdr
            or FLOAT_SCENE_FORMATS[self._force_scene_format] then
            append_unique(candidates, seen, self._force_scene_format)
        end
    else
        if self.formats.rgba16f == true then
            append_unique(candidates, seen, "rgba16f")
        end
        if self.formats.rgba32f == true then
            append_unique(candidates, seen, "rgba32f")
        end
        if not require_hdr then
            -- rgba8 is a module-level capture fallback only. render.lua never
            -- activates unclamped material output against it: values above 1
            -- would be clipped before exposure and Bloom thresholding
            append_unique(candidates, seen, "rgba8")
        end
    end
    return candidates
end

function PostProcess:_sample_candidates(samples)
    if self._required_scene_format then return { self._required_samples } end
    local candidates, seen = {}, {}
    samples = math.max(0, math.min(8,
        math.floor(tonumber(samples) or 0)))
    append_unique(candidates, seen, samples)
    append_unique(candidates, seen, 0)
    return candidates
end

function PostProcess:_create_depth(width, height, samples)
    local depth_formats = {}
    if self.formats.depth24stencil8 == true then
        depth_formats[#depth_formats + 1] = "depth24stencil8"
    end
    if self.formats.depth24 == true then
        depth_formats[#depth_formats + 1] = "depth24"
    end
    if self.formats.depth16 == true then
        depth_formats[#depth_formats + 1] = "depth16"
    end
    for index = 1, #depth_formats do
        local options = {
            format = depth_formats[index],
            readable = false,
            msaa = samples,
        }
        local depth = self:_new_canvas(width, height, options)
        if depth then
            return depth, depth_formats[index]
        end
    end
    return nil, nil
end

function PostProcess:ensure(width, height, samples, require_hdr)
    if not self:is_available() then
        return false, self.failure_reason or "post_process_unavailable"
    end
    width = round_dimension(width)
    height = round_dimension(height)
    if not width or not height then
        return false, "invalid_post_target_dimensions"
    end
    samples = math.max(0, math.min(8,
        math.floor(tonumber(samples) or 0)))
    if self.scene_canvas
        and not resource_is_released(self.scene_canvas)
        and self.scene_width == width
        and self.scene_height == height
        and self.requested_samples == samples
        and (not require_hdr
            or FLOAT_SCENE_FORMATS[self.scene_format] == true) then
        return true, self.scene_canvas, self.scene_depth
    end

    local formats = self:_scene_format_candidates(require_hdr == true)
    local sample_candidates = self:_sample_candidates(samples)
    local selected_canvas, selected_depth
    local selected_format, selected_samples, selected_depth_format
    local last_error
    for format_index = 1, #formats do
        local format = formats[format_index]
        for sample_index = 1, #sample_candidates do
            local candidate_samples = sample_candidates[sample_index]
            local canvas, canvas_error = self:_new_canvas(width, height, {
                format = format,
                readable = true,
                msaa = candidate_samples,
            })
            if canvas then
                selected_canvas = canvas
                selected_format = format
                selected_samples = candidate_samples
                selected_depth, selected_depth_format =
                    self:_create_depth(width, height, candidate_samples)
                break
            end
            last_error = canvas_error
        end
        if selected_canvas then break end
    end

    if self._required_scene_format then
        local valid = samples == self._required_samples
            and selected_canvas and selected_depth
            and selected_canvas:getFormat() == self._required_scene_format
            and selected_canvas:getMSAA() == self._required_samples
            and selected_depth:getFormat() == "depth24stencil8"
            and selected_depth:getMSAA() == self._required_samples
        if not valid then
            release_resource(selected_canvas)
            release_resource(selected_depth)
            -- publish nothing, retain the complete generation and allow retry
            return false, "experimental_rgba32f_msaa2_target_unsupported: " .. tostring(last_error)
        end
    end
    if not selected_canvas then
        self.available = false
        self.failure_reason = (require_hdr
            and "hdr_scene_canvas_allocation_failed:"
            or "scene_canvas_allocation_failed:")
            .. tostring(last_error)
        return false, self.failure_reason
    end
    if selected_canvas.setFilter then
        selected_canvas:setFilter("linear", "linear")
    end
    if selected_canvas.setWrap then
        selected_canvas:setWrap("clamp", "clamp")
    end

    local old_scene, old_depth = self.scene_canvas, self.scene_depth
    self:_release_bloom_targets()
    if self.sun_rays then self.sun_rays:retire() end
    self.scene_canvas = selected_canvas
    self.scene_depth = selected_depth
    self.scene_width = width
    self.scene_height = height
    self.requested_samples = samples
    self.scene_samples = selected_samples
    self.scene_format = selected_format
    self.scene_is_hdr = FLOAT_SCENE_FORMATS[selected_format] == true
    self.depth_format = selected_depth_format
    self.target_allocation_count = self.target_allocation_count
        + 1 + (selected_depth and 1 or 0)
    if selected_format ~= "rgba16f" then
        self.hdr_fallback_count = self.hdr_fallback_count + 1
    end
    if old_scene and old_scene ~= selected_canvas
        and not resource_is_released(old_scene) then
        release_resource(old_scene)
        self._released_resources = self._released_resources or {}
        self._released_resources[old_scene] = true
        self.target_release_count = self.target_release_count + 1
    end
    if old_depth and old_depth ~= selected_depth
        and not resource_is_released(old_depth) then
        release_resource(old_depth)
        self._released_resources = self._released_resources or {}
        self._released_resources[old_depth] = true
        self.target_release_count = self.target_release_count + 1
    end
    return true, selected_canvas, selected_depth
end

function PostProcess:is_hdr_scene_ready()
    return self:is_available()
        and self.scene_canvas ~= nil
        and self.scene_is_hdr == true
        and FLOAT_SCENE_FORMATS[self.scene_format] == true
end

function PostProcess:_ensure_bloom_targets()
    local width = math.max(1, math.floor((self.scene_width + 1) * 0.5))
    local height = math.max(1, math.floor((self.scene_height + 1) * 0.5))
    if self.bloom_a and self.bloom_b
        and not resource_is_released(self.bloom_a)
        and not resource_is_released(self.bloom_b)
        and self.bloom_width == width
        and self.bloom_height == height then
        return true
    end

    local formats, seen = {}, {}
    append_unique(formats, seen, self.scene_format)
    append_unique(formats, seen, "rgba8")
    local bloom_a, bloom_b, selected_format
    local last_error
    for index = 1, #formats do
        local format = formats[index]
        local first, first_error = self:_new_canvas(width, height, {
            format = format,
            readable = true,
            msaa = 0,
        })
        if first then
            local second, second_error = self:_new_canvas(width, height, {
                format = format,
                readable = true,
                msaa = 0,
            })
            if second then
                bloom_a, bloom_b, selected_format = first, second, format
                break
            end
            release_resource(first)
            last_error = second_error
        else
            last_error = first_error
        end
    end
    if not bloom_a or not bloom_b then
        self.bloom_target_failure_count =
            self.bloom_target_failure_count + 1
        self.last_bloom_failure_reason =
            "bloom_canvas_allocation_failed:" .. tostring(last_error)
        return false, self.last_bloom_failure_reason
    end
    if bloom_a.setFilter then bloom_a:setFilter("linear", "linear") end
    if bloom_b.setFilter then bloom_b:setFilter("linear", "linear") end
    if bloom_a.setWrap then bloom_a:setWrap("clamp", "clamp") end
    if bloom_b.setWrap then bloom_b:setWrap("clamp", "clamp") end

    self:_release_bloom_targets()
    self.bloom_a = bloom_a
    self.bloom_b = bloom_b
    self.bloom_width = width
    self.bloom_height = height
    self.bloom_format = selected_format
    self.target_allocation_count = self.target_allocation_count + 2
    self.last_bloom_failure_reason = nil
    return true
end

function PostProcess:_resolve_effect_state(state)
    state = type(state) == "table" and state or {}
    local post_effects = type(state.post_effects) == "table"
        and state.post_effects or {}
    local bloom = post_effects.bloom
    local bloom_enabled = effect_enabled(bloom)
    local intensity = bloom_enabled and clamp_number(
        bloom.Intensity, 0, 3, 0) or 0
    local size = bloom_enabled and clamp_number(
        bloom.Size, 0, 56, 24) or 0
    local threshold = bloom_enabled and clamp_number(
        bloom.Threshold, 0, 8, 1) or 8

    local correction = post_effects.color_correction
    local correction_enabled = effect_enabled(correction)
    local brightness = correction_enabled and clamp_number(
        correction.Brightness, -1, 1, 0) or 0
    local contrast = correction_enabled and clamp_number(
        correction.Contrast, -1, 4, 0) or 0
    local saturation = correction_enabled and clamp_number(
        correction.Saturation, -1, 4, 0) or 0
    local tint_r, tint_g, tint_b = 1, 1, 1
    if correction_enabled then
        local tint = correction.TintColor
        tint_r, tint_g, tint_b = coords.color3_to_gpu(
            color_component(tint, 1, "r", "R", 1),
            color_component(tint, 2, "g", "G", 1),
            color_component(tint, 3, "b", "B", 1))
    end
    return {
        exposure = clamp_number(
            state.exposure_multiplier, 0.03125, 32, 1),
        bloom_active = bloom_enabled and intensity > 0.00001,
        bloom_intensity = intensity,
        bloom_size = size,
        bloom_threshold = threshold,
        correction_active = correction_enabled,
        brightness = brightness,
        contrast = contrast,
        saturation = saturation,
        tint_r = tint_r,
        tint_g = tint_g,
        tint_b = tint_b,
    }
end

function PostProcess:_draw_fullscreen(source, target, shader)
    local source_width, source_height = source:getDimensions()
    local target_width, target_height = target:getDimensions()
    self.graphics.setCanvas(target)
    self.graphics.clear(0, 0, 0, 0)
    self.graphics.setShader(shader)
    self.graphics.setColor(1, 1, 1, 1)
    self.graphics.draw(source, 0, 0, 0,
        target_width / source_width,
        target_height / source_height)
end

function PostProcess:_copy_scene_fallback(scene_canvas, output_canvas)
    local graphics = self.graphics
    local pushed = pcall(graphics.push, "all")
    local ok = pcall(function()
        graphics.origin()
        graphics.setScissor()
        graphics.setColorMask(true, true, true, true)
        graphics.setWireframe(false)
        graphics.setBlendMode("replace", "premultiplied")
        graphics.setDepthMode("always", false)
        graphics.setMeshCullMode("none")
        self:_draw_fullscreen(scene_canvas, output_canvas, nil)
        graphics.setShader()
    end)
    if pushed then pcall(graphics.pop) end
    return ok
end

function PostProcess:_grade_scene_fallback(
    scene_canvas, output_canvas, resolved)
    local graphics = self.graphics
    local pushed = pcall(graphics.push, "all")
    local ok = pcall(function()
        graphics.origin()
        graphics.setScissor()
        graphics.setColorMask(true, true, true, true)
        graphics.setWireframe(false)
        graphics.setBlendMode("replace", "premultiplied")
        graphics.setDepthMode("always", false)
        graphics.setMeshCullMode("none")
        self._tint_uniform[1] = resolved.tint_r
        self._tint_uniform[2] = resolved.tint_g
        self._tint_uniform[3] = resolved.tint_b
        self.final_shader:send("uBloomTexture", scene_canvas)
        self.final_shader:send("uBloomEnabled", 0)
        self.final_shader:send("uBloomIntensity", 0)
        self.final_shader:send("uExposure", resolved.exposure)
        self.final_shader:send("uBrightness", resolved.brightness)
        self.final_shader:send("uContrast", resolved.contrast)
        self.final_shader:send("uSaturation", resolved.saturation)
        self.final_shader:send("uTintColor", self._tint_uniform)
        self:_draw_fullscreen(
            scene_canvas, output_canvas, self.final_shader)
        graphics.setShader()
    end)
    if pushed then pcall(graphics.pop) end
    return ok
end

function PostProcess:resolve(scene_canvas, output_canvas, state, view)
    if not self:is_available() or scene_canvas ~= self.scene_canvas then
        return false, self.failure_reason or "post_scene_target_not_ready"
    end
    if not output_canvas then
        return false, "post_output_target_missing"
    end
    local started_at = love.timer and love.timer.getTime
        and love.timer.getTime() or nil
    -- no effect-specific object, shaders, targets, draws or uploads when absent
    local effect = state and state.post_effects and state.post_effects.sun_rays
    if not self.sun_rays and effect and effect.Enabled ~= false
        and (tonumber(effect.Intensity) or .25) > 0 then
        self.sun_rays = runtime_require("sun_rays.lua").new(self.graphics)
    end
    if self.sun_rays then self.sun_rays:apply(self, state, view) end
    local resolved = self:_resolve_effect_state(state)
    local graphics = self.graphics
    local bloom_active = resolved.bloom_active
    if bloom_active then
        bloom_active = self:_ensure_bloom_targets() == true
    end

    local pushed = pcall(graphics.push, "all")
    local ok, error_message = xpcall(function()
        graphics.origin()
        graphics.setScissor()
        graphics.setColorMask(true, true, true, true)
        graphics.setWireframe(false)
        graphics.setBlendMode("replace", "premultiplied")
        graphics.setDepthMode("always", false)
        graphics.setMeshCullMode("none")

        local pass_count = self.sun_rays and self.sun_rays.last_passes or 0
        if bloom_active then
            self._source_texel[1] = 1 / self.scene_width
            self._source_texel[2] = 1 / self.scene_height
            self.bright_shader:send("uExposure", resolved.exposure)
            self.bright_shader:send(
                "uThreshold", resolved.bloom_threshold)
            self.bright_shader:send(
                "uSourceTexel", self._source_texel)
            self:_draw_fullscreen(
                scene_canvas, self.bloom_a, self.bright_shader)
            pass_count = pass_count + 1

            -- repeated bounded Gaussian pairs keep maximum Bloom.Size
            -- continuous. a single sparse nine-tap pass at Size=56 sampled
            -- isolated points ~14 full-resolution pixels apart and produced
            -- comb-shaped zero valleys. Four iterations is the hard ceiling
            local blur_iterations = math.max(1, math.min(4,
                math.ceil(resolved.bloom_size / 14)))
            local radius_half_pixels = math.max(
                0.5, resolved.bloom_size * 0.5)
            local tap_step = clamp_number(
                radius_half_pixels / (4 * blur_iterations),
                0.125, 1.75, 0.5)
            self.last_blur_iterations = blur_iterations
            self.last_blur_tap_step = tap_step
            for _ = 1, blur_iterations do
                self._blur_direction[1] =
                    tap_step / self.bloom_width
                self._blur_direction[2] = 0
                self.blur_shader:send(
                    "uDirection", self._blur_direction)
                self:_draw_fullscreen(
                    self.bloom_a, self.bloom_b, self.blur_shader)
                pass_count = pass_count + 1

                self._blur_direction[1] = 0
                self._blur_direction[2] =
                    tap_step / self.bloom_height
                self.blur_shader:send(
                    "uDirection", self._blur_direction)
                self:_draw_fullscreen(
                    self.bloom_b, self.bloom_a, self.blur_shader)
                pass_count = pass_count + 1
            end
        end

        self._tint_uniform[1] = resolved.tint_r
        self._tint_uniform[2] = resolved.tint_g
        self._tint_uniform[3] = resolved.tint_b
        self.final_shader:send(
            "uBloomTexture", bloom_active and self.bloom_a or scene_canvas)
        self.final_shader:send("uBloomEnabled", bloom_active and 1 or 0)
        self.final_shader:send(
            "uBloomIntensity", resolved.bloom_intensity)
        self.final_shader:send("uExposure", resolved.exposure)
        self.final_shader:send("uBrightness", resolved.brightness)
        self.final_shader:send("uContrast", resolved.contrast)
        self.final_shader:send("uSaturation", resolved.saturation)
        self.final_shader:send("uTintColor", self._tint_uniform)
        self:_draw_fullscreen(scene_canvas, output_canvas, self.final_shader)
        pass_count = pass_count + 1
        graphics.setShader()
        self.last_pass_count = pass_count
    end, function(message)
        return debug.traceback(tostring(message), 2)
    end)
    if pushed then pcall(graphics.pop) end

    self.frame_count = self.frame_count + 1
    self.last_bloom_active = bloom_active
    if started_at then
        self.last_resolve_ms = math.max(0,
            (love.timer.getTime() - started_at) * 1000)
    end
    if not ok then
        self.resolve_failure_count = self.resolve_failure_count + 1
        self.available = false
        self.failure_reason = "post_resolve_failed:" .. tostring(error_message)
        self.last_emergency_grade_ok = self:_grade_scene_fallback(
            scene_canvas, output_canvas, resolved)
        if not self.last_emergency_grade_ok then
            self.last_raw_copy_fallback_ok = self:_copy_scene_fallback(
                scene_canvas, output_canvas)
        end
        return false, self.failure_reason
    end
    return true
end

function PostProcess:diagnostics(state)
    local effects = type(state) == "table"
        and type(state.post_effects) == "table"
        and state.post_effects or {}
    local unsupported = {}
    local descriptors = {
        { key = "blur", name = "BlurEffect" },
        { key = "depth_of_field", name = "DepthOfFieldEffect" },
    }
    for index = 1, #descriptors do
        local descriptor = descriptors[index]
        local value = effects[descriptor.key]
        if effect_enabled(value) then
            unsupported[#unsupported + 1] = {
                key = descriptor.key,
                name = descriptor.name,
                reason = "not_implemented_in_hdr_post_tranche",
            }
        end
    end
    return {
        requested = self.enabled == true,
        available = self:is_available(),
        active = self:is_available() and self.scene_canvas ~= nil,
        failure_reason = self.failure_reason,
        scene_format = self.scene_format,
        scene_is_hdr = self.scene_is_hdr == true,
        scene_width = self.scene_width or 0,
        scene_height = self.scene_height or 0,
        scene_samples = self.scene_samples or 0,
        depth_format = self.depth_format,
        bloom_format = self.bloom_format,
        bloom_width = self.bloom_width or 0,
        bloom_height = self.bloom_height or 0,
        bloom_active_last_frame = self.last_bloom_active == true,
        sun_rays_active = self.sun_rays and self.sun_rays.valid or false,
        sun_rays_passes = self.sun_rays and self.sun_rays.last_passes or 0,
        sun_rays_storage_bytes = self.sun_rays and self.sun_rays.storage_bytes or 0,
        sun_rays_failure = self.sun_rays and self.sun_rays.failure_reason,
        sun_rays_skip = self.sun_rays and self.sun_rays.skip_reason,
        sun_rays_policy = "rendered opaque/cutout depth; blended non-occluding; full mask MSAA + quarter rgba16f,32 taps,3 passes",

        supported_effects = {
            "BloomEffect",
            "ColorCorrectionEffect",
            "SunRaysEffect",
        },
        unsupported_enabled_effects = unsupported,
        output_alpha_mode = "premultiplied",
        sky_treatment = "world_hdr_graded_once",
        screen_gui_treatment = "ldr_after_post_ungraded",
        frame_count = self.frame_count,
        last_pass_count = self.last_pass_count,
        last_blur_iterations = self.last_blur_iterations or 0,
        last_blur_tap_step = self.last_blur_tap_step or 0,
        last_resolve_ms = self.last_resolve_ms,
        resolve_failure_count = self.resolve_failure_count,
        target_allocation_count = self.target_allocation_count,
        target_release_count = self.target_release_count,
        hdr_fallback_count = self.hdr_fallback_count,
        bloom_target_failure_count = self.bloom_target_failure_count,
        last_bloom_failure_reason = self.last_bloom_failure_reason,
        last_emergency_grade_ok = self.last_emergency_grade_ok,
        last_raw_copy_fallback_ok = self.last_raw_copy_fallback_ok,
    }
end

function PostProcess:owns_released_resource(resource)
    return resource ~= nil
        and self._released_resources ~= nil
        and self._released_resources[resource] == true
end

function PostProcess:disable(reason)
    self:_release_targets()
    self.available = false
    self.failure_reason = tostring(reason or "disabled_after_runtime_failure")
    return false
end

function PostProcess:release()
    if self.released then return false end
    self:_release_targets()
    for _, field in ipairs({
        "bright_shader", "blur_shader", "final_shader",
    }) do
        local resource = self[field]
        if resource and not resource_is_released(resource) then
            release_resource(resource)
        end
        self[field] = nil
    end
    self.released = true
    self.available = false
    self.failure_reason = "released"
    return true
end

return PostProcess
