local function resolve_surface_request(self, width, height, options)
    if type(width) == "table" and height == nil and options == nil then
        options = width
        width = nil
        height = nil
    end

    options = options or {}

    local projection_width = round_dimension(
        width
        or options.surface_width
        or options.width
    )
    local projection_height = round_dimension(
        height
        or options.surface_height
        or options.height
    )

    if not projection_width or not projection_height then
        projection_width, projection_height = self:_get_projection_dimensions()
    end

    return projection_width, projection_height, options
end

local function compute_cover_rect(content_width, content_height, target_width, target_height)
    local scale = math.max(target_width / content_width, target_height / content_height)
    local draw_width = content_width * scale
    local draw_height = content_height * scale
    return (target_width - draw_width) * 0.5, (target_height - draw_height) * 0.5, draw_width, draw_height
end

local function snapshot_camera_state(camera)
    if type(camera) ~= "table" then
        return {
            x = 0,
            y = 0,
            z = 0,
            r00 = 1,
            r01 = 0,
            r02 = 0,
            r10 = 0,
            r11 = 1,
            r12 = 0,
            r20 = 0,
            r21 = 0,
            r22 = 1,
        }
    end
    return {
        x = camera.x or 0,
        y = camera.y or 0,
        z = camera.z or 0,
        r00 = camera.r00 or 1,
        r01 = camera.r01 or 0,
        r02 = camera.r02 or 0,
        r10 = camera.r10 or 0,
        r11 = camera.r11 or 1,
        r12 = camera.r12 or 0,
        r20 = camera.r20 or 0,
        r21 = camera.r21 or 0,
        r22 = camera.r22 or 1,
    }
end

local function snapshot_redraw_state(self)
    local camera = snapshot_camera_state(self.camera and self.camera.cframe or nil)
    return {
        scene_revision = self._scene_revision or 0,
        parts_dirty = self._parts_dirty == true,
        map_loading = self:is_map_loading() == true,
        -- instanced motion skips _parts_dirty/_scene_revision, without this needs_redraw freezes moving parts
        instance_move_revision = self._instance_move_revision or 0,
        world_mesh_revision = self._world_mesh_revision or 0,
        camera_x = camera.x,
        camera_y = camera.y,
        camera_z = camera.z,
        camera_r00 = camera.r00,
        camera_r01 = camera.r01,
        camera_r02 = camera.r02,
        camera_r10 = camera.r10,
        camera_r11 = camera.r11,
        camera_r12 = camera.r12,
        camera_r20 = camera.r20,
        camera_r21 = camera.r21,
        camera_r22 = camera.r22,
        camera_fov = tonumber(self.camera and self.camera.fov) or 0,
    }
end

local function redraw_states_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for key, value in pairs(a) do
        if b[key] ~= value then
            return false
        end
    end
    for key, value in pairs(b) do
        if a[key] ~= value then
            return false
        end
    end
    return true
end

