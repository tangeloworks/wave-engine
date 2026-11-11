-- Authoritative Roblox material-token registry and renderer fallback policy
--
-- the numeric ids and names below follow Enum.Material.  Rendering policy is
-- deliberately kept out of assets.lua: callers can distinguish a native local
-- texture family, a deliberate scalar/flat material, a nearest-family fallback,
-- and a known effect that the renderer has not implemented yet.  in particular,
-- resolve() never turns a recognized material into a silent nil

local Registry = {}

Registry.FLAT_ASSET_FAMILY = "Flat"

-- these are the material folders actually shipped under assets/rbx/materials
-- keep this list independent of love.filesystem so the registry can load in workers
local NATIVE_ASSET_FAMILIES = {
    Brick = true,
    Cobblestone = true,
    Concrete = true,
    CorrodedMetal = true,
    DiamondPlate = true,
    Fabric = true,
    Foil = true,
    Glass = true,
    Granite = true,
    Grass = true,
    Ice = true,
    Marble = true,
    Metal = true,
    Pebble = true,
    Sand = true,
    Slate = true,
    Wood = true,
    WoodPlanks = true,
}

-- { token, name, domain, fallback family, roughness, metalness, emissive,
--   translucency, semantic [, visual support] }
--
-- `translucent` is a renderer-policy scalar: 0 is opaque and 1 contributes no
-- opaque surface.  it does not replace BasePart.Transparency.  `emissive` is a
-- linear-HDR multiplier, so Neon intentionally exceeds 1
local OFFICIAL_SPECS = {
    { 256,  "Plastic",         "part",             "Flat",          0.55, 0.00, 0.00, 0.00, "standard" },
    { 272,  "SmoothPlastic",   "part",             "Flat",          0.24, 0.00, 0.00, 0.00, "standard" },
    { 288,  "Neon",            "part",             "Flat",          0.22, 0.00, 2.40, 0.00, "emissive" },
    { 512,  "Wood",            "part",             "Wood",          0.70, 0.00, 0.00, 0.00, "standard" },
    { 528,  "WoodPlanks",      "part_and_terrain", "WoodPlanks",    0.68, 0.00, 0.00, 0.00, "standard" },
    { 784,  "Marble",          "part",             "Marble",        0.32, 0.00, 0.00, 0.00, "standard" },
    { 788,  "Basalt",          "part_and_terrain", "Slate",         0.86, 0.00, 0.00, 0.00, "standard" },
    { 800,  "Slate",           "part_and_terrain", "Slate",         0.76, 0.00, 0.00, 0.00, "standard" },
    { 804,  "CrackedLava",     "part_and_terrain", "Granite",       0.64, 0.00, 0.35, 0.00, "warm_emissive" },
    { 816,  "Concrete",        "part_and_terrain", "Concrete",      0.82, 0.00, 0.00, 0.00, "standard" },
    { 820,  "Limestone",       "part_and_terrain", "Marble",        0.72, 0.00, 0.00, 0.00, "standard" },
    { 832,  "Granite",         "part",             "Granite",       0.62, 0.00, 0.00, 0.00, "standard" },
    { 836,  "Pavement",        "part_and_terrain", "Concrete",      0.88, 0.00, 0.00, 0.00, "standard" },
    { 848,  "Brick",           "part_and_terrain", "Brick",         0.78, 0.00, 0.00, 0.00, "standard" },
    { 864,  "Pebble",          "part",             "Pebble",        0.82, 0.00, 0.00, 0.00, "standard" },
    { 880,  "Cobblestone",     "part_and_terrain", "Cobblestone",   0.84, 0.00, 0.00, 0.00, "standard" },
    { 896,  "Rock",            "part_and_terrain", "Slate",         0.80, 0.00, 0.00, 0.00, "standard" },
    { 912,  "Sandstone",       "part_and_terrain", "Sand",          0.87, 0.00, 0.00, 0.00, "standard" },
    { 1040, "CorrodedMetal",   "part",             "CorrodedMetal", 0.72, 0.55, 0.00, 0.00, "standard" },
    { 1056, "DiamondPlate",    "part",             "DiamondPlate",  0.28, 0.90, 0.00, 0.00, "standard" },
    { 1072, "Foil",            "part",             "Foil",          0.16, 1.00, 0.00, 0.00, "standard" },
    { 1088, "Metal",           "part",             "Metal",         0.30, 0.95, 0.00, 0.00, "standard" },
    { 1280, "Grass",           "part_and_terrain", "Grass",         0.95, 0.00, 0.00, 0.00, "standard" },
    { 1284, "LeafyGrass",      "part_and_terrain", "Grass",         0.94, 0.00, 0.00, 0.00, "standard" },
    { 1296, "Sand",            "part_and_terrain", "Sand",          0.98, 0.00, 0.00, 0.00, "standard" },
    { 1312, "Fabric",          "part",             "Fabric",        1.00, 0.00, 0.00, 0.00, "standard" },
    { 1328, "Snow",            "part_and_terrain", "Ice",           0.92, 0.00, 0.00, 0.00, "standard" },
    { 1344, "Mud",             "part_and_terrain", "Sand",          0.98, 0.00, 0.00, 0.00, "standard" },
    { 1360, "Ground",          "part_and_terrain", "Sand",          0.96, 0.00, 0.00, 0.00, "standard" },
    { 1376, "Asphalt",         "part_and_terrain", "Slate",         0.96, 0.00, 0.00, 0.00, "standard" },
    { 1392, "Salt",            "part_and_terrain", "Marble",        0.68, 0.00, 0.00, 0.00, "standard" },
    -- Ice/Glacier remain opaque at BasePart.Transparency=0. their visual
    -- transmission is a lighting/refraction effect, not alpha blending
    { 1536, "Ice",             "part_and_terrain", "Ice",           0.12, 0.00, 0.00, 0.00, "ice" },
    { 1552, "Glacier",         "part_and_terrain", "Ice",           0.22, 0.00, 0.00, 0.00, "ice" },
    -- `translucent` is the minimum material transparency. Glass therefore caps
    -- opacity at 0.54, preserving the renderer's established native contract
    { 1568, "Glass",           "part",             "Glass",         0.08, 0.00, 0.00, 0.46, "glass" },
    { 1584, "ForceField",      "part",             "Glass",         0.18, 0.00, 0.70, 0.58, "force_field", "unsupported_animated" },
    { 1792, "Air",             "terrain",          "Flat",          1.00, 0.00, 0.00, 1.00, "terrain_air", "terrain_only" },
    { 2048, "Water",           "terrain",          "Ice",           0.08, 0.00, 0.00, 0.58, "terrain_water", "terrain_only" },
    { 2304, "Cardboard",       "part",             "Wood",          0.88, 0.00, 0.00, 0.00, "standard" },
    { 2305, "Carpet",          "part",             "Fabric",        1.00, 0.00, 0.00, 0.00, "standard" },
    { 2306, "CeramicTiles",    "part",             "Marble",        0.20, 0.00, 0.00, 0.00, "standard" },
    { 2307, "ClayRoofTiles",   "part",             "Brick",         0.68, 0.00, 0.00, 0.00, "standard" },
    { 2308, "RoofShingles",    "part",             "Slate",         0.90, 0.00, 0.00, 0.00, "standard" },
    { 2309, "Leather",         "part",             "Fabric",        0.58, 0.00, 0.00, 0.00, "standard" },
    { 2310, "Plaster",         "part",             "Concrete",      0.82, 0.00, 0.00, 0.00, "standard" },
    { 2311, "Rubber",          "part",             "Flat",          0.72, 0.00, 0.00, 0.00, "standard" },
}

