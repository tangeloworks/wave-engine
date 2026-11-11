local PostFX = {}

local shader = nil
local warned_replace_blend = false

local function setting_value(name, fallback)
    local setting = CFG:getSetting(name)
    if setting.value == nil then
        return fallback
    end
    return setting.value
end

local function colorblind_mode()
    local cb = setting_value("colorblind", "none")
    if cb == "protanopia" then
        return 1
    elseif cb == "deuteranopia" then
        return 2
    elseif cb == "tritanopia" then
        return 3
    end
    return 0
end

local function clamp_channel(value)
    return math.max(0, math.min(1, value))
end

-- Accessibility math needs a linear working space. LÖVE supplies one to
-- shaders when gamma correction is enabled, projects are allowed to turn that
-- feature off, so the shader and its CPU reference explicitly convert in that
-- case instead of treating encoded sRGB values as luminance
local function gamma_correct_enabled()
    return love.graphics.isGammaCorrect and love.graphics.isGammaCorrect() == true
end

local function srgb_to_linear_channel(value)
    value = clamp_channel(value)
    if value <= 0.04045 then return value / 12.92 end
    return ((value + 0.055) / 1.055) ^ 2.4
end

local function linear_to_srgb_channel(value)
    value = clamp_channel(value)
    if value <= 0.0031308 then return value * 12.92 end
    return 1.055 * (value ^ (1 / 2.4)) - 0.055
end

local function luminance(r, g, b)
    return r * 0.2126 + g * 0.7152 + b * 0.0722
end

---Simulate the selected complete dichromacy endpoint through the LMS
---projection used by the paired real-time daltonization correction below
---keeping simulation and correction in one model avoids a misleading mix of
---unrelated matrix families. this helper is a display model, not a diagnosis
---@return number, number, number
function PostFX.simulate_cvd_rgb(r, g, b, mode)
    local selected = mode
    if type(selected) == 'string' then
        selected = ({ protanopia = 1, deuteranopia = 2, tritanopia = 3 })[selected] or 0
    end
    selected = tonumber(selected) or 0
    r, g, b = clamp_channel(r), clamp_channel(g), clamp_channel(b)
    if selected < 0.5 then return r, g, b end

    -- linear sRGB -> cone-response approximation (LMS)
    local l = 17.8824 * r + 43.5161 * g + 4.11935 * b
    local m = 3.45565 * r + 27.1554 * g + 3.86714 * b
    local s = 0.0299566 * r + 0.184309 * g + 1.46709 * b
    if selected < 1.5 then
        l = 2.02344 * m - 2.52581 * s
    elseif selected < 2.5 then
        m = 0.494207 * l + 1.24827 * s
    else
        s = -0.395913 * l + 0.801109 * m
    end
    -- LMS -> linear sRGB. the coefficients are the inverse of the response
    -- approximation above and operate on the same 0..1 linear domain
    local sr = 0.0809444479 * l - 0.130504409 * m + 0.116721066 * s
    local sg = -0.0102485335 * l + 0.0540193266 * m - 0.113614708 * s
    local sb = -0.000365296938 * l - 0.00412161469 * m + 0.693511405 * s
    return clamp_channel(sr), clamp_channel(sg), clamp_channel(sb)
end

---Re-encode information that the selected CVD model loses into channels the
---model retains. the transform first derives a physically-motivated CVD
---simulation, then applies the type-specific Fidaner-style error-redistribution
---matrix. this is real daltonization, not a CVD preview, but cannot replace
---accessible authoring or claim a universal medical correction
---@return number, number, number
function PostFX.assist_rgb(r, g, b, mode)
    local selected = mode
    if type(selected) == 'string' then
        selected = ({ protanopia = 1, deuteranopia = 2, tritanopia = 3 })[selected] or 0
    end
    selected = tonumber(selected) or 0
    r, g, b = clamp_channel(r), clamp_channel(g), clamp_channel(b)
    if selected < 0.5 then return r, g, b end

    local sr, sg, sb = PostFX.simulate_cvd_rgb(r, g, b, selected)
    local er, eg, eb = r - sr, g - sg, b - sb
    local cr, cg, cb
    if selected < 1.5 then
        -- Protanopia: the L-cone loss is re-encoded into M/S information
        cr, cg, cb = 0, 0.7 * er + eg, 0.7 * er + eb
    elseif selected < 2.5 then
        -- Deuteranopia: the M-cone loss is re-encoded into L/S information
        cr, cg, cb = er + 0.7 * eg, 0, 0.7 * eg + eb
    else
        -- Tritanopia: the S-cone loss is re-encoded into L/M information
        cr, cg, cb = er + 0.7 * eb, eg + 0.7 * eb, 0
    end
    return clamp_channel(r + cr), clamp_channel(g + cg), clamp_channel(b + cb)