function RBX:_prepare_frame_state()
    local prepare_start = love.timer.getTime()
    self._last_draw_packet_build_ms = 0
    self:_pump_async_map_load()
    local map_building = self:_is_async_map_building()

    -- Runtime light enable/count changes and direct quality-option mutation
    -- can change repeated-mesh bucket topology. resolve that before the dirty
    -- scene check so the current frame never draws a scene-wide group with a
    -- newly undersized light-slot budget. during a sliced map build the parsed
    -- light count has already preflighted this topology, while local_lights is
    -- intentionally still empty until parts exist and parent transforms can be
    -- resolved. Re-evaluating that transient zero here used to flip partition
    -- true -> false -> true and schedule a second whole-scene build
    if not map_building and self._update_dirty_local_lights then
        self:_update_dirty_local_lights()
    end
    if not map_building
        and self._sync_instanced_mesh_light_partition_requirement then
        self:_sync_instanced_mesh_light_partition_requirement(
            self.local_light_count or 0, true)
    end
    if not map_building and self._update_dynamic_render_residency then
        self:_update_dynamic_render_residency()
    end
    if self._parts_dirty and not map_building then
        self:_sync_runtime_parts()
    end
    -- moved instanced parts: per-row buffer uploads (scene.lua)
    if self._flush_dirty_instance_rows then
        self:_flush_dirty_instance_rows()
    end
    -- a repeated mesh that crossed a local-light partition boundary is marked
    -- for full rebucketing by the row flush above. Complete it before this
    -- frame draws so motion never spends a frame under the wrong light pack
    if self._parts_dirty and not map_building then
        self:_sync_runtime_parts()
    end
    -- one-time atlas build, re-marks dirty to re-bake uvs, no-op after
    if self._maybe_build_mesh_atlas and not map_building then
        self:_maybe_build_mesh_atlas()
        if self._parts_dirty then
            self:_sync_runtime_parts()
        end
    end
    -- a full/atlas rebuild may have recreated distant chunks. retire those
    -- before collecting this frame's draw lists, including on the first frame
    if not map_building and self._update_dynamic_render_residency then
        self:_update_dynamic_render_residency()
    end
    if prepare_start then
        self._last_prepare_ms = (love.timer.getTime() - prepare_start) * 1000
    end
end

function RBX:needs_redraw()
    return not redraw_states_equal(self._last_present_state, snapshot_redraw_state(self))
end

-- ---- damage post-fx ----------------------------------------------------------

-- health glitch: wavy warp + ordered dither + static, spiking on a hit. it hangs off the present
-- blit because that's the only point the whole frame exists as one texture
-- the game is GAMMA-CORRECT, so Texel() here is LINEAR, not sRGB -- this sticks to uv warps and
-- additive noise and never matches a specific colour, which is what breaks under linear
local DAMAGE_FX_SOURCE = [[
    extern number uAmount;  // 0..1 low-hp base
    extern number uSpike;   // 0..1 hit spike
    extern number uSmog;    // 0..1 special-zombie view distortion
    extern number uTime;
    extern vec2 uTexel;     // 1 / canvas size

    number hash21(vec2 p) {
        return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
    }

    // bayer via mix() selects, not array indexing -- gles2 cant index a mat with a variable
    number bayer2(vec2 p) {
        number x = mod(p.x, 2.0);
        number y = mod(p.y, 2.0);
        return mix(mix(0.0, 2.0, x), mix(3.0, 1.0, x), y);
    }
    number bayer4(vec2 p) {
        return (4.0 * bayer2(floor(p * 0.5)) + bayer2(p)) / 16.0;
    }

    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
        number amt = clamp(uAmount + uSpike * 0.75, 0.0, 1.4);
        number edge = clamp(length(uv - 0.5) * 2.0, 0.0, 1.0);
        number w = amt * (0.3 + 0.7 * edge); // warp grows outward, centre stays readable

        vec2 d = uv;
        vec2 centre = uv - 0.5;
        number twist = sin(uTime * 1.7 + length(centre) * 18.0) * 0.055 * uSmog;
        d += vec2(-centre.y, centre.x) * twist;
        d.x += sin(uv.y * 11.0 + uTime * 2.4) * 0.012 * uSmog;
        d.x += sin(uv.y * 26.0 + uTime * 3.3) * 0.0055 * w;
        d.y += cos(uv.x * 19.0 + uTime * 2.1) * 0.0040 * w;
        // scanline tear: rows jump sideways. squared so it's a spike thing, not a constant
        number row = floor(uv.y / max(uTexel.y * 3.0, 0.0001));
        number tear = hash21(vec2(row, floor(uTime * 22.0))) - 0.5;
        d.x += tear * 0.035 * uSpike * uSpike;
        d = clamp(d, vec2(0.0005), vec2(0.9995));

        vec4 c = Texel(tex, d);
        number ca = 0.005 * uSpike; // chromatic split, spike only
        if (ca > 0.0002) {
            c.r = Texel(tex, clamp(d + vec2(ca, 0.0), vec2(0.0005), vec2(0.9995))).r;
            c.b = Texel(tex, clamp(d - vec2(ca, 0.0), vec2(0.0005), vec2(0.9995))).b;
        }

        number n = hash21(floor(sc) + vec2(floor(uTime * 47.0))); // static
        c.rgb += (n - 0.5) * 0.20 * amt;

        // ordered dither: the picture degrades into visible steps as you weaken
        number levels = mix(255.0, 5.0, clamp(amt, 0.0, 1.0));
        number dth = bayer4(sc) - 0.5;
        c.rgb = floor(c.rgb * levels + dth) / levels;

        number g = dot(c.rgb, vec3(0.299, 0.587, 0.114)); // bleed colour out, push red
        c.rgb = mix(c.rgb, vec3(g * 1.05, g * 0.45, g * 0.42), clamp(amt * 0.55, 0.0, 0.8));
        c.rgb *= 1.0 - edge * edge * 0.55 * clamp(amt, 0.0, 1.0); // vignette closes in
        return c * color;
    }
]]