local function normalized_name(value)
    if type(value) ~= "string" then return nil end
    return value:lower():gsub("[^%w]", "")
end

local by_token = {}
local by_name = {}
local official_tokens = {}

local function make_descriptor(spec)
    local token, name, domain, fallback = spec[1], spec[2], spec[3], spec[4]
    local native = NATIVE_ASSET_FAMILIES[name] and name or nil
    local visual_support = spec[10]
    if visual_support == nil then
        if native ~= nil then
            visual_support = "native_asset"
        elseif fallback == Registry.FLAT_ASSET_FAMILY then
            visual_support = "scalar"
        else
            visual_support = "fallback_asset"
        end
    end

    local diagnostic_code
    if visual_support == "fallback_asset" then
        diagnostic_code = "material_asset_family_fallback"
    elseif visual_support == "unsupported_animated" then
        diagnostic_code = "forcefield_animated_material_unsupported"
    elseif visual_support == "terrain_only" then
        diagnostic_code = "terrain_only_material"
    end

    return {
        token = token,
        canonical_token = token,
        name = name,
        key = normalized_name(name),
        domain = domain,
        part_eligible = domain == "part" or domain == "part_and_terrain",
        terrain_eligible = domain == "terrain" or domain == "part_and_terrain",
        native_asset_family = native,
        fallback_asset_family = fallback,
        uses_fallback_asset = native == nil and fallback ~= Registry.FLAT_ASSET_FAMILY,
        roughness = spec[5],
        metalness = spec[6],
        emissive = spec[7],
        translucent = spec[8],
        semantic = spec[9],
        animated = spec[9] == "force_field",
        visual_support = visual_support,
        supported = visual_support ~= "unsupported_animated",
        diagnostic_code = diagnostic_code,
        official = true,
        compatibility_alias = false,
    }
