-- Density, mass and body-local inertia, stateless, never touches CFrame

local Materials = {}
local Size = runtime_require("size_validation.lua")
local MaterialRegistry = runtime_require("material_registry.lua")

local PI = math.pi

local DEFAULT_DENSITY    = 0.7
local DEFAULT_FRICTION   = 0.3
local DEFAULT_ELASTICITY = 0.5
local MIN_SIZE = 0.001
local MIN_MASS = 0.001

-- {density,friction,elasticity,friction_weight,elasticity_weight} keyed by
-- Material enum, unknown -> Plastic. the source table deliberately follows
-- Creator Hub's documented order only after converting it to the solver's
-- order: Density, Friction, Elasticity, FrictionWeight, ElasticityWeight
--
-- keep this here rather than deriving it from visual-material settings: visual
-- asset fallbacks have no bearing on a part's physical behavior
--
-- only used when a part has no CustomPhysicalProperties or resolved material
-- variant physical properties
local MATERIAL_DEFAULTS = {
    [256]  = { 0.70, 0.30, 0.50, 1,   1 },   -- Plastic
    [272]  = { 0.70, 0.20, 0.50, 1,   1 },   -- SmoothPlastic
    [288]  = { 0.70, 0.30, 0.20, 1,   1 },   -- Neon
    [512]  = { 0.35, 0.48, 0.20, 1,   1 },   -- Wood
    [528]  = { 0.35, 0.48, 0.20, 1,   1 },   -- WoodPlanks
    [784]  = { 2.563, 0.20, 0.17, 1,  1 },   -- Marble
    [788]  = { 2.691, 0.70, 0.15, 0.3, 1 },  -- Basalt
    [800]  = { 2.691, 0.40, 0.20, 1,  1 },   -- Slate
    [804]  = { 2.691, 0.65, 0.15, 1,  1 },   -- CrackedLava
    [816]  = { 2.403, 0.70, 0.20, 0.3, 1 },  -- Concrete
    [820]  = { 2.691, 0.50, 0.15, 1,  1 },   -- Limestone
    [832]  = { 2.691, 0.40, 0.20, 1,  1 },   -- Granite
    [836]  = { 2.691, 0.50, 0.17, 0.3, 1 },  -- Pavement
    [848]  = { 1.922, 0.80, 0.15, 0.3, 1 },  -- Brick
    [864]  = { 2.403, 0.40, 0.17, 1,  1.5 }, -- Pebble
    [880]  = { 2.691, 0.50, 0.17, 1,  1 },   -- Cobblestone
    [896]  = { 2.691, 0.50, 0.17, 1,  1 },   -- Rock
    [912]  = { 2.691, 0.50, 0.15, 5,  1 },   -- Sandstone
    [1040] = { 7.85, 0.70, 0.20, 1,   1 },   -- CorrodedMetal
    [1056] = { 7.85, 0.35, 0.25, 1,   1 },   -- DiamondPlate
    [1072] = { 2.70, 0.40, 0.25, 1,   1 },   -- Foil
    [1088] = { 7.85, 0.40, 0.25, 1,   1 },   -- Metal
    [1280] = { 0.90, 0.40, 0.10, 1,   1.5 }, -- Grass
    [1284] = { 0.90, 0.40, 0.10, 2,   2 },   -- LeafyGrass
    [1296] = { 1.602, 0.50, 0.05, 5,  2.5 }, -- Sand
    [1312] = { 0.70, 0.35, 0.05, 1,   1 },   -- Fabric
    [1328] = { 0.90, 0.30, 0.03, 3,   4 },   -- Snow
    [1344] = { 0.90, 0.30, 0.07, 3,   4 },   -- Mud
    [1360] = { 0.90, 0.45, 0.10, 1,   1 },   -- Ground
    [1376] = { 2.36, 0.80, 0.20, 0.3, 1 },   -- Asphalt
    [1392] = { 2.165, 0.50, 0.05, 1,  1 },   -- Salt
    [1536] = { 0.919, 0.02, 0.15, 3,  1 },   -- Ice
    [1552] = { 0.919, 0.05, 0.15, 2,  1 },   -- Glacier
    [1568] = { 2.403, 0.25, 0.20, 1,  1 },   -- Glass
    [1584] = { 2.403, 0.25, 0.20, 1,  1 },   -- ForceField
    [2304] = { 0.70, 0.50, 0.05, 1,   2 },   -- Cardboard
    [2305] = { 1.10, 0.40, 0.25, 1,   2 },   -- Carpet
    [2306] = { 2.40, 0.51, 0.20, 1,   1 },   -- CeramicTiles
    [2307] = { 2.00, 0.51, 0.20, 1,   1 },   -- ClayRoofTiles
    [2308] = { 2.36, 0.80, 0.20, 0.3, 1 },   -- RoofShingles
    [2309] = { 0.86, 0.35, 0.25, 1,   1 },   -- Leather
    [2310] = { 0.75, 0.60, 0.20, 0.3, 1 },   -- Plaster
    [2311] = { 1.30, 1.50, 0.95, 3,   2 },   -- Rubber
}