-- the desktop static/dither path uses large sin/hash values that lose enough
-- precision on common GLES mediump fragment shaders to produce NaNs or a black
-- frame. this variant stays in a small numeric range and always emits a valid,
-- opaque sampled frame while preserving warp, chromatic split and low-HP red
local DAMAGE_FX_MOBILE_SOURCE = [[
    extern number uAmount;
    extern number uSpike;
    extern number uSmog;
    extern number uTime;
    extern vec2 uTexel;

    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
        number amt = clamp(uAmount + uSpike * 0.65, 0.0, 1.0);
        vec2 centre = uv - 0.5;
        number edge = clamp(length(centre) * 2.0, 0.0, 1.0);
        vec2 d = uv;
        number twist = sin(uTime * 1.5 + length(centre) * 16.0) * 0.05 * uSmog;
        d += vec2(-centre.y, centre.x) * twist;
        d.x += sin(uv.y * 18.0 + uTime * 2.2) * (0.004 * amt + 0.012 * uSmog);
        d.y += cos(uv.x * 13.0 + uTime * 1.8) * (0.003 * amt + 0.008 * uSmog);
        d = clamp(d, vec2(0.001), vec2(0.999));

        vec4 c = Texel(tex, d);
        number split = 0.004 * uSpike;
        c.r = Texel(tex, clamp(d + vec2(split, 0.0), vec2(0.001), vec2(0.999))).r;
        c.b = Texel(tex, clamp(d - vec2(split, 0.0), vec2(0.001), vec2(0.999))).b;
        number grey = dot(c.rgb, vec3(0.299, 0.587, 0.114));
        c.rgb = mix(c.rgb, vec3(grey * 1.05, grey * 0.48, grey * 0.44), amt * 0.5);
        c.rgb *= 1.0 - edge * edge * 0.4 * amt;
        return vec4(clamp(c.rgb * color.rgb, 0.0, 1.0), c.a * color.a);
    }
]]

local _damage_shader
local function damage_shader()
    if _damage_shader == nil then
        local os_name = love.system.getOS()
        local source = (os_name == "Android" or os_name == "iOS")
            and DAMAGE_FX_MOBILE_SOURCE or DAMAGE_FX_SOURCE
        local ok, sh = pcall(love.graphics.newShader, source)
        _damage_shader = ok and sh or false -- false = compile failed, dont retry every frame
    end
    return _damage_shader or nil
end

-- compile + cache the damage shader without rendering anything: call behind the
-- loading cover so the driver compile doesn't land on the first frame the
-- player ever takes a hit. returns whether the shader is usable
function RBX:warm_damage_fx()
    return damage_shader() ~= nil
end