end

---apply the hue-preserving enhanced-contrast curve used by the automatic final
---frame shader. it covers every completed project frame without project-side
---setting checks, it is still a display enhancement rather than a claim that
---arbitrary text-over-image content meets a semantic contrast standard
---@return number, number, number
function PostFX.enhance_contrast_rgb(r, g, b)
    r, g, b = clamp_channel(r), clamp_channel(g), clamp_channel(b)
    local old_luma = clamp_channel(luminance(r, g, b))
    -- a full smoothstep in linear light makes ordinary dark scene detail much
    -- too close to black. Blend it with the original luminance instead: this
    -- increases midtone separation while protecting readable shadow detail,
    -- preserves black/white endpoints, and never creates clipped bands
    local curved_luma = old_luma * old_luma * (3 - 2 * old_luma)
    local new_luma = old_luma + (curved_luma - old_luma) * 0.35
    local dr, dg, db = r - old_luma, g - old_luma, b - old_luma
    local scale = 1
    local function limit(component)
        if component > 0 then
            scale = math.min(scale, (1 - new_luma) / component)
        elseif component < 0 then
            scale = math.min(scale, new_luma / -component)
        end
    end
    limit(dr)
    limit(dg)
    limit(db)
    scale = clamp_channel(scale)
    return clamp_channel(new_luma + dr * scale),
        clamp_channel(new_luma + dg * scale),
        clamp_channel(new_luma + db * scale)
end

PostFX.high_contrast_rgb = PostFX.enhance_contrast_rgb

---Adjust a linear-light colour for the brightness setting. when the automatic
---high-contrast filter is active, keep pure black and white fixed so the
---finished frame retains its contrast anchors. the two power curves are
---monotonic, preserve both endpoints, and still move every interior tone in
---the requested direction. Standard brightness retains additive behaviour when
---high contrast is not active
---@return number, number, number
function PostFX.adjust_brightness_rgb(r, g, b, brightness, preserve_endpoints)
    brightness = tonumber(brightness) or 0
    r, g, b = clamp_channel(r), clamp_channel(g), clamp_channel(b)

    local function adjust(channel)
        if not preserve_endpoints then
            return clamp_channel(channel + brightness)
        end
        if brightness >= 0 then
            return clamp_channel(1 - (1 - channel) ^ (1 + 2 * brightness))
        end
        return clamp_channel(channel ^ (1 - 2 * brightness))
    end

    return adjust(r), adjust(g), adjust(b)
end

--- apply the same color transform as the final shader to sRGB values
--- projects can use this to check how a color will look with the current display settings
---@param options table|nil
---@return number, number, number
function PostFX.transform_rgb(r, g, b, options)
    options = options or {}
    r, g, b = clamp_channel(r), clamp_channel(g), clamp_channel(b)

    if options.encoded_srgb ~= false then
        r, g, b = srgb_to_linear_channel(r), srgb_to_linear_channel(g), srgb_to_linear_channel(b)
    end

    -- a grayscale image has no remaining colour channel to assist. Making
    -- grayscale take precedence keeps its luminance stable when a player also
    -- has a colour-vision-assist selection saved
    if options.grayscale == true then
        local y = luminance(r, g, b)
        r, g, b = y, y, y
    else
        r, g, b = PostFX.assist_rgb(r, g, b, options.colorblind or options.mode)
    end

    local high_contrast = options.high_contrast == true
    local brightness = tonumber(options.brightness) or 0
    r, g, b = PostFX.adjust_brightness_rgb(r, g, b, brightness, high_contrast)
    local gamma = math.max(tonumber(options.gamma) or 1, 0.001)
    local exponent = 1 / gamma
    r, g, b = r ^ exponent, g ^ exponent, b ^ exponent

    if high_contrast then
        r, g, b = PostFX.enhance_contrast_rgb(r, g, b)
    end

    if options.encoded_srgb ~= false then
        r, g, b = linear_to_srgb_channel(r), linear_to_srgb_channel(g), linear_to_srgb_channel(b)
    end
    return clamp_channel(r), clamp_channel(g), clamp_channel(b)
end

local function bool_text(value)
    return value and "true" or "false"
end