local function material_defaults_of(part)
    local descriptor = part and MaterialRegistry.get(part.Material) or nil
    local token = descriptor and descriptor.canonical_token or nil
    return token and MATERIAL_DEFAULTS[token] or nil
end

local function physical_properties_of(part)
    local cpp = part and part.CustomPhysicalProperties or nil
    if type(cpp) ~= "table" and type(part and part._part) == "table" then
        cpp = part._part._material_variant_physical_properties
    elseif type(cpp) ~= "table" and type(part) == "table" then
        cpp = part._material_variant_physical_properties
    end
    return type(cpp) == "table" and cpp or nil
end

-- Roblox's PhysicalProperties constructor clamps these public values.  keep
-- the consumption path in the same bounds so decoded values and direct table
-- assignments cannot create a solver-only behavior that differs from the API
-- Density's lower bound is 0.0001 (not the retired 0.01 limit)
local function clamp_range(v, lo, hi)
    if v ~= v then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function clamp_size(value)
    value = math.abs(tonumber(value) or 1)
    if value < MIN_SIZE then
        return MIN_SIZE
    end
    return value
end

local function size_components(part)
    local sx, sy, sz = Size.part(part)
    return clamp_size(sx), clamp_size(sy), clamp_size(sz)
end

-- precedence: CustomPhysicalProperties > material default > plastic
function Materials.density_of(part)
    local cpp = physical_properties_of(part)
    if type(cpp) == "table" then
        local density = tonumber(cpp.density or cpp.Density)
        if density then
            return clamp_range(density, 0.0001, 100)
        end
    end
    local md = material_defaults_of(part)
    if md then return md[1] end
    return DEFAULT_DENSITY
end

function Materials.friction_of(part)
    local cpp = physical_properties_of(part)
    if type(cpp) == "table" then
        local v = tonumber(cpp.friction or cpp.Friction)
        if v then return clamp_range(v, 0, 2) end
    end
    local md = material_defaults_of(part)
    if md then return md[2] end
    return DEFAULT_FRICTION
end

-- aka restitution
function Materials.elasticity_of(part)
    local cpp = physical_properties_of(part)
    if type(cpp) == "table" then
        local v = tonumber(cpp.elasticity or cpp.Elasticity)
        if v then return clamp_range(v, 0, 1) end
    end
    local md = material_defaults_of(part)
    if md then return md[3] end
    return DEFAULT_ELASTICITY
end

-- weight for combining friction across 2 surfaces
function Materials.friction_weight_of(part)
    local cpp = physical_properties_of(part)
    if type(cpp) == "table" then
        local v = tonumber(cpp.friction_weight or cpp.FrictionWeight)
        if v then return clamp_range(v, 0, 100) end
    end
    local md = material_defaults_of(part)
    if md then return md[4] end
    return 1.0
end

-- weight for combining elasticity across 2 surfaces
function Materials.elasticity_weight_of(part)
    local cpp = physical_properties_of(part)
    if type(cpp) == "table" then
        local v = tonumber(cpp.elasticity_weight or cpp.ElasticityWeight)
        if v then return clamp_range(v, 0, 100) end
    end
    local md = material_defaults_of(part)
    if md then return md[5] end
    return 1.0
end