local function clamp01(v)
    v = tonumber(v) or 0
    if v < 0 then return 0 elseif v > 1 then return 1 end
    return v
end

-- amount = low-hp base, spike = the hit flash. both 0 turns it off entirely -- and with it the
-- forced canvas path, so a healthy player pays nothing
function RBX:set_damage_fx(amount, spike, smog)
    self._damage_fx_amount = clamp01(amount)
    self._damage_fx_spike = clamp01(spike)
    self._damage_fx_smog = clamp01(smog)
end

function RBX:_damage_fx_active()
    return (self._damage_fx_amount or 0) > 0.002 or (self._damage_fx_spike or 0) > 0.002
        or (self._damage_fx_smog or 0) > 0.002
end

function RBX:render_to_canvas(width, height, options)
    local projection_width, projection_height = resolve_surface_request(self, width, height, options)
    local draw_start = love.timer.getTime()

    self._last_surface_path = "render_to_canvas"
    self._last_render_to_canvas_used = true
    self._last_draw_to_rect_used = false
    self._last_fullscreen_canvas_copy = false
    self._last_canvas_blit_ms = 0
    self:_prepare_frame_state()

    local render_canvas = self:_ensure_render_canvas(projection_width, projection_height)
    self._last_render_target_width = render_canvas:getWidth()
    self._last_render_target_height = render_canvas:getHeight()
    self:_render_scene_to_canvas(render_canvas, projection_width, projection_height)
    self:_record_draw_time(draw_start)
    self._last_present_state = snapshot_redraw_state(self)

    return render_canvas, {
        projection_width = projection_width,
        projection_height = projection_height,
        canvas_width = render_canvas:getWidth(),
        canvas_height = render_canvas:getHeight(),
        render_to_canvas = true,
        draw_to_rect = false,
        fullscreen_canvas_copy = false,
    }
end

local function can_draw_rect_direct(self, target_x, target_y, target_width, target_height, options)
    if options.force_canvas == true or options.force_render_canvas == true then
        return false
    end
    if (options.fit or "stretch") ~= "stretch" then
        return false
    end
    if type(options.background_color or options.clear_color) == "table" then
        return false
    end
    if self:_should_draw_via_render_canvas() then
        return false
    end
    local requested_width = round_dimension(options.surface_width or options.width)
    local requested_height = round_dimension(options.surface_height or options.height)
    if requested_width and requested_width ~= target_width then
        return false
    end
    if requested_height and requested_height ~= target_height then
        return false
    end
    local active_width, active_height = RBX._get_active_surface_dimensions()
    return math.abs(target_x) <= 0.5
        and math.abs(target_y) <= 0.5
        and math.abs(target_width - active_width) <= 0.5
        and math.abs(target_height - active_height) <= 0.5
end