end

for index = 1, #OFFICIAL_SPECS do
    local descriptor = make_descriptor(OFFICIAL_SPECS[index])
    by_token[descriptor.token] = descriptor
    by_name[descriptor.key] = descriptor
    official_tokens[index] = descriptor.token
end

-- Compatibility for token values already emitted/consumed by older revisions of
-- this runtime.  the canonical ids are 804, 820, and 836, keeping the old ids
-- observable avoids turning existing cached/runtime records into unknown plastic
local COMPATIBILITY_ALIASES = {
    [0] = 256,
    [792] = 804,
    [1408] = 820,
    [1424] = 836,
}

local compatibility_tokens = {}
for alias_token, canonical_token in pairs(COMPATIBILITY_ALIASES) do
    local canonical = assert(by_token[canonical_token])
    local alias = {}
    for key, value in pairs(canonical) do alias[key] = value end
    alias.token = alias_token
    alias.canonical_token = canonical_token
    alias.official = false
    alias.compatibility_alias = true
    alias.visual_support = "compatibility_alias"
    alias.diagnostic_code = alias_token == 0
        and "legacy_default_material_token"
        or "legacy_material_token_alias"
    by_token[alias_token] = alias
    compatibility_tokens[#compatibility_tokens + 1] = alias_token
end
table.sort(compatibility_tokens)

-- Legacy names accepted by Roblox/API history and common authored tooling
by_name.corrodedmetal = by_token[1040]
by_name.aluminum = by_token[1072]

local UNKNOWN = {
    token = 256,
    canonical_token = 256,
    name = "Unknown",
    key = "unknown",
    domain = "part",
    part_eligible = true,
    terrain_eligible = false,
    native_asset_family = nil,
    fallback_asset_family = Registry.FLAT_ASSET_FAMILY,
    uses_fallback_asset = false,
    roughness = 0.55,
    metalness = 0.00,
    emissive = 0.00,
    translucent = 0.00,
    semantic = "unknown",
    animated = false,
    visual_support = "unknown_fallback",
    supported = false,
    diagnostic_code = "unknown_material_token",
    official = false,
    compatibility_alias = false,
}

local function unwrap_material(value)
    local current = value
    for _ = 1, 4 do
        if type(current) ~= "table" then break end
        if current.Value ~= nil then
            current = current.Value
        elseif current.value ~= nil then
            current = current.value
        else
            break
        end
    end
    return current
end

---Normalizes numeric, numeric-string, EnumItem-like, and DOM value inputs
---@return number|nil
function Registry.normalize_token(value)
    value = unwrap_material(value)
    if type(value) == "string" then
        local named = by_name[normalized_name(value)]
        if named then return named.token end
    end
    local token = tonumber(value)
    if token == nil or token ~= token or token == math.huge or token == -math.huge then
        return nil
    end
    token = math.floor(token + 0.5)
    return token
end

---returns a descriptor only when the material token/name is recognized
function Registry.get(value)
    local token = Registry.normalize_token(value)
    return token ~= nil and by_token[token] or nil
end

---always returns a descriptor.  the second result reports whether the authored
---token was recognized, the third is the normalized requested token for logging
function Registry.resolve(value)
    local token = Registry.normalize_token(value)
    local descriptor = token ~= nil and by_token[token] or nil
    if descriptor ~= nil then
        return descriptor, true, token
    end
    return UNKNOWN, false, token
end

function Registry.get_by_name(name)
    return by_name[normalized_name(name)]
end

function Registry.official_tokens()
    local copy = {}
    for index = 1, #official_tokens do copy[index] = official_tokens[index] end
    return copy
end

function Registry.compatibility_tokens()
    local copy = {}
    for index = 1, #compatibility_tokens do copy[index] = compatibility_tokens[index] end
    return copy
end

function Registry.is_native_asset_family(name)
    return NATIVE_ASSET_FAMILIES[name] == true
end

function Registry.unknown_descriptor()
    return UNKNOWN
end

Registry.OFFICIAL_COUNT = #official_tokens

return Registry