---returns a fresh, script-facing property table for a base material
---
---`PhysicalProperties.new(Enum.Material.X)` must not hand callers the shared
---default tuple: script-visible values are independently owned, just like a
---normal PhysicalProperties value
function Materials.default_properties_for_material(material)
    local descriptor = MaterialRegistry.get(material)
    local token = descriptor and descriptor.canonical_token or 256
    local defaults = MATERIAL_DEFAULTS[token] or MATERIAL_DEFAULTS[256]
    return {
        density = defaults[1],
        friction = defaults[2],
        elasticity = defaults[3],
        friction_weight = defaults[4],
        elasticity_weight = defaults[5],
    }
end

---the effective values used by a physics view, in native priority order
---
---this is also the public CurrentPhysicalProperties view: per-part custom
---values win, followed by a resolved MaterialVariant/MaterialService override,
---then the base material table above
function Materials.effective_properties_of(part)
    local cpp = physical_properties_of(part)
    local acoustic = type(cpp) == "table"
        and tonumber(cpp.acoustic_absorption or cpp.AcousticAbsorption) or nil
    return {
        density = Materials.density_of(part),
        friction = Materials.friction_of(part),
        elasticity = Materials.elasticity_of(part),
        friction_weight = Materials.friction_weight_of(part),
        elasticity_weight = Materials.elasticity_weight_of(part),
        acoustic_absorption = acoustic ~= nil and clamp_range(acoustic, 0, 1) or nil,
    }
end

function Materials.volume_of(part)
    local sx, sy, sz = size_components(part)
    local shape = type(part) == "table" and part.Shape or nil

    if shape == "Ball" then
        local r = math.min(sx, sy, sz) * 0.5
        return (4 / 3) * PI * r * r * r
    elseif shape == "Cylinder" then
        -- Roblox Part cylinders run along local X. their Y/Z cross-section is
        -- circular and uses the lower radial Size component, matching the render
        -- basis and ray query rather than the Y-aligned legacy CylinderMesh
        local r = math.min(sy, sz) * 0.5
        return PI * r * r * sx
    end

    -- block / wedge / cornerwedge / truss / mesh / nil -> box
    return sx * sy * sz
end

-- NOT massless-aware, see assembly_mass_of
function Materials.mass_of(part)
    local mass = Size.result(Materials.volume_of(part) * Materials.density_of(part), part, "mass")
    if mass < MIN_MASS then
        return MIN_MASS
    end
    return mass
end

function Materials.assembly_mass_of(part, is_root)
    -- Root ownership is supplied by Assembly, not inferred from hierarchy/ropes
    if not part or (part.Massless == true and not is_root) then
        return 0
    end
    local mass = tonumber(part.Mass) or Materials.mass_of(part)
    if mass < MIN_MASS then
        return MIN_MASS
    end
    return mass
end

-- solid-box moments, per axis
function Materials.box_inertia(part, mass)
    mass = tonumber(mass) or Materials.assembly_mass_of(part)
    local sx, sy, sz = size_components(part)
    return Size.result(math.max(MIN_MASS, mass * (sy * sy + sz * sz) / 12), part, "inertia X"),
        Size.result(math.max(MIN_MASS, mass * (sx * sx + sz * sz) / 12), part, "inertia Y"),
        Size.result(math.max(MIN_MASS, mass * (sx * sx + sy * sy) / 12), part, "inertia Z")
end

-- a standalone solid uses the same physical dimensions as volume_of and the
-- collision descriptor. Visual mesh children do not own these mass properties
-- Multi-part aggregation still uses its existing root-box approximation
function Materials.part_inertia(part, mass)
    local shape = part and part.Shape
    if shape ~= "Ball" and shape ~= "Cylinder" then
        return Materials.box_inertia(part, mass)
    end
    mass = tonumber(mass) or Materials.mass_of(part)
    local sx, sy, sz = size_components(part)
    local ix, iy, iz
    if shape == "Ball" then
        local r = math.min(sx, sy, sz) * 0.5
        ix = (2 / 5) * mass * r * r
        iy, iz = ix, ix
    else
        local r = math.min(sy, sz) * 0.5
        ix = 0.5 * mass * r * r
        iy = mass * (3 * r * r + sx * sx) / 12
        iz = iy
    end
    -- keep the existing solver minimum and finite-result admission policy
    return Size.result(math.max(MIN_MASS, ix), part, "inertia X"),
        Size.result(math.max(MIN_MASS, iy), part, "inertia Y"),
        Size.result(math.max(MIN_MASS, iz), part, "inertia Z")
end

return Materials
