local runtime_coords = runtime_require("coords.lua")
local authored_color3_to_gpu = runtime_coords.color3_to_gpu
local SurfaceAppearance = runtime_require("surface_appearance.lua")
local MaterialRegistry = runtime_require("material_registry.lua")
RBX._material_variants = RBX._material_variants
    or runtime_require("material_variants.lua")

Vector3 = {}
Vector3.__name = "Vector3"

-- shared read-only default for parts without SurfaceGuis (never mutate)
EMPTY_SURFACE_GUIS = {}

-- SurfaceAppearance is a MeshPart-only visual contract.  parsed UnionOperation
-- descriptors are intentionally retained for round-tripping, but rendering
-- them here would be a non-native extension without a MeshPart UV contract
function RBX._get_native_mesh_surface_appearance(part)
    if type(part) ~= "table"
        or part.ClassName ~= "MeshPart"
        or type(part.SurfaceAppearance) ~= "table" then
        return nil
    end
    if type(RBX._part_has_renderable_mesh_source) == "function"
        and not RBX._part_has_renderable_mesh_source(part) then
        return nil
    end
    return SurfaceAppearance.normalize_descriptor(part.SurfaceAppearance)
end

function RBX._classify_part_surface_appearance_route(part, renderer)
    local descriptor = RBX._get_native_mesh_surface_appearance(part)
    if not descriptor then return nil, nil end
    if type(renderer) == "table"
        and type(renderer._get_or_parse_part_mesh) == "function"
        and not renderer:_get_or_parse_part_mesh(part) then
        return nil, nil
    end
    local transparency = 1 - get_runtime_part_opacity(part)
    return SurfaceAppearance.classify_route(
        descriptor,
        transparency,
        descriptor.color_map_active,
        { depth_prepass_samples_alpha = false }), descriptor
end

-- imported SpecialMesh asset geometry has no native BasePart material-surface
-- contract (Creator Hub explicitly contrasts it with MeshPart). keep the
-- authored legacy texture/Head route authoritative. Generated legacy shapes
-- still use the parent Part material through the ordinary primitive path
function RBX._part_allows_material_variant_surface(part)
    if type(part) ~= "table" or part.MeshOwner ~= "SpecialMesh" then
        return true
    end
    local mesh_type = normalize_special_mesh_type(
        part.SpecialMeshType, nil) or "Head"
    return mesh_type ~= "FileMesh" and mesh_type ~= "Head"
end

-- MaterialVariant uses the same alpha-pass contract as SurfaceAppearance, but
-- it is resolved from the map-owned MaterialService catalog and applies to
-- native-compatible BasePart geometry. Feed effective material alpha (including Glass/
-- ForceField translucency) into the classifier so pass selection and the full
-- shader's uMaterialSurface alpha cap cannot disagree
function RBX._classify_part_material_variant_route(part, renderer)
    if type(part) ~= "table" or type(renderer) ~= "table"
        or type(renderer._get_material_descriptor) ~= "function" then
        return nil, nil
    end
    -- MaterialVariant is an explicit string selector. empty (including
    -- whitespace-only malformed input) means the BasePart uses its ordinary
    -- Material and cannot enter a variant alpha/surface route. reject it before
    -- registry resolution: this is the overwhelmingly common map path and
    -- avoids a second descriptor lookup for every ordinary part during full
    -- scene classification
    local requested_variant = part.MaterialVariant
    local has_explicit_variant = type(requested_variant) == "string"
        and requested_variant:find("%S") ~= nil
    if not has_explicit_variant then
        -- empty Part.MaterialVariant can still inherit a MaterialService base
        -- override. preserve that native route, but avoid descriptor resolution
        -- entirely when the catalog has no override for this material
        local catalog = renderer._material_variant_catalog
        local overrides = type(catalog) == "table"
            and catalog.base_overrides or nil
        if type(overrides) ~= "table" or next(overrides) == nil then
            return nil, nil
        end
        local base = MaterialRegistry.get(part.Material)
        if not base or overrides[base.canonical_token] == nil then
            return nil, nil
        end
    end
    if not RBX._part_allows_material_variant_surface(part) then
        return nil, nil
    end
    local descriptor = renderer:_get_material_descriptor(
        part.Material, part.MaterialVariant)
    local variant = descriptor and descriptor.material_variant_surface
    if type(variant) ~= "table" then return nil, descriptor end
    local effective_alpha = get_runtime_render_alpha(part)
    return SurfaceAppearance.classify_route(
        variant,
        1 - effective_alpha,
        variant.color_map_active,
        { depth_prepass_samples_alpha = false }), descriptor
end

function RBX._classify_part_full_material_route(part, renderer)
    local route, descriptor =
        RBX._classify_part_surface_appearance_route(part, renderer)
    if route then return route, "surface_appearance", descriptor end
    route, descriptor =
        RBX._classify_part_material_variant_route(part, renderer)
    if route then return route, "material_variant", descriptor end
    return nil, nil, descriptor
end

local function vector3_build(x, y, z)
    return setmetatable({
        _x = tonumber(x) or 0,
        _y = tonumber(y) or 0,
        _z = tonumber(z) or 0,
    }, Vector3)
end

local function vector3_components(value)
    if type(value) ~= "table" then
        return nil, nil, nil
    end
    if getmetatable(value) == Vector3 then
        return rawget(value, "_x"), rawget(value, "_y"), rawget(value, "_z")
    end
    local x = tonumber(value.x or value.X or value[1])
    local y = tonumber(value.y or value.Y or value[2])
    local z = tonumber(value.z or value.Z or value[3])
    if x == nil or y == nil or z == nil then
        return nil, nil, nil
    end
    return x, y, z
end

Vector3.__index = function(self, key)
    if key == "x" or key == "X" or key == 1 then
        return rawget(self, "_x")
    end
    if key == "y" or key == "Y" or key == 2 then
        return rawget(self, "_y")
    end
    if key == "z" or key == "Z" or key == 3 then
        return rawget(self, "_z")
    end
    if key == "Magnitude" or key == "magnitude" then
        local cached = rawget(self, "_magnitude")
        if cached ~= nil then
            return cached
        end
        local x, y, z = rawget(self, "_x"), rawget(self, "_y"), rawget(self, "_z")
        local magnitude = math.sqrt(x * x + y * y + z * z)
        rawset(self, "_magnitude", magnitude)
        return magnitude
    end
    if key == "Unit" or key == "unit" then
        local cached = rawget(self, "_unit")
        if cached ~= nil then
            return cached
        end
        local x, y, z = rawget(self, "_x"), rawget(self, "_y"), rawget(self, "_z")
        local magnitude = math.sqrt(x * x + y * y + z * z)
        local unit = magnitude <= 1e-12 and Vector3.zero or vector3_build(x / magnitude, y / magnitude, z / magnitude)
        rawset(self, "_unit", unit)
        return unit
    end
    return rawget(Vector3, key)
end

Vector3.__newindex = function()
    error("Vector3 values are immutable", 2)
end

function Vector3.new(x, y, z)
    return vector3_build(x, y, z)
end

function Vector3:clone()
    return self
end

function Vector3:Dot(other)
    local ax, ay, az = vector3_components(self)
    local bx, by, bz = vector3_components(other)
    if ax == nil or bx == nil then
        error("Vector3:Dot expected a Vector3-like value", 2)
    end
    return ax * bx + ay * by + az * bz
end

function Vector3:Cross(other)
    local ax, ay, az = vector3_components(self)
    local bx, by, bz = vector3_components(other)
    if ax == nil or bx == nil then
        error("Vector3:Cross expected a Vector3-like value", 2)
    end
    return vector3_build(
        ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx
    )
end

function Vector3:Lerp(other, alpha)
    local ax, ay, az = vector3_components(self)
    local bx, by, bz = vector3_components(other)
    if ax == nil or bx == nil then
        error("Vector3:Lerp expected a Vector3-like value", 2)
    end
    local t = tonumber(alpha) or 0
    return vector3_build(
        ax + (bx - ax) * t,
        ay + (by - ay) * t,
        az + (bz - az) * t
    )
end

function Vector3.__add(a, b)
    local ax, ay, az = vector3_components(a)
    local bx, by, bz = vector3_components(b)
    if ax == nil or bx == nil then
        error("attempt to perform arithmetic on Vector3 with unsupported value", 2)
    end
    return vector3_build(ax + bx, ay + by, az + bz)
end

function Vector3.__sub(a, b)
    local ax, ay, az = vector3_components(a)
    local bx, by, bz = vector3_components(b)
    if ax == nil or bx == nil then
        error("attempt to perform arithmetic on Vector3 with unsupported value", 2)
    end
    return vector3_build(ax - bx, ay - by, az - bz)
end

function Vector3.__unm(a)
    local ax, ay, az = vector3_components(a)
    if ax == nil then
        error("attempt to negate unsupported Vector3 value", 2)
    end
    return vector3_build(-ax, -ay, -az)
end

function Vector3.__mul(a, b)
    local ax, ay, az = vector3_components(a)
    local bx, by, bz = vector3_components(b)
    if ax ~= nil and bx ~= nil then
        return vector3_build(ax * bx, ay * by, az * bz)
    end
    if ax ~= nil and type(b) == "number" then
        return vector3_build(ax * b, ay * b, az * b)
    end
    if bx ~= nil and type(a) == "number" then
        return vector3_build(a * bx, a * by, a * bz)
    end
    error("attempt to perform arithmetic on Vector3 with unsupported value", 2)
end

function Vector3.__div(a, b)
    local ax, ay, az = vector3_components(a)
    local bx, by, bz = vector3_components(b)
    if ax ~= nil and bx ~= nil then
        return vector3_build(ax / bx, ay / by, az / bz)
    end
    if ax ~= nil and type(b) == "number" then
        return vector3_build(ax / b, ay / b, az / b)
    end
    error("attempt to perform arithmetic on Vector3 with unsupported value", 2)
end

function Vector3.__eq(a, b)
    local ax, ay, az = vector3_components(a)
    local bx, by, bz = vector3_components(b)
    return ax == bx and ay == by and az == bz
end

function Vector3.__tostring(value)
    local x, y, z = vector3_components(value)
    return string.format("%g, %g, %g", x or 0, y or 0, z or 0)
end

Vector3.zero = vector3_build(0, 0, 0)
Vector3.one = vector3_build(1, 1, 1)
Vector3.xAxis = vector3_build(1, 0, 0)
Vector3.yAxis = vector3_build(0, 1, 0)
Vector3.zAxis = vector3_build(0, 0, 1)
RBX.Vector3 = Vector3

Color3 = {}
Color3.__name = "Color3"

local function color3_build(r, g, b)
    return setmetatable({
        _r = tonumber(r) or 0,
        _g = tonumber(g) or 0,
        _b = tonumber(b) or 0,
    }, Color3)
end

local function color3_components(value)
    if type(value) ~= "table" then
        return nil, nil, nil
    end
    if getmetatable(value) == Color3 then
        return rawget(value, "_r"), rawget(value, "_g"), rawget(value, "_b")
    end
    local r = tonumber(value.r or value.R or value[1])
    local g = tonumber(value.g or value.G or value[2])
    local b = tonumber(value.b or value.B or value[3])
    if r == nil or g == nil or b == nil then
        return nil, nil, nil
    end
    return r, g, b
end

Color3.__index = function(self, key)
    if key == "r" or key == "R" or key == 1 then
        return rawget(self, "_r")
    end
    if key == "g" or key == "G" or key == 2 then
        return rawget(self, "_g")
    end
    if key == "b" or key == "B" or key == 3 then
        return rawget(self, "_b")
    end
    return rawget(Color3, key)
end

Color3.__newindex = function()
    error("Color3 values are immutable", 2)
end

function Color3.new(r, g, b)
    return color3_build(r, g, b)
end

function Color3.fromRGB(r, g, b)
    return color3_build((tonumber(r) or 0) / 255, (tonumber(g) or 0) / 255, (tonumber(b) or 0) / 255)
end

function Color3.fromHSV(h, s, v)
    h = (tonumber(h) or 0) % 1
    s = clamp(tonumber(s) or 0, 0, 1)
    v = clamp(tonumber(v) or 0, 0, 1)

    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    i = i % 6

    if i == 0 then
        return color3_build(v, t, p)
    elseif i == 1 then
        return color3_build(q, v, p)
    elseif i == 2 then
        return color3_build(p, v, t)
    elseif i == 3 then
        return color3_build(p, q, v)
    elseif i == 4 then
        return color3_build(t, p, v)
    end
    return color3_build(v, p, q)
end

function Color3:clone()
    return self
end

function Color3:Lerp(other, alpha)
    local ar, ag, ab = color3_components(self)
    local br, bg, bb = color3_components(other)
    if ar == nil or br == nil then
        error("Color3:Lerp expected a Color3-like value", 2)
    end
    local t = tonumber(alpha) or 0
    return color3_build(
        ar + (br - ar) * t,
        ag + (bg - ag) * t,
        ab + (bb - ab) * t
    )
end

function Color3.__eq(a, b)
    local ar, ag, ab = color3_components(a)
    local br, bg, bb = color3_components(b)
    return ar == br and ag == bg and ab == bb
end

function Color3.__tostring(value)
    local r, g, b = color3_components(value)
    return string.format("%g, %g, %g", r or 0, g or 0, b or 0)
end

RBX.Color3 = Color3

CFrame = {}
CFrame.__name = "CFrame"
local cframe_builtin_mul

local function cframe_from_matrix_numbers(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    return setmetatable({
        _x = tonumber(x) or 0,
        _y = tonumber(y) or 0,
        _z = tonumber(z) or 0,
        _r00 = tonumber(r00) or 1,
        _r01 = tonumber(r01) or 0,
        _r02 = tonumber(r02) or 0,
        _r10 = tonumber(r10) or 0,
        _r11 = tonumber(r11) or 1,
        _r12 = tonumber(r12) or 0,
        _r20 = tonumber(r20) or 0,
        _r21 = tonumber(r21) or 0,
        _r22 = tonumber(r22) or 1,
    }, CFrame)
end

local function cframe_position_components(value)
    if getmetatable(value) == CFrame then
        return rawget(value, "_x"), rawget(value, "_y"), rawget(value, "_z")
    end
    return vector3_components(value)
end

local cframe_component_key = {
    x = "_x",
    X = "_x",
    y = "_y",
    Y = "_y",
    z = "_z",
    Z = "_z",
    r00 = "_r00",
    R00 = "_r00",
    r01 = "_r01",
    R01 = "_r01",
    r02 = "_r02",
    R02 = "_r02",
    r10 = "_r10",
    R10 = "_r10",
    r11 = "_r11",
    R11 = "_r11",
    r12 = "_r12",
    R12 = "_r12",
    r20 = "_r20",
    R20 = "_r20",
    r21 = "_r21",
    R21 = "_r21",
    r22 = "_r22",
    R22 = "_r22",
}

CFrame.__index = function(self, key)
    local component = cframe_component_key[key]
    if component then
        return rawget(self, component)
    end
    if key == "Position" or key == "p" then
        local cached = rawget(self, "_position")
        if cached ~= nil then
            return cached
        end
        local position = vector3_build(rawget(self, "_x"), rawget(self, "_y"), rawget(self, "_z"))
        rawset(self, "_position", position)
        return position
    end
    if key == "RightVector" then
        local cached = rawget(self, "_right_vector")
        if cached ~= nil then
            return cached
        end
        local right = vector3_build(rawget(self, "_r00"), rawget(self, "_r10"), rawget(self, "_r20"))
        rawset(self, "_right_vector", right)
        return right
    end
    if key == "UpVector" then
        local cached = rawget(self, "_up_vector")
        if cached ~= nil then
            return cached
        end
        local up = vector3_build(rawget(self, "_r01"), rawget(self, "_r11"), rawget(self, "_r21"))
        rawset(self, "_up_vector", up)
        return up
    end
    if key == "LookVector" then
        local cached = rawget(self, "_look_vector")
        if cached ~= nil then
            return cached
        end
        local look = vector3_build(-rawget(self, "_r02"), -rawget(self, "_r12"), -rawget(self, "_r22"))
        rawset(self, "_look_vector", look)
        return look
    end
    return rawget(CFrame, key)
end

CFrame.__newindex = function()
    error("CFrame values are immutable", 2)
end

function CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    if type(x) == "table" and type(y) == "table" then
        return CFrame.lookAt(x, y)
    end
    if type(x) == "table" then
        local px, py, pz = cframe_position_components(x)
        return cframe_from_matrix_numbers(px or 0, py or 0, pz or 0)
    end
    if r00 ~= nil then
        return cframe_from_matrix_numbers(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    end
    return cframe_from_matrix_numbers(x, y, z)
end

function CFrame.fromMatrix(position, right_vector, up_vector, back_vector)
    local x, y, z = cframe_position_components(position)
    local rx, ry, rz = vector3_components(right_vector or Vector3.xAxis)
    local ux, uy, uz = vector3_components(up_vector or Vector3.yAxis)
    local bx, by, bz = vector3_components(back_vector)
    if bx == nil then
        bx, by, bz = cross(rx or 1, ry or 0, rz or 0, ux or 0, uy or 1, uz or 0)
    end
    return cframe_from_matrix_numbers(
        x or 0, y or 0, z or 0,
        rx or 1, ux or 0, bx or 0,
        ry or 0, uy or 1, by or 0,
        rz or 0, uz or 0, bz or 1
    )
end

function CFrame.lookAt(at, look_at, up)
    local x, y, z = cframe_position_components(at)
    local tx, ty, tz = vector3_components(look_at)
    x, y, z = x or 0, y or 0, z or 0
    tx, ty, tz = tx or x, ty or y, tz or (z - 1)
    local up_x, up_y, up_z = vector3_components(up or Vector3.yAxis)
    local lx, ly, lz = normalize_or_fallback(tx - x, ty - y, tz - z, 0, 0, -1)
    local rx, ry, rz = normalize(cross(lx, ly, lz, up_x or 0, up_y or 1, up_z or 0))
    if rx == 0 and ry == 0 and rz == 0 then
        -- a multi-return expression before more arguments supplies only its
        -- first value in Lua. preserve all three cross components here
        local fallback_x, fallback_y, fallback_z = cross(lx, ly, lz, 0, 0, 1)
        rx, ry, rz = normalize_or_fallback(fallback_x, fallback_y, fallback_z, 1, 0, 0)
    end
    local ux, uy, uz = cross(rx, ry, rz, lx, ly, lz)
    return cframe_from_matrix_numbers(
        x, y, z,
        rx, ux, -lx,
        ry, uy, -ly,
        rz, uz, -lz
    )
end

function CFrame.Angles(rx, ry, rz)
    rx, ry, rz = tonumber(rx) or 0, tonumber(ry) or 0, tonumber(rz) or 0
    local sx, cx = math.sin(rx), math.cos(rx)
    local sy, cy = math.sin(ry), math.cos(ry)
    local sz, cz = math.sin(rz), math.cos(rz)
    -- preserve the original operator path for nonfinite trigonometric results,
    -- including their NaN payloads. Finite angles use the scalar path below
    if sx ~= sx or sy ~= sy or sz ~= sz
        or rawget(CFrame, "__mul") ~= cframe_builtin_mul or rawget(CFrame, "__metatable") ~= nil then
        local rot_x = cframe_from_matrix_numbers(0, 0, 0, 1, 0, 0, 0, cx, -sx, 0, sx, cx)
        local rot_y = cframe_from_matrix_numbers(0, 0, 0, cy, 0, sy, 0, 1, 0, -sy, 0, cy)
        local rot_z = cframe_from_matrix_numbers(0, 0, 0, cz, -sz, 0, sz, cz, 0, 0, 0, 1)
        return rot_x * rot_y * rot_z
    end
    -- keep both original matrix products, including zero terms: removing them
    -- changes nonfinite propagation. only the four temporary frames disappear
    local x = 0 + 1 * 0 + 0 * 0 + 0 * 0
    local y = 0 + 0 * 0 + cx * 0 + (-sx) * 0
    local z = 0 + 0 * 0 + sx * 0 + cx * 0
    local r00 = 1 * cy + 0 * 0 + 0 * (-sy)
    local r01 = 1 * 0 + 0 * 1 + 0 * 0
    local r02 = 1 * sy + 0 * 0 + 0 * cy
    local r10 = 0 * cy + cx * 0 + (-sx) * (-sy)
    local r11 = 0 * 0 + cx * 1 + (-sx) * 0
    local r12 = 0 * sy + cx * 0 + (-sx) * cy
    local r20 = 0 * cy + sx * 0 + cx * (-sy)
    local r21 = 0 * 0 + sx * 1 + cx * 0
    local r22 = 0 * sy + sx * 0 + cx * cy
    return cframe_from_matrix_numbers(
        x + r00 * 0 + r01 * 0 + r02 * 0,
        y + r10 * 0 + r11 * 0 + r12 * 0,
        z + r20 * 0 + r21 * 0 + r22 * 0,
        r00 * cz + r01 * sz + r02 * 0, r00 * (-sz) + r01 * cz + r02 * 0, r00 * 0 + r01 * 0 + r02 * 1,
        r10 * cz + r11 * sz + r12 * 0, r10 * (-sz) + r11 * cz + r12 * 0, r10 * 0 + r11 * 0 + r12 * 1,
        r20 * cz + r21 * sz + r22 * 0, r20 * (-sz) + r21 * cz + r22 * 0, r20 * 0 + r21 * 0 + r22 * 1
    )
end

function CFrame.from_matrix(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    return cframe_from_matrix_numbers(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

function CFrame.from_look_vector(x, y, z, look_x, look_y, look_z, up_x, up_y, up_z)
    -- deprecated, use CFrame.lookAt
    local at = vector3_build(x, y, z)
    local target = vector3_build((x or 0) + (look_x or 0), (y or 0) + (look_y or 0), (z or 0) + (look_z or -1))
    return CFrame.lookAt(at, target, vector3_build(up_x or 0, up_y or 1, up_z or 0))
end

function CFrame.fromMatrixNumbers(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    return cframe_from_matrix_numbers(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

function CFrame:clone()
    return self
end

local function cframe_mul_cframe(a, b)
    local ax, ay, az = rawget(a, "_x"), rawget(a, "_y"), rawget(a, "_z")
    local a00, a01, a02 = rawget(a, "_r00"), rawget(a, "_r01"), rawget(a, "_r02")
    local a10, a11, a12 = rawget(a, "_r10"), rawget(a, "_r11"), rawget(a, "_r12")
    local a20, a21, a22 = rawget(a, "_r20"), rawget(a, "_r21"), rawget(a, "_r22")
    local bx, by, bz = rawget(b, "_x"), rawget(b, "_y"), rawget(b, "_z")
    local b00, b01, b02 = rawget(b, "_r00"), rawget(b, "_r01"), rawget(b, "_r02")
    local b10, b11, b12 = rawget(b, "_r10"), rawget(b, "_r11"), rawget(b, "_r12")
    local b20, b21, b22 = rawget(b, "_r20"), rawget(b, "_r21"), rawget(b, "_r22")
    local tx = ax + a00 * bx + a01 * by + a02 * bz
    local ty = ay + a10 * bx + a11 * by + a12 * bz
    local tz = az + a20 * bx + a21 * by + a22 * bz

    return cframe_from_matrix_numbers(
        tx, ty, tz,
        a00 * b00 + a01 * b10 + a02 * b20,
        a00 * b01 + a01 * b11 + a02 * b21,
        a00 * b02 + a01 * b12 + a02 * b22,
        a10 * b00 + a11 * b10 + a12 * b20,
        a10 * b01 + a11 * b11 + a12 * b21,
        a10 * b02 + a11 * b12 + a12 * b22,
        a20 * b00 + a21 * b10 + a22 * b20,
        a20 * b01 + a21 * b11 + a22 * b21,
        a20 * b02 + a21 * b12 + a22 * b22
    )
end

local function cframe_mul_vector(a, b)
    local bx, by, bz = vector3_components(b)
    local x = rawget(a, "_x") + rawget(a, "_r00") * bx + rawget(a, "_r01") * by + rawget(a, "_r02") * bz
    local y = rawget(a, "_y") + rawget(a, "_r10") * bx + rawget(a, "_r11") * by + rawget(a, "_r12") * bz
    local z = rawget(a, "_z") + rawget(a, "_r20") * bx + rawget(a, "_r21") * by + rawget(a, "_r22") * bz
    return vector3_build(x, y, z)
end

function CFrame.__mul(a, b)
    if getmetatable(a) ~= CFrame then
        error("left operand must be CFrame", 2)
    end
    if getmetatable(b) == CFrame then
        return cframe_mul_cframe(a, b)
    end
    if type(b) == "table" then
        local bx, by, bz = vector3_components(b)
        if bx ~= nil and by ~= nil and bz ~= nil then
            return cframe_mul_vector(a, b)
        end
    end
    error("attempt to multiply CFrame with unsupported value", 2)
end
cframe_builtin_mul = CFrame.__mul

function CFrame.__add(a, b)
    local bx, by, bz = vector3_components(b)
    if getmetatable(a) ~= CFrame or bx == nil then
        error("attempt to add CFrame with unsupported value", 2)
    end
    return cframe_from_matrix_numbers(
        rawget(a, "_x") + bx,
        rawget(a, "_y") + by,
        rawget(a, "_z") + bz,
        rawget(a, "_r00"), rawget(a, "_r01"), rawget(a, "_r02"),
        rawget(a, "_r10"), rawget(a, "_r11"), rawget(a, "_r12"),
        rawget(a, "_r20"), rawget(a, "_r21"), rawget(a, "_r22")
    )
end

function CFrame.__sub(a, b)
    local bx, by, bz = vector3_components(b)
    if getmetatable(a) ~= CFrame or bx == nil then
        error("attempt to subtract CFrame with unsupported value", 2)
    end
    return a + vector3_build(-bx, -by, -bz)
end

function CFrame.__eq(a, b)
    if getmetatable(a) ~= CFrame or getmetatable(b) ~= CFrame then
        return false
    end
    return rawget(a, "_x") == rawget(b, "_x")
        and rawget(a, "_y") == rawget(b, "_y")
        and rawget(a, "_z") == rawget(b, "_z")
        and rawget(a, "_r00") == rawget(b, "_r00")
        and rawget(a, "_r01") == rawget(b, "_r01")
        and rawget(a, "_r02") == rawget(b, "_r02")
        and rawget(a, "_r10") == rawget(b, "_r10")
        and rawget(a, "_r11") == rawget(b, "_r11")
        and rawget(a, "_r12") == rawget(b, "_r12")
        and rawget(a, "_r20") == rawget(b, "_r20")
        and rawget(a, "_r21") == rawget(b, "_r21")
        and rawget(a, "_r22") == rawget(b, "_r22")
end

function CFrame.__tostring(value)
    return string.format("%g, %g, %g", value.x or 0, value.y or 0, value.z or 0)
end

function CFrame:get_right_vector()
    -- deprecated, use RightVector
    return self.RightVector.x, self.RightVector.y, self.RightVector.z
end

function CFrame:get_up_vector()
    -- deprecated, use UpVector
    return self.UpVector.x, self.UpVector.y, self.UpVector.z
end

function CFrame:get_look_vector()
    -- deprecated, use LookVector
    return self.LookVector.x, self.LookVector.y, self.LookVector.z
end

-- row-major _rIJ, basis = cols (Right,Up,Back=-LookVector), world = R*local

function CFrame.fromAxisAngle(axis, angle)
    local ax, ay, az = vector3_components(axis)
    ax, ay, az = ax or 0, ay or 0, az or 0
    local len = math.sqrt(ax * ax + ay * ay + az * az)
    if len < 1e-8 then
        return CFrame.identity
    end
    ax, ay, az = ax / len, ay / len, az / len
    angle = tonumber(angle) or 0
    local c = math.cos(angle)
    local s = math.sin(angle)
    local t = 1 - c
    return cframe_from_matrix_numbers(0, 0, 0,
        t * ax * ax + c,      t * ax * ay - s * az, t * ax * az + s * ay,
        t * ax * ay + s * az, t * ay * ay + c,      t * ay * az - s * ax,
        t * ax * az - s * ay, t * ay * az + s * ax, t * az * az + c)
end

function CFrame:VectorToWorldSpace(v)
    local vx, vy, vz = vector3_components(v)
    vx, vy, vz = vx or 0, vy or 0, vz or 0
    return vector3_build(
        rawget(self, "_r00") * vx + rawget(self, "_r01") * vy + rawget(self, "_r02") * vz,
        rawget(self, "_r10") * vx + rawget(self, "_r11") * vy + rawget(self, "_r12") * vz,
        rawget(self, "_r20") * vx + rawget(self, "_r21") * vy + rawget(self, "_r22") * vz)
end

function CFrame:VectorToObjectSpace(v)
    local vx, vy, vz = vector3_components(v)
    vx, vy, vz = vx or 0, vy or 0, vz or 0
    return vector3_build(
        rawget(self, "_r00") * vx + rawget(self, "_r10") * vy + rawget(self, "_r20") * vz,
        rawget(self, "_r01") * vx + rawget(self, "_r11") * vy + rawget(self, "_r21") * vz,
        rawget(self, "_r02") * vx + rawget(self, "_r12") * vy + rawget(self, "_r22") * vz)
end

function CFrame:PointToWorldSpace(v)
    return cframe_mul_vector(self, v)
end

function CFrame:PointToObjectSpace(v)
    local vx, vy, vz = vector3_components(v)
    vx = (vx or 0) - rawget(self, "_x")
    vy = (vy or 0) - rawget(self, "_y")
    vz = (vz or 0) - rawget(self, "_z")
    return vector3_build(
        rawget(self, "_r00") * vx + rawget(self, "_r10") * vy + rawget(self, "_r20") * vz,
        rawget(self, "_r01") * vx + rawget(self, "_r11") * vy + rawget(self, "_r21") * vz,
        rawget(self, "_r02") * vx + rawget(self, "_r12") * vy + rawget(self, "_r22") * vz)
end

function CFrame:Inverse()
    local r00, r01, r02 = rawget(self, "_r00"), rawget(self, "_r01"), rawget(self, "_r02")
    local r10, r11, r12 = rawget(self, "_r10"), rawget(self, "_r11"), rawget(self, "_r12")
    local r20, r21, r22 = rawget(self, "_r20"), rawget(self, "_r21"), rawget(self, "_r22")
    local x, y, z = rawget(self, "_x"), rawget(self, "_y"), rawget(self, "_z")
    return cframe_from_matrix_numbers(
        -(r00 * x + r10 * y + r20 * z),
        -(r01 * x + r11 * y + r21 * z),
        -(r02 * x + r12 * y + r22 * z),
        r00, r10, r20,
        r01, r11, r21,
        r02, r12, r22)
end

CFrame.__unm = function(a)
    return a:Inverse()
end

function CFrame:ToWorldSpace(cf)
    return cframe_mul_cframe(self, cf)
end

function CFrame:ToObjectSpace(cf)
    return cframe_mul_cframe(self:Inverse(), cf)
end

-- returns w,x,y,z
local function cframe_mat_to_quat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
    local trace = r00 + r11 + r22
    if trace > 0 then
        local s = math.sqrt(trace + 1.0) * 2
        return 0.25 * s, (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s
    elseif r00 > r11 and r00 > r22 then
        local s = math.sqrt(1.0 + r00 - r11 - r22) * 2
        return (r21 - r12) / s, 0.25 * s, (r01 + r10) / s, (r02 + r20) / s
    elseif r11 > r22 then
        local s = math.sqrt(1.0 + r11 - r00 - r22) * 2
        return (r02 - r20) / s, (r01 + r10) / s, 0.25 * s, (r12 + r21) / s
    else
        local s = math.sqrt(1.0 + r22 - r00 - r11) * 2
        return (r10 - r01) / s, (r02 + r20) / s, (r12 + r21) / s, 0.25 * s
    end
end

-- nlerp fallback when near-parallel
local function cframe_quat_slerp(aw, ax, ay, az, bw, bx, by, bz, t)
    local d = aw * bw + ax * bx + ay * by + az * bz
    if d < 0 then
        bw, bx, by, bz, d = -bw, -bx, -by, -bz, -d
    end
    if d > 0.9995 then
        local rw, rx, ry, rz = aw + (bw - aw) * t, ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
        local inv = 1 / math.sqrt(rw * rw + rx * rx + ry * ry + rz * rz)
        return rw * inv, rx * inv, ry * inv, rz * inv
    end
    local theta0 = math.acos(d)
    local sin0 = math.sin(theta0)
    local s1 = math.sin(theta0 * t) / sin0
    local s0 = math.cos(theta0 * t) - d * s1
    return aw * s0 + bw * s1, ax * s0 + bx * s1, ay * s0 + by * s1, az * s0 + bz * s1
end

-- pos linear, rot slerp (roblox parity)
function CFrame:Lerp(other, alpha)
    if getmetatable(other) ~= CFrame then
        error("CFrame:Lerp expects a CFrame", 2)
    end
    alpha = tonumber(alpha) or 0
    local ax, ay, az = rawget(self, "_x"), rawget(self, "_y"), rawget(self, "_z")
    local px = ax + (rawget(other, "_x") - ax) * alpha
    local py = ay + (rawget(other, "_y") - ay) * alpha
    local pz = az + (rawget(other, "_z") - az) * alpha
    local aw, aqx, aqy, aqz = cframe_mat_to_quat(
        rawget(self, "_r00"), rawget(self, "_r01"), rawget(self, "_r02"),
        rawget(self, "_r10"), rawget(self, "_r11"), rawget(self, "_r12"),
        rawget(self, "_r20"), rawget(self, "_r21"), rawget(self, "_r22"))
    local bw, bqx, bqy, bqz = cframe_mat_to_quat(
        rawget(other, "_r00"), rawget(other, "_r01"), rawget(other, "_r02"),
        rawget(other, "_r10"), rawget(other, "_r11"), rawget(other, "_r12"),
        rawget(other, "_r20"), rawget(other, "_r21"), rawget(other, "_r22"))
    local qw, qx, qy, qz = cframe_quat_slerp(aw, aqx, aqy, aqz, bw, bqx, bqy, bqz, alpha)
    local xx, yy, zz = qx * qx, qy * qy, qz * qz
    local xy, xz, yz = qx * qy, qx * qz, qy * qz
    local wx, wy, wz = qw * qx, qw * qy, qw * qz
    return cframe_from_matrix_numbers(px, py, pz,
        1 - 2 * (yy + zz), 2 * (xy - wz),     2 * (xz + wy),
        2 * (xy + wz),     1 - 2 * (xx + zz), 2 * (yz - wx),
        2 * (xz - wy),     2 * (yz + wx),     1 - 2 * (xx + yy))
end

CFrame.identity = cframe_from_matrix_numbers(0, 0, 0)
RBX.CFrame = CFrame

-- stored lowercase for physics, read roblox-cased (.Density), omitted = defaults
local PhysicalProperties = {}
PhysicalProperties.__index = function(t, key)
    if key == "Density" then return rawget(t, "density") end
    if key == "Friction" then return rawget(t, "friction") end
    if key == "Elasticity" then return rawget(t, "elasticity") end
    if key == "FrictionWeight" then return rawget(t, "friction_weight") end
    if key == "ElasticityWeight" then return rawget(t, "elasticity_weight") end
    if key == "AcousticAbsorption" then return rawget(t, "acoustic_absorption") end
    return nil
end
PhysicalProperties.__tostring = function(t)
    return string.format("PhysicalProperties(%s, %s, %s, %s, %s, %s)",
        tostring(rawget(t, "density")), tostring(rawget(t, "friction")), tostring(rawget(t, "elasticity")),
        tostring(rawget(t, "friction_weight")), tostring(rawget(t, "elasticity_weight")),
        tostring(rawget(t, "acoustic_absorption")))
end
function PhysicalProperties.new(density, friction, elasticity, friction_weight, elasticity_weight, acoustic_absorption)
    -- Roblox exposes a material overload in addition to its numeric overloads
    -- only an actual runtime Enum.Material item selects it, so a legacy one-arg
    -- numeric call keeps its established numeric-constructor behavior
    if type(density) == "table" and density.EnumType == "Material"
        and friction == nil and elasticity == nil and friction_weight == nil
        and elasticity_weight == nil and acoustic_absorption == nil then
        local properties = runtime_require("physics/materials.lua")
            .default_properties_for_material(density)
        return setmetatable(properties, PhysicalProperties)
    end

    -- these are constructor-visible limits, not merely solver guard rails. the
    -- current Roblox API metadata documents clamping for every numeric
    -- component, including density's 0.0001 lower bound. keep this local so it
    -- does not add another chunk-level local to this already large runtime
    local function clamp_component(value, fallback, lower, upper)
        value = tonumber(value)
        if value == nil or value ~= value then
            return fallback
        end
        if value < lower then return lower end
        if value > upper then return upper end
        return value
    end

    local acoustic = tonumber(acoustic_absorption)
    if acoustic ~= nil then
        acoustic = clamp_component(acoustic, 0, 0, 1)
    end
    return setmetatable({
        density = clamp_component(density, 1, 0.0001, 100),
        friction = clamp_component(friction, 0.3, 0, 2),
        elasticity = clamp_component(elasticity, 0.5, 0, 1),
        friction_weight = clamp_component(friction_weight, 1, 0, 100),
        elasticity_weight = clamp_component(elasticity_weight, 1, 0, 100),
        acoustic_absorption = acoustic,
    }, PhysicalProperties)
end
RBX.PhysicalProperties = PhysicalProperties

local enum_item_mt = {}
enum_item_mt.__tostring = function(item)
    return "Enum." .. tostring(item.EnumType) .. "." .. tostring(item.Name)
end

local function make_enum_item(enum_type, name, value)
    return setmetatable({
        EnumType = enum_type,
        Name = name,
        Value = value,
        value = value,
        EnumItem = name,
    }, enum_item_mt)
end

local function make_enum_type(enum_type, values)
    local enum = {}
    for index = 1, #values do
        local entry = values[index]
        local name = entry[1]
        enum[name] = make_enum_item(enum_type, name, entry[2])
    end
    return setmetatable(enum, {
        __tostring = function()
            return "Enum." .. enum_type
        end,
    })
end

--- build script-facing enums from the same ID table that the parser uses
--- this keeps SpecialMesh.MeshType consistent in scripts and serialized places
local function make_enum_type_from_id_table(enum_type, id_table)
    local ids = {}
    for key in pairs(id_table) do
        if type(key) == "number" then
            ids[#ids + 1] = key
        end
    end
    table.sort(ids)
    local values = {}
    for index = 1, #ids do
        values[index] = { id_table[ids[index]], ids[index] }
    end
    return make_enum_type(enum_type, values)
end

RBX.Enum = {
    NormalId = make_enum_type("NormalId", {
        { "Right", 0 },
        { "Top", 1 },
        { "Back", 2 },
        { "Left", 3 },
        { "Bottom", 4 },
        { "Front", 5 },
    }),
    Face = make_enum_type("Face", {
        { "Right", 0 },
        { "Top", 1 },
        { "Back", 2 },
        { "Left", 3 },
        { "Bottom", 4 },
        { "Front", 5 },
    }),
    PartType = make_enum_type("PartType", {
        { "Ball", 0 },
        { "Block", 1 },
        { "Cylinder", 2 },
        { "Wedge", 3 },
        { "CornerWedge", 4 },
    }),
    SurfaceType = make_enum_type("SurfaceType", {
        { "Smooth", 0 },
        { "Glue", 1 },
        { "Weld", 2 },
        { "Studs", 3 },
        { "Inlet", 4 },
        { "Universal", 5 },
        { "Hinge", 6 },
        { "Motor", 7 },
        { "SteppingMotor", 8 },
        { "SmoothNoOutlines", 9 },
    }),
    -- derived from common.lua's RBX.SPECIAL_MESH_TYPE_ENUM -- the SAME table the
    -- parser resolves a file's MeshType token through. do not re-spell it here
    MeshType = make_enum_type_from_id_table("MeshType", RBX.SPECIAL_MESH_TYPE_ENUM),
    AlphaMode = make_enum_type("AlphaMode", {
        { "Overlay", 0 },
        { "Transparency", 1 },
        { "TintMask", 2 },
        { "Opaque", 3 },
    }),
    ResamplerMode = make_enum_type("ResamplerMode", {
        { "Default", 0 },
        { "Pixelated", 1 },
    }),
    TextXAlignment = make_enum_type("TextXAlignment", {
        { "Left", 0 },
        { "Center", 1 },
        { "Right", 2 },
    }),
    TextYAlignment = make_enum_type("TextYAlignment", {
        { "Top", 0 },
        { "Center", 1 },
        { "Bottom", 2 },
    }),
    SurfaceGuiSizingMode = make_enum_type("SurfaceGuiSizingMode", {
        { "FixedSize", 0 },
        { "PixelsPerStud", 1 },
    }),
    CameraType = make_enum_type("CameraType", {
        { "Fixed", 0 },
        { "Attach", 1 },
        { "Watch", 2 },
        { "Track", 3 },
        { "Follow", 4 },
        { "Custom", 5 },
        { "Scriptable", 6 },
        { "Orbital", 7 },
    }),
    Font = make_enum_type("Font", {
        { "Legacy", 0 },
        { "Arial", 1 },
        { "ArialBold", 2 },
        { "SourceSans", 3 },
        { "SourceSansBold", 4 },
        { "SourceSansLight", 5 },
        { "SourceSansItalic", 6 },
    }),
    -- exclude skips listed, Include hits only listed, legacy names aliased
    RaycastFilterType = make_enum_type("RaycastFilterType", {
        { "Exclude", 0 },
        { "Include", 1 },
        { "Blacklist", 0 },
        { "Whitelist", 1 },
    }),
    -- the same authoritative registry used by rendering and physics. keeping
    -- script-facing Enum.Material derived prevents modern values from becoming
    -- nil in RaycastResult.Material while the renderer knows their token
    Material = make_enum_type("Material", (function()
        local values = {}
        local tokens = MaterialRegistry.official_tokens()
        for index = 1, #tokens do
            local descriptor = MaterialRegistry.get(tokens[index])
            values[index] = { descriptor.name, descriptor.token }
        end
        return values
    end)()),
}

-- spatial query types

-- accepts {x,y,z}/{X,Y,Z}/{1,2,3}/Vector3
local function coerce_vector3(value, fx, fy, fz)
    if getmetatable(value) == Vector3 then
        return value
    end
    if type(value) == "table" then
        local x = value.x or value.X or value[1]
        local y = value.y or value.Y or value[2]
        local z = value.z or value.Z or value[3]
        return Vector3.new(tonumber(x) or fx or 0, tonumber(y) or fy or 0, tonumber(z) or fz or 0)
    end
    return Vector3.new(fx or 0, fy or 0, fz or 0)
end

-- direction length = reach
local Ray = {}
Ray.__name = "Ray"
Ray.__index = function(self, key)
    if key == "Origin" then return rawget(self, "_origin") end
    if key == "Direction" then return rawget(self, "_direction") end
    if key == "Unit" then
        local dir = rawget(self, "_direction")
        local unit = (dir.Magnitude > 1e-9) and dir.Unit or dir
        return Ray.new(rawget(self, "_origin"), unit)
    end
    return rawget(Ray, key)
end
Ray.__newindex = function()
    error("Ray values are immutable", 2)
end
Ray.__tostring = function(self)
    local o, d = rawget(self, "_origin"), rawget(self, "_direction")
    return string.format("Ray(%.3g, %.3g, %.3g, %.3g, %.3g, %.3g)", o.x, o.y, o.z, d.x, d.y, d.z)
end
function Ray.new(origin, direction)
    return setmetatable({
        _origin = coerce_vector3(origin),
        _direction = coerce_vector3(direction),
    }, Ray)
end
-- finite segment, not infinite ray (roblox parity)
function Ray:ClosestPoint(point)
    local o, d = rawget(self, "_origin"), rawget(self, "_direction")
    local p = coerce_vector3(point)
    local len2 = d:Dot(d)
    if len2 <= 1e-18 then
        return o
    end
    local t = (p - o):Dot(d) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return o + d * t
end
function Ray:Distance(point)
    return (self:ClosestPoint(point) - coerce_vector3(point)).Magnitude
end
RBX.Ray = Ray

local Region3 = {}
Region3.__name = "Region3"
Region3.__index = function(self, key)
    if key == "CFrame" then return rawget(self, "_cframe") end
    if key == "Size" then return rawget(self, "_size") end
    return rawget(Region3, key)
end
Region3.__newindex = function()
    error("Region3 values are immutable", 2)
end
Region3.__tostring = function(self)
    local c, s = rawget(self, "_cframe"), rawget(self, "_size")
    return string.format("Region3(center %.3g,%.3g,%.3g size %.3g,%.3g,%.3g)",
        c.x, c.y, c.z, s.x, s.y, s.z)
end
function Region3.new(min_vec, max_vec)
    local mn, mx = coerce_vector3(min_vec), coerce_vector3(max_vec)
    local lx, hx = math.min(mn.x, mx.x), math.max(mn.x, mx.x)
    local ly, hy = math.min(mn.y, mx.y), math.max(mn.y, mx.y)
    local lz, hz = math.min(mn.z, mx.z), math.max(mn.z, mx.z)
    return setmetatable({
        _minx = lx, _miny = ly, _minz = lz,
        _maxx = hx, _maxy = hy, _maxz = hz,
        _cframe = CFrame.new((lx + hx) * 0.5, (ly + hy) * 0.5, (lz + hz) * 0.5),
        _size = Vector3.new(hx - lx, hy - ly, hz - lz),
    }, Region3)
end
RBX.Region3 = Region3

local RaycastParams = {}
RaycastParams.__name = "RaycastParams"
RaycastParams.__index = RaycastParams
function RaycastParams.new()
    return setmetatable({
        FilterType = RBX.Enum.RaycastFilterType.Exclude,
        FilterDescendantsInstances = {},
        IgnoreWater = false,
        RespectCanCollide = false,
        CollisionGroup = "Default",
    }, RaycastParams)
end
function RaycastParams:AddToFilter(instances)
    local list = self.FilterDescendantsInstances or {}
    if type(instances) == "table" and getmetatable(instances) == nil then
        for i = 1, #instances do
            list[#list + 1] = instances[i]
        end
    elseif instances ~= nil then
        list[#list + 1] = instances
    end
    self.FilterDescendantsInstances = list
end
RBX.RaycastParams = RaycastParams
-- roblox has both, same shape
RBX.OverlapParams = RaycastParams

local RaycastResult = {}
RaycastResult.__name = "RaycastResult"
RaycastResult.__tostring = function(self)
    local inst = rawget(self, "Instance")
    return "RaycastResult(" .. (inst and tostring(inst.Name) or "nil") .. ")"
end
-- Position/Normal are built LAZILY: the hot gameplay rays (NPC obstacle/ground probes,
-- controller wall/step guards) only truthiness-test the result and never read Position or
-- Normal, so eagerly allocating two ~80B metatabled Vector3 per hit was pure steady GC
-- garbage. on first read of .Position/.Normal the Vector3 is built once and rawset (memoized),
-- so callers that DO read them get a byte-identical, identity-stable value. Instance/Distance/
-- Material stay direct fields (rawget hits, __index not invoked)
RaycastResult.__index = function(self, k)
    if k == "Position" then
        local v = Vector3.new(rawget(self, "_px"), rawget(self, "_py"), rawget(self, "_pz"))
        rawset(self, "Position", v)
        return v
    elseif k == "Normal" then
        local v = Vector3.new(rawget(self, "_nx"), rawget(self, "_ny"), rawget(self, "_nz"))
        rawset(self, "Normal", v)
        return v
    end
    return RaycastResult[k]
end
function RaycastResult._new(instance, px, py, pz, nx, ny, nz, distance, material)
    return setmetatable({
        Instance = instance,
        _px = px, _py = py, _pz = pz,
        _nx = nx, _ny = ny, _nz = nz,
        Distance = distance,
        Material = material,
    }, RaycastResult)
end
RBX.RaycastResult = RaycastResult

RBX._size_validation = runtime_require("size_validation.lua")

function vec3_get(value, xk, yk, zk)
    if type(value) ~= "table" then
        return nil, nil, nil
    end
    local x = value[xk] or value[xk:upper()] or value[1]
    local y = value[yk] or value[yk:upper()] or value[2]
    local z = value[zk] or value[zk:upper()] or value[3]
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x == nil or y == nil or z == nil then
        return nil, nil, nil
    end
    return x, y, z
end

function to_vector3(value, fallback_x, fallback_y, fallback_z)
    local x, y, z = vec3_get(value, "x", "y", "z")
    if x == nil then
        return fallback_x or 0, fallback_y or 0, fallback_z or 0
    end
    return x, y, z
end

function to_color3(value, fallback_r, fallback_g, fallback_b)
    local r, g, b = vec3_get(value, "r", "g", "b")
    if r == nil then
        return fallback_r or 1, fallback_g or 1, fallback_b or 1
    end
    if r > 1 or g > 1 or b > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end
    return clamp(r, 0, 1), clamp(g, 0, 1), clamp(b, 0, 1)
end

function cframe_from_value(value, fallback)
    if getmetatable(value) == CFrame then
        return value:clone()
    end

    if type(value) ~= "table" then
        return fallback and fallback:clone() or CFrame.new()
    end

    if value.r00 or value.R00 then
        return CFrame.from_matrix(
            tonumber(value.x or value.X) or 0,
            tonumber(value.y or value.Y) or 0,
            tonumber(value.z or value.Z) or 0,
            tonumber(value.r00 or value.R00) or 1,
            tonumber(value.r01 or value.R01) or 0,
            tonumber(value.r02 or value.R02) or 0,
            tonumber(value.r10 or value.R10) or 0,
            tonumber(value.r11 or value.R11) or 1,
            tonumber(value.r12 or value.R12) or 0,
            tonumber(value.r20 or value.R20) or 0,
            tonumber(value.r21 or value.R21) or 0,
            tonumber(value.r22 or value.R22) or 1
        )
    end

    local fx, fy, fz = 0, 0, 0
    if fallback then
        fx, fy, fz = fallback.x, fallback.y, fallback.z
    end
    local x, y, z = to_vector3(value, fx, fy, fz)
    local orientation = fallback or CFrame.new()
    return CFrame.from_matrix(
        x, y, z,
        orientation.r00, orientation.r01, orientation.r02,
        orientation.r10, orientation.r11, orientation.r12,
        orientation.r20, orientation.r21, orientation.r22
    )
end

PART_PROPERTY_SCHEMA = {
    Name = "string",
    ClassName = "string(readonly)",
    Shape = "PartType",
    CFrame = "CFrame",
    Position = "Vector3",
    Size = "Vector3",
    Color = "Color3",
    BrickColor = "BrickColor",
    Transparency = "number(0..1)",
    LocalTransparencyModifier = "number(0..1)",
    Reflectance = "number(0..1)",
    Anchored = "boolean",
    CanCollide = "boolean",
    CanTouch = "boolean",
    CanQuery = "boolean",
    CollisionGroup = "string",
    CollisionGroupId = "number(integer registered ID 0..31)",
    Massless = "boolean",
    RootPriority = "number",
    CustomPhysicalProperties = "table|nil",
    CurrentPhysicalProperties = "PhysicalProperties(readonly)",
    Mass = "number(readonly)",
    AssemblyMass = "number(readonly)",
    AssemblyCenterOfMass = "Vector3(readonly)",
    AssemblyRootPart = "BasePart(readonly)",
    AssemblyShapeApproximation = "string(readonly)|nil",
    Velocity = "Vector3",
    RotVelocity = "Vector3",
    AssemblyLinearVelocity = "Vector3",
    AssemblyAngularVelocity = "Vector3",
    Material = "number|Enum.Material",
    TopSurface = "SurfaceType|nil",
    BottomSurface = "SurfaceType|nil",
    LeftSurface = "SurfaceType|nil",
    RightSurface = "SurfaceType|nil",
    FrontSurface = "SurfaceType|nil",
    BackSurface = "SurfaceType|nil",
    TopSurfaceInput = "number",
    BottomSurfaceInput = "number",
    LeftSurfaceInput = "number",
    RightSurfaceInput = "number",
    FrontSurfaceInput = "number",
    BackSurfaceInput = "number",
    TopParamA = "number|nil",
    TopParamB = "number|nil",
    BottomParamA = "number|nil",
    BottomParamB = "number|nil",
    LeftParamA = "number|nil",
    LeftParamB = "number|nil",
    RightParamA = "number|nil",
    RightParamB = "number|nil",
    FrontParamA = "number|nil",
    FrontParamB = "number|nil",
    BackParamA = "number|nil",
    BackParamB = "number|nil",
    MeshId = "string|nil",
    TextureContent = "string|nil",
    TextureId = "string|nil",
    UsePartColor = "boolean",
    DoubleSided = "boolean",
    SmoothingAngle = "number|nil",
    RenderFidelity = "string|number|nil",
    CollisionFidelity = "string|number(readonly)",
    PhysicsData = "string(readonly)|nil",
    TriangleCount = "number|nil",
    MaterialVariant = "string|nil",
    MeshSize = "Vector3(readonly)|nil",
    MeshVertexColor = "Color3(readonly)|nil",
    SurfaceGuis = "table(readonly)",
    BillboardGuis = "table(readonly)",
}

RUNTIME_BASEPART_PROPERTY_DESCRIPTORS = nil
RUNTIME_PART_PROPERTY_DESCRIPTORS_BY_CLASS = {}

WORKSPACE_PROPERTY_SCHEMA = {
    Gravity = "number",
    FallenPartsDestroyHeight = "number",
}

datamodel_methods = {}
datamodel_node_proxy_mt = {}
camera_proxy_mt = {}
camera_methods = {}
workspace_methods = {}
workspace_proxy_mt = {}

local function get_proxy_datamodel_node(proxy)
    if type(proxy) ~= "table" then
        return nil, nil
    end
    local renderer = rawget(proxy, "_renderer")
    local node = rawget(proxy, "_dm_node")
    local part = rawget(proxy, "_part")
    if not node and rawget(proxy, "_dm_root_node") then
        renderer = proxy
        node = rawget(proxy, "_dm_root_node")
    end
    if not node and type(part) == "table" then
        node = part._dm_node
    end
    if not renderer and type(node) == "table" then
        renderer = node._renderer
    end
    return renderer, node
end

local function detach_datamodel_node(node)
    local parent = node and node.Parent
    if not parent or type(parent.Children) ~= "table" then
        if node then
            node.Parent = nil
        end
        return
    end
    for index = #parent.Children, 1, -1 do
        if parent.Children[index] == node then
            table.remove(parent.Children, index)
            break
        end
    end
    if parent.ChildNameMap and parent.ChildNameMap[node.Name] == node then
        parent.ChildNameMap[node.Name] = nil
        for index = 1, #parent.Children do
            local child = parent.Children[index]
            if child and child.Name == node.Name then
                parent.ChildNameMap[node.Name] = child
                break
            end
        end
    end
    node.Parent = nil
end

local function attach_datamodel_node(parent, child)
    if type(parent) ~= "table" or type(child) ~= "table" then
        return
    end
    if child.Parent == parent then
        return
    end
    detach_datamodel_node(child)
    parent.Children = parent.Children or {}
    parent.ChildNameMap = parent.ChildNameMap or {}
    child.Parent = parent
    parent.Children[#parent.Children + 1] = child
    if parent.ChildNameMap[child.Name] == nil then
        parent.ChildNameMap[child.Name] = child
    end
end

function rename_datamodel_node(node, new_name)
    if type(node) ~= "table" then
        return
    end
    local old_name = node.Name
    new_name = tostring(new_name or "")
    if old_name == new_name then
        return
    end
    node.Name = new_name
    local parent = node.Parent
    if parent and parent.ChildNameMap and parent.ChildNameMap[old_name] == node then
        parent.ChildNameMap[old_name] = nil
        for index = 1, #(parent.Children or {}) do
            local child = parent.Children[index]
            if child and child.Name == old_name then
                parent.ChildNameMap[old_name] = child
                break
            end
        end
    end
    if parent then
        parent.ChildNameMap = parent.ChildNameMap or {}
        if parent.ChildNameMap[new_name] == nil then
            parent.ChildNameMap[new_name] = node
        end
    end
end

local function find_datamodel_child(node, name, recursive)
    if type(node) ~= "table" or type(name) ~= "string" then
        return nil
    end
    local mapped = node.ChildNameMap and node.ChildNameMap[name] or nil
    if mapped and mapped.Name == name then
        return mapped
    end
    local children = node.Children or {}
    for index = 1, #children do
        local child = children[index]
        if child and child.Name == name then
            return child
        end
    end
    if recursive then
        for index = 1, #children do
            local found = find_datamodel_child(children[index], name, true)
            if found then
                return found
            end
        end
    end
    return nil
end

local function collect_datamodel_descendants(node, out)
    local children = node and node.Children or {}
    for index = 1, #children do
        local child = children[index]
        out[#out + 1] = child
        collect_datamodel_descendants(child, out)
    end
end

local function is_datamodel_instance_class(node, class_name)
    if type(node) ~= "table" or type(class_name) ~= "string" then
        return false
    end
    if class_name == "Instance" then
        return true
    end
    local cursor = node.ClassName
    while cursor do
        if cursor == class_name then
            return true
        end
        cursor = INSTANCE_CLASS_SUPERCLASS and INSTANCE_CLASS_SUPERCLASS[cursor] or nil
    end
    return false
end

function RBX:_create_datamodel_node(class_name, name)
    return {
        ClassName = class_name or "Instance",
        Name = name or class_name or "Instance",
        Children = {},
        ChildNameMap = {},
        _renderer = self,
    }
end

function RBX:_proxy_for_datamodel_node(node)
    if type(node) ~= "table" then
        return nil
    end
    if node._runtime_part then
        return self:_get_or_create_part_proxy(node._runtime_part)
    end
    if node == self._workspace_dm_node and self.Workspace then
        return self.Workspace
    end
    if node == self._lighting_dm_node and self.Lighting then
        return self.Lighting
    end
    if node == self._dm_root_node then
        return self
    end
    if node._proxy then
        return node._proxy
    end
    local proxy = setmetatable({
        _renderer = self,
        _dm_node = node,
    }, datamodel_node_proxy_mt)
    node._proxy = proxy
    return proxy
end

function RBX:_proxy_for_datamodel_parent(node)
    return node and node.Parent and self:_proxy_for_datamodel_node(node.Parent) or nil
end

function RBX:_datamodel_children_as_proxies(node)
    local out = {}
    local children = node and node.Children or {}
    for index = 1, #children do
        out[#out + 1] = self:_proxy_for_datamodel_node(children[index])
    end
    return out
end

function RBX:_datamodel_descendants_as_proxies(node)
    local nodes = {}
    collect_datamodel_descendants(node, nodes)
    local out = {}
    for index = 1, #nodes do
        out[#out + 1] = self:_proxy_for_datamodel_node(nodes[index])
    end
    return out
end

function RBX:_set_datamodel_parent(node, parent_proxy)
    if type(node) ~= "table" then
        return
    end
    if parent_proxy == nil then
        detach_datamodel_node(node)
        return
    end
    local parent_renderer, parent_node = get_proxy_datamodel_node(parent_proxy)
    if not parent_node then
        error("Parent must be a DataModel instance or nil", 3)
    end
    if parent_renderer and parent_renderer ~= self then
        error("Cannot parent instances across RBX DataModels", 3)
    end
    attach_datamodel_node(parent_node, node)
end

function datamodel_methods:GetChildren()
    local renderer, node = get_proxy_datamodel_node(self)
    return renderer and renderer:_datamodel_children_as_proxies(node) or {}
end

function datamodel_methods:GetDescendants()
    local renderer, node = get_proxy_datamodel_node(self)
    return renderer and renderer:_datamodel_descendants_as_proxies(node) or {}
end

function datamodel_methods:FindFirstChild(name, recursive)
    local renderer, node = get_proxy_datamodel_node(self)
    local found = find_datamodel_child(node, tostring(name or ""), recursive == true)
    return renderer and renderer:_proxy_for_datamodel_node(found) or nil
end

function datamodel_methods:WaitForChild(name)
    return self:FindFirstChild(name)
end

function datamodel_methods:IsA(class_name)
    local _, node = get_proxy_datamodel_node(self)
    return is_datamodel_instance_class(node, class_name)
end

function datamodel_methods:GetFullName()
    local _, node = get_proxy_datamodel_node(self)
    if not node then
        return ""
    end
    local parts = {}
    local cursor = node
    while cursor do
        parts[#parts + 1] = cursor.Name or cursor.ClassName or "Instance"
        cursor = cursor.Parent
    end
    local out = {}
    for index = #parts, 1, -1 do
        out[#out + 1] = parts[index]
    end
    return table.concat(out, ".")
end

function datamodel_node_proxy_mt.__index(proxy, key)
    local method = datamodel_methods[key]
    if method then
        return method
    end

    local renderer, node = get_proxy_datamodel_node(proxy)
    if not node then
        return nil
    end
    if key == "Parent" then
        return renderer:_proxy_for_datamodel_parent(node)
    end
    if key == "Children" then
        return renderer:_datamodel_children_as_proxies(node)
    end
    if key == "Name" or key == "ClassName" or key == "Referent" then
        return node[key]
    end
    if type(key) == "string" then
        local child = find_datamodel_child(node, key, false)
        if child then
            return renderer:_proxy_for_datamodel_node(child)
        end
    end
    return node[key]
end

function datamodel_node_proxy_mt.__newindex(proxy, key, value)
    local renderer, node = get_proxy_datamodel_node(proxy)
    if not node then
        error("Cannot edit detached Instance")
    end
    if key == "Parent" then
        renderer:_set_datamodel_parent(node, value)
        return
    end
    if key == "Name" then
        rename_datamodel_node(node, value)
        return
    end
    if key == "ClassName" then
        error("Instance.ClassName is read-only")
    end
    node[key] = value
end

datamodel_node_proxy_mt.__tostring = function(proxy)
    local _, node = get_proxy_datamodel_node(proxy)
    return node and string.format("%s<%s>", tostring(node.ClassName), tostring(node.Name)) or "Instance(nil)"
end

function RBX:_ensure_datamodel_tree()
    if self._dm_root_node and self._workspace_dm_node and self._lighting_dm_node then
        return
    end
    self._dm_root_node = self._dm_root_node or self:_create_datamodel_node("DataModel", "game")
    self._dm_root_node._renderer = self
    self._workspace_dm_node = self._workspace_dm_node or self:_create_datamodel_node("Workspace", "Workspace")
    self._workspace_dm_node._service_name = "Workspace"
    self._workspace_dm_node._renderer = self
    self._lighting_dm_node = self._lighting_dm_node or self:_create_datamodel_node("Lighting", "Lighting")
    self._lighting_dm_node._service_name = "Lighting"
    self._lighting_dm_node._renderer = self
    self._dm_root_node.Children = self._dm_root_node.Children or {}
    attach_datamodel_node(self._dm_root_node, self._workspace_dm_node)
    attach_datamodel_node(self._dm_root_node, self._lighting_dm_node)
end

function RBX:_reset_datamodel_tree()
    local workspace_proxy = self.Workspace
    local lighting_proxy = self.Lighting
    self._dm_root_node = self:_create_datamodel_node("DataModel", "game")
    self._workspace_dm_node = self:_create_datamodel_node("Workspace", "Workspace")
    self._workspace_dm_node._service_name = "Workspace"
    self._lighting_dm_node = self:_create_datamodel_node("Lighting", "Lighting")
    self._lighting_dm_node._service_name = "Lighting"
    self._dm_node_by_referent = {}
    attach_datamodel_node(self._dm_root_node, self._workspace_dm_node)
    attach_datamodel_node(self._dm_root_node, self._lighting_dm_node)
    if workspace_proxy then
        rawset(workspace_proxy, "_dm_node", self._workspace_dm_node)
    end
    if lighting_proxy then
        rawset(lighting_proxy, "_dm_node", self._lighting_dm_node)
    end
end

local function copy_datamodel_source_properties(source, target)
    for key, value in pairs(source or {}) do
        if key ~= "Children" and key ~= "Parent" and key ~= "_dom_instance" then
            target[key] = copy_runtime_value(value)
        end
    end
end

function RBX:_convert_instance_root_to_datamodel_node(source)
    if type(source) ~= "table" then
        return nil
    end

    local part = source.Referent and self._runtime_part_by_referent and self._runtime_part_by_referent[source.Referent]
        or nil
    local node
    if part then
        node = part._dm_node or self:_create_datamodel_node(part.ClassName, part.Name)
        node.Children = {}
        node._runtime_part = part
        node._renderer = self
        part._dm_node = node
    else
        node = self:_create_datamodel_node(source.ClassName or "Instance", source.Name or source.ClassName or "Instance")
    end
    copy_datamodel_source_properties(source, node)
    node.ClassName = part and part.ClassName or (source.ClassName or node.ClassName)
    node.Name = part and part.Name or (source.Name or node.Name)
    node.Referent = source.Referent or node.Referent
    if node.Referent then
        self._dm_node_by_referent[node.Referent] = node
    end

    local children = source.Children or {}
    for index = 1, #children do
        local child = self:_convert_instance_root_to_datamodel_node(children[index])
        if child then
            attach_datamodel_node(node, child)
        end
    end

    return node
end

function RBX:_merge_service_node(service_node, source_node)
    if type(service_node) ~= "table" or type(source_node) ~= "table" then
        return
    end
    copy_datamodel_source_properties(source_node, service_node)
    service_node.ClassName = service_node.ClassName or source_node.ClassName
    service_node.Name = service_node.Name or source_node.Name
    service_node.Children = service_node.Children or {}
    local children = source_node.Children or {}
    for index = 1, #children do
        local child = self:_convert_instance_root_to_datamodel_node(children[index])
        if child then
            attach_datamodel_node(service_node, child)
        end
    end
end

function RBX:_attach_runtime_part_to_datamodel(part, parent_proxy)
    if type(part) ~= "table" then
        return
    end
    self:_ensure_datamodel_tree()
    local node = part._dm_node or self:_create_datamodel_node(part.ClassName, part.Name)
    node.ClassName = part.ClassName
    node.Name = part.Name
    node.Referent = part._map_referent or node.Referent
    node._runtime_part = part
    node._renderer = self
    node.Children = node.Children or {}
    part._dm_node = node
    if node.Referent then
        self._dm_node_by_referent = self._dm_node_by_referent or {}
        self._dm_node_by_referent[node.Referent] = node
    end
    if parent_proxy ~= nil then
        self:_set_datamodel_parent(node, parent_proxy)
    elseif not node.Parent then
        attach_datamodel_node(self._workspace_dm_node, node)
    end
end

function RBX:_attach_unparented_runtime_parts_to_workspace()
    self:_ensure_datamodel_tree()
    for index = 1, #(self.parts or {}) do
        local part = self.parts[index]
        if part and not part._destroyed and not part._dm_node then
            self:_attach_runtime_part_to_datamodel(part, nil)
        end
    end
end

function RBX:_promote_instance_roots(instance_roots)
    self:_reset_datamodel_tree()
    local roots = type(instance_roots) == "table" and instance_roots or {}
    for index = 1, #roots do
        local source = roots[index]
        local class_name = source and source.ClassName
        if class_name == "DataModel" or class_name == "Game" then
            local children = source.Children or {}
            for child_index = 1, #children do
                local child_source = children[child_index]
                local child_class = child_source and child_source.ClassName
                if child_class == "Workspace" then
                    self:_merge_service_node(self._workspace_dm_node, child_source)
                elseif child_class == "Lighting" then
                    self:_merge_service_node(self._lighting_dm_node, child_source)
                else
                    local child = self:_convert_instance_root_to_datamodel_node(child_source)
                    if child then
                        attach_datamodel_node(self._dm_root_node, child)
                    end
                end
            end
        elseif class_name == "Workspace" then
            self:_merge_service_node(self._workspace_dm_node, source)
        elseif class_name == "Lighting" then
            self:_merge_service_node(self._lighting_dm_node, source)
        else
            local node = self:_convert_instance_root_to_datamodel_node(source)
            if node then
                attach_datamodel_node(self._dm_root_node, node)
            end
        end
    end
    self:_attach_unparented_runtime_parts_to_workspace()
end

function RBX:_reset_workspace_settings_to_defaults()
    local defaults = self._default_workspace_settings or {
        Gravity = 196.2,
        FallenPartsDestroyHeight = -500,
    }
    self._workspace_settings = {
        Gravity = tonumber(defaults.Gravity) or 196.2,
        FallenPartsDestroyHeight = tonumber(defaults.FallenPartsDestroyHeight) or -500,
    }
end

function RBX:_apply_workspace_settings(settings)
    if type(self._workspace_settings) ~= "table" then
        self:_reset_workspace_settings_to_defaults()
    end
    if type(settings) == "table" then
        if settings.Gravity ~= nil then
            self._workspace_settings.Gravity = tonumber(settings.Gravity) or self._workspace_settings.Gravity or 196.2
        end
        if settings.FallenPartsDestroyHeight ~= nil then
            self._workspace_settings.FallenPartsDestroyHeight = tonumber(settings.FallenPartsDestroyHeight)
                or self._workspace_settings.FallenPartsDestroyHeight
                or -500
        end
    end
end

function RBX:_build_workspace_proxy()
    self:_ensure_datamodel_tree()
    return setmetatable({
        _renderer = self,
        _dm_node = self._workspace_dm_node,
    }, workspace_proxy_mt)
end

workspace_proxy_mt.__index = function(proxy, key)
    local workspace_method = workspace_methods[key]
    if workspace_method then
        return workspace_method
    end
    local datamodel_method = datamodel_methods[key]
    if datamodel_method then
        return datamodel_method
    end
    local renderer = rawget(proxy, "_renderer")
    if not renderer then
        return nil
    end
    local node = rawget(proxy, "_dm_node") or renderer._workspace_dm_node
    if key == "CurrentCamera" then
        return renderer._current_camera
    end
    if key == "Name" or key == "ClassName" or key == "Referent" then
        return node and node[key] or (key == "Name" and "Workspace" or key == "ClassName" and "Workspace" or nil)
    end
    if key == "Parent" then
        return renderer:_proxy_for_datamodel_parent(node)
    end
    if key == "Children" then
        return renderer:_datamodel_children_as_proxies(node)
    end
    if WORKSPACE_PROPERTY_SCHEMA[key] then
        return renderer._workspace_settings and renderer._workspace_settings[key] or nil
    end
    if type(key) == "string" then
        local child = find_datamodel_child(node, key, false)
        if child then
            return renderer:_proxy_for_datamodel_node(child)
        end
    end
    if node then
        return node[key]
    end
    return nil
end

workspace_proxy_mt.__newindex = function(proxy, key, value)
    local renderer = rawget(proxy, "_renderer")
    if not renderer then
        error("Cannot edit detached Workspace")
    end
    if key == "Gravity" then
        local numeric = tonumber(value)
        if numeric == nil then
            error("Workspace.Gravity must be numeric")
        end
        renderer:_apply_workspace_settings({ Gravity = numeric })
        return
    end
    if key == "FallenPartsDestroyHeight" then
        local numeric = tonumber(value)
        if numeric == nil then
            error("Workspace.FallenPartsDestroyHeight must be numeric")
        end
        renderer:_apply_workspace_settings({ FallenPartsDestroyHeight = numeric })
        return
    end
    if key == "CurrentCamera" then
        if value == renderer._current_camera then
            return
        end
        error("Workspace.CurrentCamera is managed by the RBX runtime")
    end
    if key == "Name" then
        local node = rawget(proxy, "_dm_node") or renderer._workspace_dm_node
        if node then
            node.Name = tostring(value or "Workspace")
        end
        return
    end
    if key == "Parent" or key == "ClassName" then
        error("Workspace." .. tostring(key) .. " is read-only")
    end
    error("Unknown workspace property '" .. tostring(key) .. "'")
end

workspace_proxy_mt.__tostring = function()
    return "Workspace"
end

function workspace_methods:GetPropertySchema()
    return WORKSPACE_PROPERTY_SCHEMA
end

camera_proxy_mt.__index = function(proxy, key)
    local method = camera_methods[key]
    if method then
        return method
    end
    local renderer = rawget(proxy, "_renderer")
    if not renderer then
        return nil
    end
    if key == "Name" then
        return "Camera"
    end
    if key == "ClassName" then
        return "Camera"
    end
    if key == "Parent" then
        return renderer.Workspace
    end
    if key == "CFrame" then
        return renderer:get_camera_cframe()
    end
    if key == "Focus" then
        return renderer:get_camera_focus()
    end
    if key == "CameraType" then
        return renderer:get_camera_type()
    end
    if key == "FieldOfView" then
        return renderer:get_camera_field_of_view()
    end
    if key == "ViewportSize" then
        return renderer:get_camera_viewport_size()
    end
    return nil
end

camera_proxy_mt.__newindex = function(proxy, key, value)
    local renderer = rawget(proxy, "_renderer")
    if not renderer then
        error("Cannot edit detached Camera")
    end
    if key == "CFrame" then
        renderer:set_camera_cframe(value)
        return
    end
    if key == "Focus" then
        renderer:set_camera_focus(value)
        return
    end
    if key == "CameraType" then
        renderer:set_camera_type(value)
        return
    end
    if key == "FieldOfView" then
        renderer:set_camera_field_of_view(value)
        return
    end
    if key == "ViewportSize" then
        error("Camera.ViewportSize is read-only")
        return
    end
    error("Unknown Camera property '" .. tostring(key) .. "'")
end

camera_proxy_mt.__tostring = function()
    return "Camera"
end

function RBX:GetService(service_name)
    self:_ensure_datamodel_tree()
    if type(service_name) ~= "string" then
        return nil
    end
    if service_name == "Workspace" then
        return self.Workspace
    end
    if service_name == "Lighting" then
        return self.Lighting
    end
    local child = find_datamodel_child(self._dm_root_node, service_name, false)
    return self:_proxy_for_datamodel_node(child)
end

function RBX:GetChildren()
    self:_ensure_datamodel_tree()
    return self:_datamodel_children_as_proxies(self._dm_root_node)
end

function RBX:GetDescendants()
    self:_ensure_datamodel_tree()
    return self:_datamodel_descendants_as_proxies(self._dm_root_node)
end

function RBX:FindFirstChild(name, recursive)
    self:_ensure_datamodel_tree()
    return self:_proxy_for_datamodel_node(find_datamodel_child(self._dm_root_node, tostring(name or ""), recursive == true))
end

function RBX:WaitForChild(name)
    return self:FindFirstChild(name)
end

function RBX:IsA(class_name)
    return class_name == "DataModel" or class_name == "Instance"
end

-- accepts snake_case/PascalCase/positional/camelCase keys
function clone_physical_properties_value(value)
    if type(value) ~= "table" then
        return nil
    end
    -- parsed RBXLX values and the table convenience accepted by the facade do
    -- not necessarily originate from PhysicalProperties.new. normalize every
    -- authored numeric component here as well, so a property read cannot
    -- expose an out-of-range value while the solver silently uses another one
    local function optional_component(raw, lower, upper)
        local numeric = tonumber(raw)
        if numeric == nil or numeric ~= numeric then return nil end
        if numeric < lower then return lower end
        if numeric > upper then return upper end
        return numeric
    end
    local friction_weight = value.friction_weight or value.FrictionWeight or value[4]
        or value.frictionWeight
    local elasticity_weight = value.elasticity_weight or value.ElasticityWeight or value[5]
        or value.elasticityWeight
    local acoustic_absorption = value.acoustic_absorption or value.AcousticAbsorption or value[6]
        or value.acousticAbsorption
    return setmetatable({
        density = optional_component(value.density or value.Density or value[1], 0.0001, 100),
        friction = optional_component(value.friction or value.Friction or value[2], 0, 2),
        elasticity = optional_component(value.elasticity or value.Elasticity or value[3], 0, 1),
        friction_weight = optional_component(friction_weight, 0, 100),
        elasticity_weight = optional_component(elasticity_weight, 0, 100),
        acoustic_absorption = optional_component(acoustic_absorption, 0, 1),
        friction_combine = value.friction_combine or value.FrictionCombine or nil,
        elasticity_combine = value.elasticity_combine or value.ElasticityCombine or nil,
    }, PhysicalProperties)
end

local function clone_vector3_value(value, fallback_x, fallback_y, fallback_z)
    local x, y, z = to_vector3(value, fallback_x, fallback_y, fallback_z)
    return Vector3.new(x, y, z)
end

local function sync_runtime_part_velocity_aliases(part)
    if type(part) ~= "table" then
        return
    end
    local linear = part.AssemblyLinearVelocity or { x = 0, y = 0, z = 0 }
    local angular = part.AssemblyAngularVelocity or { x = 0, y = 0, z = 0 }
    part.Velocity = clone_vector3_value(linear, 0, 0, 0)
    part.RotVelocity = clone_vector3_value(angular, 0, 0, 0)
end

part_methods = {}
explorer_methods = {}
build_static_mesh = nil
part_has_embedded_mesh_payload = nil
get_part_embedded_mesh_candidates = nil

local function new_runtime_signal(renderer, name)
    return new_rbx_script_signal(renderer, name)
end

local function get_runtime_part_signal(renderer, part, name)
    if not part then
        return nil
    end
    part._signals = part._signals or {}
    local signal = part._signals[name]
    if signal then
        return signal
    end
    signal = new_runtime_signal(renderer, (part.Name or part.ClassName or "Part") .. "." .. tostring(name))
    part._signals[name] = signal
    return signal
end

local function fire_runtime_part_signal(renderer, part, name, ...)
    local signals = part and part._signals or nil
    local signal = signals and signals[name] or nil
    if signal then
        fire_rbx_script_signal(signal, ...)
    end
end

local function get_runtime_part_property_signal(renderer, part, property_name)
    if not part then
        return nil
    end
    part._property_signals = part._property_signals or {}
    local signal = part._property_signals[property_name]
    if signal then
        return signal
    end
    signal = new_runtime_signal(renderer, (part.Name or part.ClassName or "Part") .. "." .. tostring(property_name))
    part._property_signals[property_name] = signal
    return signal
end

function fire_runtime_part_property_changed(renderer, part, property_name)
    local bucket = part and part._property_signals or nil
    local signal = bucket and bucket[property_name] or nil
    if signal then
        fire_rbx_script_signal(signal)
    end
    fire_runtime_part_signal(renderer, part, "Changed", property_name)
end

function cleanup_runtime_part_signals(part)
    if type(part) ~= "table" then
        return
    end
    cleanup_rbx_script_signal_bucket(part._signals)
    cleanup_rbx_script_signal_bucket(part._property_signals)
    part._signals = nil
    part._property_signals = nil
end

function get_runtime_part_basis(part)
    local cframe = part.CFrame
    local right_x, right_y, right_z, up_x, up_y, up_z, back_x, back_y, back_z, px, py, pz
    -- raw reads avoid alloc, getter cache never hits, physics rewrites cframe every frame
    local r00 = rawget(cframe, "_r00")
    if r00 ~= nil then
        right_x, right_y, right_z = r00, rawget(cframe, "_r10"), rawget(cframe, "_r20")
        up_x, up_y, up_z = rawget(cframe, "_r01"), rawget(cframe, "_r11"), rawget(cframe, "_r21")
        back_x, back_y, back_z = rawget(cframe, "_r02"), rawget(cframe, "_r12"), rawget(cframe, "_r22")
        px, py, pz = rawget(cframe, "_x"), rawget(cframe, "_y"), rawget(cframe, "_z")
    else
        right_x, right_y, right_z = cframe:get_right_vector()
        up_x, up_y, up_z = cframe:get_up_vector()
        back_x, back_y, back_z = cframe.r02, cframe.r12, cframe.r22
        px, py, pz = cframe.x, cframe.y, cframe.z
    end
    local size = part.Size
    local sx, sy, sz = size.x, size.y, size.z

    if part.BlockMeshScale then
        sx = sx * (part.BlockMeshScale.x or 1)
        sy = sy * (part.BlockMeshScale.y or 1)
        sz = sz * (part.BlockMeshScale.z or 1)
    end

    if part.BlockMeshOffset then
        local ox = part.BlockMeshOffset.x or 0
        local oy = part.BlockMeshOffset.y or 0
        local oz = part.BlockMeshOffset.z or 0
        px = px + right_x * ox + up_x * oy + back_x * oz
        py = py + right_y * ox + up_y * oy + back_y * oz
        pz = pz + right_z * ox + up_z * oy + back_z * oz
    end

    return px, py, pz, right_x, right_y, right_z, up_x, up_y, up_z, back_x, back_y, back_z, sx, sy, sz
end

function expand_scene_bounds_with_part(bounds, part)
    local px, py, pz,
    rx, ry, rz,
    ux, uy, uz,
    bx, by, bz,
    sx, sy, sz = get_runtime_part_render_basis(part)

    local hx = math.abs(sx) * 0.5
    local hy = math.abs(sy) * 0.5
    local hz = math.abs(sz) * 0.5

    -- obb->aabb extents
    local ex = math.abs(rx) * hx + math.abs(ux) * hy + math.abs(bx) * hz
    local ey = math.abs(ry) * hx + math.abs(uy) * hy + math.abs(by) * hz
    local ez = math.abs(rz) * hx + math.abs(uz) * hy + math.abs(bz) * hz

    bounds.min_x = math.min(bounds.min_x, px - ex)
    bounds.min_y = math.min(bounds.min_y, py - ey)
    bounds.min_z = math.min(bounds.min_z, pz - ez)
    bounds.max_x = math.max(bounds.max_x, px + ex)
    bounds.max_y = math.max(bounds.max_y, py + ey)
    bounds.max_z = math.max(bounds.max_z, pz + ez)
end

function get_runtime_part_bounds(part)
    local px, py, pz,
    rx, ry, rz,
    ux, uy, uz,
    bx, by, bz,
    sx, sy, sz = get_runtime_part_render_basis(part)

    local hx = math.abs(sx) * 0.5
    local hy = math.abs(sy) * 0.5
    local hz = math.abs(sz) * 0.5

    local ex = math.abs(rx) * hx + math.abs(ux) * hy + math.abs(bx) * hz
    local ey = math.abs(ry) * hx + math.abs(uy) * hy + math.abs(by) * hz
    local ez = math.abs(rz) * hx + math.abs(uz) * hy + math.abs(bz) * hz

    return {
        min_x = px - ex,
        min_y = py - ey,
        min_z = pz - ez,
        max_x = px + ex,
        max_y = py + ey,
        max_z = pz + ez,
    }
end

function RBX:_resolve_constraint_attachment_world_point(attachment)
    if type(attachment) ~= "table" then
        return nil
    end

    local parent_index = tonumber(attachment.parent_part_index)
    local parent = parent_index and self.parts and self.parts[parent_index] or nil
    if type(parent) ~= "table" or parent._destroyed then
        local world_x = tonumber(attachment.world_x)
        local world_y = tonumber(attachment.world_y)
        local world_z = tonumber(attachment.world_z)
        if world_x ~= nil and world_y ~= nil and world_z ~= nil then
            -- world_* already engine coords (verbatim decode)
            local runtime_x = world_x
            if self.flip_loaded_map_horizontally ~= false then
                runtime_x = -runtime_x
            end
            return runtime_x, world_y, world_z
        end
        return nil
    end

    local cframe = parent.CFrame
    if getmetatable(cframe) ~= CFrame then
        return nil
    end

    local px, py, pz = cframe.x or 0, cframe.y or 0, cframe.z or 0
    local rx, ry, rz = cframe.r00 or 1, cframe.r10 or 0, cframe.r20 or 0
    local ux, uy, uz = cframe.r01 or 0, cframe.r11 or 1, cframe.r21 or 0
    local bx, by, bz = cframe.r02 or 0, cframe.r12 or 0, cframe.r22 or 1

    local ox = tonumber(attachment.local_x) or 0
    local oy = tonumber(attachment.local_y) or 0
    local oz = tonumber(attachment.local_z) or 0
    return px + rx * ox + ux * oy + bx * oz,
        py + ry * ox + uy * oy + by * oz,
        pz + rz * ox + uz * oy + bz * oz
end

function RBX:_build_constraint_draw_item(constraint, index)
    if type(constraint) ~= "table" then
        return nil
    end
    -- Mechanical constraints render from live attachment facades in the
    -- constraint visual pass. Baking their parsed pose here would leave a
    -- second, stale cylinder after an endpoint moves or Visible becomes false
    -- Beam retains its existing parsed geometry path
    if constraint.class_name == "RopeConstraint" or constraint.class_name == "RodConstraint" then
        return nil
    end

    local ax, ay, az = self:_resolve_constraint_attachment_world_point(constraint.attachment0_entry)
    local bx, by, bz = self:_resolve_constraint_attachment_world_point(constraint.attachment1_entry)
    if not ax or not bx then
        return nil
    end

    local dx = bx - ax
    local dy = by - ay
    local dz = bz - az
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length <= 1e-4 then
        return nil
    end

    local up_x, up_y, up_z = dx / length, dy / length, dz / length
    local guide_x, guide_y, guide_z = 0, 1, 0
    if math.abs(up_y) > 0.985 then
        guide_x, guide_y, guide_z = 1, 0, 0
    end

    local right_x, right_y, right_z = normalize_or_fallback(
        guide_y * up_z - guide_z * up_y,
        guide_z * up_x - guide_x * up_z,
        guide_x * up_y - guide_y * up_x,
        1, 0, 0
    )
    local back_x, back_y, back_z = normalize_or_fallback(
        right_y * up_z - right_z * up_y,
        right_z * up_x - right_x * up_z,
        right_x * up_y - right_y * up_x,
        0, 0, 1
    )

    local width0 = math.abs(tonumber(constraint.width0) or 0)
    local width1 = math.abs(tonumber(constraint.width1) or 0)
    local thickness = math.abs(tonumber(constraint.thickness) or 0)
    if constraint.class_name == "Beam" and (width0 > 0 or width1 > 0) then
        thickness = math.max(thickness, (width0 + width1) * 0.5)
    end
    thickness = math.max(0.005, thickness)

    local mid_x = (ax + bx) * 0.5
    local mid_y = (ay + by) * 0.5
    local mid_z = (az + bz) * 0.5
    local alpha = clamp(1 - (tonumber(constraint.transparency) or 0), 0, 1)
    local color_r, color_g, color_b = authored_color3_to_gpu(
        clamp((constraint.color_r or 235) / 255, 0, 1),
        clamp((constraint.color_g or 235) / 255, 0, 1),
        clamp((constraint.color_b or 235) / 255, 0, 1)
    )
    local source_vertices = self._primitive_vertices and self._primitive_vertices.CylinderY or self._cube_vertices
    local mesh = build_static_mesh(self, {
        {
            mid_x, mid_y, mid_z,
            right_x, right_y, right_z,
            up_x, up_y, up_z,
            back_x, back_y, back_z,
            thickness, length, thickness,
            color_r, color_g, color_b,
            alpha,
            0,
        }
    }, source_vertices)
    if not mesh then
        return nil
    end

    local radius = thickness * 0.5
    local bounds = {
        min_x = math.min(ax, bx) - radius,
        min_y = math.min(ay, by) - radius,
        min_z = math.min(az, bz) - radius,
        max_x = math.max(ax, bx) + radius,
        max_y = math.max(ay, by) + radius,
        max_z = math.max(az, bz) + radius,
    }
    bounds.center_x = (bounds.min_x + bounds.max_x) * 0.5
    bounds.center_y = (bounds.min_y + bounds.max_y) * 0.5
    bounds.center_z = (bounds.min_z + bounds.max_z) * 0.5
    bounds.extent_x = (bounds.max_x - bounds.min_x) * 0.5
    bounds.extent_y = (bounds.max_y - bounds.min_y) * 0.5
    bounds.extent_z = (bounds.max_z - bounds.min_z) * 0.5
    bounds.radius = math.sqrt(
        bounds.extent_x * bounds.extent_x +
        bounds.extent_y * bounds.extent_y +
        bounds.extent_z * bounds.extent_z
    )
    local depth_bias, depth_compare = RBX._get_transparent_draw_depth_settings(self, {
        render_priority = 2,
        bounds = bounds,
        depth_bias = 0,
    })

    return {
        kind = "static",
        mesh = mesh,
        depth_bias = depth_bias,
        depth_compare = depth_compare,
        sort_x = mid_x,
        sort_y = mid_y,
        sort_z = mid_z,
        sort_id = 1000000 + (tonumber(index) or 0),
        render_priority = 2,
        bounds = bounds,
        source_part_id = "constraint|" .. tostring(index or 0),
        source_transparent_part = false,
    }
end

function expand_bounds_with_bounds(target, bounds)
    if not target or not bounds then
        return
    end

    target.min_x = math.min(target.min_x, bounds.min_x)
    target.min_y = math.min(target.min_y, bounds.min_y)
    target.min_z = math.min(target.min_z, bounds.min_z)
    target.max_x = math.max(target.max_x, bounds.max_x)
    target.max_y = math.max(target.max_y, bounds.max_y)
    target.max_z = math.max(target.max_z, bounds.max_z)
end

function expand_bounds_with_point(bounds, x, y, z)
    if not bounds then
        return
    end

    bounds.min_x = math.min(bounds.min_x, x)
    bounds.min_y = math.min(bounds.min_y, y)
    bounds.min_z = math.min(bounds.min_z, z)
    bounds.max_x = math.max(bounds.max_x, x)
    bounds.max_y = math.max(bounds.max_y, y)
    bounds.max_z = math.max(bounds.max_z, z)
end

function finalize_bounds(bounds)
    if not bounds or bounds.min_x == math.huge then
        return nil
    end

    local center_x = (bounds.min_x + bounds.max_x) * 0.5
    local center_y = (bounds.min_y + bounds.max_y) * 0.5
    local center_z = (bounds.min_z + bounds.max_z) * 0.5
    local extent_x = (bounds.max_x - bounds.min_x) * 0.5
    local extent_y = (bounds.max_y - bounds.min_y) * 0.5
    local extent_z = (bounds.max_z - bounds.min_z) * 0.5

    bounds.center_x = center_x
    bounds.center_y = center_y
    bounds.center_z = center_z
    bounds.extent_x = extent_x
    bounds.extent_y = extent_y
    bounds.extent_z = extent_z
    bounds.radius = math.sqrt(extent_x * extent_x + extent_y * extent_y + extent_z * extent_z)
    return bounds
end

function RBX._compute_visible_scene_bounds(opaque_chunks, transparent_items)
    local bounds = {
        min_x = math.huge,
        min_y = math.huge,
        min_z = math.huge,
        max_x = -math.huge,
        max_y = -math.huge,
        max_z = -math.huge,
    }

    local chunk_list = opaque_chunks or {}
    for i = 1, #chunk_list do
        local chunk = chunk_list[i]
        if chunk and chunk.bounds then
            expand_bounds_with_bounds(bounds, chunk.bounds)
        end
    end

    local item_list = transparent_items or {}
    for i = 1, #item_list do
        local item = item_list[i]
        if item and item.bounds then
            expand_bounds_with_bounds(bounds, item.bounds)
        end
    end

    return finalize_bounds(bounds)
end

function get_bounds_volume(bounds)
    if not bounds or bounds.min_x == math.huge then
        return 0
    end

    local dx = math.max(0, bounds.max_x - bounds.min_x)
    local dy = math.max(0, bounds.max_y - bounds.min_y)
    local dz = math.max(0, bounds.max_z - bounds.min_z)
    return dx * dy * dz
end

local TEXTURED_SHADER_VARIANT_ORDER = {
    textured_constant_unlit = 0,
    textured_basic_opaque = 1,
    textured_lit_nomaps = 2,
    textured_overlay_decal = 3,
    surface_overlay_fast = 4,
    textured_transparent = 4,
    textured_full_material = 5,
    textured_constant_debug = 6,
    mesh_debug_uv_checker = 7,
    mesh_debug_normal = 7,
    mesh_debug_tangent = 7,
    mesh_debug_bitangent = 7,
    mesh_debug_vertex_color = 7,
    mesh_debug_texture_only = 7,
    mesh_debug_material_only = 7,
    mesh_debug_winding = 7,
    mesh_debug_missing_texture = 7,
    mesh_debug_parent_color = 7,
    mesh_debug_seam = 7,
    textured_basic = 1,
    textured_lit = 2,
    textured_overlay = 3,
    textured_material = 5,
}

local TEXTURED_CULL_MODE_ORDER = {
    none = 0,
    back = 1,
    front = 2,
}

local function clear_array(list)
    for i = #list, 1, -1 do
        list[i] = nil
    end
end

function RBX._resolve_textured_shader_variant_id(item)
    if type(item) ~= "table" then
        return "textured_basic_opaque"
    end
    if type(item.shader_variant_id) == "string" and item.shader_variant_id ~= "" then
        return item.shader_variant_id
    end
    if item.overlay_pass == true then
        return "textured_overlay_decal"
    end
    if item.source_kind == "SurfaceGui" then
        return "textured_overlay_decal"
    end
    if item.source_transparent_part == true or item.transparent == true or item.alpha_blended == true then
        return "textured_transparent"
    end
    if item.use_material_maps or item.use_normal_map then
        return "textured_full_material"
    end
    if item.use_textured_lighting == false or (tonumber(item.light_influence) or 1) <= 0 then
        return "textured_constant_unlit"
    end
    if item.use_textured_lighting ~= false then
        return "textured_lit_nomaps"
    end
    return "textured_basic_opaque"
end

function RBX._get_textured_state_sort_key(item)
    local variant_id = RBX._resolve_textured_shader_variant_id(item)
    local cull_mode = (type(item) == "table" and (item.resolved_cull_mode or item.cull_mode)) or "none"
    local depth_compare = type(item) == "table" and item.depth_compare or "less"
    local texture_group_key = type(item) == "table" and item.texture_group_key or nil
    local uniform_state_key = type(item) == "table" and item.uniform_state_key or nil
    local depth_compare_order = depth_compare == "always" and "2" or (depth_compare == "lequal" and "1" or "0")

    return string.format(
        "%d|%d|%s|%s|%s",
        TEXTURED_SHADER_VARIANT_ORDER[variant_id] or 9,
        TEXTURED_CULL_MODE_ORDER[cull_mode] or 9,
        depth_compare_order,
        tostring(texture_group_key or ""),
        tostring(uniform_state_key or "")
    )
end

local VISIBLE_SIGNATURE_MOD = 2147483647
local VISIBLE_SIGNATURE_MULTIPLIER = 131
local TEXTURED_SOURCE_MERGE_MAX_LISTS = 8
local TEXTURED_SOURCE_MERGE_MAX_BATCHES = 256

local function textured_batch_less(a, b)
    local ap = a.render_priority or 0
    local bp = b.render_priority or 0
    if ap ~= bp then
        return ap < bp
    end

    local av = a.state_sort_variant_order
    local bv = b.state_sort_variant_order
    if av ~= nil and bv ~= nil then
        if av ~= bv then
            return av < bv
        end
        local ac = a.state_sort_cull_order or 0
        local bc = b.state_sort_cull_order or 0
        if ac ~= bc then
            return ac < bc
        end
        local ad = a.state_sort_depth_order or 0
        local bd = b.state_sort_depth_order or 0
        if ad ~= bd then
            return ad < bd
        end
        local at = a.texture_group_sort_token or 0
        local bt = b.texture_group_sort_token or 0
        if at ~= bt then
            return at < bt
        end
        local au = a.uniform_state_sort_token or 0
        local bu = b.uniform_state_sort_token or 0
        if au ~= bu then
            return au < bu
        end
        return (a.stable_sort_id or 0) < (b.stable_sort_id or 0)
    end

    local akey = a.state_sort_key or RBX._get_textured_state_sort_key(a)
    local bkey = b.state_sort_key or RBX._get_textured_state_sort_key(b)
    if akey ~= bkey then
        return akey < bkey
    end
    return tostring(a.key or "") < tostring(b.key or "")
end

local function sort_textured_draw_items(items)
    table.sort(items, textured_batch_less)
end

local function opaque_candidate_less(a, b)
    local ap = a._sort_depth or 1
    local bp = b._sort_depth or 1
    if math.abs(ap - bp) <= 1e-6 then
        if a._distance2 == b._distance2 then
            return tostring(a.key) < tostring(b.key)
        end
        return (a._distance2 or 0) < (b._distance2 or 0)
    end
    return ap < bp
end

local function occluder_projection_less(a, b)
    local ap = a.near_depth or 1
    local bp = b.near_depth or 1
    if math.abs(ap - bp) <= 1e-6 then
        return (a.area or 0) > (b.area or 0)
    end
    return ap < bp
end

local function mix_visible_signature(hash, value)
    return ((hash * VISIBLE_SIGNATURE_MULTIPLIER) + (tonumber(value) or 0)) % VISIBLE_SIGNATURE_MOD
end

local function get_transparent_item_signature(item)
    local signature = tonumber(item and item.sort_id) or tonumber(item and item.source_part_id) or 0
    signature = signature + ((tonumber(item and item.render_priority) or 0) * 131)
    if item and item.source_kind == "SurfaceGui" then
        signature = signature + 17
    end
    if item and item.depth_compare == "always" then
        signature = signature + 31
    elseif item and item.depth_compare == "lequal" then
        signature = signature + 13
    end
    return signature % VISIBLE_SIGNATURE_MOD
end

local function heap_sift_up(heap, index)
    while index > 1 do
        local parent = math.floor(index * 0.5)
        if not textured_batch_less(heap[index].batch, heap[parent].batch) then
            break
        end
        heap[index], heap[parent] = heap[parent], heap[index]
        index = parent
    end
end

local function heap_sift_down(heap, index)
    local count = #heap
    while true do
        local left = index * 2
        if left > count then
            break
        end
        local right = left + 1
        local next_index = left
        if right <= count and textured_batch_less(heap[right].batch, heap[left].batch) then
            next_index = right
        end
        if not textured_batch_less(heap[next_index].batch, heap[index].batch) then
            break
        end
        heap[index], heap[next_index] = heap[next_index], heap[index]
        index = next_index
    end
end

local function advance_visible_textured_source(renderer, source, batch_is_visible)
    local batches = source and source.batches or nil
    if type(batches) ~= "table" then
        return false
    end
    local index = source.index or 1
    while index <= #batches do
        local batch = batches[index]
        if batch.source_kind ~= "SurfaceGui" or batch_is_visible(batch) then
            source.index = index
            source.batch = batch
            return true
        end
        index = index + 1
    end
    source.index = index
    source.batch = nil
    return false
end

local function merge_visible_textured_sources(renderer, source_lists, out_batches, visible_surface_gui_batches, visible_surface_gui_batch_count, heap, source_states, batch_is_visible)
    clear_array(heap)
    local source_count = #source_lists
    for list_index = 1, source_count do
        local source = source_states[list_index] or {}
        source.batches = source_lists[list_index]
        source.index = 1
        source.batch = nil
        source_states[list_index] = source
        if advance_visible_textured_source(renderer, source, batch_is_visible) then
            heap[#heap + 1] = source
            heap_sift_up(heap, #heap)
        end
    end

    while #heap > 0 do
        local source = heap[1]
        local batch = source.batch
        out_batches[#out_batches + 1] = batch
        if batch.source_kind == "SurfaceGui" then
            visible_surface_gui_batches[#visible_surface_gui_batches + 1] = batch
            visible_surface_gui_batch_count = visible_surface_gui_batch_count + 1
        end

        source.index = (source.index or 1) + 1
        if advance_visible_textured_source(renderer, source, batch_is_visible) then
            heap[1] = source
        else
            local last = heap[#heap]
            heap[#heap] = nil
            if #heap > 0 then
                heap[1] = last
            end
        end
        if #heap > 0 then
            heap_sift_down(heap, 1)
        end
    end

    return visible_surface_gui_batch_count
end

local function collect_visible_textured_batches_flat(renderer, source_lists, out_batches, visible_surface_gui_batches, visible_surface_gui_batch_count, batch_is_visible)
    for list_index = 1, #source_lists do
        local batches = source_lists[list_index] or {}
        for batch_index = 1, #batches do
            local batch = batches[batch_index]
            if batch.source_kind ~= "SurfaceGui" or batch_is_visible(batch) then
                out_batches[#out_batches + 1] = batch
                if batch.source_kind == "SurfaceGui" then
                    visible_surface_gui_batches[#visible_surface_gui_batches + 1] = batch
                    visible_surface_gui_batch_count = visible_surface_gui_batch_count + 1
                end
            end
        end
    end
    sort_textured_draw_items(out_batches)
    return visible_surface_gui_batch_count
end

local function merge_or_collect_visible_textured_sources(renderer, source_lists, out_batches, visible_surface_gui_batches, visible_surface_gui_batch_count, heap, source_states, batch_is_visible)
    local source_count = #source_lists
    local total_batch_count = 0
    for list_index = 1, source_count do
        total_batch_count = total_batch_count + #(source_lists[list_index] or {})
    end
    if source_count > TEXTURED_SOURCE_MERGE_MAX_LISTS or total_batch_count > TEXTURED_SOURCE_MERGE_MAX_BATCHES then
        return collect_visible_textured_batches_flat(
            renderer,
            source_lists,
            out_batches,
            visible_surface_gui_batches,
            visible_surface_gui_batch_count,
            batch_is_visible
        )
    end
    return merge_visible_textured_sources(
        renderer,
        source_lists,
        out_batches,
        visible_surface_gui_batches,
        visible_surface_gui_batch_count,
        heap,
        source_states,
        batch_is_visible
    )
end

local function choose_bvh_axis(bounds)
    if not bounds then
        return "x"
    end

    local extent_x = bounds.extent_x or math.max(0, (bounds.max_x or 0) - (bounds.min_x or 0))
    local extent_y = bounds.extent_y or math.max(0, (bounds.max_y or 0) - (bounds.min_y or 0))
    local extent_z = bounds.extent_z or math.max(0, (bounds.max_z or 0) - (bounds.min_z or 0))

    if extent_y >= extent_x and extent_y >= extent_z then
        return "y"
    end
    if extent_z >= extent_x and extent_z >= extent_y then
        return "z"
    end
    return "x"
end

local function aggregate_occlusion_fill_ratio(bounds, opaque_volume, face_area_xy, face_area_xz, face_area_yz)
    if not bounds then
        return 0
    end

    local bounds_volume = get_bounds_volume(bounds)
    local volume_fill = 0
    if bounds_volume > 1e-6 then
        volume_fill = clamp((opaque_volume or 0) / bounds_volume, 0, 1)
    end

    local bounds_width = math.max(0.001, bounds.max_x - bounds.min_x)
    local bounds_height = math.max(0.001, bounds.max_y - bounds.min_y)
    local bounds_depth = math.max(0.001, bounds.max_z - bounds.min_z)
    local face_fill = math.max(
        clamp((face_area_xy or 0) / (bounds_width * bounds_height), 0, 1),
        clamp((face_area_xz or 0) / (bounds_width * bounds_depth), 0, 1),
        clamp((face_area_yz or 0) / (bounds_height * bounds_depth), 0, 1)
    )

    return math.max(volume_fill, face_fill)
end

local OCCLUSION_SKIP_MATERIAL_TOKENS = {
    [1568] = true, -- Glass (Ice is 1536)
}

local function material_can_occlude(part)
    local token = math.floor((tonumber(part and part.Material) or 0) + 0.5)
    return OCCLUSION_SKIP_MATERIAL_TOKENS[token] ~= true
end


local function add_chunk_occluder_candidate(renderer, chunk, part, bounds, width, height, depth, render_geometry_key,
                                            allow_block_fallback, mesh_rendered, has_part_texture)
    if not renderer or not chunk or not part or not bounds then
        return false
    end
    if renderer.enable_part_occlusion_culling == false then
        return false
    end
    if chunk.dynamic_chunk == true or part.Anchored ~= true then
        return false
    end
    if render_geometry_key ~= "Block" or allow_block_fallback == false or mesh_rendered == true then
        return false
    end
    if has_part_texture == true or not material_can_occlude(part) then
        return false
    end

    local sx = math.max(0.001, tonumber(width) or 0)
    local sy = math.max(0.001, tonumber(height) or 0)
    local sz = math.max(0.001, tonumber(depth) or 0)
    local min_extent = math.min(sx, sy, sz)
    local max_extent = math.max(sx, sy, sz)
    local mid_extent = sx + sy + sz - min_extent - max_extent
    local min_thickness = math.max(0, tonumber(renderer.occlusion_min_thickness) or 0)
    local min_size = math.max(0, tonumber(renderer.occlusion_min_occluder_size) or 0)
    if min_extent < min_thickness or max_extent < min_size or mid_extent < min_size then
        return false
    end

    local candidate = {
        bounds = bounds,
        min_extent = min_extent,
        mid_extent = mid_extent,
        max_extent = max_extent,
        part_id = part._id,
        chunk_key = chunk.key,
    }
    local candidates = chunk.occluder_candidates
    candidates[#candidates + 1] = candidate
    chunk.occluder_candidate_count = (chunk.occluder_candidate_count or 0) + 1
    return true
end

local function build_scene_chunk_bvh(chunks)
    local count = #chunks
    if count <= 0 then
        return nil
    end

    local node_bounds = {
        min_x = math.huge,
        min_y = math.huge,
        min_z = math.huge,
        max_x = -math.huge,
        max_y = -math.huge,
        max_z = -math.huge,
    }
    local has_opaque_geometry = false
    local has_transparent_geometry = false
    local opaque_part_count = 0
    local transparent_part_count = 0
    local opaque_chunk_count = 0
    local opaque_volume = 0
    local opaque_face_area_xy = 0
    local opaque_face_area_xz = 0
    local opaque_face_area_yz = 0

    for i = 1, count do
        local chunk = chunks[i]
        if chunk and chunk.bounds then
            expand_bounds_with_bounds(node_bounds, chunk.bounds)
        end
        if chunk and chunk.has_opaque_geometry then
            has_opaque_geometry = true
            opaque_chunk_count = opaque_chunk_count + 1
            opaque_part_count = opaque_part_count + (chunk.opaque_part_count or 0)
            opaque_volume = opaque_volume + (chunk.opaque_volume or 0)
            opaque_face_area_xy = opaque_face_area_xy + (chunk.opaque_face_area_xy or 0)
            opaque_face_area_xz = opaque_face_area_xz + (chunk.opaque_face_area_xz or 0)
            opaque_face_area_yz = opaque_face_area_yz + (chunk.opaque_face_area_yz or 0)
        end
        if chunk and chunk.has_transparent_geometry then
            has_transparent_geometry = true
            transparent_part_count = transparent_part_count + (chunk.transparent_part_count or 0)
        end
    end

    local bounds = finalize_bounds(node_bounds)
    local node = {
        bounds = bounds,
        has_opaque_geometry = has_opaque_geometry,
        has_transparent_geometry = has_transparent_geometry,
        opaque_part_count = opaque_part_count,
        transparent_part_count = transparent_part_count,
        opaque_chunk_count = opaque_chunk_count,
        occlusion_fill_ratio = aggregate_occlusion_fill_ratio(
            bounds,
            opaque_volume,
            opaque_face_area_xy,
            opaque_face_area_xz,
            opaque_face_area_yz
        ),
    }

    if count <= 6 then
        node.chunks = chunks
        return node
    end

    local axis = choose_bvh_axis(bounds)
    local center_key = "center_" .. axis
    table.sort(chunks, function(a, b)
        local av = (a and a.bounds and a.bounds[center_key]) or 0
        local bv = (b and b.bounds and b.bounds[center_key]) or 0
        if av == bv then
            return tostring(a and a.key or "") < tostring(b and b.key or "")
        end
        return av < bv
    end)

    local split = math.floor(count * 0.5)
    local left_chunks = {}
    local right_chunks = {}
    for i = 1, split do
        left_chunks[i] = chunks[i]
    end
    for i = split + 1, count do
        right_chunks[#right_chunks + 1] = chunks[i]
    end

    node.left = build_scene_chunk_bvh(left_chunks)
    node.right = build_scene_chunk_bvh(right_chunks)
    return node
end

function get_spatial_chunk_coords(cell_size, x, y, z)
    local safe_cell_size = math.max(1, tonumber(cell_size) or 64)
    return math.floor(x / safe_cell_size),
        math.floor(y / safe_cell_size),
        math.floor(z / safe_cell_size)
end

function get_spatial_chunk_key(cx, cy, cz)
    return tostring(cx) .. "|" .. tostring(cy) .. "|" .. tostring(cz)
end

UNIT_PART_BOUNDS = {
    min_x = -0.5,
    min_y = -0.5,
    min_z = -0.5,
    max_x = 0.5,
    max_y = 0.5,
    max_z = 0.5,
}

function apply_local_offset(px, py, pz, rx, ry, rz, ux, uy, uz, bx, by, bz, ox, oy, oz)
    return px + rx * ox + ux * oy + bx * oz,
        py + ry * ox + uy * oy + by * oz,
        pz + rz * ox + uz * oy + bz * oz
end

function get_special_mesh_primitive_shape(part)
    if type(part) ~= "table" then
        return nil
    end
    if part.MeshOwner == "CylinderMesh" then
        return "Cylinder"
    end
    if part.MeshOwner == "BlockMesh" then
        return "Block"
    end
    if part.MeshOwner ~= "SpecialMesh" then
        return nil
    end
    local mesh_type = normalize_special_mesh_type(part.SpecialMeshType, part.MeshId)
    return RBX.SPECIAL_MESH_TYPE_ENUM.primitive_shapes[mesh_type]
end

function get_runtime_part_render_basis(part)
    local px, py, pz,
    right_x, right_y, right_z,
    up_x, up_y, up_z,
    back_x, back_y, back_z,
    sx, sy, sz = get_runtime_part_basis(part)

    local special_shape = get_special_mesh_primitive_shape(part)
    local special_mesh_type = part.MeshOwner == "SpecialMesh"
        and normalize_special_mesh_type(part.SpecialMeshType, part.MeshId)
        or nil
    local shape = special_shape or normalize_part_shape(part.Shape, part.ClassName)
    local scale_x = 1
    local scale_y = 1
    local scale_z = 1

    if special_shape and part.SpecialMeshOffset then
        local ox = part.SpecialMeshOffset.x or 0
        local oy = part.SpecialMeshOffset.y or 0
        local oz = part.SpecialMeshOffset.z or 0
        px, py, pz = apply_local_offset(
            px, py, pz,
            right_x, right_y, right_z,
            up_x, up_y, up_z,
            back_x, back_y, back_z,
            ox, oy, oz
        )
    end

    if special_shape then
        local scale = RBX._get_effective_special_mesh_scale(part, special_mesh_type)
        scale_x = scale.x or 1
        scale_y = scale.y or 1
        scale_z = scale.z or 1
    end

    if special_shape then
        -- DataModelMesh.Scale is applied to the parent Size first. Cylinder
        -- variants then preserve a circular radial section by copying the lower
        -- absolute scaled radial extent to both radial axes. this ordering matters
        -- for non-uniform Scale: native Studio 0.735 renders
        --   SpecialMesh Cylinder Size(2,10,4) Scale(3,.5,2) as (6,5,5), and
        --   CylinderMesh Size(4,6,3) Scale(.5,2,3) as (2,12,2)
        -- the former is X-aligned, legacy CylinderMesh is Y-aligned. preserve each
        -- scale sign so authored negative-axis mirrors retain their handedness
        sx = sx * scale_x
        sy = sy * scale_y
        sz = sz * scale_z
        if special_mesh_type == "Cylinder" then
            local radial = math.min(math.abs(sy), math.abs(sz))
            sy = sy < 0 and -radial or radial
            sz = sz < 0 and -radial or radial
        elseif part.MeshOwner == "CylinderMesh" then
            local radial = math.min(math.abs(sx), math.abs(sz))
            sx = sx < 0 and -radial or radial
            sz = sz < 0 and -radial or radial
        end
    elseif shape == "Cylinder" then
        local radius = math.min(math.abs(sy), math.abs(sz))
        sx = sx * scale_x
        sy = radius * scale_y
        sz = radius * scale_z
    elseif shape == "Ball" then
        local diameter = math.min(math.abs(sx), math.abs(sy), math.abs(sz))
        sx = diameter * scale_x
        sy = diameter * scale_y
        sz = diameter * scale_z
    else
        sx = sx * scale_x
        sy = sy * scale_y
        sz = sz * scale_z
    end

    return px, py, pz,
        right_x, right_y, right_z,
        up_x, up_y, up_z,
        back_x, back_y, back_z,
        sx, sy, sz
end

function should_apply_part_tint(part, mesh_data)
    if type(part) ~= "table" then
        return true
    end
    if is_csg_part_class(part.ClassName) and part.UsePartColor == false then
        local has_vertex_colors = type(mesh_data) == "table"
            and type(mesh_data.colors) == "table"
            and #mesh_data.colors > 0
        if has_vertex_colors then
            return false
        end
    end
    return true
end

function should_use_mesh_vertex_colors(part, mesh_data)
    if type(mesh_data) ~= "table" or type(mesh_data.colors) ~= "table" or #mesh_data.colors == 0 then
        return false
    end
    if is_csg_part_class(part and part.ClassName) then
        return part.UsePartColor == false
    end
    return mesh_data.use_vertex_colors == true
end

local GLASS_MATERIAL_TOKEN = 1568
local IGNORE_MESH_VERTEX_COLOR_OPTIONS = { ignore_mesh_vertex_color = true }
local MESH_TEXTURE_VERTEX_COLOR_OPTIONS = { mesh_texture_uses_vertex_color = true }

function is_glass_material(part)
    if type(part) ~= "table" then
        return false
    end
    local material = tonumber(part.Material)
    return material ~= nil and math.floor(material + 0.5) == GLASS_MATERIAL_TOKEN
end

function get_runtime_render_color(part, apply_part_tint, options)
    local r, g, b = 1, 1, 1
    local override = type(part) == "table" and part._render_color_override or nil
    if type(override) == "table" then
        return authored_color3_to_gpu(
            clamp(override[1] or override.r or 1, 0, 1),
            clamp(override[2] or override.g or 1, 0, 1),
            clamp(override[3] or override.b or 1, 0, 1)
        )
    end

    local use_part_tint = apply_part_tint
    if use_part_tint == nil then
        use_part_tint = true
    end

    if use_part_tint then
        local color = type(part) == "table" and part.Color or nil
        color = color or { r = 1, g = 1, b = 1 }
        r = clamp(color.r or 1, 0, 1)
        g = clamp(color.g or 1, 0, 1)
        b = clamp(color.b or 1, 0, 1)
        if is_glass_material(part) then
            -- these coefficients are authored display-space values. preserve the
            -- established glass look, then cross the GPU boundary once
            r = clamp(r * 0.50 + 0.35, 0, 1)
            g = clamp(g * 0.50 + 0.39, 0, 1)
            b = clamp(b * 0.50 + 0.45, 0, 1)
        end
    end

    local vertex_color = type(part) == "table" and part.MeshVertexColor or nil
    if not vertex_color and type(part) == "table"
        and (part.MeshOwner == "SpecialMesh" or part.MeshOwner == "CylinderMesh") then
        vertex_color = part.SpecialMeshVertexColor
    end

    if type(options) == "table" then
        if options.mesh_texture_uses_vertex_color then
            if vertex_color then
                return authored_color3_to_gpu(
                    clamp(vertex_color.r or 1, 0, 1),
                    clamp(vertex_color.g or 1, 0, 1),
                    clamp(vertex_color.b or 1, 0, 1)
                )
            end
            return 1, 1, 1
        end
        if options.ignore_mesh_vertex_color then
            vertex_color = nil
        end
    end

    r, g, b = authored_color3_to_gpu(r, g, b)
    if vertex_color then
        local vertex_r, vertex_g, vertex_b = authored_color3_to_gpu(
            clamp(vertex_color.r or 1, 0, 1),
            clamp(vertex_color.g or 1, 0, 1),
            clamp(vertex_color.b or 1, 0, 1)
        )
        r = clamp(r * vertex_r, 0, 1)
        g = clamp(g * vertex_g, 0, 1)
        b = clamp(b * vertex_b, 0, 1)
    end

    return r, g, b
end

RBX._get_runtime_render_color = get_runtime_render_color

-- Runtime-local opacity is continuous, it is never reconstructed from RGB bytes
function get_runtime_part_opacity(part)
    if type(part) ~= "table" then return 1 end
    return (1 - clamp(tonumber(part.Transparency) or 0, 0, 1))
        * (1 - clamp(tonumber(part.LocalTransparencyModifier) or 0, 0, 1))
end
RBX._get_runtime_part_opacity = get_runtime_part_opacity

function get_runtime_render_alpha(part)
    if type(part) ~= "table" then
        return 1
    end
    local alpha = get_runtime_part_opacity(part)
    if alpha > 0 then
        local descriptor = MaterialRegistry.get(part.Material)
        local material_transparency = descriptor
            and clamp(tonumber(descriptor.translucent) or 0, 0, 1) or 0
        alpha = math.min(alpha, 1 - material_transparency)
    end
    return alpha
end

function get_runtime_render_reflectance(part)
    if type(part) ~= "table" then
        return 0
    end
    local reflectance = clamp(tonumber(part.Reflectance) or 0, 0, 1)
    if is_glass_material(part) then
        reflectance = math.max(reflectance, 0.10)
    end
    return reflectance
end

RBX._is_glass_material = is_glass_material
RBX._get_runtime_render_alpha = get_runtime_render_alpha
RBX._get_runtime_render_reflectance = get_runtime_render_reflectance

function get_runtime_part_shape(part)
    if type(part) ~= "table" then
        return "Block"
    end
    return get_special_mesh_primitive_shape(part) or normalize_part_shape(part.Shape, part.ClassName)
end

function get_runtime_part_render_geometry_key(part)
    local shape = get_runtime_part_shape(part)
    if type(part) == "table" and part.MeshOwner == "CylinderMesh" and shape == "Cylinder" then
        return "CylinderY"
    end
    return shape
end

local function special_mesh_submits_no_render_geometry(part)
    return type(part) == "table"
        and part.MeshOwner == "SpecialMesh"
        and get_runtime_part_render_geometry_key(part) == "None"
end

local function legacy_mesh_asset_owns_geometry(part)
    if type(part) ~= "table" or part.MeshOwner ~= "SpecialMesh" then
        return false
    end
    local mesh_type = normalize_special_mesh_type(part.SpecialMeshType, part.MeshId)
    return mesh_type == "Head" or mesh_type == "FileMesh"
end

RBX._get_runtime_part_render_basis = get_runtime_part_render_basis
RBX._get_runtime_part_shape = get_runtime_part_shape
RBX._get_runtime_part_render_geometry_key = get_runtime_part_render_geometry_key
RBX._special_mesh_submits_no_render_geometry =
    special_mesh_submits_no_render_geometry
RBX._legacy_mesh_asset_owns_geometry = legacy_mesh_asset_owns_geometry

function runtime_part_to_instance(part)
    local px, py, pz,
    right_x, right_y, right_z,
    up_x, up_y, up_z,
    back_x, back_y, back_z,
    sx, sy, sz = get_runtime_part_render_basis(part)

    local alpha = get_runtime_render_alpha(part)
    local reflectance = get_runtime_render_reflectance(part)
    local color_r, color_g, color_b = get_runtime_render_color(part, should_apply_part_tint(part))

    return {
        px, py, pz,
        right_x, right_y, right_z,
        up_x, up_y, up_z,
        back_x, back_y, back_z,
        sx, sy, sz,
        color_r, color_g, color_b, alpha,
        reflectance,
        clamp(tonumber(part._contact_ao_top) or 0, 0, 1),
        clamp(tonumber(part._contact_ao_bottom) or 0, 0, 1),
        clamp(tonumber(part._contact_ao_side) or 0, 0, 1),
        clamp(tonumber(part._contact_ao_max) or 0, 0, 1)
    }
end

local function create_empty_bounds()
    return {
        min_x = math.huge,
        min_y = math.huge,
        min_z = math.huge,
        max_x = -math.huge,
        max_y = -math.huge,
        max_z = -math.huge,
    }
end

local function queue_chunk_transparent_static_part(renderer, chunk, part, part_index, render_geometry_key,
                                                   part_bounds, part_width, part_height, part_depth,
                                                   is_glass_part)
    if type(renderer) ~= "table" or type(chunk) ~= "table" or type(part) ~= "table" then
        return false
    end
    if type(render_geometry_key) ~= "string" or render_geometry_key == "" then
        return false
    end

    local buckets = chunk.transparent_static_shape_instances
    if not buckets then
        buckets = {}
        chunk.transparent_static_shape_instances = buckets
    end
    local groups = chunk.transparent_static_shape_groups
    if not groups then
        groups = {}
        chunk.transparent_static_shape_groups = groups
    end

    local bucket = buckets[render_geometry_key]
    local group = groups[render_geometry_key]
    if not bucket then
        bucket = {}
        buckets[render_geometry_key] = bucket
        group = {
            bounds = create_empty_bounds(),
            source_transparent_part_ids = {},
            source_glass_part_ids = {},
            sort_id = part._id or part_index or 0,
            thin_surface = false,
            is_glass_part = false,
        }
        groups[render_geometry_key] = group
    end

    bucket[#bucket + 1] = runtime_part_to_instance(part)
    expand_bounds_with_bounds(group.bounds, part_bounds)
    local part_id = part._id or part_index
    group.source_transparent_part_ids[#group.source_transparent_part_ids + 1] = part_id
    if is_glass_part then
        group.is_glass_part = true
        group.source_glass_part_ids[#group.source_glass_part_ids + 1] = part_id
    end
    group.sort_id = math.min(tonumber(group.sort_id) or 0, tonumber(part_id) or 0)
    group.thin_surface = group.thin_surface or (math.min(part_width, part_height, part_depth) <=
        math.max(0.08, math.max(part_width, part_height, part_depth) * 0.08))
    return true
end

local function build_chunk_transparent_static_draw_items(renderer, chunk)
    local buckets = chunk and chunk.transparent_static_shape_instances
    local groups = chunk and chunk.transparent_static_shape_groups
    if type(renderer) ~= "table" or type(chunk) ~= "table" or type(buckets) ~= "table" then
        return 0, 0
    end

    local batch_count = 0
    local batched_part_count = 0
    for render_geometry_key, instances in pairs(buckets) do
        if type(instances) == "table" and #instances > 0 then
            local source_vertices = renderer._primitive_vertices and renderer._primitive_vertices[render_geometry_key]
                or renderer._cube_vertices
            local mesh = build_static_mesh(renderer, instances, source_vertices)
            if mesh then
                local group = groups and groups[render_geometry_key] or nil
                local bounds = finalize_bounds(group and group.bounds)
                local depth_bias, depth_compare = RBX._get_transparent_draw_depth_settings(renderer, {
                    render_priority = 0,
                    bounds = bounds,
                    thin_surface = group and group.thin_surface == true,
                })
                local sort_x = bounds and bounds.center_x or chunk.grid_x or 0
                local sort_y = bounds and bounds.center_y or chunk.grid_y or 0
                local sort_z = bounds and bounds.center_z or chunk.grid_z or 0
                chunk.transparent_draw_items[#chunk.transparent_draw_items + 1] = {
                    kind = "static",
                    mesh = mesh,
                    key = render_geometry_key,
                    depth_bias = depth_bias,
                    depth_compare = depth_compare,
                    sort_x = sort_x,
                    sort_y = sort_y,
                    sort_z = sort_z,
                    sort_id = group and group.sort_id or batch_count,
                    render_priority = 0,
                    bounds = bounds,
                    source_part_id = group and group.source_transparent_part_ids
                        and group.source_transparent_part_ids[1] or nil,
                    source_transparent_part = true,
                    source_transparent_part_ids = group and group.source_transparent_part_ids or nil,
                    source_glass_part_ids = group and group.source_glass_part_ids or nil,
                    is_glass_part = group and group.is_glass_part == true,
                    transparent_static_batch = true,
                    transparent_static_part_count = #instances,
                }
                batch_count = batch_count + 1
                batched_part_count = batched_part_count + #instances
            end
        end
    end

    chunk.transparent_static_shape_instances = nil
    chunk.transparent_static_shape_groups = nil
    return batch_count, batched_part_count
end

function RBX._transparent_textured_uniform_state_key(
    base_key, effective_depth_bias, effective_depth_compare)
    -- Transparent batch construction can replace the source batch's depth
    -- settings (notably for thin surfaces). the draw loops and per-shader cache
    -- both use this key as an early-return contract, so it must describe the
    -- effective values rather than the pre-derived batch values
    return table.concat({
        tostring(base_key or ""),
        "|transparent-depth-bias:",
        string.format("%.17g", tonumber(effective_depth_bias) or 0),
        "|transparent-depth-compare:",
        tostring(effective_depth_compare or "less"),
    })
end

local function refresh_remote_transparent_texture_item(renderer)
    renderer._textured_uniform_states = nil
    return true
end
RBX._refresh_remote_transparent_texture_item =
    refresh_remote_transparent_texture_item

local function append_chunk_transparent_textured_draw_items(renderer, chunk)
    local batch_map = chunk and chunk.transparent_textured_batch_map
    if type(renderer) ~= "table" or type(chunk) ~= "table" or type(batch_map) ~= "table" then
        return 0, 0
    end

    -- keep the already-baked CPU payload only until the first sorted
    -- transparent frame.  the range aggregator can then replace several
    -- source meshes with one order-preserving mesh without reading vertices
    -- back from the GPU. Dynamic chunks are deliberately excluded: their
    -- geometry can move independently and already has its own fast-rebake
    -- lifecycle
    local capture_cpu =
        renderer.enable_transparent_textured_range_aggregation ~= false
        and chunk.dynamic_chunk ~= true
    capture_cpu = capture_cpu or require('engine/graphics/rbx/runtime/retained_primitive_decal').needs_rows(renderer,chunk)
    local batches = renderer:_build_textured_batches_from_map(
        batch_map, nil, nil, capture_cpu, false,
        chunk.dynamic_chunk == true and 'dynamic' or 'static')
    local batch_count = 0
    local batched_part_count = 0
    for index = 1, #batches do
        local batch = batches[index]
        local depth_bias, depth_compare = RBX._get_transparent_draw_depth_settings(renderer, batch)
        if batch._material_pose_recipe then
            batch._material_pose_recipe.depth_bias = batch.depth_bias
            batch._material_pose_recipe.uniform_base = batch.uniform_state_key or batch.key
        end
        local source_ids = batch.source_transparent_part_ids
        local glass_ids = batch.source_glass_part_ids
        local shader_probe = {
            surface_appearance = batch.surface_appearance == true,
            surface_route = batch.surface_route,
            surface_part_alpha = batch.surface_part_alpha,
            use_material_maps = batch.use_material_maps == true,
            material_semantics_active =
                batch.material_semantics_active == true,
            use_textured_lighting = batch.use_textured_lighting ~= false,
            light_influence = batch.light_influence or 1,
            use_normal_map = batch.use_normal_map == true,
            ignore_texture_alpha = batch.ignore_texture_alpha and true or false,
            -- the static-transparent map already contains Decal, Texture,
            -- SurfaceGui, and SurfaceOverlay batches. Re-probing without these
            -- route fields downgraded every overlay to the generic straight-alpha
            -- shader before the correctly copied metadata below could be used
            source_kind = batch.source_kind,
            overlay_pass = batch.overlay_pass == true,
            source_transparent_part = true,
            transparent = true,
            shader_variant_id = "textured_transparent",
            mesh_debug_mode = batch.mesh_debug_mode,
            mesh_debug_mode_id = batch.mesh_debug_mode_id or 0,
            depth_compare = depth_compare,
        }
        local transparent_shader = renderer:_select_textured_shader_for_batch(shader_probe, true)
        local draw_item = {
            kind = "textured",
            mesh = batch.mesh,
            cpu_vertices = batch.cpu_vertices,
            _material_pose_recipe = batch._material_pose_recipe,
            vertex_count = batch.vertex_count,
            part_ranges = batch.part_ranges,
            texture = batch.texture,
            texture_group_key = batch.texture_group_key,
            remote_texture_handle = batch.remote_texture_handle,
            remote_normal_texture_handle =
                batch.remote_normal_texture_handle,
            remote_normal_texture_field =
                batch.remote_normal_texture_field,
            key = batch.key,
            uniform_state_key =
                RBX._transparent_textured_uniform_state_key(
                    batch.uniform_state_key or batch.key,
                    depth_bias,
                    depth_compare),
            flip_v = batch.flip_v,
            flip_u = batch.flip_u,
            use_material_maps = batch.use_material_maps,
            material_semantics_active =
                batch.material_semantics_active == true,
            material_surface = batch.material_surface,
            material_map_mask = batch.material_map_mask,
            use_textured_lighting = batch.use_textured_lighting,
            light_influence = batch.light_influence,
            brightness = batch.brightness,
            use_normal_map = batch.use_normal_map,
            normal_texture = batch.normal_texture,
            normal_key = batch.normal_key,
            detail_normal_texture = batch.detail_normal_texture,
            detail_normal_key = batch.detail_normal_key,
            detail_normal_mix = batch.detail_normal_mix,
            detail_contrast = batch.detail_contrast,
            texture_color_mix = batch.texture_color_mix,
            texture_premultiplied =
                batch.texture_premultiplied == true,
            vertex_color_premultiplied =
                batch.vertex_color_premultiplied == true,
            roughness_texture = batch.roughness_texture,
            metalness_texture = batch.metalness_texture,
            depth_bias = depth_bias,
            ignore_texture_alpha = batch.ignore_texture_alpha and true or false,
            cull_mode = batch.cull_mode or "none",
            mirror_cull_swap = batch.mirror_cull_swap ~= false,
            force_cull = batch.force_cull == true,
            resolved_cull_mode = batch.resolved_cull_mode,
            depth_compare = depth_compare,
            sort_x = batch.sort_x or (batch.bounds and batch.bounds.center_x) or chunk.grid_x or 0,
            sort_y = batch.sort_y or (batch.bounds and batch.bounds.center_y) or chunk.grid_y or 0,
            sort_z = batch.sort_z or (batch.bounds and batch.bounds.center_z) or chunk.grid_z or 0,
            sort_id = batch.stable_sort_id or index,
            render_priority = batch.render_priority or 0,
            bounds = batch.bounds,
            source_transparent_part = true,
            source_transparent_part_ids = source_ids,
            source_glass_part_ids = glass_ids,
            is_glass_part = batch.is_glass_part == true,
            transparent_static_batch = true,
            dynamic_chunk = chunk.dynamic_chunk == true,
            transparent_static_part_count = batch.transparent_static_part_count or (type(source_ids) == "table" and #source_ids or 0),
            shader_variant_id = shader_probe.shader_variant_id or "textured_transparent",
            uniform_layout_id = shader_probe.uniform_layout_id or "fast",
            shader = transparent_shader,
            shader_counter_key = shader_probe.shader_counter_key
                or renderer:_get_textured_shader_counter_key(transparent_shader),
            variant_counter_id = shader_probe.variant_counter_id,
            mesh_debug_mode = batch.mesh_debug_mode,
            mesh_debug_mode_id = batch.mesh_debug_mode_id,
            alpha_like = true,
            uses_shader_discard = batch.uses_shader_discard == true,
            source_kind = batch.source_kind,
            overlay_pass = batch.overlay_pass == true,
            -- Transparent primitive batches retain the GUI owner needed for
            -- visibility, canvas updates and public facade property changes
            surface_gui_ref = batch.surface_gui_ref,
            surface_gui_part_ref = batch.surface_gui_part_ref,
            surface_gui_z_offset = batch.surface_gui_z_offset,
            surface_gui_order = batch.surface_gui_order,
            surface_gui_face = batch.surface_gui_face,
            surface_gui_runtime_id = batch.surface_gui_runtime_id,
            surface_gui_max_distance = batch.surface_gui_max_distance,
            surface_gui_face_world_x = batch.surface_gui_face_world_x,
            surface_gui_face_world_y = batch.surface_gui_face_world_y,
            surface_gui_face_world_z = batch.surface_gui_face_world_z,
            surface_gui_face_normal_x = batch.surface_gui_face_normal_x,
            surface_gui_face_normal_y = batch.surface_gui_face_normal_y,
            surface_gui_face_normal_z = batch.surface_gui_face_normal_z,
            mesh_part_count = batch.mesh_part_count or 0,
            mesh_texture_hit_count = batch.mesh_texture_hit_count or 0,
            mesh_texture_miss_count = batch.mesh_texture_miss_count or 0,
            mesh_uv_missing_count = batch.mesh_uv_missing_count or 0,
            mesh_doublesided_count = batch.mesh_doublesided_count or 0,
            mesh_axis_conversion_count = batch.mesh_axis_conversion_count or 0,
            mesh_winding_flip_count = batch.mesh_winding_flip_count or 0,
            mesh_uv_flip_u_count = batch.mesh_uv_flip_u_count or 0,
            mesh_uv_flip_v_count = batch.mesh_uv_flip_v_count or 0,
            mesh_debug_axis_count = batch.mesh_debug_axis_count or 0,
            mesh_debug_bounds_count = batch.mesh_debug_bounds_count or 0,
            union_part_count = batch.union_part_count or 0,
            union_material_part_count = batch.union_material_part_count or 0,
            union_use_part_color_count = batch.union_use_part_color_count or 0,
            union_smoothing_angle_used_count = batch.union_smoothing_angle_used_count or 0,
            union_fallback_count = batch.union_fallback_count or 0,
            surface_detail_face_count = batch.surface_detail_face_count or 0,
            surface_studs_face_count = batch.surface_studs_face_count or 0,
            surface_inlet_face_count = batch.surface_inlet_face_count or 0,
            surface_universal_face_count = batch.surface_universal_face_count or 0,
            surface_shader_face_count = batch.surface_shader_face_count or 0,
            surface_geometry_face_count = batch.surface_geometry_face_count or 0,
            surface_lod_geometry_count = batch.surface_lod_geometry_count or 0,
            surface_lod_shader_count = batch.surface_lod_shader_count or 0,
            surface_fallback_count = batch.surface_fallback_count or 0,
            z_bias_overlay_count = batch.z_bias_overlay_count or 0,
            z_bias_decal_count = batch.z_bias_decal_count or 0,
            z_bias_surface_detail_count = batch.z_bias_surface_detail_count or 0,
            specialmesh_count = batch.specialmesh_count or 0,
            specialmesh_head_count = batch.specialmesh_head_count or 0,
            specialmesh_axis_fixup_count = batch.specialmesh_axis_fixup_count or 0,
            specialmesh_fallback_count = batch.specialmesh_fallback_count or 0,
        }
        RBX._copy_surface_appearance_fields(draw_item, batch)
        chunk.transparent_draw_items[#chunk.transparent_draw_items + 1] =
            draw_item
        if batch.remote_texture_handle then
            renderer:_bind_remote_texture_consumer(
                batch.remote_texture_handle, draw_item, {
                    role = "transparent_draw_item_texture",
                    texture_field = "texture",
                    resource_key_field = "texture_group_key",
                    uniform_state_key_field = "uniform_state_key",
                    mesh_field = "mesh",
                    callback = refresh_remote_transparent_texture_item,
                })
        end
        if batch.remote_normal_texture_handle then
            local texture_field = batch.remote_normal_texture_field
                or "normal_texture"
            renderer:_bind_remote_texture_consumer(
                batch.remote_normal_texture_handle, draw_item, {
                    role = "transparent_draw_item:" .. texture_field,
                    texture_field = texture_field,
                    resource_key_field = texture_field == "detail_normal_texture"
                        and "detail_normal_key" or "normal_key",
                    uniform_state_key_field = "uniform_state_key",
                    callback = refresh_remote_transparent_texture_item,
                })
        end
        renderer:_bind_surface_appearance_item_consumers(draw_item)
        batch_count = batch_count + 1
        batched_part_count = batched_part_count + (batch.transparent_static_part_count or 0)
    end
    chunk.transparent_textured_batch_map = nil
    return batch_count, batched_part_count
end

-- verbatim decode, engine world = roblox world, no z-mirror
local function convert_parsed_map_vector3(value)
    if type(value) ~= "table" then
        return nil
    end
    local x = tonumber(value.x or value.X or value[1])
    local y = tonumber(value.y or value.Y or value[2])
    local z = tonumber(value.z or value.Z or value[3])
    if x == nil and y == nil and z == nil then
        return nil
    end
    return Vector3.new(x or 0, y or 0, z or 0)
end

local function convert_parsed_map_cframe(value)
    if type(value) ~= "table" then
        return nil
    end
    local right_x = value.r00
    local right_y = value.r10
    local right_z = value.r20 or 0
    local up_x = value.r01
    local up_y = value.r11
    local up_z = value.r21 or 0
    local back_x = value.r02 or 0
    local back_y = value.r12 or 0
    local back_z = value.r22 or 1
    right_x, right_y, right_z = normalize_or_fallback(right_x, right_y, right_z, 1, 0, 0)
    up_x, up_y, up_z = normalize_or_fallback(up_x, up_y, up_z, 0, 1, 0)
    back_x, back_y, back_z = normalize_or_fallback(back_x, back_y, back_z, 0, 0, 1)
    return CFrame.from_matrix(
        tonumber(value.x or value.X) or 0,
        tonumber(value.y or value.Y) or 0,
        tonumber(value.z or value.Z) or 0,
        right_x, up_x, back_x,
        right_y, up_y, back_y,
        right_z, up_z, back_z
    )
end

function runtime_part_from_parsed(parsed, id)
    RBX._size_validation.parsed(parsed)
    local right_x = parsed.r00
    local right_y = parsed.r10
    local right_z = parsed.r20

    local up_x = parsed.r01
    local up_y = parsed.r11
    local up_z = parsed.r21

    local back_x = parsed.r02
    local back_y = parsed.r12
    local back_z = parsed.r22

    right_x, right_y, right_z = normalize_or_fallback(right_x, right_y, right_z, 1, 0, 0)
    up_x, up_y, up_z = normalize_or_fallback(up_x, up_y, up_z, 0, 1, 0)
    back_x, back_y, back_z = normalize_or_fallback(back_x, back_y, back_z, 0, 0, 1)

    local part = {
        _id = id,
        Name = parsed.name or ("Part" .. id),
        ClassName = parsed.class_name or "Part",
        Shape = normalize_part_shape(parsed.shape, parsed.class_name),
        CFrame = CFrame.from_matrix(
            parsed.x, parsed.y, parsed.z,
            right_x, up_x, back_x,
            right_y, up_y, back_y,
            right_z, up_z, back_z
        ),
        Size = {
            x = parsed.sx,
            y = parsed.sy,
            z = parsed.sz,
        },
        Color = {
            r = clamp(parsed.color_r / 255, 0, 1),
            g = clamp(parsed.color_g / 255, 0, 1),
            b = clamp(parsed.color_b / 255, 0, 1),
        },
        Transparency = clamp(tonumber(parsed.transparency) or (1 - (parsed.color_a / 255)), 0, 1),
        LocalTransparencyModifier = 0,
        Reflectance = clamp(parsed.reflectance or 0, 0, 1),
        Anchored = parsed.anchored == true,
        CanCollide = parsed.can_collide ~= false,
        CanTouch = parsed.can_touch ~= false,
        CanQuery = parsed.can_query ~= false,
        CastShadow = parsed.cast_shadow ~= false,
        CollisionGroup = parsed.collision_group or "Default",
        Massless = parsed.massless == true,
        RootPriority = tonumber(parsed.root_priority) or 0,
        CustomPhysicalProperties = clone_physical_properties_value(parsed.custom_physical_properties),
        Mass = 0,
        AssemblyMass = 0,
        AssemblyCenterOfMass = { x = parsed.x, y = parsed.y, z = parsed.z },
        AssemblyRootPart = nil,
        AssemblyShapeApproximation = nil,
        AssemblyLinearVelocity = convert_parsed_map_vector3(parsed.linear_velocity) or { x = 0, y = 0, z = 0 },
        AssemblyAngularVelocity = convert_parsed_map_vector3(parsed.angular_velocity) or { x = 0, y = 0, z = 0 },
        Material = parsed.material or 0,
        TopSurface = parsed.top_surface,
        BottomSurface = parsed.bottom_surface,
        LeftSurface = parsed.left_surface,
        RightSurface = parsed.right_surface,
        FrontSurface = parsed.front_surface,
        BackSurface = parsed.back_surface,
        TopSurfaceInput = tonumber(parsed.top_surface_input) or 0,
        BottomSurfaceInput = tonumber(parsed.bottom_surface_input) or 0,
        LeftSurfaceInput = tonumber(parsed.left_surface_input) or 0,
        RightSurfaceInput = tonumber(parsed.right_surface_input) or 0,
        FrontSurfaceInput = tonumber(parsed.front_surface_input) or 0,
        BackSurfaceInput = tonumber(parsed.back_surface_input) or 0,
        TopParamA = tonumber(parsed.top_param_a),
        TopParamB = tonumber(parsed.top_param_b),
        BottomParamA = tonumber(parsed.bottom_param_a),
        BottomParamB = tonumber(parsed.bottom_param_b),
        LeftParamA = tonumber(parsed.left_param_a),
        LeftParamB = tonumber(parsed.left_param_b),
        RightParamA = tonumber(parsed.right_param_a),
        RightParamB = tonumber(parsed.right_param_b),
        FrontParamA = tonumber(parsed.front_param_a),
        FrontParamB = tonumber(parsed.front_param_b),
        BackParamA = tonumber(parsed.back_param_a),
        BackParamB = tonumber(parsed.back_param_b),
        MeshId = parsed.mesh_id,
        TextureContent = parsed.texture_id,
        TextureId = parsed.texture_id,
        UsePartColor = parsed.use_part_color ~= false,
        DoubleSided = parsed.double_sided == true,
        SmoothingAngle = tonumber(parsed.smoothing_angle),
        RenderFidelity = parsed.render_fidelity,
        CollisionFidelity = parsed.collision_fidelity or "Default",
        PhysicsData = parsed.physics_data,
        PhysicalConfigData = parsed.physical_config_data,
        TriangleCount = tonumber(parsed.triangle_count),
        MaterialVariant = parsed.material_variant,
        SurfaceAppearance = RBX._clone_surface_appearance_descriptor(
            parsed.surface_appearance),
        MeshOwner = parsed.mesh_owner,
        SpecialMeshType = parsed.special_mesh_type,
        SpecialMeshScale = parsed.special_mesh_scale,
        SpecialMeshOffset = parsed.special_mesh_offset,
        SpecialMeshVertexColor = parsed.special_mesh_vertex_color,
        MeshVertexColor = parsed.mesh_vertex_color,
        FaceTextures = RBX._clone_face_texture_list(parsed.face_textures),
        SurfaceGuis = RBX._clone_surface_gui_list(parsed.surface_guis),
        BillboardGuis = RBX._clone_surface_gui_list(parsed.billboard_guis),
        BlockMeshScale = parsed.blockmesh_scale,
        BlockMeshOffset = parsed.blockmesh_offset,
        MeshSize = parsed.mesh_size and {
            x = parsed.mesh_size.x,
            y = parsed.mesh_size.y,
            z = parsed.mesh_size.z,
        } or nil,
        EmbeddedMeshData = parsed.embedded_mesh_data,
        EmbeddedMeshDataCandidates = RBX._clone_string_list(parsed.embedded_mesh_candidates),
        _map_referent = parsed.referent,
        _loaded_from_map = true,
        _runtime_dynamic = false,
        _initial_linear_velocity = convert_parsed_map_vector3(parsed.linear_velocity),
        _initial_angular_velocity = convert_parsed_map_vector3(parsed.angular_velocity),
        _initial_linear_velocity_source = parsed.linear_velocity_source,
        _initial_angular_velocity_source = parsed.angular_velocity_source,
        _embedded_mesh_cache = nil,
        _destroyed = false,
    }
    sync_runtime_part_velocity_aliases(part)
    return part
end

function RBX:_apply_loaded_runtime_part_coordinate_fix(part)
    if type(part) ~= "table" or getmetatable(part.CFrame) ~= CFrame then
        return part
    end

    if self.flip_loaded_map_horizontally == false then
        part._loaded_map_mirror_x = false
        sync_runtime_part_velocity_aliases(part)
        return part
    end

    part._loaded_map_mirror_x = true
    -- conjugation x*m*x, not one-sided x*m: stays a proper rotation (det+1) so meshparts render
    -- rotated not mirrored. see docs/physics_rewrite/collision_reliability.md
    part.CFrame = CFrame.from_matrix(
        -(part.CFrame.x or 0),
        part.CFrame.y or 0,
        part.CFrame.z or 0,
        part.CFrame.r00 or 1,
        -(part.CFrame.r01 or 0),
        -(part.CFrame.r02 or 0),
        -(part.CFrame.r10 or 0),
        part.CFrame.r11 or 1,
        part.CFrame.r12 or 0,
        -(part.CFrame.r20 or 0),
        part.CFrame.r21 or 0,
        part.CFrame.r22 or 1
    )
    if part._initial_linear_velocity then
        -- vector under x-mirror: x flips
        part._initial_linear_velocity = {
            x = -(part._initial_linear_velocity.x or 0),
            y = part._initial_linear_velocity.y or 0,
            z = part._initial_linear_velocity.z or 0,
        }
        part.AssemblyLinearVelocity = {
            x = part._initial_linear_velocity.x,
            y = part._initial_linear_velocity.y,
            z = part._initial_linear_velocity.z,
        }
    end
    if part._initial_angular_velocity then
        -- pseudovector under x-mirror: y/z flip, x keeps
        part._initial_angular_velocity = {
            x = part._initial_angular_velocity.x or 0,
            y = -(part._initial_angular_velocity.y or 0),
            z = -(part._initial_angular_velocity.z or 0),
        }
        part.AssemblyAngularVelocity = {
            x = part._initial_angular_velocity.x,
            y = part._initial_angular_velocity.y,
            z = part._initial_angular_velocity.z,
        }
    end
    sync_runtime_part_velocity_aliases(part)

    return part
end

function mark_parts_dirty(renderer)
    if not renderer or (tonumber(renderer._suppress_part_dirty) or 0) > 0 then
        return
    end
    renderer._debug_dirty_marks = renderer._debug_dirty_marks or {}
    renderer._debug_dirty_marks.full = (renderer._debug_dirty_marks.full or 0) + 1
    renderer._parts_dirty = true
    renderer._parts_dirty_mode = "full"
end

-- incremental release: geo ranges tracked in _static_part_geo, released by zeroing verts in place
-- untracked (surfacegui carriers, grouped transparent statics) fall back to full rebuild
local range_track_log = {}
local zero_vertex_rows = {}
local zero_row_by_arity = {}

function incremental_static_release_enabled(renderer)
    return renderer ~= nil
        and renderer.incremental_static_release ~= false
end

-- touch log -> {part_id,first,count} triples per batch, dup touches keep earliest so range spans all appends
function RBX:_flush_part_static_ranges(part)
    local log = self._range_track_log
    self._range_track_log = nil
    if not log then
        return
    end
    local pid = part and part._id
    local count = #log
    if pid ~= nil then
        local tracked = self._static_part_tracked
        if tracked then
            tracked[pid] = true
        end
        for i = 1, count, 2 do
            local batch = log[i]
            local duplicate = false
            for j = 1, i - 2, 2 do
                if log[j] == batch then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                local first = log[i + 1] + 1
                local appended = rbx_vertex_list_count(batch.vertices) - log[i + 1]
                if appended > 0 then
                    local ranges = batch.part_ranges
                    if not ranges then
                        ranges = {}
                        batch.part_ranges = ranges
                    end
                    ranges[#ranges + 1] = pid
                    ranges[#ranges + 1] = first
                    ranges[#ranges + 1] = appended
                end
            end
        end
    end
    for i = count, 1, -1 do
        log[i] = nil
    end
end

-- zeroed verts = degenerate = invisible
do
local shadow_array_vertices=require('engine/graphics/rbx/runtime/shadow_array')
function RBX:_zero_mesh_vertex_range(mesh, first, count)
    if not mesh or count <= 0 then
        return true
    end
    shadow_array_vertices.invalidate(mesh)
    local ok, format = pcall(mesh.getVertexFormat, mesh)
    if not ok or type(format) ~= "table" then
        return false
    end
    local arity = 0
    for i = 1, #format do
        local attribute = format[i]
        arity = arity + (tonumber(type(attribute) == "table" and (attribute[3] or attribute.components)) or 0)
    end
    if arity <= 0 then
        return false
    end
    local zero_row = zero_row_by_arity[arity]
    if not zero_row then
        zero_row = {}
        for i = 1, arity do
            zero_row[i] = 0
        end
        zero_row_by_arity[arity] = zero_row
    end
    -- love reads rows during setVertices, so one shared row table fills every slot
    local rows = zero_vertex_rows
    for i = 1, count do
        rows[i] = zero_row
    end
    for i = #rows, count + 1, -1 do
        rows[i] = nil
    end
    if self._static_mesh_unit_alpha then self._static_mesh_unit_alpha[mesh] = nil end
    local ok = pcall(mesh.setVertices, mesh, rows, first)
    return ok == true
end
end

function RBX:_mark_runtime_part_transform_dirty(part)
    if type(part) ~= "table" or part._destroyed or not part._id or part._workspace_active==false then
        return
    end
    -- CFrame/Position intentionally do not bump _render_prop_revision because
    -- the one-part fast-rebake path can update them in place.  derived settled
    -- aggregates still need an occupancy/content token for every such write
    part._dynamic_dirty_revision =
        (part._dynamic_dirty_revision or 0) + 1
    if (tonumber(part._mesh_lod_count) or 0) > 1 then
        -- projected extent changes when either endpoint moves. a monotonically
        -- changing token prevents an in-progress bounded scan from declaring a
        -- stale cycle complete after the moving part's old slot was already read
        self._mesh_lod_view_revision =
            (self._mesh_lod_view_revision or 0) + 1
        self._mesh_lod_rescan_pending = true
    end
    if self._invalidate_settled_merge_for_part then
        self:_invalidate_settled_merge_for_part(part)
    end
    if (tonumber(self._suppress_part_dirty) or 0) > 0 then
        return
    end
    self._debug_dirty_marks = self._debug_dirty_marks or {}
    self._debug_dirty_marks.transform = (self._debug_dirty_marks.transform or 0) + 1
    self._parts_dirty = true
    if self._parts_dirty_mode ~= "full" then
        self._parts_dirty_mode = "transform"
    end
    self._transform_dirty_parts = self._transform_dirty_parts or {}
    self._transform_dirty_parts[part._id] = part
    -- must invalidate the merge bake, else appearance writes stay invisible til it wakes
end

local function can_update_runtime_part_incrementally(renderer, part, allow_stored)
    return renderer
        and type(part) == "table"
        and not part._destroyed
        and (part._workspace_active~=false or allow_stored==true)
        -- all get their own dynamic chunk + cheap transform sync
        and (part._runtime_dynamic == true or part._promoted_dynamic == true
            or part._appearance_dynamic == true)
        -- anchored stays static except kinematic followers (rotatev/motor6d), sticky
        -- ex-dynamics (fall bricks flip anchored a lot, avoid re-batch each flip) and
        -- appearance-promoted statics (they re-bake in place, not via re-batch)
        and (part.Anchored ~= true or part._kinematic_dynamic == true
            or part._runtime_dynamic_sticky == true
            -- an imported prop already owns a dynamic chunk after waking
            -- Anchoring changes simulation, not that valid render residency
            or part._promoted_dynamic == true
            or part._appearance_dynamic == true)
        and part._id ~= nil
end

local function update_runtime_part_dynamic_flag(renderer, part)
    if type(part) ~= "table" or part._loaded_from_map == true then
        if renderer and renderer._refresh_physics_part_registration
            and not (part and part._physics_defer_registration
                and part._workspace_active == false) then
            renderer:_refresh_physics_part_registration(part)
        end
        return
    end
    part._runtime_dynamic = renderer
        and (part.Anchored ~= true or part._runtime_dynamic_sticky == true)
        or false
    if renderer and part.Anchored ~= true then
        -- once dynamic, stays dynamic (sticky note in can_update_runtime_part_incrementally)
        part._runtime_dynamic_sticky = true
    end
    if renderer and renderer._refresh_physics_part_registration
        and not (part._physics_defer_registration
            and part._workspace_active == false) then
        renderer:_refresh_physics_part_registration(part)
    end
end

-- Appearance writes (Color/Reflectance/surface params) on a static map part used to
-- force a FULL scene re-bake (~80 ms on a 5k-part map for one recolor). instead: zero the
-- part's baked static geometry in place (destroy-path machinery) and move it to the
-- dynamic-chunk path, where appearance rebakes touch only its own chunk. the next full
-- rebuild re-bakes it statically with its current look and clears the flag (self-heal in
-- _sync_runtime_parts)
local function appearance_promote_part(renderer, part, allow_runtime_static)
    if not renderer or type(part) ~= "table" or part._destroyed or part._id == nil then
        return false
    end
    if part._appearance_dynamic == true then
        return true
    end
    -- full builds also bake runtime-created statics. Subsequent pose/Size
    -- writes can release their tracked ranges just like imported static parts
    if (part._loaded_from_map ~= true and allow_runtime_static ~= true)
        or not incremental_static_release_enabled(renderer)
        or part._static_geo_untracked == true then
        return false
    end
    if not renderer:_release_static_part_geometry(part) then
        return false
    end
    part._appearance_dynamic = true
    local promoted = renderer._appearance_promoted_parts
    if not promoted then
        promoted = {}
        renderer._appearance_promoted_parts = promoted
    end
    promoted[part._id] = part
    renderer._appearance_promoted_count = (renderer._appearance_promoted_count or 0) + 1
    renderer._appearance_promote_count = (renderer._appearance_promote_count or 0) + 1
    renderer:_mark_runtime_part_transform_dirty(part)
    return true
end

-- a remote mesh changes geometry without changing any authored Part property
-- Route that publication through the same proven static-range release/dynamic
-- chunk path used by appearance edits, while explicitly invalidating the fast
-- rebake revision so an existing dynamic chunk cannot reuse fallback vertices
function RBX:_promote_remote_mesh_part_incrementally(part)
    if type(part) ~= "table" or part._destroyed or part._id == nil then
        return false, "stale_part"
    end
    part._rb_cache = nil
    part._mesh_xf_cache = nil
    part._render_prop_revision = (part._render_prop_revision or 0) + 1
    if can_update_runtime_part_incrementally(self, part) then
        self:_mark_runtime_part_transform_dirty(part)
        return true, "dynamic_rebuild"
    end
    if appearance_promote_part(self, part) then
        return true, "static_range_promoted"
    end
    local reason = "full_rebuild_required"
    if part._loaded_from_map ~= true then
        reason = reason .. ":not_map_loaded"
    elseif incremental_static_release_enabled(self) ~= true then
        reason = reason .. ":incremental_release_disabled"
    elseif part._static_geo_untracked == true then
        reason = reason .. ":explicitly_untracked"
    elseif not (self._static_part_tracked
            and self._static_part_tracked[part._id]) then
        reason = reason .. ":missing_static_range"
    else
        reason = reason .. ":range_release_failed"
    end
    local live_index = nil
    for index = 1, #(self.parts or {}) do
        if self.parts[index] == part then
            live_index = index
            break
        end
    end
    return false, string.format(
        "%s id=%s loaded_index=%s live_index=%s referent=%s name=%s class=%s"
            .. " anchored=%s runtime_dynamic=%s sticky=%s promoted=%s"
            .. " kinematic=%s appearance_dynamic=%s untracked=%s"
            .. " chunk=%s mesh_owner=%s mesh_type=%s mesh_id=%s alpha=%s",
        reason,
        tostring(part._id),
        tostring(part._loaded_part_index),
        tostring(live_index),
        tostring(part._map_referent),
        tostring(part.Name),
        tostring(part.ClassName),
        tostring(part.Anchored),
        tostring(part._runtime_dynamic),
        tostring(part._runtime_dynamic_sticky),
        tostring(part._promoted_dynamic),
        tostring(part._kinematic_dynamic),
        tostring(part._appearance_dynamic),
        tostring(part._static_geo_untracked),
        tostring(part._scene_chunk_key),
        tostring(part.MeshOwner and (part.MeshOwner.ClassName
            or part.MeshOwner._class_name or part.MeshOwner)),
        tostring(part.SpecialMeshType),
        tostring(part.MeshId),
        tostring(get_runtime_render_alpha(part)))
end

local promote_loaded_part_to_dynamic

local function mark_runtime_part_draw_dirty(renderer, part, allow_runtime_static, pose_only)
    -- Stored source rooms retain mutable Instances. their next Workspace entry
    -- rebuilds the current appearance, mutations while stored own no draw work
    if part and part._workspace_active == false then return end
    -- only pose writes preserve the row's captured material/alpha and bucket
    -- Appearance setters run before their property revision advances, treating
    -- them as motion queues an old row that the flush then rejects as stale
    if pose_only and renderer and renderer._note_instanced_part_moved and renderer:_note_instanced_part_moved(part) then
        return
    end
    if can_update_runtime_part_incrementally(renderer, part) then
        renderer:_mark_runtime_part_transform_dirty(part)
    elseif not appearance_promote_part(renderer, part, true) then
        -- imported CSG and other untracked geometry cannot release an old
        -- static range. a scripted pose still needs only ONE full rebuild:
        -- retain a driven chunk afterwards instead of rebuilding the map for
        -- every frame of an anchored character/door animation
        if not (allow_runtime_static and part and part.Anchored == true
            and promote_loaded_part_to_dynamic(renderer, part, true)) then
            mark_parts_dirty(renderer)
        end
    end
end

-- one rebuild w/o this part + own chunk, then cheap transform sync, idempotent
promote_loaded_part_to_dynamic = function(renderer, part, driven)
    if type(part) ~= "table" or part._id == nil or part._destroyed then
        return false
    end
    if part._loaded_from_map ~= true then
        return false -- only loaded-map parts need promotion
    end
    if part._promoted_dynamic == true then
        if driven and part._kinematic_dynamic ~= true then
            part._kinematic_dynamic = true
            -- a former dynamic may have been anchored and rendered since its
            -- last physics publication. its first scripted pose still needs
            -- a transform upload when static-range promotion is unavailable
            if renderer then renderer:_mark_runtime_part_transform_dirty(part) end
        end
        return true
    end
    -- fast instanced parts never promote (per-row uploads), kinematic followers + decal carriers fall through
    if not driven then
        local instanced_ref = part._instanced_ref
        if instanced_ref and instanced_ref.fast == true
            and instanced_ref.generation == (renderer._instance_generation or 0) then
            return true
        end
    end
    -- Anchored physics stays static, scripted poses and follower drivers can
    -- keep their render geometry in a driven chunk
    if not renderer or (part.Anchored == true and not driven) then
        return false
    end
    part._promoted_dynamic = true
    if driven then part._kinematic_dynamic = true end
    renderer._promoted_loaded_parts = renderer._promoted_loaded_parts or {}
    if renderer._promoted_loaded_parts[part._id] == nil then
        renderer._promoted_loaded_parts[part._id] = part
        renderer._promoted_loaded_part_count = (renderer._promoted_loaded_part_count or 0) + 1
    end
    -- fast path: zero static ranges + mark transform-dirty, no rebuild, else full rebuild
    if incremental_static_release_enabled(renderer)
        and part._static_geo_untracked ~= true
        and renderer:_release_static_part_geometry(part) then
        renderer._incremental_promote_count = (renderer._incremental_promote_count or 0) + 1
        renderer:_mark_runtime_part_transform_dirty(part)
    else
        mark_parts_dirty(renderer)
    end
    return true
end

-- not auto-wired to sleep, needs explicit call, triggers one full rebuild
local function demote_loaded_part_to_static(renderer, part)
    if type(part) ~= "table" or part._id == nil then
        return false
    end
    if part._promoted_dynamic ~= true then
        return false
    end
    part._promoted_dynamic = false
    part._kinematic_dynamic = nil
    if renderer and renderer._promoted_loaded_parts and renderer._promoted_loaded_parts[part._id] then
        renderer._promoted_loaded_parts[part._id] = nil
        renderer._promoted_loaded_part_count = math.max(0, (renderer._promoted_loaded_part_count or 1) - 1)
    end
    if renderer then
        mark_parts_dirty(renderer)
    end
    return true
end

local function normalize_runtime_surface_property(value, property_name)
    if value == nil then
        return nil
    end
    local normalized = normalize_surface_type(value)
    if normalized == nil then
        error("Part." .. tostring(property_name) .. " must be a valid SurfaceType|string|number|nil")
    end
    return normalized
end

local function invalidate_runtime_part_value_cache(part, key)
    local cache = part and part._value_cache
    if not cache then
        return
    end
    if key == nil then
        part._value_cache = nil
        return
    end
    cache[key] = nil
    if key == "CFrame" or key == "Position" then
        cache.Position = nil
        cache.AssemblyCenterOfMass = nil
    elseif key == "Color" or key == "BrickColor" then
        cache.Color = nil
        cache.MeshVertexColor = nil
    elseif key == "AssemblyLinearVelocity" or key == "Velocity" then
        cache.AssemblyLinearVelocity = nil
        cache.Velocity = nil
    elseif key == "AssemblyAngularVelocity" or key == "RotVelocity" then
        cache.AssemblyAngularVelocity = nil
        cache.RotVelocity = nil
    end
end

local function get_runtime_part_value_cache(part)
    local cache = part._value_cache
    if not cache then
        cache = {}
        part._value_cache = cache
    end
    return cache
end

local function cached_runtime_vector3(part, key, x, y, z)
    local cache = get_runtime_part_value_cache(part)
    local cached = cache[key]
    if cached ~= nil then
        return cached
    end
    cached = Vector3.new(x or 0, y or 0, z or 0)
    cache[key] = cached
    return cached
end

local function cached_runtime_color3(part, key, r, g, b)
    local cache = get_runtime_part_value_cache(part)
    local cached = cache[key]
    if cached ~= nil then
        return cached
    end
    cached = Color3.new(r or 0, g or 0, b or 0)
    cache[key] = cached
    return cached
end

RUNTIME_PART_INITIAL_PROPERTY_ORDER = {
    "Name",
    "Shape",
    "CFrame",
    "Position",
    "Size",
    "Color",
    "BrickColor",
    "Transparency",
    "LocalTransparencyModifier",
    "Reflectance",
    "Anchored",
    "CanCollide",
    "CanTouch",
    "CanQuery",
    "CollisionGroup",
    "Massless",
    "RootPriority",
    "CustomPhysicalProperties",
    "Velocity",
    "RotVelocity",
    "AssemblyLinearVelocity",
    "AssemblyAngularVelocity",
    "Material",
    "TopSurface",
    "BottomSurface",
    "LeftSurface",
    "RightSurface",
    "FrontSurface",
    "BackSurface",
    "TopSurfaceInput",
    "BottomSurfaceInput",
    "LeftSurfaceInput",
    "RightSurfaceInput",
    "FrontSurfaceInput",
    "BackSurfaceInput",
    "TopParamA",
    "TopParamB",
    "BottomParamA",
    "BottomParamB",
    "LeftParamA",
    "LeftParamB",
    "RightParamA",
    "RightParamB",
    "FrontParamA",
    "FrontParamB",
    "BackParamA",
    "BackParamB",
    "MeshId",
    "TextureContent",
    "TextureId",
    "UsePartColor",
    "DoubleSided",
    "SmoothingAngle",
    "RenderFidelity",
    "CollisionFidelity",
    "PhysicsData",
    "PhysicalConfigData",
    "TriangleCount",
    "MaterialVariant",
}

local function direct_runtime_part_get(_, part, descriptor)
    return part[descriptor.name]
end

local function readonly_runtime_part_set(_, _, _, descriptor)
    error("Part." .. tostring(descriptor.name) .. " is read-only")
end

---invalidates the one renderer part whose authored Decal/Texture layers changed
---
---Face layers are baked into textured batch vertices, so changing the descriptor
---is an appearance edit rather than a transform-only row upload.  the existing
---appearance-promotion path releases just this loaded part's static ranges and
---rebuilds it as a dynamic chunk, runtime/dynamic parts already take the same
---one-part path.  a full scene rebuild remains the correctness fallback for an
---untracked static range
function RBX:_mark_runtime_part_face_textures_dirty(
        part, texture_layer_descriptor)
    if type(part) ~= "table" or part._destroyed or part._id == nil then
        return false
    end
    -- the combined authored/surface/gui layer list is memoized for the duration
    -- of a build. attach/detach changes its membership, so invalidate the part
    -- explicitly even when the next synchronization is incremental
    part._ft_cache = nil
    part._ft_cache_token = nil
    if self.retain_face_texture_array == true
        and type(texture_layer_descriptor) == "table" then
        -- only a normalized FaceInstance content write carries this identity
        -- Hierarchy, UV, opacity, projection and cosmetic writes clear it so a
        -- retained chunk uses the established full one-owner rebuild
        part._face_texture_array_descriptor = texture_layer_descriptor
        part._face_texture_array_revision =
            (part._face_texture_array_revision or 0) + 1
    else
        part._face_texture_array_descriptor = nil
    end
    part._render_prop_revision = (part._render_prop_revision or 0) + 1
    mark_runtime_part_draw_dirty(self, part)
    return true
end

---invalidates one MeshPart whose effective direct SurfaceAppearance changed
---
---the maps and alpha mode alter batching, pass routing, shader identity, and
---remote texture consumers, but never mesh geometry or render bounds. bump only
---the appearance revision and use the same part-local static-range promotion /
---dynamic rebake path as other visual edits, decoded mesh and bounds caches stay
---warm intentionally
function RBX:_mark_runtime_part_surface_appearance_dirty(part)
    if type(part) ~= "table" or part._destroyed or part._id == nil
        or part.ClassName ~= "MeshPart" then
        return false
    end
    part._surface_appearance_stats_generation = nil
    part._surface_appearance_revision =
        (part._surface_appearance_revision or 0) + 1
    part._render_prop_revision = (part._render_prop_revision or 0) + 1
    mark_runtime_part_draw_dirty(self, part)
    return true
end

---invalidates the one BasePart whose effective DataModelMesh child changed
---Geometry source/type changes additionally retire a pending remote consumer;
---Scale/Offset/VertexColor/Texture writes retain decoded shared assets and only
---rebake this part's range/chunk through the normal incremental draw path
function RBX:_mark_runtime_part_legacy_mesh_dirty(part, source_changed, affine_only)
    if type(part) ~= "table" or part._destroyed or part._id == nil then
        return false
    end
    part._rb_cache = nil
    part._mesh_xf_cache = nil
    part._value_cache = nil
    -- incremental owner changes do not advance the full-build collect token
    -- retire the old generated layers before any consumer can collect them
    part._ft_cache = nil
    part._ft_cache_token = nil
    part._surface_detail_geometry_faces = nil
    part._surface_detail_lod_shader_faces = nil
    if source_changed then
        part._mesh_lod_base_mesh = nil
        part._mesh_lod_count = nil
        part._mesh_lod_index = nil
        part._mesh_lod_fidelity = nil
        if self._unbind_remote_mesh_consumer then
            self:_unbind_remote_mesh_consumer(part)
        end
    end
    part._render_prop_revision = (part._render_prop_revision or 0) + 1
    if affine_only then part._render_affine_revision = (part._render_affine_revision or 0) + 1 end
    mark_runtime_part_draw_dirty(self, part)
    return true
end

-- `parts[parsed_index]` is an ABI for parser-authored attachments and lights, so
-- loaded-map entries must never move.  Runtime-created parts live strictly after
-- that stable prefix.  their suffix is dense and swap-deleted, an intrusive list
-- preserves creation order for the deprecated Part explorer without retaining a
-- table slot for every part ever created during the map generation
local function loaded_part_prefix_count(renderer)
    local parts = renderer.parts or {}
    local count = tonumber(renderer._loaded_part_count)
    if count == nil then
        -- Pre-storage/test cores historically only had `parts`.  treat their
        -- existing contents as the stable loaded prefix before admitting a
        -- runtime-created suffix
        count = #parts
        renderer._loaded_part_count = count
    end
    return math.max(0, math.floor(count))
end

local function link_runtime_part_in_creation_order(renderer, part)
    local tail = renderer._runtime_part_order_tail
    part._runtime_part_order_prev = tail
    part._runtime_part_order_next = nil
    if tail then
        tail._runtime_part_order_next = part
    else
        renderer._runtime_part_order_head = part
    end
    renderer._runtime_part_order_tail = part
end

local function ensure_runtime_part_storage(renderer)
    if renderer._runtime_part_storage_initialized == true then
        return
    end

    local parts = renderer.parts or {}
    renderer.parts = parts
    local loaded_count = loaded_part_prefix_count(renderer)
    renderer._runtime_part_order_head = nil
    renderer._runtime_part_order_tail = nil
    renderer._runtime_live_part_count = 0

    -- Compatibility migration for a renderer assembled before this storage
    -- contract was initialized.  production renderers start with an empty
    -- suffix, but keeping this bounded migration makes internal seams robust
    for index = loaded_count + 1, #parts do
        local part = parts[index]
        if type(part) == "table" and not part._destroyed then
            part._runtime_part_slot = index
            link_runtime_part_in_creation_order(renderer, part)
            renderer._runtime_live_part_count =
                renderer._runtime_live_part_count + 1
        end
    end
    renderer._runtime_part_storage_peak_slots = math.max(
        tonumber(renderer._runtime_part_storage_peak_slots) or 0,
        renderer._runtime_live_part_count)
    renderer._runtime_part_storage_initialized = true
end

function RBX:_register_runtime_part_storage(part)
    if type(part) ~= "table" or part._destroyed then
        return false
    end
    ensure_runtime_part_storage(self)
    if part._runtime_part_slot ~= nil then
        return true
    end

    local parts = self.parts
    local slot = #parts + 1
    parts[slot] = part
    part._runtime_part_slot = slot
    link_runtime_part_in_creation_order(self, part)
    self._runtime_live_part_count =
        (tonumber(self._runtime_live_part_count) or 0) + 1
    self._runtime_part_storage_peak_slots = math.max(
        tonumber(self._runtime_part_storage_peak_slots) or 0,
        self._runtime_live_part_count)
    return true
end

function RBX:_remove_runtime_part_storage(part)
    if type(part) ~= "table" then
        return false
    end
    ensure_runtime_part_storage(self)

    local slot = tonumber(part._runtime_part_slot)
    local loaded_count = loaded_part_prefix_count(self)
    local parts = self.parts
    if slot == nil or slot <= loaded_count or parts[slot] ~= part then
        return false
    end

    local previous = part._runtime_part_order_prev
    local following = part._runtime_part_order_next
    if previous then
        previous._runtime_part_order_next = following
    else
        self._runtime_part_order_head = following
    end
    if following then
        following._runtime_part_order_prev = previous
    else
        self._runtime_part_order_tail = previous
    end
    part._runtime_part_order_prev = nil
    part._runtime_part_order_next = nil

    local last_slot = #parts
    local moved = parts[last_slot]
    if slot ~= last_slot then
        -- the loaded prefix cannot be here: runtime-created parts are always
        -- appended after it, and only this function removes suffix entries
        parts[slot] = moved
        if type(moved) == "table" then
            moved._runtime_part_slot = slot
            -- local-light entries resolve their live BasePart through this
            -- dense suffix slot.  repair only lights already indexed to the
            -- swap-moved part, its world transform did not change, so this is
            -- deliberately revision/grid neutral
            local moved_lights = self._local_lights_by_part_id
                and self._local_lights_by_part_id[moved._id] or nil
            for light_index = 1, #(moved_lights or {}) do
                moved_lights[light_index].parent_part_index = slot
            end
        end
        -- a bounded mesh-LOD scan may already have advanced beyond `slot`
        -- Rewind to the replacement instead of letting swap-delete move the
        -- last live part behind the cursor and falsely complete this view
        -- revision without ever inspecting it
        local lod_cursor = math.max(1, math.floor(
            tonumber(self._mesh_lod_scan_cursor) or 1))
        if slot < lod_cursor then
            self._mesh_lod_scan_cursor = slot
            self._mesh_lod_rescan_pending = true
        end
    end
    parts[last_slot] = nil
    part._runtime_part_slot = nil
    self._runtime_live_part_count = math.max(0,
        (tonumber(self._runtime_live_part_count) or 1) - 1)
    self._runtime_part_storage_removal_count =
        (tonumber(self._runtime_part_storage_removal_count) or 0) + 1
    return true
end

local function visit_runtime_parts_in_explorer_order(renderer, visitor)
    local parts = renderer.parts or {}
    local loaded_count = math.min(loaded_part_prefix_count(renderer), #parts)
    for index = 1, loaded_count do
        local part = parts[index]
        if type(part) == "table" and not part._destroyed then
            if visitor(part) == false then
                return false
            end
        end
    end

    if renderer._runtime_part_storage_initialized == true then
        local part = renderer._runtime_part_order_head
        while part do
            local following = part._runtime_part_order_next
            if not part._destroyed and visitor(part) == false then
                return false
            end
            part = following
        end
    else
        for index = loaded_count + 1, #parts do
            local part = parts[index]
            if type(part) == "table" and not part._destroyed then
                if visitor(part) == false then
                    return false
                end
            end
        end
    end
    return true
end

function RBX:_get_runtime_part_storage_stats()
    ensure_runtime_part_storage(self)
    local order_count = 0
    local part = self._runtime_part_order_head
    while part do
        order_count = order_count + 1
        part = part._runtime_part_order_next
    end
    local loaded_count = loaded_part_prefix_count(self)
    return {
        loaded_slot_count = loaded_count,
        scan_slot_count = #(self.parts or {}),
        runtime_dense_slot_count = math.max(0,
            #(self.parts or {}) - loaded_count),
        live_runtime_part_count =
            tonumber(self._runtime_live_part_count) or 0,
        runtime_explorer_order_count = order_count,
        peak_runtime_slot_count =
            tonumber(self._runtime_part_storage_peak_slots) or 0,
        runtime_removal_count =
            tonumber(self._runtime_part_storage_removal_count) or 0,
        next_part_id = tonumber(self._next_part_id) or 1,
    }
end

function update_runtime_part_name_index(renderer, part, old_name, new_name)
    if not renderer or not part then
        return
    end
    local by_name = renderer._runtime_part_by_name
    if not by_name then
        by_name = {}
        renderer._runtime_part_by_name = by_name
    end
    if old_name and by_name[old_name] == part then
        by_name[old_name] = nil
        visit_runtime_parts_in_explorer_order(renderer, function(candidate)
            if candidate and not candidate._destroyed and candidate ~= part and candidate.Name == old_name then
                by_name[old_name] = candidate
                return false
            end
        end)
    end
    if new_name and by_name[new_name] == nil and not part._destroyed then
        by_name[new_name] = part
    end
end

function index_runtime_part_core_handle(renderer, part)
    if not renderer or type(part) ~= "table" then
        return part
    end
    renderer._runtime_part_by_id = renderer._runtime_part_by_id or {}
    renderer._runtime_part_by_name = renderer._runtime_part_by_name or {}
    if part._id then
        renderer._runtime_part_by_id[part._id] = part
    end
    if part._map_referent then
        renderer._runtime_part_by_referent = renderer._runtime_part_by_referent or {}
        renderer._runtime_part_by_referent[part._map_referent] = part
    end
    update_runtime_part_name_index(renderer, part, nil, part.Name)
    return part
end

function unindex_runtime_part_core_handle(renderer, part)
    if not renderer or type(part) ~= "table" then
        return
    end
    if renderer._runtime_part_by_id and part._id then
        renderer._runtime_part_by_id[part._id] = nil
    end
    if renderer._runtime_part_by_referent and part._map_referent then
        renderer._runtime_part_by_referent[part._map_referent] = nil
    end
    update_runtime_part_name_index(renderer, part, part.Name, nil)
end

local function runtime_part_position_get(_, part)
    return cached_runtime_vector3(part, "Position", part.CFrame.x, part.CFrame.y, part.CFrame.z)
end

local function runtime_part_cframe_get(_, part)
    return part.CFrame
end

local function runtime_part_size_get(_, part)
    return cached_runtime_vector3(part, "Size", part.Size.x, part.Size.y, part.Size.z)
end

local function runtime_part_color_get(_, part)
    return cached_runtime_color3(part, "Color", part.Color.r, part.Color.g, part.Color.b)
end

local function runtime_part_brick_color_get(_, part)
    return {
        Name = "Custom",
        Number = 0,
        Color = { R = part.Color.r, G = part.Color.g, B = part.Color.b },
    }
end

local function runtime_part_custom_physical_properties_get(_, part)
    return clone_physical_properties_value(part.CustomPhysicalProperties)
end

function RBX._runtime_part_current_physical_properties_get(_, part)
    local properties = runtime_require("physics/materials.lua")
        .effective_properties_of(part)
    return setmetatable(properties, PhysicalProperties)
end

local function runtime_part_assembly_center_of_mass_get(_, part)
    local value = part.AssemblyCenterOfMass or part.CFrame.Position
    return cached_runtime_vector3(part, "AssemblyCenterOfMass", value.x or value.X, value.y or value.Y, value.z or value.Z)
end

local function runtime_part_linear_velocity_get(_, part, descriptor)
    local value = part.AssemblyLinearVelocity or part.Velocity or Vector3.zero
    return cached_runtime_vector3(part, descriptor.name, value.x or value.X, value.y or value.Y, value.z or value.Z)
end

local function runtime_part_angular_velocity_get(_, part, descriptor)
    local value = part.AssemblyAngularVelocity or part.RotVelocity or Vector3.zero
    return cached_runtime_vector3(part, descriptor.name, value.x or value.X, value.y or value.Y, value.z or value.Z)
end

local function runtime_part_assembly_root_part_get(renderer, part)
    return renderer and part.AssemblyRootPart and renderer:_get_or_create_part_proxy(part.AssemblyRootPart) or nil
end

local function runtime_part_mesh_size_get(_, part)
    local value = part.MeshSize
    return value and cached_runtime_vector3(part, "MeshSize", value.x or value.X, value.y or value.Y, value.z or value.Z)
        or nil
end

local function runtime_part_mesh_vertex_color_get(_, part)
    local value = part.MeshVertexColor
    return value and cached_runtime_color3(part, "MeshVertexColor", value.r or value.R, value.g or value.G, value.b or value.B)
        or nil
end

local function runtime_part_name_set(renderer, part, value)
    if type(value) ~= "string" then
        error("Part.Name must be a string")
    end
    local old_name = part.Name
    if old_name == value then
        return true
    end
    part.Name = value
    update_runtime_part_name_index(renderer, part, old_name, value)
    if part._dm_node then
        rename_datamodel_node(part._dm_node, value)
    end
    if part._instance_node then
        if not rawget(part._instance_node, "_destroyed") and part._instance_node.Name ~= value then
            part._instance_node.Name = value
        else
            rawset(part._instance_node, "_name", value)
        end
    end
end

local function runtime_part_shape_set(renderer, part, value)
    local normalized = normalize_part_shape(value, part.ClassName)
    if normalize_part_shape(part.Shape, part.ClassName) == normalized then
        return true
    end
    part.Shape = normalized
    -- Shape changes the collider kind (ball vs block) + inertia, the physics view
    -- snapshot must refresh or collisions keep the old geometry indefinitely (the
    -- incremental add/remove paths removed the accidental rebuilds that used to
    -- correct it as a side effect)
    if renderer and renderer._refresh_runtime_part_mass then
        renderer:_refresh_runtime_part_mass(part)
    end
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_cframe_set(renderer, part, value)
    local cframe = cframe_from_value(value, part.CFrame)
    if part.CFrame == cframe then
        return true
    end
    part.CFrame = cframe
    invalidate_runtime_part_value_cache(part, "CFrame")
    if renderer and renderer._note_runtime_part_physics_transform_changed then
        -- pose_only: in-place teleport fast path
        renderer:_note_runtime_part_physics_transform_changed(part, true)
    end
    mark_runtime_part_draw_dirty(renderer, part, true, true)
end

local function runtime_part_position_set(renderer, part, value)
    local x, y, z = to_vector3(value, part.CFrame.x, part.CFrame.y, part.CFrame.z)
    if part.CFrame.x == x and part.CFrame.y == y and part.CFrame.z == z then
        return true
    end
    part.CFrame = CFrame.from_matrix(
        x, y, z,
        part.CFrame.r00, part.CFrame.r01, part.CFrame.r02,
        part.CFrame.r10, part.CFrame.r11, part.CFrame.r12,
        part.CFrame.r20, part.CFrame.r21, part.CFrame.r22
    )
    invalidate_runtime_part_value_cache(part, "Position")
    if renderer and renderer._note_runtime_part_physics_transform_changed then
        -- pose_only: in-place teleport fast path
        renderer:_note_runtime_part_physics_transform_changed(part, true)
    end
    mark_runtime_part_draw_dirty(renderer, part, true, true)
end

local function runtime_part_size_set(renderer, part, value)
    local x, y, z = RBX._size_validation.components(value, part, true)
    if part.Size.x == x and part.Size.y == y and part.Size.z == z then
        return true
    end
    part.Size = { x = x, y = y, z = z }
    invalidate_runtime_part_value_cache(part, "Size")
    if renderer and renderer._refresh_runtime_part_mass then
        renderer:_refresh_runtime_part_mass(part)
    end
    if renderer and renderer._note_runtime_part_physics_transform_changed then
        renderer:_note_runtime_part_physics_transform_changed(part)
    end
    -- Size keeps its full geometry/physics invalidation, only static-range
    -- ownership is promoted here, avoiding an order dependency on CFrame
    mark_runtime_part_draw_dirty(renderer, part, true)
end

local function runtime_part_color_set(renderer, part, value, descriptor)
    local color_value = value
    if descriptor.name == "BrickColor" and type(value) == "table" and value.Color then
        color_value = value.Color
    end
    local r, g, b = to_color3(color_value, part.Color.r, part.Color.g, part.Color.b)
    local cur = part.Color
    -- no-op guard (see runtime_part_clamped_number_set)
    if cur and cur.r == r and cur.g == g and cur.b == b then
        return true
    end
    part.Color = { r = r, g = g, b = b }
    invalidate_runtime_part_value_cache(part, "Color")
    -- fast instanced parts carry tint per row: re-upload the row, skip re-bucketing
    if renderer and renderer._note_instanced_part_recolored
        and renderer:_note_instanced_part_recolored(part) then
        return
    end
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_clamped_number_set(renderer, part, value, descriptor)
    local number = tonumber(value)
    if number == nil then
        error("Part." .. descriptor.name .. " must be a number")
    end
    number = clamp(number, descriptor.min or 0, descriptor.max or 1)
    -- no-op guard: same-value write otherwise costs a full re-batch
    if part[descriptor.name] == number then
        return true
    end
    part[descriptor.name] = number
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_anchored_set(renderer, part, value)
    local anchored = value and true or false
    if part.Anchored == anchored then
        return true
    end
    -- residency unchanged (sticky/kinematic) = transform mark suffices, no re-batch
    local was_incremental = can_update_runtime_part_incrementally(renderer, part)
    local retained_chunk = part._promoted_dynamic == true and renderer
        and renderer._scene_chunk_map and part._scene_chunk_key
        and renderer._scene_chunk_map[part._scene_chunk_key] or nil
    part.Anchored = anchored
    update_runtime_part_dynamic_flag(renderer, part)
    if renderer then
        renderer._physics_assembly_dirty = true
    end
    -- Detached authoring still updates the physics contract above, but owns
    -- no submitted geometry. Workspace publication chooses its render owner
    if part._workspace_active == false then return end
    if was_incremental and can_update_runtime_part_incrementally(renderer, part) then
        -- an imported prop with unchanged one-part render ownership already
        -- has the exact pose/appearance payload. preserve that owner across
        -- Anchored-only writes, including a fresh full-build chunk without a
        -- warm transform snapshot. Physics registration above still changes
        local same_render_owner = retained_chunk
            and part._promoted_dynamic == true
            and retained_chunk.dynamic_chunk == true
            and retained_chunk.dynamic_part == part
            and renderer._scene_chunk_map
            and renderer._scene_chunk_map[part._scene_chunk_key] == retained_chunk
        if not same_render_owner then
            mark_runtime_part_draw_dirty(renderer, part, false, true)
        end
    else
        mark_parts_dirty(renderer)
    end
end

local function runtime_part_boolean_set(_, part, value, descriptor)
    if descriptor.false_means_false then
        part[descriptor.name] = value ~= false
    else
        part[descriptor.name] = value and true or false
    end
end

local function runtime_part_massless_set(renderer, part, value)
    part.Massless = value and true or false
    if renderer and renderer._refresh_runtime_part_mass then
        renderer:_refresh_runtime_part_mass(part)
    end
end

-- mirrors false_means_false
local function runtime_part_can_collide_set(renderer, part, value)
    local collide = value ~= false
    -- no-op guard: same-value write otherwise purges manifolds + topology rebuild
    if part.CanCollide == collide then
        return true
    end
    part.CanCollide = collide
    if renderer and renderer._on_runtime_part_collision_changed then
        renderer:_on_runtime_part_collision_changed(part)
    end
end

local function runtime_part_rotation_locked_set(renderer, part, value)
    local locked = value == true
    if (part.RotationLocked == true) == locked then
        return true
    end
    if renderer and renderer._set_runtime_part_rotation_locked then
        renderer:_set_runtime_part_rotation_locked(part, locked)
    else
        part.RotationLocked = locked
    end
end

local function runtime_part_collision_group_set(renderer, part, value)
    assert(renderer, "Physical collision group setter requires its owning world")
    return RBX._collision_group_part.set_name(renderer, part, value, invalidate_runtime_part_value_cache)
end

function RBX._runtime_part_collision_group_id_get(renderer, part)
    return RBX._collision_group_part.get_id(renderer, part)
end

function RBX._runtime_part_collision_group_id_set(renderer, part, value)
    assert(renderer, "Physical collision group setter requires its owning world")
    return RBX._collision_group_part.set_id(renderer, part, value, invalidate_runtime_part_value_cache)
end

-- affects inertia derivation in assembly.build
local function runtime_part_root_priority_set(renderer, part, value)
    local numeric = tonumber(value)
    if numeric == nil then
        error("Part.RootPriority must be numeric")
    end
    part.RootPriority = numeric
    if renderer and renderer._on_runtime_part_assembly_property_changed then
        renderer:_on_runtime_part_assembly_property_changed(part)
    end
end

local function runtime_part_string_set(_, part, value, descriptor)
    if type(value) ~= "string" then
        error("Part." .. descriptor.name .. " must be a string")
    end
    part[descriptor.name] = value
end

local function runtime_part_number_set(_, part, value, descriptor)
    local numeric = tonumber(value)
    if numeric == nil then
        error("Part." .. descriptor.name .. " must be numeric")
    end
    part[descriptor.name] = numeric
end

local function runtime_part_custom_physical_properties_set(renderer, part, value)
    part.CustomPhysicalProperties = clone_physical_properties_value(value)
    if renderer and renderer._refresh_runtime_part_mass then
        renderer:_refresh_runtime_part_mass(part)
    end
end

local function runtime_part_linear_velocity_set(renderer, part, value)
    if renderer and renderer._set_runtime_part_assembly_linear_velocity then
        renderer:_set_runtime_part_assembly_linear_velocity(part, value)
        local x, y, z = to_vector3(value, 0, 0, 0)
        part._initial_linear_velocity = { x = x, y = y, z = z }
        part._initial_linear_velocity_source = "runtime"
        invalidate_runtime_part_value_cache(part, "AssemblyLinearVelocity")
        return
    end
    invalidate_runtime_part_value_cache(part, "AssemblyLinearVelocity")
end

local function runtime_part_angular_velocity_set(renderer, part, value)
    if renderer and renderer._set_runtime_part_assembly_angular_velocity then
        renderer:_set_runtime_part_assembly_angular_velocity(part, value)
        local x, y, z = to_vector3(value, 0, 0, 0)
        part._initial_angular_velocity = { x = x, y = y, z = z }
        part._initial_angular_velocity_source = "runtime"
        invalidate_runtime_part_value_cache(part, "AssemblyAngularVelocity")
        return
    end
    invalidate_runtime_part_value_cache(part, "AssemblyAngularVelocity")
end

local function runtime_part_surface_set(renderer, part, value, descriptor)
    local normalized = normalize_runtime_surface_property(value, descriptor.name)
    local current = normalize_runtime_surface_property(
        part[descriptor.name], descriptor.name)
    if current == normalized then
        return true
    end
    part[descriptor.name] = normalized
    mark_runtime_part_draw_dirty(renderer, part)
end

-- CastShadow is a submission-policy property, not color geometry.  Changing it
-- must invalidate the cached caster selection/depth atlas without rebuilding
-- any scene mesh or instance buffer
local function runtime_part_cast_shadow_set(renderer, part, value)
    local normalized = value ~= false
    if part.CastShadow == normalized then
        return true
    end
    part.CastShadow = normalized
    if renderer then
        renderer._directional_shadow_caster_revision =
            (renderer._directional_shadow_caster_revision or 0) + 1
        renderer._shadow_casters_stale = true
    end
end

local function runtime_part_surface_number_set(renderer, part, value, descriptor)
    local normalized = tonumber(value) or 0
    if (tonumber(part[descriptor.name]) or 0) == normalized then
        return true
    end
    part[descriptor.name] = normalized
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_surface_optional_number_set(renderer, part, value, descriptor)
    local normalized = value == nil and nil or tonumber(value) or 0
    local current = part[descriptor.name]
    current = current == nil and nil or tonumber(current) or 0
    if current == normalized then
        return true
    end
    part[descriptor.name] = normalized
    mark_runtime_part_draw_dirty(renderer, part)
end

local function normalize_runtime_optional_string(value, property_name)
    if value == nil then
        return nil
    end
    if type(value) ~= "string" then
        error("Part." .. property_name .. " must be string|nil")
    end
    local normalized = trim(value)
    return normalized ~= "" and normalized or nil
end

local function runtime_part_optional_string_asset_set(renderer, part, value, descriptor)
    local normalized = normalize_runtime_optional_string(value, descriptor.name)
    local current = normalize_runtime_optional_string(
        part[descriptor.name], descriptor.name)
    if current == normalized then
        return true
    end
    part[descriptor.name] = normalized
    if descriptor.name == "MeshId" then
        -- a source-bound cooked collider cannot survive replacement geometry
        if part._collision_decomposition then
            part._collision_decomposition=nil;part._cd_scaled=nil
            if renderer._note_runtime_part_physics_transform_changed then
                renderer:_note_runtime_part_physics_transform_changed(part,false)
            end
        end
        -- a pending replacement can resolve to nil for several frames. do not
        -- retain the old decoded LOD graph or let its committed index leak into
        -- the next asset while that happens
        part._mesh_lod_base_mesh = nil
        part._mesh_lod_count = nil
        part._mesh_lod_index = nil
        part._mesh_lod_fidelity = nil
    end
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_draw_boolean_set(renderer, part, value, descriptor)
    local normalized = value and true or false
    if (part[descriptor.name] and true or false) == normalized then
        return true
    end
    part[descriptor.name] = normalized
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_optional_number_draw_set(renderer, part, value, descriptor)
    local normalized = value == nil and nil or tonumber(value) or 0
    local current = part[descriptor.name]
    current = current == nil and nil or tonumber(current) or 0
    if current == normalized then
        return true
    end
    part[descriptor.name] = normalized
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_render_fidelity_set(renderer, part, value)
    local normalized = value == nil and nil or tostring(value)
    local current = part.RenderFidelity == nil
        and nil or tostring(part.RenderFidelity)
    if current == normalized then
        return true
    end
    part.RenderFidelity = normalized
    mark_runtime_part_draw_dirty(renderer, part)
end

-- Collision geometry is prepared outside ordinary gameplay. import/clone may
-- initialize its authored metadata before registration, runtime writes cannot
-- silently leave an old decomposition attached to a new mode or blob
function runtime_part_collision_metadata_set(_, part, value, descriptor)
    assert(part._physics_defer_registration, "Part." .. descriptor.name .. " is read-only after initialization")
    if descriptor.name == "PhysicsData" or descriptor.name == "PhysicalConfigData" then
        assert(value == nil or type(value) == "string", descriptor.name .. " requires decoded bytes")
    else
        if type(value) == "table" then value = value.Name or value.name or value.Value end
        assert(type(value) == "string" or type(value) == "number", "CollisionFidelity requires an enum name or value")
    end
    part[descriptor.name] = value
end

local function runtime_part_material_variant_set(renderer, part, value)
    local normalized = normalize_runtime_optional_string(value, "MaterialVariant")
    local current = normalize_runtime_optional_string(
        part.MaterialVariant, "MaterialVariant")
    if current == normalized then
        return true
    end
    part.MaterialVariant = normalized
    if renderer and renderer._refresh_runtime_part_material_variant_physics then
        renderer:_refresh_runtime_part_material_variant_physics(part)
    end
    if renderer and renderer._refresh_runtime_part_mass then
        renderer:_refresh_runtime_part_mass(part)
    end
    mark_runtime_part_draw_dirty(renderer, part)
end

local function runtime_part_material_set(renderer, part, value)
    local numeric = tonumber(value)
    if numeric == nil then
        numeric = MaterialRegistry.normalize_token(value)
    end
    if numeric == nil then
        error("Part.Material must be a material enum or numeric token")
    end
    if tonumber(part.Material) == numeric then
        return true
    end
    part.Material = numeric
    if renderer and renderer._refresh_runtime_part_material_variant_physics then
        renderer:_refresh_runtime_part_material_variant_physics(part)
    end
    -- Material drives density (mass) + friction/elasticity defaults, refresh the
    -- physics view snapshot (see runtime_part_shape_set)
    if renderer and renderer._refresh_runtime_part_mass then
        renderer:_refresh_runtime_part_mass(part)
    end
    mark_runtime_part_draw_dirty(renderer, part)
end

function RBX:_refresh_runtime_part_material_variant_physics(part)
    if type(part) ~= "table" then return nil end
    local variant = RBX._material_variants.resolve(
        self._material_variant_catalog,
        part.Material,
        part.MaterialVariant)
    part._material_variant_physical_properties = variant
        and clone_physical_properties_value(
            variant.custom_physical_properties) or nil
    return part._material_variant_physical_properties
end

local function build_runtime_basepart_property_descriptors()
    if RUNTIME_BASEPART_PROPERTY_DESCRIPTORS then
        return RUNTIME_BASEPART_PROPERTY_DESCRIPTORS
    end

    local descriptors = {}
    local function add(name, spec)
        spec = spec or {}
        spec.name = name
        spec.schema = PART_PROPERTY_SCHEMA[name]
        spec.get = spec.get or direct_runtime_part_get
        spec.set = spec.set or readonly_runtime_part_set
        descriptors[name] = spec
        return spec
    end

    add("Name", { set = runtime_part_name_set })
    add("ClassName")
    add("Shape", { set = runtime_part_shape_set })
    add("CFrame", { get = runtime_part_cframe_get, set = runtime_part_cframe_set })
    add("Position", { get = runtime_part_position_get, set = runtime_part_position_set })
    add("Size", { get = runtime_part_size_get, set = runtime_part_size_set })
    add("Color", { get = runtime_part_color_get, set = runtime_part_color_set })
    add("BrickColor", { get = runtime_part_brick_color_get, set = runtime_part_color_set })
    add("Transparency", { set = runtime_part_clamped_number_set, min = 0, max = 1 })
    add("LocalTransparencyModifier", { set = runtime_part_clamped_number_set, min = 0, max = 1 })
    add("Reflectance", { set = runtime_part_clamped_number_set, min = 0, max = 1 })
    add("Anchored", { set = runtime_part_anchored_set })
    add("CanCollide", { set = runtime_part_can_collide_set })
    add("RotationLocked", { set = runtime_part_rotation_locked_set })
    add("CanTouch", { set = runtime_part_boolean_set, false_means_false = true })
    add("CanQuery", { set = runtime_part_boolean_set, false_means_false = true })
    add("CastShadow", { set = runtime_part_cast_shadow_set })
    add("CollisionGroup", { set = runtime_part_collision_group_set })
    add("CollisionGroupId", { get = RBX._runtime_part_collision_group_id_get, set = RBX._runtime_part_collision_group_id_set })
    add("Massless", { set = runtime_part_massless_set })
    add("RootPriority", { set = runtime_part_root_priority_set })
    add("CustomPhysicalProperties", {
        get = runtime_part_custom_physical_properties_get,
        set = runtime_part_custom_physical_properties_set,
    })
    add("CurrentPhysicalProperties", { get = RBX._runtime_part_current_physical_properties_get })
    add("Mass")
    add("AssemblyMass")
    add("AssemblyCenterOfMass", { get = runtime_part_assembly_center_of_mass_get })
    add("AssemblyRootPart", { get = runtime_part_assembly_root_part_get })
    add("AssemblyShapeApproximation")
    add("Velocity", { get = runtime_part_linear_velocity_get, set = runtime_part_linear_velocity_set })
    add("AssemblyLinearVelocity", { get = runtime_part_linear_velocity_get, set = runtime_part_linear_velocity_set })
    add("RotVelocity", { get = runtime_part_angular_velocity_get, set = runtime_part_angular_velocity_set })
    add("AssemblyAngularVelocity", { get = runtime_part_angular_velocity_get, set = runtime_part_angular_velocity_set })
    add("Material", { set = runtime_part_material_set })
    add("MeshId", { set = runtime_part_optional_string_asset_set })
    add("TextureContent", { set = runtime_part_optional_string_asset_set })
    add("TextureId", { set = runtime_part_optional_string_asset_set })
    add("UsePartColor", { set = runtime_part_draw_boolean_set })
    add("DoubleSided", { set = runtime_part_draw_boolean_set })
    add("SmoothingAngle", { set = runtime_part_optional_number_draw_set })
    add("RenderFidelity", { set = runtime_part_render_fidelity_set })
    add("CollisionFidelity", { set = runtime_part_collision_metadata_set })
    add("PhysicsData", { set = runtime_part_collision_metadata_set })
    add("PhysicalConfigData", { set = runtime_part_collision_metadata_set })
    add("TriangleCount", { set = runtime_part_optional_number_draw_set })
    add("MaterialVariant", { set = runtime_part_material_variant_set })
    add("MeshSize", { get = runtime_part_mesh_size_get })
    add("MeshVertexColor", { get = runtime_part_mesh_vertex_color_get })
    add("SurfaceGuis")
    add("BillboardGuis")

    for index = 1, #SURFACE_PROPERTY_FIELDS do
        local field = SURFACE_PROPERTY_FIELDS[index]
        local prefix = field.property:gsub("Surface$", "")
        add(field.property, { set = runtime_part_surface_set })
        add(prefix .. "SurfaceInput", { set = runtime_part_surface_number_set })
        add(prefix .. "ParamA", { set = runtime_part_surface_optional_number_set })
        add(prefix .. "ParamB", { set = runtime_part_surface_optional_number_set })
    end

    RUNTIME_BASEPART_PROPERTY_DESCRIPTORS = descriptors
    return descriptors
end

function get_runtime_part_class_property_descriptors(class_name)
    class_name = tostring(class_name or "Part")
    local cached = RUNTIME_PART_PROPERTY_DESCRIPTORS_BY_CLASS[class_name]
    if cached then
        return cached
    end
    local base = build_runtime_basepart_property_descriptors()
    local descriptors = {}
    for name, descriptor in pairs(base) do
        descriptors[name] = descriptor
    end
    RUNTIME_PART_PROPERTY_DESCRIPTORS_BY_CLASS[class_name] = descriptors
    return descriptors
end

function get_runtime_part_property_descriptor(class_name, key)
    if type(key) ~= "string" then
        return nil
    end
    local descriptors = get_runtime_part_class_property_descriptors(class_name)
    return descriptors[key]
end

function RBX:_get_runtime_part_class_property_descriptors(class_name)
    return get_runtime_part_class_property_descriptors(class_name)
end

function RBX:_get_runtime_part_property_descriptor(class_name, key)
    return get_runtime_part_property_descriptor(class_name, key)
end

function get_runtime_part_property_value(renderer, part, key)
    if not part or part._destroyed then
        return nil
    end
    local descriptor = get_runtime_part_property_descriptor(part.ClassName, key)
    if descriptor and descriptor.get then
        return descriptor.get(renderer, part, descriptor)
    end
    return nil
end

-- exempt from _render_prop_revision: pose/velocity (fast-rebake handles those) + physics-only
-- props, bumping would discard fast-rebake snapshots on every CanCollide/Anchored flip
local RENDER_PROP_REVISION_EXEMPT = {
    CFrame = true, Position = true,
    Velocity = true, AssemblyLinearVelocity = true,
    RotVelocity = true, AssemblyAngularVelocity = true,
    Anchored = true, CanCollide = true, CanTouch = true, CanQuery = true,
    CollisionGroup = true, CollisionGroupId = true, Massless = true, RootPriority = true,
    CustomPhysicalProperties = true, RotationLocked = true,
}

function set_runtime_part_property_with_descriptor(renderer, part, descriptor, value)
    if not part or part._destroyed then
        error("Cannot edit destroyed Part")
    end
    if not descriptor then
        error("Unknown part property 'nil'")
    end
    -- keep cached bounds and mesh transforms when a replicated write repeats the current value
    -- binary visibility changes still need to go through their normal update path
    local retained_visibility_marker = descriptor.name == "Transparency"
        and part._retain_animation_visibility_packet == true
    local previous_transparency = retained_visibility_marker
        and tonumber(part.Transparency) or nil
    local previous_bounds_cache = part._rb_cache
    local previous_mesh_transform_cache = part._mesh_xf_cache
    part._rb_cache = nil
    part._mesh_xf_cache = nil
    -- setters return true on no-op, skip the bump or same-value writes discard fast-rebake state
    local noop = descriptor.set(renderer, part, value, descriptor)
    if noop == true then
        part._rb_cache = previous_bounds_cache
        part._mesh_xf_cache = previous_mesh_transform_cache
        return true
    end
    if noop ~= true and not RENDER_PROP_REVISION_EXEMPT[descriptor.name] then
        part._render_prop_revision = (part._render_prop_revision or 0) + 1
        if descriptor.name == 'Size' then
            part._render_size_revision=(part._render_size_revision or 0)+1
            if part.ClassName=='MeshPart' and part.MeshOwner~='SpecialMesh' then
                part._render_affine_revision=(part._render_affine_revision or 0)+1
            end
        end
        if retained_visibility_marker then
            local current_transparency = tonumber(part.Transparency)
            if (previous_transparency == 0 and current_transparency == 1)
                or (previous_transparency == 1 and current_transparency == 0) then
                part._retained_animation_visibility_revision =
                    (part._retained_animation_visibility_revision or 0) + 1
                -- exact tagged dynamic visibility changes alter only the
                -- shadow tail. static command ownership remains reusable
                if renderer then
                    renderer._directional_shadow_dynamic_caster_revision =
                        (renderer._directional_shadow_dynamic_caster_revision or 0) + 1
                    renderer._shadow_casters_stale = true
                end
            end
        end
    end
    return false
end

function set_runtime_part_property(renderer, part, key, value)
    if not part or part._destroyed then
        error("Cannot edit destroyed Part")
    end
    local descriptor = get_runtime_part_property_descriptor(part.ClassName, key)
    if not descriptor then
        error("Unknown part property '" ..
            tostring(key) ..
            "'. Property names are exact-case; available: Name, ClassName, Shape, CFrame, Position, Size, Color, Transparency, Reflectance, Anchored, CanCollide, CanTouch, CanQuery, CollisionGroup, Massless, RootPriority, CustomPhysicalProperties, Velocity, RotVelocity, AssemblyLinearVelocity, AssemblyAngularVelocity, Material, MaterialVariant, TopSurface, BottomSurface, LeftSurface, RightSurface, FrontSurface, BackSurface, TopSurfaceInput, BottomSurfaceInput, LeftSurfaceInput, RightSurfaceInput, FrontSurfaceInput, BackSurfaceInput, TopParamA, TopParamB, BottomParamA, BottomParamB, LeftParamA, LeftParamB, RightParamA, RightParamB, FrontParamA, FrontParamB, BackParamA, BackParamB, MeshId, TextureContent, TextureId, UsePartColor, DoubleSided, SmoothingAngle, RenderFidelity, TriangleCount, MeshSize, MeshVertexColor")
    end
    return set_runtime_part_property_with_descriptor(
        renderer, part, descriptor, value)
end

runtime_require("physics.lua").install(RBX, {
    invalidate_runtime_part_value_cache = invalidate_runtime_part_value_cache,
    mark_runtime_part_draw_dirty = mark_runtime_part_draw_dirty,
    promote_loaded_part_to_dynamic = promote_loaded_part_to_dynamic,
    demote_loaded_part_to_static = demote_loaded_part_to_static,
})

part_proxy_mt = {}
part_proxy_mt.__index = function(proxy, key)
    local method = part_methods[key] or datamodel_methods[key]
    if method then
        return method
    end

    local part = rawget(proxy, "_part")
    local renderer = rawget(proxy, "_renderer")
    if not part or part._destroyed then
        return nil
    end

    if type(key) == "string" then
        if key == "Changed" then
            return get_runtime_part_signal(renderer, part, "Changed")
        end
        if key == "BrickColor" then
            return {
                Name = "Custom",
                Number = 0,
                Color = { R = part.Color.r, G = part.Color.g, B = part.Color.b },
            }
        end
    end

    local node = part._dm_node
    if key == "Parent" then
        return renderer and renderer:_proxy_for_datamodel_parent(node) or nil
    end
    if key == "Children" then
        return renderer and renderer:_datamodel_children_as_proxies(node) or {}
    end
    if type(key) == "string" and node then
        local child = find_datamodel_child(node, key, false)
        if child then
            return renderer:_proxy_for_datamodel_node(child)
        end
    end

    if key == "CustomPhysicalProperties" then
        return clone_physical_properties_value(part.CustomPhysicalProperties)
    end
    return get_runtime_part_property_value(renderer, part, key)
end

part_proxy_mt.__newindex = function(proxy, key, value)
    local part = rawget(proxy, "_part")
    if not part or part._destroyed then
        error("Cannot edit destroyed Part")
    end
    local renderer = rawget(proxy, "_renderer")
    local actual_key = key
    if actual_key == "Parent" then
        renderer:_attach_runtime_part_to_datamodel(part, value)
        return
    end
    set_runtime_part_property(renderer, part, actual_key, value)
    fire_runtime_part_property_changed(renderer, part, actual_key)
end

part_proxy_mt.__tostring = function(proxy)
    local part = rawget(proxy, "_part")
    if not part then
        return "Part(nil)"
    end
    return string.format("Part<%s:%s>", tostring(part.ClassName), tostring(part.Name))
end

-- shared by part:Destroy() + the kill-plane sweep, idempotent
function RBX:_destroy_runtime_part(target)
    if type(target) ~= "table" or target._destroyed then
        return false
    end
    -- Physics kill-plane destruction enters through the core handle, not the
    -- public Instance.  Delegate to the facade when present so Destroying,
    -- descendants, hierarchy membership, and DataModel id/referent indexes are
    -- retired at the same boundary as an explicit Instance:Destroy().  the
    -- facade calls back into _release_destroyed_part_geometry, which performs
    -- the dense-slot/remote/geometry cleanup exactly once
    local instance = rawget(target, "_instance_node")
    if type(instance) == "table" and not rawget(instance, "_destroyed")
        and type(instance.Destroy) == "function" then
        instance:Destroy()
        return target._destroyed == true
    end
    detach_datamodel_node(target._dm_node)
    cleanup_runtime_part_signals(target)
    unindex_runtime_part_core_handle(self, target)
    target._destroyed = true
    self:_release_destroyed_part_geometry(target)
    -- guarded so map-viewer (no physics world) pays nothing
    if self._physics_world and self._refresh_physics_part_registration then
        self:_refresh_physics_part_registration(target)
    end
    return true
end

-- drop one destroyed part's baked geometry WITHOUT rebuilding the scene, falling back to
-- a full rebuild only when the part's geometry isn't individually tracked
--
-- shared with the datamodel facade's Instance:Destroy, which used to just call
-- mark_parts_dirty() -- i.e. "full" -- so destroying a single NPC re-baked the entire map:
-- measured at 210-380ms and ~48MB of garbage per death on a classic map
--
-- call AFTER target._destroyed is set (both callers do), the release helpers expect it
function RBX:_release_destroyed_part_geometry(target)
    if type(target) ~= "table" then
        return false
    end
    -- both the lightweight Part proxy and the full DataModel facade enter here
    -- retire every lifetime-sized owner before any geometry branch can return
    -- loaded entries remain at their parser-authored indices, runtime suffix
    -- entries are swap-deleted in O(1)
    self:_remove_runtime_part_storage(target)
    if target._id ~= nil and self._part_proxy_by_id
        and self._part_proxy_by_id[target._id] then
        self._part_proxy_by_id[target._id] = nil
    end
    if target._id ~= nil and self._transform_dirty_parts then
        self._transform_dirty_parts[target._id] = nil
    end
    if self._unbind_remote_mesh_consumer then
        self:_unbind_remote_mesh_consumer(target)
    end
    if self._release_part_embedded_mesh_cache then
        self:_release_part_embedded_mesh_cache(target)
    end
    target._mesh_lod_base_mesh = nil
    target._mesh_lod_count = nil
    target._mesh_lod_index = nil
    target._mesh_lod_fidelity = nil
    -- else destruction leaks the record (demotion only clears on settle)
    if target._id ~= nil and self._promoted_loaded_parts and self._promoted_loaded_parts[target._id] then
        self._promoted_loaded_parts[target._id] = nil
        self._promoted_loaded_part_count = math.max(0, (self._promoted_loaded_part_count or 1) - 1)
    end
    -- dynamic drops its chunk, static tracked zeroes baked ranges, else full rebuild
    local was_dynamic = target._promoted_dynamic == true or target._runtime_dynamic == true
        or target._appearance_dynamic == true
    target._promoted_dynamic = nil
    target._kinematic_dynamic = nil
    if target._appearance_dynamic == true then
        target._appearance_dynamic = nil
        if target._id ~= nil and self._appearance_promoted_parts then
            self._appearance_promoted_parts[target._id] = nil
            self._appearance_promoted_count = math.max(0, (self._appearance_promoted_count or 1) - 1)
        end
    end
    if was_dynamic and self:_remove_dynamic_scene_chunk_for_part(target) then
        self._incremental_destroy_count = (self._incremental_destroy_count or 0) + 1
        return true
    elseif target._retained_dynamic_geometry then
        -- Workspace departure may already have retired this owned chunk
        -- no shared static ranges can belong to a retained dynamic part
        self._incremental_destroy_count = (self._incremental_destroy_count or 0) + 1
        return true
    elseif target._workspace_geometry_retired == true then
        -- the facade removes the subtree from Workspace before Destroy
        -- That departure already released its positively identified owner
        self._incremental_destroy_count = (self._incremental_destroy_count or 0) + 1
        return true
    elseif not was_dynamic
        and incremental_static_release_enabled(self)
        and target._static_geo_untracked ~= true
        and self:_release_static_part_geometry(target) then
        self._incremental_destroy_count = (self._incremental_destroy_count or 0) + 1
        self:_invalidate_dynamic_visible_cache()
        return true
    end
    -- Fully transparent statics can't be released incrementally -- they bake into grouped
    -- multi-part meshes and carry _static_geo_untracked, so the branch above skips them and
    -- they'd fall through to a whole-map re-bake (measured 370-660ms + ~52MB for destroying
    -- ONE invisible marker part, e.g. an ammo-box holder)
    --
    -- they don't need releasing: at Transparency>=1 the baked triangles draw nothing, so
    -- leaving them in the mesh is pixel-identical to removing them. Strictly > any full
    -- re-bake. the trade is that those vertices linger until the next rebuild happens for
    -- some other reason -- fine for the invisible markers this covers, and still cheap even
    -- in bulk. Deliberately gated on >=1: a partially transparent part WOULD leave a
    -- visible ghost, so it must keep taking the slow, correct path
    if not was_dynamic and (tonumber(target.Transparency) or 0) >= 1 then
        self._incremental_destroy_count = (self._incremental_destroy_count or 0) + 1
        self:_invalidate_dynamic_visible_cache()
        return true
    end
    mark_parts_dirty(self)
    return false
end

function part_methods:Destroy()
    local renderer = rawget(self, "_renderer")
    local target = rawget(self, "_part")
    if not renderer or not target or target._destroyed then
        return
    end
    renderer:_destroy_runtime_part(target)
end

function part_methods:Clone()
    local renderer = rawget(self, "_renderer")
    local part = rawget(self, "_part")
    if not renderer or not part or part._destroyed then
        return nil
    end
    local clone = renderer:_create_runtime_part(part.ClassName, {
        Name = part.Name .. "_Clone",
        Shape = part.Shape,
        CFrame = part.CFrame:clone(),
        Size = { x = part.Size.x, y = part.Size.y, z = part.Size.z },
        Color = { r = part.Color.r, g = part.Color.g, b = part.Color.b },
        Transparency = part.Transparency,
        LocalTransparencyModifier = part.LocalTransparencyModifier,
        Reflectance = part.Reflectance,
        Anchored = part.Anchored,
        CanCollide = part.CanCollide,
        CanTouch = part.CanTouch,
        CanQuery = part.CanQuery,
        CollisionGroup = part.CollisionGroup,
        Massless = part.Massless,
        RootPriority = part.RootPriority,
        CustomPhysicalProperties = clone_physical_properties_value(part.CustomPhysicalProperties),
        AssemblyLinearVelocity = part.AssemblyLinearVelocity and {
            x = part.AssemblyLinearVelocity.x,
            y = part.AssemblyLinearVelocity.y,
            z = part.AssemblyLinearVelocity.z,
        } or nil,
        AssemblyAngularVelocity = part.AssemblyAngularVelocity and {
            x = part.AssemblyAngularVelocity.x,
            y = part.AssemblyAngularVelocity.y,
            z = part.AssemblyAngularVelocity.z,
        } or nil,
        Material = part.Material,
        TopSurface = part.TopSurface,
        BottomSurface = part.BottomSurface,
        LeftSurface = part.LeftSurface,
        RightSurface = part.RightSurface,
        FrontSurface = part.FrontSurface,
        BackSurface = part.BackSurface,
        MeshId = part.MeshId,
        TextureContent = part.TextureContent,
        TextureId = part.TextureId,
        UsePartColor = part.UsePartColor,
        DoubleSided = part.DoubleSided,
        SmoothingAngle = part.SmoothingAngle,
        RenderFidelity = part.RenderFidelity,
        CollisionFidelity = part.CollisionFidelity,
        PhysicsData = part.PhysicsData,
        PhysicalConfigData = part.PhysicalConfigData,
        TriangleCount = part.TriangleCount,
        MaterialVariant = part.MaterialVariant,
    })

    if clone then
        -- includes modern Rotation/UV fields and deep-copies Color3 storage;
        -- the former hand-written subset both lost fields and aliased `color`
        clone.FaceTextures = RBX._clone_face_texture_list(part.FaceTextures)
        clone.SurfaceGuis = RBX._clone_surface_gui_list(part.SurfaceGuis)
        clone.BillboardGuis = RBX._clone_surface_gui_list(part.BillboardGuis)
        clone.SurfaceAppearance = RBX._clone_surface_appearance_descriptor(
            part.SurfaceAppearance)
        clone.BlockMeshScale = part.BlockMeshScale and {
            x = part.BlockMeshScale.x,
            y = part.BlockMeshScale.y,
            z = part.BlockMeshScale.z,
        } or nil
        clone.BlockMeshOffset = part.BlockMeshOffset and {
            x = part.BlockMeshOffset.x,
            y = part.BlockMeshOffset.y,
            z = part.BlockMeshOffset.z,
        } or nil
        clone.MeshSize = part.MeshSize and {
            x = part.MeshSize.x,
            y = part.MeshSize.y,
            z = part.MeshSize.z,
        } or nil
        clone.MeshVertexColor = part.MeshVertexColor and {
            r = part.MeshVertexColor.r,
            g = part.MeshVertexColor.g,
            b = part.MeshVertexColor.b,
        } or nil
        clone.MeshOwner = part.MeshOwner
        clone.SpecialMeshType = part.SpecialMeshType
        clone.SpecialMeshScale = part.SpecialMeshScale and {
            x = part.SpecialMeshScale.x,
            y = part.SpecialMeshScale.y,
            z = part.SpecialMeshScale.z,
        } or nil
        clone.SpecialMeshOffset = part.SpecialMeshOffset and {
            x = part.SpecialMeshOffset.x,
            y = part.SpecialMeshOffset.y,
            z = part.SpecialMeshOffset.z,
        } or nil
        clone.SpecialMeshVertexColor = part.SpecialMeshVertexColor and {
            r = part.SpecialMeshVertexColor.r,
            g = part.SpecialMeshVertexColor.g,
            b = part.SpecialMeshVertexColor.b,
        } or nil
        clone.EmbeddedMeshData = part.EmbeddedMeshData
        clone.EmbeddedMeshDataCandidates = RBX._clone_string_list(part.EmbeddedMeshDataCandidates)
        -- resolve through the by-content cache on first use.  Copying the
        -- source part's strong memo here bypassed pin accounting and made the
        -- clone retain old-map decoded geometry after its source was destroyed
        clone._embedded_mesh_cache = nil
        clone._loaded_map_mirror_x = part._loaded_map_mirror_x == true
        if clone._workspace_active ~= false then mark_parts_dirty(renderer) end
    end

    return renderer:_get_or_create_part_proxy(clone)
end

function part_methods:GetPropertySchema()
    return PART_PROPERTY_SCHEMA
end

function part_methods:GetMass()
    local part = rawget(self, "_part")
    return part and (part.Mass or 0) or 0
end

function part_methods:GetPropertyChangedSignal(property_name)
    local renderer = rawget(self, "_renderer")
    local part = rawget(self, "_part")
    return get_runtime_part_property_signal(renderer, part, property_name)
end

function part_methods:ApplyImpulse(impulse)
    local renderer = rawget(self, "_renderer")
    local part = rawget(self, "_part")
    if renderer and part and renderer._apply_runtime_part_impulse then
        renderer:_apply_runtime_part_impulse(part, impulse)
    end
end

function part_methods:ApplyImpulseAtPosition(impulse, position)
    local renderer = rawget(self, "_renderer")
    local part = rawget(self, "_part")
    if renderer and part and renderer._apply_runtime_part_impulse_at_position then
        renderer:_apply_runtime_part_impulse_at_position(part, impulse, position)
    end
end

function part_methods:ApplyAngularImpulse(impulse)
    local renderer = rawget(self, "_renderer")
    local part = rawget(self, "_part")
    if renderer and part and renderer._apply_runtime_part_angular_impulse then
        renderer:_apply_runtime_part_angular_impulse(part, impulse)
    end
end

part_explorer_mt = {}
part_explorer_mt.__index = function(explorer, key)
    local renderer = rawget(explorer, "_renderer")
    if not renderer then
        return nil
    end

    if explorer_methods[key] then
        return explorer_methods[key]
    end

    if type(key) == "number" then
        local raw = renderer:_get_runtime_part_by_index(key)
        return raw and renderer:_get_or_create_part_proxy(raw) or nil
    end

    if type(key) == "string" then
        local raw = renderer:_find_runtime_part_by_name(key)
        return raw and renderer:_get_or_create_part_proxy(raw) or nil
    end

    return nil
end

part_explorer_mt.__newindex = function()
    error("game.Part is a deprecated read-only compatibility shim. Use rbx.Instance.new('Part') or Workspace tree lookups.")
end

function explorer_methods:Get(index_or_name)
    local renderer = rawget(self, "_renderer")
    if type(index_or_name) == "number" then
        local raw = renderer:_get_runtime_part_by_index(index_or_name)
        return raw and renderer:_get_or_create_part_proxy(raw) or nil
    end
    local raw = renderer:_find_runtime_part_by_name(index_or_name)
    return raw and renderer:_get_or_create_part_proxy(raw) or nil
end

function explorer_methods:GetAll()
    local renderer = rawget(self, "_renderer")
    local out = {}
    visit_runtime_parts_in_explorer_order(renderer, function(raw)
        out[#out + 1] = renderer:_get_or_create_part_proxy(raw)
    end)
    return out
end

function explorer_methods:FindFirstChild(name)
    return self:Get(name)
end

function explorer_methods:Count()
    local renderer = rawget(self, "_renderer")
    local count = 0
    visit_runtime_parts_in_explorer_order(renderer, function()
        count = count + 1
    end)
    return count
end

function explorer_methods:GetPropertySchema()
    return PART_PROPERTY_SCHEMA
end

part_explorer_mt.__len = function(explorer)
    local renderer = rawget(explorer, "_renderer")
    if not renderer then
        return 0
    end
    return explorer_methods.Count(explorer)
end

part_explorer_mt.__tostring = function(explorer)
    local renderer = rawget(explorer, "_renderer")
    if not renderer then
        return "PartExplorer(nil)"
    end
    return string.format("PartExplorer<%d>", explorer_methods.Count(explorer))
end

function canonicalize_part_class_name(class_name)
    if type(class_name) ~= "string" then
        return nil
    end

    local trimmed = class_name:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end

    if SUPPORTED_PART_CLASSES[trimmed] then
        return trimmed
    end

    local lowered = trimmed:lower()
    for key in pairs(SUPPORTED_PART_CLASSES) do
        if key:lower() == lowered then
            return key
        end
    end

    return nil
end

function RBX:_fire_runtime_part_signal(part, name, ...)
    return fire_runtime_part_signal(self, part, name, ...)
end

function RBX:_get_or_create_part_proxy(part)
    if not part then
        return nil
    end

    local cached = self._part_proxy_by_id[part._id]
    if cached then
        rawset(cached, "_part", part)
        return cached
    end

    local proxy = setmetatable({
        _renderer = self,
        _part = part,
    }, part_proxy_mt)

    self._part_proxy_by_id[part._id] = proxy
    return proxy
end

function RBX:_get_runtime_part_by_index(index)
    if type(index) ~= "number" then
        return nil
    end

    local wanted = math.floor(index)
    if wanted < 1 then
        return nil
    end

    local visible_index = 0
    local result = nil
    visit_runtime_parts_in_explorer_order(self, function(part)
        visible_index = visible_index + 1
        if visible_index == wanted then
            result = part
            return false
        end
    end)
    return result
end

function RBX:_find_runtime_part_by_name(name)
    if type(name) ~= "string" then
        return nil
    end

    local indexed = self._runtime_part_by_name and self._runtime_part_by_name[name] or nil
    if indexed and not indexed._destroyed and indexed.Name == name then
        return indexed
    end

    local result = nil
    visit_runtime_parts_in_explorer_order(self, function(part)
        if part.Name == name then
            self._runtime_part_by_name = self._runtime_part_by_name or {}
            self._runtime_part_by_name[name] = part
            result = part
            return false
        end
    end)
    return result
end

function RBX:_create_scene_chunk(key, grid_x, grid_y, grid_z)
    return {
        key = key,
        grid_x = grid_x,
        grid_y = grid_y,
        grid_z = grid_z,
        -- Monotonic for in-place content uploads.  Pointer identity catches a
        -- rebuilt one-part chunk, this revision catches fast-rebakes which
        -- deliberately preserve that identity
        _settled_content_revision = 1,
        bounds = {
            min_x = math.huge,
            min_y = math.huge,
            min_z = math.huge,
            max_x = -math.huge,
            max_y = -math.huge,
            max_z = -math.huge,
        },
        cube_instances = {},
        opaque_static_shape_instances = {},
        opaque_static_draw_items = {},
        opaque_textured_batch_map = {},
        overlay_textured_batch_map = {},
        transparent_textured_batch_map = {},
        textured_batches = {},
        overlay_textured_batches = {},
        transparent_draw_items = {},
        transparent_static_shape_instances = {},
        transparent_static_shape_groups = {},
        occluder_candidates = {},
        occluder_candidate_count = 0,
        opaque_volume = 0,
        opaque_face_area_xy = 0,
        opaque_face_area_xz = 0,
        opaque_face_area_yz = 0,
        opaque_part_count = 0,
        transparent_part_count = 0,
        instance_count = 0,
        _cube_instance_batch = nil,
        instance_mesh = nil,
        static_cube_mesh = nil,
        has_opaque_geometry = false,
        has_transparent_geometry = false,
        visible_revision = 0,
    }
end

function RBX:_get_or_create_scene_chunk(chunk_map, x, y, z)
    local grid_x, grid_y, grid_z = get_spatial_chunk_coords(self.visibility_cell_size, x, y, z)
    local key = get_spatial_chunk_key(grid_x, grid_y, grid_z)
    local chunk = chunk_map[key]
    if chunk then
        return chunk
    end

    chunk = self:_create_scene_chunk(key, grid_x, grid_y, grid_z)
    chunk_map[key] = chunk
    return chunk
end

function RBX:_attach_instance_attributes_to_mesh(draw_mesh, instance_mesh, phase)
    if not draw_mesh or not instance_mesh then
        return false
    end

    draw_mesh:attachAttribute("InstancePosition", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceRight", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceUp", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceBack", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceSize", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceColor", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceReflectance", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceContactAO", instance_mesh, "perinstance")

    if phase == "draw" then
        self._frame_instance_attribute_attach_count = (self._frame_instance_attribute_attach_count or 0) + 8
    else
        self._instance_attribute_attach_build_count = (self._instance_attribute_attach_build_count or 0) + 8
    end
    return true
end

function RBX:_note_render_backend_error(scope, err)
    self._render_backend_error_count = (self._render_backend_error_count or 0) + 1
    self._render_backend_last_error = string.format("%s: %s",
        tostring(scope or "unknown"), tostring(err))
    -- avoid turning a recurring driver failure into a per-frame logging cost
    if self._render_backend_error_count <= 3 then
        print("[rbx] menori backend fallback: " .. self._render_backend_last_error)
    end
end

function RBX:_release_opaque_cube_batch(batch)
    if not batch then
        return false
    end
    local backend = self._render_backend
    local ok, released
    if backend and batch.backend == backend and backend.release_batch then
        ok, released = pcall(backend.release_batch, backend, batch)
    elseif type(batch.release) == "function" then
        ok, released = pcall(batch.release, batch)
    else
        return false
    end
    if not ok then
        self:_note_render_backend_error("release opaque batch", released)
        return false
    end
    return released == true
end

local function release_scene_mesh_once(resource, released)
    if type(resource) ~= "userdata" or released[resource] then
        return false
    end
    local ok, release = pcall(function()
        return resource.release
    end)
    if not ok or type(release) ~= "function" then
        return false
    end
    released[resource] = true
    local release_ok, did_release = pcall(release, resource)
    return release_ok and did_release ~= false
end

local function note_backend_batch_aliases(batch, released)
    if type(batch) ~= "table" then
        return
    end
    local draw_mesh = rawget(batch, "draw_mesh")
    local instance_mesh = rawget(batch, "instance_mesh")
    if draw_mesh then released[draw_mesh] = true end
    if instance_mesh then released[instance_mesh] = true end
end

local function release_scene_draw_item(renderer, item, released, release_backend)
    if type(item) ~= "table" then
        return 0
    end
    local count = 0
    local cpu_vertices = rawget(item, "cpu_vertices")
    local cpu_vertex_data =
        type(cpu_vertices) == "table" and rawget(cpu_vertices, "vdata")
        or nil
    if release_scene_mesh_once(cpu_vertex_data, released) then
        count = count + 1
    end
    item.cpu_vertices = nil
    local instance_batch = rawget(item, "_instance_resource_batch")
    local static_batch = rawget(item, "_static_resource_batch")
    local batch = instance_batch or static_batch
    if batch then
        local batch_already_released = released[batch] == true
        released[batch] = true
        if instance_batch and not batch_already_released
            and item.kind == "instanced_primitive" then
            renderer._primitive_instanced_batch_count = math.max(
                0, (renderer._primitive_instanced_batch_count or 0) - 1)
            renderer._primitive_instanced_object_count = math.max(
                0,
                (renderer._primitive_instanced_object_count or 0)
                    - math.max(0, tonumber(item.count or item.primitive_count) or 0)
            )
        end
        note_backend_batch_aliases(batch, released)
        if release_backend
            and not batch_already_released
            and renderer:_release_opaque_cube_batch(batch) then
            count = count + 1
        end
        item._instance_resource_batch = nil
        item._static_resource_batch = nil
    else
        -- Attached draw meshes first, then their per-instance source buffers
        if release_scene_mesh_once(item.draw_mesh or item.mesh, released) then
            count = count + 1
        end
        if item.mesh ~= item.draw_mesh
            and release_scene_mesh_once(item.mesh, released) then
            count = count + 1
        end
        if release_scene_mesh_once(item.instance_mesh, released) then
            count = count + 1
        end
    end
    item.mesh = nil
    item.draw_mesh = nil
    item.instance_mesh = nil
    return count
end

local function release_scene_draw_list(renderer, list, released, release_backend)
    local count = 0
    for index = 1, #(list or {}) do
        count = count + release_scene_draw_item(
            renderer, list[index], released, release_backend)
    end
    return count
end

function RBX:_release_chunk_cube_meshes(chunk, released, release_backend)
    if type(chunk) ~= "table" then
        return 0
    end
    released = released or {}
    local count = 0
    local batch = chunk._cube_instance_batch
    if batch then
        note_backend_batch_aliases(batch, released)
        if release_backend ~= false and self:_release_opaque_cube_batch(batch) then
            count = count + 1
        end
        chunk._cube_instance_batch = nil
    else
        if release_scene_mesh_once(chunk.cube_draw_mesh, released) then
            count = count + 1
        end
        if release_scene_mesh_once(chunk.instance_mesh, released) then
            count = count + 1
        end
    end
    if release_scene_mesh_once(chunk.static_cube_mesh, released) then
        count = count + 1
    end
    chunk.cube_draw_mesh = nil
    chunk.instance_mesh = nil
    chunk.static_cube_mesh = nil
    return count
end

function RBX:_release_scene_chunk_meshes(chunk, released, release_backend)
    if type(chunk) ~= "table" then
        return 0
    end
    released = released or {}
    for _, item in ipairs(chunk.transparent_draw_items or {}) do
        local recipe = item._material_pose_recipe
        if recipe and recipe.data then
            recipe.floats = nil
            recipe.data:release()
            recipe.data = nil
        end
        item._material_pose_recipe = nil
    end
    chunk._primitive_pose_structure = nil
    local count = self:_release_chunk_cube_meshes(
        chunk, released, release_backend)
    count = count + require('engine/graphics/rbx/runtime/retained_primitive_decal').release(self,chunk)
    count = count + release_scene_draw_list(
        self, chunk.opaque_static_draw_items, released, release_backend)
    count = count + release_scene_draw_list(
        self, chunk.textured_batches, released, release_backend)
    count = count + release_scene_draw_list(
        self, chunk.overlay_textured_batches, released, release_backend)
    count = count + release_scene_draw_list(
        self, chunk.transparent_draw_items, released, release_backend)
    count = count + release_scene_draw_list(
        self, chunk.surface_gui_batches, released, release_backend)
    return count
end

-- full rebuilds replace these meshes atomically from the renderer's point of
-- view. retire the previous raw LOVE generation immediately instead of waiting
-- for a later Lua GC/driver collection. Images, canvases and persistent asset
-- caches are deliberately outside this mesh-only traversal
function RBX:_release_scene_mesh_generation()
    if self._sever_transparent_textured_range_groups then
        -- Aggregates are about to be detached by the centralized discard
        -- Sever transparent range aliases while every derived chunk is still
        -- reachable (the legacy physics sleeper path may contain them)
        self:_sever_transparent_textured_range_groups()
    end
    local released = {}
    local count = 0
    if self._discard_settled_merge_generation then
        -- derived aggregates are not in _scene_chunks. retire their committed
        -- and partially-built ownership before traversing the authoritative
        -- generation, the backend reset immediately after this function owns
        -- backend batches, so only sever aliases here
        local _, settled_count = self:_discard_settled_merge_generation(
            "scene_generation_release", false, false, released)
        count = count + (settled_count or 0)
    end
    -- Cluster resources alias backend-owned meshes but are not part of the
    -- source chunk lists. drop their aliases before the backend generation
    -- reset that immediately follows this traversal
    self:_release_static_local_light_clusters(false)
    for index = 1, #(self._scene_chunks or {}) do
        count = count + self:_release_scene_chunk_meshes(
            self._scene_chunks[index], released, false)
    end
    for _, chunk in pairs(self._dormant_dynamic_scene_chunk_map or {}) do
        count = count + self:_release_scene_chunk_meshes(
            chunk, released, false)
    end
    self._dormant_dynamic_scene_chunk_map = nil
    count = count + self:_release_scene_chunk_meshes(
        self._settled_merge_chunk, released, false)
    local pending = self._settled_merge_pending
    count = count + self:_release_scene_chunk_meshes(
        type(pending) == "table" and pending.chunk or nil, released, false)

    for _, list in pairs({
        self._opaque_static_draw_items,
        self._mega_static_draw_items,
        self._textured_batches,
        self._mega_textured_batches,
        self._mega_overlay_textured_batches,
        self._transparent_draw_items,
        self._instanced_mesh_groups,
    }) do
        count = count + release_scene_draw_list(self, list, released, false)
    end

    for _, resource in pairs({
        self._mega_cube_draw_mesh,
        self._mega_instance_mesh,
        self._mega_dynamic_cube_draw_mesh,
        self._mega_dynamic_instance_mesh,
        self._instance_draw_mesh,
        self._instance_mesh,
        self._static_mesh,
    }) do
        if release_scene_mesh_once(resource, released) then
            count = count + 1
        end
    end
    note_backend_batch_aliases(self._mega_cube_batch, released)
    note_backend_batch_aliases(self._mega_dynamic_cube_batch, released)
    self._lifecycle_scene_generation_release_count =
        (self._lifecycle_scene_generation_release_count or 0) + count
    if self._sever_transparent_textured_range_groups then
        self:_sever_transparent_textured_range_groups()
    end
    return count
end

local function visit_scene_transparent_items(renderer, callback)
    local seen_items = {}

    local function visit_list(list)
        for index = 1, #(list or {}) do
            local item = list[index]
            if type(item) == "table" and not seen_items[item] then
                seen_items[item] = true
                callback(item)
            end
        end
    end

    local function visit_chunk(chunk)
        if type(chunk) == "table" then
            visit_list(chunk.transparent_draw_items)
        end
    end

    for index = 1, #(renderer._scene_chunks or {}) do
        visit_chunk(renderer._scene_chunks[index])
    end
    for index = 1, #(renderer._settled_merge_chunks or {}) do
        visit_chunk(renderer._settled_merge_chunks[index])
    end
    visit_chunk(renderer._settled_merge_chunk)
    local pending = renderer._settled_merge_pending
    if type(pending) == "table" then
        for index = 1, #(pending.chunks or {}) do
            visit_chunk(pending.chunks[index])
        end
        visit_chunk(pending.current_chunk or pending.chunk)
    end
    visit_list(renderer._transparent_draw_items)
end

function RBX:_sever_transparent_textured_range_groups()
    local groups = self._transparent_textured_range_groups
    for group_index = 1, #(groups or {}) do
        local group = groups[group_index]
        for source_index = 1,
            #(group.source_items or {}) do
            local item = group.source_items[source_index]
            if item
                and item._transparent_range_group == group then
                item._transparent_range_group = nil
                item._transparent_range_shader = nil
                item._transparent_range_base_first = nil
                item._transparent_range_first = nil
                item._transparent_range_count = nil
                item._transparent_range_build_light_payload = nil
                item._transparent_range_light_payload = nil
                item._transparent_range_light_revision = nil
                item._transparent_range_light_configuration_key =
                    nil
                item._transparent_range_light_shader = nil
                item._transparent_range_order_seen_token = nil
                item._transparent_range_pending_first = nil
            end
        end
        group.mesh = nil
        group.shader = nil
        group.source_items = nil
        group.vertex_map = nil
        group.current_order = nil
        group._order_scratch = nil
    end
    self._transparent_textured_range_groups = nil
    self._transparent_textured_range_groups_pending = nil
    self._transparent_textured_range_build_state = nil
    return true
end

local function release_flat_vertex_payload(vertices, released)
    local data = type(vertices) == "table" and vertices.vdata or nil
    if not data or (released and released[data]) then
        return false
    end
    if released then
        released[data] = true
    end
    local ok, release = pcall(function()
        return data.release
    end)
    if not ok or type(release) ~= "function" then
        return false
    end
    local release_ok, did_release = pcall(release, data)
    if release_ok then
        vertices.vdata = nil
        vertices.vbuf = nil
        vertices.vbuf_cap = nil
        vertices.vbuf_n = 0
    end
    return release_ok and did_release ~= false
end

function RBX:_release_transparent_textured_range_cpu_vertices()
    local released = {}
    local seen_items = {}
    local item_count = 0
    local byte_count = 0
    local function release_item(item)
        if type(item) ~= "table" or seen_items[item] then
            return
        end
        seen_items[item] = true
        local vertices = item.cpu_vertices
        if type(vertices) == "table" then
            local vertex_count = math.max(
                0,
                math.floor(
                    tonumber(item.vertex_count)
                        or rbx_vertex_list_count(vertices)
                        or 0
                )
            )
            byte_count = byte_count + vertex_count * 20 * 4
            if release_flat_vertex_payload(vertices, released) then
                item_count = item_count + 1
            end
            item.cpu_vertices = nil
        end
    end
    visit_scene_transparent_items(self, release_item)

    -- a source can leave its chunk while an incremental build plan still owns
    -- the discovery record (for example, a static part is promoted or
    -- destroyed between slices). release those otherwise-unreachable payloads
    -- as well, they must never survive a cancelled plan through an external
    -- Lua reference
    local state = self._transparent_textured_range_build_state
    local records = type(state) == "table" and state.records or nil
    for index = 1,
        (type(state) == "table" and state.record_count or 0) do
        local record = records and records[index] or nil
        release_item(record and record.item)
    end
    return item_count, byte_count
end

function RBX:_cancel_transparent_textured_range_build(reason)
    local state = self._transparent_textured_range_build_state
    if type(state) ~= "table" then
        return false
    end
    self:_release_transparent_textured_range_cpu_vertices()
    self._transparent_textured_range_build_state = nil
    self._transparent_textured_range_groups_pending = false
    local stats = state.stats
        or self._transparent_textured_range_stats
        or {}
    self._transparent_textured_range_stats = stats
    stats.build_cancelled = true
    stats.build_complete = true
    stats.pending_group_count = 0
    stats.cancellation_reason = reason or "cancelled"
    if (stats.built_group_count or 0) == 0 then
        stats.inactive_reason = stats.cancellation_reason
    end
    return true
end

local function normalized_transparent_range_depth_compare(item)
    if item and item.depth_compare == "always" then
        return "always"
    end
    if item and item.depth_compare == "lequal" then
        return "lequal"
    end
    return "less"
end

local function transparent_range_resolved_cull(renderer, item)
    return item.resolved_cull_mode or renderer:_resolve_cull_mode(
        item.cull_mode or "none",
        item.mirror_cull_swap == true,
        item.force_cull == true)
end

local function transparent_range_item_record(
    renderer, item, get_textured_shader, spatial_cell)
    if type(item) ~= "table"
        or item.kind ~= "textured"
        or item.dynamic_chunk == true
        or item.source_kind == "SurfaceGui"
        or item.source_transparent_part ~= true
        or not item.mesh
        or type(item.cpu_vertices) ~= "table" then
        return nil
    end

    local vertex_count = math.max(
        0,
        math.floor(
            tonumber(item.vertex_count)
                or rbx_vertex_list_count(item.cpu_vertices)
                or 0
        )
    )
    if vertex_count <= 0 then
        return nil
    end

    local shader = get_textured_shader
        and get_textured_shader(item)
        or item.shader
    if not shader then
        return nil
    end

    local light_payload = "no-local-light-uniform"
    if renderer:_shader_supports_local_lights(shader) then
        light_payload = RBX._local_light_pack_payload_key(
            renderer:_get_local_light_pack_for_item(item))
    end

    local bounds = item.bounds
    local x = item.sort_x or (bounds and bounds.center_x) or 0
    local y = item.sort_y or (bounds and bounds.center_y) or 0
    local z = item.sort_z or (bounds and bounds.center_z) or 0
    return {
        item = item,
        shader = shader,
        texture = item.texture,
        uniform_state_key = item.uniform_state_key,
        render_priority = item.render_priority or 0,
        depth_compare =
            normalized_transparent_range_depth_compare(item),
        depth_bias = item.depth_bias
            or renderer.transparent_depth_bias
            or 0,
        cull_mode =
            transparent_range_resolved_cull(renderer, item),
        blend_class = shader == renderer._overlay_textured_shader
            and "premultiplied"
            or "alphamultiply",
        flip_u = item.flip_u == true,
        flip_v = item.flip_v == true,
        use_material_maps =
            item.use_material_maps == true,
        use_textured_lighting =
            item.use_textured_lighting ~= false,
        light_influence = math.max(
            0,
            math.min(
                1,
                tonumber(item.light_influence) or 1)),
        brightness = math.max(
            0, tonumber(item.brightness) or 1),
        use_normal_map = item.use_normal_map == true,
        normal_texture =
            item.normal_texture
                or renderer._flat_normal_texture,
        detail_normal_texture =
            item.detail_normal_texture
                or renderer._flat_normal_texture,
        detail_normal_mix = item.detail_normal_mix or 0,
        detail_contrast = item.detail_contrast or 1,
        texture_color_mix = item.texture_color_mix or 1,
        texture_premultiplied =
            item.texture_premultiplied == true,
        vertex_color_premultiplied =
            item.vertex_color_premultiplied == true,
        roughness_texture =
            item.roughness_texture
                or (item.surface_appearance == true
                    and renderer._roughness_half_texture)
                or renderer._white_texture,
        metalness_texture =
            item.metalness_texture
                or renderer._black_texture,
        emissive_texture =
            item.emissive_texture
                or renderer._black_texture,
        surface_appearance = item.surface_appearance == true,
        surface_signature = item.surface_signature,
        surface_route = item.surface_route,
        ignore_texture_alpha =
            item.ignore_texture_alpha == true,
        mesh_debug_mode_id =
            item.mesh_debug_mode_id
                or RBX._get_mesh_debug_mode_id(
                    item.mesh_debug_mode),
        light_payload = light_payload,
        cell_x = math.floor(x / spatial_cell),
        cell_y = math.floor(y / spatial_cell),
        cell_z = math.floor(z / spatial_cell),
        vertex_count = vertex_count,
        vertex_bytes = vertex_count * 20 * 4,
    }
end

local function transparent_range_records_compatible(a, b)
    return a ~= nil
        and b ~= nil
        and a.shader == b.shader
        and a.texture == b.texture
        and a.uniform_state_key == b.uniform_state_key
        and a.render_priority == b.render_priority
        and a.depth_compare == b.depth_compare
        and a.depth_bias == b.depth_bias
        and a.cull_mode == b.cull_mode
        and a.blend_class == b.blend_class
        and a.flip_u == b.flip_u
        and a.flip_v == b.flip_v
        and a.use_material_maps == b.use_material_maps
        and a.use_textured_lighting
            == b.use_textured_lighting
        and a.light_influence == b.light_influence
        and a.brightness == b.brightness
        and a.use_normal_map == b.use_normal_map
        and a.normal_texture == b.normal_texture
        and a.detail_normal_texture
            == b.detail_normal_texture
        and a.detail_normal_mix == b.detail_normal_mix
        and a.detail_contrast == b.detail_contrast
        and a.texture_color_mix == b.texture_color_mix
        and a.texture_premultiplied
            == b.texture_premultiplied
        and a.vertex_color_premultiplied
            == b.vertex_color_premultiplied
        and a.roughness_texture == b.roughness_texture
        and a.metalness_texture == b.metalness_texture
        and a.emissive_texture == b.emissive_texture
        and a.surface_appearance == b.surface_appearance
        and a.surface_signature == b.surface_signature
        and a.surface_route == b.surface_route
        and a.ignore_texture_alpha
            == b.ignore_texture_alpha
        and a.mesh_debug_mode_id == b.mesh_debug_mode_id
        and a.light_payload == b.light_payload
        and a.cell_x == b.cell_x
        and a.cell_y == b.cell_y
        and a.cell_z == b.cell_z
end

local function transparent_range_items_uniforms_compatible(
    renderer, a, b)
    return (a.flip_u == true) == (b.flip_u == true)
        and (a.flip_v == true) == (b.flip_v == true)
        and (a.use_material_maps == true)
            == (b.use_material_maps == true)
        and (a.use_textured_lighting ~= false)
            == (b.use_textured_lighting ~= false)
        and math.max(
            0,
            math.min(
                1,
                tonumber(a.light_influence) or 1))
            == math.max(
                0,
                math.min(
                    1,
                    tonumber(b.light_influence) or 1))
        and math.max(0, tonumber(a.brightness) or 1)
            == math.max(0, tonumber(b.brightness) or 1)
        and (a.use_normal_map == true)
            == (b.use_normal_map == true)
        and (a.normal_texture
                or renderer._flat_normal_texture)
            == (b.normal_texture
                or renderer._flat_normal_texture)
        and (a.detail_normal_texture
                or renderer._flat_normal_texture)
            == (b.detail_normal_texture
                or renderer._flat_normal_texture)
        and (a.detail_normal_mix or 0)
            == (b.detail_normal_mix or 0)
        and (a.detail_contrast or 1)
            == (b.detail_contrast or 1)
        and (a.texture_color_mix or 1)
            == (b.texture_color_mix or 1)
        and (a.texture_premultiplied == true)
            == (b.texture_premultiplied == true)
        and (a.vertex_color_premultiplied == true)
            == (b.vertex_color_premultiplied == true)
        and (a.roughness_texture
                or (a.surface_appearance == true
                    and renderer._roughness_half_texture)
                or renderer._white_texture)
            == (b.roughness_texture
                or (b.surface_appearance == true
                    and renderer._roughness_half_texture)
                or renderer._white_texture)
        and (a.metalness_texture
                or renderer._black_texture)
            == (b.metalness_texture
                or renderer._black_texture)
        and (a.emissive_texture
                or renderer._black_texture)
            == (b.emissive_texture
                or renderer._black_texture)
        and (a.surface_appearance == true)
            == (b.surface_appearance == true)
        and a.surface_signature == b.surface_signature
        and a.surface_route == b.surface_route
        and (a.ignore_texture_alpha == true)
            == (b.ignore_texture_alpha == true)
        and (a.mesh_debug_mode_id
                or RBX._get_mesh_debug_mode_id(
                    a.mesh_debug_mode))
            == (b.mesh_debug_mode_id
                or RBX._get_mesh_debug_mode_id(
                    b.mesh_debug_mode))
end

local function build_transparent_range_mesh(renderer, candidate)
    local all_flat = true
    for index = candidate.first, candidate.last do
        if candidate.records[index].item.cpu_vertices.vbuf == nil then
            all_flat = false
            break
        end
    end

    local merged_vertices =
        all_flat and rbx_create_flat_vertex_list() or {}
    if all_flat and not merged_vertices then
        all_flat = false
        merged_vertices = {}
    end

    local ok_append, append_error = pcall(function()
        for index = candidate.first, candidate.last do
            local source = candidate.records[index].item.cpu_vertices
            if all_flat then
                rbx_flat_vertex_list_append(merged_vertices, source)
            else
                local source_tables = source
                if source.vbuf ~= nil then
                    source_tables =
                        rbx_flat_vertex_list_to_tables(source)
                end
                for vertex_index = 1, #source_tables do
                    merged_vertices[#merged_vertices + 1] =
                        source_tables[vertex_index]
                end
            end
        end
    end)
    if not ok_append then
        release_flat_vertex_payload(merged_vertices)
        return nil, append_error
    end

    local mesh
    local packed
    local ok_mesh, mesh_error = pcall(function()
        packed = rbx_pack_vertices_bytedata(
            merged_vertices, 20)
        mesh = love.graphics.newMesh(
            renderer._textured_vertex_format,
            candidate.vertex_count,
            "triangles",
            "static")
        if packed then
            mesh:setVertices(packed)
        else
            local table_vertices = merged_vertices
            if merged_vertices.vbuf ~= nil then
                table_vertices =
                    rbx_flat_vertex_list_to_tables(
                        merged_vertices)
            end
            mesh:setVertices(table_vertices)
        end
        mesh:setTexture(
            candidate.records[candidate.first].item.texture
                or renderer._white_texture)
    end)
    if packed then
        pcall(packed.release, packed)
    end
    release_flat_vertex_payload(merged_vertices)
    if not ok_mesh then
        if mesh then
            pcall(mesh.release, mesh)
        end
        return nil, mesh_error
    end
    return mesh
end

-- Replaces only profitable, exact adjacent textured runs from the first
-- sorted transparent frame. each source item keeps its own bounds and sort
-- identity but points at a disjoint draw range in a shared mesh. Later camera
-- orders therefore either collapse a forward-contiguous range or draw the
-- original source ranges independently, geometry is never resorted by merged
-- bounds and persistent vertex data is not duplicated
function RBX:_build_transparent_textured_range_groups(
    sorted_items, get_textured_shader, incremental)
    if self._transparent_textured_range_groups_pending ~= true then
        return false
    end
    self._transparent_textured_range_groups_pending = false

    local started_at = love.timer.getTime()
    local stats = {
        enabled =
            self.enable_transparent_textured_range_aggregation ~= false,
        candidate_run_count = 0,
        candidate_source_draw_count = 0,
        candidate_saved_draw_count = 0,
        candidate_vertex_bytes = 0,
        built_group_count = 0,
        merged_source_draw_count = 0,
        theoretical_saved_draw_count = 0,
        uploaded_vertex_bytes = 0,
        released_source_mesh_count = 0,
        budget_skipped_run_count = 0,
        budget_skipped_source_draw_count = 0,
        build_failure_count = 0,
    }
    self._transparent_textured_range_stats = stats
    self._transparent_textured_range_groups = {}

    if self.enable_transparent_textured_range_aggregation == false then
        stats.inactive_reason = "disabled"
        self:_release_transparent_textured_range_cpu_vertices()
        stats.build_ms =
            math.max(0, (love.timer.getTime() - started_at) * 1000)
        return false
    end

    local spatial_cell = math.max(
        8,
        tonumber(self.local_light_grid_cell_size) or 64)
        * math.max(
            1,
            math.floor(
                tonumber(self.local_light_cluster_supercell_span)
                    or 2))
    local max_sources_per_group = math.max(
        2,
        math.floor(
            tonumber(
                self.transparent_textured_range_max_sources_per_group)
                or 32))
    local records = {}
    local record_count = #(sorted_items or {})
    for index = 1, record_count do
        local record = transparent_range_item_record(
            self,
            sorted_items[index],
            get_textured_shader,
            spatial_cell)
        if record then
            record.source_order = index
        end
        records[index] = record
    end

    -- Bucket every compatible visible source, not just today's adjacent
    -- pairs. the mesh stores each source once, a small vertex map is reordered
    -- after a settled camera sort, allowing future A->B, B->A, and longer runs
    -- without one duplicate mesh per observed direction
    local buckets = {}
    for index = 1, record_count do
        local record = records[index]
        if record then
            local bucket
            for bucket_index = 1, #buckets do
                local candidate_bucket = buckets[bucket_index]
                if transparent_range_records_compatible(
                    candidate_bucket.representative, record) then
                    bucket = candidate_bucket
                    break
                end
            end
            if not bucket then
                bucket = {
                    representative = record,
                    records = {},
                    source_order = index,
                }
                buckets[#buckets + 1] = bucket
            end
            bucket.records[#bucket.records + 1] = record
            record.bucket = bucket
        end
    end

    local candidates = {}
    for bucket_index = 1, #buckets do
        local bucket = buckets[bucket_index]
        local chunk_first = 1
        while chunk_first <= #bucket.records do
            local chunk_last = math.min(
                #bucket.records,
                chunk_first + max_sources_per_group - 1)
            if chunk_last - chunk_first + 1 >= 2 then
                local candidate_records = {}
                local vertex_count = 0
                local vertex_bytes = 0
                for source_index = chunk_first, chunk_last do
                    local record = bucket.records[source_index]
                    candidate_records[
                        #candidate_records + 1] = record
                    vertex_count =
                        vertex_count + record.vertex_count
                    vertex_bytes =
                        vertex_bytes + record.vertex_bytes
                end
                candidates[#candidates + 1] = {
                    records = candidate_records,
                    first = 1,
                    last = #candidate_records,
                    source_count = #candidate_records,
                    saved_draws = 0,
                    vertex_count = vertex_count,
                    vertex_bytes = vertex_bytes,
                    source_order =
                        candidate_records[1].source_order,
                }
                local candidate = candidates[#candidates]
                for source_index = 1, #candidate_records do
                    candidate_records[source_index].candidate =
                        candidate
                end
            end
            chunk_first = chunk_last + 1
        end
    end

    -- only buckets with a real current-frame win are worth replacing. the
    -- remaining members of such a bucket are included so a later camera order
    -- can form different runs by changing only the compact vertex map
    for index = 2, record_count do
        local previous = records[index - 1]
        local current = records[index]
        if previous
            and current
            and previous.candidate ~= nil
            and previous.candidate == current.candidate then
            previous.candidate.saved_draws =
                previous.candidate.saved_draws + 1
        end
    end
    local profitable_candidates = {}
    for index = 1, #candidates do
        local candidate = candidates[index]
        if candidate.saved_draws > 0 then
            profitable_candidates[
                #profitable_candidates + 1] = candidate
        else
            for record_index = 1, #candidate.records do
                candidate.records[record_index].candidate = nil
            end
        end
    end
    candidates = profitable_candidates

    for index = 1, #candidates do
        local candidate = candidates[index]
        stats.candidate_run_count =
            stats.candidate_run_count + 1
        stats.candidate_source_draw_count =
            stats.candidate_source_draw_count
                + candidate.source_count
        stats.candidate_saved_draw_count =
            stats.candidate_saved_draw_count
                + candidate.saved_draws
        stats.candidate_vertex_bytes =
            stats.candidate_vertex_bytes
                + candidate.vertex_bytes
    end

    local minimum_savings = math.max(
        1,
        math.floor(
            tonumber(
                self.transparent_textured_range_min_saved_draws)
                or 6))
    if stats.candidate_saved_draw_count < minimum_savings then
        stats.inactive_reason = "below_savings_threshold"
        self:_release_transparent_textured_range_cpu_vertices()
        stats.build_ms =
            math.max(0, (love.timer.getTime() - started_at) * 1000)
        return false
    end

    table.sort(candidates, function(a, b)
        if a.saved_draws ~= b.saved_draws then
            return a.saved_draws > b.saved_draws
        end
        if a.vertex_bytes ~= b.vertex_bytes then
            return a.vertex_bytes < b.vertex_bytes
        end
        return a.source_order < b.source_order
    end)

    local max_groups = math.max(
        1,
        math.floor(
            tonumber(self.transparent_textured_range_max_groups)
                or 64))
    local max_vertex_bytes = math.max(
        0,
        math.floor(
            tonumber(
                self.transparent_textured_range_max_vertex_bytes)
                or (16 * 1024 * 1024)))
    local mesh_ref_counts = {}
    visit_scene_transparent_items(self, function(item)
        local mesh = item.mesh
        if mesh then
            mesh_ref_counts[mesh] =
                (mesh_ref_counts[mesh] or 0) + 1
        end
    end)

    stats.prepare_ms =
        math.max(0, (love.timer.getTime() - started_at) * 1000)
    stats.build_ms = stats.prepare_ms
    stats.build_complete = false
    stats.pending_group_count = #candidates
    self._transparent_textured_range_build_state = {
        candidates = candidates,
        records = records,
        record_count = record_count,
        next_candidate_index = 1,
        max_groups = max_groups,
        max_vertex_bytes = max_vertex_bytes,
        mesh_ref_counts = mesh_ref_counts,
        released_source_meshes = {},
        uploaded_bytes = 0,
        stats = stats,
        slice_ms = 0,
    }
    return self:_advance_transparent_textured_range_build(
        sorted_items, incremental ~= true)
end

local function remap_transparent_range_static_index(
    renderer, part_id, old_mesh, old_first, count,
    new_mesh, new_first)
    local slot = renderer._static_part_geo
        and renderer._static_part_geo[part_id]
    if type(slot) ~= "table" then
        return false
    end
    local matched = false
    for index = 1, #slot, 3 do
        if slot[index] == old_mesh
            and slot[index + 1] == old_first
            and slot[index + 2] == count then
            slot[index] = new_mesh
            slot[index + 1] = new_first
            matched = true
        end
    end
    return matched
end

-- build immutable shared payloads in bounded slices. Candidate discovery is
-- cheap, but uploading several megabytes of transparent geometry in one first
-- frame produced a visible load-completion spike on a large map. one candidate
-- group is now committed per frame by default, source meshes remain valid
-- until their replacement group is ready, so partial progress renders exactly
-- like the original scene
function RBX:_advance_transparent_textured_range_build(
    sorted_items, finish_all)
    local state = self._transparent_textured_range_build_state
    if type(state) ~= "table" then
        return false, true
    end

    local stats = state.stats
        or self._transparent_textured_range_stats
        or {}
    state.stats = stats
    self._transparent_textured_range_stats = stats

    if finish_all ~= true
        and self._camera_motion_state == "moving"
        and self.transparent_textured_range_build_while_moving
            ~= true then
        stats.motion_deferred_build_count =
            (stats.motion_deferred_build_count or 0) + 1
        return false, false
    end

    local slice_started_at = love.timer.getTime()
    local max_groups_this_slice = finish_all == true
        and math.huge
        or math.max(
            1,
            math.floor(
                tonumber(
                    self.transparent_textured_range_max_groups_per_frame)
                    or 1))
    local slice_budget_ms = finish_all == true
        and math.huge
        or math.max(
            0,
            tonumber(
                self.transparent_textured_range_build_budget_ms)
                or 2)
    local processed_group_count = 0
    local built_group_count = 0
    local range_index_needs_rebuild = false

    while state.next_candidate_index <= #state.candidates do
        if processed_group_count >= max_groups_this_slice then
            break
        end
        if processed_group_count > 0
            and (love.timer.getTime() - slice_started_at) * 1000
                >= slice_budget_ms then
            break
        end

        local candidate =
            state.candidates[state.next_candidate_index]
        state.next_candidate_index =
            state.next_candidate_index + 1
        local over_group_budget =
            stats.built_group_count >= state.max_groups
        local over_byte_budget =
            candidate.vertex_bytes > state.max_vertex_bytes
                - state.uploaded_bytes
        if over_group_budget or over_byte_budget then
            stats.budget_skipped_run_count =
                stats.budget_skipped_run_count + 1
            stats.budget_skipped_source_draw_count =
                stats.budget_skipped_source_draw_count
                    + candidate.source_count
        else
            processed_group_count = processed_group_count + 1
            local group_build_started_at = love.timer.getTime()
            local merged_mesh, build_error =
                build_transparent_range_mesh(self, candidate)
            local group_build_ms = math.max(
                0,
                (love.timer.getTime() - group_build_started_at)
                    * 1000)
            stats.last_group_build_ms = group_build_ms
            stats.peak_group_build_ms = math.max(
                stats.peak_group_build_ms or 0,
                group_build_ms)
            stats.peak_group_vertex_bytes = math.max(
                stats.peak_group_vertex_bytes or 0,
                candidate.vertex_bytes)
            if not merged_mesh then
                stats.build_failure_count =
                    stats.build_failure_count + 1
                stats.last_build_error = tostring(build_error)
            else
                local group = {
                    mesh = merged_mesh,
                    shader =
                        candidate.records[
                            candidate.first].shader,
                    source_items = {},
                    source_count = candidate.source_count,
                    vertex_count = candidate.vertex_count,
                    vertex_bytes = candidate.vertex_bytes,
                    vertex_map = {},
                    current_order = {},
                    build_scene_revision =
                        self._scene_revision or 0,
                }
                local touched_meshes = {}
                local vertex_base = 0
                for source_index = candidate.first,
                    candidate.last do
                    local record =
                        candidate.records[source_index]
                    local item = record.item
                    local old_mesh = item.mesh
                    group.source_items[
                        #group.source_items + 1] = item
                    item.mesh = merged_mesh
                    item._transparent_range_group = group
                    item._transparent_range_shader =
                        record.shader
                    item._transparent_range_base_first =
                        vertex_base + 1
                    item._transparent_range_first =
                        vertex_base + 1
                    item._transparent_range_count =
                        record.vertex_count
                    item._transparent_range_build_light_payload =
                        record.light_payload
                    if type(item.part_ranges) == "table" then
                        for range_index = 1,
                            #item.part_ranges, 3 do
                            local part_id =
                                item.part_ranges[range_index]
                            local old_first =
                                item.part_ranges[range_index + 1]
                            local count =
                                item.part_ranges[range_index + 2]
                            local new_first =
                                old_first + vertex_base
                            if not remap_transparent_range_static_index(
                                self,
                                part_id,
                                old_mesh,
                                old_first,
                                count,
                                merged_mesh,
                                new_first) then
                                range_index_needs_rebuild = true
                            end
                            item.part_ranges[range_index + 1] =
                                new_first
                        end
                    end
                    vertex_base =
                        vertex_base + record.vertex_count
                    if old_mesh then
                        state.mesh_ref_counts[old_mesh] =
                            (state.mesh_ref_counts[old_mesh] or 1) - 1
                        touched_meshes[old_mesh] = true
                    end
                end
                self._transparent_textured_range_groups[
                    #self._transparent_textured_range_groups + 1] =
                    group
                stats.built_group_count =
                    stats.built_group_count + 1
                stats.merged_source_draw_count =
                    stats.merged_source_draw_count
                        + candidate.source_count
                stats.theoretical_saved_draw_count =
                    stats.theoretical_saved_draw_count
                        + candidate.saved_draws
                stats.uploaded_vertex_bytes =
                    stats.uploaded_vertex_bytes
                        + candidate.vertex_bytes
                state.uploaded_bytes =
                    state.uploaded_bytes + candidate.vertex_bytes
                self:_note_gpu_upload_bytes(
                    candidate.vertex_bytes)
                self:_note_load_cache_stat(
                    "gpu_mesh_upload_count")
                self._mesh_uploads_total =
                    (self._mesh_uploads_total or 0) + 1
                built_group_count = built_group_count + 1

                for mesh in pairs(touched_meshes) do
                    if (state.mesh_ref_counts[mesh] or 0) <= 0
                        and not state.released_source_meshes[mesh] then
                        state.released_source_meshes[mesh] = true
                        if release_scene_mesh_once(mesh, {}) then
                            stats.released_source_mesh_count =
                                stats.released_source_mesh_count + 1
                        end
                    end
                end
            end
        end
    end

    if range_index_needs_rebuild
        and self._index_static_part_ranges then
        local range_index_started_at = love.timer.getTime()
        self:_index_static_part_ranges(
            self._scene_chunks or {})
        local range_index_ms = math.max(
            0,
            (love.timer.getTime() - range_index_started_at)
                * 1000)
        stats.range_index_rebuild_count =
            (stats.range_index_rebuild_count or 0) + 1
        stats.peak_range_index_ms = math.max(
            stats.peak_range_index_ms or 0,
            range_index_ms)
    end

    if built_group_count > 0 then
        local refresh_started_at = love.timer.getTime()
        self:_refresh_transparent_textured_range_vertex_maps(
            sorted_items, false)
        local refresh_ms = math.max(
            0,
            (love.timer.getTime() - refresh_started_at) * 1000)
        stats.peak_build_refresh_ms = math.max(
            stats.peak_build_refresh_ms or 0,
            refresh_ms)
    end

    local slice_ms =
        math.max(0, (love.timer.getTime() - slice_started_at) * 1000)
    state.slice_ms = (state.slice_ms or 0) + slice_ms
    stats.build_slice_count =
        (stats.build_slice_count or 0) + 1
    stats.last_build_slice_ms = slice_ms
    stats.peak_build_slice_ms =
        math.max(stats.peak_build_slice_ms or 0, slice_ms)
    stats.build_ms = (stats.prepare_ms or 0) + state.slice_ms

    local complete =
        state.next_candidate_index > #state.candidates
    stats.pending_group_count = complete
        and 0
        or (#state.candidates
            - state.next_candidate_index + 1)
    stats.build_complete = complete
    if complete then
        self:_release_transparent_textured_range_cpu_vertices()
        self._transparent_textured_range_build_state = nil
        if stats.built_group_count == 0 then
            stats.inactive_reason =
                stats.build_failure_count > 0
                    and "build_failed"
                    or "budget_exhausted"
        end
    end
    return built_group_count > 0, complete
end

function RBX:_refresh_transparent_textured_range_vertex_maps(
    sorted_items, force)
    local groups = self._transparent_textured_range_groups
    if type(groups) ~= "table" or #groups == 0 then
        return 0
    end

    local stats =
        self._transparent_textured_range_stats or {}
    self._transparent_textured_range_stats = stats
    if not force
        and self._camera_motion_state == "moving"
        and self.transparent_textured_range_refresh_while_moving
            ~= true then
        stats.motion_deferred_refresh_count =
            (stats.motion_deferred_refresh_count or 0) + 1
        return 0
    end

    local token =
        (self._transparent_textured_range_order_token or 0) + 1
    self._transparent_textured_range_order_token = token
    for group_index = 1, #groups do
        local group = groups[group_index]
        local ordered = group._order_scratch or {}
        group._order_scratch = ordered
        group._order_count = 0
    end

    for item_index = 1, #(sorted_items or {}) do
        local item = sorted_items[item_index]
        local group = item
            and item._transparent_range_group
            or nil
        if group and group.mesh == item.mesh then
            local count = (group._order_count or 0) + 1
            group._order_count = count
            group._order_scratch[count] = item
            item._transparent_range_order_seen_token = token
        end
    end

    local refreshed = 0
    for group_index = 1, #groups do
        local group = groups[group_index]
        local ordered = group._order_scratch
        local count = group._order_count or 0
        -- keep culled members addressable after the visible prefix. a later
        -- cull change will move them into exact sorted position and upload one
        -- new index map, while the vertex payload itself stays immutable
        for source_index = 1, #(group.source_items or {}) do
            local item = group.source_items[source_index]
            if item._transparent_range_order_seen_token ~= token then
                count = count + 1
                ordered[count] = item
            end
        end
        for stale_index = #ordered, count + 1, -1 do
            ordered[stale_index] = nil
        end

        local current_order = group.current_order or {}
        group.current_order = current_order
        local changed = force == true or #current_order ~= count
        if not changed then
            for order_index = 1, count do
                if current_order[order_index]
                    ~= ordered[order_index] then
                    changed = true
                    break
                end
            end
        end

        if changed and group.vertex_map_failed ~= true then
            local vertex_map = group.vertex_map or {}
            group.vertex_map = vertex_map
            local map_cursor = 0
            for order_index = 1, count do
                local item = ordered[order_index]
                item._transparent_range_pending_first =
                    map_cursor + 1
                local base_first =
                    item._transparent_range_base_first
                local vertex_count =
                    item._transparent_range_count or 0
                for vertex_offset = 0, vertex_count - 1 do
                    map_cursor = map_cursor + 1
                    vertex_map[map_cursor] =
                        base_first + vertex_offset
                end
            end
            for stale_index = #vertex_map,
                map_cursor + 1, -1 do
                vertex_map[stale_index] = nil
            end

            local map_ok, map_error = pcall(
                group.mesh.setVertexMap,
                group.mesh,
                vertex_map)
            if map_ok then
                for order_index = 1, count do
                    local item = ordered[order_index]
                    item._transparent_range_first =
                        item._transparent_range_pending_first
                    item._transparent_range_pending_first = nil
                    current_order[order_index] = item
                end
                for stale_index = #current_order,
                    count + 1, -1 do
                    current_order[stale_index] = nil
                end
                refreshed = refreshed + 1
                stats.vertex_map_upload_count =
                    (stats.vertex_map_upload_count or 0) + 1
                stats.vertex_map_uploaded_bytes =
                    (stats.vertex_map_uploaded_bytes or 0)
                        + map_cursor * 4
            else
                group.vertex_map_failed = true
                stats.vertex_map_failure_count =
                    (stats.vertex_map_failure_count or 0) + 1
                stats.last_vertex_map_error =
                    tostring(map_error)
                -- the immutable vertex payload is authored in the initial
                -- source order. if the very first identity-map upload fails,
                -- those base ranges remain a fully correct fallback
                for order_index = 1, count do
                    local item = ordered[order_index]
                    item._transparent_range_pending_first = nil
                    item._transparent_range_first =
                        item._transparent_range_base_first
                end
                for source_index = 1,
                    #(group.source_items or {}) do
                    current_order[source_index] =
                        group.source_items[source_index]
                end
            end
        end
    end
    stats.last_vertex_map_refresh_count = refreshed
    return refreshed
end

function RBX:_transparent_textured_range_light_payload(item)
    local shader = item
        and (item.shader
            or item._transparent_range_shader)
    if not shader or not self:_shader_supports_local_lights(shader) then
        return "no-local-light-uniform"
    end
    -- the frame normally synchronized this epoch already. keep this helper
    -- correct when called directly after a live option mutation, while using
    -- the allocation-free scalar fast path instead of rebuilding a signature
    -- string for every range item
    self:_sync_local_light_pack_configuration()
    local configuration_key =
        self._local_light_pack_configuration_signature
    local revision = self._local_light_revision or 0
    if item._transparent_range_light_revision ~= revision
        or item._transparent_range_light_configuration_key
            ~= configuration_key
        or item._transparent_range_light_shader ~= shader then
        item._transparent_range_light_payload =
            RBX._local_light_pack_payload_key(
                self:_get_local_light_pack_for_item(item))
        item._transparent_range_light_revision = revision
        item._transparent_range_light_configuration_key =
            configuration_key
        item._transparent_range_light_shader = shader
    end
    return item._transparent_range_light_payload
end

-- returns the maximal forward-contiguous shared-mesh run beginning at
-- start_index. Reverse ranges, interleaving items, changed light selections,
-- or any different render state stop the span immediately
function RBX:_transparent_textured_range_span(items, start_index)
    local first = items and items[start_index]
    local group = first
        and first._transparent_range_group
        or nil
    local first_vertex = first
        and first._transparent_range_first
        or nil
    local first_count = first
        and first._transparent_range_count
        or nil
    if not group
        or not first.mesh
        or first.mesh ~= group.mesh
        or not first_vertex
        or not first_count
        or first_count <= 0 then
        return start_index, nil
    end

    local payload =
        self:_transparent_textured_range_light_payload(first)
    local last_index = start_index
    local range_end = first_vertex + first_count - 1
    for index = start_index + 1, #(items or {}) do
        local item = items[index]
        if not item
            or item.kind ~= "textured"
            or item._transparent_range_group ~= group
            or item.mesh ~= group.mesh
            or item._transparent_range_first ~= range_end + 1
            or (item.shader
                    or item._transparent_range_shader)
                ~= (first.shader
                    or first._transparent_range_shader)
            or item.texture ~= first.texture
            or item.uniform_state_key
                ~= first.uniform_state_key
            or (item.render_priority or 0)
                ~= (first.render_priority or 0)
            or normalized_transparent_range_depth_compare(item)
                ~= normalized_transparent_range_depth_compare(first)
            or (item.depth_bias
                    or self.transparent_depth_bias
                    or 0)
                ~= (first.depth_bias
                    or self.transparent_depth_bias
                    or 0)
            or transparent_range_resolved_cull(self, item)
                ~= transparent_range_resolved_cull(self, first)
            or not transparent_range_items_uniforms_compatible(
                self, first, item)
            or self:_transparent_textured_range_light_payload(item)
                ~= payload then
            break
        end
        range_end =
            item._transparent_range_first
                + item._transparent_range_count - 1
        last_index = index
    end
    return last_index, range_end - first_vertex + 1
end

local SETTLED_PENDING_BATCH_MAP_FIELDS = {
    "opaque_textured_batch_map",
    "overlay_textured_batch_map",
    "transparent_textured_batch_map",
}

local function release_settled_pending_cpu_payloads(chunk, released)
    if type(chunk) ~= "table" then return 0 end
    released = released or {}
    local count = 0
    for field_index = 1, #SETTLED_PENDING_BATCH_MAP_FIELDS do
        local batch_map = chunk[SETTLED_PENDING_BATCH_MAP_FIELDS[field_index]]
        for _, batch in pairs(batch_map or {}) do
            if release_flat_vertex_payload(batch and batch.vertices, released) then
                count = count + 1
            end
            if batch then batch.vertices = nil end
        end
    end
    return count
end

local function release_settled_chunk(renderer, chunk, seen_chunks,
        released_resources, cpu_released, release_backend)
    if type(chunk) ~= "table" or seen_chunks[chunk] then return 0 end
    seen_chunks[chunk] = true
    release_settled_pending_cpu_payloads(chunk, cpu_released)
    return renderer:_release_scene_chunk_meshes(
        chunk, released_resources, release_backend ~= false)
end

function RBX:_discard_settled_merge_pending(reason, release_backend,
        released_resources, cpu_released, seen_chunks)
    local pending = self._settled_merge_pending
    if type(pending) ~= "table" then return false, 0 end
    seen_chunks = seen_chunks or {}
    released_resources = released_resources or {}
    cpu_released = cpu_released or {}
    local count = 0
    for index = 1, #(pending.chunks or {}) do
        count = count + release_settled_chunk(
            self, pending.chunks[index], seen_chunks,
            released_resources, cpu_released, release_backend)
    end
    count = count + release_settled_chunk(
        self, pending.current_chunk or pending.chunk,
        seen_chunks, released_resources, cpu_released, release_backend)
    for index = 1, #(pending.groups or {}) do
        local group = pending.groups[index]
        count = count + release_settled_chunk(
            self, group and group.chunk,
            seen_chunks, released_resources, cpu_released, release_backend)
        if group then
            group.chunk = nil
            group.records = nil
            group.parts = nil
        end
    end
    pending.chunks = nil
    pending.groups = nil
    pending.members = nil
    pending.ids = nil
    pending.current_chunk = nil
    pending.chunk = nil
    pending.cancel_reason = reason or "cancelled"
    self._settled_merge_pending = nil
    self._settled_merge_cancel_count =
        (self._settled_merge_cancel_count or 0) + 1
    self._settled_merge_last_cancel_reason = pending.cancel_reason
    return true, count
end

function RBX:_discard_settled_merge_committed(reason, release_backend,
        released_resources, cpu_released, seen_chunks)
    local chunks = self._settled_merge_chunks
    local legacy = self._settled_merge_chunk
    if (type(chunks) ~= "table" or #chunks == 0) and not legacy then
        self._settled_merge_ids = nil
        self._settled_merge_members = nil
        return false, 0
    end
    seen_chunks = seen_chunks or {}
    released_resources = released_resources or {}
    cpu_released = cpu_released or {}
    local count = 0
    for index = 1, #(chunks or {}) do
        count = count + release_settled_chunk(
            self, chunks[index], seen_chunks,
            released_resources, cpu_released, release_backend)
    end
    count = count + release_settled_chunk(
        self, legacy, seen_chunks,
        released_resources, cpu_released, release_backend)
    self._settled_merge_chunks = nil
    self._settled_merge_chunk = nil
    self._settled_merge_ids = nil
    self._settled_merge_members = nil
    self._settled_merge_last_discard_reason = reason or "discarded"
    return true, count
end

function RBX:_discard_settled_merge_generation(reason, invalidate,
        release_backend, released_resources)
    local cpu_released, seen_chunks = {}, {}
    released_resources = released_resources or {}
    local pending, pending_count = self:_discard_settled_merge_pending(
        reason, release_backend, released_resources,
        cpu_released, seen_chunks)
    local committed, committed_count = self:_discard_settled_merge_committed(
        reason, release_backend, released_resources,
        cpu_released, seen_chunks)
    self._settled_merge_last_ids = nil
    self._settled_merge_last_members = nil
    self._settled_merge_stable_frames = 0
    self._settled_merge_part_count = 0
    self._scene_dynamic_chunks_drawn = self._scene_dynamic_chunks or {}
    if committed and invalidate ~= false
        and self._invalidate_dynamic_visible_cache then
        self:_invalidate_dynamic_visible_cache()
    end
    return pending or committed,
        (pending_count or 0) + (committed_count or 0)
end

-- Legacy internal seam retained for lifecycle/tests and the physics path
function RBX:_discard_settled_merge_chunk()
    return self:_discard_settled_merge_committed(
        "legacy_discard", true)
end

function RBX:_invalidate_settled_merge_for_part(part)
    local id = type(part) == "table" and part._id or nil
    if id == nil then return false end
    local committed = self._settled_merge_members
    local pending = self._settled_merge_pending
    local pending_members = type(pending) == "table"
        and pending.members or nil
    if (committed and committed[id])
        or (pending_members and pending_members[id]) then
        return self:_discard_settled_merge_generation(
            "member_dirty", true, true)
    end
    return false
end

-- built-in geometry is authored as a flat triangle list because the legacy
-- LOVE/static paths transform that representation directly.  Menori can keep
-- the same topology with substantially fewer immutable GPU vertices by using
-- a vertex map.  Deduplication is deliberately exact and considers both
-- position and normal: vertices on a hard edge must remain split even when
-- their positions coincide
local function build_exact_indexed_primitive_geometry(source_vertices)
    if type(source_vertices) ~= "table" or #source_vertices == 0 then
        return nil
    end

    local roots = {}
    local vertices = {}
    local indices = {}
    for source_index = 1, #source_vertices do
        local source = source_vertices[source_index]
        if type(source) ~= "table" then
            return nil
        end

        local node = roots
        for component = 1, 6 do
            local value = source[component]
            if type(value) ~= "number" or value ~= value then
                return nil
            end
            local next_node = node[value]
            if next_node == nil then
                next_node = {}
                node[value] = next_node
            end
            node = next_node
        end

        local vertex_index = node.vertex_index
        if vertex_index == nil then
            vertex_index = #vertices + 1
            -- all built-in formats are position + normal. Copying the six
            -- values keeps this cache independent from accidental edits to a
            -- source row while leaving the original flat arrays untouched
            vertices[vertex_index] = {
                source[1], source[2], source[3],
                source[4], source[5], source[6],
            }
            node.vertex_index = vertex_index
            if vertex_index > 65535 then
                -- these built-ins are far below the uint16 ceiling. Returning
                -- nil preserves the prior non-indexed Menori behavior if a
                -- future generated primitive exceeds it
                return nil
            end
        end
        indices[source_index] = vertex_index
    end

    return {
        vertices = vertices,
        indices = indices,
        vertex_count = #vertices,
        source_vertex_count = #source_vertices,
        index_count = #indices,
        indices_tsize = 2,
    }
end

function RBX:_get_menori_indexed_primitive_geometry(
    shape_name, source_vertices)
    local cache = self._menori_indexed_primitive_geometry
    if cache == nil then
        cache = {}
        self._menori_indexed_primitive_geometry = cache
    end

    local cached = cache[shape_name]
    if cached and cached.source_vertices == source_vertices then
        return cached
    end

    local indexed = build_exact_indexed_primitive_geometry(source_vertices)
    if indexed then
        indexed.shape_name = shape_name
        indexed.source_vertices = source_vertices
        cache[shape_name] = indexed
    else
        cache[shape_name] = nil
    end
    return indexed
end

function RBX:_create_menori_cube_batch(rows, initial_capacity)
    local backend = self._render_backend
    if self.render_backend_name ~= "menori" or not backend then
        return nil
    end

    rows = rows or {}
    local closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(rows)
    local source_vertices = self._cube_vertices
    local indexed = self:_get_menori_indexed_primitive_geometry(
        "Block", source_vertices)
    local base_vertices = indexed and indexed.vertices or source_vertices
    local upload_start = love.timer.getTime()
    local ok, batch_or_error = pcall(backend.create_opaque_batch, backend, {
        base_vertex_format = self._cube_vertex_format,
        base_vertices = base_vertices,
        vertex_count = #base_vertices,
        source_vertex_count = #(source_vertices or {}),
        indices = indexed and indexed.indices or nil,
        indices_tsize = indexed and indexed.indices_tsize or nil,
        instance_format = self._instance_vertex_format,
        instance_rows = rows,
        instance_count = #rows,
        initial_capacity = math.max(1, tonumber(initial_capacity) or #rows),
        mode = "triangles",
    })
    if not ok or not batch_or_error then
        self:_note_render_backend_error("create opaque Block batch", batch_or_error)
        return nil
    end

    local batch = batch_or_error
    batch.shape_name = "Block"
    batch.closed_primitive_handedness = closed_primitive_handedness
    batch.batch_key = RBX._closed_primitive_batch_key(
        "Block", closed_primitive_handedness)
    self:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
    -- one Menori batch owns two LOVE meshes: immutable Block vertices and the
    -- dynamic per-instance rows
    self:_note_load_cache_stat("gpu_mesh_upload_count")
    self:_note_load_cache_stat("gpu_mesh_upload_count")
    self:_note_gpu_upload_bytes(#(base_vertices or {}) * 6 * 4)
    self:_note_gpu_upload_bytes(
        indexed and indexed.index_count * indexed.indices_tsize or 0)
    self:_note_gpu_upload_bytes(math.max(1, batch.instance_capacity or #rows) * 24 * 4)
    return batch
end

function RBX:_create_menori_primitive_batch(shape_name, rows)
    local backend = self._render_backend
    local source_vertices = self._primitive_vertices
        and self._primitive_vertices[shape_name] or nil
    if self.render_backend_name ~= "menori"
        or not backend
        or type(source_vertices) ~= "table"
        or #source_vertices == 0 then
        return nil
    end

    rows = rows or {}
    local closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(rows)
    local indexed = self:_get_menori_indexed_primitive_geometry(
        shape_name, source_vertices)
    local base_vertices = indexed and indexed.vertices or source_vertices
    local upload_start = love.timer.getTime()
    local ok, batch_or_error = pcall(
        backend.create_instanced_batch or backend.create_opaque_batch,
        backend,
        {
            base_vertex_format = self._cube_vertex_format,
            base_vertices = base_vertices,
            vertex_count = #base_vertices,
            source_vertex_count = #source_vertices,
            indices = indexed and indexed.indices or nil,
            indices_tsize = indexed and indexed.indices_tsize or nil,
            instance_format = self._instance_vertex_format,
            instance_rows = rows,
            instance_count = #rows,
            initial_capacity = math.max(1, #rows),
            mode = "triangles",
            kind = "opaque_primitive_" .. tostring(shape_name),
        })
    if not ok or not batch_or_error then
        self:_note_render_backend_error(
            "create opaque " .. tostring(shape_name) .. " batch",
            batch_or_error)
        return nil
    end

    local batch = batch_or_error
    batch.shape_name = shape_name
    batch.closed_primitive_handedness = closed_primitive_handedness
    batch.batch_key = RBX._closed_primitive_batch_key(
        shape_name, closed_primitive_handedness)
    self:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
    self:_note_load_cache_stat("gpu_mesh_upload_count")
    self:_note_load_cache_stat("gpu_mesh_upload_count")
    self:_note_gpu_upload_bytes(#base_vertices * 6 * 4)
    self:_note_gpu_upload_bytes(
        indexed and indexed.index_count * indexed.indices_tsize or 0)
    self:_note_gpu_upload_bytes(math.max(
        1, batch.instance_capacity or #rows) * 24 * 4)
    return batch
end

function RBX:_update_menori_primitive_batch(batch, shape_name, rows)
    local backend = self._render_backend
    if self.render_backend_name ~= "menori"
        or not backend
        or type(batch) ~= "table"
        or batch.backend ~= backend
        or batch.released
        or batch.shape_name ~= shape_name then
        return nil
    end

    local update = backend.update_instanced_batch or backend.update_opaque_batch
    if type(update) ~= "function" then
        return nil
    end
    rows = rows or {}
    local upload_start = love.timer.getTime()
    local ok, updated_or_error = pcall(
        update, backend, batch, rows, #rows)
    if not ok or not updated_or_error then
        self:_note_render_backend_error(
            "update opaque " .. tostring(shape_name) .. " batch",
            updated_or_error)
        return nil
    end
    batch = updated_or_error
    batch.shape_name = shape_name
    batch.closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(rows)
    batch.batch_key = RBX._closed_primitive_batch_key(
        shape_name, batch.closed_primitive_handedness)
    self:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
    self:_note_gpu_upload_bytes(#rows * 24 * 4)
    return batch
end

local function stage_primitive_instance_ranges(renderer, batch, part_ids)
    if not batch or not batch.instance_mesh or type(part_ids) ~= "table" then
        return
    end
    local stage = renderer._range_static_stage
    if not stage then
        stage = {}
        renderer._range_static_stage = stage
    end
    for row, part_id in pairs(part_ids) do
        if part_id ~= nil then
            stage[#stage + 1] = part_id
            stage[#stage + 1] = batch.instance_mesh
            stage[#stage + 1] = row
            stage[#stage + 1] = 1
        end
    end
end

function RBX:_build_opaque_primitive_draw_item(
    shape_name, instances, part_ids, options)
    options = options or {}
    instances = instances or {}
    local batch_key = options.batch_key or shape_name
    local source_vertices = self._primitive_vertices
        and self._primitive_vertices[shape_name] or self._cube_vertices
    local allow_instancing = options.allow_instancing ~= false
        and self.use_instancing == true
        and self.constant_fragment_shader ~= true
    local reuse_item = options.reuse_item
    local previous_batch = type(reuse_item) == "table"
        and rawget(reuse_item, "_instance_resource_batch") or nil
    local previous_instanced_count = previous_batch
        and math.max(0, tonumber(reuse_item.count) or 0) or 0
    local closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(instances)

    if allow_instancing then
        local batch = self:_update_menori_primitive_batch(
            previous_batch, shape_name, instances)
        local reused_batch = batch ~= nil
        if not batch then
            batch = self:_create_menori_primitive_batch(shape_name, instances)
        end
        if batch then
            batch.closed_primitive_handedness =
                closed_primitive_handedness
            batch.batch_key = batch_key
            if reused_batch then
                -- Ownership moves into the replacement chunk. the old chunk
                -- releaser must not retire aliases that the new item still uses
                reuse_item._instance_resource_batch = nil
                reuse_item.draw_mesh = nil
                reuse_item.instance_mesh = nil
                reuse_item.count = 0
            end
            if options.track_ranges ~= false then
                stage_primitive_instance_ranges(self, batch, part_ids)
            end
            if reused_batch then
                self._primitive_instanced_object_count = math.max(
                    0,
                    (self._primitive_instanced_object_count or 0)
                        + #instances - previous_instanced_count
                )
            else
                self._primitive_instanced_batch_count =
                    (self._primitive_instanced_batch_count or 0) + 1
                self._primitive_instanced_object_count =
                    (self._primitive_instanced_object_count or 0) + #instances
            end
            return {
                kind = "instanced_primitive",
                key = batch_key,
                batch_key = batch_key,
                shape_name = shape_name,
                bounds = options.bounds,
                draw_mesh = batch.draw_mesh,
                instance_mesh = batch.instance_mesh,
                count = batch.instance_count,
                primitive_count = #instances,
                closed_primitive_handedness =
                    closed_primitive_handedness,
                _instance_resource_batch = batch,
                dynamic_chunk = options.dynamic_chunk == true,
                mega_static = options.mega_static == true,
            }
        end
    end

    local mesh = build_static_mesh(
        self, instances, source_vertices, part_ids)
    if not mesh then
        return nil
    end
    return {
        kind = "static",
        mesh = mesh,
        key = batch_key,
        batch_key = batch_key,
        shape_name = shape_name,
        bounds = options.bounds,
        primitive_count = #instances,
        closed_primitive_handedness = closed_primitive_handedness,
        dynamic_chunk = options.dynamic_chunk == true,
        mega_static = options.mega_static == true,
    }
end

function RBX:_assign_chunk_cube_batch(chunk, batch)
    chunk._cube_instance_batch = batch
    chunk.instance_mesh = batch and batch.instance_mesh or nil
    chunk.cube_draw_mesh = batch and batch.draw_mesh or nil
    chunk.instance_count = batch and batch.instance_count or 0
    if batch and batch.closed_primitive_handedness then
        chunk.closed_primitive_handedness =
            batch.closed_primitive_handedness
        chunk.closed_primitive_batch_key = batch.batch_key
    end
end

function RBX:_new_instanced_cube_draw_mesh(instance_mesh)
    if not instance_mesh then
        return nil
    end

    local upload_start = love.timer.getTime()
    local draw_mesh = love.graphics.newMesh(self._cube_vertex_format, self._cube_vertices, "triangles", "static")
    self:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
    self:_note_load_cache_stat("gpu_mesh_upload_count")
    self:_note_gpu_upload_bytes(#(self._cube_vertices or {}) * 11 * 4)
    self:_attach_instance_attributes_to_mesh(draw_mesh, instance_mesh, "build")
    return draw_mesh
end

function RBX:_build_chunk_instance_mesh(chunk)
    if not chunk then
        return false
    end

    chunk.closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(
            chunk.cube_instances)
    chunk.closed_primitive_batch_key = RBX._closed_primitive_batch_key(
        "Block", chunk.closed_primitive_handedness)
    if #chunk.cube_instances == 0 then
        self:_release_chunk_cube_meshes(chunk, {}, true)
        self:_assign_chunk_cube_batch(chunk, nil)
        return true
    end

    self:_release_chunk_cube_meshes(chunk, {}, true)

    if self.render_backend_name == "menori" and self._render_backend then
        local batch = self:_create_menori_cube_batch(
            chunk.cube_instances, #chunk.cube_instances)
        if batch then
            self:_assign_chunk_cube_batch(chunk, batch)
            chunk.static_cube_mesh = nil
            return true
        end
        -- a batch-local backend failure must not make the map disappear. the
        -- original LOVE resource path below remains a pixel-identical fallback
    end

    local ok, instance_mesh = pcall(function()
        local vertex_count = math.max(1, #chunk.cube_instances)
        local upload_start = love.timer.getTime()
        local mesh = love.graphics.newMesh(self._instance_vertex_format, vertex_count, "points", "static")
        self:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
        self:_note_load_cache_stat("gpu_mesh_upload_count")
        self:_note_gpu_upload_bytes(vertex_count * 24 * 4)
        mesh:setVertices(chunk.cube_instances)
        return mesh
    end)

    if not ok or not instance_mesh then
        chunk._cube_instance_batch = nil
        chunk.instance_mesh = nil
        chunk.cube_draw_mesh = nil
        chunk.instance_count = 0
        return false
    end

    local draw_ok, draw_mesh = pcall(function()
        return self:_new_instanced_cube_draw_mesh(instance_mesh)
    end)
    if not draw_ok or not draw_mesh then
        release_scene_mesh_once(draw_mesh, {})
        release_scene_mesh_once(instance_mesh, {})
        chunk._cube_instance_batch = nil
        chunk.instance_mesh = nil
        chunk.cube_draw_mesh = nil
        chunk.instance_count = 0
        return false
    end

    chunk._cube_instance_batch = nil
    chunk.instance_mesh = instance_mesh
    chunk.cube_draw_mesh = draw_mesh
    chunk.static_cube_mesh = nil
    chunk.instance_count = #chunk.cube_instances
    return true
end

function RBX:_build_mega_cube_draw(chunks)
    local previous_batch = self._mega_cube_batch
    local released = {}
    if previous_batch then
        note_backend_batch_aliases(previous_batch, released)
        self:_release_opaque_cube_batch(previous_batch)
    else
        release_scene_mesh_once(self._mega_cube_draw_mesh, released)
        release_scene_mesh_once(self._mega_instance_mesh, released)
    end
    self._mega_cube_batch = nil
    self._mega_instance_mesh = nil
    self._mega_cube_draw_mesh = nil
    self._mega_instance_count = 0
    self._mega_cube_handedness = "collapsed"
    self._mega_cube_batch_key = "Block|0"

    if not self.use_instancing then
        return
    end

    local total = 0
    for i = 1, #chunks do
        local chunk = chunks[i]
        if chunk and chunk.dynamic_chunk ~= true then
            total = total + #(chunk.cube_instances or {})
        end
    end
    if total <= 0 then
        return
    end

    local instances = {}
    for i = 1, #chunks do
        local chunk = chunks[i]
        if chunk and chunk.dynamic_chunk ~= true then
            -- incremental release: chunk row j = mega row base + j
            chunk._mega_cube_row_base = #instances
            local chunk_instances = chunk.cube_instances or nil
            for j = 1, #(chunk_instances or {}) do
                instances[#instances + 1] = chunk_instances[j]
            end
        end
    end
    local closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(instances)
    self._mega_cube_handedness = closed_primitive_handedness
    self._mega_cube_batch_key = RBX._closed_primitive_batch_key(
        "Block", closed_primitive_handedness)

    if self.render_backend_name == "menori" and self._render_backend then
        local batch = self:_create_menori_cube_batch(instances, total)
        if batch then
            batch.closed_primitive_handedness =
                closed_primitive_handedness
            self._mega_cube_batch = batch
            self._mega_instance_mesh = batch.instance_mesh
            self._mega_cube_draw_mesh = batch.draw_mesh
            self._mega_instance_count = batch.instance_count
            return
        end
        -- preserve the legacy mega path as a local fallback. per-chunk Menori
        -- batches remain valid if only this allocation fails
    end

    local instance_mesh
    local ok, draw_mesh = pcall(function()
        local upload_start = love.timer.getTime()
        instance_mesh = love.graphics.newMesh(
            self._instance_vertex_format, math.max(1, total), "points", "static")
        self:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
        self:_note_load_cache_stat("gpu_mesh_upload_count")
        self:_note_gpu_upload_bytes(math.max(1, total) * 24 * 4)
        instance_mesh:setVertices(instances)
        return self:_new_instanced_cube_draw_mesh(instance_mesh)
    end)

    if ok and instance_mesh and draw_mesh then
        self._mega_cube_batch = nil
        self._mega_instance_mesh = instance_mesh
        self._mega_cube_draw_mesh = draw_mesh
        self._mega_instance_count = total
    else
        local partial = {}
        release_scene_mesh_once(draw_mesh, partial)
        release_scene_mesh_once(instance_mesh, partial)
    end
end

function RBX:_refresh_dynamic_chunk_cube_fallbacks(dynamic_chunks)
    local refreshed = 0
    for index = 1, #(dynamic_chunks or {}) do
        local chunk = dynamic_chunks[index]
        if chunk and chunk.dynamic_chunk == true then
            self:_build_single_scene_chunk_cube_draw(chunk)
            if #(chunk.cube_instances or {}) == 0
                or (chunk.instance_mesh and chunk.cube_draw_mesh)
                or chunk.static_cube_mesh then
                refreshed = refreshed + 1
            end
        end
    end
    self._mega_dynamic_fallback_refresh_count = refreshed
    return refreshed
end

-- dynamic twin of _build_mega_cube_draw: all moving cubes in one instanced buffer (1 draw);
-- over-allocated + reused via setVertices so a move is repack+upload, not newmesh
function RBX:_build_dynamic_mega_cube_draw(dynamic_chunks)
    if not self.use_instancing or self.dynamic_mega_dynamic_cubes ~= true then
        local released = {}
        local batch = self._mega_dynamic_cube_batch
        if batch then
            note_backend_batch_aliases(batch, released)
            self:_release_opaque_cube_batch(batch)
        else
            release_scene_mesh_once(self._mega_dynamic_cube_draw_mesh, released)
            release_scene_mesh_once(self._mega_dynamic_instance_mesh, released)
        end
        self._mega_dynamic_cube_batch = nil
        self._mega_dynamic_instance_mesh = nil
        self._mega_dynamic_cube_draw_mesh = nil
        self._mega_dynamic_instance_count = 0
        self._mega_dynamic_instance_capacity = 0
        self._mega_dynamic_cube_handedness = "collapsed"
        self._mega_dynamic_cube_batch_key = "Block|0"
        return
    end
    dynamic_chunks = dynamic_chunks or self._scene_dynamic_chunks or {}
    local scratch = self._mega_dynamic_scratch or {}
    self._mega_dynamic_scratch = scratch
    local total = 0
    for i = 1, #dynamic_chunks do
        local chunk = dynamic_chunks[i]
        if chunk and chunk.dynamic_chunk == true then
            local ci = chunk.cube_instances
            if ci then
                for j = 1, #ci do
                    total = total + 1
                    scratch[total] = ci[j]
                end
            end
        end
    end
    for k = #scratch, total + 1, -1 do scratch[k] = nil end
    local closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(scratch)
    self._mega_dynamic_cube_handedness =
        closed_primitive_handedness
    self._mega_dynamic_cube_batch_key = RBX._closed_primitive_batch_key(
        "Block", closed_primitive_handedness)
    if total <= 0 then
        local batch = self._mega_dynamic_cube_batch
        if batch and self._render_backend then
            local ok, update_error = pcall(
                self._render_backend.update_opaque_batch,
                self._render_backend, batch, scratch, 0)
            if ok then
                self._mega_dynamic_instance_mesh = batch.instance_mesh
                self._mega_dynamic_cube_draw_mesh = batch.draw_mesh
                self._mega_dynamic_instance_capacity = batch.instance_capacity or 0
            else
                self:_note_render_backend_error("clear dynamic Block batch", update_error)
                self:_release_opaque_cube_batch(batch)
                self._mega_dynamic_cube_batch = nil
                self._mega_dynamic_instance_mesh = nil
                self._mega_dynamic_cube_draw_mesh = nil
                self._mega_dynamic_instance_capacity = 0
            end
        end
        self._mega_dynamic_instance_count = 0
        return
    end

    local capacity = self._mega_dynamic_instance_capacity or 0
    local alloc = math.max(total, math.ceil(capacity * 1.5), 64)

    if self.render_backend_name == "menori" and self._render_backend then
        local batch = self._mega_dynamic_cube_batch
        local ok, update_error = true, nil
        if batch and not batch.released then
            ok, update_error = pcall(
                self._render_backend.update_opaque_batch,
                self._render_backend, batch, scratch, total)
        else
            batch = self:_create_menori_cube_batch(scratch, alloc)
            ok = batch ~= nil
        end

        if ok and batch then
            batch.closed_primitive_handedness =
                closed_primitive_handedness
            batch.batch_key = self._mega_dynamic_cube_batch_key
            self._mega_dynamic_cube_batch = batch
            self._mega_dynamic_instance_mesh = batch.instance_mesh
            self._mega_dynamic_cube_draw_mesh = batch.draw_mesh
            self._mega_dynamic_instance_capacity = batch.instance_capacity or alloc
            self._mega_dynamic_instance_count = batch.instance_count or total
            return
        end

        if update_error then
            self:_note_render_backend_error("update dynamic Block batch", update_error)
        end
        self:_release_opaque_cube_batch(batch)
        self._mega_dynamic_cube_batch = nil
        self._mega_dynamic_instance_mesh = nil
        self._mega_dynamic_cube_draw_mesh = nil
        self._mega_dynamic_instance_capacity = 0
        -- Continue into the raw LOVE fallback for this batch
        capacity = 0
        alloc = math.max(total, 64)
    end

    local instance_mesh = self._mega_dynamic_instance_mesh
    local draw_mesh = self._mega_dynamic_cube_draw_mesh
    -- reuse over-allocated buffer in place if it fits
    if instance_mesh and draw_mesh and total <= capacity then
        if pcall(instance_mesh.setVertices, instance_mesh, scratch) then
            self._mega_dynamic_instance_count = total
            return
        end
    end
    -- realloc w/ 1.5x headroom to amortize growth
    local new_instance_mesh
    local ok, new_draw_mesh = pcall(function()
        local upload_start = love.timer.getTime()
        new_instance_mesh = love.graphics.newMesh(
            self._instance_vertex_format, alloc, "points", "static")
        self:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
        self:_note_load_cache_stat("gpu_mesh_upload_count")
        self:_note_gpu_upload_bytes(alloc * 24 * 4)
        new_instance_mesh:setVertices(scratch)
        return self:_new_instanced_cube_draw_mesh(new_instance_mesh)
    end)
    if ok and new_instance_mesh and new_draw_mesh then
        local released = {}
        release_scene_mesh_once(draw_mesh, released)
        release_scene_mesh_once(instance_mesh, released)
        self._mega_dynamic_cube_batch = nil
        self._mega_dynamic_instance_mesh = new_instance_mesh
        self._mega_dynamic_cube_draw_mesh = new_draw_mesh
        self._mega_dynamic_instance_capacity = alloc
        self._mega_dynamic_instance_count = total
    else
        local released = {}
        release_scene_mesh_once(new_draw_mesh, released)
        release_scene_mesh_once(new_instance_mesh, released)
        release_scene_mesh_once(draw_mesh, released)
        release_scene_mesh_once(instance_mesh, released)
        -- count=0 so draw gate falls back to per-chunk loop, not a stale buffer
        self._mega_dynamic_instance_mesh = nil
        self._mega_dynamic_cube_draw_mesh = nil
        self._mega_dynamic_instance_capacity = 0
        self._mega_dynamic_instance_count = 0
        -- fast-recube deliberately mutates only the CPU row because the dynamic
        -- mega upload normally consumes it. if both mega upload paths fail, the
        -- per-chunk GPU rows may still contain last frame's pose. refresh them
        -- before allowing the draw gate to fall back to those chunks
        self:_refresh_dynamic_chunk_cube_fallbacks(dynamic_chunks)
    end
end

function RBX:_build_mega_static_draw_items(shape_instances, shape_instance_part_ids, checkpoint)
    local items = {}
    if type(shape_instances) ~= "table" then
        return items
    end

    local visited=0
    for batch_key, instances in pairs(shape_instances) do
        visited=visited+1
        if checkpoint then checkpoint('scene:mega-primitive',visited)end
        if type(instances) == "table" and #instances > 0 then
            local shape_name =
                RBX._closed_primitive_shape_name_from_batch_key(batch_key)
            local shape_part_ids = shape_instance_part_ids
                and shape_instance_part_ids[batch_key] or nil
            local item = self:_build_opaque_primitive_draw_item(
                shape_name,
                instances,
                shape_part_ids,
                {
                    mega_static = true,
                    batch_key = batch_key,
                })
            if item then
                items[#items + 1] = item
            end
        end
    end

    table.sort(items, function(a, b)
        return tostring(a.key) < tostring(b.key)
    end)
    return items
end

local LOCAL_LIGHT_CLUSTER_INSTANCE_COMPONENTS = 24

local function local_light_cluster_number(value)
    value = tonumber(value)
    if value == nil then
        return nil
    end
    if value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

function RBX._local_light_pack_payload_key(pack)
    if type(pack) ~= "table" then
        return "local-empty"
    end
    local immutable =
        rawget(pack, "_payload_immutable") == true
    local cached = immutable
        and rawget(pack, "_uniform_payload_key")
        or nil
    if cached ~= nil then
        return cached
    end
    local ambient = pack and pack.ambient or nil
    local selected_count = math.max(
        0,
        math.min(
            4,
            math.floor(tonumber(pack.count) or 0)))
    local key_parts = {
        tostring(pack and pack.key or "local-empty"),
        "|count:",
        tostring(selected_count),
        "|ambient:",
        string.format("%.17g", tonumber(ambient and ambient[1]) or 0),
        ",",
        string.format("%.17g", tonumber(ambient and ambient[2]) or 0),
        ",",
        string.format("%.17g", tonumber(ambient and ambient[3]) or 0),
    }

    -- Runtime compact packs and renderer-owned empty packs are immutable, their
    -- revision/id key is the exact slot identity and can keep the cheap cached
    -- signature above. Legacy/test packs are writable, so include every live
    -- selected slot component and deliberately do not cache the result
    if not immutable and selected_count > 0 then
        local slots = rawget(pack, "slots") or {}
        local vector_names = {
            "a", "b", "c", "d", "e", "f",
        }
        for slot_index = 1, selected_count do
            local slot = slots[slot_index] or {}
            for vector_index = 1, #vector_names do
                local vector =
                    slot[vector_names[vector_index]] or {}
                key_parts[#key_parts + 1] = "|"
                key_parts[#key_parts + 1] =
                    vector_names[vector_index]
                key_parts[#key_parts + 1] = ":"
                for component = 1, 4 do
                    if component > 1 then
                        key_parts[#key_parts + 1] = ","
                    end
                    key_parts[#key_parts + 1] =
                        string.format(
                            "%.17g",
                            tonumber(vector[component]) or 0)
                end
            end
        end
    end

    local key = table.concat(key_parts)
    if immutable then
        pack._uniform_payload_key = key
    end
    return key
end

function RBX:_static_local_light_cluster_build_signature()
    return table.concat({
        tostring(self._instance_generation or 0),
        "|", tostring(self._static_scene_revision or 0),
        "|", tostring(self.max_lights_per_batch or 0),
        "|", tostring(self.local_light_cluster_supercell_span or 0),
        "|", tostring(self.local_light_grid_cell_size or 0),
        "|", tostring(self.canonicalize_local_light_slots ~= false),
        "|", tostring(self.local_light_cluster_max_batches or 0),
        "|", tostring(
            self.local_light_cluster_max_duplicate_instance_bytes or 0),
        "|", tostring(self.render_backend_name or ""),
    })
end

local function read_local_light_cluster_instance_rows(instance_mesh, count)
    if not instance_mesh or type(instance_mesh.getVertex) ~= "function" then
        return nil, "instance_mesh_unreadable"
    end
    local rows = {}
    for row_index = 1, math.max(0, tonumber(count) or 0) do
        local row
        local ok, read_error = pcall(function()
            row = { instance_mesh:getVertex(row_index) }
        end)
        if not ok or type(row) ~= "table"
            or #row < LOCAL_LIGHT_CLUSTER_INSTANCE_COMPONENTS then
            return nil, ok and "instance_row_short"
                or ("instance_row_read_failed:" .. tostring(read_error))
        end
        for component = 1, LOCAL_LIGHT_CLUSTER_INSTANCE_COMPONENTS do
            local value = local_light_cluster_number(row[component])
            if value == nil then
                return nil, "instance_row_nonfinite"
            end
            row[component] = value
        end
        rows[row_index] = row
    end
    return rows
end

local function validate_local_light_cluster_instance_rows(rows, count)
    if type(rows) ~= "table" or #rows < count then
        return nil, "instance_rows_missing"
    end
    for row_index = 1, count do
        local row = rows[row_index]
        if type(row) ~= "table"
            or #row < LOCAL_LIGHT_CLUSTER_INSTANCE_COMPONENTS then
            return nil, "instance_row_short"
        end
        for component = 1, LOCAL_LIGHT_CLUSTER_INSTANCE_COMPONENTS do
            if local_light_cluster_number(row[component]) == nil then
                return nil, "instance_row_nonfinite"
            end
        end
    end
    return rows
end

local function pin_local_light_cluster_pack(
    item, pack, bounds, light_revision, configuration_signature)
    item._local_light_pack_revision = light_revision
    item._local_light_pack_configuration_signature =
        configuration_signature
    item._local_light_pack = pack
    item._local_light_pack_bounds = bounds
    item._local_light_pack_min_x = bounds and bounds.min_x or nil
    item._local_light_pack_min_y = bounds and bounds.min_y or nil
    item._local_light_pack_min_z = bounds and bounds.min_z or nil
    item._local_light_pack_max_x = bounds and bounds.max_x or nil
    item._local_light_pack_max_y = bounds and bounds.max_y or nil
    item._local_light_pack_max_z = bounds and bounds.max_z or nil
end

local SCENE_FRAME_PACKET_STATE_FIELDS = {
    "_scene_frame_packet",
    "_mega_visible_static_draw_items_buffer",
    "_mega_visible_textured_batches_buffer",
    "_mega_visible_overlay_textured_batches_buffer",
    "_opaque_light_sorted_static_items_buffer",
    "_clustered_opaque_static_items_buffer",
    "_raw_chunk_cube_draw_list_buffer",
    "_raw_chunk_static_cube_list_buffer",
    "_chunk_cube_draw_list_buffer",
    "_chunk_static_cube_list_buffer",
    "_opaque_surface_geometry_batches_buffer",
    "_opaque_base_textured_batches_buffer",
    "_surface_gui_overlay_batches_buffer",
    "_decal_overlay_textured_batches_buffer",
    "_transparent_surface_gui_items_buffer",
    "_transparent_regular_items_buffer",
    "_local_light_cluster_visible_count_scratch",
    "_local_light_cluster_visible_order_valid_scratch",
    "_local_light_cluster_visible_last_source_order_scratch",
    "_local_light_cluster_emitted_scratch",
}

-- draw packets intentionally retain composed arrays between steady frames
-- any map/cluster generation retirement must sever those references eagerly:
-- otherwise a destroyed renderer can retain the old scene graph and released
-- GPU handles indefinitely, and an in-place retirement can reuse a stale list
function RBX:_invalidate_scene_frame_packet_state()
    for index = 1, #SCENE_FRAME_PACKET_STATE_FIELDS do
        self[SCENE_FRAME_PACKET_STATE_FIELDS[index]] = nil
    end
    self._compose_sig1 = nil
    self._compose_sig2 = nil
    self._compose_sig3 = nil
    self._compose_sig4 = nil
    self._compose_mega_flag = nil
    self._compose_primitive_flag = nil
    self._compose_tex_flag = nil
    self._compose_light_sort_flag = nil
    self._compose_light_cluster_generation = nil
    self._opaque_split_valid = false
end

function RBX:_release_static_local_light_clusters(
    release_backend, preserve_attempt_state)
    self:_invalidate_scene_frame_packet_state()
    local clusters = self._static_local_light_clusters
    if type(clusters) ~= "table" then
        self._static_local_light_clusters = nil
        -- an explicit retirement means the source geometry may have changed
        -- without advancing one of the coarse build-signature revisions (for
        -- example, promoting/deleting a purely opaque non-occluder in place)
        -- let maintenance schedule one fresh attempt for the still-current
        -- signature instead of treating an older successful attempt as final
        if preserve_attempt_state ~= true then
            self._static_local_light_cluster_last_attempt_signature = nil
            self._static_local_light_cluster_pending_signature = nil
            self._static_local_light_cluster_pending_since = nil
            self._static_local_light_cluster_failure_signature = nil
            self._static_local_light_cluster_failure_count = nil
            self._static_local_light_cluster_retry_at = nil
        end
        return 0
    end

    local released_count = 0
    for index = 1, #(clusters.cube_items or {}) do
        local item = clusters.cube_items[index]
        local batch = item and item._cube_instance_batch
        if batch and release_backend ~= false
            and self:_release_opaque_cube_batch(batch) then
            released_count = released_count + 1
        end
        if item then
            item._cube_instance_batch = nil
            item.cube_draw_mesh = nil
            item.instance_mesh = nil
            item.source_items = nil
            item.source_order_by_item = nil
        end
    end
    for index = 1, #(clusters.primitive_items or {}) do
        local item = clusters.primitive_items[index]
        local batch = item and item._instance_resource_batch
        if batch and release_backend ~= false
            and self:_release_opaque_cube_batch(batch) then
            released_count = released_count + 1
        end
        if item then
            item._instance_resource_batch = nil
            item.draw_mesh = nil
            item.instance_mesh = nil
            item.source_items = nil
            item.source_order_by_item = nil
        end
    end

    clusters.cube_by_source = nil
    clusters.primitive_by_source = nil
    clusters.cube_items = nil
    clusters.primitive_items = nil
    clusters.backend = nil
    self._static_local_light_clusters = nil
    self._static_local_light_cluster_last_build_stats = nil
    if preserve_attempt_state ~= true then
        self._static_local_light_cluster_last_attempt_signature = nil
        self._static_local_light_cluster_pending_signature = nil
        self._static_local_light_cluster_pending_since = nil
        self._static_local_light_cluster_failure_signature = nil
        self._static_local_light_cluster_failure_count = nil
        self._static_local_light_cluster_retry_at = nil
    end
    return released_count
end

function RBX:_rebuild_static_local_light_clusters(build_options)
    build_options = build_options or {}
    if self._sync_local_light_pack_configuration then
        self:_sync_local_light_pack_configuration()
    end
    self:_release_static_local_light_clusters(true, true)
    self._static_local_light_cluster_last_build_stats = nil

    if self.enable_static_local_light_clusters == false
        or self.enable_local_lights == false
        or self.enable_local_light_pack_sorting == false
        or self.use_instancing ~= true
        or self.constant_fragment_shader == true
        or self.render_backend_name ~= "menori"
        or not self._render_backend
        or self.enable_occlusion_culling == true
        or (tonumber(self.local_light_count) or 0)
            <= math.max(0, tonumber(self.max_lights_per_batch) or 0) then
        return nil
    end
    self._static_local_light_cluster_last_attempt_signature =
        self:_static_local_light_cluster_build_signature()

    local build_started_at = love.timer.getTime()
    local light_revision = self._local_light_revision or 0
    local instance_generation = self._instance_generation or 0
    local static_scene_revision = self._static_scene_revision or 0
    local build_signature =
        self:_static_local_light_cluster_build_signature()
    local supercell_span = math.max(
        1, math.floor(tonumber(self.local_light_cluster_supercell_span) or 2))
    local cube_buckets = {}
    local primitive_buckets = {}
    local cube_bucket_order = {}
    local primitive_bucket_order = {}
    local stats = {
        candidate_cube_draw_count = 0,
        candidate_primitive_draw_count = 0,
        candidate_instance_count = 0,
        profitable_bucket_count = 0,
        source_read_failure_count = 0,
        backend_failure_count = 0,
        budget_skipped_bucket_count = 0,
        budget_skipped_instance_count = 0,
        duplicate_instance_bytes = 0,
        cube_cluster_count = 0,
        primitive_cluster_count = 0,
        covered_cube_draw_count = 0,
        covered_primitive_draw_count = 0,
        clustered_instance_count = 0,
        uploaded_bytes = 0,
        theoretical_draws_saved = 0,
        active_cube_draws_saved = 0,
        active_primitive_draws_saved = 0,
        active_cube_cluster_draw_count = 0,
        active_primitive_cluster_draw_count = 0,
        failure_reasons = {},
    }

    local function note_failure(reason)
        reason = tostring(reason or "unknown")
        stats.source_read_failure_count =
            stats.source_read_failure_count + 1
        stats.failure_reasons[reason] =
            (stats.failure_reasons[reason] or 0) + 1
    end

    local function append_source(
        bucket_map, bucket_order, category, source, chunk,
        batch_key, shape_name, count, bounds, handedness,
        instance_mesh, fallback_rows)
        if count <= 0 then
            return
        end
        local pack = self:_get_local_light_pack_for_item(source)
        local gx = tonumber(chunk and chunk.grid_x) or 0
        local gy = tonumber(chunk and chunk.grid_y) or 0
        local gz = tonumber(chunk and chunk.grid_z) or 0
        local supercell_key = table.concat({
            math.floor(gx / supercell_span), ":",
            math.floor(gy / supercell_span), ":",
            math.floor(gz / supercell_span),
        })
        local key = table.concat({
            RBX._local_light_pack_payload_key(pack),
            "|supercell:", supercell_key,
            "|batch:", tostring(batch_key or ""),
        })
        local bucket = bucket_map[key]
        if not bucket then
            bucket = {
                category = category,
                key = key,
                batch_key = batch_key,
                shape_name = shape_name,
                closed_primitive_handedness = handedness,
                pack = pack,
                sources = {},
                source_records = {},
                instance_count = 0,
                bounds = {
                    min_x = math.huge,
                    min_y = math.huge,
                    min_z = math.huge,
                    max_x = -math.huge,
                    max_y = -math.huge,
                    max_z = -math.huge,
                },
            }
            bucket_map[key] = bucket
            bucket_order[#bucket_order + 1] = bucket
        end
        bucket.sources[#bucket.sources + 1] = source
        bucket.source_records[#bucket.source_records + 1] = {
            source = source,
            count = count,
            instance_mesh = instance_mesh,
            fallback_rows = fallback_rows,
        }
        bucket.instance_count = bucket.instance_count + count
        stats.candidate_instance_count =
            stats.candidate_instance_count + count
        if bounds then
            expand_bounds_with_bounds(bucket.bounds, bounds)
        end
    end

    for chunk_index = 1, #(self._scene_static_chunks or {}) do
        local chunk = self._scene_static_chunks[chunk_index]
        if chunk and chunk.dynamic_chunk ~= true then
            local cube_count = math.max(
                0, tonumber(chunk.instance_count) or 0)
            if cube_count > 0 and chunk.cube_draw_mesh then
                stats.candidate_cube_draw_count =
                    stats.candidate_cube_draw_count + 1
                append_source(
                    cube_buckets,
                    cube_bucket_order,
                    "cube",
                    chunk,
                    chunk,
                    chunk.closed_primitive_batch_key,
                    "Block",
                    cube_count,
                    chunk.bounds,
                    chunk.closed_primitive_handedness,
                    chunk.instance_mesh,
                    chunk.cube_instances)
            end

            for item_index = 1, #(chunk.opaque_static_draw_items or {}) do
                local item = chunk.opaque_static_draw_items[item_index]
                if item and item.kind == "instanced_primitive"
                    and item.draw_mesh
                    and (tonumber(item.count) or 0) > 0 then
                    stats.candidate_primitive_draw_count =
                        stats.candidate_primitive_draw_count + 1
                    append_source(
                        primitive_buckets,
                        primitive_bucket_order,
                        "primitive",
                        item,
                        chunk,
                        item.batch_key or item.key,
                        item.shape_name,
                        item.count,
                        item.bounds or chunk.bounds,
                        item.closed_primitive_handedness,
                        item.instance_mesh,
                        nil)
                end
            end
        end
    end

    local clusters = {
        light_revision = light_revision,
        instance_generation = instance_generation,
        static_scene_revision = static_scene_revision,
        build_signature = build_signature,
        backend = self._render_backend,
        backend_generation =
            self._render_backend and self._render_backend.generation or 0,
        cube_items = {},
        primitive_items = {},
        cube_by_source = {},
        primitive_by_source = {},
        stats = stats,
    }

    local function note_batch_upload(batch)
        stats.uploaded_bytes = stats.uploaded_bytes
            + math.max(0, tonumber(batch and batch.vertex_count) or 0) * 6 * 4
            + math.max(0, tonumber(batch and batch.index_count) or 0)
                * math.max(0, tonumber(batch and batch.indices_tsize) or 0)
            + math.max(0, tonumber(batch and batch.instance_count) or 0)
                * LOCAL_LIGHT_CLUSTER_INSTANCE_COMPONENTS * 4
    end

    local function build_cluster_source_order(sources)
        local order = {}
        for source_index = 1, #sources do
            order[sources[source_index]] = source_index
        end
        return order
    end

    -- Metadata bucketing happens before any synchronous GPU readback. Singleton
    -- buckets can never save a draw, so they stay on the retained source path
    -- without paying getVertex calls or temporary row-table duplication
    local function materialize_bucket_rows(bucket)
        local rows = {}
        for record_index = 1, #(bucket.source_records or {}) do
            local record = bucket.source_records[record_index]
            local record_rows, row_error
            if record.instance_mesh
                and type(record.instance_mesh.getVertex) == "function" then
                record_rows, row_error =
                    read_local_light_cluster_instance_rows(
                        record.instance_mesh, record.count)
            elseif record.fallback_rows then
                record_rows, row_error =
                    validate_local_light_cluster_instance_rows(
                        record.fallback_rows, record.count)
            else
                row_error = "instance_mesh_unreadable"
            end
            if not record_rows then
                note_failure(row_error)
                return nil
            end
            for row_index = 1, record.count do
                rows[#rows + 1] = record_rows[row_index]
            end
        end
        return rows
    end

    local max_cluster_batches = math.max(
        0,
        math.floor(
            tonumber(self.local_light_cluster_max_batches) or 256))
    local max_duplicate_instance_bytes = math.max(
        0,
        tonumber(self.local_light_cluster_max_duplicate_instance_bytes)
            or (32 * 1024 * 1024))
    if build_options.maintenance == true then
        max_cluster_batches = math.min(
            max_cluster_batches,
            math.max(
                0,
                math.floor(tonumber(
                    self.local_light_cluster_maintenance_max_batches) or 16)))
        max_duplicate_instance_bytes = math.min(
            max_duplicate_instance_bytes,
            math.max(
                0,
                tonumber(
                    self.local_light_cluster_maintenance_max_duplicate_instance_bytes)
                    or (2 * 1024 * 1024)))
        stats.maintenance_budgeted = true
    else
        stats.maintenance_budgeted = false
    end
    stats.max_cluster_batches = max_cluster_batches
    stats.max_duplicate_instance_bytes = max_duplicate_instance_bytes
    local built_cluster_count = 0
    local duplicate_instance_bytes = 0

    local function bucket_is_within_budget(bucket)
        stats.profitable_bucket_count =
            stats.profitable_bucket_count + 1
        local predicted_bytes =
            math.max(0, tonumber(bucket.instance_count) or 0)
                * LOCAL_LIGHT_CLUSTER_INSTANCE_COMPONENTS * 4
        if built_cluster_count >= max_cluster_batches
            or duplicate_instance_bytes + predicted_bytes
                > max_duplicate_instance_bytes then
            stats.budget_skipped_bucket_count =
                stats.budget_skipped_bucket_count + 1
            stats.budget_skipped_instance_count =
                stats.budget_skipped_instance_count
                    + math.max(0, tonumber(bucket.instance_count) or 0)
            return false
        end
        return true, predicted_bytes
    end

    for index = 1, #cube_bucket_order do
        local bucket = cube_bucket_order[index]
        if #bucket.sources >= 2 then
            local within_budget, predicted_bytes =
                bucket_is_within_budget(bucket)
            local rows = within_budget
                and materialize_bucket_rows(bucket) or nil
            local batch = rows and self:_create_menori_cube_batch(
                rows, #rows) or nil
            if batch then
                built_cluster_count = built_cluster_count + 1
                duplicate_instance_bytes =
                    duplicate_instance_bytes + predicted_bytes
                batch.closed_primitive_handedness =
                    bucket.closed_primitive_handedness
                        or batch.closed_primitive_handedness
                batch.batch_key = bucket.batch_key or batch.batch_key
                local bounds = finalize_bounds(bucket.bounds)
                local item = {
                    local_light_cluster = true,
                    local_light_cluster_category = "cube",
                    source_draw_count = #bucket.sources,
                    source_items = bucket.sources,
                    source_order_by_item =
                        build_cluster_source_order(bucket.sources),
                    bounds = bounds,
                    instance_count = batch.instance_count,
                    cube_draw_mesh = batch.draw_mesh,
                    instance_mesh = batch.instance_mesh,
                    closed_primitive_handedness =
                        batch.closed_primitive_handedness,
                    closed_primitive_batch_key = batch.batch_key,
                    _cube_instance_batch = batch,
                }
                pin_local_light_cluster_pack(
                    item,
                    bucket.pack,
                    bounds,
                    light_revision,
                    self._local_light_pack_configuration_signature)
                clusters.cube_items[#clusters.cube_items + 1] = item
                for source_index = 1, #bucket.sources do
                    clusters.cube_by_source[
                        bucket.sources[source_index]] = item
                end
                stats.cube_cluster_count = stats.cube_cluster_count + 1
                stats.covered_cube_draw_count =
                    stats.covered_cube_draw_count + #bucket.sources
                stats.clustered_instance_count =
                    stats.clustered_instance_count + batch.instance_count
                note_batch_upload(batch)
            elseif rows then
                stats.backend_failure_count =
                    stats.backend_failure_count + 1
            end
        end
    end

    for index = 1, #primitive_bucket_order do
        local bucket = primitive_bucket_order[index]
        if #bucket.sources >= 2 then
            local within_budget, predicted_bytes =
                bucket_is_within_budget(bucket)
            local rows = within_budget
                and materialize_bucket_rows(bucket) or nil
            local batch = rows and self:_create_menori_primitive_batch(
                bucket.shape_name, rows) or nil
            if batch then
                built_cluster_count = built_cluster_count + 1
                duplicate_instance_bytes =
                    duplicate_instance_bytes + predicted_bytes
                batch.closed_primitive_handedness =
                    bucket.closed_primitive_handedness
                        or batch.closed_primitive_handedness
                batch.batch_key = bucket.batch_key or batch.batch_key
                local bounds = finalize_bounds(bucket.bounds)
                local item = {
                    kind = "instanced_primitive",
                    local_light_cluster = true,
                    local_light_cluster_category = "primitive",
                    source_draw_count = #bucket.sources,
                    source_items = bucket.sources,
                    source_order_by_item =
                        build_cluster_source_order(bucket.sources),
                    key = bucket.batch_key,
                    batch_key = bucket.batch_key,
                    shape_name = bucket.shape_name,
                    bounds = bounds,
                    draw_mesh = batch.draw_mesh,
                    instance_mesh = batch.instance_mesh,
                    count = batch.instance_count,
                    primitive_count = batch.instance_count,
                    closed_primitive_handedness =
                        batch.closed_primitive_handedness,
                    _instance_resource_batch = batch,
                }
                pin_local_light_cluster_pack(
                    item,
                    bucket.pack,
                    bounds,
                    light_revision,
                    self._local_light_pack_configuration_signature)
                clusters.primitive_items[
                    #clusters.primitive_items + 1] = item
                for source_index = 1, #bucket.sources do
                    clusters.primitive_by_source[
                        bucket.sources[source_index]] = item
                end
                stats.primitive_cluster_count =
                    stats.primitive_cluster_count + 1
                stats.covered_primitive_draw_count =
                    stats.covered_primitive_draw_count + #bucket.sources
                stats.clustered_instance_count =
                    stats.clustered_instance_count + batch.instance_count
                note_batch_upload(batch)
            elseif rows then
                stats.backend_failure_count =
                    stats.backend_failure_count + 1
            end
        end
    end

    stats.theoretical_draws_saved =
        stats.covered_cube_draw_count
        + stats.covered_primitive_draw_count
        - stats.cube_cluster_count
        - stats.primitive_cluster_count
    stats.duplicate_instance_bytes = duplicate_instance_bytes
    stats.build_ms =
        math.max(0, (love.timer.getTime() - build_started_at) * 1000)
    self._static_local_light_cluster_last_build_stats = stats
    local transient_failure_count =
        (stats.source_read_failure_count or 0)
        + (stats.backend_failure_count or 0)
    if transient_failure_count > 0 then
        if self._static_local_light_cluster_failure_signature
            == build_signature then
            self._static_local_light_cluster_failure_count =
                (self._static_local_light_cluster_failure_count or 0) + 1
        else
            self._static_local_light_cluster_failure_signature =
                build_signature
            self._static_local_light_cluster_failure_count = 1
        end
        local base_delay = math.max(
            0,
            tonumber(self.local_light_cluster_failure_retry_delay) or 0.5)
        local max_delay = math.max(
            base_delay,
            tonumber(self.local_light_cluster_failure_max_retry_delay) or 5)
        local exponent = math.min(
            8,
            math.max(
                0,
                (self._static_local_light_cluster_failure_count or 1) - 1))
        self._static_local_light_cluster_retry_at =
            love.timer.getTime()
                + math.min(max_delay, base_delay * (2 ^ exponent))
    else
        self._static_local_light_cluster_failure_signature = nil
        self._static_local_light_cluster_failure_count = nil
        self._static_local_light_cluster_retry_at = nil
    end

    if stats.cube_cluster_count <= 0
        and stats.primitive_cluster_count <= 0 then
        self._static_local_light_clusters = nil
        return nil
    end
    self._static_local_light_clusters = clusters
    return clusters
end

function RBX:_build_chunk_cube_draws(chunks, checkpoint)
    -- Drain only cube-owned batches here. other categories (notably repeated
    -- mesh groups) can already belong to this scene generation by the time cube
    -- resources are finalized
    local released = {}
    if self._mega_cube_batch then
        note_backend_batch_aliases(self._mega_cube_batch, released)
        self:_release_opaque_cube_batch(self._mega_cube_batch)
    else
        release_scene_mesh_once(self._mega_cube_draw_mesh, released)
        release_scene_mesh_once(self._mega_instance_mesh, released)
    end
    if self._mega_dynamic_cube_batch then
        note_backend_batch_aliases(self._mega_dynamic_cube_batch, released)
        self:_release_opaque_cube_batch(self._mega_dynamic_cube_batch)
    else
        release_scene_mesh_once(self._mega_dynamic_cube_draw_mesh, released)
        release_scene_mesh_once(self._mega_dynamic_instance_mesh, released)
    end
    self._mega_cube_batch = nil
    self._mega_dynamic_cube_batch = nil
    self._mega_instance_mesh = nil
    self._mega_cube_draw_mesh = nil
    self._mega_instance_count = 0
    self._mega_cube_handedness = "collapsed"
    self._mega_cube_batch_key = "Block|0"
    self._mega_cube_path_active = false
    self._mega_dynamic_instance_mesh = nil
    self._mega_dynamic_cube_draw_mesh = nil
    self._mega_dynamic_instance_count = 0
    self._mega_dynamic_instance_capacity = 0
    self._mega_dynamic_cube_handedness = "collapsed"
    self._mega_dynamic_cube_batch_key = "Block|0"
    if self.use_instancing then
        for i = 1, #chunks do
            if checkpoint then checkpoint('scene:cube-chunks',i,#chunks)end
            local chunk = chunks[i]
            -- empty chunks must pass through the builder too: a reused chunk can
            -- transition from one or more cubes to none, and its previous raw
            -- aliases were invalidated by the backend reset above
            if not self:_build_chunk_instance_mesh(chunk) then
                -- a local allocation failure must remain local. other Menori
                -- categories may already own valid instanced resources, so
                -- mutating the renderer-wide capability here would strand them
                self:_release_chunk_cube_meshes(chunk, {}, true)
                chunk.instance_count = #(chunk.cube_instances or {})
                chunk.static_cube_mesh = build_static_mesh(
                    self,
                    chunk.cube_instances,
                    nil,
                    chunk.cube_instance_part_ids)
            end
        end
        if checkpoint then checkpoint('scene:mega-cube')end
        self:_build_mega_cube_draw(chunks)
        return
    end

    for i = 1, #chunks do
        if checkpoint then checkpoint('scene:cube-chunks',i,#chunks)end
        local chunk = chunks[i]
        self:_release_chunk_cube_meshes(chunk, {}, true)
        chunk.instance_count = #chunk.cube_instances
        if #chunk.cube_instances > 0 then
            chunk.static_cube_mesh = build_static_mesh(self, chunk.cube_instances, nil, chunk.cube_instance_part_ids)
        else
            chunk.static_cube_mesh = nil
        end
    end
end

function RBX:_prepare_occlusion_buffer()
    local width = math.max(16, round_dimension(self.occlusion_buffer_width) or 96)
    local height = math.max(9, round_dimension(self.occlusion_buffer_height) or 54)
    local size = width * height

    if not self._occlusion_depth or #self._occlusion_depth ~= size then
        self._occlusion_depth = {}
    end

    for i = 1, size do
        self._occlusion_depth[i] = 2
    end

    self._occlusion_buffer_actual_width = width
    self._occlusion_buffer_actual_height = height
    return width, height
end

function RBX:_rasterize_occlusion_rect(projection, depth, shrink_pixels)
    if not projection or not self._occlusion_depth then
        return
    end

    local width = self._occlusion_buffer_actual_width
    local height = self._occlusion_buffer_actual_height
    local shrink = math.max(0, tonumber(shrink_pixels) or 0)
    local min_x = math.max(0, projection.min_x + shrink)
    local min_y = math.max(0, projection.min_y + shrink)
    local max_x = math.min(width - 1, projection.max_x - shrink)
    local max_y = math.min(height - 1, projection.max_y - shrink)
    if min_x > max_x or min_y > max_y then
        return
    end

    for y = min_y, max_y do
        local row = y * width
        for x = min_x, max_x do
            local index = row + x + 1
            if depth < self._occlusion_depth[index] then
                self._occlusion_depth[index] = depth
            end
        end
    end
end

function RBX:_projection_is_occluded(projection, expand_pixels, depth_bias)
    if not projection or not self._occlusion_depth then
        return false
    end

    local width = self._occlusion_buffer_actual_width
    local height = self._occlusion_buffer_actual_height
    local expand = math.max(0, tonumber(expand_pixels) or 0)
    local min_x = math.max(0, projection.min_x - expand)
    local min_y = math.max(0, projection.min_y - expand)
    local max_x = math.min(width - 1, projection.max_x + expand)
    local max_y = math.min(height - 1, projection.max_y + expand)
    if min_x > max_x or min_y > max_y then
        return false
    end

    local wanted_depth = projection.near_depth - (depth_bias or self.occlusion_depth_bias or 0)
    for y = min_y, max_y do
        local row = y * width
        for x = min_x, max_x do
            local depth = self._occlusion_depth[row + x + 1]
            if depth > wanted_depth then
                return false
            end
        end
    end

    return true
end

function RBX:_update_adaptive_mega_batch_state(stats)
    stats = stats or self._culling_stats or {}
    local cube_available = self.use_instancing == true
        and self._mega_cube_draw_mesh ~= nil
        and (self._mega_instance_count or 0) > 0
    local primitive_available = self.use_instancing == true
        and type(self._mega_static_draw_items) == "table"
        and #self._mega_static_draw_items > 0
        and (self._mega_primitive_instance_count or 0) > 0

    if self.adaptive_mega_batch == false or self.use_instancing ~= true then
        self._mega_cube_path_active = false
        self._mega_primitive_path_active = false
        return
    end

    local chunk_count = math.max(1, tonumber(stats.chunk_count) or 0)
    local occluded_chunk_ratio = (tonumber(stats.occlusion_chunk_cull_count or stats.occluded_chunk_count) or 0) /
        chunk_count
    local item_test_count = math.max(1, tonumber(stats.occlusion_item_test_count) or 0)
    local occluded_item_ratio = (tonumber(stats.occlusion_item_cull_count) or 0) / item_test_count
    local occlusion_beneficial = self.enable_occlusion_culling == true
        and self.occlusion_disable_mega_when_beneficial ~= false
        and (occluded_chunk_ratio >= (self.occlusion_benefit_chunk_cull_ratio or 0.06)
            or occluded_item_ratio >= (self.occlusion_benefit_chunk_cull_ratio or 0.06))
    -- a scene-wide draw can only bind one local-light pack. when more active
    -- lights exist than the shader slots, spatial chunks may need different
    -- selections, retain per-chunk draws until clustered mega batches exist
    local local_light_overflow = self.enable_local_lights ~= false
        and (tonumber(self.local_light_count) or 0)
            > math.max(0, tonumber(self.max_lights_per_batch) or 0)

    stats.occlusion_mega_disabled = occlusion_beneficial
    stats.local_light_mega_disabled = local_light_overflow
    stats.mega_local_light_overflow_disabled = local_light_overflow
    if self.force_mega_batch == true
        and not occlusion_beneficial
        and not local_light_overflow then
        self._mega_cube_path_active = cube_available
        self._mega_primitive_path_active = primitive_available
        return
    end
    if occlusion_beneficial or local_light_overflow then
        self._mega_cube_path_active = false
        self._mega_primitive_path_active = false
        return
    end

    local visible_chunk_ratio = clamp(
        (tonumber(stats.visible_opaque_chunk_count) or 0) / chunk_count, 0, 1)
    local opaque_part_count = math.max(1, tonumber(self._opaque_part_count) or 0)
    local visible_part_ratio = clamp(
        (tonumber(stats.visible_opaque_part_count) or 0) / opaque_part_count, 0, 1)
    local visible_opaque_chunk_count = tonumber(stats.visible_opaque_chunk_count) or 0
    local min_visible_chunks = tonumber(self.mega_batch_min_visible_chunks) or 0
    local preferred = self.prefer_mega_batch == true
    local default_enter_ratio = preferred and 0.62 or 0.72
    local default_exit_ratio = preferred and 0.48 or 0.55
    local enter_ratio = clamp(tonumber(self.mega_batch_enter_visible_ratio) or default_enter_ratio, 0, 1)
    local exit_ratio = clamp(tonumber(self.mega_batch_exit_visible_ratio) or default_exit_ratio, 0, enter_ratio)
    local small_scene_limit = math.max(
        0, tonumber(self.mega_batch_small_scene_instance_limit) or 4096)

    -- on small scenes, the original absolute chunk threshold still avoids needless
    -- submission overhead. on large maps it is unsafe: crossing 96 nearby chunks
    -- could suddenly replace a culled set with one draw containing tens of thousands
    -- of off-screen instances. Require both useful instance coverage and broad spatial
    -- coverage there, hysteresis keeps the choice stable while moving
    local function mega_path_worthwhile(
        total_instance_count,
        visible_instance_count,
        ratio,
        chunk_threshold_scale)
        total_instance_count = math.max(1, tonumber(total_instance_count) or 0)
        local has_visible_instance_count = visible_instance_count ~= nil
        local visible_instance_ratio = has_visible_instance_count
            and clamp(
                (tonumber(visible_instance_count) or 0) / total_instance_count,
                0,
                1
            )
            or visible_part_ratio
        local small_scene = total_instance_count <= small_scene_limit
        local chunk_threshold = math.max(1, min_visible_chunks * chunk_threshold_scale)
        if small_scene then
            return visible_opaque_chunk_count >= chunk_threshold
                or visible_chunk_ratio >= ratio
                or visible_part_ratio >= ratio,
                visible_instance_ratio,
                false
        end
        return visible_instance_ratio >= ratio
                and visible_chunk_ratio >= ratio * 0.5,
            visible_instance_ratio,
            true
    end

    local cube_ratio = 0
    local cube_large_scene = false
    if cube_available then
        local cube_ratio_gate = self._mega_cube_path_active
            and exit_ratio or enter_ratio
        local cube_chunk_scale = self._mega_cube_path_active and 0.75 or 1
        self._mega_cube_path_active, cube_ratio, cube_large_scene =
            mega_path_worthwhile(
                self._mega_instance_count,
                stats.visible_cube_instance_count,
                cube_ratio_gate,
                cube_chunk_scale
            )
    else
        self._mega_cube_path_active = false
    end

    local primitive_ratio = 0
    local primitive_large_scene = false
    if primitive_available then
        local primitive_ratio_gate = self._mega_primitive_path_active
            and exit_ratio or enter_ratio
        local primitive_chunk_scale = self._mega_primitive_path_active and 0.75 or 1
        self._mega_primitive_path_active,
            primitive_ratio,
            primitive_large_scene = mega_path_worthwhile(
                self._mega_primitive_instance_count,
                stats.visible_primitive_instance_count,
                primitive_ratio_gate,
                primitive_chunk_scale
            )
    else
        self._mega_primitive_path_active = false
    end

    stats.mega_visible_instance_ratio = cube_ratio
    stats.mega_primitive_visible_instance_ratio = primitive_ratio
    stats.mega_visible_chunk_ratio = visible_chunk_ratio
    stats.mega_large_scene_gate = cube_large_scene
    stats.mega_primitive_large_scene_gate = primitive_large_scene
end

function RBX:_update_visible_scene()
    local culling_start = love.timer.getTime()
    -- must run before the cull cache check, so sleep/wake forces a re-cull
    self:_apply_settled_dynamic_merge()
    local chunks = self._scene_chunks or {}
    local static_chunks = self._scene_static_chunks or chunks
    local dynamic_chunks = self._scene_dynamic_chunks_drawn or self._scene_dynamic_chunks or {}
    local scene_bvh = self._scene_chunk_bvh
    local cache = self._visible_scene_cache_state or {}
    local camera = self.camera.cframe
    local opaque_part_count = tonumber(self._opaque_part_count) or 0
    local large_scene_full_visible_cache = (tonumber(self._opaque_part_count) or 0) >= 4000
        or #chunks >= 512
    local mega_visibility_cache_eligible = self.prefer_mega_batch == true
        or self._mega_cube_path_active == true
        or self._mega_primitive_path_active == true
    local full_visible_cache_frames_remaining = tonumber(cache.full_visible_fast_path_frames_remaining) or 0
    local full_visible_fast_path = large_scene_full_visible_cache
        and mega_visibility_cache_eligible
        and self.enable_occlusion_culling ~= true
        and self.enable_frustum_culling ~= false
        and cache.full_visible_fast_path == true
        and full_visible_cache_frames_remaining > 0
    if cache.scene_revision == self._scene_revision
        -- Camera-tolerant static reuse cannot retain a camera-dependent
        -- dynamic rejection. an unchanged camera still takes the normal hit
        and (cache.camera == camera or (full_visible_fast_path
            and not self._dynamic_frustum_cull_present))
        and cache.width == self._last_width
        and cache.height == self._last_height
        and cache.flip_y == self._projection_flip_y
        and cache.fov == self.camera.fov
        and (full_visible_fast_path or cache.near_clip == self._active_near_clip)
        and (full_visible_fast_path or cache.far_clip == self._active_far_clip)
        and cache.enable_frustum_culling == self.enable_frustum_culling
        and cache.enable_occlusion_culling == self.enable_occlusion_culling
        and cache.enable_chunk_occlusion_culling == self.enable_chunk_occlusion_culling
        and cache.enable_item_occlusion_culling == self.enable_item_occlusion_culling
        and cache.occlusion_buffer_width == self.occlusion_buffer_width
        and cache.occlusion_buffer_height == self.occlusion_buffer_height
        and cache.occlusion_min_area == self.occlusion_min_area
        and cache.occlusion_depth_bias == self.occlusion_depth_bias
        and cache.occlusion_occluder_shrink_pixels == self.occlusion_occluder_shrink_pixels
        and cache.occlusion_test_expand_pixels == self.occlusion_test_expand_pixels then
        if full_visible_fast_path then
            cache.full_visible_fast_path_frames_remaining = math.max(
                0,
                (tonumber(cache.full_visible_fast_path_frames_remaining) or 0) - 1
            )
            -- fast path tolerates a moved camera but per-group frustum flags are exact vs the OLD
            -- one: reset to nil (=drawn) or a culled group stays invisible when orbited into view
            if cache.camera ~= camera then
                local groups = self._instanced_mesh_groups
                if groups then
                    for group_index = 1, #groups do
                        groups[group_index].frustum_visible = nil
                    end
                end
            end
        end
        self._last_cull_ms = 0
        if self._culling_stats then
            self._culling_stats.culling_time_ms = 0
            self._culling_stats.full_visible_fast_path = full_visible_fast_path
        end
        self._cull_cache_hit_count = (self._cull_cache_hit_count or 0) + 1
        return
    end

    -- dynamic-only refresh: reuse cached static visibility, re-append dynamic, skip static re-cull
    if not full_visible_fast_path
        and self._static_visible_cache_valid
        and cache.static_scene_revision == self._static_scene_revision
        and self:_static_cull_inputs_match(cache, camera) then
        local refresh_start = love.timer.getTime()
        self._visible_scene_revision = (self._visible_scene_revision or 0) + 1
        self:_restore_static_visible()
        local accum = self._static_vis_bounds and {
            min_x = self._static_vis_bounds.min_x, min_y = self._static_vis_bounds.min_y,
            min_z = self._static_vis_bounds.min_z, max_x = self._static_vis_bounds.max_x,
            max_y = self._static_vis_bounds.max_y, max_z = self._static_vis_bounds.max_z,
        } or { min_x = math.huge, min_y = math.huge, min_z = math.huge,
            max_x = -math.huge, max_y = -math.huge, max_z = -math.huge }
        self:_append_dynamic_chunks_to_visible(self._scene_dynamic_chunks_drawn or self._scene_dynamic_chunks,
            accum, self._static_vis_signature or 0)
        cache.scene_revision = self._scene_revision
        self._cull_dynamic_refresh_count = (self._cull_dynamic_refresh_count or 0) + 1
        self._last_cull_ms = (love.timer.getTime() - refresh_start) * 1000
        if self._culling_stats then self._culling_stats.culling_time_ms = self._last_cull_ms end
        return
    end

    -- full recompute: should stay ~0/frame while only dynamics move
    self._cull_recompute_count = (self._cull_recompute_count or 0) + 1

    local visible_opaque_chunks = self._visible_opaque_chunks_buffer or {}
    local visible_transparent_draw_items = self._visible_transparent_draw_items_buffer or {}
    local visible_textured_batches = self._visible_textured_batches_buffer or {}
    local visible_overlay_textured_batches = self._visible_overlay_textured_batches_buffer or {}
    local visible_surface_gui_batches = self._visible_surface_gui_batches_buffer or {}
    local visible_static_draw_items = self._visible_static_draw_items_buffer or {}
    local opaque_candidates = self._opaque_candidates_buffer or {}
    local occluder_projections = self._occluder_projection_buffer or {}
    local visible_chunk_marks = self._visible_chunk_marks or {}
    local visible_transparent_part_marks = self._visible_transparent_part_marks or {}
    local visible_glass_part_marks = self._visible_glass_part_marks or {}
    local chunk_mark_id = (self._visible_chunk_mark_id or 0) + 1
    local transparent_part_mark_id = (self._visible_transparent_part_mark_id or 0) + 1
    local glass_part_mark_id = (self._visible_glass_part_mark_id or 0) + 1

    self._visible_chunk_mark_id = chunk_mark_id
    self._visible_transparent_part_mark_id = transparent_part_mark_id
    self._visible_glass_part_mark_id = glass_part_mark_id
    self._visible_opaque_chunks_buffer = visible_opaque_chunks
    self._visible_transparent_draw_items_buffer = visible_transparent_draw_items
    self._visible_textured_batches_buffer = visible_textured_batches
    self._visible_overlay_textured_batches_buffer = visible_overlay_textured_batches
    self._visible_surface_gui_batches_buffer = visible_surface_gui_batches
    self._visible_static_draw_items_buffer = visible_static_draw_items
    self._opaque_candidates_buffer = opaque_candidates
    self._occluder_projection_buffer = occluder_projections
    self._visible_chunk_marks = visible_chunk_marks
    self._visible_transparent_part_marks = visible_transparent_part_marks
    self._visible_glass_part_marks = visible_glass_part_marks

    local visible_chunk_count = 0
    local visible_opaque_chunk_count = 0
    local visible_transparent_draw_count = 0
    local visible_transparent_part_count = 0
    local visible_glass_part_count = 0
    local frustum_visible_chunk_count = 0
    local frustum_visible_opaque_part_count = 0
    local occluded_chunk_count = 0
    local occluder_chunk_count = 0
    local occluder_candidate_count = 0
    local occluder_accepted_count = 0
    local occlusion_chunk_test_count = 0
    local occlusion_chunk_cull_count = 0
    local occlusion_item_test_count = 0
    local occlusion_item_cull_count = 0
    local occlusion_false_positive_guard_count = 0
    local visible_opaque_part_count = 0
    local visible_cube_instance_count = 0
    local visible_primitive_instance_count = 0
    local occluded_opaque_part_count = 0
    local visible_surface_gui_batch_count = 0
    local visible_transparent_signature = 0
    local visible_scene_bounds = {
        min_x = math.huge,
        min_y = math.huge,
        min_z = math.huge,
        max_x = -math.huge,
        max_y = -math.huge,
        max_z = -math.huge,
    }
    local invalid_bounds_count = 0
    local frustum_culled_chunk_count = 0
    local culling_disabled_reason = nil
    local largest_rejected_chunk_key = nil
    local largest_rejected_reason = nil
    local largest_rejected_opaque_parts = 0
    local largest_rejected_instance_count = 0
    local largest_rejected_score = -1
    local textured_mega_locked = self._textured_mega_locked == true

    -- static textured meshes are already represented by the scene-wide locked
    -- batches in this mode. Rebuilding and sorting their deferred per-chunk
    -- metadata on every camera cull only creates work, SurfaceGuis and dynamic
    -- chunks still need their normal visibility path
    local function chunk_textured_batch_needed(batch)
        return not textured_mega_locked
            or (batch and (batch.source_kind == "SurfaceGui"
                or batch.dynamic_chunk == true))
    end

    local function bounds_valid_for_cull(bounds)
        if not bounds then
            return false
        end
        if RBX._bounds_are_finite and not RBX._bounds_are_finite(bounds) then
            invalid_bounds_count = invalid_bounds_count + 1
            return false
        end
        return true
    end

    local function note_rejected_chunk(chunk, reason)
        if not chunk then
            return
        end
        local score = (tonumber(chunk.opaque_part_count) or 0)
            + (tonumber(chunk.transparent_part_count) or 0)
            + (tonumber(chunk.instance_count) or 0)
        if score > largest_rejected_score then
            largest_rejected_score = score
            largest_rejected_chunk_key = chunk.key or chunk.bvh_key or "bvh_node"
            largest_rejected_reason = reason
            largest_rejected_opaque_parts = tonumber(chunk.opaque_part_count) or 0
            largest_rejected_instance_count = tonumber(chunk.instance_count) or 0
        end
    end

    clear_array(visible_opaque_chunks)
    clear_array(visible_transparent_draw_items)
    clear_array(visible_textured_batches)
    clear_array(visible_overlay_textured_batches)
    clear_array(visible_surface_gui_batches)
    clear_array(visible_static_draw_items)
    clear_array(opaque_candidates)
    clear_array(occluder_projections)

    if #chunks == 0 then
        self._visible_opaque_chunks = visible_opaque_chunks
        self._visible_transparent_draw_items = visible_transparent_draw_items
        self._visible_textured_batches = visible_textured_batches
        self._visible_overlay_textured_batches = visible_overlay_textured_batches
        self._visible_surface_gui_batches = visible_surface_gui_batches
        self._visible_static_draw_items = visible_static_draw_items
        self._visible_scene_bounds = nil
        self._visible_transparent_signature = 0
        self._culling_stats = {
            chunk_count = 0,
            visible_chunk_count = 0,
            visible_opaque_chunk_count = 0,
            visible_transparent_draw_count = 0,
            visible_transparent_part_count = 0,
            visible_glass_part_count = 0,
            visible_opaque_part_count = 0,
            frustum_visible_opaque_part_count = 0,
            occluded_opaque_part_count = 0,
            occluded_chunk_count = 0,
            occluder_chunk_count = 0,
            frustum_visible_chunk_count = 0,
            frustum_culled_chunk_count = 0,
            invalid_bounds_count = 0,
            invalid_culling_input = false,
            culling_disabled_reason = nil,
            largest_rejected_chunk_key = nil,
            largest_rejected_reason = nil,
            largest_rejected_opaque_parts = 0,
            largest_rejected_instance_count = 0,
            visible_cube_instance_count = 0,
            visible_primitive_instance_count = 0,
            occlusion_enabled = false,
            occlusion_requested = self.enable_occlusion_culling == true,
            occlusion_adaptive_skipped = false,
            occlusion_adaptive_skip_remaining = tonumber(self._occlusion_adaptive_skip_count) or 0,
            occlusion_buffer_width = 0,
            occlusion_buffer_height = 0,
            occluder_candidate_count = 0,
            occluder_accepted_count = 0,
            occlusion_chunk_test_count = 0,
            occlusion_chunk_cull_count = 0,
            occlusion_item_test_count = 0,
            occlusion_item_cull_count = 0,
            occlusion_false_positive_guard_count = 0,
            occlusion_time_ms = 0,
            culling_time_ms = culling_start and (love.timer.getTime() - culling_start) * 1000 or 0,
        }
        self._last_cull_ms = self._culling_stats.culling_time_ms or 0
        self:_update_adaptive_mega_batch_state(self._culling_stats)
        -- empty scene: nothing to reuse next frame
        self._static_visible_cache_valid = false
        cache.scene_revision = self._scene_revision
        cache.camera = camera
        cache.width = self._last_width
        cache.height = self._last_height
        cache.flip_y = self._projection_flip_y
        cache.fov = self.camera.fov
        cache.near_clip = self._active_near_clip
        cache.far_clip = self._active_far_clip
        cache.enable_frustum_culling = self.enable_frustum_culling
        cache.enable_occlusion_culling = self.enable_occlusion_culling
        cache.enable_chunk_occlusion_culling = self.enable_chunk_occlusion_culling
        cache.enable_item_occlusion_culling = self.enable_item_occlusion_culling
        cache.occlusion_buffer_width = self.occlusion_buffer_width
        cache.occlusion_buffer_height = self.occlusion_buffer_height
        cache.occlusion_min_area = self.occlusion_min_area
        cache.occlusion_depth_bias = self.occlusion_depth_bias
        cache.occlusion_occluder_shrink_pixels = self.occlusion_occluder_shrink_pixels
        cache.occlusion_test_expand_pixels = self.occlusion_test_expand_pixels
        cache.full_visible_fast_path = false
        cache.full_visible_fast_path_frames_remaining = 0
        self._visible_scene_cache_state = cache
        self._visible_scene_revision = (self._visible_scene_revision or 0) + 1
        return
    end

    local camera_matrices_valid = (RBX._matrix_is_finite == nil)
        or (RBX._matrix_is_finite(self._projection_matrix) and RBX._matrix_is_finite(self._view_matrix))
    local vp = camera_matrices_valid and multiply_matrices(self._projection_matrix, self._view_matrix) or nil
    local planes = vp and extract_frustum_planes(vp) or nil
    local frustum_planes_valid = (RBX._frustum_planes_are_valid == nil) or RBX._frustum_planes_are_valid(planes)
    -- stash for the billboard pass (runs after this cull), stale stash ok, camera unchanged
    self._frame_frustum_planes = (planes and frustum_planes_valid) and planes or nil
    local frustum_culling_enabled = self.enable_frustum_culling
        and camera_matrices_valid
        and frustum_planes_valid
    if self.enable_frustum_culling and not frustum_culling_enabled then
        culling_disabled_reason = camera_matrices_valid and "invalid_frustum_planes" or "invalid_camera_matrices"
    end
    local buffer_width = 0
    local buffer_height = 0
    local occlusion_requested = self.enable_occlusion_culling == true
        and camera_matrices_valid
        and frustum_planes_valid
    local adaptive_occlusion_skipped = false
    if occlusion_requested and self.adaptive_occlusion_culling ~= false then
        local skip_count = tonumber(self._occlusion_adaptive_skip_count) or 0
        if skip_count > 0 then
            adaptive_occlusion_skipped = true
            self._occlusion_adaptive_skip_count = skip_count - 1
        end
    end
    local occlusion_enabled = occlusion_requested and not adaptive_occlusion_skipped
    local chunk_occlusion_enabled = occlusion_enabled and self.enable_chunk_occlusion_culling ~= false
    local item_occlusion_enabled = occlusion_enabled and self.enable_item_occlusion_culling ~= false
    local occlusion_start_time = nil
    if occlusion_enabled then
        occlusion_start_time = love.timer.getTime()
    end
    if occlusion_enabled then
        buffer_width, buffer_height = self:_prepare_occlusion_buffer()
    end
    local opaque_candidate_count = 0
    local look_x, look_y, look_z = camera:get_look_vector()

    local function enqueue_transparent_items(chunk)
        if not chunk.has_transparent_geometry then
            return
        end

        for j = 1, #chunk.transparent_draw_items do
            local item = chunk.transparent_draw_items[j]
            local item_visible = true
            if frustum_culling_enabled and bounds_valid_for_cull(item.bounds) then
                item_visible = not bounds_outside_frustum(item.bounds, planes)
            end
            if item_visible and item.source_kind == "SurfaceGui" then
                item_visible = self:_surface_gui_batch_is_visible(item)
            end
            if item_visible then
                if visible_chunk_marks[chunk.key] ~= chunk_mark_id then
                    visible_chunk_marks[chunk.key] = chunk_mark_id
                    visible_chunk_count = visible_chunk_count + 1
                end
                if item.source_transparent_part then
                    local source_ids = item.source_transparent_part_ids
                    if type(source_ids) == "table" then
                        for source_index = 1, #source_ids do
                            local source_id = source_ids[source_index]
                            if source_id ~= nil and visible_transparent_part_marks[source_id] ~= transparent_part_mark_id then
                                visible_transparent_part_marks[source_id] = transparent_part_mark_id
                                visible_transparent_part_count = visible_transparent_part_count + 1
                            end
                        end
                    elseif item.source_part_id ~= nil
                        and visible_transparent_part_marks[item.source_part_id] ~= transparent_part_mark_id then
                        visible_transparent_part_marks[item.source_part_id] = transparent_part_mark_id
                        visible_transparent_part_count = visible_transparent_part_count + 1
                    end
                end
                local glass_ids = item.source_glass_part_ids
                if type(glass_ids) == "table" then
                    for source_index = 1, #glass_ids do
                        local source_id = glass_ids[source_index]
                        if source_id ~= nil and visible_glass_part_marks[source_id] ~= glass_part_mark_id then
                            visible_glass_part_marks[source_id] = glass_part_mark_id
                            visible_glass_part_count = visible_glass_part_count + 1
                        end
                    end
                elseif item.is_glass_part and item.source_part_id ~= nil
                    and visible_glass_part_marks[item.source_part_id] ~= glass_part_mark_id then
                    visible_glass_part_marks[item.source_part_id] = glass_part_mark_id
                    visible_glass_part_count = visible_glass_part_count + 1
                end
                visible_transparent_draw_count = visible_transparent_draw_count + 1
                visible_transparent_draw_items[visible_transparent_draw_count] = item
                visible_transparent_signature = (visible_transparent_signature + get_transparent_item_signature(item)) %
                    VISIBLE_SIGNATURE_MOD
                if item.source_kind == "SurfaceGui" then
                    visible_surface_gui_batches[#visible_surface_gui_batches + 1] = item
                    visible_surface_gui_batch_count = visible_surface_gui_batch_count + 1
                end
                if item.bounds then
                    expand_bounds_with_bounds(visible_scene_bounds, item.bounds)
                end
            end
        end
    end

    local function enqueue_opaque_chunk(chunk)
        if not chunk.has_opaque_geometry then
            return
        end

        frustum_visible_opaque_part_count = frustum_visible_opaque_part_count + (chunk.opaque_part_count or 0)
        if occlusion_enabled then
            local dx = (chunk.bounds.center_x or 0) - camera.x
            local dy = (chunk.bounds.center_y or 0) - camera.y
            local dz = (chunk.bounds.center_z or 0) - camera.z
            chunk._distance2 = dx * dx + dy * dy + dz * dz
            chunk._screen_projection = project_bounds_to_buffer(
                chunk.bounds,
                self._view_matrix,
                self._projection_matrix,
                buffer_width,
                buffer_height,
                self._projection_flip_y
            )
            chunk._sort_depth = chunk._screen_projection and chunk._screen_projection.near_depth or 1
        else
            chunk._screen_projection = nil
            chunk._sort_depth = nil
            chunk._distance2 = nil
        end
        opaque_candidate_count = opaque_candidate_count + 1
        opaque_candidates[opaque_candidate_count] = chunk
    end

    local function visit_chunk(chunk)
        local in_frustum = true
        if frustum_culling_enabled and bounds_valid_for_cull(chunk.bounds) then
            in_frustum = not bounds_outside_frustum(chunk.bounds, planes)
        end
        if not in_frustum then
            frustum_culled_chunk_count = frustum_culled_chunk_count + 1
            note_rejected_chunk(chunk, "frustum_chunk")
            return
        end

        frustum_visible_chunk_count = frustum_visible_chunk_count + 1
        enqueue_opaque_chunk(chunk)
        enqueue_transparent_items(chunk)
    end

    local function node_sort_depth(node)
        local bounds = node and node.bounds
        if not bounds then
            return math.huge, math.huge
        end
        local dx = (bounds.center_x or 0) - camera.x
        local dy = (bounds.center_y or 0) - camera.y
        local dz = (bounds.center_z or 0) - camera.z
        return dot(dx, dy, dz, look_x, look_y, look_z) - (bounds.radius or 0), (dx * dx) + (dy * dy) + (dz * dz)
    end

    local function visit_bvh(node)
        if not node then
            return
        end

        if frustum_culling_enabled
            and bounds_valid_for_cull(node.bounds)
            and bounds_outside_frustum(node.bounds, planes) then
            note_rejected_chunk(node, "frustum_bvh_node")
            return
        end

        if node.chunks then
            for i = 1, #node.chunks do
                visit_chunk(node.chunks[i])
            end
            return
        end

        local first = node.left
        local second = node.right
        if occlusion_enabled and first and second then
            local first_depth, first_distance2 = node_sort_depth(first)
            local second_depth, second_distance2 = node_sort_depth(second)
            if second_depth < first_depth or (second_depth == first_depth and second_distance2 < first_distance2) then
                first, second = second, first
            end
        end

        visit_bvh(first)
        visit_bvh(second)
    end

    if full_visible_fast_path then
        for i = 1, #chunks do
            local chunk = chunks[i]
            if chunk.has_transparent_geometry then
                enqueue_transparent_items(chunk)
            end
            if chunk.has_opaque_geometry then
                if visible_chunk_marks[chunk.key] ~= chunk_mark_id then
                    visible_chunk_marks[chunk.key] = chunk_mark_id
                    visible_chunk_count = visible_chunk_count + 1
                end
                frustum_visible_chunk_count = frustum_visible_chunk_count + 1
                frustum_visible_opaque_part_count = frustum_visible_opaque_part_count + (chunk.opaque_part_count or 0)
                visible_opaque_part_count = visible_opaque_part_count + (chunk.opaque_part_count or 0)
                if chunk.dynamic_chunk ~= true then
                    visible_cube_instance_count =
                        visible_cube_instance_count + (chunk.instance_count or 0)
                end
                visible_opaque_chunk_count = visible_opaque_chunk_count + 1
                visible_opaque_chunks[visible_opaque_chunk_count] = chunk
                chunk.visible_revision = self._scene_revision
                if chunk.bounds then
                    expand_bounds_with_bounds(visible_scene_bounds, chunk.bounds)
                end
                if chunk.opaque_static_draw_items then
                    for j = 1, #chunk.opaque_static_draw_items do
                        local item = chunk.opaque_static_draw_items[j]
                        visible_static_draw_items[#visible_static_draw_items + 1] = item
                        if chunk.dynamic_chunk ~= true then
                            visible_primitive_instance_count =
                                visible_primitive_instance_count
                                    + math.max(0, tonumber(item.primitive_count) or 0)
                        end
                    end
                end
                if chunk.textured_batches then
                    for j = 1, #chunk.textured_batches do
                        local batch = chunk.textured_batches[j]
                        if chunk_textured_batch_needed(batch)
                            and (batch.source_kind ~= "SurfaceGui" or self:_surface_gui_batch_is_visible(batch)) then
                            visible_textured_batches[#visible_textured_batches + 1] = batch
                            if batch.source_kind == "SurfaceGui" then
                                visible_surface_gui_batches[#visible_surface_gui_batches + 1] = batch
                                visible_surface_gui_batch_count = visible_surface_gui_batch_count + 1
                            end
                        end
                    end
                end
                if chunk.overlay_textured_batches then
                    for j = 1, #chunk.overlay_textured_batches do
                        local batch = chunk.overlay_textured_batches[j]
                        if chunk_textured_batch_needed(batch)
                            and (batch.source_kind ~= "SurfaceGui" or self:_surface_gui_batch_is_visible(batch)) then
                            visible_overlay_textured_batches[#visible_overlay_textured_batches + 1] = batch
                            if batch.source_kind == "SurfaceGui" then
                                visible_surface_gui_batches[#visible_surface_gui_batches + 1] = batch
                                visible_surface_gui_batch_count = visible_surface_gui_batch_count + 1
                            end
                        end
                    end
                end
            end
        end

        self._visible_opaque_chunks = visible_opaque_chunks
        self._visible_transparent_draw_items = visible_transparent_draw_items
        self._visible_textured_batches = visible_textured_batches
        self._visible_overlay_textured_batches = visible_overlay_textured_batches
        self._visible_surface_gui_batches = visible_surface_gui_batches
        self._visible_static_draw_items = visible_static_draw_items
        -- groups draw scene-wide, bounds must feed visible bounds or depth-clip clips them
        do
            local groups = self._instanced_mesh_groups
            if groups then
                -- culled = skipped by draw + excluded from bounds union, nil = drawn
                local group_cull_enabled = self.instanced_group_cull == true
                    and frustum_culling_enabled
                local cull_started = group_cull_enabled and love.timer.getTime() or nil
                local visible_groups, culled_groups, culled_instances = 0, 0, 0
                for group_index = 1, #groups do
                    local group = groups[group_index]
                    local group_bounds = group.bounds
                    if group_cull_enabled and group_bounds
                        and bounds_valid_for_cull(group_bounds)
                        and bounds_outside_frustum(group_bounds, planes) then
                        group.frustum_visible = false
                        culled_groups = culled_groups + 1
                        culled_instances = culled_instances + (group.count or 0)
                    else
                        group.frustum_visible = nil
                        visible_groups = visible_groups + 1
                        if group_bounds then
                            expand_bounds_with_bounds(visible_scene_bounds, group_bounds)
                        end
                    end
                end
                self._instanced_group_cull_stats = {
                    visible = visible_groups,
                    culled = culled_groups,
                    culled_instances = culled_instances,
                    cull_ms = cull_started and (love.timer.getTime() - cull_started) * 1000 or 0,
                }
            end
        end
        self._visible_scene_bounds = finalize_bounds(visible_scene_bounds)
        sort_textured_draw_items(visible_textured_batches)
        sort_textured_draw_items(visible_overlay_textured_batches)
        self._visible_transparent_signature = visible_transparent_signature

        local culling_time_ms = culling_start and (love.timer.getTime() - culling_start) * 1000 or 0
        self._culling_stats = {
            chunk_count = #chunks,
            visible_chunk_count = visible_chunk_count,
            visible_opaque_chunk_count = visible_opaque_chunk_count,
            visible_transparent_draw_count = visible_transparent_draw_count,
            visible_transparent_part_count = visible_transparent_part_count,
            visible_glass_part_count = visible_glass_part_count,
            visible_opaque_part_count = visible_opaque_part_count,
            frustum_visible_opaque_part_count = frustum_visible_opaque_part_count,
            occluded_opaque_part_count = 0,
            occluded_chunk_count = 0,
            occluder_chunk_count = 0,
            frustum_visible_chunk_count = frustum_visible_chunk_count,
            frustum_culled_chunk_count = frustum_culled_chunk_count,
            invalid_bounds_count = invalid_bounds_count,
            invalid_culling_input = culling_disabled_reason ~= nil,
            culling_disabled_reason = culling_disabled_reason,
            largest_rejected_chunk_key = largest_rejected_chunk_key,
            largest_rejected_reason = largest_rejected_reason,
            largest_rejected_opaque_parts = largest_rejected_opaque_parts,
            largest_rejected_instance_count = largest_rejected_instance_count,
            visible_textured_batch_count = #visible_textured_batches,
            visible_overlay_textured_batch_count = #visible_overlay_textured_batches,
            visible_surface_gui_batch_count = visible_surface_gui_batch_count,
            visible_cube_instance_count = visible_cube_instance_count,
            visible_primitive_instance_count = visible_primitive_instance_count,
            occlusion_enabled = false,
            occlusion_requested = false,
            occlusion_adaptive_skipped = false,
            occlusion_adaptive_skip_remaining = 0,
            occlusion_buffer_width = 0,
            occlusion_buffer_height = 0,
            occluder_candidate_count = 0,
            occluder_accepted_count = 0,
            occlusion_chunk_test_count = 0,
            occlusion_chunk_cull_count = 0,
            occlusion_item_test_count = 0,
            occlusion_item_cull_count = 0,
            occlusion_item_gate_active = false,
            occlusion_false_positive_guard_count = 0,
            occlusion_time_ms = 0,
            culling_time_ms = culling_time_ms,
            full_visible_fast_path = true,
        }
        self._last_cull_ms = culling_time_ms
        self:_update_adaptive_mega_batch_state(self._culling_stats)
        cache.scene_revision = self._scene_revision
        cache.camera = camera
        cache.width = self._last_width
        cache.height = self._last_height
        cache.flip_y = self._projection_flip_y
        cache.fov = self.camera.fov
        cache.near_clip = self._active_near_clip
        cache.far_clip = self._active_far_clip
        cache.enable_frustum_culling = self.enable_frustum_culling
        cache.enable_occlusion_culling = self.enable_occlusion_culling
        cache.enable_chunk_occlusion_culling = self.enable_chunk_occlusion_culling
        cache.enable_item_occlusion_culling = self.enable_item_occlusion_culling
        cache.occlusion_buffer_width = self.occlusion_buffer_width
        cache.occlusion_buffer_height = self.occlusion_buffer_height
        cache.occlusion_min_area = self.occlusion_min_area
        cache.occlusion_depth_bias = self.occlusion_depth_bias
        cache.occlusion_occluder_shrink_pixels = self.occlusion_occluder_shrink_pixels
        cache.occlusion_test_expand_pixels = self.occlusion_test_expand_pixels
        cache.full_visible_fast_path = true
        -- this branch includes every dynamic chunk, so no rejection survives
        self._dynamic_frustum_cull_present = false
        -- fast path includes all chunks (no static cache), dont let a later frame reuse a stale set
        self._static_visible_cache_valid = false
        cache.full_visible_fast_path_frames_remaining = math.max(
            1,
            tonumber(self.full_visible_cull_cache_frames) or 8
        )
        self._visible_scene_cache_state = cache
        self._visible_scene_revision = (self._visible_scene_revision or 0) + 1
        return
    end

    -- static-only cull, dynamics appended after, so a moving part doesnt force this to re-run
    if scene_bvh then
        visit_bvh(scene_bvh)
    else
        for i = 1, #static_chunks do
            visit_chunk(static_chunks[i])
        end
    end

    if occlusion_enabled then
        table.sort(opaque_candidates, opaque_candidate_less)

        local min_occluder_area = self.occlusion_min_projected_area or self.occlusion_min_area or 1
        for i = 1, opaque_candidate_count do
            local chunk = opaque_candidates[i]
            chunk._occlusion_has_accepted_occluder = false
            local candidates = chunk.occluder_candidates
            for j = 1, #(candidates or {}) do
                occluder_candidate_count = occluder_candidate_count + 1
                local candidate = candidates[j]
                local projection = project_bounds_to_buffer(
                    candidate.bounds,
                    self._view_matrix,
                    self._projection_matrix,
                    buffer_width,
                    buffer_height,
                    self._projection_flip_y
                )
                if projection
                    and projection.all_in_front
                    and projection.area >= min_occluder_area then
                    projection.chunk_key = chunk.key
                    projection.chunk = chunk
                    occluder_accepted_count = occluder_accepted_count + 1
                    occluder_projections[occluder_accepted_count] = projection
                    if chunk._occlusion_has_accepted_occluder ~= true then
                        chunk._occlusion_has_accepted_occluder = true
                        occluder_chunk_count = occluder_chunk_count + 1
                    end
                end
            end
        end

        table.sort(occluder_projections, occluder_projection_less)
        for i = 1, occluder_accepted_count do
            local projection = occluder_projections[i]
            self:_rasterize_occlusion_rect(
                projection,
                projection.far_depth,
                self.occlusion_occluder_shrink_pixels
            )
        end
    end

    local has_occluder = occluder_accepted_count > 0
    local item_occlusion_gate_active = false
    local function opaque_batch_visible_after_occlusion(batch)
        if not item_occlusion_enabled or not item_occlusion_gate_active or not has_occluder or not batch or
            not batch.bounds then
            return true
        end
        if batch.source_kind == "SurfaceGui" then
            return true
        end
        local projection = project_bounds_to_buffer(
            batch.bounds,
            self._view_matrix,
            self._projection_matrix,
            buffer_width,
            buffer_height,
            self._projection_flip_y
        )
        if not projection or not projection.all_in_front then
            return true
        end
        occlusion_item_test_count = occlusion_item_test_count + 1
        if self:_projection_is_occluded(
            projection,
            self.occlusion_test_expand_pixels,
            self.occlusion_min_depth_separation
        ) then
            occlusion_item_cull_count = occlusion_item_cull_count + 1
            return false
        end
        return true
    end

    for i = 1, opaque_candidate_count do
        local chunk = opaque_candidates[i]
        local projection = chunk._screen_projection
        local is_occluded = false
        if chunk_occlusion_enabled and has_occluder and projection and projection.all_in_front then
            if chunk._occlusion_has_accepted_occluder == true then
                occlusion_false_positive_guard_count = occlusion_false_positive_guard_count + 1
            else
                occlusion_chunk_test_count = occlusion_chunk_test_count + 1
                is_occluded = self:_projection_is_occluded(
                    projection,
                    self.occlusion_test_expand_pixels,
                    self.occlusion_min_depth_separation
                )
            end
            if item_occlusion_enabled and not item_occlusion_gate_active and occlusion_chunk_test_count >= 48 then
                local chunk_cull_ratio = occlusion_chunk_cull_count / math.max(1, occlusion_chunk_test_count)
                item_occlusion_gate_active = occlusion_chunk_cull_count >= 16 or chunk_cull_ratio >= 0.035
            end
        end

        if is_occluded then
            occluded_chunk_count = occluded_chunk_count + 1
            occlusion_chunk_cull_count = occlusion_chunk_cull_count + 1
            occluded_opaque_part_count = occluded_opaque_part_count + (chunk.opaque_part_count or 0)
            note_rejected_chunk(chunk, "occlusion_chunk")
        else
            if visible_chunk_marks[chunk.key] ~= chunk_mark_id then
                visible_chunk_marks[chunk.key] = chunk_mark_id
                visible_chunk_count = visible_chunk_count + 1
            end
            visible_opaque_part_count = visible_opaque_part_count + (chunk.opaque_part_count or 0)
            if chunk.dynamic_chunk ~= true then
                visible_cube_instance_count =
                    visible_cube_instance_count + (chunk.instance_count or 0)
            end
            visible_opaque_chunk_count = visible_opaque_chunk_count + 1
            visible_opaque_chunks[visible_opaque_chunk_count] = chunk
            chunk.visible_revision = self._scene_revision
            if chunk.bounds then
                expand_bounds_with_bounds(visible_scene_bounds, chunk.bounds)
            end
            if chunk.opaque_static_draw_items then
                for j = 1, #chunk.opaque_static_draw_items do
                    local item = chunk.opaque_static_draw_items[j]
                    visible_static_draw_items[#visible_static_draw_items + 1] = item
                    if chunk.dynamic_chunk ~= true then
                        visible_primitive_instance_count =
                            visible_primitive_instance_count
                                + math.max(0, tonumber(item.primitive_count) or 0)
                    end
                end
            end
            if chunk.textured_batches then
                for j = 1, #chunk.textured_batches do
                    local batch = chunk.textured_batches[j]
                    if chunk_textured_batch_needed(batch)
                        and opaque_batch_visible_after_occlusion(batch)
                        and (batch.source_kind ~= "SurfaceGui" or self:_surface_gui_batch_is_visible(batch)) then
                        visible_textured_batches[#visible_textured_batches + 1] = batch
                        if batch.source_kind == "SurfaceGui" then
                            visible_surface_gui_batches[#visible_surface_gui_batches + 1] = batch
                            visible_surface_gui_batch_count = visible_surface_gui_batch_count + 1
                        end
                    end
                end
            end
            if chunk.overlay_textured_batches then
                for j = 1, #chunk.overlay_textured_batches do
                    local batch = chunk.overlay_textured_batches[j]
                    if chunk_textured_batch_needed(batch)
                        and opaque_batch_visible_after_occlusion(batch)
                        and (batch.source_kind ~= "SurfaceGui" or self:_surface_gui_batch_is_visible(batch)) then
                        visible_overlay_textured_batches[#visible_overlay_textured_batches + 1] = batch
                        if batch.source_kind == "SurfaceGui" then
                            visible_surface_gui_batches[#visible_surface_gui_batches + 1] = batch
                            visible_surface_gui_batch_count = visible_surface_gui_batch_count + 1
                        end
                    end
                end
            end
        end
    end

    self._visible_opaque_chunks = visible_opaque_chunks
    self._visible_transparent_draw_items = visible_transparent_draw_items
    self._visible_textured_batches = visible_textured_batches
    self._visible_overlay_textured_batches = visible_overlay_textured_batches
    self._visible_surface_gui_batches = visible_surface_gui_batches
    self._visible_static_draw_items = visible_static_draw_items
    -- culled = skipped by draw + excluded from bounds union in _append_dynamic_chunks_to_visible, nil = drawn
    do
        local groups = self._instanced_mesh_groups
        if groups and #groups > 0 then
            local group_cull_enabled = self.instanced_group_cull == true
                and frustum_culling_enabled
            local cull_started = group_cull_enabled and love.timer.getTime() or nil
            local visible_groups, culled_groups, culled_instances = 0, 0, 0
            for group_index = 1, #groups do
                local group = groups[group_index]
                local group_bounds = group.bounds
                if group_cull_enabled and group_bounds
                    and bounds_valid_for_cull(group_bounds)
                    and bounds_outside_frustum(group_bounds, planes) then
                    group.frustum_visible = false
                    culled_groups = culled_groups + 1
                    culled_instances = culled_instances + (group.count or 0)
                else
                    group.frustum_visible = nil
                    visible_groups = visible_groups + 1
                end
            end
            self._instanced_group_cull_stats = {
                visible = visible_groups,
                culled = culled_groups,
                culled_instances = culled_instances,
                cull_ms = cull_started and (love.timer.getTime() - cull_started) * 1000 or 0,
            }
        end
    end
    -- sort static-only lists BEFORE the snapshot: every dynamic-refresh restore then starts
    -- from state order, and _append_dynamic_chunks_to_visible only re-sorts when dynamics
    -- actually appended (the comparator is a total order, so sort output is input-order
    -- independent and the final order is identical to the old sort-after-append)
    sort_textured_draw_items(visible_textured_batches)
    sort_textured_draw_items(visible_overlay_textured_batches)
    -- snapshot static-only set (pre-finalize bounds+signature) for reuse, then append dynamics
    self:_snapshot_static_visible(visible_opaque_chunks, visible_textured_batches,
        visible_overlay_textured_batches, visible_surface_gui_batches, visible_static_draw_items,
        visible_transparent_draw_items, visible_scene_bounds, visible_transparent_signature)
    self:_append_dynamic_chunks_to_visible(dynamic_chunks, visible_scene_bounds, visible_transparent_signature)
    local occlusion_time_ms = 0
    if occlusion_start_time then
        occlusion_time_ms = (love.timer.getTime() - occlusion_start_time) * 1000
    end
    local culling_time_ms = (love.timer.getTime() - culling_start) * 1000
    local occlusion_chunk_cull_ratio = occlusion_chunk_test_count > 0
        and (occlusion_chunk_cull_count / occlusion_chunk_test_count)
        or 0
    local occlusion_item_cull_ratio = occlusion_item_test_count > 0
        and (occlusion_item_cull_count / occlusion_item_test_count)
        or 0
    if not occlusion_requested then
        self._occlusion_adaptive_skip_count = 0
    elseif occlusion_enabled and self.adaptive_occlusion_culling ~= false then
        local useful = occlusion_chunk_cull_count >= 16
            or occlusion_item_cull_count >= 16
            or occlusion_chunk_cull_ratio >= 0.035
            or occlusion_item_cull_ratio >= 0.035
        if useful then
            self._occlusion_adaptive_skip_count = 0
        else
            self._occlusion_adaptive_skip_count = math.max(
                tonumber(self._occlusion_adaptive_skip_count) or 0,
                tonumber(self.occlusion_skip_frames_after_miss) or 0
            )
        end
    end
    self._culling_stats = {
        chunk_count = #chunks,
        visible_chunk_count = visible_chunk_count,
        visible_opaque_chunk_count = visible_opaque_chunk_count,
        visible_transparent_draw_count = visible_transparent_draw_count,
        visible_transparent_part_count = visible_transparent_part_count,
        visible_glass_part_count = visible_glass_part_count,
        visible_opaque_part_count = visible_opaque_part_count,
        frustum_visible_opaque_part_count = frustum_visible_opaque_part_count,
        occluded_opaque_part_count = occluded_opaque_part_count,
        occluded_chunk_count = occluded_chunk_count,
        occluder_chunk_count = occluder_chunk_count,
        frustum_visible_chunk_count = frustum_visible_chunk_count,
        frustum_culled_chunk_count = frustum_culled_chunk_count,
        invalid_bounds_count = invalid_bounds_count,
        invalid_culling_input = culling_disabled_reason ~= nil,
        culling_disabled_reason = culling_disabled_reason,
        largest_rejected_chunk_key = largest_rejected_chunk_key,
        largest_rejected_reason = largest_rejected_reason,
        largest_rejected_opaque_parts = largest_rejected_opaque_parts,
        largest_rejected_instance_count = largest_rejected_instance_count,
        visible_textured_batch_count = #visible_textured_batches,
        visible_overlay_textured_batch_count = #visible_overlay_textured_batches,
        visible_surface_gui_batch_count = visible_surface_gui_batch_count,
        visible_cube_instance_count = visible_cube_instance_count,
        visible_primitive_instance_count = visible_primitive_instance_count,
        occlusion_enabled = occlusion_enabled,
        occlusion_requested = occlusion_requested,
        occlusion_adaptive_skipped = adaptive_occlusion_skipped,
        occlusion_adaptive_skip_remaining = tonumber(self._occlusion_adaptive_skip_count) or 0,
        occlusion_buffer_width = buffer_width,
        occlusion_buffer_height = buffer_height,
        occluder_candidate_count = occluder_candidate_count,
        occluder_accepted_count = occluder_accepted_count,
        occlusion_chunk_test_count = occlusion_chunk_test_count,
        occlusion_chunk_cull_count = occlusion_chunk_cull_count,
        occlusion_item_test_count = occlusion_item_test_count,
        occlusion_item_cull_count = occlusion_item_cull_count,
        occlusion_item_gate_active = item_occlusion_gate_active,
        occlusion_false_positive_guard_count = occlusion_false_positive_guard_count,
        occlusion_time_ms = occlusion_time_ms,
        culling_time_ms = culling_time_ms,
        full_visible_fast_path = false,
    }
    self._last_cull_ms = culling_time_ms
    self:_update_adaptive_mega_batch_state(self._culling_stats)
    cache.scene_revision = self._scene_revision
    cache.static_scene_revision = self._static_scene_revision
    cache.camera = camera
    cache.width = self._last_width
    cache.height = self._last_height
    cache.flip_y = self._projection_flip_y
    cache.fov = self.camera.fov
    cache.near_clip = self._active_near_clip
    cache.far_clip = self._active_far_clip
    cache.enable_frustum_culling = self.enable_frustum_culling
    cache.enable_occlusion_culling = self.enable_occlusion_culling
    cache.enable_chunk_occlusion_culling = self.enable_chunk_occlusion_culling
    cache.enable_item_occlusion_culling = self.enable_item_occlusion_culling
    cache.occlusion_buffer_width = self.occlusion_buffer_width
    cache.occlusion_buffer_height = self.occlusion_buffer_height
    cache.occlusion_min_area = self.occlusion_min_area
    cache.occlusion_depth_bias = self.occlusion_depth_bias
    cache.occlusion_occluder_shrink_pixels = self.occlusion_occluder_shrink_pixels
    cache.occlusion_test_expand_pixels = self.occlusion_test_expand_pixels
    local arm_full_visible_cache = large_scene_full_visible_cache
        and mega_visibility_cache_eligible
        and not occlusion_requested
        and self.enable_frustum_culling ~= false
        and #chunks > 0
        and visible_opaque_chunk_count >= (#chunks * 0.97)
        and visible_opaque_part_count >= (opaque_part_count * 0.97)
    cache.full_visible_fast_path = arm_full_visible_cache
    cache.full_visible_fast_path_frames_remaining = arm_full_visible_cache
        and math.max(1, tonumber(self.full_visible_cull_cache_frames) or 8)
        or 0
    self._visible_scene_cache_state = cache
    self._visible_scene_revision = (self._visible_scene_revision or 0) + 1
end

-- static/dynamic visible-set split: full cull above is static-only, snapshotted for reuse
-- dynamics always included (no cull) -- that only over-draws, never hides

local function copy_into(dst, src)
    for i = #dst, 1, -1 do dst[i] = nil end
    if src then for i = 1, #src do dst[i] = src[i] end end
end

-- same comparison as the cull short-circuit minus scene_revision/fast-path camera exception
-- not local: _update_visible_scene (defined earlier) resolves it at call time
function RBX:_static_cull_inputs_match(cache, camera)
    return cache.camera == camera
        and cache.width == self._last_width
        and cache.height == self._last_height
        and cache.flip_y == self._projection_flip_y
        and cache.fov == self.camera.fov
        and cache.near_clip == self._active_near_clip
        and cache.far_clip == self._active_far_clip
        and cache.enable_frustum_culling == self.enable_frustum_culling
        and cache.enable_occlusion_culling == self.enable_occlusion_culling
        and cache.enable_chunk_occlusion_culling == self.enable_chunk_occlusion_culling
        and cache.enable_item_occlusion_culling == self.enable_item_occlusion_culling
        and cache.occlusion_buffer_width == self.occlusion_buffer_width
        and cache.occlusion_buffer_height == self.occlusion_buffer_height
        and cache.occlusion_min_area == self.occlusion_min_area
        and cache.occlusion_depth_bias == self.occlusion_depth_bias
        and cache.occlusion_occluder_shrink_pixels == self.occlusion_occluder_shrink_pixels
        and cache.occlusion_test_expand_pixels == self.occlusion_test_expand_pixels
end

-- bounds_accum is the PRE-finalize min/max accumulator, so dynamics can merge before finalize
function RBX:_snapshot_static_visible(opaque, textured, overlay, surface_gui, static_draw,
                                      transparent, bounds_accum, signature)
    self._static_vis_opaque = self._static_vis_opaque or {}
    self._static_vis_textured = self._static_vis_textured or {}
    self._static_vis_overlay = self._static_vis_overlay or {}
    self._static_vis_surface_gui = self._static_vis_surface_gui or {}
    self._static_vis_static_draw = self._static_vis_static_draw or {}
    self._static_vis_transparent = self._static_vis_transparent or {}
    copy_into(self._static_vis_opaque, opaque)
    copy_into(self._static_vis_textured, textured)
    copy_into(self._static_vis_overlay, overlay)
    copy_into(self._static_vis_surface_gui, surface_gui)
    copy_into(self._static_vis_static_draw, static_draw)
    copy_into(self._static_vis_transparent, transparent)
    self._static_vis_bounds = bounds_accum and {
        min_x = bounds_accum.min_x, min_y = bounds_accum.min_y, min_z = bounds_accum.min_z,
        max_x = bounds_accum.max_x, max_y = bounds_accum.max_y, max_z = bounds_accum.max_z,
    } or nil
    self._static_vis_signature = signature or 0
    self._static_visible_cache_valid = true
end

function RBX:_restore_static_visible()
    self._visible_opaque_chunks = self._visible_opaque_chunks_buffer or {}
    self._visible_textured_batches = self._visible_textured_batches_buffer or {}
    self._visible_overlay_textured_batches = self._visible_overlay_textured_batches_buffer or {}
    self._visible_surface_gui_batches = self._visible_surface_gui_batches_buffer or {}
    self._visible_static_draw_items = self._visible_static_draw_items_buffer or {}
    self._visible_transparent_draw_items = self._visible_transparent_draw_items_buffer or {}
    copy_into(self._visible_opaque_chunks, self._static_vis_opaque)
    copy_into(self._visible_textured_batches, self._static_vis_textured)
    copy_into(self._visible_overlay_textured_batches, self._static_vis_overlay)
    copy_into(self._visible_surface_gui_batches, self._static_vis_surface_gui)
    copy_into(self._visible_static_draw_items, self._static_vis_static_draw)
    copy_into(self._visible_transparent_draw_items, self._static_vis_transparent)
end

-- retain aggregate bounds, omit only eligible rigid meshes outside lateral planes
function RBX:_append_dynamic_chunks_to_visible(dynamic_chunks, bounds_accum, base_signature)
    self._dynamic_frustum_cull_present = false
    local opaque = self._visible_opaque_chunks
    local textured = self._visible_textured_batches
    local overlay = self._visible_overlay_textured_batches
    local surface_gui = self._visible_surface_gui_batches
    local static_draw = self._visible_static_draw_items
    local transparent = self._visible_transparent_draw_items
    local sig = base_signature or 0
    local rev = self._visible_scene_revision or 0
    dynamic_chunks = dynamic_chunks or {}
    -- restored static lists are already sorted, re-sort only if dynamics actually appended
    local textured_count_before = #textured
    local overlay_count_before = #overlay
    for i = 1, #dynamic_chunks do
        local chunk = dynamic_chunks[i]
        if chunk then
            local hidden = chunk._animation_visibility_hidden == true
            if not hidden then
            -- fast-bake snapshots and retained primitive decals each have one
            -- current single-owner bound. Cubes may draw through a scene-wide
            -- mega batch. keep near/far bounds and all mutation/upload/lifetime
            -- work unchanged, this only omits an outside color submission
            local eligible = self.enable_frustum_culling ~= false
                and (chunk._fast_bake ~= nil or chunk._fast_decal ~= nil)
                and #(chunk.cube_instances or {}) == 0
            local culled = eligible and bounds_outside_frustum(
                chunk.bounds, self._frame_frustum_planes, 4)
            if eligible then
                self._dynamic_frustum_test_count = (self._dynamic_frustum_test_count or 0) + 1
                if culled then
                    self._dynamic_frustum_culled_count = (self._dynamic_frustum_culled_count or 0) + 1
                    self._dynamic_frustum_cull_present = true
                end
            end
            if not culled then
            if chunk.has_opaque_geometry then
                opaque[#opaque + 1] = chunk
                chunk.visible_revision = rev
                local items = chunk.opaque_static_draw_items
                if items then for j = 1, #items do static_draw[#static_draw + 1] = items[j] end end
                local tb = chunk.textured_batches
                if tb then for j = 1, #tb do
                    local b = tb[j]
                    if b.source_kind ~= "SurfaceGui" or self:_surface_gui_batch_is_visible(b) then
                        textured[#textured + 1] = b
                        if b.source_kind == "SurfaceGui" then surface_gui[#surface_gui + 1] = b end
                    end
                end end
                local ob = chunk.overlay_textured_batches
                if ob then for j = 1, #ob do
                    local b = ob[j]
                    if b.source_kind ~= "SurfaceGui" or self:_surface_gui_batch_is_visible(b) then
                        overlay[#overlay + 1] = b
                        if b.source_kind == "SurfaceGui" then surface_gui[#surface_gui + 1] = b end
                    end
                end end
            end
            if chunk.has_transparent_geometry then
                local ti = chunk.transparent_draw_items
                for j = 1, #ti do
                    local item = ti[j]
                    if item.source_kind ~= "SurfaceGui" or self:_surface_gui_batch_is_visible(item) then
                        transparent[#transparent + 1] = item
                        sig = (sig + get_transparent_item_signature(item)) % VISIBLE_SIGNATURE_MOD
                        if item.source_kind == "SurfaceGui" then surface_gui[#surface_gui + 1] = item end
                    end
                end
            end
            end
            end
            if chunk.bounds and bounds_accum then expand_bounds_with_bounds(bounds_accum, chunk.bounds) end
        end
    end
    if #textured > textured_count_before then
        sort_textured_draw_items(textured)
    end
    if #overlay > overlay_count_before then
        sort_textured_draw_items(overlay)
    end
    -- group bounds keep depth-clip from clipping them (same union as full cull)
    if bounds_accum then
        local groups = self._instanced_mesh_groups
        if groups then
            for group_index = 1, #groups do
                local group = groups[group_index]
                -- mirror draw-pass skip: culled groups dont widen bounds
                if group.bounds and group.frustum_visible ~= false then
                    expand_bounds_with_bounds(bounds_accum, group.bounds)
                end
            end
        end
    end
    self._visible_scene_bounds = (bounds_accum and bounds_accum.min_x < math.huge)
        and finalize_bounds(bounds_accum) or nil
    self._visible_transparent_signature = sig
end

local function get_dynamic_scene_chunk_key(part)
    return "__dynamic_part:" .. tostring(part and part._id or "?")
end

-- zero a loaded part's baked static geo in place, true only if fully tracked+zeroed, else caller
-- must full-rebuild. also drops its transparent draw items + occluder candidates
function RBX:_release_static_part_geometry(part)
    local pid = part and part._id
    if pid == nil then
        return false
    end
    local geo = self._static_part_geo
    local tracked = self._static_part_tracked
    if not tracked or not tracked[pid] then
        return false
    end
    -- static shadow descriptors duplicate ownership/ranges. invalidate before
    -- zeroing or promoting a source, even if its Mesh/list identity survives
    self._directional_shadow_static_ownership_revision =
        (self._directional_shadow_static_ownership_revision or 0) + 1
    -- a not-yet-built candidate still owns the original non-zero CPU payload
    -- Letting it commit after this range is zeroed would resurrect a destroyed
    -- or promoted part inside the new shared mesh. keep already-built groups,
    -- but retire the remaining plan before mutating geometry
    if self._transparent_textured_range_build_state then
        self:_cancel_transparent_textured_range_build(
            "static_geometry_mutated")
    end
    -- Cluster buffers duplicate static instance rows. retire the whole
    -- revision-locked generation before zeroing any source row so a destroyed
    -- or promoted part can never survive as clustered ghost geometry
    if self._static_local_light_clusters then
        self:_release_static_local_light_clusters(true)
    end
    tracked[pid] = nil
    local slot = geo and geo[pid]
    if geo then
        geo[pid] = nil
    end
    -- range uploads include unchanged rows between their endpoints. retire
    -- the CPU owner together with its GPU range, or a neighbour's later pose
    -- upload resurrects a collected/destroyed instance from the retained rows
    local ref = part._instanced_ref
    local retained_row = ref and ref.group.rows and ref.group.rows[ref.row]
    if retained_row then
        for lane = 1, #retained_row do retained_row[lane] = 0 end
        ref.group.vertex_alpha_is_one = false
        ref.group._shadow_content_revision = (ref.group._shadow_content_revision or 0) + 1
        self._shadow_instance_flushed_revision = nil
    end
    if slot then
        for i = 1, #slot, 3 do
            if not self:_zero_mesh_vertex_range(slot[i], slot[i + 1], slot[i + 2]) then
                return false
            end
        end
    end
    -- must stop taking the row-move fast path (row already zeroed above)
    if part._instanced_ref then
        if self._dirty_instance_rows then
            self._dirty_instance_rows[part] = nil
        end
        part._instanced_ref = nil
    end

    local chunk = self._scene_chunk_map and part._scene_chunk_key
        and self._scene_chunk_map[part._scene_chunk_key] or nil
    if chunk and chunk.dynamic_chunk ~= true then
        local items = chunk.transparent_draw_items
        if items and #items > 0 then
            local write = 0
            local removed = false
            for i = 1, #items do
                local item = items[i]
                if item and item.source_part_id == pid and item.transparent_static_batch ~= true then
                    removed = true
                else
                    write = write + 1
                    items[write] = item
                end
            end
            for i = #items, write + 1, -1 do
                items[i] = nil
            end
            if removed then
                chunk.has_transparent_geometry = #items > 0
                self._static_scene_revision = (self._static_scene_revision or 0) + 1
                self._scene_revision = (self._scene_revision or 0) + 1
                if self._visible_scene_cache_state then
                    self._visible_scene_cache_state.scene_revision = nil
                end
                if self._transparent_sort_cache_state then
                    self._transparent_sort_cache_state.items = nil
                end
            end
        end
        local candidates = chunk.occluder_candidates
        if candidates and #candidates > 0 then
            local write = 0
            for i = 1, #candidates do
                local candidate = candidates[i]
                if not (candidate and candidate.part_id == pid) then
                    write = write + 1
                    candidates[write] = candidate
                end
            end
            if write < #candidates then
                for i = #candidates, write + 1, -1 do
                    candidates[i] = nil
                end
                chunk.occluder_candidate_count = write
                -- occlusion is baked into the cached cull, must invalidate or hidden chunks stay culled
                self._static_scene_revision = (self._static_scene_revision or 0) + 1
                self._scene_revision = (self._scene_revision or 0) + 1
                if self._visible_scene_cache_state then
                    self._visible_scene_cache_state.scene_revision = nil
                end
            end
        end
    end
    return true
end

function RBX:_unlink_dynamic_scene_chunk(chunk, key)
    local renderer = self
    local list = renderer._scene_chunks
    if list then
        for i = #list, 1, -1 do
            local entry = list[i]
            if entry == chunk or (entry and entry.key == key) then
                table.remove(list, i)
            end
        end
    end
    local dynamic_chunks = renderer._scene_dynamic_chunks
    if dynamic_chunks then
        for i = #dynamic_chunks, 1, -1 do
            local entry = dynamic_chunks[i]
            if entry == chunk or (entry and entry.key == key) then
                table.remove(dynamic_chunks, i)
            end
        end
        renderer:_build_dynamic_mega_cube_draw(dynamic_chunks)
    end
    renderer:_invalidate_dynamic_visible_cache()
end

-- store a retained owner outside Workspace without leaving its geometry in
-- culling, packet, shadow, bounds, or transparent-sort lists. this is opt-in:
-- ordinary Workspace departure keeps its established immediate release path
function RBX:_park_dynamic_scene_chunk_for_part(part)
    local key = get_dynamic_scene_chunk_key(part)
    local chunk_map = self._scene_chunk_map
    local chunk = chunk_map and chunk_map[key] or nil
    if not chunk then return false end
    local dormant = self._dormant_dynamic_scene_chunk_map
    if not dormant then dormant = {};self._dormant_dynamic_scene_chunk_map = dormant end
    local previous = dormant[key]
    if previous and previous ~= chunk then
        self:_release_scene_chunk_meshes(previous, {}, true)
    end
    dormant[key] = chunk
    chunk_map[key] = nil
    self:_unlink_dynamic_scene_chunk(chunk, key)
    return true
end

-- return a parked owner to active lists before its next transform sync. the
-- current authored pose/appearance is republished by that sync, the parked
-- chunk supplies only reusable mesh/CPU ownership
function RBX:_restore_parked_dynamic_scene_chunk_for_part(part)
    local key = get_dynamic_scene_chunk_key(part)
    local dormant = self._dormant_dynamic_scene_chunk_map
    local chunk = dormant and dormant[key] or nil
    if not chunk then return false end
    dormant[key] = nil
    if not next(dormant) then self._dormant_dynamic_scene_chunk_map = nil end
    if chunk.dynamic_part ~= part or chunk.dynamic_part_id ~= part._id then
        self:_release_scene_chunk_meshes(chunk, {}, true)
        return false
    end
    local chunk_map = self._scene_chunk_map or {}
    self._scene_chunk_map = chunk_map
    local active = chunk_map[key]
    if active and active ~= chunk then
        self:_release_scene_chunk_meshes(chunk, {}, true)
        return false
    end
    chunk_map[key] = chunk
    local list = self._scene_chunks or {}
    self._scene_chunks = list
    list[#list + 1] = chunk
    local dynamic_chunks = self._scene_dynamic_chunks or {}
    self._scene_dynamic_chunks = dynamic_chunks
    dynamic_chunks[#dynamic_chunks + 1] = chunk
    self:_build_dynamic_mega_cube_draw(dynamic_chunks)
    self:_invalidate_dynamic_visible_cache()
    return true
end

-- drop a dynamic part's chunk without a scene rebuild, settled merge
-- self-heals. a parked chunk is never active, but Destroy must release it
function RBX:_remove_dynamic_scene_chunk_for_part(part)
    local key = get_dynamic_scene_chunk_key(part)
    local chunk_map = self._scene_chunk_map
    local chunk = chunk_map and chunk_map[key] or nil
    if chunk then
        self:_release_scene_chunk_meshes(chunk, {}, true)
        chunk_map[key] = nil
        self:_unlink_dynamic_scene_chunk(chunk, key)
        return true
    end
    local dormant = self._dormant_dynamic_scene_chunk_map
    chunk = dormant and dormant[key] or nil
    if not chunk then return false end
    dormant[key] = nil
    if not next(dormant) then self._dormant_dynamic_scene_chunk_map = nil end
    self:_release_scene_chunk_meshes(chunk, {}, true)
    return true
end

function RBX:_preserve_dynamic_part_geometry_while_stored(part)
    assert(type(part)=="table" and not part._destroyed and part._retained_dynamic_geometry==true,
        "Stored dynamic geometry requires a retained live runtime part")
    part._preserve_dynamic_geometry_when_stored = true
    return true
end

-- Materialize one explicitly retained source owner while it is parked outside
-- Workspace. the chunk remains dormant: it is excluded from culling, packet,
-- shadow, bounds, transparent-sort, and physics membership until ordinary
-- Workspace publication restores it and queues a current-property sync
function RBX:_prepare_dynamic_part_geometry_while_stored(part)
    assert(type(part)=="table" and not part._destroyed
        and part._retained_dynamic_geometry==true
        and part._preserve_dynamic_geometry_when_stored==true,
        "Stored dynamic preparation requires a retained preservable live runtime part")
    if part._workspace_active~=false then return false,"not_stored" end
    local key=get_dynamic_scene_chunk_key(part)
    if self._scene_chunk_map and self._scene_chunk_map[key] then return false,"active" end
    local dormant=self._dormant_dynamic_scene_chunk_map
    if dormant and dormant[key] then
        part._prepared_dynamic_geometry_while_stored=true
        return true,"already_prepared"
    end
    -- the normal dynamic builder intentionally rejects stored parts. its
    -- explicit allow_stored lane is used only by this opt-in owner path
    local chunk=self:_build_dynamic_scene_chunk_for_part(part,part._id,nil,true)
    if not chunk then return false,"unsupported" end
    self:_build_single_scene_chunk_cube_draw(chunk)
    self:_capture_dynamic_chunk_fast_bake(chunk,part)
    self:_capture_dynamic_chunk_cube_fast(chunk,part)
    if not dormant then dormant={};self._dormant_dynamic_scene_chunk_map=dormant end
    dormant[key]=chunk
    part._prepared_dynamic_geometry_while_stored=true
    return true,"prepared"
end

-- Storage changes membership without destroying authored objects or their
-- progress. Cached membership is read by render/physics paths, never discovered
-- by a world hierarchy walk on every frame
function RBX:_retain_dynamic_part_geometry(part)
    assert(type(part)=="table" and not part._destroyed and part._loaded_from_map~=true,
        "Retained dynamic geometry requires a live runtime part")
    if part._retained_dynamic_geometry then return true end
    -- Transfer existing static ownership before choosing a persistent chunk
    -- Detached new parts have never published geometry and need no release
    if part._scene_chunk_key and not can_update_runtime_part_incrementally(self,part) then
        assert(part._static_geo_untracked~=true and self:_release_static_part_geometry(part),
            "Cannot transfer untracked static geometry")
    end
    part._retained_dynamic_geometry=true
    part._runtime_dynamic_sticky=true
    part._runtime_dynamic=true
    if part._appearance_dynamic then
        part._appearance_dynamic=nil
        if self._appearance_promoted_parts and self._appearance_promoted_parts[part._id] then
            self._appearance_promoted_parts[part._id]=nil
            self._appearance_promoted_count=math.max(0,(self._appearance_promoted_count or 1)-1)
        end
    end
    self:_mark_runtime_part_transform_dirty(part)
    return true
end

-- light payloads do not own geometry. refresh each original source's exact
-- selection, an aggregate remains eligible only while all sources agree
-- Divergence submits the retained source batches until they agree again
-- no union-bounds light selection, instance readback, upload or resource
-- retirement belongs to this data-only update
function RBX:_refresh_static_local_light_cluster_packs()
    local clusters=self._static_local_light_clusters
    if not clusters then return false end
    local revision=self._local_light_revision or 0
    local function refresh(items)
        for _,item in ipairs(items or {})do
            local pack,key,valid=nil,nil,true
            for _,source in ipairs(item.source_items or {})do
                local selected=self:_get_local_light_pack_for_item(source,true)
                local selected_key=RBX._local_light_pack_payload_key(selected)
                if not pack then pack,key=selected,selected_key
                elseif selected_key~=key then valid=false;break end
            end
            item.light_payload_valid=valid and pack~=nil
            if item.light_payload_valid then
                pin_local_light_cluster_pack(item,pack,item.bounds,revision,
                    self._local_light_pack_configuration_signature)
            end
        end
    end
    refresh(clusters.cube_items);refresh(clusters.primitive_items)
    clusters.light_revision=revision
    clusters.payload_refresh_count=(clusters.payload_refresh_count or 0)+1
    return true
end

function RBX:_set_runtime_part_workspace_membership(part,active)
    active=active==true
    if part._workspace_active==active then return end
    local previous=part._workspace_active;part._workspace_active=active
    if not active then
        if self._on_runtime_part_removed_from_physics then self:_on_runtime_part_removed_from_physics(part) end
        if self._invalidate_settled_merge_for_part then self:_invalidate_settled_merge_for_part(part) end
        local removed=part._preserve_dynamic_geometry_when_stored==true
            and self:_park_dynamic_scene_chunk_for_part(part)
            or self:_remove_dynamic_scene_chunk_for_part(part)
        local retired=removed or part._retained_dynamic_geometry==true or previous==false
            or (previous==nil and part._loaded_from_map~=true)
        if not removed and previous~=false and not part._retained_dynamic_geometry
            and (previous~=nil or part._loaded_from_map==true) then
            -- the first detached membership assignment of a new runtime part
            -- has no published geometry. imported parts may already be baked
            if incremental_static_release_enabled(self) and part._static_geo_untracked~=true
                and self:_release_static_part_geometry(part) then retired=true
            else mark_parts_dirty(self) end
        end
        part._workspace_geometry_retired=retired and true or nil
        if self._transform_dirty_parts then self._transform_dirty_parts[part._id]=nil end
        if self._dirty_instance_rows then self._dirty_instance_rows[part]=nil end
        self:_invalidate_dynamic_visible_cache()
    else
        part._workspace_geometry_retired=nil
        if self._refresh_physics_part_registration then self:_refresh_physics_part_registration(part) end
        if previous==false then
            self:_restore_parked_dynamic_scene_chunk_for_part(part)
            if part._loaded_from_map~=true and can_update_runtime_part_incrementally(self,part) then
                -- a newly published moving part already qualifies for an
                -- independently owned chunk. retain that ownership through
                -- departure/Destroy, including before its first drawn frame
                self:_retain_dynamic_part_geometry(part)
                if part._prepared_dynamic_geometry_while_stored==true then
                    self:_mark_runtime_part_transform_dirty(part)
                end
            elseif part._retained_dynamic_geometry or can_update_runtime_part_incrementally(self,part) then
                self:_mark_runtime_part_transform_dirty(part)
            else
                mark_parts_dirty(self)
            end
        end
    end
end

-- Unload only independently owned moving-part meshes. static mega batches,
-- shared textures, constraints, instances and simulation state stay intact
-- Re-entry uses current properties/pose, never a saved copy of the old part
function RBX:_update_dynamic_render_residency()
    local radius = self.dynamic_render_distance or 0
    local pending = self._render_streamed_parts
    if radius <= 0 and not pending then return end
    local camera = self.camera and self.camera.cframe
    if not camera then return end
    pending = pending or {}
    self._render_streamed_parts = pending
    local function distance_squared(part)
        local b = self:_get_part_render_bounds(part)
        local x = math.max(b.min_x - camera.x, 0, camera.x - b.max_x)
        local y = math.max(b.min_y - camera.y, 0, camera.y - b.max_y)
        local z = math.max(b.min_z - camera.z, 0, camera.z - b.max_z)
        return x*x + y*y + z*z
    end
    for id, part in pairs(pending) do
        if part._destroyed or not can_update_runtime_part_incrementally(self, part) then
            pending[id], part._render_streamed_out = nil, nil
        elseif radius <= 0 or distance_squared(part) <= radius*radius then
            pending[id], part._render_streamed_out = nil, nil
            self._transform_dirty_parts = self._transform_dirty_parts or {}
            self._transform_dirty_parts[id] = part
            if not self._parts_dirty then self._parts_dirty_mode = "transform" end
            self._parts_dirty = true
        end
    end
    if radius > 0 then
        local unload = radius + (self.dynamic_render_hysteresis or 32)
        local chunks = self._scene_dynamic_chunks or {}
        for i = #chunks, 1, -1 do
            local part = chunks[i].dynamic_part
            if part and not part._destroyed and distance_squared(part) > unload*unload then
                pending[part._id], part._render_streamed_out = part, true
                self:_remove_dynamic_scene_chunk_for_part(part)
            end
        end
    end
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    self._render_streamed_part_count = count
end

-- end-of-sync: fold every range source into _static_part_geo[pid] = {mesh,first,count} triples
function RBX:_index_static_part_ranges(chunk_list)
    local geo = {}
    self._static_part_geo = geo

    local function absorb(pid, mesh, first, count)
        if pid == nil or not mesh or count <= 0 then
            return
        end
        local slot = geo[pid]
        if not slot then
            slot = {}
            geo[pid] = slot
        end
        slot[#slot + 1] = mesh
        slot[#slot + 1] = first
        slot[#slot + 1] = count
    end

    local function absorb_item(item)
        local ranges = item and item.part_ranges
        local mesh = item and item.mesh
        if not ranges or not mesh then
            return
        end
        for i = 1, #ranges, 3 do
            absorb(ranges[i], mesh, ranges[i + 1], ranges[i + 2])
        end
    end

    local function absorb_item_list(items)
        if not items then
            return
        end
        for i = 1, #items do
            absorb_item(items[i])
        end
    end

    absorb_item_list(self._mega_textured_batches)
    absorb_item_list(self._mega_overlay_textured_batches)

    local mega_instance_mesh = self._mega_instance_mesh

    for index = 1, #(chunk_list or {}) do
        local chunk = chunk_list[index]
        if chunk and chunk.dynamic_chunk ~= true then
            absorb_item_list(chunk.textured_batches)
            absorb_item_list(chunk.overlay_textured_batches)
            absorb_item_list(chunk.transparent_draw_items)
            local ids = chunk.cube_instance_part_ids
            if ids then
                local chunk_instance_mesh = chunk.instance_mesh
                local mega_base = chunk._mega_cube_row_base
                for row, pid in pairs(ids) do
                    if chunk_instance_mesh then
                        absorb(pid, chunk_instance_mesh, row, 1)
                    end
                    if mega_instance_mesh and mega_base then
                        absorb(pid, mega_instance_mesh, mega_base + row, 1)
                    end
                end
            end
        end
    end

    local stage = self._range_static_stage
    if stage then
        for i = 1, #stage, 4 do
            absorb(stage[i], stage[i + 1], stage[i + 2], stage[i + 3])
        end
        self._range_static_stage = nil
    end
end

-- sub-pixel move since last bake skips the chunk rebuild (jittering assemblies would re-bake
-- every frame), pos in studs, rot in matrix delta (0.0017 ~= 0.1deg)
local DYNAMIC_POSE_SKIP_POS_EPS = 0.02
local DYNAMIC_POSE_SKIP_ROT_EPS = 0.0017

-- raw reads: __index on 9 fields/part/frame was the hottest row of transform sync
local function dynamic_part_render_pose_changed(part)
    local cf = part.CFrame
    if type(cf) ~= "table" then return true end
    local lb = part._last_baked_render_pose
    if not lb then return true end
    -- appearance writes bump revision w/o moving pose, mustnt be pose-skipped
    if (part._render_prop_revision or 0) ~= (lb[10] or 0) then
        return true
    end
    local x, y, z, r00, r11, r22, r01, r12, r20
    x = rawget(cf, "_x")
    if x ~= nil then
        y, z = rawget(cf, "_y"), rawget(cf, "_z")
        r00, r11, r22 = rawget(cf, "_r00"), rawget(cf, "_r11"), rawget(cf, "_r22")
        r01, r12, r20 = rawget(cf, "_r01"), rawget(cf, "_r12"), rawget(cf, "_r20")
    else
        x, y, z = cf.x or 0, cf.y or 0, cf.z or 0
        r00, r11, r22 = cf.r00 or 1, cf.r11 or 1, cf.r22 or 1
        r01, r12, r20 = cf.r01 or 0, cf.r12 or 0, cf.r20 or 0
    end
    local pe = DYNAMIC_POSE_SKIP_POS_EPS
    if math.abs(x - lb[1]) >= pe
        or math.abs(y - lb[2]) >= pe
        or math.abs(z - lb[3]) >= pe then
        return true
    end
    local re = DYNAMIC_POSE_SKIP_ROT_EPS
    return math.abs(r00 - lb[4]) >= re
        or math.abs(r11 - lb[5]) >= re
        or math.abs(r22 - lb[6]) >= re
        or math.abs(r01 - lb[7]) >= re
        or math.abs(r12 - lb[8]) >= re
        or math.abs(r20 - lb[9]) >= re
end

local function record_dynamic_part_render_pose(part)
    local cf = part.CFrame
    if type(cf) ~= "table" then return end
    local lb = part._last_baked_render_pose
    if not lb then lb = {}; part._last_baked_render_pose = lb end
    lb[10] = part._render_prop_revision or 0
    local x = rawget(cf, "_x")
    if x ~= nil then
        lb[1], lb[2], lb[3] = x, rawget(cf, "_y"), rawget(cf, "_z")
        lb[4], lb[5], lb[6] = rawget(cf, "_r00"), rawget(cf, "_r11"), rawget(cf, "_r22")
        lb[7], lb[8], lb[9] = rawget(cf, "_r01"), rawget(cf, "_r12"), rawget(cf, "_r20")
    else
        lb[1], lb[2], lb[3] = cf.x or 0, cf.y or 0, cf.z or 0
        lb[4], lb[5], lb[6] = cf.r00 or 1, cf.r11 or 1, cf.r22 or 1
        lb[7], lb[8], lb[9] = cf.r01 or 0, cf.r12 or 0, cf.r20 or 0
    end
end

-- billboards render via their own quad path, so they dont block this
local function invisible_part_renders_nothing(part)
    local face_textures = part.FaceTextures
    if face_textures and #face_textures > 0 then
        return false
    end
    local surface_guis = part.SurfaceGuis
    if surface_guis and #surface_guis > 0 then
        return false
    end
    if not RBX._is_empty_asset_reference(part.TextureContent)
        or not RBX._is_empty_asset_reference(part.TextureId) then
        return false
    end
    return true
end

local function update_scene_chunk_part_content(
        renderer, chunk, part, part_index, record_part_chunk_key, allow_stored)
    if type(part) ~= "table" or part._destroyed
        or (part._workspace_active==false and allow_stored~=true) then
        return
    end

    local part_bounds = renderer:_get_part_render_bounds(part)
    finalize_bounds(part_bounds)
    expand_bounds_with_bounds(chunk.bounds, part_bounds)

    local part_width = math.max(0.001, part_bounds.max_x - part_bounds.min_x)
    local part_height = math.max(0.001, part_bounds.max_y - part_bounds.min_y)
    local part_depth = math.max(0.001, part_bounds.max_z - part_bounds.min_z)

    local surface_route =
        RBX._classify_part_full_material_route(part, renderer)
    local alpha = surface_route and surface_route.part_alpha
        or get_runtime_render_alpha(part)
    -- emit no geometry, else every Transparency=1 hitbox rebuilds a GPU mesh + zero-alpha
    -- draw every frame. bounds already expanded above
    if alpha <= 0 and invisible_part_renders_nothing(part) then
        return
    end
    local is_transparent = surface_route and surface_route.blend
        or (surface_route == nil and alpha < 0.999)
    local is_glass_part = surface_route == nil and is_glass_material(part)
    local render_geometry_key = get_runtime_part_render_geometry_key(part)
    local is_block_shape = render_geometry_key == "Block"
    local part_center_x = (part_bounds.min_x + part_bounds.max_x) * 0.5
    local part_center_y = (part_bounds.min_y + part_bounds.max_y) * 0.5
    local part_center_z = (part_bounds.min_z + part_bounds.max_z) * 0.5
    local part_volume = math.max(0.001, part_width * part_height * part_depth)
    local allow_dynamic_overlays = true

    local part_textured_batch_map = is_transparent and {} or chunk.opaque_textured_batch_map
    local material_batch_map = part_textured_batch_map
    local transparent_uses_chunk_textured_map = false
    local allow_block_fallback = not is_csg_part_class(part.ClassName)
        and not special_mesh_submits_no_render_geometry(part)
        and not legacy_mesh_asset_owns_geometry(part)

    local mesh_rendered = false
    if RBX._part_has_renderable_mesh_source(part) then
        mesh_rendered = renderer:_append_mesh_part_batch(part_textured_batch_map, part)
    end
    if is_csg_part_class(part.ClassName) and not mesh_rendered then
        allow_block_fallback = true
    end

    local material_rendered = false
    local material_batch_key = nil
    local has_part_texture = not RBX._is_empty_asset_reference(part.TextureContent)
        or not RBX._is_empty_asset_reference(part.TextureId)
    if is_transparent and not mesh_rendered then
        chunk.transparent_textured_batch_map = chunk.transparent_textured_batch_map or {}
        part_textured_batch_map = chunk.transparent_textured_batch_map
        material_batch_map = chunk.transparent_textured_batch_map
        transparent_uses_chunk_textured_map = true
    end
    if allow_dynamic_overlays and allow_block_fallback and not mesh_rendered and not has_part_texture then
        material_rendered, material_batch_key =
            renderer:_append_part_material_batch(material_batch_map, part,
                chunk.dynamic_chunk == true and is_transparent and part.MeshOwner == nil)
    end
    -- same gate as static build: no studs/inlets if a mesh replaced geo or a DataModelMesh child exists
    if allow_dynamic_overlays and allow_block_fallback and is_block_shape
        and not mesh_rendered and part.MeshOwner == nil then
        renderer:_append_surface_detail_geometry_batch(material_batch_map, part)
    end


    if not is_transparent and allow_block_fallback and not mesh_rendered and not material_rendered then
        local instance = runtime_part_to_instance(part)
        local instance_handedness =
            RBX._classify_closed_primitive_instance_row(instance)
        local cube_fast_path = is_block_shape
            and instance_handedness == "positive"
        if cube_fast_path then
            chunk.cube_instances[#chunk.cube_instances + 1] = instance
        else
            local batch_key = RBX._closed_primitive_batch_key(
                render_geometry_key, instance_handedness)
            local bucket = chunk.opaque_static_shape_instances[batch_key]
            if not bucket then
                bucket = {}
                chunk.opaque_static_shape_instances[batch_key] = bucket
            end
            bucket[#bucket + 1] = instance
        end
    end

    if is_transparent then
        chunk.transparent_part_count = chunk.transparent_part_count + 1
        if allow_dynamic_overlays and mesh_rendered then
            renderer:_append_mesh_face_decals(part_textured_batch_map, part)
        elseif allow_dynamic_overlays and renderer:_append_surface_primitive_face_decals(part_textured_batch_map, part) then
        elseif allow_dynamic_overlays and allow_block_fallback then
            renderer:_append_part_face_decals(part_textured_batch_map, part)
        end

        if alpha > 0
            and allow_block_fallback
            and not mesh_rendered
            and not material_rendered then
            local source_vertices = renderer._primitive_vertices and renderer._primitive_vertices[render_geometry_key] or
                renderer._cube_vertices
            local mesh = build_static_mesh(renderer, { runtime_part_to_instance(part) }, source_vertices)
            if mesh then
                local depth_bias, depth_compare = RBX._get_transparent_draw_depth_settings(renderer, {
                    render_priority = 0,
                    bounds = part_bounds,
                    thin_surface = math.min(part_width, part_height, part_depth) <=
                        math.max(0.08, math.max(part_width, part_height, part_depth) * 0.08),
                })
                chunk.transparent_draw_items[#chunk.transparent_draw_items + 1] = {
                    kind = "static",
                    mesh = mesh,
                    depth_bias = depth_bias,
                    depth_compare = depth_compare,
                    sort_x = part_center_x,
                    sort_y = part_center_y,
                    sort_z = part_center_z,
                    sort_id = part._id or part_index,
                    render_priority = 0,
                    bounds = part_bounds,
                    source_part_id = part._id or part_index,
                    source_transparent_part = true,
                    is_glass_part = is_glass_part,
                }
            end
        end

        if not transparent_uses_chunk_textured_map then
            local part_batches = renderer:_build_textured_batches_from_map(
                part_textured_batch_map, nil, nil, chunk.dynamic_chunk==true, false,
                chunk.dynamic_chunk == true and 'dynamic' or 'static')
            for batch_index = 1, #part_batches do
                local batch = part_batches[batch_index]
                local depth_bias, depth_compare = RBX._get_transparent_draw_depth_settings(renderer, batch)
                chunk.transparent_draw_items[#chunk.transparent_draw_items + 1] = {
                kind = "textured",
                mesh = batch.mesh,
                cpu_vertices = batch.cpu_vertices,
                vertex_count = batch.vertex_count,
                texture = batch.texture,
                key = batch.key,
                uniform_state_key =
                    RBX._transparent_textured_uniform_state_key(
                        batch.uniform_state_key or batch.key,
                        depth_bias,
                        depth_compare),
                flip_v = batch.flip_v,
                flip_u = batch.flip_u,
                use_material_maps = batch.use_material_maps,
                material_semantics_active =
                    batch.material_semantics_active == true,
                material_surface = batch.material_surface,
                material_map_mask = batch.material_map_mask,
                use_textured_lighting = batch.use_textured_lighting,
                light_influence = batch.light_influence,
                brightness = batch.brightness,
                use_normal_map = batch.use_normal_map,
                normal_texture = batch.normal_texture,
                detail_normal_texture = batch.detail_normal_texture,
                detail_normal_mix = batch.detail_normal_mix,
                detail_contrast = batch.detail_contrast,
                texture_color_mix = batch.texture_color_mix,
                texture_premultiplied =
                    batch.texture_premultiplied == true,
                vertex_color_premultiplied =
                    batch.vertex_color_premultiplied == true,
                roughness_texture = batch.roughness_texture,
                metalness_texture = batch.metalness_texture,
                depth_bias = depth_bias,
                ignore_texture_alpha = batch.ignore_texture_alpha and true or false,
                cull_mode = batch.cull_mode or "none",
                mirror_cull_swap = batch.mirror_cull_swap ~= false,
                force_cull = batch.force_cull == true,
                resolved_cull_mode = batch.resolved_cull_mode,
                depth_compare = depth_compare,
                sort_x = batch.sort_x or part_center_x,
                sort_y = batch.sort_y or part_center_y,
                sort_z = batch.sort_z or part_center_z,
                sort_id = part._id or part_index,
                render_priority = batch.render_priority or 0,
                bounds = batch.bounds or part_bounds,
                source_part_id = part._id or part_index,
                source_transparent_part = true,
                is_glass_part = is_glass_part,
                dynamic_chunk = chunk.dynamic_chunk == true,
                shader_variant_id = batch.shader_variant_id or "textured_transparent",
                uniform_layout_id = batch.uniform_layout_id or "fast",
                shader = batch.shader,
                shader_counter_key = batch.shader_counter_key,
                variant_counter_id = batch.variant_counter_id,
                mesh_debug_mode = batch.mesh_debug_mode,
                mesh_debug_mode_id = batch.mesh_debug_mode_id,
                alpha_like = true,
                uses_shader_discard = batch.uses_shader_discard == true,
                source_kind = batch.source_kind,
                overlay_pass = batch.overlay_pass == true,
                surface_gui_ref = batch.surface_gui_ref,
                surface_gui_part_ref = batch.surface_gui_part_ref,
                surface_gui_z_offset = batch.surface_gui_z_offset,
                surface_gui_order = batch.surface_gui_order,
                surface_gui_face = batch.surface_gui_face,
                surface_gui_runtime_id = batch.surface_gui_runtime_id,
                surface_gui_max_distance = batch.surface_gui_max_distance,
                surface_gui_face_world_x = batch.surface_gui_face_world_x,
                surface_gui_face_world_y = batch.surface_gui_face_world_y,
                surface_gui_face_world_z = batch.surface_gui_face_world_z,
                surface_gui_face_normal_x = batch.surface_gui_face_normal_x,
                surface_gui_face_normal_y = batch.surface_gui_face_normal_y,
                surface_gui_face_normal_z = batch.surface_gui_face_normal_z,
                mesh_part_count = batch.mesh_part_count or 0,
                mesh_texture_hit_count = batch.mesh_texture_hit_count or 0,
                mesh_texture_miss_count = batch.mesh_texture_miss_count or 0,
                mesh_uv_missing_count = batch.mesh_uv_missing_count or 0,
                mesh_doublesided_count = batch.mesh_doublesided_count or 0,
                mesh_axis_conversion_count = batch.mesh_axis_conversion_count or 0,
                mesh_winding_flip_count = batch.mesh_winding_flip_count or 0,
                mesh_uv_flip_u_count = batch.mesh_uv_flip_u_count or 0,
                mesh_uv_flip_v_count = batch.mesh_uv_flip_v_count or 0,
                mesh_debug_axis_count = batch.mesh_debug_axis_count or 0,
                mesh_debug_bounds_count = batch.mesh_debug_bounds_count or 0,
                union_part_count = batch.union_part_count or 0,
                union_material_part_count = batch.union_material_part_count or 0,
                union_use_part_color_count = batch.union_use_part_color_count or 0,
                union_smoothing_angle_used_count = batch.union_smoothing_angle_used_count or 0,
                union_fallback_count = batch.union_fallback_count or 0,
                surface_detail_face_count = batch.surface_detail_face_count or 0,
                surface_studs_face_count = batch.surface_studs_face_count or 0,
                surface_inlet_face_count = batch.surface_inlet_face_count or 0,
                surface_universal_face_count = batch.surface_universal_face_count or 0,
                surface_shader_face_count = batch.surface_shader_face_count or 0,
                surface_geometry_face_count = batch.surface_geometry_face_count or 0,
                surface_lod_geometry_count = batch.surface_lod_geometry_count or 0,
                surface_lod_shader_count = batch.surface_lod_shader_count or 0,
                surface_fallback_count = batch.surface_fallback_count or 0,
                z_bias_overlay_count = batch.z_bias_overlay_count or 0,
                z_bias_decal_count = batch.z_bias_decal_count or 0,
                z_bias_surface_detail_count = batch.z_bias_surface_detail_count or 0,
                specialmesh_count = batch.specialmesh_count or 0,
                specialmesh_head_count = batch.specialmesh_head_count or 0,
                specialmesh_axis_fixup_count = batch.specialmesh_axis_fixup_count or 0,
                specialmesh_fallback_count = batch.specialmesh_fallback_count or 0,
                }
                local draw_item = chunk.transparent_draw_items[
                    #chunk.transparent_draw_items]
                draw_item.texture_group_key = batch.texture_group_key
                draw_item.normal_key = batch.normal_key
                draw_item.detail_normal_key = batch.detail_normal_key
                draw_item.remote_texture_handle = batch.remote_texture_handle
                draw_item.remote_normal_texture_handle =
                    batch.remote_normal_texture_handle
                draw_item.remote_normal_texture_field =
                    batch.remote_normal_texture_field
                RBX._copy_surface_appearance_fields(draw_item, batch)
                renderer:_bind_copied_textured_item_remote_consumers(draw_item)
            end
        end
    else
        chunk.opaque_part_count = chunk.opaque_part_count + 1
        if not surface_route
            or surface_route.route ~= "opaque_cutout" then
            chunk.opaque_volume = chunk.opaque_volume + part_volume
            chunk.opaque_face_area_xy = chunk.opaque_face_area_xy + (part_width * part_height)
            chunk.opaque_face_area_xz = chunk.opaque_face_area_xz + (part_width * part_depth)
            chunk.opaque_face_area_yz = chunk.opaque_face_area_yz + (part_height * part_depth)
            add_chunk_occluder_candidate(
                renderer,
                chunk,
                part,
                part_bounds,
                part_width,
                part_height,
                part_depth,
                render_geometry_key,
                allow_block_fallback,
                mesh_rendered,
                has_part_texture
            )
        end
        if allow_dynamic_overlays and mesh_rendered then
            renderer:_append_mesh_face_decals(chunk.overlay_textured_batch_map, part)
        elseif allow_dynamic_overlays and renderer:_append_surface_primitive_face_decals(chunk.overlay_textured_batch_map, part) then
        elseif allow_dynamic_overlays and allow_block_fallback then
            renderer:_append_part_face_decals(
                chunk.overlay_textured_batch_map,
                part,
                nil,
                nil,
                chunk.opaque_textured_batch_map
            )
        end
    end

    -- derived settled aggregates are draw substitutes, never authoritative
    -- geometry owners. a cancelled background build must not redirect later
    -- release/occlusion bookkeeping away from the raw one-part chunk
    if record_part_chunk_key ~= false then
        part._scene_chunk_key = chunk.key
    end
end

local function finalize_scene_chunk(renderer, chunk, reuse_chunk)
    local reuse_primitives = nil
    if reuse_chunk and reuse_chunk.opaque_static_draw_items then
        reuse_primitives = {}
        for index = 1, #reuse_chunk.opaque_static_draw_items do
            local item = reuse_chunk.opaque_static_draw_items[index]
            if item and item.key ~= nil then
                reuse_primitives[item.key] = item
            end
        end
    end
    for batch_key, instances in pairs(chunk.opaque_static_shape_instances) do
        if #instances > 0 then
            local shape_name =
                RBX._closed_primitive_shape_name_from_batch_key(batch_key)
            local shape_part_ids = chunk.opaque_static_shape_instance_part_ids
                and chunk.opaque_static_shape_instance_part_ids[batch_key] or nil
            local item = renderer:_build_opaque_primitive_draw_item(
                shape_name,
                instances,
                shape_part_ids,
                {
                    allow_instancing = true,
                    dynamic_chunk = chunk.dynamic_chunk == true,
                    bounds = chunk.bounds,
                    track_ranges = chunk.dynamic_chunk ~= true,
                    reuse_item = reuse_primitives
                        and reuse_primitives[batch_key] or nil,
                    batch_key = batch_key,
                })
            if item then
                -- Opaque packet ordering uses the owning spatial chunk as a
                -- deterministic tie-break. keeping it on the item also lets
                -- static local-light clusters concatenate rows in exactly the
                -- order used by the unclustered draw list
                item._scene_chunk_key = chunk.key
                item._scene_chunk_grid_x = chunk.grid_x
                item._scene_chunk_grid_y = chunk.grid_y
                item._scene_chunk_grid_z = chunk.grid_z
                chunk.opaque_static_draw_items[
                    #chunk.opaque_static_draw_items + 1] = item
            end
        end
    end

    table.sort(chunk.opaque_static_draw_items, function(a, b)
        return tostring(a.key) < tostring(b.key)
    end)

    append_chunk_transparent_textured_draw_items(renderer, chunk)
    -- reuse prev frame's gpu meshes (same asset/vertex count) so a move updates in place, no re-alloc
    local reuse_opaque, reuse_overlay
    if reuse_chunk then
        reuse_opaque = {}
        local prev_op = reuse_chunk.textured_batches
        if prev_op then for i = 1, #prev_op do reuse_opaque[prev_op[i].key] = prev_op[i] end end
        reuse_overlay = {}
        local prev_ov = reuse_chunk.overlay_textured_batches
        if prev_ov then for i = 1, #prev_ov do reuse_overlay[prev_ov[i].key] = prev_ov[i] end end
    end
    -- keep cpu vertex tables on single-part dynamic chunks: _fast_rebake_dynamic_chunk snapshots them
    -- to ffi so later moves are rigid re-transform+upload. static/merged-settle chunks never capture
    local capture_cpu = chunk.dynamic_chunk == true and chunk.dynamic_part ~= nil
    chunk.textured_batches = renderer:_build_textured_batches_from_map(
        chunk.opaque_textured_batch_map, reuse_opaque, nil, capture_cpu,
        chunk.dynamic_chunk ~= true,
        chunk.dynamic_chunk == true and 'dynamic' or 'static')
    chunk.overlay_textured_batches = renderer:_build_textured_batches_from_map(
        chunk.overlay_textured_batch_map, reuse_overlay, nil, capture_cpu,
        chunk.dynamic_chunk ~= true,
        chunk.dynamic_chunk == true and 'dynamic' or 'static')
    if chunk.dynamic_chunk == true then
        for index = 1, #chunk.textured_batches do
            chunk.textured_batches[index].dynamic_chunk = true
        end
        for index = 1, #chunk.overlay_textured_batches do
            chunk.overlay_textured_batches[index].dynamic_chunk = true
        end
    end
    chunk.has_opaque_geometry = (#chunk.cube_instances > 0)
        or (#chunk.opaque_static_draw_items > 0)
        or (#chunk.textured_batches > 0)
    chunk.has_transparent_geometry = #chunk.transparent_draw_items > 0
    chunk.bounds = finalize_bounds(chunk.bounds)
    chunk.occlusion_fill_ratio = aggregate_occlusion_fill_ratio(
        chunk.bounds,
        chunk.opaque_volume,
        chunk.opaque_face_area_xy,
        chunk.opaque_face_area_xz,
        chunk.opaque_face_area_yz
    )

    chunk.opaque_static_shape_instances = nil
    chunk.opaque_textured_batch_map = nil
    chunk.overlay_textured_batch_map = nil
    chunk.transparent_textured_batch_map = nil
    chunk.opaque_face_area_xy = nil
    chunk.opaque_face_area_xz = nil
    chunk.opaque_face_area_yz = nil
end

function RBX:_get_or_create_part_scene_chunk(chunk_map, part, center_x, center_y, center_z, allow_stored)
    if can_update_runtime_part_incrementally(self, part, allow_stored) then
        local key = get_dynamic_scene_chunk_key(part)
        local chunk = chunk_map[key]
        if chunk then
            return chunk
        end
        local grid_x, grid_y, grid_z = get_spatial_chunk_coords(self.visibility_cell_size, center_x, center_y, center_z)
        chunk = self:_create_scene_chunk(key, grid_x, grid_y, grid_z)
        chunk.dynamic_chunk = true
        chunk.dynamic_part_id = part._id
        chunk.dynamic_part = part -- back-ref for the settled-dynamic merge
        chunk_map[key] = chunk
        return chunk
    end
    return self:_get_or_create_scene_chunk(chunk_map, center_x, center_y, center_z)
end

local MERGED_TEXTURED_BATCH_COUNT_FIELDS = {
    mesh_part_count = true,
    mesh_texture_hit_count = true,
    mesh_texture_miss_count = true,
    mesh_uv_missing_count = true,
    mesh_doublesided_count = true,
    mesh_axis_conversion_count = true,
    mesh_winding_flip_count = true,
    mesh_uv_flip_u_count = true,
    mesh_uv_flip_v_count = true,
    mesh_debug_axis_count = true,
    mesh_debug_bounds_count = true,
    union_part_count = true,
    union_material_part_count = true,
    union_use_part_color_count = true,
    union_smoothing_angle_used_count = true,
    union_fallback_count = true,
    surface_detail_face_count = true,
    surface_studs_face_count = true,
    surface_inlet_face_count = true,
    surface_universal_face_count = true,
    surface_shader_face_count = true,
    surface_geometry_face_count = true,
    surface_lod_geometry_count = true,
    surface_lod_shader_count = true,
    surface_fallback_count = true,
    z_bias_overlay_count = true,
    z_bias_decal_count = true,
    z_bias_surface_detail_count = true,
    specialmesh_count = true,
    specialmesh_head_count = true,
    specialmesh_axis_fixup_count = true,
    specialmesh_fallback_count = true,
}

local function merge_opaque_textured_batch_map(target, source)
    if type(target) ~= "table" or type(source) ~= "table" then
        return
    end

    for key, batch in pairs(source) do
        local vertices = batch and batch.vertices or nil
        if batch and batch.source_kind ~= "SurfaceGui" and rbx_vertex_list_count(vertices) > 0 then
            local merged = target[key]
            if not merged then
                merged = {}
                for field, value in pairs(batch) do
                    if field ~= "vertices"
                        and field ~= "bounds"
                        and field ~= "part_ranges" -- per-source-batch, translated copies appended below
                        and field ~= "_sort_sum_x"
                        and field ~= "_sort_sum_y"
                        and field ~= "_sort_sum_z"
                        and field ~= "_sort_count"
                        and not MERGED_TEXTURED_BATCH_COUNT_FIELDS[field] then
                        merged[field] = value
                    end
                end
                -- match the source representation, mode is constant within one build
                merged.vertices = vertices.vbuf ~= nil and rbx_create_flat_vertex_list() or {}
                target[key] = merged
            end

            local out_vertices = merged.vertices
            local merge_base
            if vertices.vbuf ~= nil then
                merge_base = rbx_vertex_list_count(out_vertices)
                rbx_flat_vertex_list_append(out_vertices, vertices)
            else
                merge_base = #out_vertices
                for index = 1, #vertices do
                    out_vertices[#out_vertices + 1] = vertices[index]
                end
            end
            -- translate per-part ranges into merged vertex array (incremental release)
            local source_ranges = batch.part_ranges
            if source_ranges then
                local merged_ranges = merged.part_ranges
                if not merged_ranges then
                    merged_ranges = {}
                    merged.part_ranges = merged_ranges
                end
                for index = 1, #source_ranges, 3 do
                    merged_ranges[#merged_ranges + 1] = source_ranges[index]
                    merged_ranges[#merged_ranges + 1] = source_ranges[index + 1] + merge_base
                    merged_ranges[#merged_ranges + 1] = source_ranges[index + 2]
                end
            end

            if batch.bounds then
                merged.bounds = merged.bounds or {
                    min_x = math.huge,
                    min_y = math.huge,
                    min_z = math.huge,
                    max_x = -math.huge,
                    max_y = -math.huge,
                    max_z = -math.huge,
                }
                expand_bounds_with_bounds(merged.bounds, batch.bounds)
            end
            merged._sort_sum_x = (merged._sort_sum_x or 0) + (batch._sort_sum_x or 0)
            merged._sort_sum_y = (merged._sort_sum_y or 0) + (batch._sort_sum_y or 0)
            merged._sort_sum_z = (merged._sort_sum_z or 0) + (batch._sort_sum_z or 0)
            merged._sort_count = (merged._sort_count or 0) + (batch._sort_count or 0)
            for field in pairs(MERGED_TEXTURED_BATCH_COUNT_FIELDS) do
                merged[field] = (tonumber(merged[field]) or 0) + (tonumber(batch[field]) or 0)
            end
        end
    end
end

local function batch_map_has_drawable_batches(batch_map)
    if type(batch_map) ~= "table" then
        return false
    end
    for _, batch in pairs(batch_map) do
        if rbx_vertex_list_count(batch and batch.vertices) > 0 then
            return true
        end
    end
    return false
end

RBX.STATIC_TEXTURED_SPATIAL_PAGE_MAX_SOURCE_ROWS = 65535

-- Spatial pages are only an ownership/layout change when Menori can own the
-- immutable payload.  keeping the capability check here makes the option
-- default-on without changing the proven LOVE/legacy-mega fallback on systems
-- that cannot satisfy the exact-static contract
function RBX:_static_textured_spatial_page_mode_status()
    if self.enable_static_textured_spatial_pages == false then
        return false, "disabled"
    end
    if self.enable_static_textured_indexing == false then
        return false, "static_textured_indexing_disabled"
    end
    if self.render_backend_name ~= "menori" then
        return false, "not_menori"
    end
    if type(self._get_static_textured_index_capability) ~= "function" then
        return false, "capability_probe_unavailable"
    end
    local capability = self:_get_static_textured_index_capability()
    if type(capability) ~= "table" or capability.enabled ~= true then
        return false, type(capability) == "table"
            and (capability.reason or "capability_unavailable")
            or "capability_unavailable"
    end
    return true, nil
end

-- Predict the draw amplification before allocating either layout.  a page is
-- one (cell, pass, state) source, the legacy comparison is one (pass, state)
-- source.  this is deliberately conservative because an overview camera can
-- see every cell, where page-local culling cannot repay hundreds of extra draw
-- submissions.  the force option exists for profiler/pixel A/B runs
function RBX:_static_textured_spatial_page_layout_is_safe(chunk_list)
    local unique_base = {}
    local unique_overlay = {}
    local page_count = 0
    local unique_count = 0

    local function scan_map(batch_map, unique)
        for key, batch in pairs(batch_map or {}) do
            if batch and batch.source_kind ~= "SurfaceGui"
                and rbx_vertex_list_count(batch.vertices) > 0 then
                page_count = page_count + 1
                if unique[key] ~= true then
                    unique[key] = true
                    unique_count = unique_count + 1
                end
            end
        end
    end

    for index = 1, #(chunk_list or {}) do
        local chunk = chunk_list[index]
        if chunk and chunk.dynamic_chunk ~= true then
            scan_map(chunk.opaque_textured_batch_map, unique_base)
            scan_map(chunk.overlay_textured_batch_map, unique_overlay)
        end
    end

    local amplification = unique_count > 0
        and (page_count / unique_count) or 1
    local max_pages = math.max(
        1,
        math.floor(tonumber(
            self.static_textured_spatial_page_max_batches) or 256))
    local max_amplification = math.max(
        1,
        tonumber(
            self.static_textured_spatial_page_max_draw_amplification) or 2)
    local forced = self.force_static_textured_spatial_pages == true
    local safe = forced or (
        page_count <= max_pages
        and amplification <= max_amplification)
    local reason
    if not safe then
        if page_count > max_pages then
            reason = "page_batch_budget"
        else
            reason = "draw_amplification_budget"
        end
    end
    return safe, reason, {
        candidate_page_count = page_count,
        legacy_state_batch_count = unique_count,
        draw_amplification = amplification,
        max_page_count = max_pages,
        max_draw_amplification = max_amplification,
        forced = forced,
    }
end

-- build one independently-owned resource for every state source in one
-- visibility cell.  a failure is contained to that state/page: later pages and
-- other cells still build, and no page aliases a scene-wide mega resource
--
-- Source rows above the uint16-aligned ceiling deliberately retain a
-- cell-bounded flat upload.  Splitting the FFI buffer would otherwise require
-- copying or retaining overlapping per-part ranges, the bounded fallback is
-- exact, isolated to one visibility cell, and observable in the stats below
function RBX:_build_static_textured_spatial_pages_for_chunk(chunk, stats)
    stats = stats or {}
    local page_count_before = tonumber(stats.page_count) or 0

    local function build_pass(batch_map, destination, pass_name)
        local keys = {}
        for key, batch in pairs(batch_map or {}) do
            if batch and rbx_vertex_list_count(batch.vertices) > 0 then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys, function(left, right)
            return tostring(left) < tostring(right)
        end)

        for key_index = 1, #keys do
            local key = keys[key_index]
            local batch = batch_map[key]
            local source_rows = rbx_vertex_list_count(batch.vertices)
            local is_spatial_page = batch.source_kind ~= "SurfaceGui"
            if is_spatial_page then
                stats.source_batch_count =
                    (stats.source_batch_count or 0) + 1
                stats.max_source_rows = math.max(
                    tonumber(stats.max_source_rows) or 0, source_rows)
            else
                stats.compatibility_batch_count =
                    (stats.compatibility_batch_count or 0) + 1
            end

            local oversized = is_spatial_page and source_rows
                > RBX.STATIC_TEXTURED_SPATIAL_PAGE_MAX_SOURCE_ROWS
            if oversized then
                stats.cell_bounded_flat_fallback_page_count =
                    (stats.cell_bounded_flat_fallback_page_count or 0) + 1
            end

            local singleton = { [key] = batch }
            local ok, items_or_error = pcall(
                self._build_textured_batches_from_map,
                self,
                singleton,
                nil,
                nil,
                nil,
                is_spatial_page)
            if not ok or type(items_or_error) ~= "table" then
                stats.failure_count = (stats.failure_count or 0) + 1
                stats.failed_pages = stats.failed_pages or {}
                if #stats.failed_pages < 16 then
                    stats.failed_pages[#stats.failed_pages + 1] = {
                        chunk_key = chunk and chunk.key,
                        pass = pass_name,
                        key = tostring(key),
                        error = tostring(items_or_error),
                    }
                end
                if self._note_render_backend_error then
                    self:_note_render_backend_error(
                        "build static textured spatial page", items_or_error)
                end
            elseif #items_or_error == 0 then
                -- Unsafe finite-data rejection intentionally suppresses the
                -- source item. count it independently from an exception
                stats.suppressed_page_count =
                    (stats.suppressed_page_count or 0) + 1
            else
                for item_index = 1, #items_or_error do
                    local item = items_or_error[item_index]
                    if type(item) == "table" then
                        if is_spatial_page then
                            item._static_textured_spatial_page = true
                            item._static_textured_spatial_page_pass = pass_name
                            item._static_textured_spatial_page_ordinal =
                                (stats.page_count or 0) + 1
                            item._static_textured_spatial_page_source_rows =
                                source_rows
                            item._static_textured_spatial_page_flat_fallback =
                                oversized or nil
                        end
                        item._scene_chunk_key = chunk and chunk.key
                        item._scene_chunk_grid_x = chunk and chunk.grid_x
                        item._scene_chunk_grid_y = chunk and chunk.grid_y
                        item._scene_chunk_grid_z = chunk and chunk.grid_z
                        destination[#destination + 1] = item
                        if is_spatial_page then
                            stats.page_count = (stats.page_count or 0) + 1
                            if pass_name == "overlay" then
                                stats.overlay_page_count =
                                    (stats.overlay_page_count or 0) + 1
                            else
                                stats.base_page_count =
                                    (stats.base_page_count or 0) + 1
                            end
                            if item._static_resource_batch then
                                stats.menori_owned_page_count =
                                    (stats.menori_owned_page_count or 0) + 1
                            else
                                stats.raw_flat_page_count =
                                    (stats.raw_flat_page_count or 0) + 1
                            end
                        end
                    end
                end
            end
        end
    end

    local base_pages = {}
    local overlay_pages = {}
    build_pass(chunk and chunk.opaque_textured_batch_map,
        base_pages, "base")
    build_pass(chunk and chunk.overlay_textured_batch_map,
        overlay_pages, "overlay")
    if (tonumber(stats.page_count) or 0) > page_count_before then
        stats.chunk_count = (stats.chunk_count or 0) + 1
    end
    return base_pages, overlay_pages, stats
end

function RBX:_rebuild_scene_chunk_caches()
    local chunk_list = self._scene_chunks or {}
    table.sort(chunk_list, function(a, b)
        return tostring(a.key) < tostring(b.key)
    end)

    self:_build_chunk_cube_draws(chunk_list)

    local bvh_chunks = {}
    local static_chunks = {}
    local dynamic_chunks = {}
    local scene_bounds = {
        min_x = math.huge,
        min_y = math.huge,
        min_z = math.huge,
        max_x = -math.huge,
        max_y = -math.huge,
        max_z = -math.huge,
    }
    local total_cube_instances = 0
    local opaque_static_batch_count = 0
    local textured_batch_count = 0
    local transparent_draw_count = 0

    for index = 1, #chunk_list do
        local chunk = chunk_list[index]
        if chunk and chunk.bounds then
            expand_bounds_with_bounds(scene_bounds, chunk.bounds)
        end
        if chunk and chunk.dynamic_chunk == true then
            dynamic_chunks[#dynamic_chunks + 1] = chunk
        else
            static_chunks[#static_chunks + 1] = chunk
            bvh_chunks[#bvh_chunks + 1] = chunk
        end
        total_cube_instances = total_cube_instances + #(chunk and chunk.cube_instances or {})
        opaque_static_batch_count = opaque_static_batch_count + #(chunk and chunk.opaque_static_draw_items or {})
        textured_batch_count = textured_batch_count
            + #(chunk and chunk.textured_batches or {})
            + #(chunk and chunk.overlay_textured_batches or {})
        transparent_draw_count = transparent_draw_count + #(chunk and chunk.transparent_draw_items or {})
    end

    self._scene_chunk_bvh = build_scene_chunk_bvh(bvh_chunks)
    self._scene_static_chunks = static_chunks
    self._scene_dynamic_chunks = dynamic_chunks
    self:_build_dynamic_mega_cube_draw(dynamic_chunks)
    self.instance_count = total_cube_instances
    self._opaque_static_batch_count = opaque_static_batch_count
    self._textured_batch_count = textured_batch_count
    self._transparent_draw_count = transparent_draw_count
    self._scene_bounds = scene_bounds.min_x < math.huge and finalize_bounds(scene_bounds) or nil
    self._mega_textured_batches = nil
    self._mega_overlay_textured_batches = nil
    self._visible_opaque_chunks = {}
    self._visible_transparent_draw_items = {}
    self._visible_textured_batches = {}
    self._visible_overlay_textured_batches = {}
    self._visible_surface_gui_batches = {}
    self._visible_static_draw_items = {}
    self._scene_revision = (self._scene_revision or 0) + 1
    self._static_scene_revision = (self._static_scene_revision or 0) + 1
    self._visible_scene_cache_state = self._visible_scene_cache_state or {}
    self._visible_scene_cache_state.scene_revision = nil
    self._transparent_sort_cache_state = self._transparent_sort_cache_state or {}
    self._transparent_sort_cache_state.items = nil
end

-- pure textured chunks retain one immutable reference pose and a GPU rigid
-- transform. Property/scale changes still rebuild this one owned chunk
function RBX:_capture_dynamic_chunk_fast_bake(chunk, part)
    chunk._fast_bake = nil
    require('engine/graphics/rbx/runtime/retained_primitive_decal').release(self,chunk)
    if require('engine/graphics/rbx/runtime/retained_primitive_decal').capture(self,chunk,part,rbx_snapshot_item_vertices) then return end
    local gpu_pose = self.retain_rigid_chunk_transforms ~= false
    if not gpu_pose and type(rbx_snapshot_item_vertices) ~= "function" then
        return
    end
    -- one cube instance can ride along w/ textured snapshots (RotateV axle = cube row + surface
    -- detail), its row is rewritten in place, only on the instanced dynamic-mega path
    local cube_count = chunk.cube_instances and #chunk.cube_instances or 0
    if cube_count > 1
        or (cube_count == 1 and not (self.use_instancing and self.dynamic_mega_dynamic_cubes ~= false))
        or (chunk.opaque_static_draw_items and #chunk.opaque_static_draw_items > 0) then
        return
    end
    local snapshots = {}
    local function absorb(list)
        for i = 1, #(list or {}) do
            local item = list[i]
            if not item or not item.mesh then
                return false
            end
            local snapshot = gpu_pose and {count=item.mesh:getVertexCount()}
                or rbx_snapshot_item_vertices(item)
            if not snapshot then
                return false
            end
            snapshot.mesh = item.mesh
            snapshot.item = item
            item.rigid_pose=nil
            snapshot.sort_x,snapshot.sort_y,snapshot.sort_z=item.sort_x,item.sort_y,item.sort_z
            if item.source_kind == "SurfaceGui" then
                snapshot.gui_x, snapshot.gui_y, snapshot.gui_z = item.surface_gui_face_world_x,
                    item.surface_gui_face_world_y, item.surface_gui_face_world_z
                snapshot.gui_nx, snapshot.gui_ny, snapshot.gui_nz = item.surface_gui_face_normal_x,
                    item.surface_gui_face_normal_y, item.surface_gui_face_normal_z
            end
            -- Bounds follow the same immutable baked-pose -> current-pose
            -- delta as the vertex snapshot. copy values rather than retaining
            -- the live AABB, which changes on every rigid update
            if item.bounds then
                snapshot.item = item
                snapshot.base_min_x, snapshot.base_max_x = item.bounds.min_x, item.bounds.max_x
                snapshot.base_min_y, snapshot.base_max_y = item.bounds.min_y, item.bounds.max_y
                snapshot.base_min_z, snapshot.base_max_z = item.bounds.min_z, item.bounds.max_z
            end
            snapshots[#snapshots + 1] = snapshot
            -- ffi snapshot supersedes lua vertex tables, releasing ~halves per-part memory
            item.cpu_vertices = nil
        end
        return true
    end
    -- Transparent textured items use the identical 20-float vertex layout
    -- a retained GPU pose can also move static primitive items without touching
    -- their world-space vertex buffer, their static shader receives the same
    -- rigid delta. CPU rebaking still rejects those items because their compact
    -- vertex format is not compatible with the textured snapshot layout
    for _,item in ipairs(chunk.transparent_draw_items or {}) do
        if item.kind ~= 'textured' and (item.kind ~= 'static' or not gpu_pose) then
            return
        end
    end
    if not absorb(chunk.textured_batches) or not absorb(chunk.overlay_textured_batches)
        or not absorb(chunk.transparent_draw_items) then
        return
    end
    if #snapshots == 0 then
        -- pure-cube (or empty) chunks are _capture_dynamic_chunk_cube_fast's job
        return
    end
    local px, py, pz,
    rx, ry, rz,
    ux, uy, uz,
    bx, by, bz = get_runtime_part_render_basis(part)
    local bounds = chunk.bounds or {}
    chunk._fast_bake = {
        part = part,
        prop_revision = part._render_prop_revision or 0,
        snapshots = snapshots,
        cube_row = cube_count == 1 and chunk.cube_instances[1] or nil,
        base_px = px, base_py = py, base_pz = pz,
        base_rx = rx, base_ry = ry, base_rz = rz,
        base_ux = ux, base_uy = uy, base_uz = uz,
        base_bx = bx, base_by = by, base_bz = bz,
        base_min_x = bounds.min_x, base_min_y = bounds.min_y, base_min_z = bounds.min_z,
        base_max_x = bounds.max_x, base_max_y = bounds.max_y, base_max_z = bounds.max_z,
    }
    -- a retained face-array item has one immutable mesh and sampler array
    -- capture it only when there is exactly one direct descriptor/item pair;
    -- all shared, remote, auxiliary and membership cases retain full rebuilds
    local face_array_binding, face_array_invalid = nil, false
    for index = 1, #snapshots do
        local item = snapshots[index].item
        local descriptor = item and item._face_array_binding_descriptor
        if descriptor ~= nil then
            if type(descriptor) ~= "table" or face_array_binding ~= nil
                or item.remote_texture_handle ~= nil
                or item.remote_normal_texture_handle ~= nil
                or item.face_array_texture == nil
                or type(item.face_array_layer) ~= "number"
                or type(item.face_array_set_key) ~= "string"
                or type(item.face_array_entry) ~= "table"
                or not item.mesh then
                face_array_invalid = true
                break
            end
            face_array_binding = {
                descriptor = descriptor,
                item = item,
                entry = item.face_array_entry,
                part = part,
                revision = part._face_texture_array_revision or 0,
            }
        end
    end
    local direct_faces = part.FaceTextures
    if not face_array_invalid and face_array_binding
        and type(direct_faces) == "table" and #direct_faces == 1
        and direct_faces[1] == face_array_binding.descriptor then
        chunk._fast_bake.face_array_binding = face_array_binding
    end
    if gpu_pose then
        local pose={rows={{1,0,0,0},{0,1,0,0},{0,0,1,0}},revision=0}
        chunk._fast_bake.gpu_pose=pose
        for i=1,#snapshots do snapshots[i].item.rigid_pose=pose end
        local mesh_cache=part._mesh_xf_cache
        local transform=mesh_cache and mesh_cache.transform
        -- FileMesh UVs are asset-owned. Generated material/face/GUI layers,
        -- primitive-parent scale rules and mixed cube packets still rebake
        local scale_rule=transform and transform.special_mesh_transform_rule
        local affine=transform and (scale_rule=='asset_scale'
            or (scale_rule==nil and part.ClassName=='MeshPart' and part.MeshOwner~='SpecialMesh'))
            and cube_count==0 and #(chunk.overlay_textured_batches or {})==0
        for i=1,#snapshots do
            local item=snapshots[i].item
            if item.source_kind=='SurfaceGui' or (item.surface_geometry_face_count or 0)>0
                or (item.surface_shader_face_count or 0)>0 or item.legacy_textured==false then affine=false end
        end
        if affine and math.abs(transform.scale_x)>1e-9 and math.abs(transform.scale_y)>1e-9
            and math.abs(transform.scale_z)>1e-9 then
            local base={}
            for key,value in pairs(transform) do if type(value)~='table' then base[key]=value end end
            chunk._fast_bake.affine_base=base
            chunk._fast_bake.affine_mesh=mesh_cache.mesh_data
            chunk._fast_bake.affine_revision=part._render_affine_revision or 0
        end
    end
    -- guard animation sources publish a strict opaque/hidden swap among four
    -- standalone FileMeshes. preserve only that already-GPU-posed, one-packet
    -- representation, faces, SurfaceGuis, primitives, partial alpha, local
    -- transparency and all ordinary MeshParts retain the existing fallback
    local retained_fast = chunk._fast_bake
    local surface_guis = part.SurfaceGuis
    if part._retain_animation_visibility_packet == true
        and retained_fast and retained_fast.gpu_pose
        and part.ClassName == "MeshPart"
        and part.Transparency == 0
        and (tonumber(part.LocalTransparencyModifier) or 0) == 0
        and get_runtime_render_alpha(part) >= 0.999
        and #snapshots == 1
        and #(chunk.cube_instances or {}) == 0
        and #(chunk.opaque_static_draw_items or {}) == 0
        and #(chunk.textured_batches or {}) == 1
        and #(chunk.overlay_textured_batches or {}) == 0
        and #(chunk.transparent_draw_items or {}) == 0
        and (not direct_faces or #direct_faces == 0)
        and (not surface_guis or #surface_guis == 0)
        and snapshots[1].item and snapshots[1].item.source_kind ~= "SurfaceGui" then
        retained_fast.animation_visibility_packet = true
        retained_fast.animation_visibility_revision =
            part._retained_animation_visibility_revision or 0
        chunk._animation_visibility_hidden = false
    end
end

-- moved single-part chunk: re-transform snapshot by rigid delta (baked pose vs current), upload
-- via bytedata, move bounds. false = caller falls back to full re-bake
function RBX:_fast_rebake_dynamic_chunk(chunk, part)
    if chunk and chunk._fast_decal then
        return require('engine/graphics/rbx/runtime/retained_primitive_decal').update(self,chunk,part)
    end
    local fast = chunk and chunk._fast_bake
    if not fast or fast.part ~= part or part._destroyed then
        return false
    end
    local prop_revision = part._render_prop_revision or 0
    if prop_revision ~= fast.prop_revision then
        local binding = fast.face_array_binding
        local layer_revision = part._face_texture_array_revision or 0
        local prop_delta = prop_revision - fast.prop_revision
        local layer_delta = binding and layer_revision
            - (binding.revision or 0) or -1
        local visibility_revision = part._retained_animation_visibility_revision or 0
        local visibility_delta = visibility_revision
            - (fast.animation_visibility_revision or 0)
        local transparency = tonumber(part.Transparency)
        local hidden = chunk._animation_visibility_hidden == true
        local animation_visibility_transition = fast.animation_visibility_packet == true
            and prop_delta == 1 and prop_delta == visibility_delta
            and (tonumber(part.LocalTransparencyModifier) or 0) == 0
            and (transparency == 0 or transparency == 1)
            and ((transparency == 1) ~= hidden)
        if animation_visibility_transition then
            fast.prop_revision = prop_revision
            fast.animation_visibility_revision = visibility_revision
            chunk._animation_visibility_hidden = transparency == 1
        elseif binding and prop_delta > 0 and prop_delta == layer_delta
            and part._face_texture_array_descriptor == binding.descriptor
            and require('engine/graphics/rbx/runtime/retained_face_array')
                .update_layer(self, binding) then
            fast.prop_revision = prop_revision
            binding.revision = layer_revision
        elseif not fast.affine_base or prop_delta
            ~= (part._render_affine_revision or 0) - fast.affine_revision then
            chunk._fast_bake = nil
            return false
        end
    end

    local px, py, pz,
    rx, ry, rz,
    ux, uy, uz,
    bx, by, bz,
    sx, sy, sz = get_runtime_part_render_basis(part)

    -- ride-along cube: rewrite pose slots in place, mega repack reads the mutated row, 16+ pose-independent
    local cube_row = fast.cube_row
    if cube_row then
        if chunk.cube_instances and chunk.cube_instances[1] == cube_row then
            chunk._cube_pose_dirty = true
            cube_row[1], cube_row[2], cube_row[3] = px, py, pz
            cube_row[4], cube_row[5], cube_row[6] = rx, ry, rz
            cube_row[7], cube_row[8], cube_row[9] = ux, uy, uz
            cube_row[10], cube_row[11], cube_row[12] = bx, by, bz
            cube_row[13], cube_row[14], cube_row[15] = sx, sy, sz
        else
            chunk._fast_bake = nil
            return false
        end
    end

    -- delta = C_current * C_baked^T, bases are pure rotations, scale is baked into the snapshot
    local m00 = rx * fast.base_rx + ux * fast.base_ux + bx * fast.base_bx
    local m01 = rx * fast.base_ry + ux * fast.base_uy + bx * fast.base_by
    local m02 = rx * fast.base_rz + ux * fast.base_uz + bx * fast.base_bz
    local m10 = ry * fast.base_rx + uy * fast.base_ux + by * fast.base_bx
    local m11 = ry * fast.base_ry + uy * fast.base_uy + by * fast.base_by
    local m12 = ry * fast.base_rz + uy * fast.base_uz + by * fast.base_bz
    local m20 = rz * fast.base_rx + uz * fast.base_ux + bz * fast.base_bx
    local m21 = rz * fast.base_ry + uz * fast.base_uy + bz * fast.base_by
    local m22 = rz * fast.base_rz + uz * fast.base_uz + bz * fast.base_bz
    local tx = px - (m00 * fast.base_px + m01 * fast.base_py + m02 * fast.base_pz)
    local ty = py - (m10 * fast.base_px + m11 * fast.base_py + m12 * fast.base_pz)
    local tz = pz - (m20 * fast.base_px + m21 * fast.base_py + m22 * fast.base_pz)

    local base=fast.affine_base
    if base and (part._render_affine_revision or 0)~=fast.affine_revision then
        local current=self:_get_mesh_render_transform(part,fast.affine_mesh)
        -- Crossing a zero/sign boundary can change culling and mirrored UV
        -- policy. rebuild at that boundary rather than blessing old coverage
        if not current or math.abs(current.scale_x)<=1e-9 or math.abs(current.scale_y)<=1e-9
            or math.abs(current.scale_z)<=1e-9 or current.cull_swap~=base.cull_swap
            or current.uv_mirror_u~=base.uv_mirror_u or current.uv_mirror_v~=base.uv_mirror_v then
            chunk._fast_bake=nil;return false
        end
        local x,y,z=current.scale_x/base.scale_x,current.scale_y/base.scale_y,current.scale_z/base.scale_z
        m00=current.rx*x*base.rx+current.ux*y*base.ux+current.bx*z*base.bx
        m01=current.rx*x*base.ry+current.ux*y*base.uy+current.bx*z*base.by
        m02=current.rx*x*base.rz+current.ux*y*base.uz+current.bx*z*base.bz
        m10=current.ry*x*base.rx+current.uy*y*base.ux+current.by*z*base.bx
        m11=current.ry*x*base.ry+current.uy*y*base.uy+current.by*z*base.by
        m12=current.ry*x*base.rz+current.uy*y*base.uz+current.by*z*base.bz
        m20=current.rz*x*base.rx+current.uz*y*base.ux+current.bz*z*base.bx
        m21=current.rz*x*base.ry+current.uz*y*base.uy+current.bz*z*base.by
        m22=current.rz*x*base.rz+current.uz*y*base.uz+current.bz*z*base.bz
        tx=current.px-(m00*base.px+m01*base.py+m02*base.pz)
        ty=current.py-(m10*base.px+m11*base.py+m12*base.pz)
        tz=current.pz-(m20*base.px+m21*base.py+m22*base.pz)
        fast.gpu_pose.affine=true
        self._affine_chunk_pose_update_count=(self._affine_chunk_pose_update_count or 0)+1
    end

    local pose=fast.gpu_pose
    if pose then
        local a,b,c=pose.rows[1],pose.rows[2],pose.rows[3]
        a[1],a[2],a[3],a[4]=m00,m01,m02,tx
        b[1],b[2],b[3],b[4]=m10,m11,m12,ty
        c[1],c[2],c[3],c[4]=m20,m21,m22,tz
        pose.revision=pose.revision+1
        self._rigid_chunk_pose_update_count=(self._rigid_chunk_pose_update_count or 0)+1
    end

    local snapshots = fast.snapshots
    local shadow_array_vertices = not pose and require('engine/graphics/rbx/runtime/shadow_array')
    for i = 1, #snapshots do
        local snapshot = snapshots[i]
        if not pose then
            rbx_fast_bake_apply(snapshot,
                m00, m01, m02, m10, m11, m12, m20, m21, m22, tx, ty, tz)
            if snapshot.item.mesh_texture_layer then
                -- packed uv and color values stay fixed when the part rotates
                for vertex = 0, snapshot.count - 1 do
                    local offset = vertex * 20
                    for field = 13, 18 do
                        snapshot.dst[offset + field] = snapshot.src[offset + field]
                    end
                end
            end
            if self._static_mesh_unit_alpha then self._static_mesh_unit_alpha[snapshot.mesh] = nil end
            shadow_array_vertices.invalidate(snapshot.mesh)
            local ok = pcall(snapshot.mesh.setVertices, snapshot.mesh, snapshot.dst_data)
            if not ok then
                chunk._fast_bake = nil
                return false
            end
            if self._note_gpu_upload_bytes then self:_note_gpu_upload_bytes(snapshot.count*80) end
        end
        if snapshot.sort_x~=nil then
            local item=snapshot.item;local x,y,z=snapshot.sort_x,snapshot.sort_y,snapshot.sort_z
            item.sort_x=m00*x+m01*y+m02*z+tx
            item.sort_y=m10*x+m11*y+m12*z+ty
            item.sort_z=m20*x+m21*y+m22*z+tz
        end
        -- SurfaceGui visibility uses a world-space face plane as well as its
        -- vertices. Carry both through the same rigid transform, otherwise a
        -- rotating face keeps the old backface/distance test and disappears
        if snapshot.gui_x ~= nil then
            local item = snapshot.item
            local x, y, z = snapshot.gui_x, snapshot.gui_y, snapshot.gui_z
            item.surface_gui_face_world_x = m00*x + m01*y + m02*z + tx
            item.surface_gui_face_world_y = m10*x + m11*y + m12*z + ty
            item.surface_gui_face_world_z = m20*x + m21*y + m22*z + tz
            x, y, z = snapshot.gui_nx, snapshot.gui_ny, snapshot.gui_nz
            item.surface_gui_face_normal_x = m00*x + m01*y + m02*z
            item.surface_gui_face_normal_y = m10*x + m11*y + m12*z
            item.surface_gui_face_normal_z = m20*x + m21*y + m22*z
        end
        if snapshot.item and snapshot.base_min_x ~= nil then
            local bounds = snapshot.item.bounds
            local cx = (snapshot.base_min_x + snapshot.base_max_x) * 0.5
            local cy = (snapshot.base_min_y + snapshot.base_max_y) * 0.5
            local cz = (snapshot.base_min_z + snapshot.base_max_z) * 0.5
            local ex = (snapshot.base_max_x - snapshot.base_min_x) * 0.5
            local ey = (snapshot.base_max_y - snapshot.base_min_y) * 0.5
            local ez = (snapshot.base_max_z - snapshot.base_min_z) * 0.5
            local wx = m00 * cx + m01 * cy + m02 * cz + tx
            local wy = m10 * cx + m11 * cy + m12 * cz + ty
            local wz = m20 * cx + m21 * cy + m22 * cz + tz
            local hx = math.abs(m00) * ex + math.abs(m01) * ey + math.abs(m02) * ez
            local hy = math.abs(m10) * ex + math.abs(m11) * ey + math.abs(m12) * ez
            local hz = math.abs(m20) * ex + math.abs(m21) * ey + math.abs(m22) * ez
            -- exact transformed AABB of the original conservative box, with
            -- no vertex walk/allocation or cumulative rotation growth. the
            -- existing light-pack cache compares these six values in place
            bounds.min_x, bounds.max_x = wx - hx, wx + hx
            bounds.min_y, bounds.max_y = wy - hy, wy + hy
            bounds.min_z, bounds.max_z = wz - hz, wz + hz
            finalize_bounds(bounds)
        end
    end

    -- move aabb rigidly: transform 8 baked corners, take min/max
    local bounds = chunk.bounds or {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
    for corner = 0, 7 do
        local cx = (corner % 2 == 0) and fast.base_min_x or fast.base_max_x
        local cy = (math.floor(corner / 2) % 2 == 0) and fast.base_min_y or fast.base_max_y
        local cz = (math.floor(corner / 4) % 2 == 0) and fast.base_min_z or fast.base_max_z
        local wx = m00 * cx + m01 * cy + m02 * cz + tx
        local wy = m10 * cx + m11 * cy + m12 * cz + ty
        local wz = m20 * cx + m21 * cy + m22 * cz + tz
        if wx < min_x then min_x = wx end
        if wy < min_y then min_y = wy end
        if wz < min_z then min_z = wz end
        if wx > max_x then max_x = wx end
        if wy > max_y then max_y = wy end
        if wz > max_z then max_z = wz end
    end
    bounds.min_x, bounds.min_y, bounds.min_z = min_x, min_y, min_z
    bounds.max_x, bounds.max_y, bounds.max_z = max_x, max_y, max_z
    chunk.bounds = finalize_bounds(bounds)
    chunk._settled_content_revision =
        (chunk._settled_content_revision or 0) + 1
    self._fast_rebake_count = (self._fast_rebake_count or 0) + 1
    return true
end

-- cube-row fast path: single-cube chunk (plain moving Part) rewrites its 24-slot instance row in
-- place, mega cube repack picks it up free. instanced dynamic-mega path only, any property write
-- bumps _render_prop_revision and falls back to full rebuild
function RBX:_capture_dynamic_chunk_cube_fast(chunk, part)
    chunk._cube_fast = nil
    local cube_count = chunk.cube_instances and #chunk.cube_instances or 0
    if cube_count > 1 then
        return
    end
    if cube_count == 1 and not (self.use_instancing and self.dynamic_mega_dynamic_cubes ~= false) then
        return
    end
    if (chunk.opaque_static_draw_items and #chunk.opaque_static_draw_items > 0)
        or (chunk.transparent_draw_items and #chunk.transparent_draw_items > 0)
        or (chunk.textured_batches and #chunk.textured_batches > 0)
        or (chunk.overlay_textured_batches and #chunk.overlay_textured_batches > 0)
        or (chunk.surface_gui_batches and #chunk.surface_gui_batches > 0) then
        return
    end
    local shape_buckets = chunk.opaque_static_shape_instances
    if shape_buckets and next(shape_buckets) ~= nil then
        return
    end
    local transparent_buckets = chunk.transparent_static_shape_instances
    if transparent_buckets and next(transparent_buckets) ~= nil then
        return
    end
    -- empty=true = fully-invisible hitbox chunk (zero geo after alpha-0 skip), its move is bounds-only
    chunk._cube_fast = {
        part = part,
        prop_revision = part._render_prop_revision or 0,
        empty = cube_count == 0,
    }
end

function RBX:_fast_recube_dynamic_chunk(chunk, part)
    local fast = chunk and chunk._cube_fast
    if not fast or fast.part ~= part or part._destroyed then
        return false
    end
    if (part._render_prop_revision or 0) ~= fast.prop_revision then
        chunk._cube_fast = nil
        return false
    end
    local instance
    if not fast.empty then
        if not (self.use_instancing and self.dynamic_mega_dynamic_cubes ~= false) then
            return false
        end
        instance = chunk.cube_instances and chunk.cube_instances[1]
        if not instance then
            chunk._cube_fast = nil
            return false
        end
    end

    local px, py, pz,
    right_x, right_y, right_z,
    up_x, up_y, up_z,
    back_x, back_y, back_z,
    sx, sy, sz = get_runtime_part_render_basis(part)
    if instance then
        chunk._cube_pose_dirty = true
        instance[1], instance[2], instance[3] = px, py, pz
        instance[4], instance[5], instance[6] = right_x, right_y, right_z
        instance[7], instance[8], instance[9] = up_x, up_y, up_z
        instance[10], instance[11], instance[12] = back_x, back_y, back_z
        instance[13], instance[14], instance[15] = sx, sy, sz
        chunk.closed_primitive_handedness =
            RBX._classify_closed_primitive_instance_row(instance)
        chunk.closed_primitive_batch_key =
            RBX._closed_primitive_batch_key(
                "Block", chunk.closed_primitive_handedness)
        -- slots 16-24 (color/alpha/reflectance/contact-ao) are pose-independent, writing them
        -- bumps prop revision and takes the rebuild path
    end

    -- world aabb of oriented box, from basis columns
    local abs = math.abs
    local hx, hy, hz = abs(sx) * 0.5, abs(sy) * 0.5, abs(sz) * 0.5
    local ex = abs(right_x) * hx + abs(up_x) * hy + abs(back_x) * hz
    local ey = abs(right_y) * hx + abs(up_y) * hy + abs(back_y) * hz
    local ez = abs(right_z) * hx + abs(up_z) * hy + abs(back_z) * hz
    local bounds = chunk.bounds or {}
    bounds.min_x, bounds.max_x = px - ex, px + ex
    bounds.min_y, bounds.max_y = py - ey, py + ey
    bounds.min_z, bounds.max_z = pz - ez, pz + ez
    chunk.bounds = finalize_bounds(bounds)
    chunk._settled_content_revision =
        (chunk._settled_content_revision or 0) + 1
    self._fast_recube_count = (self._fast_recube_count or 0) + 1
    return true
end

function RBX:_capture_primitive_pose_structure(chunk, part)
    -- a primitive fallback is not an authoritative primitive source. preserve
    -- its resolver/publication route when external or embedded geometry exists
    if RBX._part_has_renderable_mesh_source(part) then return end
    if #chunk.cube_instances ~= 0 or #chunk.textured_batches ~= 0
        or #chunk.overlay_textured_batches ~= 0 or #(chunk.surface_gui_batches or {}) ~= 0 then return end
    local item, route
    if #chunk.opaque_static_draw_items == 1 and #chunk.transparent_draw_items == 0 then
        item = chunk.opaque_static_draw_items[1]
        if item.kind == "instanced_primitive" and item.count == 1 then route = "instance" end
    elseif #chunk.transparent_draw_items == 1 and #chunk.opaque_static_draw_items == 0 then
        item = chunk.transparent_draw_items[1]
        local recipe = item._material_pose_recipe
        if recipe and item.vertex_count == 36 and #recipe.local_inputs == 36
            and rbx_vertex_list_count(recipe.vertices) == 36 then
            local ok, data = pcall(rbx_pack_vertices_bytedata, recipe.vertices, 20)
            recipe.vertices = nil
            if ok and data then
                recipe.data = data
                recipe.floats = require("ffi").cast("float*", data:getFFIPointer())
                route = "material"
            end
        end
    end
    if not route then return end
    chunk._primitive_pose_structure = {
        route = route, prop_revision = part._render_prop_revision or 0,
        texture_revision = self._remote_texture_asset_revision or 0,
        mesh_revision = self._remote_mesh_asset_revision or 0,
        material_depth_bias = self.material_depth_bias,
        use_instancing = self.use_instancing,
        constant_fragment = self.constant_fragment,
        generation = self._instance_generation,
        valid = true,
    }
end

function RBX:_reuse_primitive_pose_structure(chunk, part)
    local state = chunk._primitive_pose_structure
    if not state or not state.valid or chunk.dynamic_part ~= part
        or state.prop_revision ~= (part._render_prop_revision or 0)
        or state.texture_revision ~= (self._remote_texture_asset_revision or 0)
        or state.mesh_revision ~= (self._remote_mesh_asset_revision or 0)
        or state.material_depth_bias ~= self.material_depth_bias
        or state.use_instancing ~= self.use_instancing
        or state.constant_fragment ~= self.constant_fragment
        or state.generation ~= self._instance_generation then return false end
    -- a failed/partial write must never claim that the previous pose is valid
    state.valid = false
    local item
    if state.route == "instance" then
        item = chunk.opaque_static_draw_items[1]
        local row = runtime_part_to_instance(part)
        if RBX._classify_closed_primitive_instance_row(row) ~= item.closed_primitive_handedness
            or not self:_update_menori_primitive_batch(item._instance_resource_batch,
                item.shape_name, {row}) then return false end
    else
        item = chunk.transparent_draw_items[1]
        if not self:_update_material_primitive_pose(item, part) then return false end
    end
    local bounds = self:_get_part_render_bounds(part)
    chunk.bounds.min_x, chunk.bounds.min_y, chunk.bounds.min_z = bounds.min_x, bounds.min_y, bounds.min_z
    chunk.bounds.max_x, chunk.bounds.max_y, chunk.bounds.max_z = bounds.max_x, bounds.max_y, bounds.max_z
    finalize_bounds(chunk.bounds)
    local x, y, z = (bounds.min_x + bounds.max_x) * .5,
        (bounds.min_y + bounds.max_y) * .5, (bounds.min_z + bounds.max_z) * .5
    chunk.grid_x, chunk.grid_y, chunk.grid_z = get_spatial_chunk_coords(self.visibility_cell_size, x, y, z)
    if state.route == "instance" then
        local w, h, d = math.max(.001, bounds.max_x-bounds.min_x),
            math.max(.001, bounds.max_y-bounds.min_y), math.max(.001, bounds.max_z-bounds.min_z)
        chunk.opaque_volume = math.max(.001, w*h*d)
        chunk.occlusion_fill_ratio = aggregate_occlusion_fill_ratio(chunk.bounds, chunk.opaque_volume, w*h, w*d, h*d)
        item.bounds = chunk.bounds
        item._scene_chunk_grid_x, item._scene_chunk_grid_y, item._scene_chunk_grid_z = chunk.grid_x, chunk.grid_y, chunk.grid_z
    else
        item.bounds = chunk.bounds
        item.sort_x, item.sort_y, item.sort_z = x, y, z
        local recipe = item._material_pose_recipe
        recipe.depth_input = recipe.depth_input or {}
        recipe.depth_input.bounds = chunk.bounds
        recipe.depth_input.depth_bias = recipe.depth_bias
        local bias, compare = RBX._get_transparent_draw_depth_settings(self, recipe.depth_input)
        if item.depth_bias ~= bias or item.depth_compare ~= compare then
            item.depth_bias, item.depth_compare = bias, compare
            item.uniform_state_key = RBX._transparent_textured_uniform_state_key(recipe.uniform_base, bias, compare)
        end
    end
    chunk._settled_content_revision = (chunk._settled_content_revision or 0) + 1
    state.valid = true
    self._primitive_pose_reuse_count = (self._primitive_pose_reuse_count or 0) + 1
    return true
end

function RBX:_build_dynamic_scene_chunk_for_part(part, part_index, reuse_chunk, allow_stored)
    if not can_update_runtime_part_incrementally(self, part, allow_stored) then
        return nil
    end

    -- the full-build token does not change on a one-part rebuild. Generated
    -- layers contain world-space GUI planes and size-dependent texture tiling
    part._ft_cache, part._ft_cache_token = nil, nil

    local part_bounds = self:_get_part_render_bounds(part)
    local center_x = (part_bounds.min_x + part_bounds.max_x) * 0.5
    local center_y = (part_bounds.min_y + part_bounds.max_y) * 0.5
    local center_z = (part_bounds.min_z + part_bounds.max_z) * 0.5
    local chunk = self:_get_or_create_part_scene_chunk({}, part, center_x, center_y, center_z,
        allow_stored)
    update_scene_chunk_part_content(self, chunk, part, part_index or part._id or 0,
        nil, allow_stored)
    finalize_scene_chunk(self, chunk, reuse_chunk)
    self:_capture_primitive_pose_structure(chunk, part)
    for _, item in ipairs(chunk.transparent_draw_items) do
        if item._material_pose_recipe and not item._material_pose_recipe.data then
            item._material_pose_recipe = nil
        end
    end
    return chunk
end

-- settled-dynamic mesh merge: sleepers fold into one shared texture-grouped chunk (own chunk each
-- = ~110 extra draws @255 parts, static mega would thrash 15k parts). rebuilt only on membership
-- change -> _scene_dynamic_chunks_drawn, gated by dynamic_mesh_merge
function RBX:_invalidate_dynamic_visible_cache()
    self._scene_revision = (self._scene_revision or 0) + 1
    self._dynamic_scene_revision = (self._dynamic_scene_revision or 0) + 1
    if self._visible_scene_cache_state then
        self._visible_scene_cache_state.scene_revision = nil
    end
end

-- Candidate membership must remain steady before any derived upload begins
-- Startup physics settles roughly one assembly/frame, while remote fanout is
-- deliberately sliced, so an ID-only comparison would continuously rebake
local SETTLED_MERGE_STABILITY_FRAMES = 8
-- Eight render frames can fit between two physics ticks at uncapped rates
-- a body briefly sleeping against a mover must not trigger a mesh merge that
-- the very next simulation tick discards. its original mesh remains drawable
local SETTLED_MERGE_SLICE_SECONDS = 0.0015
local SETTLED_MERGE_MAX_GROUP_PARTS = 24
local SETTLED_MERGE_MAX_GROUP_VERTICES = 65536
local SETTLED_MERGE_MAX_GROUP_BATCH_KEYS = 12
local SETTLED_MERGE_MAX_TOTAL_GROUPS = 64
local SETTLED_MERGE_MAX_TOTAL_PARTS = 512
local SETTLED_MERGE_MAX_TOTAL_VERTICES = 1048576
-- Planning runs from the visible-scene update path. keep both the raw scan and
-- the number of materialized candidate records bounded independently of the
-- total dynamic-part population, a popular asynchronously loaded mesh can
-- otherwise turn this into a permanent O(scene) allocator after promotion
local SETTLED_MERGE_MAX_SCAN_CHUNKS = 1024
local SETTLED_MERGE_FAILURE_COOLDOWN_SECONDS = 1

local function settled_member_token_equal(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.kind == b.kind
        and a.part == b.part
        and a.chunk == b.chunk
        and a.chunk_revision == b.chunk_revision
        and a.dirty_revision == b.dirty_revision
        and a.render_revision == b.render_revision
        and a.handle == b.handle
        and a.handle_revision == b.handle_revision
        and a.instance_generation == b.instance_generation
        and a.light_revision == b.light_revision
        and a.light_configuration == b.light_configuration
end

local function settled_merge_members_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local count_a, count_b = 0, 0
    for id, token in pairs(a) do
        count_a = count_a + 1
        if not settled_member_token_equal(token, b[id]) then return false end
    end
    for _ in pairs(b) do count_b = count_b + 1 end
    return count_a == count_b
end

local function settled_chunk_has_surface_gui(chunk)
    for _, list in pairs({
        chunk and chunk.textured_batches,
        chunk and chunk.overlay_textured_batches,
        chunk and chunk.transparent_draw_items,
        chunk and chunk.surface_gui_batches,
    }) do
        for index = 1, #(list or {}) do
            if list[index] and list[index].source_kind == "SurfaceGui" then
                return true
            end
        end
    end
    return false
end

local function settled_record_draw_metrics(renderer, chunk)
    local vertex_count, draw_count, batch_key_count = 0, 0, 0
    local batch_keys = {}
    local shared_pack, shared_payload = nil, nil
    local local_lights_active = renderer.enable_local_lights ~= false
        and (tonumber(renderer.local_light_count) or 0) > 0
    for pass_index, list in ipairs({
        chunk.textured_batches or {},
        chunk.overlay_textured_batches or {},
    }) do
        for index = 1, #list do
            local item = list[index]
            if not item or item.source_kind == "SurfaceGui" then
                return nil, "surface_gui"
            end
            local count = math.max(0, math.floor(
                tonumber(item.vertex_count) or 0))
            if count <= 0 or not item.mesh then
                return nil, "missing_draw_payload"
            end
            vertex_count = vertex_count + count
            draw_count = draw_count + 1
            local key = tostring(pass_index) .. "|"
                .. tostring(item.key or item.uniform_state_key or index)
            if not batch_keys[key] then
                batch_keys[key] = true
                batch_key_count = batch_key_count + 1
            end
            if local_lights_active then
                if type(renderer._get_local_light_pack_for_item) ~= "function"
                    or type(RBX._local_light_pack_payload_key) ~= "function" then
                    return nil, "local_light_pack_unavailable"
                end
                local pack = renderer:_get_local_light_pack_for_item(item)
                local payload = RBX._local_light_pack_payload_key(pack)
                if shared_payload ~= nil and payload ~= shared_payload then
                    return nil, "mixed_local_light_pack"
                end
                shared_pack, shared_payload = pack, payload
            end
        end
    end
    return {
        vertex_count = vertex_count,
        draw_count = draw_count,
        batch_keys = batch_keys,
        batch_key_count = batch_key_count,
        light_pack = shared_pack,
        light_payload = shared_payload or "no_local_lights",
        local_lights_active = local_lights_active,
    }
end

local function settled_remote_candidate(renderer, chunk, part)
    local handle = type(part) == "table"
        and rawget(part, "_remote_mesh_handle") or nil
    local revision = type(handle) == "table"
        and math.max(0, math.floor(tonumber(handle.revision) or 0)) or 0
    local slot = type(handle) == "table"
        and type(handle.consumer_slots) == "table"
        and handle.consumer_slots[part] or nil
    local bind_current = slot ~= nil
        and type(handle.consumers) == "table"
        and handle.consumers[part] ~= nil
        and type(handle.consumer_order) == "table"
        and handle.consumer_order[slot] == part
        and type(handle.consumer_bind_revision) == "table"
        and handle.consumer_bind_revision[slot] ~= nil
    local consumer_result_revision = bind_current
        and type(handle.consumer_result_revision) == "table"
        and (tonumber(handle.consumer_result_revision[slot]) or 0) or 0
    local publication_applied = consumer_result_revision >= revision
        or (tonumber(handle and handle._renderer_fanout_completed_revision)
            or 0) >= revision
    if type(part) ~= "table" or part._destroyed
        or part._appearance_dynamic ~= true
        or part._loaded_from_map ~= true
        or part.Anchored ~= true
        or part._runtime_dynamic == true
        or part._runtime_dynamic_sticky == true
        or part._promoted_dynamic == true
        or part._kinematic_dynamic == true
        or type(handle) ~= "table"
        or handle.ready ~= true or handle.result == nil
        or revision <= 0 or not bind_current or not publication_applied
        or rawget(part, "_remote_mesh_variant_key") ~= handle.variant_key
        or not chunk or chunk.dynamic_part ~= part
        or chunk.dynamic_part_id ~= part._id
        or #(chunk.textured_batches or {}) == 0
        or #(chunk.cube_instances or {}) > 0
        or #(chunk.opaque_static_draw_items or {}) > 0
        or #(chunk.transparent_draw_items or {}) > 0
        or chunk.has_transparent_geometry == true
        or settled_chunk_has_surface_gui(chunk) then
        return nil
    end
    local metrics = settled_record_draw_metrics(renderer, chunk)
    if not metrics then return nil end
    return handle, revision, metrics
end

local function settled_group_accepts(group, record, max_parts,
        max_vertices, max_keys)
    if #group.records >= max_parts
        or group.vertex_count + record.vertex_count > max_vertices then
        return false
    end
    local added = 0
    for key in pairs(record.batch_keys) do
        if not group.batch_keys[key] then added = added + 1 end
    end
    return group.batch_key_count + added <= max_keys
end

local function settled_group_add(group, record)
    group.records[#group.records + 1] = record
    group.vertex_count = group.vertex_count + record.vertex_count
    group.source_draw_count = group.source_draw_count + record.draw_count
    for key in pairs(record.batch_keys) do
        if not group.batch_keys[key] then
            group.batch_keys[key] = true
            group.batch_key_count = group.batch_key_count + 1
        end
    end
end

-- plan settled groups before touching meshes or changing the source chunks
function RBX:_collect_settled_merge_plan(raw)
    raw = raw or self._scene_dynamic_chunks or {}
    local world = self._physics_world
    local p2a = world and world.part_to_assembly
    local max_parts = math.max(2, math.floor(tonumber(
        self.settled_merge_max_group_parts)
        or SETTLED_MERGE_MAX_GROUP_PARTS))
    local max_vertices = math.max(3, math.floor(tonumber(
        self.settled_merge_max_group_vertices)
        or SETTLED_MERGE_MAX_GROUP_VERTICES))
    local max_keys = math.max(1, math.floor(tonumber(
        self.settled_merge_max_group_batch_keys)
        or SETTLED_MERGE_MAX_GROUP_BATCH_KEYS))
    local max_total_groups = math.max(1, math.floor(tonumber(
        self.settled_merge_max_total_groups)
        or SETTLED_MERGE_MAX_TOTAL_GROUPS))
    local max_total_parts = math.max(2, math.floor(tonumber(
        self.settled_merge_max_total_parts)
        or SETTLED_MERGE_MAX_TOTAL_PARTS))
    local max_total_vertices = math.max(3, math.floor(tonumber(
        self.settled_merge_max_total_vertices)
        or SETTLED_MERGE_MAX_TOTAL_VERTICES))
    local max_scan_chunks = math.max(1, math.floor(tonumber(
        self.settled_merge_max_scan_chunks)
        or SETTLED_MERGE_MAX_SCAN_CHUNKS))
    local max_candidate_records = math.max(2, math.floor(tonumber(
        self.settled_merge_max_candidate_records)
        or max_total_parts))

    local records = {}
    local scanned = 0
    local raw_count = #raw
    local scan_limit = math.min(raw_count, max_scan_chunks)
    local scan_start = math.max(1, math.floor(tonumber(
        self._settled_merge_scan_cursor) or 1))
    if scan_start > raw_count then scan_start = 1 end
    for offset = 0, scan_limit - 1 do
        scanned = scanned + 1
        local index = ((scan_start + offset - 1) % raw_count) + 1
        local chunk = raw[index]
        local part = chunk and chunk.dynamic_part
        local id = chunk and chunk.dynamic_part_id
        if part and id ~= nil and chunk.textured_batches
            and #chunk.textured_batches > 0
            and #(chunk.cube_instances or {}) == 0 then
            local kind, handle, handle_revision, metrics
            local asm = p2a and p2a[id]
            local body = asm and asm.body
            if body and not body.is_static and body.sleeping == true
                and (not body._sleep_step
                    or (world.step_index - body._sleep_step) * world.config.fixed_dt >= 0.25) then
                kind = "physics"
                -- Sleep compaction must preserve the exact same top-four light
                -- pack as the authoritative one-part draw. a scene-wide pack
                -- changes shading as soon as more than four lights overlap
                metrics = settled_record_draw_metrics(self, chunk)
            else
                handle, handle_revision, metrics =
                    settled_remote_candidate(self, chunk, part)
                if handle then kind = "remote" end
            end
            if kind and metrics then
                records[#records + 1] = {
                    id = id,
                    part = part,
                    chunk = chunk,
                    chunk_revision =
                        chunk._settled_content_revision or 0,
                    kind = kind,
                    handle = handle,
                    handle_revision = handle_revision or 0,
                    dirty_revision = part._dynamic_dirty_revision or 0,
                    render_revision = part._render_prop_revision or 0,
                    instance_generation = self._instance_generation or 0,
                    light_revision = self._local_light_revision or 0,
                    light_configuration =
                        self._local_light_pack_configuration_signature,
                    vertex_count = metrics.vertex_count,
                    draw_count = metrics.draw_count,
                    batch_keys = metrics.batch_keys,
                    batch_key_count = metrics.batch_key_count,
                    light_pack = metrics.light_pack,
                    light_payload = metrics.light_payload,
                    local_lights_active = metrics.local_lights_active,
                    grid_x = chunk.grid_x or 0,
                    grid_y = chunk.grid_y or 0,
                    grid_z = chunk.grid_z or 0,
                }
                if #records >= max_candidate_records then break end
            end
        end
    end
    self._settled_merge_last_scan_count = scanned
    self._settled_merge_last_candidate_count = #records
    self._settled_merge_last_scan_truncated = scanned < raw_count
    self._settled_merge_max_observed_scan_count = math.max(
        tonumber(self._settled_merge_max_observed_scan_count) or 0, scanned)
    local buckets, bucket_order = {}, {}
    for index = 1, #records do
        local record = records[index]
        if record.vertex_count <= max_vertices then
            local bucket_key
            -- both remote and sleeping physics substitutes remain spatially
            -- bounded. World-spanning physics aggregates defeat frustum and
            -- occlusion culling even when local lighting is disabled
            bucket_key = table.concat({
                record.kind, record.grid_x, record.grid_y, record.grid_z,
                record.light_payload,
            }, "|")
            local bucket = buckets[bucket_key]
            if not bucket then
                bucket = {
                    key = bucket_key,
                    kind = record.kind,
                    groups = {},
                }
                buckets[bucket_key] = bucket
                bucket_order[#bucket_order + 1] = bucket
            end
            local group = bucket.groups[#bucket.groups]
            if not group or not settled_group_accepts(
                    group, record, max_parts, max_vertices, max_keys) then
                group = {
                    key = bucket_key .. "|" .. tostring(#bucket.groups + 1),
                    kind = record.kind,
                    records = {},
                    batch_keys = {},
                    batch_key_count = 0,
                    vertex_count = 0,
                    source_draw_count = 0,
                    grid_x = record.grid_x,
                    grid_y = record.grid_y,
                    grid_z = record.grid_z,
                    light_pack = record.light_pack,
                    light_payload = record.light_payload,
                }
                bucket.groups[#bucket.groups + 1] = group
            end
            settled_group_add(group, record)
        end
    end

    table.sort(bucket_order, function(a, b)
        if (a.kind == "physics") ~= (b.kind == "physics") then
            return a.kind == "physics"
        end
        return a.key < b.key
    end)
    local groups, members, ids = {}, {}, {}
    local accepted_parts, accepted_vertices = 0, 0
    for bucket_index = 1, #bucket_order do
        local bucket_groups = bucket_order[bucket_index].groups
        for group_index = 1, #bucket_groups do
            local group = bucket_groups[group_index]
            local profitable = group.kind == "physics"
                or (#group.records >= 2
                    and group.source_draw_count > group.batch_key_count)
            local fits_total = #groups < max_total_groups
                and accepted_parts + #group.records <= max_total_parts
                and accepted_vertices + group.vertex_count
                    <= max_total_vertices
            if profitable and fits_total then
                groups[#groups + 1] = group
                accepted_parts = accepted_parts + #group.records
                accepted_vertices = accepted_vertices + group.vertex_count
                for record_index = 1, #group.records do
                    local record = group.records[record_index]
                    members[record.id] = record
                    ids[record.id] = true
                end
            end
        end
    end
    table.sort(groups, function(a, b) return a.key < b.key end)

    -- an unprofitable/ineligible prefix must not starve useful chunks later in
    -- the dynamic list forever. Advance only when this bounded window produced
    -- no plan, once a plan exists, hold the exact window stable for token
    -- validation, the stability delay, and atomic commit
    if raw_count <= 0 then
        self._settled_merge_scan_cursor = 1
    elseif #groups == 0 and scanned > 0 then
        local next_cursor = ((scan_start + scanned - 1) % raw_count) + 1
        if next_cursor <= scan_start then
            self._settled_merge_scan_wrap_count =
                (self._settled_merge_scan_wrap_count or 0) + 1
        end
        self._settled_merge_scan_cursor = next_cursor
    else
        self._settled_merge_scan_cursor = scan_start
    end
    return groups, members, ids
end

local function compose_settled_merge_draw_list(renderer, raw)
    local members = renderer._settled_merge_members
    local chunks = renderer._settled_merge_chunks
    if type(members) ~= "table" or type(chunks) ~= "table"
        or #chunks == 0 then
        renderer._scene_dynamic_chunks_drawn = raw
        renderer._settled_merge_part_count = 0
        return
    end
    local draw = renderer._settled_merge_keep_scratch or {}
    renderer._settled_merge_keep_scratch = draw
    for index = #draw, 1, -1 do draw[index] = nil end
    for index = 1, #raw do
        local chunk = raw[index]
        if not (chunk and members[chunk.dynamic_part_id]) then
            draw[#draw + 1] = chunk
        end
    end
    for index = 1, #chunks do draw[#draw + 1] = chunks[index] end
    renderer._scene_dynamic_chunks_drawn = draw
    local count = 0
    for _ in pairs(members) do count = count + 1 end
    renderer._settled_merge_part_count = count
end

local function pin_settled_group_light_pack(renderer, chunk, group, pending)
    if not group.light_pack then return end
    for _, list in pairs({
        chunk.textured_batches,
        chunk.overlay_textured_batches,
    }) do
        for index = 1, #(list or {}) do
            local item = list[index]
            pin_local_light_cluster_pack(
                item, group.light_pack, item.bounds,
                pending.light_revision,
                pending.light_configuration)
        end
    end
end

local function fail_settled_merge_build(renderer, reason, build_error)
    renderer._settled_merge_failure_count =
        (renderer._settled_merge_failure_count or 0) + 1
    renderer._settled_merge_last_error = tostring(
        build_error or reason or "settled_merge_failed")
    renderer._settled_merge_failure_until = love.timer.getTime()
        + SETTLED_MERGE_FAILURE_COOLDOWN_SECONDS
    renderer:_discard_settled_merge_pending(reason, true)
end

function RBX:_apply_settled_dynamic_merge()
    local raw = self._scene_dynamic_chunks or {}
    if self.dynamic_mesh_merge == false then
        self:_discard_settled_merge_generation("disabled", true, true)
        self._scene_dynamic_chunks_drawn = raw
        return
    end
    if #raw == 0 and not self._settled_merge_chunk
        and not self._settled_merge_pending then
        self._settled_merge_last_ids = nil
        self._settled_merge_last_members = nil
        self._settled_merge_stable_frames = 0
        self._scene_dynamic_chunks_drawn = raw
        self._settled_merge_part_count = 0
        return
    end

    local groups, members, ids = self:_collect_settled_merge_plan(raw)
    if next(members) == nil then
        self:_discard_settled_merge_generation("no_candidates", true, true)
        self._scene_dynamic_chunks_drawn = raw
        return
    end

    local committed_current = settled_merge_members_equal(
        members, self._settled_merge_members)
    if self._settled_merge_members and not committed_current then
        self:_discard_settled_merge_committed("membership_changed", true)
        self:_invalidate_dynamic_visible_cache()
    end
    local pending = self._settled_merge_pending
    if pending and not settled_merge_members_equal(
            members, pending.members) then
        self:_discard_settled_merge_pending("pending_membership_changed", true)
        pending = nil
    end

    local same_as_last = settled_merge_members_equal(
        members, self._settled_merge_last_members)
    self._settled_merge_last_members = members
    self._settled_merge_last_ids = ids
    self._settled_merge_stable_frames = same_as_last
        and ((self._settled_merge_stable_frames or 0) + 1) or 0

    if committed_current then
        compose_settled_merge_draw_list(self, raw)
        return
    end
    self._scene_dynamic_chunks_drawn = raw
    self._settled_merge_part_count = 0

    local now = love.timer.getTime()
    if now < (tonumber(self._settled_merge_failure_until) or 0)
        or self._settled_merge_stable_frames
            < SETTLED_MERGE_STABILITY_FRAMES then
        return
    end

    if not pending then
        pending = {
            groups = groups,
            members = members,
            ids = ids,
            chunks = {},
            group_index = 1,
            record_index = 0,
            slice_frames = 0,
            light_revision = self._local_light_revision or 0,
            light_configuration =
                self._local_light_pack_configuration_signature,
        }
        self._settled_merge_pending = pending
        self._settled_merge_restart_count =
            (self._settled_merge_restart_count or 0) + 1
    end

    local slice_started_at = love.timer.getTime()
    local slice_seconds = math.max(0, tonumber(
        self.settled_merge_slice_seconds)
        or SETTLED_MERGE_SLICE_SECONDS)
    pending.slice_frames = pending.slice_frames + 1
    while pending.group_index <= #pending.groups do
        local group = pending.groups[pending.group_index]
        local chunk = pending.current_chunk
        if not chunk then
            local create_ok, create_result = pcall(
                self._create_scene_chunk,
                self,
                "__dynamic_settled_merge:" .. group.key,
                group.grid_x, group.grid_y, group.grid_z)
            if not create_ok or type(create_result) ~= "table" then
                fail_settled_merge_build(
                    self, "group_create_failed", create_result)
                return
            end
            chunk = create_result
            chunk.dynamic_chunk = true
            chunk.settled_merge = true
            chunk.settled_merge_group_key = group.key
            pending.current_chunk = chunk
            group.chunk = chunk
            pending.record_index = 0
        end

        while pending.record_index < #group.records do
            pending.record_index = pending.record_index + 1
            local record = group.records[pending.record_index]
            local current = members[record.id]
            if not settled_member_token_equal(record, current)
                or record.part._destroyed then
                self:_discard_settled_merge_pending(
                    "member_changed_during_build", true)
                return
            end
            local ok, build_error = pcall(
                update_scene_chunk_part_content,
                self, chunk, record.part,
                record.part._id or pending.record_index,
                false)
            if not ok then
                fail_settled_merge_build(
                    self, "part_build_failed", build_error)
                return
            end
            if pending.record_index < #group.records
                and (love.timer.getTime() - slice_started_at)
                    >= slice_seconds then
                return
            end
        end

        local finalize_started_at = love.timer.getTime()
        local ok, finalize_error = pcall(finalize_scene_chunk, self, chunk)
        if not ok then
            fail_settled_merge_build(
                self, "group_finalize_failed", finalize_error)
            return
        end
        pin_settled_group_light_pack(self, chunk, group, pending)
        pending.chunks[#pending.chunks + 1] = chunk
        pending.current_chunk = nil
        group.chunk = nil
        pending.group_index = pending.group_index + 1
        pending.record_index = 0
        pending.last_finalize_ms =
            (love.timer.getTime() - finalize_started_at) * 1000
        -- GPU upload/finalization is not preemptible, hard group caps bound it,
        -- and at most one such upload group is allowed per frame
        break
    end

    if pending.group_index <= #pending.groups then return end
    if not settled_merge_members_equal(members, pending.members) then
        self:_discard_settled_merge_pending("commit_token_mismatch", true)
        return
    end

    local chunks = pending.chunks
    pending.chunks = nil
    pending.groups = nil
    pending.members = nil
    pending.ids = nil
    self._settled_merge_pending = nil
    self:_discard_settled_merge_committed("replacement_commit", true)
    self._settled_merge_chunks = chunks
    self._settled_merge_chunk = chunks[1]
    self._settled_merge_members = members
    self._settled_merge_ids = ids
    self._settled_merge_last_build_frames = pending.slice_frames
    self._settled_merge_last_finalize_ms = pending.last_finalize_ms or 0
    self._settled_merge_commit_count =
        (self._settled_merge_commit_count or 0) + 1
    compose_settled_merge_draw_list(self, raw)
    self:_invalidate_dynamic_visible_cache()
end

function RBX:_build_single_scene_chunk_cube_draw(chunk)
    if type(chunk) ~= "table" then
        return
    end

    -- the CPU rows may already describe a newer accepted render pose. never
    -- bless the individual consumer until its fallible upload has completed
    chunk._cube_pose_dirty = true
    chunk.instance_count = #(chunk.cube_instances or {})
    chunk.closed_primitive_handedness =
        RBX._summarize_closed_primitive_instance_rows(
            chunk.cube_instances)
    chunk.closed_primitive_batch_key = RBX._closed_primitive_batch_key(
        "Block", chunk.closed_primitive_handedness)
    if chunk.instance_count <= 0 then
        self:_release_chunk_cube_meshes(chunk, {}, true)
        self:_assign_chunk_cube_batch(chunk, nil)
        chunk._cube_pose_dirty = nil
        return true
    end

    if self.use_instancing then
        local batch = chunk._cube_instance_batch
        if self.render_backend_name == "menori"
            and self._render_backend and batch and not batch.released then
            local update_ok, update_error = pcall(
                self._render_backend.update_opaque_batch,
                self._render_backend, batch, chunk.cube_instances, chunk.instance_count)
            if update_ok then
                batch.closed_primitive_handedness =
                    chunk.closed_primitive_handedness
                batch.batch_key = chunk.closed_primitive_batch_key
                self:_assign_chunk_cube_batch(chunk, batch)
                chunk.static_cube_mesh = nil
                chunk._cube_pose_dirty = nil
                return true
            end
            self:_note_render_backend_error("update chunk Block batch", update_error)
            self:_release_opaque_cube_batch(batch)
            self:_assign_chunk_cube_batch(chunk, nil)
        end

        local instance_mesh = chunk.instance_mesh
        local draw_mesh = chunk.cube_draw_mesh
        if instance_mesh and draw_mesh and instance_mesh.getVertexCount then
            local count_ok, vertex_count = pcall(instance_mesh.getVertexCount, instance_mesh)
            if count_ok and vertex_count == chunk.instance_count then
                local vertices_ok = pcall(instance_mesh.setVertices, instance_mesh, chunk.cube_instances)
                if vertices_ok then
                    chunk.static_cube_mesh = nil
                    chunk._cube_pose_dirty = nil
                    return true
                end
            end
        end

        if self:_build_chunk_instance_mesh(chunk) then
            chunk._cube_pose_dirty = nil
            return true
        end
    end

    self:_release_chunk_cube_meshes(chunk, {}, true)
    chunk.instance_count = #(chunk.cube_instances or {})
    chunk.static_cube_mesh = build_static_mesh(self, chunk.cube_instances)
    if chunk.static_cube_mesh then
        chunk._cube_pose_dirty = nil
        return true
    end
    return false
end

-- Mega color/shadow consumers use their own current publication. only refresh
-- an individual buffer when a selected consumer needs it (including re-entry
-- or a local-light route change without another pose update)
function RBX:_ensure_dynamic_chunk_cube_pose(chunk)
    if chunk and chunk.dynamic_chunk == true and chunk._cube_pose_dirty then
        assert(self:_build_single_scene_chunk_cube_draw(chunk),
            "dynamic Block pose publication failed")
        self._dynamic_cube_pose_publications =
            (self._dynamic_cube_pose_publications or 0) + 1
    end
end

function RBX:_sync_runtime_part_transforms()
    local sync_started_at = love.timer.getTime()
    local dirty_parts = self._transform_dirty_parts or {}
    local chunk_map = self._scene_chunk_map or {}
    local chunk_list = self._scene_chunks or {}
    local changed = false
    local dirty_count = 0

    local pose_skip_enabled = self.dynamic_render_pose_skip ~= false
    local newly_added_dynamic = nil
    -- per-frame path census, so a profile can tell "38 parts moved" from
    -- "38 parts moved and every one took the slow full-rebuild branch"
    local n_considered, n_skip, n_rebake, n_recube, n_full = 0, 0, 0, 0, 0
    -- branch timing is opt-in (collect_hotspot_stats): it needs a getTime pair per
    -- dirty part, and there are hundreds per frame, so leaving it on would cost more
    -- than some of the branches it measures
    local time_branches = self.collect_hotspot_stats == true
    local t_rebake, t_recube, t_full = 0, 0, 0
    local branch_started_at = 0
    for _, part in pairs(dirty_parts) do
        n_considered = n_considered + 1
        if time_branches then branch_started_at = love.timer.getTime() end
        if can_update_runtime_part_incrementally(self, part) and not part._render_streamed_out then
            -- previous frame's chunk (same key): batch meshes reused in place, avoids per-frame alloc
            local previous_chunk = chunk_map[get_dynamic_scene_chunk_key(part)]
            if pose_skip_enabled and previous_chunk and not dynamic_part_render_pose_changed(part) then
                -- sub-threshold jitter: keep the bake. deliberately doesnt set `changed`, so
                -- all-sub-threshold frames skip re-aggregation + cull invalidation entirely
                self._dynamic_pose_skipped_count = (self._dynamic_pose_skipped_count or 0) + 1
                n_skip = n_skip + 1
            elseif previous_chunk and self:_fast_rebake_dynamic_chunk(previous_chunk, part) then
                -- rigid re-transform in ffi + upload, chunk object unchanged, no map/list surgery
                dirty_count = dirty_count + 1
                n_rebake = n_rebake + 1
                if time_branches then t_rebake = t_rebake + (love.timer.getTime() - branch_started_at) end
                record_dynamic_part_render_pose(part)
                changed = true
            elseif previous_chunk and self:_reuse_primitive_pose_structure(previous_chunk, part) then
                dirty_count = dirty_count + 1
                n_rebake = n_rebake + 1
                if time_branches then t_rebake = t_rebake + (love.timer.getTime() - branch_started_at) end
                record_dynamic_part_render_pose(part)
                changed = true
            elseif previous_chunk and self:_fast_recube_dynamic_chunk(previous_chunk, part) then
                -- single-cube chunk -> in-place row rewrite, mega repack reads the mutated row
                dirty_count = dirty_count + 1
                n_recube = n_recube + 1
                if time_branches then t_recube = t_recube + (love.timer.getTime() - branch_started_at) end
                record_dynamic_part_render_pose(part)
                changed = true
            else
                dirty_count = dirty_count + 1
                n_full = n_full + 1
                local chunk = self:_build_dynamic_scene_chunk_for_part(part, part._id, previous_chunk)
                if chunk then
                    record_dynamic_part_render_pose(part)
                if previous_chunk then
                    chunk._cube_instance_batch = previous_chunk._cube_instance_batch
                    chunk.instance_mesh = previous_chunk.instance_mesh
                    chunk.cube_draw_mesh = previous_chunk.cube_draw_mesh
                    chunk.static_cube_mesh = previous_chunk.static_cube_mesh
                    previous_chunk._cube_instance_batch = nil
                    previous_chunk.instance_mesh = nil
                    previous_chunk.cube_draw_mesh = nil
                    previous_chunk.static_cube_mesh = nil
                end
                self:_build_single_scene_chunk_cube_draw(chunk)
                if previous_chunk then
                    -- Reused textured meshes cleared their old aliases during
                    -- finalize_scene_chunk, everything still owned by the old
                    -- chunk is now genuinely unmatched
                    self:_release_scene_chunk_meshes(previous_chunk, {}, true)
                end
                self:_capture_dynamic_chunk_fast_bake(chunk, part)
                self:_capture_dynamic_chunk_cube_fast(chunk, part)
                chunk_map[chunk.key] = chunk
                local replaced = false
                for index = 1, #chunk_list do
                    if chunk_list[index] and chunk_list[index].key == chunk.key then
                        chunk_list[index] = chunk
                        replaced = true
                        break
                    end
                end
                if not replaced then
                    chunk_list[#chunk_list + 1] = chunk
                end
                -- brand-new chunk (incremental promotion lands here): must remember it, the dynamic-set
                -- rebuild below only re-walks prior members and would silently drop it from drawing
                if not previous_chunk then
                    newly_added_dynamic = newly_added_dynamic or {}
                    newly_added_dynamic[#newly_added_dynamic + 1] = chunk
                end
                    changed = true
                end
                if time_branches then t_full = t_full + (love.timer.getTime() - branch_started_at) end
            end
        end
    end
    self._debug_last_transform_rebake_ms = t_rebake * 1000
    self._debug_last_transform_recube_ms = t_recube * 1000
    self._debug_last_transform_full_ms = t_full * 1000

    self._debug_sync_counts = self._debug_sync_counts or {}
    self._debug_sync_counts.transform = (self._debug_sync_counts.transform or 0) + 1
    self._debug_last_sync_mode = "transform"
    self._debug_last_transform_sync_part_count = dirty_count
    self._debug_last_transform_considered = n_considered
    self._debug_last_transform_pose_skipped = n_skip
    self._debug_last_transform_fast_rebake = n_rebake
    self._debug_last_transform_fast_recube = n_recube
    self._debug_last_transform_full_rebuild = n_full

    if self._mark_local_lights_dirty_for_parts then
        self:_mark_local_lights_dirty_for_parts(dirty_parts)
    end

    self._transform_dirty_parts = {}
    self._parts_dirty = false
    self._parts_dirty_mode = nil

    if changed then
        self._scene_chunk_map = chunk_map
        self._scene_chunks = chunk_list
        -- never rescan all chunks: the dynamic set only changes on full rebuild, so refresh the
        -- dynamic few + combine w/ the cached static aggregate. O(dynamic) not O(all) -- one moving
        -- part in a 1130-chunk map costs ~2.5ms otherwise
        local dynamic_chunks = {}
        local dyn_bounds = {
            min_x = math.huge,
            min_y = math.huge,
            min_z = math.huge,
            max_x = -math.huge,
            max_y = -math.huge,
            max_z = -math.huge,
        }
        local dyn_cube = 0
        local dyn_opaque = 0
        local dyn_textured = 0
        local dyn_transp = 0
        local prev_dynamic = self._scene_dynamic_chunks or {}
        local seen_dynamic_keys = newly_added_dynamic and {} or nil
        for index = 1, #prev_dynamic do
            local prev = prev_dynamic[index]
            local key = prev and prev.key
            -- pull the freshly-rebuilt chunk for this key (dirty loop replaced it in chunk_map)
            local chunk = (key ~= nil and chunk_map[key]) or prev
            if chunk and chunk.dynamic_chunk == true then
                if seen_dynamic_keys and chunk.key ~= nil then
                    seen_dynamic_keys[chunk.key] = true
                end
                dynamic_chunks[#dynamic_chunks + 1] = chunk
                if chunk.bounds then
                    expand_bounds_with_bounds(dyn_bounds, chunk.bounds)
                end
                dyn_cube = dyn_cube + #(chunk.cube_instances or {})
                dyn_opaque = dyn_opaque + #(chunk.opaque_static_draw_items or {})
                dyn_textured = dyn_textured
                    + #(chunk.textured_batches or {})
                    + #(chunk.overlay_textured_batches or {})
                dyn_transp = dyn_transp + #(chunk.transparent_draw_items or {})
            end
        end
        if newly_added_dynamic then
            for index = 1, #newly_added_dynamic do
                local chunk = newly_added_dynamic[index]
                if chunk and chunk.dynamic_chunk == true
                    and (chunk.key == nil or not seen_dynamic_keys[chunk.key]) then
                    if chunk.key ~= nil then
                        seen_dynamic_keys[chunk.key] = true
                    end
                    dynamic_chunks[#dynamic_chunks + 1] = chunk
                    if chunk.bounds then
                        expand_bounds_with_bounds(dyn_bounds, chunk.bounds)
                    end
                    dyn_cube = dyn_cube + #(chunk.cube_instances or {})
                    dyn_opaque = dyn_opaque + #(chunk.opaque_static_draw_items or {})
                    dyn_textured = dyn_textured
                        + #(chunk.textured_batches or {})
                        + #(chunk.overlay_textured_batches or {})
                    dyn_transp = dyn_transp + #(chunk.transparent_draw_items or {})
                end
            end
        end
        local dynamic_list_unchanged = not newly_added_dynamic and n_full == 0
            and #dynamic_chunks == #prev_dynamic
        if dynamic_list_unchanged then
            for index = 1, #dynamic_chunks do
                if dynamic_chunks[index] ~= prev_dynamic[index] then
                    dynamic_list_unchanged = false
                    break
                end
            end
        end
        if dynamic_list_unchanged then
            dynamic_chunks = prev_dynamic
        end
        self._scene_dynamic_chunks = dynamic_chunks
        self:_build_dynamic_mega_cube_draw(dynamic_chunks)
        -- cached static union U fresh dynamic union, exact, statics dont move between rebuilds
        local combined_bounds = {
            min_x = math.huge,
            min_y = math.huge,
            min_z = math.huge,
            max_x = -math.huge,
            max_y = -math.huge,
            max_z = -math.huge,
        }
        local static_bounds = self._static_scene_bounds
        if static_bounds then
            expand_bounds_with_bounds(combined_bounds, static_bounds)
        end
        if dyn_bounds.min_x < math.huge then
            expand_bounds_with_bounds(combined_bounds, dyn_bounds)
        end
        self._scene_bounds = combined_bounds.min_x < math.huge and finalize_bounds(combined_bounds) or nil
        self.instance_count = (self._static_cube_instance_count or 0) + dyn_cube
        self._opaque_static_batch_count = (self._static_opaque_static_batch_count or 0) + dyn_opaque
        self._textured_batch_count = (self._static_textured_batch_count or 0) + dyn_textured
        self._transparent_draw_count = (self._static_transparent_draw_count or 0) + dyn_transp
        -- bump dynamic revision, not static, so the next cull takes the cheap dynamic-only path
        self._scene_revision = (self._scene_revision or 0) + 1
        self._dynamic_scene_revision = (self._dynamic_scene_revision or 0) + 1
        if dynamic_list_unchanged then
            self._dynamic_scene_pose_only_revision =
                (self._dynamic_scene_pose_only_revision or 0) + 1
        end
        self._visible_scene_cache_state = self._visible_scene_cache_state or {}
        self._visible_scene_cache_state.scene_revision = nil
    end
    if sync_started_at then
        self._last_draw_packet_build_ms = math.max(0, (love.timer.getTime() - sync_started_at) * 1000)
    end

end

-- instanced mesh rendering: repeated opaque mesh/union/specialmesh geo -> one shared gpu mesh +
-- per-instance rows (drawInstanced), grouped by geometry+render-state signature. ineligible parts
-- fall back to baked, see docs/performance/INSTANCED_MESH_BASELINE.md

function RBX:_attach_mesh_instance_attributes(draw_mesh, instance_mesh)
    draw_mesh:attachAttribute("InstancePosition", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceRight", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceUp", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceBack", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceScale", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceColor", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceMisc", instance_mesh, "perinstance")
    draw_mesh:attachAttribute("InstanceContactAO", instance_mesh, "perinstance")
    self._instance_attribute_attach_build_count = (self._instance_attribute_attach_build_count or 0) + 8
end

function RBX._get_instanced_mesh_light_cell_key(renderer, transform)
    if type(renderer) ~= "table"
        or renderer._instanced_mesh_requires_light_partition ~= true then
        return nil
    end
    -- repeated geometry must not form one scene-wide light consumer. Partition
    -- by the same coarse world cells used by the local-light clustering path;
    -- the draw then selects an exact pack from each resulting group's bounds
    -- map application enables this gate from the parsed-light count before
    -- parts are built, runtime light-count changes dirty/rebuild the groups
    local cell_size =
        tonumber(renderer._instanced_mesh_light_partition_size)
        or (
            math.max(
                8,
                tonumber(renderer.local_light_grid_cell_size)
                    or 64)
            * math.max(
                1,
                math.floor(
                    tonumber(
                        renderer.local_light_cluster_supercell_span)
                        or 2))
        )
    return table.concat({
        math.floor(
            (tonumber(transform and transform.px) or 0)
                / cell_size),
        ":",
        math.floor(
            (tonumber(transform and transform.py) or 0)
                / cell_size),
        ":",
        math.floor(
            (tonumber(transform and transform.pz) or 0)
                / cell_size),
    })
end

-- true=bucketed (caller skips baked append), else false+reason. color/alpha mirrors
-- _append_mesh_part_batch exactly, stashed so repacks never re-derive differently
local function try_bucket_instanced_mesh_part(renderer, buckets, bucket_order, part, chunk, is_transparent)
    if is_transparent then
        return false, "transparent"
    end
    if part._promoted_dynamic == true or part._runtime_dynamic == true
        or part._kinematic_dynamic == true or part._appearance_dynamic == true then
        return false, "dynamic_path"
    end
    local mesh_data = renderer:_get_or_parse_part_mesh(part)
    if not mesh_data then
        return false, "no_mesh_data"
    end
    local surface_descriptor = RBX._get_native_mesh_surface_appearance(part)
    if surface_descriptor then
        local eligible, reason =
            SurfaceAppearance.instancing_eligibility(surface_descriptor)
        if not eligible then
            return false, reason
                or "surface_appearance_requires_baked_shader"
        end
    end
    local material_descriptor = renderer:_get_material_descriptor(
        part.Material, part.MaterialVariant)
    if material_descriptor
        and material_descriptor.material_variant_surface_active == true then
        -- the projected instanced shader does not yet carry ColorMap alpha,
        -- emissive, or five stable remote sampler handles. keep fidelity by
        -- routing variants through the baked full-material path explicitly
        return false, "material_variant_requires_baked_shader"
    end
    -- SurfaceAppearance is always a baked/full-shader path.  resolve its exact
    -- eligibility reason before generic atlas/debug fallbacks so diagnostics do
    -- not depend on unrelated renderer settings
    if renderer.mesh_texture_atlas == true then
        return false, "atlas_active"
    end
    if renderer.mesh_debug_mode or renderer.mesh_debug_target then
        return false, "mesh_debug_active"
    end
    local texture_info = renderer:_resolve_mesh_part_texture_info(
        part, mesh_data, material_descriptor)
    if texture_info.mesh_texture_layer then
        return false, "mesh_texture_layer_requires_baked_shader"
    end
    local signature = rbx_mesh_geometry_signature(mesh_data)
    if not signature then
        return false, "no_signature"
    end
    local transform = renderer:_get_mesh_render_transform(part, mesh_data)
    if type(transform) ~= "table" then
        return false, "no_transform"
    end

    -- material-projected parts instance via the projected shader variant if parity holds, else
    -- baked w/ a reason, see PROJECTED_UV_INSTANCING_BASELINE.md
    local projected = nil
    if texture_info.use_material_texture then
        if renderer.instanced_projected_uv ~= true
            or renderer._instanced_mesh_material_shader == nil then
            return false, "projected_uv_disabled"
        end
        -- baked uses the FULL material shader only under this config, other configs pick the fast
        -- textured shader, which the instanced variant cant reproduce -- so stay baked
        if renderer.textured_shader_quality ~= "full"
            or renderer.high_fps_shaders == true
            or renderer.target_fps_mode == true
            or renderer.disable_material_maps == true
            or renderer.disable_normal_maps == true then
            return false, "projected_uv_variant_unsupported"
        end
        -- baked shader uses real tangents for normal maps, the instanced variant has none
        if type(mesh_data.tangents) == "table" and #mesh_data.tangents > 0 then
            return false, "projected_uv_has_tangents"
        end
        local projection = transform.projection
        if type(projection) ~= "table" then
            return false, "projected_uv_no_projection"
        end
        local descriptor = texture_info.material_descriptor
        if type(descriptor) ~= "table" or not descriptor.color_texture then
            return false, "projected_uv_descriptor_incomplete"
        end
        local face_ids, face_context = renderer:_bake_projected_face_ids(mesh_data, transform)
        if not face_ids then
            return false, "projected_uv_face_bake_failed"
        end
        -- bake scales UVs by local_scale+em-sign, build_context scales BOUNDS by scale_*+em-sign
        -- they differ only by +-1, hence 2 sign uniforms (emSign, boundsSign=scale*em/local_scale)
        local em_x = transform.projection_extra_mirror_x and -1 or 1
        local em_y = transform.projection_extra_mirror_y and -1 or 1
        local em_z = transform.projection_extra_mirror_z and -1 or 1
        local ls_x = transform.local_scale_x or ((transform.mesh_axis_x or 1) * transform.scale_x)
        local ls_y = transform.local_scale_y or transform.scale_y
        local ls_z = transform.local_scale_z or ((transform.mesh_axis_z or 1) * transform.scale_z)
        if math.abs(ls_x) < 1e-9 or math.abs(ls_y) < 1e-9 or math.abs(ls_z) < 1e-9 then
            return false, "projected_uv_degenerate_scale"
        end
        projected = {
            descriptor = descriptor,
            projection = projection,
            face_ids = face_ids,
            face_context = face_context,
            -- UNscaled mesh-local bounds, shader rebuilds the scaled/mirrored range per instance
            local_bounds = transform.bounds,
            em_sign_x = em_x,
            em_sign_y = em_y,
            em_sign_z = em_z,
            bounds_sign_x = (transform.scale_x * em_x) / ls_x,
            bounds_sign_y = (transform.scale_y * em_y) / ls_y,
            bounds_sign_z = (transform.scale_z * em_z) / ls_z,
            tiling = math.max(0.001, descriptor.tiling or 1),
            studs_per_tile = math.max(0.001,
                renderer.material_studs_per_tile or MATERIAL_STUDS_PER_TILE),
        }
    end

    local is_csg_part = is_csg_part_class(part.ClassName)
    local is_double_sided = part.DoubleSided == true
    local has_mesh_texture = texture_info.has_mesh_texture
    local colors_used = should_use_mesh_vertex_colors(part, mesh_data)
        and type(mesh_data.colors) == "table" and #mesh_data.colors > 0

    -- per-part color decisions, byte-for-byte the bake's logic
    local apply_part_tint = should_apply_part_tint(part, mesh_data)
    local color_options = colors_used and IGNORE_MESH_VERTEX_COLOR_OPTIONS or nil
    if has_mesh_texture and not is_csg_part then
        apply_part_tint = false
        if not colors_used then
            color_options = MESH_TEXTURE_VERTEX_COLOR_OPTIONS
        end
    end
    local render_color_mode = nil
    if color_options then
        render_color_mode = color_options.ignore_mesh_vertex_color
            and "ignore_mesh_vertex_color"
            or "mesh_texture_uses_vertex_color"
    end
    local color_r, color_g, color_b = get_runtime_render_color(part, apply_part_tint, color_options)
    local alpha = get_runtime_render_alpha(part)
    local reflectance = get_runtime_render_reflectance(part)

    -- a missing image texture means white albedo, not emissive/unlit geometry
    -- keep all non-projected opaque meshes on the same frame-lit instanced
    -- shader so the instanced and CPU-baked paths remain pixel-equivalent
    local variant = projected and "material_projected" or "fast"
    local cull_mode = (is_csg_part or is_double_sided) and "none" or "back"
    local render_extent = get_scaled_bounds_extent(
        transform.bounds, transform.scale_x, transform.scale_y, transform.scale_z)
    local depth_bias = RBX._get_dynamic_depth_bias(renderer, "mesh", part, render_extent, mesh_data)
    local bias_key = math.floor(depth_bias * 10000 + (depth_bias >= 0 and 0.5 or -0.5)) / 10000

    local key = signature
        .. "|" .. texture_info.batch_key
        .. "|v:" .. variant
        .. "|cm:" .. cull_mode
        .. "|sw:" .. (transform.cull_swap and "1" or "0")
        .. "|fu:" .. (transform.uv_mirror_u and "1" or "0")
        .. "|fv:" .. (transform.uv_mirror_v and "1" or "0")
        .. "|vc:" .. (colors_used and "1" or "0")
        .. "|db:" .. string.format("%.4f", bias_key)
    local light_cell_key =
        RBX._get_instanced_mesh_light_cell_key(
            renderer, transform)
    if light_cell_key then
        key = key .. "|llc:" .. light_cell_key
    end
    if projected then
        -- baked face ids are only exact for instances sharing the signed-scale context they were
        -- computed under, the context key folds that in
        key = key .. "|proj:" .. projected.face_context
            .. "|mat:" .. tostring(projected.descriptor.key)
    end

    local bucket = buckets[key]
    if not bucket then
        bucket = {
            key = key,
            entries = {},
            mesh_data = mesh_data,
            texture = projected and projected.descriptor.color_texture or texture_info.texture,
            texture_key = texture_info.texture_key,
            -- Legacy mesh textures own their alpha coverage. Material-projected
            -- textures are opaque surface detail and deliberately ignore alpha
            ignore_texture_alpha = texture_info.use_material_texture == true,
            remote_texture_handle = projected and nil
                or texture_info.remote_texture_handle,
            variant = variant,
            cull_mode = cull_mode,
            cull_swap = transform.cull_swap == true,
            -- material batches sample flip_v=true, flip_u=false, the uv mirror flags are
            -- mesh-texture semantics, not material
            flip_u = projected and false or (transform.uv_mirror_u == true),
            flip_v = projected and true or (transform.uv_mirror_v == true),
            use_vertex_colors = colors_used,
            depth_bias = depth_bias,
            signature = signature,
            projected = projected,
            light_cell_key = light_cell_key,
        }
        buckets[key] = bucket
        bucket_order[#bucket_order + 1] = bucket
    end
    bucket.entries[#bucket.entries + 1] = {
        part = part,
        chunk = chunk,
        mesh_data = mesh_data,
        transform = transform,
        color_r = color_r,
        color_g = color_g,
        color_b = color_b,
        alpha = alpha,
        reflectance = reflectance,
        render_apply_part_tint = apply_part_tint,
        render_color_mode = render_color_mode,
    }
    return true
end

-- built-in material primitives share the repeated-mesh resource lifecycle, but
-- retain primitive face projection and ownership. cache only immutable source
-- geometry and face IDs: parent Size stays per-instance rather than splitting
-- groups into one geometry upload per size
function RBX:_try_bucket_instanced_material_primitive(buckets, bucket_order, part, chunk, is_transparent)
    -- a primitive geometry key alone is insufficient: asset-owned BaseParts
    -- can still report their parent's Shape when no primitive override exists
    -- keep those owners on their mesh route even if this helper is called
    -- outside the full-build classifier's normal ownership gates
    if type(part) ~= "table"
        or legacy_mesh_asset_owns_geometry(part)
        or is_csg_part_class(part.ClassName) or part.ClassName == "MeshPart"
        or RBX._part_has_renderable_mesh_source(part)
        or not RBX._is_empty_asset_reference(part.TextureContent)
        or not RBX._is_empty_asset_reference(part.TextureId)
        or self._material_primitive_instancing_enabled == false
        or is_transparent or get_runtime_render_alpha(part) < 0.999
        or part._promoted_dynamic == true or part._runtime_dynamic == true
        or part._kinematic_dynamic == true or part._appearance_dynamic == true
        or self._instanced_mesh_material_shader == nil
        or self.textured_shader_quality ~= "full"
        or self.high_fps_shaders == true or self.target_fps_mode == true
        or self.disable_material_maps == true or self.disable_normal_maps == true then
        return false
    end
    local descriptor = self:_get_material_descriptor(part.Material, part.MaterialVariant)
    if not descriptor or descriptor.canonical_token == 256
        or descriptor.material_variant_surface_active == true then
        return false
    end
    local shape = get_runtime_part_render_geometry_key(part)
    local source = self._primitive_vertices and self._primitive_vertices[shape]
    if type(source) ~= "table" or #source == 0 or #source % 3 ~= 0 then
        return false
    end
    local px, py, pz, rx, ry, rz, ux, uy, uz, bx, by, bz, sx, sy, sz =
        get_runtime_part_render_basis(part)
    if math.abs(sx) <= 1e-6 or math.abs(sy) <= 1e-6 or math.abs(sz) <= 1e-6 then
        return false
    end
    local transform = {
        px = px, py = py, pz = pz,
        rx = rx, ry = ry, rz = rz, ux = ux, uy = uy, uz = uz,
        bx = bx, by = by, bz = bz,
        local_scale_x = sx, local_scale_y = sy, local_scale_z = sz,
    }
    local light_cell, light_cell_size, light_cell_x, light_cell_y, light_cell_z
    if self._instanced_mesh_requires_light_partition == true then
        light_cell_size = math.max(8, tonumber(self.local_light_grid_cell_size) or 64)
        local bounds = self:_get_part_render_bounds(part)
        -- the existing shared-cell selector accepts an individual consumer no
        -- wider than one cell. its half-cell-expanded query conservatively
        -- contains that part even when it straddles a cell boundary. preserve
        -- oversized primitives on the already-batched material route
        if not bounds or bounds.max_x - bounds.min_x > light_cell_size
            or bounds.max_y - bounds.min_y > light_cell_size
            or bounds.max_z - bounds.min_z > light_cell_size then
            return false
        end
        light_cell_x = math.floor((bounds.min_x + bounds.max_x) * 0.5 / light_cell_size)
        light_cell_y = math.floor((bounds.min_y + bounds.max_y) * 0.5 / light_cell_size)
        light_cell_z = math.floor((bounds.min_z + bounds.max_z) * 0.5 / light_cell_size)
        light_cell = light_cell_x .. ":" .. light_cell_y .. ":" .. light_cell_z
    end
    local cache = self._material_primitive_mesh_sources
    if not cache then
        cache = setmetatable({}, { __mode = "k" })
        self._material_primitive_mesh_sources = cache
    end
    local geometry = cache[source]
    if not geometry then
        local positions, normals = {}, {}
        for i = 1, #source do
            local vertex = source[i]
            local offset = (i - 1) * 3
            for axis = 1, 3 do
                positions[offset + axis] = vertex[axis] or 0
                normals[offset + axis] = vertex[axis + 3] or 0
            end
        end
        geometry = { mesh_data = { positions = positions, normals = normals }, faces = {} }
        cache[source] = geometry
    end
    local extra_mirror = part._loaded_map_mirror_x == true
    local face_context = (sx < 0 and 1 or 0) + (sy < 0 and 2 or 0)
        + (sz < 0 and 4 or 0) + (extra_mirror and 8 or 0)
        + (RBX._accurate_face_axes and 16 or 0)
    local face_ids = geometry.faces[face_context]
    if not face_ids then
        face_ids = {}
        local projection = MATERIAL_PROJECTION.build_context(nil, sx, sy, sz, extra_mirror, false, false)
        local ids = { Right = 0, Top = 1, Back = 2, Left = 3, Bottom = 4, Front = 5 }
        for i = 1, #source, 3 do
            local a, b, c = source[i], source[i + 1], source[i + 2]
            local face = MATERIAL_PROJECTION.select_face_name(nil,
                (a[4] or 0) + (b[4] or 0) + (c[4] or 0),
                (a[5] or 0) + (b[5] or 0) + (c[5] or 0),
                (a[6] or 0) + (b[6] or 0) + (c[6] or 0), projection)
            face_ids[i], face_ids[i + 1], face_ids[i + 2] = ids[face], ids[face], ids[face]
        end
        geometry.faces[face_context] = face_ids
    end
    local use_maps = descriptor.has_color_map == true
    local depth_bias = clamp(tonumber(RBX._get_dynamic_depth_bias(self, "material", part,
        math.max(math.abs(sx), math.abs(sy), math.abs(sz)))) or 0, -0.01, 0.01)
    local bias_key = math.floor(depth_bias * 10000 + (depth_bias >= 0 and 0.5 or -0.5)) / 10000
    local cull_swap = RBX._basis_handedness_sign(rx, ry, rz, ux, uy, uz, bx, by, bz)
        * RBX._axis_sign(sx) * RBX._axis_sign(sy) * RBX._axis_sign(sz) < 0
    local signature = "material_primitive|" .. shape
    local key = signature .. "|" .. descriptor.key .. "|pf:" .. face_context
        .. "|sw:" .. (cull_swap and "1" or "0") .. "|db:" .. string.format("%.4f", bias_key)
        .. (light_cell and "|llc:" .. light_cell or "")
    local bucket = buckets[key]
    if not bucket then
        local em = extra_mirror and -1 or 1
        bucket = {
            key = key, signature = signature, entries = {},
            mesh_data = geometry.mesh_data, primitive_material = true,
            texture = use_maps and descriptor.color_texture or self._white_texture,
            texture_key = use_maps and descriptor.key or "__white",
            ignore_texture_alpha = true, variant = "material_projected",
            cull_mode = "back", cull_swap = cull_swap,
            flip_u = false, flip_v = use_maps, use_vertex_colors = false,
            depth_bias = depth_bias, light_cell_key = light_cell,
            -- Lighting identity is separate from the real union AABB used by
            -- culling/shadows. the union may exceed one cell even though every
            -- member is a valid consumer of this same deterministic cell pack
            material_primitive_light_cell = light_cell and {
                x = light_cell_x, y = light_cell_y, z = light_cell_z, size = light_cell_size,
            } or nil,
            projected = {
                primitive = true, descriptor = descriptor,
                use_material_maps = use_maps, use_normal_map = use_maps and descriptor.has_normal_map == true,
                texture_color_mix = use_maps and 1 or 0,
                face_ids = face_ids, face_context = tostring(face_context),
                em_sign_x = em, em_sign_y = 1, em_sign_z = 1,
                bounds_sign_x = em, bounds_sign_y = 1, bounds_sign_z = 1,
                tiling = math.max(0.001, descriptor.tiling or 1),
                studs_per_tile = math.max(0.001, self.material_studs_per_tile or MATERIAL_STUDS_PER_TILE),
            },
        }
        buckets[key] = bucket
        bucket_order[#bucket_order + 1] = bucket
    end
    local r, g, b = get_runtime_render_color(part, true)
    bucket.entries[#bucket.entries + 1] = {
        part = part, chunk = chunk, transform = transform, primitive_material = true,
        color_r = r, color_g = g, color_b = b, alpha = get_runtime_render_alpha(part),
        reflectance = get_runtime_render_reflectance(part), render_apply_part_tint = true,
    }
    return true, key
end

-- groups >=2 become instanced gpu groups, singletons late-append via baked path -- so this MUST run
-- before chunk finalize, while the batch maps are still open. gpu failure falls back per bucket
local function refresh_remote_instanced_mesh_group(
    renderer, group, texture, resource_key)
    group.texture = texture
    group.texture_key = resource_key
    local backend_batch = group._instance_resource_batch
    if type(backend_batch) == "table" then
        backend_batch.texture = texture
    end
    return true
end
RBX._refresh_remote_instanced_mesh_group =
    refresh_remote_instanced_mesh_group

function RBX:_build_instanced_mesh_groups(buckets, bucket_order, fallback_reasons)
    -- Invocation-local opt-in attribution: never read a later rebuild's
    -- mutable profile table as this initial load's fallback measurement
    local fallback_profile = type(self._face_layer_build_profile) == "table" and {
        material_wall = 0, material_calls = 0,
        mesh_wall = 0, mesh_calls = 0,
    } or nil
    local groups = {}
    self._instanced_mesh_groups = groups
    self._instanced_mesh_object_count = 0
    self._instanced_projected_group_count = 0
    self._instanced_projected_object_count = 0
    local index_stats = {
        indexed_group_count = 0,
        uint16_group_count = 0,
        uint32_group_count = 0,
        flat_group_count = 0,
        backend_failure_fallback_count = 0,
        source_vertex_count = 0,
        base_vertex_count = 0,
        index_count = 0,
        flat_vertex_bytes = 0,
        uploaded_base_bytes = 0,
        bytes_saved = 0,
        fallback_reasons = {},
    }
    self._instanced_mesh_index_stats = index_stats
    -- clear, else a zero-group rebuild reports the previous scene's cull numbers
    self._instanced_group_cull_stats = nil
    self._instanced_group_cull_saved_draws = 0
    self._instanced_group_cull_saved_instances = 0
    if #bucket_order == 0 then
        return fallback_profile
    end

    local geo_cache = {}
    local generation = self._instance_generation or 0

    local function late_append(entry, reason)
        fallback_reasons[reason] = (fallback_reasons[reason] or 0) + 1
        self._range_track_log = range_track_log
        local ok, batch_key
        if entry.primitive_material then
            ok, batch_key = self:_append_part_material_batch(entry.chunk.opaque_textured_batch_map, entry.part)
        else
            ok = self:_append_mesh_part_batch(entry.chunk.opaque_textured_batch_map, entry.part)
        end
        self:_flush_part_static_ranges(entry.part)
        if not ok then
            fallback_reasons.late_append_failed = (fallback_reasons.late_append_failed or 0) + 1
        end
    end

    if fallback_profile then
        -- select once: ordinary builds retain the original closure with no
        -- extra per-entry branch/clock. Direct calls preserve yields/errors;
        -- an aborted invocation never returns completed attribution
        local append = late_append
        late_append = function(entry, reason)
            local started = love.timer.getTime()
            append(entry, reason)
            local elapsed = love.timer.getTime() - started
            if entry.primitive_material then
                fallback_profile.material_wall =
                    fallback_profile.material_wall + elapsed
                fallback_profile.material_calls = fallback_profile.material_calls + 1
            else
                fallback_profile.mesh_wall = fallback_profile.mesh_wall + elapsed
                fallback_profile.mesh_calls = fallback_profile.mesh_calls + 1
            end
        end
    end

    -- each group adds a draw. imported meshes may replace independent draws,
    -- but material primitives otherwise share an existing static material
    -- batch: instance count alone does not establish a win. Require enough
    -- source-vertex work for their production route, explicit private opt-in
    -- keeps the complete candidate path available to GPU/A-B oracles
    local MIN_GROUP_COUNT = 8
    local MIN_GROUP_VERT_SCORE = 8000
    local min_material_primitive_vert_score =
        tonumber(self._material_primitive_min_vertex_score) or 32000
    -- private build-time oracle seam, not a public renderer option. keep the
    -- production policy when a diagnostic supplies a non-finite/invalid score
    if min_material_primitive_vert_score < 1
        or min_material_primitive_vert_score ~= min_material_primitive_vert_score
        or min_material_primitive_vert_score == math.huge then
        min_material_primitive_vert_score = 32000
    end
    min_material_primitive_vert_score = math.floor(min_material_primitive_vert_score)
    index_stats.material_primitive_min_vertex_score = min_material_primitive_vert_score

    for order_index = 1, #bucket_order do
        local bucket = bucket_order[order_index]
        local entries = bucket.entries
        local geo_vertex_count = math.floor(#(bucket.mesh_data.positions or "") / 3)
        local retain_transform = self.retain_mesh_transforms == true
            and not bucket.primitive_material and not bucket.projected
        if #entries < 2 and not retain_transform then
            for i = 1, #entries do
                late_append(entries[i], "group_of_one")
            end
        elseif bucket.primitive_material
            and self._material_primitive_instancing_enabled ~= true
            and #entries * geo_vertex_count < min_material_primitive_vert_score then
            for i = 1, #entries do
                late_append(entries[i], "primitive_material_below_vertex_score")
            end
        elseif not retain_transform and #entries < MIN_GROUP_COUNT
            and #entries * geo_vertex_count < MIN_GROUP_VERT_SCORE then
            for i = 1, #entries do
                late_append(entries[i], "group_below_threshold")
            end
        else
            local projected = bucket.projected
            local geo_key = bucket.signature .. "|vc:" .. (bucket.use_vertex_colors and "1" or "0")
                .. (projected and ("|pf:" .. projected.face_context) or "")
            local geo = geo_cache[geo_key]
            if geo == nil then
                local indexed, index_reason, index_diagnostic
                if self.enable_repeated_mesh_indexing == false then
                    index_reason = "disabled"
                elseif self.render_backend_name == "menori"
                    and self._render_backend then
                    indexed, index_reason, index_diagnostic =
                        rbx_build_indexed_instanced_mesh_geometry(
                            bucket.mesh_data,
                            bucket.use_vertex_colors,
                            projected and projected.face_ids or nil
                        )
                end
                geo = {
                    mesh_data = bucket.mesh_data,
                    use_vertex_colors = bucket.use_vertex_colors,
                    face_ids = projected and projected.face_ids or nil,
                    projected = projected ~= nil,
                    source_vertex_count = geo_vertex_count,
                    component_count = projected and 13 or 12,
                    indexed = indexed,
                    index_reason = index_reason,
                    index_diagnostic = index_diagnostic,
                    -- the flat ByteData is deliberately lazy. Successful Menori
                    -- groups never allocate or upload the legacy base geometry
                    byte_data = nil,
                }
                geo_cache[geo_key] = geo
            end

            local group = nil
            if geo then
                local pending_batch
                local pending_draw_mesh
                local pending_instance_mesh
                local ok_group, group_or_err = pcall(function()
                    local draw_mesh
                    local instance_mesh
                    local instance_resource_batch
                    local rows = {}
                    local instances_have_unit_alpha = true
                    -- Flat six-number AABB snapshots parallel to the instance
                    -- rows. a moved extremal member can then shrink the group
                    -- exactly without retaining another table per part
                    local instance_bounds = {}
                    local bounds = {
                        min_x = math.huge, min_y = math.huge, min_z = math.huge,
                        max_x = -math.huge, max_y = -math.huge, max_z = -math.huge,
                    }
                    for i = 1, #entries do
                        local entry = entries[i]
                        local part = entry.part
                        rows[i] = rbx_pack_mesh_instance_row({}, entry.transform,
                            entry.color_r, entry.color_g, entry.color_b, entry.alpha,
                            entry.reflectance,
                            part._contact_ao_top or 0, part._contact_ao_bottom or 0,
                            part._contact_ao_side or 0, part._contact_ao_max or 0)
                        instances_have_unit_alpha = instances_have_unit_alpha
                            and rows[i][19] == 1
                        local part_bounds = self:_get_part_render_bounds(part)
                        local bounds_offset = (i - 1) * 6
                        instance_bounds[bounds_offset + 1] = part_bounds.min_x
                        instance_bounds[bounds_offset + 2] = part_bounds.min_y
                        instance_bounds[bounds_offset + 3] = part_bounds.min_z
                        instance_bounds[bounds_offset + 4] = part_bounds.max_x
                        instance_bounds[bounds_offset + 5] = part_bounds.max_y
                        instance_bounds[bounds_offset + 6] = part_bounds.max_z
                        expand_bounds_with_bounds(bounds, part_bounds)
                    end

                    local indexed = geo.indexed
                    local backend_failure = false
                    if indexed
                        and self.render_backend_name == "menori"
                        and self._render_backend then
                        local backend_ok, batch_or_error = pcall(
                            self._render_backend.create_instanced_batch,
                            self._render_backend, {
                                base_vertex_format =
                                    projected
                                        and self._instanced_projected_vertex_format
                                        or self._instanced_mesh_vertex_format,
                                base_vertices = indexed.vertices,
                                vertex_count = indexed.vertex_count,
                                source_vertex_count =
                                    indexed.source_vertex_count,
                                indices = indexed.indices,
                                indices_tsize = indexed.indices_tsize,
                                instance_format = self._mesh_instance_vertex_format,
                                instance_rows = rows,
                                instance_count = #entries,
                                initial_capacity = #entries,
                                kind = "opaque_mesh_group",
                            })
                        if backend_ok and batch_or_error then
                            instance_resource_batch = batch_or_error
                            pending_batch = instance_resource_batch
                            draw_mesh = instance_resource_batch.draw_mesh
                            instance_mesh = instance_resource_batch.instance_mesh
                            draw_mesh:setTexture(
                                bucket.texture or self._white_texture)
                            self._instance_attribute_attach_build_count =
                                (self._instance_attribute_attach_build_count or 0) + 8
                        else
                            backend_failure = true
                            self:_note_render_backend_error(
                                "create repeated mesh group", batch_or_error)
                        end
                    end
                    if not instance_mesh then
                        if geo.byte_data == nil then
                            local byte_data, vertex_count
                            if geo.projected then
                                byte_data, vertex_count =
                                    rbx_build_instanced_projected_geometry(
                                        geo.mesh_data,
                                        geo.use_vertex_colors,
                                        geo.face_ids
                                    )
                            else
                                byte_data, vertex_count =
                                    rbx_build_instanced_mesh_geometry(
                                        geo.mesh_data,
                                        geo.use_vertex_colors
                                    )
                            end
                            geo.byte_data = byte_data or false
                            geo.flat_vertex_count = vertex_count or 0
                        end
                        if geo.byte_data == false then
                            error("repeated mesh flat geometry pack failed", 0)
                        end
                        draw_mesh = love.graphics.newMesh(
                            projected and self._instanced_projected_vertex_format
                                or self._instanced_mesh_vertex_format,
                            geo.flat_vertex_count, "triangles", "static")
                        pending_draw_mesh = draw_mesh
                        draw_mesh:setVertices(geo.byte_data)
                        draw_mesh:setTexture(bucket.texture or self._white_texture)
                        instance_mesh = love.graphics.newMesh(
                            self._mesh_instance_vertex_format, #entries, "points", "dynamic")
                        pending_instance_mesh = instance_mesh
                        instance_mesh:setVertices(rows)
                        self:_attach_mesh_instance_attributes(draw_mesh, instance_mesh)
                    end
                    -- every successful repeated group uploads two LOVE Mesh
                    -- resources: one immutable base and one instance buffer
                    -- keep this counter's existing resource semantics (the
                    -- Menori Block/primitive paths count the same pair)
                    self:_note_load_cache_stat("gpu_mesh_upload_count")
                    self:_note_load_cache_stat("gpu_mesh_upload_count")
                    local indexed_active = instance_resource_batch ~= nil
                    local flat_vertex_bytes =
                        geo.source_vertex_count * geo.component_count * 4
                    local uploaded_base_bytes = indexed_active
                        and indexed.indexed_bytes or flat_vertex_bytes
                    self:_note_gpu_upload_bytes(uploaded_base_bytes)
                    self:_note_gpu_upload_bytes(#entries * 27 * 4)

                    local built = {
                        key = bucket.key,
                        variant = bucket.variant,
                        draw_mesh = draw_mesh,
                        instance_mesh = instance_mesh,
                        _instance_resource_batch = instance_resource_batch,
                        count = #entries,
                        vertex_count = indexed_active
                            and indexed.vertex_count
                            or geo.source_vertex_count,
                        source_vertex_count = geo.source_vertex_count,
                        index_count = indexed_active
                            and indexed.index_count or 0,
                        indices_tsize = indexed_active
                            and indexed.indices_tsize or nil,
                        indexed_base_geometry = indexed_active,
                        -- Prove the actual immutable base and all uploaded rows
                        -- mutable/legacy resources retain the original varying
                        vertex_alpha_is_one = indexed_active and not retain_transform
                            and instances_have_unit_alpha
                            and RBX._textured_vertices_have_unit_alpha(indexed.vertices),
                        flat_vertex_bytes = flat_vertex_bytes,
                        uploaded_base_bytes = uploaded_base_bytes,
                        index_fallback_reason = indexed_active
                            and nil
                            or (backend_failure
                                and "backend_failure"
                                or geo.index_reason
                                or (self.render_backend_name == "menori"
                                    and "index_build_unavailable"
                                    or "love_backend")),
                        rows = rows,
                        instance_bounds = instance_bounds,
                        texture = bucket.texture,
                        texture_key = bucket.texture_key,
                        ignore_texture_alpha =
                            bucket.ignore_texture_alpha == true,
                        remote_texture_handle = bucket.remote_texture_handle,
                        cull_mode = bucket.cull_mode,
                        cull_swap = bucket.cull_swap,
                        flip_u = bucket.flip_u,
                        flip_v = bucket.flip_v,
                        depth_bias = bucket.depth_bias,
                        light_cell_key = bucket.light_cell_key,
                        material_primitive_light_cell = bucket.material_primitive_light_cell,
                        bounds = finalize_bounds(bounds),
                        generation = generation,
                        -- projected-uv group state consumed by draw pass
                        projected = projected and {
                            primitive = projected.primitive == true,
                            use_material_maps = projected.use_material_maps,
                            use_normal_map = projected.use_normal_map,
                            texture_color_mix = projected.texture_color_mix,
                            material_key = projected.descriptor.key,
                            material_surface = projected.descriptor.material_surface,
                            material_map_mask = projected.descriptor.material_map_mask,
                            normal_texture = projected.descriptor.normal_texture,
                            roughness_texture = projected.descriptor.roughness_texture,
                            metalness_texture = projected.descriptor.metalness_texture,
                            tiling = projected.tiling,
                            studs_per_tile = projected.studs_per_tile,
                            em_sign = { projected.em_sign_x, projected.em_sign_y, projected.em_sign_z },
                            bounds_sign = { projected.bounds_sign_x, projected.bounds_sign_y,
                                projected.bounds_sign_z },
                            bounds_min = {
                                (projected.local_bounds and projected.local_bounds.min_x) or -0.5,
                                (projected.local_bounds and projected.local_bounds.min_y) or -0.5,
                                (projected.local_bounds and projected.local_bounds.min_z) or -0.5,
                            },
                            bounds_max = {
                                (projected.local_bounds and projected.local_bounds.max_x) or 0.5,
                                (projected.local_bounds and projected.local_bounds.max_y) or 0.5,
                                (projected.local_bounds and projected.local_bounds.max_z) or 0.5,
                            },
                        } or nil,
                    }
                    return built
                end)
                if ok_group then
                    group = group_or_err
                else
                    if pending_batch then
                        self:_release_opaque_cube_batch(pending_batch)
                    else
                        local released = {}
                        release_scene_mesh_once(
                            pending_instance_mesh, released)
                        release_scene_mesh_once(
                            pending_draw_mesh, released)
                    end
                end
            end

            if not group then
                for i = 1, #entries do
                    late_append(entries[i], geo and "group_gpu_failed" or "geometry_pack_failed")
                end
            else
                if group.remote_texture_handle then
                    self:_bind_remote_texture_consumer(
                        group.remote_texture_handle, group, {
                            role = "instanced_group_texture",
                            texture_field = "texture",
                            resource_key_field = "texture_key",
                            mesh_field = "draw_mesh",
                            callback = refresh_remote_instanced_mesh_group,
                        })
                end
                groups[#groups + 1] = group
                self._instanced_mesh_object_count = self._instanced_mesh_object_count + #entries
                index_stats.source_vertex_count =
                    index_stats.source_vertex_count
                        + (group.source_vertex_count or 0)
                index_stats.base_vertex_count =
                    index_stats.base_vertex_count
                        + (group.vertex_count or 0)
                index_stats.index_count =
                    index_stats.index_count
                        + (group.index_count or 0)
                index_stats.flat_vertex_bytes =
                    index_stats.flat_vertex_bytes
                        + (group.flat_vertex_bytes or 0)
                index_stats.uploaded_base_bytes =
                    index_stats.uploaded_base_bytes
                        + (group.uploaded_base_bytes or 0)
                index_stats.bytes_saved =
                    index_stats.bytes_saved
                        + math.max(
                            0,
                            (group.flat_vertex_bytes or 0)
                                - (group.uploaded_base_bytes or 0)
                        )
                if group.indexed_base_geometry then
                    index_stats.indexed_group_count =
                        index_stats.indexed_group_count + 1
                    if group.indices_tsize == 2 then
                        index_stats.uint16_group_count =
                            index_stats.uint16_group_count + 1
                    else
                        index_stats.uint32_group_count =
                            index_stats.uint32_group_count + 1
                    end
                else
                    index_stats.flat_group_count =
                        index_stats.flat_group_count + 1
                    local fallback_reason =
                        group.index_fallback_reason or "unknown"
                    index_stats.fallback_reasons[fallback_reason] =
                        (index_stats.fallback_reasons[fallback_reason] or 0) + 1
                    if fallback_reason == "backend_failure" then
                        index_stats.backend_failure_fallback_count =
                            index_stats.backend_failure_fallback_count + 1
                    end
                end
                if projected then
                    self._instanced_projected_group_count = self._instanced_projected_group_count + 1
                    self._instanced_projected_object_count =
                        self._instanced_projected_object_count + #entries
                end
                local stage = self._range_static_stage
                if not stage then
                    stage = {}
                    self._range_static_stage = stage
                end
                for i = 1, #entries do
                    local entry = entries[i]
                    local part = entry.part
                    part._instanced_ref = {
                        group = group,
                        row = i,
                        generation = generation,
                        fast = not entry.primitive_material and part._instanced_has_decals ~= true,
                        -- mismatch = this ref's cached color/alpha/texture/geo is stale, so moves
                        -- fall back to full rebuild instead of re-uploading a stale row
                        prop_revision = part._render_prop_revision or 0,
                        color_r = entry.color_r,
                        color_g = entry.color_g,
                        color_b = entry.color_b,
                        alpha = entry.alpha,
                        reflectance = entry.reflectance,
                        render_apply_part_tint = entry.render_apply_part_tint,
                        render_color_mode = entry.render_color_mode,
                        -- the group's immutable geometry already owns this
                        -- decode. keep that same handle for pose-only updates;
                        -- remote/LOD/provisional geometry still resolves live
                        mesh_data = entry.mesh_data == bucket.mesh_data
                            and rawget(part, "_remote_mesh_handle") == nil
                            and not (type(entry.mesh_data.render_lods) == "table"
                                and #entry.mesh_data.render_lods > 1)
                            and entry.mesh_data.source_kind ~= "csg_physics"
                            and entry.mesh_data or nil,
                        mesh_asset_revision = self._remote_mesh_asset_revision or 0,
                    }
                    part._instanced_has_decals = nil
                    -- release index, so destroy/promote reuse the row-zero machinery
                    stage[#stage + 1] = part._id
                    stage[#stage + 1] = group.instance_mesh
                    stage[#stage + 1] = i
                    stage[#stage + 1] = 1
                end
            end
        end
    end

    -- cluster by shader+uniform state so change-only sends collapse to a handful/frame, not 3/group
    for i = 1, #groups do
        local group = groups[i]
        group.state_sort_key = group.variant
            .. "|" .. (group.flip_u and "1" or "0") .. (group.flip_v and "1" or "0")
            .. "|" .. string.format("%.4f", group.depth_bias or 0)
            .. "|" .. tostring(group.cull_mode) .. (group.cull_swap and "s" or "")
            .. "|" .. group.key
    end
    table.sort(groups, function(a, b)
        return a.state_sort_key < b.state_sort_key
    end)
    return fallback_profile
end

function RBX:_shared_instance_pose_note_recovery_motion()
    local previous = self._instance_move_revision or 0
    if (self._shadow_instance_known_revision or 0) == previous then
        self._shadow_instance_known_revision = previous + 1
    end
    self._instance_move_revision = previous + 1
end

function RBX:_shared_instance_pose_note_uniform_motion()
    local previous = self._instance_move_revision or 0
    local revision = previous + 1
    -- the instance stream is intentionally unchanged, but the dedicated shader
    -- pose and conservative group bounds are complete for this revision. this
    -- preserves the retained static shadow command path without blessing a
    -- partial row upload
    self._instance_move_revision = revision
    self._shadow_instance_known_revision = revision
    self._shadow_instance_flushed_revision = revision
    return revision
end

function RBX:_shared_instance_pose_is_finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

function RBX:_shared_instance_pose_update_bounds(group, pose)
    local source = group.instance_bounds
    local count = math.max(0, math.floor(tonumber(group.count) or 0))
    if type(source) ~= "table" or #source < count * 6
        or type(group.bounds) ~= "table" then
        return false
    end
    local row0, row1, row2 = pose.row0, pose.row1, pose.row2
    local tx, ty, tz = pose.translation[1], pose.translation[2], pose.translation[3]
    local a00, a01, a02 = math.abs(row0[1]), math.abs(row0[2]), math.abs(row0[3])
    local a10, a11, a12 = math.abs(row1[1]), math.abs(row1[2]), math.abs(row1[3])
    local a20, a21, a22 = math.abs(row2[1]), math.abs(row2[2]), math.abs(row2[3])
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
    for row = 1, count do
        local offset = (row - 1) * 6
        local source_min_x, source_min_y, source_min_z = source[offset + 1], source[offset + 2], source[offset + 3]
        local source_max_x, source_max_y, source_max_z = source[offset + 4], source[offset + 5], source[offset + 6]
        if not (self:_shared_instance_pose_is_finite(source_min_x)
            and self:_shared_instance_pose_is_finite(source_min_y)
            and self:_shared_instance_pose_is_finite(source_min_z)
            and self:_shared_instance_pose_is_finite(source_max_x)
            and self:_shared_instance_pose_is_finite(source_max_y)
            and self:_shared_instance_pose_is_finite(source_max_z)) then
            return false
        end
        -- the common pose rotates each instance around its own center. Rotating
        -- the prior world AABB is conservative even for nonuniform/signed mesh
        -- scale and leaves culling, local-light selection and cascades safe
        local center_x = (source_min_x + source_max_x) * 0.5 + tx
        local center_y = (source_min_y + source_max_y) * 0.5 + ty
        local center_z = (source_min_z + source_max_z) * 0.5 + tz
        local extent_x = (source_max_x - source_min_x) * 0.5
        local extent_y = (source_max_y - source_min_y) * 0.5
        local extent_z = (source_max_z - source_min_z) * 0.5
        local rotated_x = a00 * extent_x + a01 * extent_y + a02 * extent_z
        local rotated_y = a10 * extent_x + a11 * extent_y + a12 * extent_z
        local rotated_z = a20 * extent_x + a21 * extent_y + a22 * extent_z
        min_x = math.min(min_x, center_x - rotated_x)
        min_y = math.min(min_y, center_y - rotated_y)
        min_z = math.min(min_z, center_z - rotated_z)
        max_x = math.max(max_x, center_x + rotated_x)
        max_y = math.max(max_y, center_y + rotated_y)
        max_z = math.max(max_z, center_z + rotated_z)
    end
    local bounds = group.bounds
    bounds.min_x, bounds.min_y, bounds.min_z = min_x, min_y, min_z
    bounds.max_x, bounds.max_y, bounds.max_z = max_x, max_y, max_z
    finalize_bounds(bounds)
    -- a moved group must never retain a prior negative frustum result
    group.frustum_visible = nil
    return true
end

-- Content may establish this only after proving that it owns every member of a
-- single fast group and that every public pose still follows one shared basis
-- the public CFrame writes continue unchanged, only their redundant GPU row
-- publication is replaced by a private, recoverable shader pose
function RBX:_begin_shared_instanced_group_pose(state, desired)
    if self._shared_instance_pose_supported ~= true
        or self._shared_instance_pose_write_group ~= nil
        or type(state) ~= "table" or type(desired) ~= "table" then
        return nil
    end
    local group = state.group
    local base = state.base_cframe
    local count = group and math.max(0, math.floor(tonumber(group.count) or 0)) or 0
    if type(group) ~= "table" or group.generation ~= (self._instance_generation or 0)
        or group.variant ~= "fast" or group.projected ~= nil or group.light_cell_key ~= nil
        or count < 2 or state.member_count ~= count or type(state.members) ~= "table"
        or type(state.member_lookup) ~= "table" or type(base) ~= "table" then
        return nil
    end
    if state.pose_epoch ~= (group._shared_instance_pose_epoch or 0) then
        return nil
    end
    local pose = group._shared_instance_pose
    if pose and pose.state ~= state then
        self:_clear_shared_instanced_group_pose(group, true)
        return nil
    end
    if not pose then
        pose = {
            state = state,
            members = state.members,
            member_lookup = state.member_lookup,
            member_count = count,
            translation = { 0, 0, 0 },
            row0 = { 1, 0, 0 }, row1 = { 0, 1, 0 }, row2 = { 0, 0, 1 },
            seen = {}, written_members = {}, written_count = 0,
        }
        group._shared_instance_pose = pose
    end
    local b00, b01, b02 = base.r00, base.r01, base.r02
    local b10, b11, b12 = base.r10, base.r11, base.r12
    local b20, b21, b22 = base.r20, base.r21, base.r22
    local d00, d01, d02 = desired.r00, desired.r01, desired.r02
    local d10, d11, d12 = desired.r10, desired.r11, desired.r12
    local d20, d21, d22 = desired.r20, desired.r21, desired.r22
    if not (self:_shared_instance_pose_is_finite(b00) and self:_shared_instance_pose_is_finite(b01)
        and self:_shared_instance_pose_is_finite(b02) and self:_shared_instance_pose_is_finite(b10)
        and self:_shared_instance_pose_is_finite(b11) and self:_shared_instance_pose_is_finite(b12)
        and self:_shared_instance_pose_is_finite(b20) and self:_shared_instance_pose_is_finite(b21)
        and self:_shared_instance_pose_is_finite(b22) and self:_shared_instance_pose_is_finite(d00)
        and self:_shared_instance_pose_is_finite(d01) and self:_shared_instance_pose_is_finite(d02)
        and self:_shared_instance_pose_is_finite(d10) and self:_shared_instance_pose_is_finite(d11)
        and self:_shared_instance_pose_is_finite(d12) and self:_shared_instance_pose_is_finite(d20)
        and self:_shared_instance_pose_is_finite(d21) and self:_shared_instance_pose_is_finite(d22)
        and self:_shared_instance_pose_is_finite(desired.x) and self:_shared_instance_pose_is_finite(desired.y)
        and self:_shared_instance_pose_is_finite(desired.z)
        and self:_shared_instance_pose_is_finite(state.base_translation_x)
        and self:_shared_instance_pose_is_finite(state.base_translation_y)
        and self:_shared_instance_pose_is_finite(state.base_translation_z)) then
        self:_clear_shared_instanced_group_pose(group, false)
        return nil
    end
    -- desired_rotation * inverse(base_rotation), CFrame matrices are row-major
    pose.row0[1] = d00 * b00 + d01 * b01 + d02 * b02
    pose.row0[2] = d00 * b10 + d01 * b11 + d02 * b12
    pose.row0[3] = d00 * b20 + d01 * b21 + d02 * b22
    pose.row1[1] = d10 * b00 + d11 * b01 + d12 * b02
    pose.row1[2] = d10 * b10 + d11 * b11 + d12 * b12
    pose.row1[3] = d10 * b20 + d11 * b21 + d12 * b22
    pose.row2[1] = d20 * b00 + d21 * b01 + d22 * b02
    pose.row2[2] = d20 * b10 + d21 * b11 + d22 * b12
    pose.row2[3] = d20 * b20 + d21 * b21 + d22 * b22
    pose.translation[1] = desired.x - state.base_translation_x
    pose.translation[2] = desired.y - state.base_translation_y
    pose.translation[3] = desired.z - state.base_translation_z
    if not self:_shared_instance_pose_update_bounds(group, pose) then
        self:_clear_shared_instanced_group_pose(group, false)
        return nil
    end
    for index = 1, pose.written_count do
        pose.seen[pose.written_members[index]] = nil
        pose.written_members[index] = nil
    end
    pose.written_count = 0
    pose.write_open = true
    pose.active = true
    self._shared_instance_pose_write_group = group
    return pose
end

function RBX:_end_shared_instanced_group_pose(pose, complete)
    local group = self._shared_instance_pose_write_group
    if type(group) ~= "table" or group._shared_instance_pose ~= pose then
        return false
    end
    self._shared_instance_pose_write_group = nil
    pose.write_open = false
    if complete ~= true or pose.written_count ~= pose.member_count then
        self:_clear_shared_instanced_group_pose(group, true)
        return false
    end
    if pose.written_count > 0 then
        self:_shared_instance_pose_note_uniform_motion()
        self._shared_instance_pose_update_count =
            (self._shared_instance_pose_update_count or 0) + 1
        self._shared_instance_pose_skipped_rows =
            (self._shared_instance_pose_skipped_rows or 0) + pose.written_count
    end
    return true
end

function RBX:_clear_shared_instanced_group_pose(group, recover_rows)
    local pose = type(group) == "table" and group._shared_instance_pose
    if type(pose) ~= "table" then return false end
    if self._shared_instance_pose_write_group == group then
        self._shared_instance_pose_write_group = nil
    end
    group._shared_instance_pose = nil
    group._shared_instance_pose_epoch =
        (group._shared_instance_pose_epoch or 0) + 1
    pose.active, pose.write_open = false, false
    local queued = false
    if recover_rows == true then
        local dirty = self._dirty_instance_rows
        if not dirty then dirty = {};self._dirty_instance_rows = dirty end
        for index = 1, #(pose.members or {}) do
            local part = pose.members[index]
            local ref = part and part._instanced_ref
            if ref and ref.group == group
                and ref.generation == (self._instance_generation or 0)
                and ref.prop_revision == (part._render_prop_revision or 0) then
                dirty[part] = ref
                queued = true
            end
        end
    end
    if queued then
        self:_shared_instance_pose_note_recovery_motion()
        self._shared_instance_pose_recovery_count =
            (self._shared_instance_pose_recovery_count or 0) + 1
    end
    return queued
end

-- moved instanced part just re-uploads its row: no promotion/chunk/rebuild, true=handled. decal
-- carriers (fast=false) return false so normal promotion still zeroes their decal ranges + row
function RBX:_note_instanced_part_moved(part)
    local ref = part._instanced_ref
    if not ref or ref.fast ~= true or ref.generation ~= (self._instance_generation or 0) then
        return false
    end
    local group = ref.group
    local pose = group and group._shared_instance_pose
    -- non-pose write since group build: row/group state stale, fall through to full-dirty so the
    -- next sync re-bakes/re-buckets
    if ref.prop_revision ~= (part._render_prop_revision or 0) then
        if pose then self:_clear_shared_instanced_group_pose(group, true) end
        return false
    end
    if self._shared_instance_pose_write_group == group and pose
        and pose.write_open == true and pose.member_lookup and pose.member_lookup[part] then
        if pose.seen[part] then
            self:_clear_shared_instanced_group_pose(group, true)
            return false
        end
        local next_count = pose.written_count + 1
        if next_count > pose.member_count then
            self:_clear_shared_instanced_group_pose(group, true)
            return false
        end
        pose.seen[part] = true
        pose.written_members[next_count] = part
        pose.written_count = next_count
        return true
    end
    if pose then self:_clear_shared_instanced_group_pose(group, true) end
    local dirty = self._dirty_instance_rows
    if not dirty then
        dirty = {}
        self._dirty_instance_rows = dirty
    end
    dirty[part] = ref
    -- read by surface.needs_redraw: instanced motion never sets _parts_dirty/_scene_revision, so
    -- viewport hosts have no other way to know the frame changed
    local previous = self._instance_move_revision or 0
    if (self._shadow_instance_known_revision or 0) == previous then
        self._shadow_instance_known_revision = previous + 1
    end
    self._instance_move_revision = previous + 1
    return true
end

-- Color-only sibling of _note_instanced_part_moved: tint is per-row instance data, so a
-- recolor re-uploads one row instead of falling to a full re-bucket. runs inside the
-- Color setter BEFORE the shared revision bump, so the ref revision is pre-advanced to
-- match the bump that lands right after (same-frame moves then stay on the fast path)
function RBX:_note_instanced_part_recolored(part)
    local ref = part._instanced_ref
    if not ref or ref.fast ~= true or ref.generation ~= (self._instance_generation or 0) then
        return false
    end
    if ref.group and ref.group._shared_instance_pose then
        self:_clear_shared_instanced_group_pose(ref.group, true)
    end
    if ref.prop_revision ~= (part._render_prop_revision or 0) then
        return false -- another non-pose write already queued a full re-bucket
    end
    local color_options = nil
    if ref.render_color_mode == "ignore_mesh_vertex_color" then
        color_options = IGNORE_MESH_VERTEX_COLOR_OPTIONS
    elseif ref.render_color_mode == "mesh_texture_uses_vertex_color" then
        color_options = MESH_TEXTURE_VERTEX_COLOR_OPTIONS
    end
    local apply_part_tint = ref.render_apply_part_tint
    if apply_part_tint == nil then
        apply_part_tint = true
    end
    ref.color_r, ref.color_g, ref.color_b =
        get_runtime_render_color(part, apply_part_tint, color_options)
    ref.prop_revision = ref.prop_revision + 1
    local dirty = self._dirty_instance_rows
    if not dirty then
        dirty = {}
        self._dirty_instance_rows = dirty
    end
    dirty[part] = ref
    local previous = self._instance_move_revision or 0
    if (self._shadow_instance_known_revision or 0) == previous then
        self._shadow_instance_known_revision = previous + 1
    end
    self._instance_move_revision = previous + 1
    return true
end

function RBX:_flush_dirty_instance_rows()
    local dirty = self._dirty_instance_rows
    if not dirty or next(dirty) == nil then
        return
    end
    self._dirty_instance_rows = {}
    local scratch_row = self._instance_row_scratch
    if not scratch_row then
        scratch_row = {}
        self._instance_row_scratch = scratch_row
    end
    local rows_wrapper = self._instance_rows_wrapper
    if not rows_wrapper then
        rows_wrapper = { scratch_row }
        self._instance_rows_wrapper = rows_wrapper
    end
    local updated = 0
    local complete = true
    local upload_failure
    local motion_revision = self._instance_move_revision or 0
    -- a group is rescanned at most once per flush, and only when a row that
    -- owned one of its six extrema moved inward. non-extremal movement and
    -- outward growth stay O(1)
    local exact_bounds_groups = {}
    local pending_group_uploads = {}
    local uploaded_rows, upload_calls = 0, 0
    local upload_started_at = love.timer.getTime()
    for part, ref in pairs(dirty) do
        if not part._destroyed
            and part._instanced_ref == ref
            and ref.generation == (self._instance_generation or 0)
            and ref.prop_revision == (part._render_prop_revision or 0) then
            local mesh_data = ref.mesh_data
            if not mesh_data or rawget(part, "_remote_mesh_handle") ~= nil
                or ref.mesh_asset_revision ~= (self._remote_mesh_asset_revision or 0) then
                mesh_data = self:_get_or_parse_part_mesh(part)
            end
            local transform = mesh_data and self:_get_mesh_instance_render_transform(part, mesh_data) or nil
            if transform then
                local light_cell_key =
                    RBX._get_instanced_mesh_light_cell_key(
                        self, transform)
                if light_cell_key ~= ref.group.light_cell_key then
                    -- a light cell is part of the bucket identity. Moving a
                    -- row across that boundary must rebucket it, merely
                    -- expanding the old group's bounds recreates the
                    -- scene-wide top-four lighting error
                    mark_parts_dirty(self)
                    transform = nil
                end
            end
            if transform then
                rbx_pack_mesh_instance_row(scratch_row, transform,
                    ref.color_r, ref.color_g, ref.color_b, ref.alpha, ref.reflectance,
                    part._contact_ao_top or 0, part._contact_ao_bottom or 0,
                    part._contact_ao_side or 0, part._contact_ao_max or 0)
                rows_wrapper[1] = scratch_row
                -- invalidate before the fallible write, never bless a partial upload
                ref.group.vertex_alpha_is_one = false
                ref.group._shadow_content_revision = (ref.group._shadow_content_revision or 0) + 1
                self._shadow_instance_flushed_revision = nil
                local group = ref.group
                local ok, upload_error
                if type(group.rows) == 'table' then
                    -- keep all 27 lanes for untouched rows as well. Upload one
                    -- changed span per group: separate tiny writes otherwise
                    -- synchronize with the preceding instanced draw repeatedly
                    local target = group.rows[ref.row]
                    if not target then target = {};group.rows[ref.row] = target end
                    for lane = 1, 27 do target[lane] = scratch_row[lane] end
                    local span = pending_group_uploads[group]
                    if not span then
                        span = {first=ref.row,last=ref.row};pending_group_uploads[group] = span
                    else
                        span.first = math.min(span.first,ref.row)
                        span.last = math.max(span.last,ref.row)
                    end
                    ok = true
                else
                    -- older external groups do not own a retained CPU row set
                    ok, upload_error = pcall(group.instance_mesh.setVertices,
                        group.instance_mesh, rows_wrapper, ref.row)
                    if ok then uploaded_rows=uploaded_rows+1;upload_calls=upload_calls+1 end
                end
                if ok then
                    updated = updated + 1
                    local part_bounds = self:_get_part_render_bounds(part, transform)
                    local instance_bounds = group.instance_bounds
                    local bounds = group.bounds
                    if type(instance_bounds) == "table" and type(bounds) == "table" then
                        local bounds_offset = (ref.row - 1) * 6
                        local old_min_x = instance_bounds[bounds_offset + 1]
                        local old_min_y = instance_bounds[bounds_offset + 2]
                        local old_min_z = instance_bounds[bounds_offset + 3]
                        local old_max_x = instance_bounds[bounds_offset + 4]
                        local old_max_y = instance_bounds[bounds_offset + 5]
                        local old_max_z = instance_bounds[bounds_offset + 6]

                        instance_bounds[bounds_offset + 1] = part_bounds.min_x
                        instance_bounds[bounds_offset + 2] = part_bounds.min_y
                        instance_bounds[bounds_offset + 3] = part_bounds.min_z
                        instance_bounds[bounds_offset + 4] = part_bounds.max_x
                        instance_bounds[bounds_offset + 5] = part_bounds.max_y
                        instance_bounds[bounds_offset + 6] = part_bounds.max_z

                        local may_shrink =
                            (old_min_x == bounds.min_x and part_bounds.min_x > old_min_x)
                            or (old_min_y == bounds.min_y and part_bounds.min_y > old_min_y)
                            or (old_min_z == bounds.min_z and part_bounds.min_z > old_min_z)
                            or (old_max_x == bounds.max_x and part_bounds.max_x < old_max_x)
                            or (old_max_y == bounds.max_y and part_bounds.max_y < old_max_y)
                            or (old_max_z == bounds.max_z and part_bounds.max_z < old_max_z)
                        if may_shrink then
                            exact_bounds_groups[group] = true
                        elseif exact_bounds_groups[group] ~= true then
                            expand_bounds_with_bounds(bounds, part_bounds)
                            finalize_bounds(bounds)
                        end
                    else
                        -- Compatibility for a group created before the exact
                        -- per-row cache existed (or by an external test/tool)
                        expand_bounds_with_bounds(group.bounds, part_bounds)
                        finalize_bounds(group.bounds)
                    end
                    -- a moved row can enter the frustum before the next full cull re-tests the
                    -- group, nil = drawn, so motion never leaves a group wrongly invisible
                    group.frustum_visible = nil
                else
                    -- Retry all queued rows: earlier writes may already have succeeded
                    upload_failure = upload_failure or upload_error
                end
            else
                complete = false
            end
        else
            complete = false
        end
    end
    for group, span in pairs(pending_group_uploads) do
        local rows = group._row_upload_scratch
        if not rows then rows = {};group._row_upload_scratch = rows end
        local count = span.last-span.first+1
        for index=1,count do rows[index]=group.rows[span.first+index-1] end
        for index=#rows,count+1,-1 do rows[index]=nil end
        local ok, upload_error = pcall(group.instance_mesh.setVertices,
            group.instance_mesh,rows,span.first)
        if ok then
            uploaded_rows=uploaded_rows+count;upload_calls=upload_calls+1
        else upload_failure=upload_failure or upload_error end
    end
    for group in pairs(exact_bounds_groups) do
        local instance_bounds = group.instance_bounds
        local bounds = group.bounds
        bounds.min_x, bounds.min_y, bounds.min_z = math.huge, math.huge, math.huge
        bounds.max_x, bounds.max_y, bounds.max_z = -math.huge, -math.huge, -math.huge
        for bounds_offset = 1, #instance_bounds, 6 do
            bounds.min_x = math.min(bounds.min_x, instance_bounds[bounds_offset])
            bounds.min_y = math.min(bounds.min_y, instance_bounds[bounds_offset + 1])
            bounds.min_z = math.min(bounds.min_z, instance_bounds[bounds_offset + 2])
            bounds.max_x = math.max(bounds.max_x, instance_bounds[bounds_offset + 3])
            bounds.max_y = math.max(bounds.max_y, instance_bounds[bounds_offset + 4])
            bounds.max_z = math.max(bounds.max_z, instance_bounds[bounds_offset + 5])
        end
        finalize_bounds(bounds)
    end
    if upload_failure then
        -- finish bounds for successful rows before propagating. a retry must not
        -- lose a pending extrema rescan, or any newer queued owner
        for part, ref in pairs(dirty) do
            if self._dirty_instance_rows[part] == nil then self._dirty_instance_rows[part] = ref end
        end
        error(upload_failure, 0)
    end
    if complete and self._shadow_instance_known_revision == motion_revision
        and (self._instance_move_revision or 0) == motion_revision then
        self._shadow_instance_flushed_revision = motion_revision
    end
    if updated > 0 then
        self._instance_transform_update_count = (self._instance_transform_update_count or 0) + updated
        self._instance_row_upload_last_ms = (love.timer.getTime() - upload_started_at) * 1000
        local bytes = uploaded_rows * 27 * 4
        self._instance_row_upload_bytes = (self._instance_row_upload_bytes or 0) + bytes
        self._instance_row_upload_call_count = (self._instance_row_upload_call_count or 0) + upload_calls
        self._instance_row_uploaded_rows = (self._instance_row_uploaded_rows or 0) + uploaded_rows
        if self._note_gpu_upload_bytes then self:_note_gpu_upload_bytes(bytes) end
        self:_invalidate_dynamic_visible_cache()
    end
end

function RBX:_sync_runtime_parts(force_rebuild, checkpoint)
    if not force_rebuild and not self._parts_dirty then
        return
    end

    if not force_rebuild and not checkpoint and self._parts_dirty_mode == "transform" then
        -- pool the per-vertex tables re-baked chunks throw away each frame = dominant move-time GC
        rbx_dynamic_vtx_pool_begin()
        self:_sync_runtime_part_transforms()
        rbx_dynamic_vtx_pool_end()
        return
    end

    -- Remote workers may publish while an async full build is suspended at a
    -- checkpoint. keep a per-build observation ledger so publication fanout
    -- cannot promote a half-classified part, and so the commit acknowledges
    -- only meshes this build actually consumed. a publication that arrived
    -- after its part was visited remains queued for ordinary incremental
    -- promotion once the build commits
    local async_full_build = self._is_async_map_building
        and self:_is_async_map_building()
    local remote_mesh_full_build_seen = async_full_build
        and self._remote_mesh_full_build_seen or nil
    if async_full_build
        and type(remote_mesh_full_build_seen) ~= "table" then
        remote_mesh_full_build_seen = {}
        self._remote_mesh_full_build_seen = remote_mesh_full_build_seen
    end
    local full_sync_start = love.timer.getTime()
    self._load_stage_times = self._load_stage_times or {}
    -- full rebuilds replace every scene mesh. raw LOVE meshes need explicit
    -- retirement just as much as backend-owned batches, otherwise one edit can
    -- leave an entire old map generation resident until a later GC
    local generation_release_start = love.timer.getTime()
    self:_release_scene_mesh_generation()
    self._load_stage_times.scene_generation_release = math.max(
        0, love.timer.getTime() - generation_release_start)
    -- release backend ownership after the raw traversal has skipped and marked
    -- its aliases, category-local builders must not reset the whole backend
    -- because siblings may already have been built for the new generation
    local backend_reset_start = love.timer.getTime()
    if self._render_backend and self._render_backend.reset then
        local reset_ok, reset_error = pcall(
            self._render_backend.reset, self._render_backend)
        if not reset_ok then
            self:_note_render_backend_error("reset scene batch generation", reset_error)
        end
    end
    self._load_stage_times.scene_backend_reset = math.max(
        0, love.timer.getTime() - backend_reset_start)
    self._mega_cube_batch = nil
    self._mega_dynamic_cube_batch = nil
    self._mega_instance_mesh = nil
    self._mega_cube_draw_mesh = nil
    self._mega_instance_count = 0
    self._mega_cube_handedness = "collapsed"
    self._mega_cube_batch_key = "Block|0"
    self._mega_cube_path_active = false
    self._mega_primitive_instance_count = 0
    self._mega_primitive_path_active = false
    self._mega_dynamic_instance_mesh = nil
    self._mega_dynamic_cube_draw_mesh = nil
    self._mega_dynamic_instance_count = 0
    self._mega_dynamic_instance_capacity = 0
    self._mega_dynamic_cube_handedness = "collapsed"
    self._mega_dynamic_cube_batch_key = "Block|0"
    self._primitive_instanced_batch_count = 0
    self._primitive_instanced_object_count = 0

    self._debug_sync_counts = self._debug_sync_counts or {}
    self._debug_sync_counts.full = (self._debug_sync_counts.full or 0) + 1
    self._debug_last_sync_mode = force_rebuild and "force_full" or "full"

    -- full rebuild re-bakes appearance-promoted parts statically with their current
    -- look, so the promotion flag self-heals here (see mark_runtime_part_draw_dirty)
    do
        local promoted = self._appearance_promoted_parts
        if promoted then
            for _, promoted_part in pairs(promoted) do
                promoted_part._appearance_dynamic = nil
            end
            self._appearance_promoted_parts = nil
            self._appearance_promoted_count = 0
        end
    end

    local scene_sync_start = love.timer.getTime()
    self._load_stage_times.scene_sync_preamble = math.max(
        0, scene_sync_start - full_sync_start)
    -- per-build token: _collect_part_face_textures memoizes within one rebuild, else it recomputes
    -- twice per opaque part (decal pass + face-decal pass). bumping invalidates stale caches
    self._face_texture_collect_token = (self._face_texture_collect_token or 0) + 1
    -- timing individual faces adds a clock read to each build step
    self._face_layer_build_profile = self.collect_hotspot_stats and {} or nil
    local profile_load_hotspots = self._face_layer_build_profile ~= nil
    local collect_scene_build_diagnostics = self.collect_hotspot_stats == true
    local material_fallback_diagnostic_limit = 64
    local _preloop_alloc_start = profile_load_hotspots
        and collectgarbage("count") or nil
    -- Contact-AO resolves exact mesh bounds before the classifier asks for the
    -- same local geometry through its material/instancing/decal routes. Carry
    -- only positive local results across this one full-build transaction
    local full_build_mesh_resolution_memo =
        self._begin_full_build_mesh_resolution_memo
        and self:_begin_full_build_mesh_resolution_memo() or nil
    if self._rebuild_contact_separation_cache then
        self:_rebuild_contact_separation_cache(checkpoint)
    end
    self._mesh_uploads_this_build = 0
    if self._reset_static_textured_index_stats then
        self:_reset_static_textured_index_stats()
    end
    -- Resolved generic textured-batch keys are valid only for this full-build
    -- configuration. Individual dynamic chunks may reuse the resulting keys
    -- after commit, while the next rebuild derives them again from live state
    self._part_material_resolved_batch_keys = {}
    local static_textured_spatial_pages_active,
        static_textured_spatial_page_inactive_reason =
        self:_static_textured_spatial_page_mode_status()
    self._static_textured_spatial_pages_active =
        static_textured_spatial_pages_active == true
    self._static_textured_spatial_page_inactive_reason =
        static_textured_spatial_page_inactive_reason
    local static_textured_spatial_page_stats = {
        enabled = self.enable_static_textured_spatial_pages ~= false,
        active = static_textured_spatial_pages_active == true,
        inactive_reason = static_textured_spatial_page_inactive_reason,
        max_source_rows_per_exact_page =
            RBX.STATIC_TEXTURED_SPATIAL_PAGE_MAX_SOURCE_ROWS,
        chunk_count = 0,
        source_batch_count = 0,
        compatibility_batch_count = 0,
        page_count = 0,
        base_page_count = 0,
        overlay_page_count = 0,
        menori_owned_page_count = 0,
        raw_flat_page_count = 0,
        cell_bounded_flat_fallback_page_count = 0,
        failure_count = 0,
        suppressed_page_count = 0,
        max_source_rows = 0,
    }
    self._static_textured_spatial_page_stats =
        static_textured_spatial_page_stats
    self._surface_detail_cache_hits_this_build = 0
    self._surface_detail_cache_misses_this_build = 0
    self._surface_detail_combined_normal_cache_hits = 0
    self._surface_detail_combined_normal_cache_misses = 0
    self._surface_appearance_stats_build_token =
        (self._surface_appearance_stats_build_token or 0) + 1
    self._surface_appearance_stats = {
        resolved_mesh_part_count = 0,
        color_map_count = 0,
        data_map_count = 0,
        transparent_blend_count = 0,
        opaque_cutout_count = 0,
        texture_pack_unsupported_count = 0,
        texture_pack_unsupported_examples = {},
        unsupported_texture_pack_only_count = 0,
        unsupported_texture_pack_examples = {},
    }
    if force_rebuild then
        self._mesh_uploads_total = 0
        self._union_mesh_uploads = 0
    end

    local chunk_map = {}
    local chunk_list = {}
    local mega_static_shape_instances = {}
    local mega_static_shape_instance_part_ids = {}
    local mega_textured_batch_map = {}
    local mega_overlay_textured_batch_map = {}
    -- fresh range-tracking state for this build (see _flush_part_static_ranges)
    self._static_part_tracked = {}
    self._static_part_geo = nil
    self._range_static_stage = nil
    self._range_track_log = nil
    -- bump makes every prior part._instanced_ref inert (moved-row writes + promotion skips check it)
    self._instance_generation = (self._instance_generation or 0) + 1
    self._dirty_instance_rows = nil
    self._shadow_instance_known_revision = self._instance_move_revision or 0
    self._shadow_instance_flushed_revision = self._instance_move_revision or 0
    local instanced_buckets = {}
    local instanced_bucket_order = {}
    local instancing_fallbacks = {}
    -- locked textured-mega config only: groups draw scene-wide like the locked mega lists, and
    -- that's cull-equivalent only there (occlusion/adaptive-off configs stay fully baked)
    local mesh_instancing_active = self.mesh_instancing == true
        and self.enable_occlusion_culling ~= true
        and self.adaptive_mega_batch ~= false
        and self.constant_fragment_shader ~= true
    local unique_colors = {}
    local live_part_count = 0
    local mesh_rendered_count = 0
    local material_rendered_count = 0
    local material_fallback_count = 0
    local plastic_fallback_count = 0
    local material_fallback_events = {}
    local zfight_risk_count = 0
    local missing_mesh_count = 0
    local missing_union_mesh_count = 0
    local union_fallback_count = 0
    local total_cube_instances = 0
    local opaque_static_batch_count = 0
    local textured_batch_count = 0
    local transparent_draw_count = 0
    local transparent_static_batch_count = 0
    local transparent_static_batched_part_count = 0
    local surface_gui_count = 0
    local surface_gui_entries = {}
    local billboard_gui_count = 0
    local billboard_entries = {}
    local total_opaque_part_count = 0
    local total_transparent_part_count = 0
    local total_glass_part_count = 0
    local zero_alpha_base_geometry_elided_count = 0
    local scene_bounds = {
        min_x = math.huge,
        min_y = math.huge,
        min_z = math.huge,
        max_x = -math.huge,
        max_y = -math.huge,
        max_z = -math.huge,
    }

    local function is_plain_plastic_material_token(token)
        local material = math.floor((tonumber(token) or 0) + 0.5)
        return material == 0 or material == 256 or material == 272
    end

    local function record_material_fallback(part, reason, material_token, has_part_texture)
        if not collect_scene_build_diagnostics
            or #material_fallback_events >= material_fallback_diagnostic_limit then
            return
        end
        local texture_id = part and (part.TextureContent or part.TextureId)
        local is_true_plastic = reason == "true_plastic_or_untextured_primitive"
            and is_plain_plastic_material_token(material_token)
            and has_part_texture ~= true
        local event = {
            id = part and part._id,
            name = part and part.Name,
            class_name = part and part.ClassName,
            material = material_token,
            texture_id = texture_id,
            reason = reason,
            has_part_texture = has_part_texture == true,
            true_plastic = is_true_plastic,
        }
        material_fallback_events[#material_fallback_events + 1] = event
    end

    local function bounds_overlap_amount(a_min, a_max, b_min, b_max)
        return math.min(a_max, b_max) - math.max(a_min, b_min)
    end

    local function bounds_axis_gap(a_min, a_max, b_min, b_max)
        if a_max < b_min then
            return b_min - a_max
        end
        if b_max < a_min then
            return a_min - b_max
        end
        return 0
    end

    local function part_bounds_have_near_coplanar_risk(a, b)
        if type(a) ~= "table" or type(b) ~= "table" then
            return false
        end
        local epsilon = math.max(0.0005, tonumber(self.zfight_risk_epsilon) or 0.01)
        local overlap_x = bounds_overlap_amount(a.min_x, a.max_x, b.min_x, b.max_x)
        local overlap_y = bounds_overlap_amount(a.min_y, a.max_y, b.min_y, b.max_y)
        local overlap_z = bounds_overlap_amount(a.min_z, a.max_z, b.min_z, b.max_z)
        local gap_x = bounds_axis_gap(a.min_x, a.max_x, b.min_x, b.max_x)
        local gap_y = bounds_axis_gap(a.min_y, a.max_y, b.min_y, b.max_y)
        local gap_z = bounds_axis_gap(a.min_z, a.max_z, b.min_z, b.max_z)
        local span_x = math.max(0.001, math.min(a.max_x - a.min_x, b.max_x - b.min_x))
        local span_y = math.max(0.001, math.min(a.max_y - a.min_y, b.max_y - b.min_y))
        local span_z = math.max(0.001, math.min(a.max_z - a.min_z, b.max_z - b.min_z))
        return (gap_x <= epsilon and overlap_y > span_y * 0.15 and overlap_z > span_z * 0.15)
            or (gap_y <= epsilon and overlap_x > span_x * 0.15 and overlap_z > span_z * 0.15)
            or (gap_z <= epsilon and overlap_x > span_x * 0.15 and overlap_y > span_y * 0.15)
    end

    local function note_zfight_risk(chunk, part_bounds, part)
        if not collect_scene_build_diagnostics then
            return
        end
        if type(chunk) ~= "table" or type(part_bounds) ~= "table" then
            return
        end
        local probes = chunk._zfight_probe_parts
        if not probes then
            probes = {}
            chunk._zfight_probe_parts = probes
        end
        for probe_index = 1, #probes do
            local probe = probes[probe_index]
            if probe and probe.part ~= part and part_bounds_have_near_coplanar_risk(part_bounds, probe.bounds) then
                zfight_risk_count = zfight_risk_count + 1
                break
            end
        end
        if #probes < 96 then
            probes[#probes + 1] = {
                part = part,
                bounds = part_bounds,
            }
        end
    end

    -- Fine-grained stage sampling is a profiler concern, not renderer work
    -- the loop below has many probes per part/face, calling the platform clock
    -- for all 16k+ parts on every ordinary load adds measurable overhead while
    -- producing diagnostics nobody requested. keep the enclosing stage clocks
    -- accurate in every profile, but make the per-part probes allocation/C-call
    -- free unless the dedicated load-hotspot mode is requested
    local _lt = profile_load_hotspots
        and love.timer.getTime or function() return 0 end
    local c_bounds, c_chunk, c_mesh, c_material = 0, 0, 0, 0
    local c_partclass, c_instance, c_transp, c_body = 0, 0, 0, 0
    local c_transp_batch, c_finalize_sgui = 0, 0
    local c_finalize_face_layers, c_finalize_opaque_metrics = 0, 0
    local c_finalize_transparent_queue = 0
    local c_face_predicate, c_face_mesh = 0, 0
    local c_face_surface_primitive, c_face_block = 0, 0
    local n_face_mesh, n_face_surface_primitive, n_face_block = 0, 0, 0
    local profile_face_routes = profile_load_hotspots
    local _preloop_end = love.timer.getTime()
    local _classify_timing = self._get_async_map_checkpoint_state
        and self:_get_async_map_checkpoint_state(checkpoint)
    if _classify_timing then
        _classify_timing = {
            state = _classify_timing,
            suspended_seconds = _classify_timing.suspended_seconds,
            yield_count = _classify_timing.yield_count,
        }
    end
    local _preloop_alloc_end = profile_load_hotspots
        and collectgarbage("count") or nil
    local total_parts = #self.parts
    for i = 1, total_parts do
        if checkpoint and (i == 1 or i == total_parts or i % 24 == 0) then
            checkpoint("scene_parts", i, total_parts)
        end

        local part = self.parts[i]
        if part and not part._destroyed and part._workspace_active~=false then
            local _tbody = _lt()
            live_part_count = live_part_count + 1
            -- clear stale ref or it pins old GPU meshes + wrongly satisfies fast-path checks, fresh
            -- refs get assigned later in _build_instanced_mesh_groups. decal flag re-detected too
            part._instanced_ref = nil
            part._instanced_has_decals = nil
            part._static_geo_untracked = nil
            part._scene_chunk_key = nil
            -- every part folded into shared static geometry needs an ownership
            -- range.  incremental release currently consumes those ranges only
            -- for map-loaded parts, but CastShadow filtering also uses the index
            -- as its authoritative part -> GPU packet map.  Runtime-created
            -- anchored parts self-heal from their temporary dynamic chunk into
            -- this static build, so excluding them made their colour geometry
            -- render while their shadow caster silently disappeared
            local range_trackable = part._id ~= nil
                and not can_update_runtime_part_incrementally(self, part)
            self._range_track_log = range_trackable and range_track_log or nil
            local part_surface_guis = part.SurfaceGuis or EMPTY_SURFACE_GUIS
            if range_trackable and #part_surface_guis > 0 then
                -- surfacegui geometry rides its own batch/canvas state, not range-tracked
                part._static_geo_untracked = true
            end
            surface_gui_count = surface_gui_count + #part_surface_guis
            for surface_gui_index = 1, #part_surface_guis do
                local surface_gui = part_surface_guis[surface_gui_index]
                if type(surface_gui) == "table" then
                    surface_gui_entries[#surface_gui_entries + 1] = {
                        surface_gui = surface_gui,
                        part = part,
                        runtime_id = surface_gui.runtime_id,
                    }
                end
            end
            -- billboards keep their own list: no face geo, quads stream per frame in gui.lua
            local part_billboard_guis = part.BillboardGuis
            if type(part_billboard_guis) == "table" then
                billboard_gui_count = billboard_gui_count + #part_billboard_guis
                for billboard_index = 1, #part_billboard_guis do
                    local billboard_gui = part_billboard_guis[billboard_index]
                    if type(billboard_gui) == "table" then
                        billboard_entries[#billboard_entries + 1] = {
                            gui = billboard_gui,
                            part = part,
                            runtime_id = billboard_gui.runtime_id,
                        }
                    end
                end
            end
            local _tb = _lt()
            local part_bounds = self:_get_part_render_bounds(part)
            finalize_bounds(part_bounds)
            expand_bounds_with_bounds(scene_bounds, part_bounds)
            c_bounds = c_bounds + (_lt() - _tb)

            local part_width = math.max(0.001, part_bounds.max_x - part_bounds.min_x)
            local part_height = math.max(0.001, part_bounds.max_y - part_bounds.min_y)
            local part_depth = math.max(0.001, part_bounds.max_z - part_bounds.min_z)

            local _tp = _lt()
            local r = clamp(math.floor(part.Color.r * 255 + 0.5), 0, 255)
            local g = clamp(math.floor(part.Color.g * 255 + 0.5), 0, 255)
            local b = clamp(math.floor(part.Color.b * 255 + 0.5), 0, 255)
            -- RGB8 fits exactly in Lua's numeric mantissa. a packed number avoids
            -- allocating one formatted string per part solely for diagnostics
            unique_colors[r * 65536 + g * 256 + b] = true

            local surface_route =
                RBX._classify_part_full_material_route(part, self)
            local alpha = surface_route and surface_route.part_alpha
                or get_runtime_render_alpha(part)
            if alpha <= 0 then
                zero_alpha_base_geometry_elided_count =
                    zero_alpha_base_geometry_elided_count + 1
            end
            local is_transparent = surface_route and surface_route.blend
                or (surface_route == nil and alpha < 0.999)
            local is_glass_part = surface_route == nil
                and is_glass_material(part)
            if is_transparent then
                total_transparent_part_count = total_transparent_part_count + 1
                if is_glass_part then
                    total_glass_part_count = total_glass_part_count + 1
                end
            end
            local material_token = tonumber(part.Material) or 0
            local render_geometry_key = get_runtime_part_render_geometry_key(part)
            local is_block_shape = render_geometry_key == "Block"
            local part_center_x = (part_bounds.min_x + part_bounds.max_x) * 0.5
            local part_center_y = (part_bounds.min_y + part_bounds.max_y) * 0.5
            local part_center_z = (part_bounds.min_z + part_bounds.max_z) * 0.5
            c_partclass = c_partclass + (_lt() - _tp)
            local omit_invisible_base_part =
                alpha <= 0 and invisible_part_renders_nothing(part)
            local _ttr = nil
            if not omit_invisible_base_part then
            local _tc = _lt()
            local chunk = self:_get_or_create_part_scene_chunk(chunk_map, part, part_center_x, part_center_y,
                part_center_z)
            part._scene_chunk_key = chunk.key
            expand_bounds_with_bounds(chunk.bounds, part_bounds)
            if collect_scene_build_diagnostics then
                note_zfight_risk(chunk, part_bounds, part)
            end
            c_chunk = c_chunk + (_lt() - _tc)
            local part_volume = math.max(0.001, part_width * part_height * part_depth)

            local part_textured_batch_map = is_transparent and {} or chunk.opaque_textured_batch_map
            local material_batch_map = part_textured_batch_map
            local transparent_uses_chunk_textured_map = false
            local allow_block_fallback = not is_csg_part_class(part.ClassName)
                and not special_mesh_submits_no_render_geometry(part)
                and not legacy_mesh_asset_owns_geometry(part)

            local _tm = _lt()
            local mesh_rendered = false
            local part_instanced = false
            if RBX._part_has_renderable_mesh_source(part) then
                if mesh_instancing_active and range_trackable then
                    local bucketed, fallback_reason = try_bucket_instanced_mesh_part(
                        self, instanced_buckets, instanced_bucket_order, part, chunk, is_transparent)
                    if bucketed then
                        -- sets rendered so the fallback chain below stays closed, the decal branch
                        -- still runs (decals stay baked)
                        mesh_rendered = true
                        part_instanced = true
                        chunk.instanced_part_count = (chunk.instanced_part_count or 0) + 1
                    elseif fallback_reason then
                        instancing_fallbacks[fallback_reason] = (instancing_fallbacks[fallback_reason] or 0) + 1
                    end
                end
                if not mesh_rendered then
                    mesh_rendered = self:_append_mesh_part_batch(part_textured_batch_map, part)
                    if not mesh_rendered then
                        missing_mesh_count = missing_mesh_count + 1
                        if is_csg_part_class(part.ClassName) then
                            missing_union_mesh_count = missing_union_mesh_count + 1
                        end
                    end
                end
            end
            if is_csg_part_class(part.ClassName) and not mesh_rendered then
                allow_block_fallback = true
                union_fallback_count = union_fallback_count + 1
            end
            c_mesh = c_mesh + (_lt() - _tm)

            local _tmat = _lt()
            local material_rendered = false
            local material_batch_key = nil
            local has_part_texture = not RBX._is_empty_asset_reference(part.TextureContent)
                or not RBX._is_empty_asset_reference(part.TextureId)
            if is_transparent and not mesh_rendered then
                chunk.transparent_textured_batch_map = chunk.transparent_textured_batch_map or {}
                part_textured_batch_map = chunk.transparent_textured_batch_map
                material_batch_map = chunk.transparent_textured_batch_map
                transparent_uses_chunk_textured_map = true
            end
            if allow_block_fallback and not mesh_rendered and not has_part_texture then
                if mesh_instancing_active and range_trackable then
                    material_rendered, material_batch_key = self:_try_bucket_instanced_material_primitive(
                        instanced_buckets, instanced_bucket_order, part, chunk, is_transparent)
                    if material_rendered then
                        part_instanced = true
                        chunk.instanced_part_count = (chunk.instanced_part_count or 0) + 1
                    end
                end
                if not material_rendered then
                    material_rendered, material_batch_key =
                        self:_append_part_material_batch(material_batch_map, part)
                end
            end
            -- surface detail only when the part's own block geo renders: a mesh fully replaces geo,
            -- and any DataModelMesh child (BlockMesh etc) suppresses studs
            if allow_block_fallback and is_block_shape
                and not mesh_rendered and part.MeshOwner == nil then
                -- detail bakes into the static batch even for instanced parts, so it would freeze in
                -- world space on row-fast-path moves -- flag for promotion escape via range-log growth
                local detail_log_before = part_instanced and #range_track_log or 0
                self:_append_surface_detail_geometry_batch(material_batch_map, part)
                if part_instanced and #range_track_log > detail_log_before then
                    part._instanced_has_decals = true
                end
            end
            c_material = c_material + (_lt() - _tmat)

            local _ti = _lt()
            if mesh_rendered then
                mesh_rendered_count = mesh_rendered_count + 1
            elseif material_rendered then
                material_rendered_count = material_rendered_count + 1
            elseif not is_transparent and allow_block_fallback then
                if not is_plain_plastic_material_token(material_token) and not has_part_texture then
                    material_fallback_count = material_fallback_count + 1
                    record_material_fallback(part, "missing_material_descriptor", material_token, has_part_texture)
                elseif has_part_texture then
                    material_fallback_count = material_fallback_count + 1
                    record_material_fallback(part, "basepart_texture_without_renderable_mesh", material_token,
                        has_part_texture)
                else
                    plastic_fallback_count = plastic_fallback_count + 1
                    record_material_fallback(part, "true_plastic_or_untextured_primitive", material_token,
                        has_part_texture)
                end
                local instance = runtime_part_to_instance(part)
                local instance_handedness =
                    RBX._classify_closed_primitive_instance_row(instance)
                local cube_fast_path = is_block_shape
                    and instance_handedness == "positive"
                if cube_fast_path then
                    chunk.cube_instances[#chunk.cube_instances + 1] = instance
                    if range_trackable then
                        local ids = chunk.cube_instance_part_ids
                        if not ids then
                            ids = {}
                            chunk.cube_instance_part_ids = ids
                        end
                        ids[#chunk.cube_instances] = part._id
                    end
                    total_cube_instances = total_cube_instances + 1
                else
                    local batch_key = RBX._closed_primitive_batch_key(
                        render_geometry_key, instance_handedness)
                    local bucket = chunk.opaque_static_shape_instances[batch_key]
                    if not bucket then
                        bucket = {}
                        chunk.opaque_static_shape_instances[batch_key] = bucket
                    end
                    bucket[#bucket + 1] = instance
                    if range_trackable then
                        local ids_by_shape = chunk.opaque_static_shape_instance_part_ids
                        if not ids_by_shape then
                            ids_by_shape = {}
                            chunk.opaque_static_shape_instance_part_ids = ids_by_shape
                        end
                        local ids = ids_by_shape[batch_key]
                        if not ids then
                            ids = {}
                            ids_by_shape[batch_key] = ids
                        end
                        ids[#bucket] = part._id
                    end
                    if chunk.dynamic_chunk ~= true then
                        local mega_bucket = mega_static_shape_instances[batch_key]
                        if not mega_bucket then
                            mega_bucket = {}
                            mega_static_shape_instances[batch_key] = mega_bucket
                        end
                        mega_bucket[#mega_bucket + 1] = instance
                        if range_trackable then
                            local mega_ids = mega_static_shape_instance_part_ids[batch_key]
                            if not mega_ids then
                                mega_ids = {}
                                mega_static_shape_instance_part_ids[batch_key] = mega_ids
                            end
                            mega_ids[#mega_bucket] = part._id
                        end
                    end
                end
            end
            c_instance = c_instance + (_lt() - _ti)

            _ttr = _lt()
            if is_transparent then
                chunk.transparent_part_count = chunk.transparent_part_count + 1
                local _tface = profile_face_routes and _lt() or nil
                local _tpredicate = profile_face_routes and _lt() or nil
                local has_face_layers = RBX._part_has_face_layers(part)
                if profile_face_routes then
                    c_face_predicate = c_face_predicate
                        + (_lt() - _tpredicate)
                end
                if has_face_layers then
                    if mesh_rendered then
                        local _tappend = profile_face_routes and _lt() or nil
                        self:_append_mesh_face_decals(part_textured_batch_map, part)
                        if profile_face_routes then
                            c_face_mesh = c_face_mesh + (_lt() - _tappend)
                            n_face_mesh = n_face_mesh + 1
                        end
                    else
                        local _tappend = profile_face_routes and _lt() or nil
                        local used_surface_primitive =
                            self:_append_surface_primitive_face_decals(
                                part_textured_batch_map, part)
                        if profile_face_routes then
                            c_face_surface_primitive =
                                c_face_surface_primitive
                                + (_lt() - _tappend)
                        end
                        if used_surface_primitive then
                            if profile_face_routes then
                                n_face_surface_primitive =
                                    n_face_surface_primitive + 1
                            end
                        elseif allow_block_fallback then
                            _tappend = profile_face_routes and _lt() or nil
                            self:_append_part_face_decals(
                                part_textured_batch_map, part)
                            if profile_face_routes then
                                c_face_block = c_face_block
                                    + (_lt() - _tappend)
                                n_face_block = n_face_block + 1
                            end
                        end
                    end
                end
                if profile_face_routes then
                    c_finalize_face_layers = c_finalize_face_layers
                        + (_lt() - _tface)
                end

                local _tqueue = profile_face_routes and _lt() or nil
                if alpha > 0
                    and allow_block_fallback
                    and not mesh_rendered
                    and not material_rendered then
                    if range_trackable then
                        -- grouped transparent statics bake multi-part meshes, not range-tracked
                        part._static_geo_untracked = true
                    end
                    queue_chunk_transparent_static_part(
                        self,
                        chunk,
                        part,
                        i,
                        render_geometry_key,
                        part_bounds,
                        part_width,
                        part_height,
                        part_depth,
                        is_glass_part
                    )
                end
                if profile_face_routes then
                    c_finalize_transparent_queue =
                        c_finalize_transparent_queue
                        + (_lt() - _tqueue)
                end

                if not transparent_uses_chunk_textured_map then
                    local _ttb = _lt()
                    local capture_transparent_cpu =
                        self.enable_transparent_textured_range_aggregation ~= false
                        and chunk.dynamic_chunk ~= true
                    local part_batches = self:_build_textured_batches_from_map(
                        part_textured_batch_map,
                        nil,
                        nil,
                        capture_transparent_cpu,
                        false)
                    c_transp_batch = c_transp_batch + (_lt() - _ttb)
                    for j = 1, #part_batches do
                        local batch = part_batches[j]
                        local depth_bias, depth_compare = RBX._get_transparent_draw_depth_settings(self, batch)
                        local overlay_decal = batch.overlay_pass == true
                            or batch.source_kind == "SurfaceOverlay"
                            or batch.source_kind == "SurfaceGui"
                        chunk.transparent_draw_items[#chunk.transparent_draw_items + 1] = {
                        kind = "textured",
                        mesh = batch.mesh,
                        cpu_vertices = batch.cpu_vertices,
                        vertex_count = batch.vertex_count,
                        part_ranges = batch.part_ranges,
                        texture = batch.texture,
                        key = batch.key,
                        uniform_state_key =
                            RBX._transparent_textured_uniform_state_key(
                                batch.uniform_state_key or batch.key,
                                depth_bias,
                                depth_compare),
                        flip_v = batch.flip_v,
                        flip_u = batch.flip_u,
                        use_material_maps = batch.use_material_maps,
                        material_semantics_active =
                            batch.material_semantics_active == true,
                        material_surface = batch.material_surface,
                        material_map_mask = batch.material_map_mask,
                        use_textured_lighting = batch.use_textured_lighting,
                        light_influence = batch.light_influence,
                        brightness = batch.brightness,
                        use_normal_map = batch.use_normal_map,
                        normal_texture = batch.normal_texture,
                        detail_normal_texture = batch.detail_normal_texture,
                        detail_normal_mix = batch.detail_normal_mix,
                        detail_contrast = batch.detail_contrast,
                        texture_color_mix = batch.texture_color_mix,
                        texture_premultiplied =
                            batch.texture_premultiplied == true,
                        vertex_color_premultiplied =
                            batch.vertex_color_premultiplied == true,
                        roughness_texture = batch.roughness_texture,
                        metalness_texture = batch.metalness_texture,
                        depth_bias = depth_bias,
                        ignore_texture_alpha = batch.ignore_texture_alpha and true or false,
                        cull_mode = batch.cull_mode or "none",
                        mirror_cull_swap = batch.mirror_cull_swap ~= false,
                        force_cull = batch.force_cull == true,
                        resolved_cull_mode = batch.resolved_cull_mode,
                        depth_compare = depth_compare,
                        sort_x = batch.sort_x or part_center_x,
                        sort_y = batch.sort_y or part_center_y,
                        sort_z = batch.sort_z or part_center_z,
                        sort_id = part._id or i,
                        render_priority = batch.render_priority or 0,
                        bounds = batch.bounds or part_bounds,
                        source_part_id = part._id or i,
                        source_transparent_part = true,
                        is_glass_part = is_glass_part,
                        dynamic_chunk = chunk.dynamic_chunk == true,
                        shader_variant_id = batch.shader_variant_id
                            or (overlay_decal and "textured_overlay_decal" or "textured_transparent"),
                        uniform_layout_id = batch.uniform_layout_id or (overlay_decal and "overlay" or "fast"),
                        shader = batch.shader,
                        shader_counter_key = batch.shader_counter_key,
                        variant_counter_id = batch.variant_counter_id,
                        mesh_debug_mode = batch.mesh_debug_mode,
                        mesh_debug_mode_id = batch.mesh_debug_mode_id,
                        alpha_like = true,
                        uses_shader_discard = batch.uses_shader_discard == true,
                        source_kind = batch.source_kind,
                        overlay_pass = batch.overlay_pass == true,
                        surface_gui_ref = batch.surface_gui_ref,
                        surface_gui_part_ref = batch.surface_gui_part_ref,
                        surface_gui_z_offset = batch.surface_gui_z_offset,
                        surface_gui_order = batch.surface_gui_order,
                        surface_gui_face = batch.surface_gui_face,
                        surface_gui_runtime_id = batch.surface_gui_runtime_id,
                        surface_gui_max_distance = batch.surface_gui_max_distance,
                        surface_gui_face_world_x = batch.surface_gui_face_world_x,
                        surface_gui_face_world_y = batch.surface_gui_face_world_y,
                        surface_gui_face_world_z = batch.surface_gui_face_world_z,
                        surface_gui_face_normal_x = batch.surface_gui_face_normal_x,
                        surface_gui_face_normal_y = batch.surface_gui_face_normal_y,
                        surface_gui_face_normal_z = batch.surface_gui_face_normal_z,
                        mesh_part_count = batch.mesh_part_count or 0,
                        mesh_texture_hit_count = batch.mesh_texture_hit_count or 0,
                        mesh_texture_miss_count = batch.mesh_texture_miss_count or 0,
                        mesh_uv_missing_count = batch.mesh_uv_missing_count or 0,
                        mesh_doublesided_count = batch.mesh_doublesided_count or 0,
                        mesh_axis_conversion_count = batch.mesh_axis_conversion_count or 0,
                        mesh_winding_flip_count = batch.mesh_winding_flip_count or 0,
                        mesh_uv_flip_u_count = batch.mesh_uv_flip_u_count or 0,
                        mesh_uv_flip_v_count = batch.mesh_uv_flip_v_count or 0,
                        mesh_debug_axis_count = batch.mesh_debug_axis_count or 0,
                        mesh_debug_bounds_count = batch.mesh_debug_bounds_count or 0,
                        union_part_count = batch.union_part_count or 0,
                        union_material_part_count = batch.union_material_part_count or 0,
                        union_use_part_color_count = batch.union_use_part_color_count or 0,
                        union_smoothing_angle_used_count = batch.union_smoothing_angle_used_count or 0,
                        union_fallback_count = batch.union_fallback_count or 0,
                        surface_detail_face_count = batch.surface_detail_face_count or 0,
                        surface_studs_face_count = batch.surface_studs_face_count or 0,
                        surface_inlet_face_count = batch.surface_inlet_face_count or 0,
                        surface_universal_face_count = batch.surface_universal_face_count or 0,
                        surface_shader_face_count = batch.surface_shader_face_count or 0,
                        surface_geometry_face_count = batch.surface_geometry_face_count or 0,
                        surface_lod_geometry_count = batch.surface_lod_geometry_count or 0,
                        surface_lod_shader_count = batch.surface_lod_shader_count or 0,
                        surface_fallback_count = batch.surface_fallback_count or 0,
                        z_bias_overlay_count = batch.z_bias_overlay_count or 0,
                        z_bias_decal_count = batch.z_bias_decal_count or 0,
                        z_bias_surface_detail_count = batch.z_bias_surface_detail_count or 0,
                        specialmesh_count = batch.specialmesh_count or 0,
                        specialmesh_head_count = batch.specialmesh_head_count or 0,
                        specialmesh_axis_fixup_count = batch.specialmesh_axis_fixup_count or 0,
                        specialmesh_fallback_count = batch.specialmesh_fallback_count or 0,
                        }
                        local draw_item = chunk.transparent_draw_items[
                            #chunk.transparent_draw_items]
                        draw_item.texture_group_key = batch.texture_group_key
                        draw_item.normal_key = batch.normal_key
                        draw_item.detail_normal_key = batch.detail_normal_key
                        draw_item.remote_texture_handle =
                            batch.remote_texture_handle
                        draw_item.remote_normal_texture_handle =
                            batch.remote_normal_texture_handle
                        draw_item.remote_normal_texture_field =
                            batch.remote_normal_texture_field
                        RBX._copy_surface_appearance_fields(draw_item, batch)
                        self:_bind_copied_textured_item_remote_consumers(draw_item)
                    end
                end
            else
                local _tmetrics = profile_face_routes and _lt() or nil
                total_opaque_part_count = total_opaque_part_count + 1
                chunk.opaque_part_count = chunk.opaque_part_count + 1
                if not surface_route
                    or surface_route.route ~= "opaque_cutout" then
                    chunk.opaque_volume = chunk.opaque_volume + part_volume
                    chunk.opaque_face_area_xy = chunk.opaque_face_area_xy + (part_width * part_height)
                    chunk.opaque_face_area_xz = chunk.opaque_face_area_xz + (part_width * part_depth)
                    chunk.opaque_face_area_yz = chunk.opaque_face_area_yz + (part_height * part_depth)
                    add_chunk_occluder_candidate(
                        self,
                        chunk,
                        part,
                        part_bounds,
                        part_width,
                        part_height,
                        part_depth,
                        render_geometry_key,
                        allow_block_fallback,
                        mesh_rendered,
                        has_part_texture
                    )
                end
                if profile_face_routes then
                    c_finalize_opaque_metrics = c_finalize_opaque_metrics
                        + (_lt() - _tmetrics)
                end
                local _tface = profile_face_routes and _lt() or nil
                local _tpredicate = profile_face_routes and _lt() or nil
                local has_face_layers = RBX._part_has_face_layers(part)
                if profile_face_routes then
                    c_face_predicate = c_face_predicate
                        + (_lt() - _tpredicate)
                end
                if has_face_layers then
                    if mesh_rendered then
                        -- decals stay baked even for instanced parts, so a decal carrier must NOT take
                        -- the row-move fast path (decals would freeze in world space). range-log growth
                        -- detects it -> flag -> moves use normal promotion escape
                        local log_len_before = part_instanced and #range_track_log or 0
                        local _tappend = profile_face_routes and _lt() or nil
                        self:_append_mesh_face_decals(chunk.overlay_textured_batch_map, part)
                        if profile_face_routes then
                            c_face_mesh = c_face_mesh + (_lt() - _tappend)
                            n_face_mesh = n_face_mesh + 1
                        end
                        if part_instanced and #range_track_log > log_len_before then
                            part._instanced_has_decals = true
                        end
                    else
                        local _tappend = profile_face_routes and _lt() or nil
                        local used_surface_primitive =
                            self:_append_surface_primitive_face_decals(
                                chunk.overlay_textured_batch_map, part)
                        if profile_face_routes then
                            c_face_surface_primitive =
                                c_face_surface_primitive
                                + (_lt() - _tappend)
                        end
                        if used_surface_primitive then
                            if profile_face_routes then
                                n_face_surface_primitive =
                                    n_face_surface_primitive + 1
                            end
                        elseif allow_block_fallback then
                            _tappend = profile_face_routes and _lt() or nil
                            self:_append_part_face_decals(
                                chunk.overlay_textured_batch_map,
                                part,
                                nil,
                                nil,
                                chunk.opaque_textured_batch_map
                            )
                            if profile_face_routes then
                                c_face_block = c_face_block
                                    + (_lt() - _tappend)
                                n_face_block = n_face_block + 1
                            end
                        end
                    end
                end
                if profile_face_routes then
                    c_finalize_face_layers = c_finalize_face_layers
                        + (_lt() - _tface)
                end
            end
            end
            local _ft = _ttr and (_lt() - _ttr) or 0
            c_transp = c_transp + _ft
            if #part_surface_guis > 0 then c_finalize_sgui = c_finalize_sgui + _ft end
            if range_trackable then
                self:_flush_part_static_ranges(part)
            else
                self._range_track_log = nil
            end
            c_body = c_body + (_lt() - _tbody)
        end
    end
    self._range_track_log = nil
    -- must resolve while the per-chunk batch maps are still open: singletons late-append into the
    -- chunk map and land in the mega merge below
    if _classify_timing then
        -- one shared boundary partitions the existing initial window. Late
        -- grouping includes fallback baking/native uploads, not just CPU work
        -- no new per-part clocks or clocks on unbound live/synchronous builds
        local state = _classify_timing.state
        _classify_timing.traversal_wall_seconds =
            love.timer.getTime() - _preloop_end
        _classify_timing.traversal_suspended_seconds =
            state.suspended_seconds - _classify_timing.suspended_seconds
        _classify_timing.traversal_yield_count =
            state.yield_count - _classify_timing.yield_count
    end
    local late_fallback_profile = self:_build_instanced_mesh_groups(
        instanced_buckets, instanced_bucket_order, instancing_fallbacks)
    if _classify_timing and type(late_fallback_profile) == "table" then
        _classify_timing.late_fallback_material_wall = late_fallback_profile.material_wall
        _classify_timing.late_fallback_material_calls = late_fallback_profile.material_calls
        _classify_timing.late_fallback_mesh_wall = late_fallback_profile.mesh_wall
        _classify_timing.late_fallback_mesh_calls = late_fallback_profile.mesh_calls
    end
    self._range_track_log = nil
    self._instancing_fallback_reasons = instancing_fallbacks
    local _partsloop_end = love.timer.getTime()
    if _classify_timing
        and self:_get_async_map_checkpoint_state(checkpoint)
            == _classify_timing.state then
        local state = _classify_timing.state
        _classify_timing.state = nil
        _classify_timing.wall_seconds = math.max(0,
            _partsloop_end - _preloop_end)
        _classify_timing.suspended_seconds = state.suspended_seconds
            - _classify_timing.suspended_seconds
        _classify_timing.yield_count = state.yield_count
            - _classify_timing.yield_count
        _classify_timing.stage_times = self._load_stage_times
        -- keep private until async completion has proved this is the initial
        -- ready-scene window, not an aborted build or a later promotion scope
        if state.initial_classify_timing == nil then
            state.initial_classify_timing = _classify_timing
        else
            -- More than one checkpoint-bound scene scope is ambiguous, equal
            -- wall durations are not a unique build identity. Report no data
            state.initial_classify_timing = false
        end
    end
    local _partsloop_alloc_end = profile_load_hotspots
        and collectgarbage("count") or nil

    local total_constraints = #(self.constraints or {})
    for i = 1, total_constraints do
        if checkpoint and (i == 1 or i == total_constraints or i % 24 == 0) then
            checkpoint("scene_constraints", i, total_constraints)
        end

        local item = self:_build_constraint_draw_item(self.constraints[i], i)
        if item then
            local chunk = self:_get_or_create_scene_chunk(chunk_map, item.sort_x or 0, item.sort_y or 0, item.sort_z or 0)
            expand_bounds_with_bounds(chunk.bounds, item.bounds)
            expand_bounds_with_bounds(scene_bounds, item.bounds)
            chunk.transparent_draw_items[#chunk.transparent_draw_items + 1] = item
        end
    end

    local chunk_batch_start = love.timer.getTime()
    local chunk_total = 0
    for _ in pairs(chunk_map) do
        chunk_total = chunk_total + 1
    end

    local chunk_index = 0
    for _, chunk in pairs(chunk_map) do
        chunk_index = chunk_index + 1
        if checkpoint and (chunk_index == 1 or chunk_index == chunk_total or chunk_index % 8 == 0) then
            checkpoint("scene_chunks", chunk_index, chunk_total)
        end

        for batch_key, instances in pairs(chunk.opaque_static_shape_instances) do
            if #instances > 0 then
                local shape_name =
                    RBX._closed_primitive_shape_name_from_batch_key(batch_key)
                local shape_part_ids = chunk.opaque_static_shape_instance_part_ids
                    and chunk.opaque_static_shape_instance_part_ids[batch_key] or nil
                local item = self:_build_opaque_primitive_draw_item(
                    shape_name,
                    instances,
                    shape_part_ids,
                    {
                        allow_instancing = true,
                        dynamic_chunk = chunk.dynamic_chunk == true,
                        bounds = chunk.bounds,
                        track_ranges = chunk.dynamic_chunk ~= true,
                        batch_key = batch_key,
                    })
                if item then
                    item._scene_chunk_key = chunk.key
                    item._scene_chunk_grid_x = chunk.grid_x
                    item._scene_chunk_grid_y = chunk.grid_y
                    item._scene_chunk_grid_z = chunk.grid_z
                    chunk.opaque_static_draw_items[
                        #chunk.opaque_static_draw_items + 1] = item
                end
            end
        end

        table.sort(chunk.opaque_static_draw_items, function(a, b)
            return tostring(a.key) < tostring(b.key)
        end)

        local chunk_transparent_static_batches, chunk_transparent_static_parts =
            build_chunk_transparent_static_draw_items(self, chunk)
        local chunk_transparent_textured_batches, chunk_transparent_textured_parts =
            append_chunk_transparent_textured_draw_items(self, chunk)
        transparent_static_batch_count = transparent_static_batch_count + chunk_transparent_static_batches
            + chunk_transparent_textured_batches
        transparent_static_batched_part_count = transparent_static_batched_part_count + chunk_transparent_static_parts
            + chunk_transparent_textured_parts

        local chunk_has_textured_batches = batch_map_has_drawable_batches(chunk.opaque_textured_batch_map)
        local chunk_has_overlay_batches = batch_map_has_drawable_batches(chunk.overlay_textured_batch_map)
        chunk.textured_batches = {}
        chunk.overlay_textured_batches = {}
        chunk.has_opaque_geometry = (#chunk.cube_instances > 0)
            or (#chunk.opaque_static_draw_items > 0)
            or chunk_has_textured_batches
            or chunk_has_overlay_batches
            or (chunk.instanced_part_count or 0) > 0
        chunk.has_transparent_geometry = #chunk.transparent_draw_items > 0
        local bounds = finalize_bounds(chunk.bounds)
        chunk.occlusion_fill_ratio = aggregate_occlusion_fill_ratio(
            bounds,
            chunk.opaque_volume,
            chunk.opaque_face_area_xy,
            chunk.opaque_face_area_xz,
            chunk.opaque_face_area_yz
        )

        opaque_static_batch_count = opaque_static_batch_count + #chunk.opaque_static_draw_items
        transparent_draw_count = transparent_draw_count + #chunk.transparent_draw_items

        chunk.opaque_static_shape_instances = nil
        chunk.transparent_static_shape_instances = nil
        chunk.transparent_static_shape_groups = nil
        chunk.transparent_textured_batch_map = nil
        chunk.opaque_face_area_xy = nil
        chunk.opaque_face_area_xz = nil
        chunk.opaque_face_area_yz = nil
        chunk._zfight_probe_parts = nil
        chunk_list[#chunk_list + 1] = chunk
    end

    table.sort(chunk_list, function(a, b)
        return tostring(a.key) < tostring(b.key)
    end)

    if static_textured_spatial_pages_active then
        local layout_safe, layout_reason, layout_stats =
            self:_static_textured_spatial_page_layout_is_safe(chunk_list)
        for key, value in pairs(layout_stats or {}) do
            static_textured_spatial_page_stats[key] = value
        end
        if not layout_safe then
            static_textured_spatial_pages_active = false
            static_textured_spatial_page_inactive_reason = layout_reason
        end
    end
    self._static_textured_spatial_pages_active =
        static_textured_spatial_pages_active == true
    self._static_textured_spatial_page_inactive_reason =
        static_textured_spatial_page_inactive_reason
    static_textured_spatial_page_stats.active =
        static_textured_spatial_pages_active == true
    static_textured_spatial_page_stats.inactive_reason =
        static_textured_spatial_page_inactive_reason

    -- the fallback is the exact pre-page composition path.  Populate these
    -- maps only after the allocation-free page safety audit rejects the layout,
    -- so the accepted page path never creates or aliases a global copy
    if not static_textured_spatial_pages_active then
        for index = 1, #chunk_list do
            if checkpoint then checkpoint('scene:mega-texture-merge',index,#chunk_list)end
            local chunk = chunk_list[index]
            if chunk.dynamic_chunk ~= true then
                merge_opaque_textured_batch_map(
                    mega_textured_batch_map,
                    chunk.opaque_textured_batch_map)
                merge_opaque_textured_batch_map(
                    mega_overlay_textured_batch_map,
                    chunk.overlay_textured_batch_map)
            end
        end
    end

    if checkpoint then checkpoint('scene:late-finalization')end
    self:_build_chunk_cube_draws(chunk_list,checkpoint)
    self._mega_static_draw_items = nil
    self._mega_primitive_instance_count = 0
    self._mega_primitive_path_active = false
    if self.use_instancing == true then
        self._mega_static_draw_items = self:_build_mega_static_draw_items(
            mega_static_shape_instances,
            mega_static_shape_instance_part_ids,checkpoint
        )
        for index = 1, #(self._mega_static_draw_items or {}) do
            self._mega_primitive_instance_count =
                self._mega_primitive_instance_count
                    + math.max(
                        0,
                        tonumber(
                            self._mega_static_draw_items[index].primitive_count
                        ) or 0
                    )
        end
    end

    local mega_cube_path_active = (self._mega_instance_count or 0) > 0
    textured_batch_count = 0
    if static_textured_spatial_pages_active then
        -- static ownership stays in the visibility cell. Dynamic chunks retain
        -- their mutable LOVE meshes and all transparent/SurfaceGui paths were
        -- finalized above, before this opaque-only page composition
        self._mega_textured_batches = nil
        self._mega_overlay_textured_batches = nil
        self._textured_mega_locked = false
        static_textured_spatial_page_stats.legacy_mega_skipped = true
        for i = 1, #chunk_list do
            if checkpoint then checkpoint('scene:texture-finalize',i,#chunk_list)end
            local chunk = chunk_list[i]
            if chunk.dynamic_chunk == true then
                chunk.textured_batches = self:_build_textured_batches_from_map(
                    chunk.opaque_textured_batch_map, nil, nil, nil, false)
                chunk.overlay_textured_batches = self:_build_textured_batches_from_map(
                    chunk.overlay_textured_batch_map, nil, nil, nil, false)
                for batch_index = 1, #chunk.textured_batches do
                    chunk.textured_batches[batch_index].dynamic_chunk = true
                end
                for batch_index = 1, #chunk.overlay_textured_batches do
                    chunk.overlay_textured_batches[batch_index].dynamic_chunk = true
                end
            else
                chunk.textured_batches,
                    chunk.overlay_textured_batches =
                    self:_build_static_textured_spatial_pages_for_chunk(
                        chunk, static_textured_spatial_page_stats)
            end
            textured_batch_count = textured_batch_count
                + #chunk.textured_batches
                + #chunk.overlay_textured_batches
            chunk.opaque_textured_batch_map = nil
            chunk.overlay_textured_batch_map = nil
        end
    elseif mega_cube_path_active then
        self._mega_textured_batches =
            self:_build_textured_batches_from_map(
                mega_textured_batch_map, nil, nil, nil, true)
        self._mega_overlay_textured_batches =
            self:_build_textured_batches_from_map(
                mega_overlay_textured_batch_map, nil, nil, nil, true)
        textured_batch_count = textured_batch_count
            + #(self._mega_textured_batches or {})
            + #(self._mega_overlay_textured_batches or {})
        -- only defer static-chunk textured meshes if the mega lists draw EVERY frame: cube-mega
        -- hysteresis can flip _mega_cube_path_active off from visibility ratios alone and blank the
        -- deferred meshes (verified bug). so defer only under default config, and LOCK the textured
        -- compose path so it never follows the cube hysteresis
        local textured_mega_locked = self.enable_occlusion_culling ~= true
            and self.adaptive_mega_batch ~= false
        self._textured_mega_locked = textured_mega_locked
        for i = 1, #chunk_list do
            if checkpoint then checkpoint('scene:texture-finalize',i,#chunk_list)end
            local chunk = chunk_list[i]
            local defer_static = chunk.dynamic_chunk ~= true and textured_mega_locked
            chunk.textured_batches = self:_build_textured_batches_from_map(
                chunk.opaque_textured_batch_map, nil, defer_static, nil,
                chunk.dynamic_chunk ~= true)
            chunk.overlay_textured_batches = self:_build_textured_batches_from_map(
                chunk.overlay_textured_batch_map, nil, defer_static, nil,
                chunk.dynamic_chunk ~= true)
            if chunk.dynamic_chunk == true then
                for batch_index = 1, #chunk.textured_batches do
                    chunk.textured_batches[batch_index].dynamic_chunk = true
                end
                for batch_index = 1, #chunk.overlay_textured_batches do
                    chunk.overlay_textured_batches[batch_index].dynamic_chunk = true
                end
            end
            textured_batch_count = textured_batch_count + #chunk.textured_batches + #chunk.overlay_textured_batches
            chunk.opaque_textured_batch_map = nil
            chunk.overlay_textured_batch_map = nil
        end
    else
        self._mega_textured_batches = nil
        self._mega_overlay_textured_batches = nil
        self._textured_mega_locked = false
        for i = 1, #chunk_list do
            if checkpoint then checkpoint('scene:texture-finalize',i,#chunk_list)end
            local chunk = chunk_list[i]
            chunk.textured_batches = self:_build_textured_batches_from_map(
                chunk.opaque_textured_batch_map, nil, nil, nil,
                chunk.dynamic_chunk ~= true)
            chunk.overlay_textured_batches = self:_build_textured_batches_from_map(
                chunk.overlay_textured_batch_map, nil, nil, nil,
                chunk.dynamic_chunk ~= true)
            if chunk.dynamic_chunk == true then
                for batch_index = 1, #chunk.textured_batches do
                    chunk.textured_batches[batch_index].dynamic_chunk = true
                end
                for batch_index = 1, #chunk.overlay_textured_batches do
                    chunk.overlay_textured_batches[batch_index].dynamic_chunk = true
                end
            end
            textured_batch_count = textured_batch_count + #chunk.textured_batches + #chunk.overlay_textured_batches
            chunk.opaque_textured_batch_map = nil
            chunk.overlay_textured_batch_map = nil
        end
    end

    local load_stage_times = self._load_stage_times or {}
    load_stage_times.scene_part_classify = math.max(0, chunk_batch_start - scene_sync_start)
    -- sub-stage split, remainder = part-classify + surfacegui collect + transparent build + overhead
    load_stage_times.classify_bounds = math.max(0, c_bounds)
    load_stage_times.classify_chunk_assign = math.max(0, c_chunk)
    load_stage_times.classify_mesh_bake = math.max(0, c_mesh)
    load_stage_times.classify_material_surface = math.max(0, c_material)
    load_stage_times.classify_partclass = math.max(0, c_partclass)
    load_stage_times.classify_instance_build = math.max(0, c_instance)
    load_stage_times.classify_finalize = math.max(0, c_transp)
    load_stage_times.classify_transp_batch = math.max(0, c_transp_batch)
    load_stage_times.classify_finalize_sgui = math.max(0, c_finalize_sgui)
    load_stage_times.classify_finalize_face_layers =
        math.max(0, c_finalize_face_layers)
    load_stage_times.classify_finalize_opaque_metrics =
        math.max(0, c_finalize_opaque_metrics)
    load_stage_times.classify_finalize_transparent_queue =
        math.max(0, c_finalize_transparent_queue)
    load_stage_times.classify_face_predicate = math.max(0, c_face_predicate)
    load_stage_times.classify_face_mesh = math.max(0, c_face_mesh)
    load_stage_times.classify_face_surface_primitive =
        math.max(0, c_face_surface_primitive)
    load_stage_times.classify_face_block = math.max(0, c_face_block)
    load_stage_times.classify_face_mesh_count = n_face_mesh
    load_stage_times.classify_face_surface_primitive_count =
        n_face_surface_primitive
    load_stage_times.classify_face_block_count = n_face_block
    local face_profile = self._face_layer_build_profile or {}
    load_stage_times.classify_block_face_collect =
        math.max(0, tonumber(face_profile.collect) or 0)
    load_stage_times.classify_block_face_setup =
        math.max(0, tonumber(face_profile.setup) or 0)
    load_stage_times.classify_block_face_dispatch =
        math.max(0, tonumber(face_profile.dispatch) or 0)
    load_stage_times.classify_block_face_resource =
        math.max(0, tonumber(face_profile.resource) or 0)
    load_stage_times.classify_block_face_authored_resource =
        math.max(0, tonumber(face_profile.authored_resource) or 0)
    load_stage_times.classify_block_face_surface_resource =
        math.max(0, tonumber(face_profile.surface_resource) or 0)
    load_stage_times.classify_block_face_gui_resource =
        math.max(0, tonumber(face_profile.gui_resource) or 0)
    load_stage_times.classify_block_face_batch =
        math.max(0, tonumber(face_profile.batch) or 0)
    load_stage_times.classify_block_face_vertex =
        math.max(0, tonumber(face_profile.vertex) or 0)
    load_stage_times.classify_block_face_layer_count =
        tonumber(face_profile.layer_count) or 0
    load_stage_times.classify_block_face_authored_count =
        tonumber(face_profile.authored_layer_count) or 0
    load_stage_times.classify_block_face_surface_count =
        tonumber(face_profile.surface_layer_count) or 0
    load_stage_times.classify_block_face_gui_count =
        tonumber(face_profile.gui_layer_count) or 0
    load_stage_times.classify_block_face_resource_resolved_count =
        tonumber(face_profile.resource_resolved_count) or 0
    load_stage_times.classify_block_face_resource_missing_count =
        tonumber(face_profile.resource_missing_count) or 0
    load_stage_times.classify_block_face_batch_memo_hit_count =
        tonumber(face_profile.batch_memo_hit_count) or 0
    load_stage_times.classify_block_face_direct_resource_count =
        tonumber(face_profile.direct_resource_count) or 0
    load_stage_times.classify_block_face_asset_resource_count =
        tonumber(face_profile.asset_resource_count) or 0
    load_stage_times.classify_material_batch_key_cache_hits =
        tonumber(face_profile.material_batch_key_cache_hits) or 0
    load_stage_times.classify_material_batch_key_cache_misses =
        tonumber(face_profile.material_batch_key_cache_misses) or 0
    load_stage_times.classify_body_total = math.max(0, c_body)
    -- Wall windows, including async checkpoint suspension. parts_loop also
    -- includes post-loop instance-group construction/late fallback, body_total
    -- is sampled only in hotspot mode and is not complete CPU attribution
    load_stage_times.classify_preloop = math.max(0, _preloop_end - scene_sync_start)
    load_stage_times.classify_parts_loop = math.max(0, _partsloop_end - _preloop_end)
    load_stage_times.classify_constraints_loop = math.max(0, chunk_batch_start - _partsloop_end)
    -- alloc deltas per boundary (KB), load-profiler measurement only
    if _preloop_alloc_start then
        load_stage_times.classify_preloop_alloc_kb = math.max(0, _preloop_alloc_end - _preloop_alloc_start)
        load_stage_times.classify_parts_loop_alloc_kb = math.max(0, _partsloop_alloc_end - _preloop_alloc_end)
    end
    load_stage_times.classify_other = math.max(0,
        (chunk_batch_start - scene_sync_start)
        - c_bounds - c_chunk - c_mesh - c_material - c_partclass - c_instance - c_transp)
    load_stage_times.gpu_upload_batch_build = math.max(0, love.timer.getTime() - chunk_batch_start)
    load_stage_times.draw_packet_build = load_stage_times.gpu_upload_batch_build
    load_stage_times.mesh_uploads = self._mesh_uploads_this_build or 0
    load_stage_times.union_uploads = self._union_mesh_uploads or 0
    self._load_stage_times = load_stage_times
    self._last_draw_packet_build_ms = math.max(0, load_stage_times.gpu_upload_batch_build * 1000)

    -- fold recorded per-part ranges into the release index (incremental promote/destroy)
    local range_index_start = love.timer.getTime()
    if checkpoint then checkpoint('scene:range-index')end
    self:_index_static_part_ranges(chunk_list)
    load_stage_times.range_index = math.max(0, love.timer.getTime() - range_index_start)

    local spatial_structure_start = love.timer.getTime()
    self._scene_chunk_map = chunk_map
    self._scene_chunks = chunk_list
    self._scene_static_chunks = {}
    self._scene_dynamic_chunks = {}
    local bvh_chunks = {}
    -- cache the static aggregate so per-frame dynamic sync never rescans all chunks, it just adds
    -- dynamics to these totals, static counts = grand totals minus dynamic contribution
    local static_scene_bounds = {
        min_x = math.huge,
        min_y = math.huge,
        min_z = math.huge,
        max_x = -math.huge,
        max_y = -math.huge,
        max_z = -math.huge,
    }
    local dynamic_cube_instances = 0
    local dynamic_opaque_static_batch_count = 0
    local dynamic_textured_batch_count = 0
    local dynamic_transparent_draw_count = 0
    for i = 1, #chunk_list do
        local chunk = chunk_list[i]
        if chunk and chunk.dynamic_chunk == true then
            self._scene_dynamic_chunks[#self._scene_dynamic_chunks + 1] = chunk
            dynamic_cube_instances = dynamic_cube_instances + #(chunk.cube_instances or {})
            dynamic_opaque_static_batch_count = dynamic_opaque_static_batch_count
                + #(chunk.opaque_static_draw_items or {})
            dynamic_textured_batch_count = dynamic_textured_batch_count
                + #(chunk.textured_batches or {})
                + #(chunk.overlay_textured_batches or {})
            dynamic_transparent_draw_count = dynamic_transparent_draw_count
                + #(chunk.transparent_draw_items or {})
        else
            self._scene_static_chunks[#self._scene_static_chunks + 1] = chunk
            bvh_chunks[#bvh_chunks + 1] = chunk
            if chunk and chunk.bounds then
                expand_bounds_with_bounds(static_scene_bounds, chunk.bounds)
            end
        end
    end
    self._static_scene_bounds = static_scene_bounds.min_x < math.huge
        and finalize_bounds(static_scene_bounds) or nil
    for index = 1, #(self._mega_static_draw_items or {}) do
        self._mega_static_draw_items[index].bounds = self._static_scene_bounds
    end
    self._static_cube_instance_count = math.max(0, total_cube_instances - dynamic_cube_instances)
    self._static_opaque_static_batch_count =
        math.max(0, opaque_static_batch_count - dynamic_opaque_static_batch_count)
    self._static_textured_batch_count = math.max(0, textured_batch_count - dynamic_textured_batch_count)
    self._static_transparent_draw_count = math.max(0, transparent_draw_count - dynamic_transparent_draw_count)
    if checkpoint then checkpoint('scene:spatial-index')end
    self._scene_chunk_bvh = build_scene_chunk_bvh(bvh_chunks)
    if checkpoint then checkpoint('scene:dynamic-mega')end
    self:_build_dynamic_mega_cube_draw(self._scene_dynamic_chunks)
    load_stage_times.spatial_structure_build = math.max(0, love.timer.getTime() - spatial_structure_start)
    self._instance_vertices = {}
    self.instance_count = total_cube_instances
    self._opaque_static_draw_items = {}
    self._textured_batches = {}
    self._transparent_draw_items = {}
    self._opaque_static_batch_count = opaque_static_batch_count
    self._textured_batch_count = textured_batch_count
    self._transparent_draw_count = transparent_draw_count
    self._transparent_static_batch_count = transparent_static_batch_count
    self._transparent_static_batched_part_count = transparent_static_batched_part_count
    self._transparent_static_draws_eliminated = math.max(0,
        transparent_static_batched_part_count - transparent_static_batch_count)
    self._visible_opaque_chunks = {}
    self._visible_transparent_draw_items = {}
    self._visible_textured_batches = {}
    self._visible_overlay_textured_batches = {}
    self._visible_surface_gui_batches = {}
    self._visible_static_draw_items = {}
    self._surface_gui_entries = surface_gui_entries
    self._billboard_entries = billboard_entries
    self._surface_gui_preload_cursor = 0
    local surface_gui_build_start = love.timer.getTime()
    local surface_gui_prebuilt_count = 0
    -- canvases build lazily (draw path + _preload_surface_gui_canvases backfill), this eager build
    -- only front-loads the cost -- ~570ms/199 guis on sky emporium. default off
    if self.preload_static_surface_guis == true and self._ensure_surface_gui_runtime_texture then
        for entry_index = 1, #surface_gui_entries do
            if checkpoint then checkpoint('scene:surface-canvas',entry_index,#surface_gui_entries)end
            local entry = surface_gui_entries[entry_index]
            local surface_gui = entry and entry.surface_gui
            if type(surface_gui) == "table" then
                local _, _, redrawn = self:_ensure_surface_gui_runtime_texture(surface_gui, entry.part)
                if redrawn then
                    surface_gui_prebuilt_count = surface_gui_prebuilt_count + 1
                end
            end
        end
    end
    load_stage_times.surfacegui_build = math.max(0, love.timer.getTime() - surface_gui_build_start)
    if checkpoint then checkpoint('scene:publish')end
    local scene_finalize_start = love.timer.getTime()
    self._surface_gui_prebuilt_count = surface_gui_prebuilt_count
    if scene_bounds.min_x < math.huge then
        self._scene_bounds = finalize_bounds(scene_bounds)
    else
        self._scene_bounds = nil
    end
    self.part_count = live_part_count
    self.surface_gui_count = surface_gui_count
    self.billboard_gui_count = billboard_gui_count
    self._opaque_part_count = total_opaque_part_count
    self._transparent_part_count = total_transparent_part_count
    self._glass_part_count = total_glass_part_count
    self._zero_alpha_base_geometry_elided_count =
        zero_alpha_base_geometry_elided_count
    self.mesh_part_count = mesh_rendered_count
    self.material_part_count = material_rendered_count
    self.material_fallback_count = material_fallback_count
    self.plastic_fallback_count = plastic_fallback_count
    self.material_fallback_events = material_fallback_events
    self.material_fallback_log = material_fallback_events
    self.material_fallback_log_limit =
        collect_scene_build_diagnostics
            and material_fallback_diagnostic_limit or 0
    self.material_fallback_log_truncated =
        collect_scene_build_diagnostics
            and (material_fallback_count + plastic_fallback_count)
                > #material_fallback_events
            or false
    self._scene_build_diagnostics_active =
        collect_scene_build_diagnostics
    self.zfight_risk_count = zfight_risk_count
    self.normal_material_packet_count = material_rendered_count
    self.missing_mesh_count = missing_mesh_count
    self.missing_union_mesh_count = missing_union_mesh_count
    self.union_fallback_count = union_fallback_count
    self.unique_color_count = 0
    for _ in pairs(unique_colors) do
        self.unique_color_count = self.unique_color_count + 1
    end

    self._culling_stats = {
        chunk_count = #chunk_list,
        visible_chunk_count = 0,
        visible_opaque_chunk_count = 0,
        visible_transparent_draw_count = 0,
        visible_transparent_part_count = 0,
        visible_opaque_part_count = 0,
        frustum_visible_opaque_part_count = 0,
        occluded_opaque_part_count = 0,
        occluded_chunk_count = 0,
        occluder_chunk_count = 0,
        frustum_visible_chunk_count = 0,
        frustum_culled_chunk_count = 0,
        invalid_bounds_count = 0,
        invalid_culling_input = false,
    }
    self._scene_revision = (self._scene_revision or 0) + 1
    self._static_scene_revision = (self._static_scene_revision or 0) + 1
    self._visible_scene_cache_state = self._visible_scene_cache_state or {}
    self._visible_scene_cache_state.scene_revision = nil
    self._transparent_sort_cache_state = self._transparent_sort_cache_state or {}
    self._transparent_sort_cache_state.items = nil
    if self._mark_all_local_lights_dirty then
        self:_mark_all_local_lights_dirty()
    end
    self._transparent_textured_range_groups = nil
    self._transparent_textured_range_stats = nil
    self._transparent_textured_range_build_state = nil
    self._transparent_textured_range_groups_pending =
        self.enable_transparent_textured_range_aggregation ~= false
    if self._acknowledge_remote_mesh_full_build then
        -- this is the successful full-build commit point. never acknowledge
        -- earlier: a cancelled/throwing build owns only a partial replacement
        -- generation and its publication queue must be retired by load recovery
        local remote_ack_start = love.timer.getTime()
        local acknowledged, ack_error = pcall(
            self._acknowledge_remote_mesh_full_build,
            self,
            remote_mesh_full_build_seen)
        load_stage_times.remote_mesh_full_build_ack = math.max(
            0, love.timer.getTime() - remote_ack_start)
        if not acknowledged then
            self._remote_mesh_full_build_ack_error = tostring(ack_error)
        end
    end
    if self._remote_mesh_full_build_seen == remote_mesh_full_build_seen then
        self._remote_mesh_full_build_seen = nil
    end
    if self._clear_full_build_mesh_resolution_memo then
        self:_clear_full_build_mesh_resolution_memo(
            full_build_mesh_resolution_memo, "committed")
    end
    self._parts_dirty = false
    self._parts_dirty_mode = nil
    self._transform_dirty_parts = {}
    load_stage_times.scene_finalize_bookkeeping = math.max(
        0, love.timer.getTime() - scene_finalize_start)
end

function RBX:_create_runtime_part(class_name, initial_properties)
    local normalized_class = canonicalize_part_class_name(class_name)
    if not normalized_class then
        error(
            "Unsupported runtime instance class '" .. tostring(class_name) ..
            "'. Instance.new only supports: Part, SpawnLocation, WedgePart, CornerWedgePart, TrussPart, Seat, VehicleSeat, MeshPart, UnionOperation, PartOperation, NegateOperation")
    end

    if type(initial_properties) == "table" and initial_properties.Size ~= nil then
        RBX._size_validation.components(initial_properties.Size, initial_properties, true)
    end
    local id = self._next_part_id
    self._next_part_id = id + 1

    local initial_parent = nil
    local has_initial_parent = false
    if type(initial_properties) == "table" and initial_properties.Parent ~= nil then
        initial_parent = initial_properties.Parent
        has_initial_parent = true
    end
    -- public Instance.new parts are detached until the DataModel hierarchy
    -- confirms their first parent.  keep them out of physics from the first
    -- property write, a later Workspace membership transition owns the one
    -- required registration with the final property set
    local starts_stored = self._datamodel ~= nil and not has_initial_parent

    ---@type RBXLXPart
    ---@diagnostic disable-next-line: missing-fields
    local part = {
        _id = id,
        Name = normalized_class .. tostring(id),
        ClassName = normalized_class,
        Shape = normalize_part_shape(nil, normalized_class),
        CFrame = CFrame.new(),
        Size = { x = 4, y = 1, z = 2 },
        Color = { r = 0.78, g = 0.78, b = 0.78 },
        Transparency = 0,
        LocalTransparencyModifier = 0,
        Reflectance = 0,
        Anchored = true,
        CanCollide = true,
        CanTouch = true,
        CanQuery = true,
        CastShadow = true,
        CollisionGroup = "Default",
        Massless = false,
        RootPriority = 0,
        CustomPhysicalProperties = nil,
        Mass = 0,
        AssemblyMass = 0,
        AssemblyCenterOfMass = { x = 0, y = 0, z = 0 },
        AssemblyRootPart = nil,
        AssemblyShapeApproximation = nil,
        Velocity = { x = 0, y = 0, z = 0 },
        RotVelocity = { x = 0, y = 0, z = 0 },
        AssemblyLinearVelocity = { x = 0, y = 0, z = 0 },
        AssemblyAngularVelocity = { x = 0, y = 0, z = 0 },
        Material = 0,
        TopSurface = nil,
        BottomSurface = nil,
        LeftSurface = nil,
        RightSurface = nil,
        FrontSurface = nil,
        BackSurface = nil,
        TopSurfaceInput = 0,
        BottomSurfaceInput = 0,
        LeftSurfaceInput = 0,
        RightSurfaceInput = 0,
        FrontSurfaceInput = 0,
        BackSurfaceInput = 0,
        TopParamA = nil,
        TopParamB = nil,
        BottomParamA = nil,
        BottomParamB = nil,
        LeftParamA = nil,
        LeftParamB = nil,
        RightParamA = nil,
        RightParamB = nil,
        FrontParamA = nil,
        FrontParamB = nil,
        BackParamA = nil,
        BackParamB = nil,
        MeshId = nil,
        TextureContent = nil,
        TextureId = nil,
        UsePartColor = true,
        DoubleSided = false,
        SmoothingAngle = nil,
        RenderFidelity = nil,
        CollisionFidelity = "Default",
        PhysicsData = nil,
        PhysicalConfigData = nil,
        TriangleCount = nil,
        MaterialVariant = nil,
        SurfaceAppearance = nil,
        MeshOwner = nil,
        SpecialMeshType = nil,
        SpecialMeshScale = nil,
        SpecialMeshOffset = nil,
        SpecialMeshVertexColor = nil,
        MeshVertexColor = nil,
        FaceTextures = {},
        SurfaceGuis = {},
        BillboardGuis = {},
        BlockMeshScale = nil,
        BlockMeshOffset = nil,
        MeshSize = nil,
        EmbeddedMeshData = nil,
        EmbeddedMeshDataCandidates = nil,
        _loaded_from_map = false,
        _runtime_dynamic = false,
        _embedded_mesh_cache = nil,
        _destroyed = false,
    }
    if starts_stored then
        part._workspace_active = false
        part._physics_excluded = true
    end

    -- physics mirror of _suppress_part_dirty: property descriptors (Anchored,
    -- CanCollide, ...) AND update_runtime_part_dynamic_flag call
    -- _refresh_physics_part_registration as side effects, which would bind a
    -- HALF-built snapshot into the world (and the epilogue's mass refresh would
    -- then see a bound part and force a whole-world rebuild -- a ~200-800ms hitch
    -- at 48k parts, fired per runtime part creation). defer: the epilogue below
    -- registers exactly once with the complete property set
    part._physics_defer_registration = true

    if type(initial_properties) == "table" then
        local suppress_count = (tonumber(self._suppress_part_dirty) or 0) + 1
        self._suppress_part_dirty = suppress_count
        local ok, err = pcall(function()
            local handled = {}
            for i = 1, #RUNTIME_PART_INITIAL_PROPERTY_ORDER do
                local key = RUNTIME_PART_INITIAL_PROPERTY_ORDER[i]
                local value = initial_properties[key]
                if value ~= nil then
                    set_runtime_part_property(self, part, key, value)
                    handled[key] = true
                end
            end

            for key, value in pairs(initial_properties) do
                if key == "Parent" then
                    handled[key] = true
                elseif not handled[key] then
                    set_runtime_part_property(self, part, key, value)
                end
            end
        end)
        self._suppress_part_dirty = suppress_count > 1 and suppress_count - 1 or nil
        if not ok then
            part._physics_defer_registration = nil
            error(err, 0)
        end
    end

    -- update_runtime_part_dynamic_flag ALSO calls
    -- _refresh_physics_part_registration -- the defer flag must stay set through it,
    -- or the part binds there and the mass refresh below sees a bound part and
    -- forces a whole-world rebuild. single registration happens at the end
    update_runtime_part_dynamic_flag(self, part)
    self:_register_runtime_part_storage(part)
    index_runtime_part_core_handle(self, part)
    part._physics_defer_registration = nil
    self:_refresh_runtime_part_material_variant_physics(part)
    self:_refresh_runtime_part_mass(part)
    if part._workspace_active ~= false then
        self:_refresh_physics_part_registration(part)
    end
    self:_attach_runtime_part_to_datamodel(part, has_initial_parent and initial_parent or nil)
    if part._workspace_active == false then
        -- Clone/Instance.new initialization is unpublished. its final
        -- Workspace membership performs physics registration and render
        -- ownership after callers finish the stored-property writes
    elseif can_update_runtime_part_incrementally(self, part) then
        self:_mark_runtime_part_transform_dirty(part)
    elseif part.Anchored == true and (self._appearance_promoted_count or 0) < 2048 then
        -- bounded: a new anchored runtime part starts in its own dynamic chunk instead of
        -- forcing a full scene re-bake (measured ~85 ms per creating frame on a 5k map)
        -- the next real full rebuild folds it into the static set (self-heal clears the
        -- flag), the cap keeps runaway creation from accumulating per-part chunks
        part._appearance_dynamic = true
        local promoted = self._appearance_promoted_parts
        if not promoted then
            promoted = {}
            self._appearance_promoted_parts = promoted
        end
        promoted[part._id] = part
        self._appearance_promoted_count = (self._appearance_promoted_count or 0) + 1
        self:_mark_runtime_part_transform_dirty(part)
    else
        mark_parts_dirty(self)
    end
    return part
end

function RBX:_reset_runtime_parts()
    self._render_streamed_parts = nil
    self._render_streamed_part_count = 0
    local reset_phase_started = love.timer.getTime()
    local function finish_reset_phase(stage_name)
        local now = love.timer.getTime()
        if type(self._add_load_stage_time) == "function" then
            self:_add_load_stage_time(
                stage_name, now - reset_phase_started)
        end
        reset_phase_started = now
    end
    if self._clear_full_build_mesh_resolution_memo then
        self:_clear_full_build_mesh_resolution_memo(nil, "runtime_reset")
    end
    -- a cancelled/throwing sliced build may never reach the successful scene
    -- commit that normally clears this ledger. reset must always re-enable
    -- publication fanout for the next authoritative map generation
    self._remote_mesh_full_build_seen = nil
    if self._clear_remote_mesh_promotion_queue then
        -- Queue entries hold ready handles strongly while their consumer slots
        -- are walked. retire the old map generation before ids and parts can be
        -- reused by the next load
        self:_clear_remote_mesh_promotion_queue()
        self._remote_mesh_full_rebuild_pending = false
    end
    if self._discard_settled_merge_generation then
        -- lifecycle.lua resets backend ownership immediately below.  Detach
        -- every derived aggregate and release unfinished flat CPU payloads
        -- first, while the pending graph is still reachable
        self:_discard_settled_merge_generation(
            "map_reset", false, false)
    end
    finish_reset_phase("runtime_reset_queue_retire")
    if self._release_scene_gpu_resources then
        local release_ok, release_error = pcall(
            self._release_scene_gpu_resources, self)
        if not release_ok then
            print("[rbx] map resource release failed: " .. tostring(release_error))
        end
    elseif self._render_backend and self._render_backend.reset then
        local reset_ok, reset_error = pcall(self._render_backend.reset, self._render_backend)
        if not reset_ok then
            self:_note_render_backend_error("reset map batches", reset_error)
        end
    end
    finish_reset_phase("runtime_reset_scene_release")
    for index = 1, #(self.parts or {}) do
        local part = self.parts[index]
        if type(part) == "table" then
            if self._unbind_remote_mesh_consumer then
                self:_unbind_remote_mesh_consumer(part)
            end
            if self._release_part_embedded_mesh_cache then
                self:_release_part_embedded_mesh_cache(part)
            end
            -- Decoded remote results can own every retained v4+ LOD stream
            -- Externally retained old-generation facades must not keep that
            -- graph alive after a map reset even though their core part is
            -- deliberately left as a destroyed tombstone for API semantics
            part._mesh_lod_base_mesh = nil
            part._mesh_lod_count = nil
            part._mesh_lod_index = nil
            part._mesh_lod_fidelity = nil
            -- the dense suffix is also threaded in public creation order
            -- Break both intrusive edges while every live part is still
            -- reachable: clearing only the renderer's head/tail would let one
            -- externally retained tombstone pin the rest of the old map
            part._runtime_part_order_prev = nil
            part._runtime_part_order_next = nil
            part._runtime_part_slot = nil
            part._destroyed = true
            if cleanup_runtime_part_signals then
                cleanup_runtime_part_signals(part)
            end
        end
    end
    finish_reset_phase("runtime_reset_part_retire")
    if self._retire_embedded_mesh_content_cache_generation then
        -- Parts above have released every pin and severed direct memos. keep
        -- only the bounded immutable content lookup warm for the next map;
        -- renderer destruction still clears it in lifecycle.lua. the cache
        -- validates the zero-pin invariant and clears itself on any violation
        self:_retire_embedded_mesh_content_cache_generation()
    elseif self._clear_embedded_mesh_content_cache then
        self:_clear_embedded_mesh_content_cache()
    end
    finish_reset_phase("runtime_reset_embedded_retire")
    self.parts = {}
    -- MaterialService catalogs and descriptors are one map generation. never
    -- let an omitted/failed catalog on the next map inherit an old override
    self._material_variant_catalog = nil
    self._material_variant_error = nil
    self._material_cache = {}
    self._loaded_part_count = 0
    self._runtime_part_storage_initialized = true
    self._runtime_part_order_head = nil
    self._runtime_part_order_tail = nil
    self._runtime_live_part_count = 0
    self._runtime_part_storage_peak_slots = 0
    self._runtime_part_storage_removal_count = 0
    self.constraints = {}
    self._part_proxy_by_id = {}
    self._runtime_part_by_id = {}
    self._runtime_part_by_name = {}
    self._runtime_part_by_referent = {}
    self._parsed_physics_instances = {}
    self._physics_constraints = {}
    self._physics_movers = {}
    self._physics_movers_by_part_id = {}
    self._physics_dynamic_parts = {}
    self._physics_assemblies = {}
    self._physics_part_assembly_by_id = {}
    self._physics_assembly_dirty = true
    self._physics_broadphase_pairs = {}
    self._physics_broadphase_pair_count = 0
    self._physics_woken_part_ids = {}
    self._physics_follower_rest_cache = {}
    self._physics_pending_query_parts = {}
    self._pending_touch_events = {}
    if self._physics_world then
        self._physics_world.assemblies_built = false
        self._physics_world.manual_no_collision = {}
        self._physics_world.no_collision = {}
    end
    self._next_part_id = 1
    self._parts_dirty = false
    self._parts_dirty_mode = nil
    self._transform_dirty_parts = {}
    -- Promotion tables retain strong references to loaded-map parts. a map
    -- reset must retire the entire generation, including parts temporarily
    -- promoted out of static batches, or an id reused by the next map can share
    -- stale promotion/deferred state with a destroyed part
    self._promoted_loaded_parts = nil
    self._promoted_loaded_part_count = 0
    self._appearance_promoted_parts = nil
    self._appearance_promoted_count = 0
    self._scene_bounds = nil
    self._scene_chunks = {}
    self._scene_chunk_map = {}
    self._scene_static_chunks = {}
    self._scene_dynamic_chunks = {}
    self._dormant_dynamic_scene_chunk_map = nil
    self._scene_dynamic_chunks_drawn = nil
    self._settled_merge_chunks = nil
    self._settled_merge_chunk = nil
    self._settled_merge_members = nil
    self._settled_merge_ids = nil
    self._settled_merge_pending = nil
    -- missing face assets are diagnosed once per map generation. keeping
    -- these keys across maps would suppress a useful warning after a reload
    -- and make the map-level count cumulative
    self._missing_face_texture_warning_keys = {}
    self._missing_face_texture_count = 0
    self._settled_merge_last_members = nil
    self._settled_merge_last_ids = nil
    self._settled_merge_stable_frames = 0
    self._settled_merge_part_count = 0
    self._settled_merge_failure_until = nil
    self._settled_merge_last_scan_count = 0
    self._settled_merge_last_candidate_count = 0
    self._settled_merge_last_scan_truncated = false
    self._settled_merge_max_observed_scan_count = 0
    self._settled_merge_scan_cursor = 1
    self._settled_merge_scan_wrap_count = 0
    self._instanced_mesh_groups = nil
    self._instanced_mesh_index_stats = nil
    self._static_textured_index_stats = nil
    self._static_textured_spatial_pages_active = false
    self._static_textured_spatial_page_inactive_reason = nil
    self._static_textured_spatial_page_stats = nil
    self._instanced_mesh_object_count = 0
    self._primitive_instanced_batch_count = 0
    self._primitive_instanced_object_count = 0
    self._dirty_instance_rows = nil
    self._instance_generation = (self._instance_generation or 0) + 1
    self._mesh_texture_atlas = nil
    self._mesh_atlas_candidates = nil
    self._mesh_atlas_built = false
    self._surface_detail_geometry_cache = {}
    self._sprite_batches = {}
    self._sprite_billboard_draw_items = {}
    self._static_scene_bounds = nil
    self._static_cube_instance_count = 0
    self._static_opaque_static_batch_count = 0
    self._static_textured_batch_count = 0
    self._static_transparent_draw_count = 0
    self._mega_cube_batch = nil
    self._mega_instance_mesh = nil
    self._mega_cube_draw_mesh = nil
    self._mega_instance_count = 0
    self._mega_cube_handedness = "collapsed"
    self._mega_cube_batch_key = "Block|0"
    self._mega_cube_path_active = false
    self._mega_primitive_instance_count = 0
    self._mega_primitive_path_active = false
    self._static_local_light_clusters = nil
    self._static_local_light_cluster_last_build_stats = nil
    self._static_local_light_cluster_last_attempt_signature = nil
    self._static_local_light_cluster_pending_signature = nil
    self._static_local_light_cluster_pending_since = nil
    self._transparent_textured_range_groups = nil
    self._transparent_textured_range_stats = nil
    self._transparent_textured_range_build_state = nil
    self._transparent_textured_range_groups_pending = nil
    self._transparent_textured_range_order_token = 0
    self._mega_dynamic_cube_batch = nil
    self._mega_dynamic_instance_mesh = nil
    self._mega_dynamic_cube_draw_mesh = nil
    self._mega_dynamic_instance_count = 0
    self._mega_dynamic_instance_capacity = 0
    self._mega_dynamic_cube_handedness = "collapsed"
    self._mega_dynamic_cube_batch_key = "Block|0"
    self._scene_chunk_bvh = nil
    self._opaque_static_draw_items = {}
    self._mega_static_draw_items = nil
    self._textured_batches = {}
    self._transparent_draw_items = {}
    self._visible_opaque_chunks = {}
    self._visible_transparent_draw_items = {}
    self._visible_textured_batches = {}
    self._visible_overlay_textured_batches = {}
    self._visible_surface_gui_batches = {}
    self._visible_static_draw_items = {}
    self._surface_gui_entries = {}
    self._surface_gui_preload_cursor = 0
    self._billboard_entries = {}
    self._billboard_draw_items = {}
    self._billboard_stats = nil
    self._screen_guis = {}
    self._opaque_static_batch_count = 0
    self._textured_batch_count = 0
    self._transparent_draw_count = 0
    self._opaque_part_count = 0
    self._transparent_part_count = 0
    self._glass_part_count = 0
    self._zero_alpha_base_geometry_elided_count = 0
    self.instance_count = 0
    self._scene_revision = (self._scene_revision or 0) + 1
    self._static_scene_revision = (self._static_scene_revision or 0) + 1
    self._visible_scene_revision = 0
    self._static_visible_cache_valid = false
    self._visible_scene_cache_state = {}
    self._transparent_sort_cache_state = {}
    self._culling_stats = {
        chunk_count = 0,
        visible_chunk_count = 0,
        visible_opaque_chunk_count = 0,
        visible_transparent_draw_count = 0,
        visible_transparent_part_count = 0,
        visible_opaque_part_count = 0,
        frustum_visible_opaque_part_count = 0,
        occluded_opaque_part_count = 0,
        occluded_chunk_count = 0,
        occluder_chunk_count = 0,
        frustum_visible_chunk_count = 0,
        frustum_culled_chunk_count = 0,
        invalid_bounds_count = 0,
        invalid_culling_input = false,
    }
    self.mesh_part_count = 0
    self.material_part_count = 0
    self.material_fallback_count = 0
    self.plastic_fallback_count = 0
    self.material_fallback_events = {}
    self.material_fallback_log = self.material_fallback_events
    self.material_fallback_log_limit = 0
    self.material_fallback_log_truncated = false
    self._scene_build_diagnostics_active = false
    self.zfight_risk_count = 0
    self.normal_material_packet_count = 0
    self._surface_detail_cache_hits_this_build = 0
    self._surface_detail_cache_misses_this_build = 0
    self._surface_detail_combined_normal_cache_hits = 0
    self._surface_detail_combined_normal_cache_misses = 0
    self.missing_mesh_count = 0
    self.missing_union_mesh_count = 0
    self.constraint_count = 0
    finish_reset_phase("runtime_reset_state_clear")
end

function RBX:_convert_loaded_map_vector_value(value)
    local converted = convert_parsed_map_vector3(value)
    if not converted then
        return nil
    end
    if self.flip_loaded_map_horizontally ~= false then
        -- Polar vector: only X flips. (An angular velocity or torque would need
        -- coords.mirror_x_pseudovector instead -- Y and Z flip, X does not.)
        converted = Vector3.new(-(converted.x or 0), converted.y or 0, converted.z or 0)
    end
    return converted
end

function RBX:_convert_loaded_map_cframe_value(value)
    local converted = convert_parsed_map_cframe(value)
    if not converted then
        return nil
    end
    if self.flip_loaded_map_horizontally ~= false then
        -- mirror the rotation on both sides so the resulting basis stays right-handed
        local coords = runtime_require("coords.lua")
        local mirrored = coords.mirror_x({
            x = converted.x or 0, y = converted.y or 0, z = converted.z or 0,
            r00 = converted.r00 or 1, r01 = converted.r01 or 0, r02 = converted.r02 or 0,
            r10 = converted.r10 or 0, r11 = converted.r11 or 1, r12 = converted.r12 or 0,
            r20 = converted.r20 or 0, r21 = converted.r21 or 0, r22 = converted.r22 or 1,
        })
        converted = CFrame.from_matrix(
            mirrored.x, mirrored.y, mirrored.z,
            mirrored.r00, mirrored.r01, mirrored.r02,
            mirrored.r10, mirrored.r11, mirrored.r12,
            mirrored.r20, mirrored.r21, mirrored.r22
        )
    end
    return converted
end

function RBX:_load_runtime_parts_from_parsed(
        parsed_parts, parsed_constraints, checkpoint, collision_policy_owner)
    RBX._size_validation.admit(parsed_parts)
    local reset_start = love.timer.getTime()
    self:_reset_runtime_parts()
    if collision_policy_owner then
        RBX._collision_group_policy.commit(self, collision_policy_owner)
    end
    if self._is_async_map_building and self:_is_async_map_building() then
        -- guard publication for the whole yielding replacement transaction,
        -- including the part-creation slices before _sync_runtime_parts starts
        -- the full sync reuses this table as its exact observation ledger
        self._remote_mesh_full_build_seen = {}
    end
    self:_add_load_stage_time(
        "runtime_parts_reset", love.timer.getTime() - reset_start)

    -- Parser metadata rides named fields on the dense parts array. capture it
    -- before the array is converted into runtime parts and later discarded
    self._material_variant_catalog = type(parsed_parts) == "table"
        and parsed_parts._material_variant_catalog or nil
    self._material_variant_error = type(parsed_parts) == "table"
        and parsed_parts._material_variant_error or nil

    -- screen guis ride the parts array as a named field (parser.lua), wrapped in the surfacegui
    -- proxy machinery so facade writes mark dirty + re-sync, same as part-anchored guis
    self._screen_guis = RBX._clone_surface_gui_list(
        type(parsed_parts) == "table" and parsed_parts._screen_guis or nil)

    local total_parts = #parsed_parts
    self._loaded_part_count = total_parts
    local part_by_referent = {}
    self._runtime_part_by_referent = part_by_referent
    self._runtime_part_by_id = {}
    self._runtime_part_by_name = {}
    local instance_creation_start = love.timer.getTime()
    for i = 1, total_parts do
        if checkpoint and (i == 1 or i == total_parts or i % 48 == 0) then
            checkpoint("runtime_parts", i, total_parts)
        end

        local pp = parsed_parts[i]
        local part = runtime_part_from_parsed(pp, self._next_part_id)
        -- physics_anchor_loaded_parts: the map is pure scenery -- force-anchor before
        -- physics registration so no map part ever becomes a dynamic body (see render.lua
        -- option comment). Must happen here, not in runtime_part_from_parsed, so
        -- runtime-created parts (character/NPCs) keep their authored Anchored
        if self.physics_anchor_loaded_parts then
            part.Anchored = true
        end
        self:_apply_loaded_runtime_part_coordinate_fix(part)
        self._next_part_id = self._next_part_id + 1
        part._loaded_part_index = i
        self.parts[i] = part
        index_runtime_part_core_handle(self, part)
        self:_refresh_runtime_part_material_variant_physics(part)
        self:_refresh_runtime_part_mass(part)
        self:_refresh_physics_part_registration(part)
    end
    self:_add_load_stage_time("instance_creation", love.timer.getTime() - instance_creation_start)

    local constraints_start = love.timer.getTime()
    local constraint_list = parsed_constraints or {}
    for i = 1, #constraint_list do
        self.constraints[#self.constraints + 1] = copy_runtime_value(constraint_list[i])
    end
    self.constraint_count = #self.constraints
    self:_add_load_stage_time(
        "constraint_creation", love.timer.getTime() - constraints_start)

    self._parts_dirty = true
    local scene_sync_start = love.timer.getTime()
    self:_sync_runtime_parts(true, checkpoint)
    local runtime_scene_sync_current =
        math.max(0, love.timer.getTime() - scene_sync_start)
    self._initial_contact_separation_stats = {}
    for key, value in pairs(self._contact_separation_stats or {}) do
        if type(value) == "number" or type(value) == "string"
            or type(value) == "boolean" then
            self._initial_contact_separation_stats[key] = value
        end
    end
    self._load_stage_times.runtime_scene_sync_current =
        runtime_scene_sync_current
    -- Later remote-mesh publication rebuilds overwrite the live scene-stage
    -- counters. preserve the map-ready build once so load reports do not
    -- accidentally describe the last promotion rebuild instead
    for _, key in ipairs({
        "scene_sync_preamble",
        "scene_generation_release",
        "scene_backend_reset",
        "scene_part_classify",
        "classify_preloop",
        "classify_parts_loop",
        "classify_constraints_loop",
        "classify_bounds",
        "classify_chunk_assign",
        "classify_mesh_bake",
        "classify_material_surface",
        "classify_partclass",
        "classify_instance_build",
        "classify_finalize",
        "classify_transp_batch",
        "classify_finalize_sgui",
        "classify_finalize_face_layers",
        "classify_finalize_opaque_metrics",
        "classify_finalize_transparent_queue",
        "classify_body_total",
        "classify_other",
        "gpu_upload_batch_build",
        "range_index",
        "spatial_structure_build",
        "surfacegui_build",
        "scene_finalize_bookkeeping",
        "remote_mesh_full_build_ack",
    }) do
        self._load_stage_times["initial_" .. key] =
            self._load_stage_times[key]
    end
    self:_add_load_stage_time(
        "runtime_scene_sync", runtime_scene_sync_current)
    -- shadow caster list/grid feed ONLY get_shadow_diagnostics (frame-path shadows are
    -- per-vertex shadow_factor) -- defer the O(#parts)+grid build to that call instead of
    -- paying it on every full scene rebuild (was ~a full 48k-part walk per rebuild hitch)
    self._shadow_casters_stale = true
end

function RBX:_build_instance_api()
    local renderer = self
    local api = {}

    ---@param class_name string
    ---@param properties table|nil
    function api.new(class_name, properties)
        local part = renderer:_create_runtime_part(class_name, properties)
        return renderer:_get_or_create_part_proxy(part)
    end

    function api.GetSupportedClasses()
        local classes = {}
        for class_name in pairs(SUPPORTED_PART_CLASSES) do
            classes[#classes + 1] = class_name
        end
        table.sort(classes)
        return classes
    end

    return api
end

function RBX:_get_instance_api()
    if not self._instance_api then
        self._instance_api = self:_build_instance_api()
    end
    return self._instance_api
end

function RBX:_warn_deprecated_api(legacy_name, replacement)
    if self._debug_deprecation_warnings ~= true then
        return
    end
    self._deprecation_warning_seen = self._deprecation_warning_seen or {}
    if self._deprecation_warning_seen[legacy_name] then
        return
    end
    self._deprecation_warning_seen[legacy_name] = true
    print(string.format(
        "[rbx] %s is a compatibility alias, use %s",
        legacy_name,
        replacement
    ))
end

local function make_deprecated_runtime_api_shim(renderer, legacy_name, target, replacement)
    if renderer._debug_deprecation_warnings ~= true then
        return target
    end
    return setmetatable({}, {
        __index = function(_, key)
            renderer:_warn_deprecated_api(legacy_name, replacement)
            return target[key]
        end,
        __newindex = function(_, key, value)
            renderer:_warn_deprecated_api(legacy_name, replacement)
            target[key] = value
        end,
        __len = function()
            renderer:_warn_deprecated_api(legacy_name, replacement)
            return #target
        end,
        __pairs = function()
            renderer:_warn_deprecated_api(legacy_name, replacement)
            return pairs(target)
        end,
        __tostring = function()
            return tostring(target)
        end,
    })
end

function RBX:_install_deprecated_runtime_shims()
    -- compat shims, new scripts should require("engine/graphics/rbx") instead
    self.CFrame = make_deprecated_runtime_api_shim(self, "game.CFrame", RBX.CFrame, "rbx.CFrame")
    self.Vector3 = make_deprecated_runtime_api_shim(self, "game.Vector3", RBX.Vector3, "rbx.Vector3")
    self.Color3 = make_deprecated_runtime_api_shim(self, "game.Color3", RBX.Color3, "rbx.Color3")
    self.Enum = make_deprecated_runtime_api_shim(self, "game.Enum", RBX.Enum, "rbx.Enum")
    self.Instance = make_deprecated_runtime_api_shim(self, "game.Instance", self:_get_instance_api(), "rbx.Instance")
    self.Part = make_deprecated_runtime_api_shim(
        self,
        "game.Part",
        self._part_explorer,
        "game.Workspace:GetChildren() or game.Workspace:FindFirstChild(...)"
    )
end

local function get_active_datamodel_for_global_instance()
    local game = RBX._active_datamodel
    if type(game) ~= "table" then
        error("rbx.Instance.new requires an active DataModel; call rbx.new(...) first", 3)
    end
    return game
end

RBX.Instance = {
    new = function(class_name, properties)
        local game = get_active_datamodel_for_global_instance()
        return game:_get_instance_api().new(class_name, properties)
    end,
    GetSupportedClasses = function()
        local classes = {}
        for class_name in pairs(SUPPORTED_PART_CLASSES) do
            classes[#classes + 1] = class_name
        end
        table.sort(classes)
        return classes
    end,
}