local function safe_call(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then
        return a, b, c, d
    end
    return nil
end

local function object_id(value)
    if value == nil then
        return "nil"
    end
    return tostring(value)
end

local function snapshot_graphics_state()
    local graphics = love.graphics

    local blend_mode, alpha_mode = safe_call(graphics.getBlendMode)
    local depth_compare, depth_write = safe_call(graphics.getDepthMode)
    local cull_mode = safe_call(graphics.getMeshCullMode)
    local shader_value = safe_call(graphics.getShader)
    local canvas_value = safe_call(graphics.getCanvas)
    local cm_r, cm_g, cm_b, cm_a = safe_call(graphics.getColorMask)
    local sc_x, sc_y, sc_w, sc_h = safe_call(graphics.getScissor)
    local stencil_compare, stencil_value = safe_call(graphics.getStencilTest)

    return {
        shader = object_id(shader_value),
        canvas = object_id(canvas_value),
        blend = tostring(blend_mode or "unknown") .. "/" .. tostring(alpha_mode or "unknown"),
        depth = tostring(depth_compare or "unknown") .. "/" .. tostring(depth_write),
        cull = tostring(cull_mode or "unknown"),
        color_mask = table.concat({
            bool_text(cm_r ~= false),
            bool_text(cm_g ~= false),
            bool_text(cm_b ~= false),
            bool_text(cm_a ~= false),
        }, ","),
        scissor = sc_x and table.concat({ sc_x, sc_y or 0, sc_w or 0, sc_h or 0 }, ",") or "nil",
        stencil = tostring(stencil_compare or "nil") .. "/" .. tostring(stencil_value or "nil"),
    }
end

local function state_diff(a, b)
    local fields = { "shader", "canvas", "blend", "depth", "cull", "color_mask", "scissor", "stencil" }
    local diffs = {}
    for index = 1, #fields do
        local field = fields[index]
        if tostring(a and a[field]) ~= tostring(b and b[field]) then
            diffs[#diffs + 1] = field .. ":" .. tostring(a and a[field]) .. "->" .. tostring(b and b[field])
        end
    end
    return diffs
end

function PostFX.get_shader()
    if shader then
        return shader
    end
    local code = [[
        extern number uGamma;
        extern number uBrightness;
        extern number uGrayscale;
        extern number uHighContrast;
        extern number uCBMode;
        extern number uGammaCorrect;

        // The CVD endpoint and correction use one linear-sRGB/LMS model.
        // The assist then applies type-specific error redistribution
        // (daltonization), so it is correction-oriented rather than a CVD
        // preview.
        vec3 srgbToLinear(vec3 c) {
            vec3 low = c / 12.92;
            vec3 high = pow((c + vec3(0.055)) / 1.055, vec3(2.4));
            return mix(low, high, step(vec3(0.04045), c));
        }

        vec3 linearToSrgb(vec3 c) {
            c = clamp(c, 0.0, 1.0);
            vec3 low = c * 12.92;
            vec3 high = vec3(1.055) * pow(c, vec3(1.0 / 2.4)) - vec3(0.055);
            return mix(low, high, step(vec3(0.0031308), c));
        }

        vec3 sourceToWorkingColor(vec3 c) {
            if (uGammaCorrect > 0.5) return c;
            return srgbToLinear(clamp(c, 0.0, 1.0));
        }

        vec3 workingToOutputColor(vec3 c) {
            if (uGammaCorrect > 0.5) return c;
            return linearToSrgb(c);
        }

        vec3 simulateCVD(vec3 c, number mode) {
            if (mode < 0.5) return c;
            number l = 17.8824 * c.r + 43.5161 * c.g + 4.11935 * c.b;
            number m = 3.45565 * c.r + 27.1554 * c.g + 3.86714 * c.b;
            number s = 0.0299566 * c.r + 0.184309 * c.g + 1.46709 * c.b;
            if (mode < 1.5) {
                l = 2.02344 * m - 2.52581 * s;
            } else if (mode < 2.5) {
                m = 0.494207 * l + 1.24827 * s;
            } else {
                s = -0.395913 * l + 0.801109 * m;
            }
            return vec3(
                0.0809444479 * l - 0.130504409 * m + 0.116721066 * s,
                -0.0102485335 * l + 0.0540193266 * m - 0.113614708 * s,
                -0.000365296938 * l - 0.00412161469 * m + 0.693511405 * s);
        }

        vec3 applyColorVisionAssist(vec3 c, number mode) {
            if (mode < 0.5) return c;
            vec3 error = c - clamp(simulateCVD(c, mode), 0.0, 1.0);
            vec3 correction;
            if (mode < 1.5) {
                correction = vec3(0.0, 0.7 * error.r + error.g,
                    0.7 * error.r + error.b);
            } else if (mode < 2.5) {
                correction = vec3(error.r + 0.7 * error.g, 0.0,
                    0.7 * error.g + error.b);
            } else {
                correction = vec3(error.r + 0.7 * error.b,
                    error.g + 0.7 * error.b, 0.0);
            }
            return clamp(c + correction, 0.0, 1.0);
        }

        vec3 applyGrayscale(vec3 c) {
            number y = dot(c, vec3(0.2126, 0.7152, 0.0722));
            return vec3(y, y, y);
        }

        // Keep black/white frame endpoints through automatic high contrast
        // brightness adjustment. The power curves are monotonic, so they avoid
        // clipped plateaus while retaining ordinary additive brightness outside
        // high-contrast mode.
        vec3 applyBrightness(vec3 c, number brightness, number preserveEndpoints) {
            c = clamp(c, 0.0, 1.0);
            if (preserveEndpoints < 0.5) {
                return clamp(c + vec3(brightness), 0.0, 1.0);
            }
            if (brightness >= 0.0) {
                return clamp(vec3(1.0) - pow(vec3(1.0) - c, vec3(1.0 + 2.0 * brightness)), 0.0, 1.0);
            }
            return clamp(pow(c, vec3(1.0 - 2.0 * brightness)), 0.0, 1.0);
        }

        number luma(vec3 c) {
            return dot(c, vec3(0.2126, 0.7152, 0.0722));
        }

        number gamutSafeChromaScale(vec3 chroma, number targetLuma) {
            number scale = 1.0;
            if (chroma.r > 0.0) scale = min(scale, (1.0 - targetLuma) / chroma.r);
            else if (chroma.r < 0.0) scale = min(scale, targetLuma / -chroma.r);
            if (chroma.g > 0.0) scale = min(scale, (1.0 - targetLuma) / chroma.g);
            else if (chroma.g < 0.0) scale = min(scale, targetLuma / -chroma.g);
            if (chroma.b > 0.0) scale = min(scale, (1.0 - targetLuma) / chroma.b);
            else if (chroma.b < 0.0) scale = min(scale, targetLuma / -chroma.b);
            return clamp(scale, 0.0, 1.0);
        }

        // A shadow-protected luminance-only S curve improves midtone
        // separation while preserving hue/chroma wherever the target gamut
        // allows it. A full linear-light smoothstep crushes normal dark scene
        // detail, so blend only part of that curve into the source luminance.
        vec3 applyEnhancedContrast(vec3 c, number enabled) {
            if (enabled < 0.5) return c;
            number oldLuma = clamp(luma(c), 0.0, 1.0);
            number curvedLuma = oldLuma * oldLuma * (3.0 - 2.0 * oldLuma);
            number targetLuma = mix(oldLuma, curvedLuma, 0.35);
            vec3 chroma = c - vec3(oldLuma);
            return clamp(vec3(targetLuma) + chroma * gamutSafeChromaScale(chroma, targetLuma), 0.0, 1.0);
        }

        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc)
        {
            vec4 src = Texel(tex, uv) * color;
            vec3 c = src.a > 0.0 ? src.rgb / src.a : src.rgb;
            c = sourceToWorkingColor(c);
            if (uGrayscale > 0.5) c = applyGrayscale(c);
            else c = applyColorVisionAssist(c, uCBMode);
            c = applyBrightness(c, uBrightness, uHighContrast);
            number invGamma = 1.0 / max(uGamma, 0.001);
            c = pow(c, vec3(invGamma));
            c = applyEnhancedContrast(c, uHighContrast);
            c = workingToOutputColor(c);
            return vec4(c * src.a, src.a);
        }
    ]]
    shader = love.graphics.newShader(code)
    return shader
end

function PostFX.active()
    if CFG and CFG.postfx_active then
        return CFG.postfx_active()
    end
    local cb = setting_value("colorblind", "none")
    local grayscale = setting_value("grayscale", false) == true
    local high_contrast = setting_value("high_contrast", false) == true
    local gamma = tonumber(setting_value("gamma", 1.0)) or 1.0
    local brightness = tonumber(setting_value("brightness", 0.0)) or 0.0
    return (cb ~= "none") or grayscale or high_contrast or gamma ~= 1.0 or brightness ~= 0.0
end

function PostFX.send_uniforms()
    local sh = PostFX.get_shader()
    sh:send("uGamma", tonumber(setting_value("gamma", 1.0)) or 1.0)
    sh:send("uBrightness", tonumber(setting_value("brightness", 0.0)) or 0.0)
    sh:send("uGrayscale", setting_value("grayscale", false) == true and 1 or 0)
    sh:send("uHighContrast", setting_value("high_contrast", false) == true and 1 or 0)
    sh:send("uCBMode", colorblind_mode())
    sh:send("uGammaCorrect", gamma_correct_enabled() and 1 or 0)
end

function PostFX.ensure_canvas(width, height)
    width = math.max(1, math.floor((tonumber(width) or 1) + 0.5))
    height = math.max(1, math.floor((tonumber(height) or 1) + 0.5))
    local Surface = require("engine/graphics/surface")
    if not Surface.matches(G.postfxCanvas, width, height) then
        G.postfxCanvas = Surface.new_canvas(width, height)
        G.postfxCanvas:setWrap("clampzero", "clampzero")
    end
    return G.postfxCanvas
end

function PostFX.set_canvas_filter(filter)
    G.postfxCanvas:setFilter(filter, filter)
end

function PostFX.begin_frame()
    if not PostFX.active() then
        return false
    end
    local graphics = love.graphics
    local rw = math.max(1, math.floor(G.resolution.x + 0.5))
    local rh = math.max(1, math.floor(G.resolution.y + 0.5))
    local canvas = PostFX.ensure_canvas(rw, rh)

    PostFX._active_frame = true
    PostFX._frame_push_active = false
    PostFX._target_before_begin = G._presentation_target
    PostFX._shader_binds_this_frame = 0
    PostFX._state_before_begin = snapshot_graphics_state()
    PostFX._state_before_grayscale = nil
    PostFX._state_after_pop = nil
    PostFX._used_depth_canvas = true
    graphics.push("all")
    PostFX._frame_push_active = true
    graphics.setCanvas({ canvas, depth = true, stencil = true })
    G._presentation_target = { kind = "postfx", canvas = canvas }
    graphics.setShader()
    graphics.origin()
    graphics.setScissor()
    graphics.setStencilTest()
    graphics.setColorMask(true, true, true, true)
    graphics.setBlendMode("alpha", "alphamultiply")
    graphics.setDepthMode("always", true)
    graphics.clear(0, 0, 0, 0, true, true)
    -- leave the pipeline in 2D depth state ("always", no write). a "less"+write here
    -- let the first fullscreen rect claim the depth buffer and every later 2D draw
    -- (pause backdrop, menus, HUD) failed the test -> solid-color screen whenever the
    -- 3D pass (which sets its own depth modes) wasn't there to reset state
    graphics.setDepthMode("always", false)
    graphics.setMeshCullMode("none")
    graphics.setColor(1, 1, 1, 1)
    return true
end

---Safely unwind an incomplete normal presentation pass after a draw error
---the graphics stack itself restores the prior Canvas descriptor (including
---temporary depth/stencil attachments), the saved engine marker restores the
---matching ratio pass when one contains this post-process pass
function PostFX.abort_frame()
    if not PostFX._active_frame and not PostFX._frame_push_active then
        return false
    end

    local prior_target = PostFX._target_before_begin
    local graphics = love.graphics
    pcall(graphics.setShader)
    if PostFX._frame_push_active then
        pcall(graphics.pop)
    end
    pcall(graphics.setShader)

    PostFX._active_frame = false
    PostFX._frame_push_active = false
    PostFX._target_before_begin = nil
    if G then G._presentation_target = prior_target end
    return true
end

local function set_final_blend()
    local ok = pcall(love.graphics.setBlendMode, "replace", "premultiplied")
    if not ok then
        if not warned_replace_blend then
            warned_replace_blend = true
            print("[graphics] replace blending unavailable, using premultiplied alpha")
        end
        love.graphics.setBlendMode("alpha", "premultiplied")
    end
end

function PostFX.end_frame()
    if not PostFX._active_frame then
        return false
    end
    local graphics = love.graphics
    local canvas = G.postfxCanvas
    PostFX._state_before_grayscale = snapshot_graphics_state()

    G._presentation_target = nil
    graphics.setCanvas()
    graphics.origin()
    graphics.setScissor()
    graphics.setStencilTest()
    graphics.setColorMask(true, true, true, true)
    graphics.setDepthMode("always", false)
    graphics.setMeshCullMode("none")
    set_final_blend()
    graphics.setColor(1, 1, 1, 1)
    PostFX.send_uniforms()
    local sh = PostFX.get_shader()
    graphics.setShader(sh)
    PostFX._shader_binds_this_frame = (PostFX._shader_binds_this_frame or 0) + 1
    PostFX._state_during_grayscale = snapshot_graphics_state()
    graphics.draw(canvas, 0, 0)
    graphics.setShader()
    graphics.pop()
    PostFX._frame_push_active = false
    PostFX._active_frame = false
    PostFX._target_before_begin = nil
    PostFX._state_after_pop = snapshot_graphics_state()
    local leak_details = state_diff(PostFX._state_before_begin or {}, PostFX._state_after_pop or {})
    local state_leak = #leak_details > 0
    PostFX._last_stats = {
        color_vision_assist = setting_value("colorblind", "none"),
        grayscale_enabled = setting_value("grayscale", false) == true,
        high_contrast_enabled = setting_value("high_contrast", false) == true,
        gamma = tonumber(setting_value("gamma", 1.0)) or 1.0,
        brightness = tonumber(setting_value("brightness", 0.0)) or 0.0,
        working_color_space = gamma_correct_enabled() and "linear" or "srgb_linearized",
        grayscale_application_stage = "final_postprocess_only",
        render_target = "postfx_canvas_with_depth",
        depth_buffer_active_during_3d = true,
        depth_buffer_active_during_grayscale = false,
        accessibility_shader_binds = PostFX._shader_binds_this_frame or 0,
        state_leak_detected = state_leak,
        leak_details = leak_details,
    }
    return true
end

---unwind the nested push used while compositing a 4:3 Canvas. this is kept
---separate from abort_frame because the ratio path does not call begin_frame
function PostFX.abort_ratio_composite()
    if not PostFX._ratio_composite_push_active then
        return false
    end
    local graphics = love.graphics
    pcall(graphics.setShader)
    pcall(graphics.pop)
    pcall(graphics.setShader)
    PostFX._ratio_composite_push_active = false
    return true
end

function PostFX.apply_to_canvas(canvas, x, y, sx, sy)
    if not PostFX.active() then
        return false
    end
    local graphics = love.graphics
    PostFX._shader_binds_this_frame = 0
    PostFX._state_before_begin = snapshot_graphics_state()
    graphics.push("all")
    PostFX._ratio_composite_push_active = true
    graphics.setCanvas()
    graphics.origin()
    graphics.setScissor()
    graphics.setStencilTest()
    graphics.setColorMask(true, true, true, true)
    graphics.setDepthMode("always", false)
    graphics.setMeshCullMode("none")
    set_final_blend()
    graphics.setColor(1, 1, 1, 1)
    PostFX.send_uniforms()
    local sh = PostFX.get_shader()
    graphics.setShader(sh)
    PostFX._shader_binds_this_frame = 1
    PostFX._state_before_grayscale = { blend = "ratio_canvas", shader = "nil" }
    PostFX._state_during_grayscale = snapshot_graphics_state()
    graphics.draw(canvas, x or 0, y or 0, 0, sx or 1, sy or sx or 1)
    graphics.setShader()
    graphics.pop()
    PostFX._ratio_composite_push_active = false

    PostFX._state_after_pop = snapshot_graphics_state()
    local leak_details = state_diff(PostFX._state_before_begin or {}, PostFX._state_after_pop or {})
    local state_leak = #leak_details > 0
    PostFX._last_stats = {
        color_vision_assist = setting_value("colorblind", "none"),
        grayscale_enabled = setting_value("grayscale", false) == true,
        high_contrast_enabled = setting_value("high_contrast", false) == true,
        gamma = tonumber(setting_value("gamma", 1.0)) or 1.0,
        brightness = tonumber(setting_value("brightness", 0.0)) or 0.0,
        working_color_space = gamma_correct_enabled() and "linear" or "srgb_linearized",
        grayscale_application_stage = "final_postprocess_only",
        render_target = "ratio_canvas_with_depth",
        depth_buffer_active_during_3d = true,
        depth_buffer_active_during_grayscale = false,
        accessibility_shader_binds = 1,
        state_leak_detected = state_leak,
        leak_details = leak_details,
    }
    return true
end

function PostFX.get_last_stats()
    return PostFX._last_stats or {}
end

function PostFX.reset_debug()
    PostFX._logged_once = false
    PostFX._debug_log_count = 0
    PostFX._last_stats = nil
    PostFX._shader_binds_this_frame = 0
end

return PostFX
