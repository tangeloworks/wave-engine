-- bounded Atmosphere transport and shader contract
--
-- Roblox does not publish its renderer implementation, but it does document
-- the observable role of every Atmosphere property.  this module turns that
-- public contract into a deterministic Beer-Lambert approximation shared by
-- the CPU oracles and every RBX material/sky shader.  it deliberately owns no
-- LOVE resources and retains no parsed Instance graph

local Atmosphere = {}

Atmosphere.DEFAULT_DISTANCE_SCALE = 4096
Atmosphere.SEMANTICS_VERSION = 1
Atmosphere.DEFAULTS = type(RBX) == "table" and RBX._ATMOSPHERE_DEFAULTS or {
    Density = 0.395000011,
    Offset = 0,
    Color = { 0.7843, 0.6667, 0.4235 },
    Decay = { 0.3608, 0.2353, 0.0549 },
    Haze = 0,
    Glare = 0,
}

local function finite(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value
        or value == math.huge or value == -math.huge then
        return fallback
    end
    return value
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function property(source, lower, upper)
    if type(source) ~= "table" then return nil end
    local value = source[lower]
    if value == nil then value = source[upper] end
    return value
end

local function color3(value, fallback)
    value = type(value) == "table" and value or fallback
    fallback = fallback or { 1, 1, 1 }
    return {
        clamp(finite(value[1] or value.r or value.R, fallback[1]), 0, 1),
        clamp(finite(value[2] or value.g or value.G, fallback[2]), 0, 1),
        clamp(finite(value[3] or value.b or value.B, fallback[3]), 0, 1),
    }
end

local function vector3(value, fallback_x, fallback_y, fallback_z)
    value = type(value) == "table" and value or {}
    return finite(value[1] or value.x or value.X, fallback_x or 0),
        finite(value[2] or value.y or value.Y, fallback_y or 0),
        finite(value[3] or value.z or value.Z, fallback_z or 0)
end

local function normalized(x, y, z, fallback_x, fallback_y, fallback_z)
    -- Scale before squaring so hostile-but-finite coordinates cannot overflow
    -- Lua's double range. the 1e-10 squared-length cutoff is mirrored exactly
    -- by FRAME_GLSL, tiny rays use the same deterministic fallback on CPU/GPU
    local largest = math.max(math.abs(x), math.abs(y), math.abs(z))
    if largest == 0 or largest ~= largest then
        return fallback_x or 0, fallback_y or 0, fallback_z or 1, 0
    end
    local scaled_x, scaled_y, scaled_z = x / largest, y / largest, z / largest
    local scaled_length_squared = scaled_x * scaled_x
        + scaled_y * scaled_y + scaled_z * scaled_z
    if largest <= 1e-5
        and largest * largest * scaled_length_squared <= 1e-10 then
        return fallback_x or 0, fallback_y or 0, fallback_z or 1, 0
    end
    local scaled_length = math.sqrt(scaled_length_squared)
    return scaled_x / scaled_length, scaled_y / scaled_length,
        scaled_z / scaled_length, largest * scaled_length
end

local function mix(a, b, t)
    return a + (b - a) * t
end

local function resolved_descriptor(source)
    if type(source) == "table"
        and source._rbx_atmosphere_semantics_version
            == Atmosphere.SEMANTICS_VERSION then
        return source
    end
    return Atmosphere.normalize(source)
end

---normalize parsed/raw Atmosphere state into a small value-owned descriptor
function Atmosphere.normalize(source, options)
    options = options or {}
    local explicit_present = property(source, "present", "Present")
    if explicit_present == nil then
        explicit_present = property(source, "enabled", "Enabled")
    end
    local present = type(source) == "table" and explicit_present ~= false
    local distance_scale = finite(
        options.distance_scale
            or property(source, "distance_scale", "DistanceScale"),
        Atmosphere.DEFAULT_DISTANCE_SCALE)
    distance_scale = clamp(distance_scale, 32, 1000000)

    return {
        _rbx_atmosphere_semantics_version = Atmosphere.SEMANTICS_VERSION,
        enabled = present,
        density = clamp(finite(property(source, "density", "Density"),
            Atmosphere.DEFAULTS.Density), 0, 1),
        offset = clamp(finite(property(source, "offset", "Offset"),
            Atmosphere.DEFAULTS.Offset), -1, 1),
        color = color3(property(source, "color", "Color"),
            Atmosphere.DEFAULTS.Color),
        decay = color3(property(source, "decay", "Decay"),
            Atmosphere.DEFAULTS.Decay),
        haze = clamp(finite(property(source, "haze", "Haze"),
            Atmosphere.DEFAULTS.Haze), 0, 10),
        glare = clamp(finite(property(source, "glare", "Glare"),
            Atmosphere.DEFAULTS.Glare), 0, 10),
        distance_scale = distance_scale,
        inverse_distance_scale = 1 / distance_scale,
    }
end

---three vec4 values, sent as one uniform array update per shader switch
function Atmosphere.pack(source, options)
    local descriptor = resolved_descriptor(source)
    if options and options.distance_scale then
        descriptor = Atmosphere.normalize(descriptor, options)
    end
    -- CPU evaluation stays explicitly in the descriptor's input color space
    -- production renderers may supply their authored->GPU converter here so
    -- the packed shader values are linear exactly once, without duplicating
    -- Atmosphere normalization or mutating the parsed descriptor
    if options and type(options.color_transform) == "function" then
        local color_r, color_g, color_b = options.color_transform(
            descriptor.color[1], descriptor.color[2], descriptor.color[3])
        local decay_r, decay_g, decay_b = options.color_transform(
            descriptor.decay[1], descriptor.decay[2], descriptor.decay[3])
        descriptor = {
            _rbx_atmosphere_semantics_version = Atmosphere.SEMANTICS_VERSION,
            enabled = descriptor.enabled,
            density = descriptor.density,
            offset = descriptor.offset,
            color = { color_r, color_g, color_b },
            decay = { decay_r, decay_g, decay_b },
            haze = descriptor.haze,
            glare = descriptor.glare,
            distance_scale = descriptor.distance_scale,
            inverse_distance_scale = descriptor.inverse_distance_scale,
        }
    end
    return {
        {
            descriptor.color[1], descriptor.color[2], descriptor.color[3],
            descriptor.density,
        },
        {
            descriptor.decay[1], descriptor.decay[2], descriptor.decay[3],
            descriptor.offset,
        },
        {
            descriptor.haze, descriptor.glare,
            descriptor.inverse_distance_scale,
            descriptor.enabled and 1 or 0,
        },
    }
end

local function scattering_terms(descriptor, view_x, view_y, view_z,
        sun_x, sun_y, sun_z)
    local sun_alignment = clamp(
        view_x * sun_x + view_y * sun_y + view_z * sun_z, 0, 1)
    local haze = clamp(descriptor.haze * 0.1, 0, 1)
    local glare = clamp(descriptor.glare * 0.1, 0, 1)
    local coupled = haze * glare
    -- Decay is the away-from-sun hue.  its documented visibility depends on
    -- both Haze and Glare, so a zero in either property leaves Color intact
    local decay_mix = coupled * (1 - sun_alignment)
    local scatter_r = mix(descriptor.color[1], descriptor.decay[1], decay_mix)
    local scatter_g = mix(descriptor.color[2], descriptor.decay[2], decay_mix)
    local scatter_b = mix(descriptor.color[3], descriptor.decay[3], decay_mix)
    -- a narrow lobe at low haze broadens as haze rises.  this is fixed-cost
    -- analytic work, Glare cannot become visible without Haze
    local glare_exponent = mix(96, 8, haze)
    local glare_lobe = (sun_alignment ^ glare_exponent) * coupled
    return scatter_r, scatter_g, scatter_b, glare_lobe, haze
end

---Evaluate atmosphere over an already-lit linear-HDR world sample
---returns r,g,b, transmittance, optical_depth
function Atmosphere.evaluate_world(rgb, world_position, camera_position,
        sun_direction, source)
    local descriptor = resolved_descriptor(source)
    local in_r, in_g, in_b = vector3(rgb, 0, 0, 0)
    if not descriptor.enabled then
        return in_r, in_g, in_b, 1, 0
    end
    in_r, in_g, in_b = math.max(in_r, 0), math.max(in_g, 0),
        math.max(in_b, 0)

    local world_x, world_y, world_z = vector3(world_position, 0, 0, 0)
    local camera_x, camera_y, camera_z = vector3(camera_position, 0, 0, 0)
    local view_x, view_y, view_z, distance = normalized(
        world_x - camera_x, world_y - camera_y, world_z - camera_z,
        0, 0, 1)
    local raw_sun_x, raw_sun_y, raw_sun_z =
        vector3(sun_direction, 0, 1, 0)
    local sun_x, sun_y, sun_z = normalized(
        raw_sun_x, raw_sun_y, raw_sun_z, 0, 1, 0)
    local horizon = clamp(1 - math.abs(view_y), 0, 1)
    local density_load = descriptor.density * 3.5
    local haze_load = descriptor.haze * 0.04
        * (0.35 + horizon * 0.65)
    local particle_load = density_load + haze_load
    -- Offset shifts an existing particle field, it cannot manufacture fog
    -- when both Density and Haze are zero
    local offset_load = math.min(particle_load, 1)
    local optical_depth = math.min(80, math.max(0,
        distance * descriptor.inverse_distance_scale
            * particle_load
            - descriptor.offset * 0.45 * offset_load))
    local transmittance = math.exp(-optical_depth)
    local fog = 1 - transmittance
    local scatter_r, scatter_g, scatter_b, glare_lobe = scattering_terms(
        descriptor, view_x, view_y, view_z, sun_x, sun_y, sun_z)
    local glare_energy = glare_lobe * fog * 0.5
    return in_r * transmittance + scatter_r * fog
            + descriptor.color[1] * glare_energy,
        in_g * transmittance + scatter_g * fog
            + descriptor.color[2] * glare_energy,
        in_b * transmittance + scatter_b * fog
            + descriptor.color[3] * glare_energy,
        transmittance,
        optical_depth
end

---Evaluate Atmosphere against a linear-HDR skybox sample
function Atmosphere.evaluate_sky(rgb, view_direction, sun_direction, source)
    local descriptor = resolved_descriptor(source)
    local in_r, in_g, in_b = vector3(rgb, 0, 0, 0)
    if not descriptor.enabled then return in_r, in_g, in_b end
    in_r, in_g, in_b = math.max(in_r, 0), math.max(in_g, 0),
        math.max(in_b, 0)
    local raw_view_x, raw_view_y, raw_view_z =
        vector3(view_direction, 0, 0, 1)
    local raw_sun_x, raw_sun_y, raw_sun_z =
        vector3(sun_direction, 0, 1, 0)
    local view_x, view_y, view_z = normalized(
        raw_view_x, raw_view_y, raw_view_z, 0, 0, 1)
    local sun_x, sun_y, sun_z = normalized(
        raw_sun_x, raw_sun_y, raw_sun_z, 0, 1, 0)
    local scatter_r, scatter_g, scatter_b, glare_lobe, haze =
        scattering_terms(descriptor,
            view_x, view_y, view_z, sun_x, sun_y, sun_z)
    local horizon = clamp(1 - math.abs(view_y), 0, 1)
    -- Density affects objects/terrain directly. Haze owns the sky tint, the
    -- skybox only becomes less visible from Density indirectly through world
    -- geometry in front of it
    local sky_load = descriptor.haze * 0.075
    local coverage = clamp(sky_load
            * ((0.35 + horizon * 0.65)
                - descriptor.offset * 0.18),
        0, 1)
    local glare_energy = glare_lobe * mix(1.4, 3.0, haze)
    return mix(in_r, scatter_r, coverage)
            + descriptor.color[1] * glare_energy,
        mix(in_g, scatter_g, coverage)
            + descriptor.color[2] * glare_energy,
        mix(in_b, scatter_b, coverage)
            + descriptor.color[3] * glare_energy
end

-- shader equivalent of the CPU contract.  Functions take camera/sun inputs
-- explicitly so the block can be shared by material, terrain and sky shaders
-- without depending on their uniform naming conventions
Atmosphere.FRAME_GLSL = [[
uniform vec4 uAtmosphere[3];

vec3 rbxAtmosphereSafeDirection(vec3 value, vec3 fallbackDirection)
{
    float largest = max(max(abs(value.x), abs(value.y)), abs(value.z));
    if (!(largest > 0.0)) {
        return fallbackDirection;
    }
    vec3 scaled = value / largest;
    float scaledMagnitudeSquared = dot(scaled, scaled);
    if (largest <= 0.00001
        && largest * largest * scaledMagnitudeSquared <= 0.0000000001) {
        return fallbackDirection;
    }
    return scaled * inversesqrt(scaledMagnitudeSquared);
}

float rbxAtmosphereSafeLength(vec3 value)
{
    float largest = max(max(abs(value.x), abs(value.y)), abs(value.z));
    if (!(largest > 0.0)) {
        return 0.0;
    }
    return largest * length(value / largest);
}

vec4 rbxAtmosphereScatter(vec3 viewDirection, vec3 sunDirection)
{
    float sunAlignment = clamp(dot(viewDirection, sunDirection), 0.0, 1.0);
    float haze = clamp(uAtmosphere[2].x * 0.1, 0.0, 1.0);
    float glare = clamp(uAtmosphere[2].y * 0.1, 0.0, 1.0);
    float coupled = haze * glare;
    if (coupled <= 0.000001) {
        return vec4(uAtmosphere[0].rgb, 0.0);
    }
    float decayMix = coupled * (1.0 - sunAlignment);
    vec3 scatterColor = mix(
        uAtmosphere[0].rgb, uAtmosphere[1].rgb, decayMix);
    float glareExponent = mix(96.0, 8.0, haze);
    float glareLobe = pow(sunAlignment, glareExponent) * coupled;
    return vec4(scatterColor, glareLobe);
}

vec3 rbxApplyAtmosphere(vec3 rgb, vec3 worldPosition,
    vec3 cameraPosition, vec3 sunDirection)
{
    if (uAtmosphere[2].w < 0.5) {
        return rgb;
    }
    vec3 ray = worldPosition - cameraPosition;
    float distanceToSample = rbxAtmosphereSafeLength(ray);
    vec3 viewDirection = rbxAtmosphereSafeDirection(ray, vec3(0.0, 0.0, 1.0));
    vec3 safeSun = rbxAtmosphereSafeDirection(sunDirection, vec3(0.0, 1.0, 0.0));
    float horizon = clamp(1.0 - abs(viewDirection.y), 0.0, 1.0);
    float densityLoad = uAtmosphere[0].w * 3.5;
    float hazeLoad = uAtmosphere[2].x * 0.04
        * (0.35 + horizon * 0.65);
    float particleLoad = densityLoad + hazeLoad;
    float offsetLoad = min(particleLoad, 1.0);
    float opticalDepth = clamp(
        distanceToSample * uAtmosphere[2].z
            * particleLoad
            - uAtmosphere[1].w * 0.45 * offsetLoad,
        0.0, 80.0);
    float transmittance = exp(-opticalDepth);
    float fog = 1.0 - transmittance;
    vec4 scatter = rbxAtmosphereScatter(viewDirection, safeSun);
    float glareEnergy = scatter.a * fog * 0.5;
    return max(rgb, vec3(0.0)) * transmittance
        + scatter.rgb * fog
        + uAtmosphere[0].rgb * glareEnergy;
}

vec3 rbxApplyAtmosphereSky(vec3 rgb, vec3 viewDirection,
    vec3 sunDirection)
{
    if (uAtmosphere[2].w < 0.5) {
        return rgb;
    }
    vec3 safeView = rbxAtmosphereSafeDirection(
        viewDirection, vec3(0.0, 0.0, 1.0));
    vec3 safeSun = rbxAtmosphereSafeDirection(
        sunDirection, vec3(0.0, 1.0, 0.0));
    vec4 scatter = rbxAtmosphereScatter(safeView, safeSun);
    float horizon = clamp(1.0 - abs(safeView.y), 0.0, 1.0);
    float skyLoad = uAtmosphere[2].x * 0.075;
    float coverage = clamp(skyLoad
            * ((0.35 + horizon * 0.65)
                - uAtmosphere[1].w * 0.18),
        0.0, 1.0);
    float haze = clamp(uAtmosphere[2].x * 0.1, 0.0, 1.0);
    float glareEnergy = scatter.a * mix(1.4, 3.0, haze);
    return mix(max(rgb, vec3(0.0)), scatter.rgb, coverage)
        + uAtmosphere[0].rgb * glareEnergy;
}
]]

return Atmosphere