function RBX:draw_to_rect(x, y, width, height, options)
    options = options or {}

    local target_width = math.max(1, round_dimension(width) or 1)
    local target_height = math.max(1, round_dimension(height) or 1)
    local target_x = tonumber(x) or 0
    local target_y = tonumber(y) or 0
    local fit = options.fit or "stretch"

    if can_draw_rect_direct(self, target_x, target_y, target_width, target_height, options) then
        self:draw()
        self._last_surface_path = "draw_to_rect_direct"
        self._last_render_to_canvas_used = false
        self._last_draw_to_rect_used = true
        self._last_fullscreen_canvas_copy = false
        self._last_canvas_blit_ms = 0
        return nil, {
            projection_width = target_width,
            projection_height = target_height,
            canvas_width = target_width,
            canvas_height = target_height,
            draw_x = target_x,
            draw_y = target_y,
            draw_width = target_width,
            draw_height = target_height,
            target_x = target_x,
            target_y = target_y,
            target_width = target_width,
            target_height = target_height,
            fit = fit,
            render_to_canvas = false,
            draw_to_rect = true,
            direct_render = true,
            fullscreen_canvas_copy = false,
        }
    end

    local surface_width = options.use_projection_size and nil or target_width
    local surface_height = options.use_projection_size and nil or target_height
    if options.surface_width or options.surface_height or options.width or options.height then
        surface_width = options.surface_width or options.width
        surface_height = options.surface_height or options.height
    end

    local render_canvas, surface = self:render_to_canvas(surface_width, surface_height, options)

    local draw_x = target_x
    local draw_y = target_y
    local draw_width = target_width
    local draw_height = target_height

    if fit == "contain" then
        local offset_x, offset_y, fitted_width, fitted_height = self:_compute_letterbox_rect(
            surface.canvas_width,
            surface.canvas_height,
            target_width,
            target_height
        )
        draw_x = target_x + offset_x
        draw_y = target_y + offset_y
        draw_width = fitted_width
        draw_height = fitted_height
    elseif fit == "cover" then
        local offset_x, offset_y, covered_width, covered_height = compute_cover_rect(
            surface.canvas_width,
            surface.canvas_height,
            target_width,
            target_height
        )
        draw_x = target_x + offset_x
        draw_y = target_y + offset_y
        draw_width = covered_width
        draw_height = covered_height
    end

    love.graphics.push("all")
    love.graphics.setShader()
    love.graphics.setMeshCullMode("none")
    love.graphics.setDepthMode("always", false)

    local background_color = options.background_color or options.clear_color
    if type(background_color) == "table" then
        love.graphics.setColor(background_color)
        love.graphics.rectangle("fill", target_x, target_y, target_width, target_height)
    end

    love.graphics.setColor(1, 1, 1, 1)
    local blit_start = love.timer.getTime()
    -- post-fx rides the present blit, push("all") above scopes the shader, pop() clears it
    local fx = self:_damage_fx_active() and damage_shader() or nil
    if fx then
        fx:send("uAmount", self._damage_fx_amount or 0)
        fx:send("uSpike", self._damage_fx_spike or 0)
        fx:send("uSmog", self._damage_fx_smog or 0)
        fx:send("uTime", love.timer.getTime() % 3600)
        -- reused: this runs every frame the fx is up, which at low hp is every frame for the
        -- rest of the life -- no reason to hand the GC a fresh 2-element table each time
        local texel = self._damage_fx_texel
        if not texel then
            texel = { 0, 0 }
            self._damage_fx_texel = texel
        end
        texel[1] = 1 / render_canvas:getWidth()
        texel[2] = 1 / render_canvas:getHeight()
        fx:send("uTexel", texel)
        love.graphics.setShader(fx)
    end
    self:_draw_render_canvas_to_target(render_canvas, draw_x, draw_y, draw_width, draw_height)
    self._last_canvas_blit_ms = (love.timer.getTime() - blit_start) * 1000
    love.graphics.pop()

    surface.draw_x = draw_x
    surface.draw_y = draw_y
    surface.draw_width = draw_width
    surface.draw_height = draw_height
    surface.target_x = target_x
    surface.target_y = target_y
    surface.target_width = target_width
    surface.target_height = target_height
    surface.fit = fit
    surface.render_to_canvas = true
    surface.draw_to_rect = true
    surface.direct_render = false
    local active_width, active_height = RBX._get_active_surface_dimensions()
    local fullscreen_copy = math.abs(target_x) <= 0.5
        and math.abs(target_y) <= 0.5
        and math.abs(target_width - active_width) <= 0.5
        and math.abs(target_height - active_height) <= 0.5
    surface.fullscreen_canvas_copy = fullscreen_copy
    self._last_surface_path = "draw_to_rect"
    self._last_render_to_canvas_used = true
    self._last_draw_to_rect_used = true
    self._last_fullscreen_canvas_copy = fullscreen_copy

    return render_canvas, surface
end

function RBX:capture_frame(width, height, options)
    local render_canvas, surface = self:render_to_canvas(width, height, options)
    return render_canvas:newImageData(), surface
end
