-- the parser, physics and renderer share a right-handed space with +Y up
-- positions are in studs and the camera looks along local -Z
--
-- a CFrame stores its rotation in row order after x, y, z
-- its first two columns give RightVector and UpVector
-- negate the third column for LookVector
--
-- face normals use the same axes: Front is -Z, Right is +X and Top is +Y

local coords = {}

local sqrt = math.sqrt
local abs = math.abs

local EPSILON = 1e-9

-- ============================================================================
-- Scalar conversions (identity, by design -- see the header)
-- ============================================================================

---Roblox world position -> engine world position
---Identity: both spaces are right-handed, +Y up, same units (studs)
function coords.position(x, y, z) return x, y, z end

---Roblox direction/normal -> engine direction. Identity, same reasoning
function coords.direction(x, y, z) return x, y, z end

---Roblox Size (always positive extents) -> engine scale
---Roblox treats Size as an absolute extent, a negative component is not
---meaningful and Studio cannot author one, but a malformed file can carry one
---abs() here rather than at each call site, so a bad file cannot invert winding
function coords.size(x, y, z) return abs(x), abs(y), abs(z) end

-- ============================================================================
-- Basis extraction
-- ============================================================================

---@return number,number,number  local +X in world space
function coords.right_vector(cf)
    return cf.r00, cf.r10, cf.r20
end

---@return number,number,number  local +Y in world space
function coords.up_vector(cf)
    return cf.r01, cf.r11, cf.r21
end

---@return number,number,number  local -Z in world space (the Roblox LookVector)
function coords.look_vector(cf)
    return -cf.r02, -cf.r12, -cf.r22
end

---local +Z. Distinct from look_vector: this is the BACK direction
function coords.back_vector(cf)
    return cf.r02, cf.r12, cf.r22
end

---Determinant of the rotation block
---+1 = proper rotation. -1 = a reflection has been introduced, which inverts
---triangle winding and flips every cross product downstream
function coords.determinant(cf)
    return cf.r00 * (cf.r11 * cf.r22 - cf.r12 * cf.r21)
        - cf.r01 * (cf.r10 * cf.r22 - cf.r12 * cf.r20)
        + cf.r02 * (cf.r10 * cf.r21 - cf.r11 * cf.r20)
end

---@return boolean true when the frame is a proper (non-reflecting) rotation
function coords.is_proper_rotation(cf, tolerance)
    return abs(coords.determinant(cf) - 1) <= (tolerance or 1e-6)
end

-- ============================================================================
-- Point / direction transforms
-- ============================================================================

---local point -> world. world = t + R * p
function coords.point_to_world(cf, px, py, pz)
    return cf.x + cf.r00 * px + cf.r01 * py + cf.r02 * pz,
        cf.y + cf.r10 * px + cf.r11 * py + cf.r12 * pz,
        cf.z + cf.r20 * px + cf.r21 * py + cf.r22 * pz
end

---World point -> local. local = R^T * (p - t), valid because R is orthonormal
function coords.point_to_local(cf, px, py, pz)
    local dx, dy, dz = px - cf.x, py - cf.y, pz - cf.z
    return cf.r00 * dx + cf.r10 * dy + cf.r20 * dz,
        cf.r01 * dx + cf.r11 * dy + cf.r21 * dz,
        cf.r02 * dx + cf.r12 * dy + cf.r22 * dz
end

---local direction -> world. no translation, used for velocities, ray directions,
---light directions and constraint axes
function coords.direction_to_world(cf, dx, dy, dz)
    return cf.r00 * dx + cf.r01 * dy + cf.r02 * dz,
        cf.r10 * dx + cf.r11 * dy + cf.r12 * dz,
        cf.r20 * dx + cf.r21 * dy + cf.r22 * dz
end

---World direction -> local
function coords.direction_to_local(cf, dx, dy, dz)
    return cf.r00 * dx + cf.r10 * dy + cf.r20 * dz,
        cf.r01 * dx + cf.r11 * dy + cf.r21 * dz,
        cf.r02 * dx + cf.r12 * dy + cf.r22 * dz
end

-- transform normals with the inverse transpose so they stay perpendicular under nonuniform scale

---transforms a local normal to world space, correct under non-uniform scale
---@param sx number scale applied along local X (must be non-zero)
function coords.normal_to_world(cf, nx, ny, nz, sx, sy, sz)
    -- inverse scale first: S^-1 * n
    local ix = (sx ~= nil and abs(sx) > EPSILON) and (nx / sx) or nx
    local iy = (sy ~= nil and abs(sy) > EPSILON) and (ny / sy) or ny
    local iz = (sz ~= nil and abs(sz) > EPSILON) and (nz / sz) or nz

    -- then rotate: R * (S^-1 * n)
    local wx = cf.r00 * ix + cf.r01 * iy + cf.r02 * iz
    local wy = cf.r10 * ix + cf.r11 * iy + cf.r12 * iz
    local wz = cf.r20 * ix + cf.r21 * iy + cf.r22 * iz

    local len = sqrt(wx * wx + wy * wy + wz * wz)
    if len < EPSILON then
        -- Degenerate: fall back to the un-scaled rotation so the caller still
        -- receives a unit vector rather than NaN
        wx, wy, wz = cf.r00 * nx + cf.r01 * ny + cf.r02 * nz,
            cf.r10 * nx + cf.r11 * ny + cf.r12 * nz,
            cf.r20 * nx + cf.r21 * ny + cf.r22 * nz
        len = sqrt(wx * wx + wy * wy + wz * wz)
        if len < EPSILON then return 0, 1, 0 end
    end
    return wx / len, wy / len, wz / len
end

---returns the 3x3 normal matrix (inverse-transpose of R*S) in row-major order
---use when transforming many normals under one transform, or when handing a
---uniform to a shader
function coords.normal_matrix(cf, sx, sy, sz)
    local ax = (sx ~= nil and abs(sx) > EPSILON) and (1 / sx) or 1
    local ay = (sy ~= nil and abs(sy) > EPSILON) and (1 / sy) or 1
    local az = (sz ~= nil and abs(sz) > EPSILON) and (1 / sz) or 1
    return cf.r00 * ax, cf.r01 * ay, cf.r02 * az,
        cf.r10 * ax, cf.r11 * ay, cf.r12 * az,
        cf.r20 * ax, cf.r21 * ay, cf.r22 * az
end

-- transform a tangent with the linear transform and a normal with its inverse transpose
-- orthogonalize the tangent against the transformed normal before deriving the bitangent

---transforms a local tangent to world space and re-orthogonalises it against the
---already-transformed world normal
---
---takes the basis as loose numbers rather than a CFrame table because the call
---site is a per-vertex loop: building a table per vertex would allocate millions
---of times per bake. `coords.tangent_to_world` is the CFrame-shaped wrapper
---
---@param rx number local +X axis in world space (CFrame RightVector, column 0)
---@param ux number local +Y axis in world space (UpVector, column 1)
---@param bx number local +Z axis in world space (back, i.e. -LookVector, column 2)
---@param sx number|nil SIGNED scale along local X -- pass the same scale the
---POSITIONS were multiplied by, sign included, so a mirrored part's tangent
---mirrors with its geometry
---@param nwx number|nil world normal to orthogonalise against; must already be
---unit length. pass nil to skip the Gram-Schmidt step
---@return number,number,number unit world tangent, or 0,0,0 when degenerate
---(tangent parallel to the normal, or a zero scale collapsed it) -- the same
---"no tangent" signal the shaders already test for with dot(t, t) > epsilon
function coords.tangent_to_world_basis(rx, ry, rz, ux, uy, uz, bx, by, bz,
                                       tx, ty, tz, sx, sy, sz, nwx, nwy, nwz)
    -- POSITION rule: multiply by the scale
    local lx = tx * (sx or 1)
    local ly = ty * (sy or 1)
    local lz = tz * (sz or 1)

    local wx = rx * lx + ux * ly + bx * lz
    local wy = ry * lx + uy * ly + by * lz
    local wz = rz * lx + uz * ly + bz * lz

    if nwx ~= nil then
        local d = wx * nwx + wy * nwy + wz * nwz
        wx = wx - nwx * d
        wy = wy - nwy * d
        wz = wz - nwz * d
    end

    local len = sqrt(wx * wx + wy * wy + wz * wz)
    if len < EPSILON then return 0, 0, 0 end
    return wx / len, wy / len, wz / len
end

---CFrame-shaped wrapper around tangent_to_world_basis
---@param cf table CFrame in the flat r00..r22 layout
function coords.tangent_to_world(cf, tx, ty, tz, sx, sy, sz, nwx, nwy, nwz)
    return coords.tangent_to_world_basis(
        cf.r00, cf.r10, cf.r20,
        cf.r01, cf.r11, cf.r21,
        cf.r02, cf.r12, cf.r22,
        tx, ty, tz, sx, sy, sz, nwx, nwy, nwz)
end

---true when a scale triple flips triangle winding (an odd number of negative
---components). Callers must swap their index order when this is true, otherwise
---back-face culling removes the wrong faces
function coords.scale_flips_winding(sx, sy, sz)
    local negatives = 0
    if (sx or 1) < 0 then negatives = negatives + 1 end
    if (sy or 1) < 0 then negatives = negatives + 1 end
    if (sz or 1) < 0 then negatives = negatives + 1 end
    return (negatives % 2) == 1
end

-- mirror the position and the basis consistently when converting an authored mirrored part

---mirrors a CFrame through the YZ plane (negating world X) by conjugation
---Position mirrors, the rotation stays proper (det +1)
function coords.mirror_x(cf)
    return {
        x = -cf.x, y = cf.y, z = cf.z,
        -- F * R * F with F = diag(-1,1,1): negate the off-diagonal blocks that
        -- mix X with Y/Z, leave r00 and the YZ sub-block alone
        r00 = cf.r00, r01 = -cf.r01, r02 = -cf.r02,
        r10 = -cf.r10, r11 = cf.r11, r12 = cf.r12,
        r20 = -cf.r20, r21 = cf.r21, r22 = cf.r22,
    }
end

---mirrors a POLAR vector (position, linear velocity, force, ray direction)
---the X component flips
function coords.mirror_x_vector(x, y, z)
    return -x, y, z
end

---mirrors an AXIAL vector / pseudovector (angular velocity, torque, a surface
---normal expressed as a cross product). under a reflection these behave
---oppositely to polar vectors: the components PERPENDICULAR to the mirror plane
---are the ones that survive unchanged, so Y and Z flip and X does not
---Getting this backwards makes mirrored maps spin the wrong way
function coords.mirror_x_pseudovector(x, y, z)
    return x, -y, -z
end

-- ============================================================================
-- NormalId faces -- the authoritative table
-- ============================================================================

---Face name -> local-space normal, plus a tangent frame for UV mapping
---tangent runs along the face's +U, bitangent along +V, and
---(tangent x bitangent) == normal for every entry, so the frame is right-handed
---and consistent across all six faces
coords.FACE = {
    Front  = { normal = { 0, 0, -1 }, tangent = { 1, 0, 0 },  bitangent = { 0, -1, 0 } },
    Back   = { normal = { 0, 0, 1 },  tangent = { -1, 0, 0 }, bitangent = { 0, -1, 0 } },
    Right  = { normal = { 1, 0, 0 },  tangent = { 0, 0, 1 },  bitangent = { 0, -1, 0 } },
    Left   = { normal = { -1, 0, 0 }, tangent = { 0, 0, -1 }, bitangent = { 0, -1, 0 } },
    -- these signs keep the top and bottom tangent frames right-handed
    Top    = { normal = { 0, 1, 0 },  tangent = { 1, 0, 0 },  bitangent = { 0, 0, -1 } },
    Bottom = { normal = { 0, -1, 0 }, tangent = { 1, 0, 0 },  bitangent = { 0, 0, 1 } },
}

---Roblox Enum.NormalId numeric values
coords.FACE_BY_ID = {
    [0] = "Right", [1] = "Top", [2] = "Back",
    [3] = "Left", [4] = "Bottom", [5] = "Front",
}

coords.FACE_ID = {
    Right = 0, Top = 1, Back = 2, Left = 3, Bottom = 4, Front = 5,
}

coords.FACE_NAMES = { "Front", "Back", "Right", "Left", "Top", "Bottom" }

---@return number,number,number local-space normal of a face
function coords.face_normal(face_name)
    local face = coords.FACE[face_name]
    if not face then return 0, 0, -1 end
    local n = face.normal
    return n[1], n[2], n[3]
end

---World-space normal of a face on a part, correct under non-uniform scale
function coords.face_normal_to_world(cf, face_name, sx, sy, sz)
    local nx, ny, nz = coords.face_normal(face_name)
    return coords.normal_to_world(cf, nx, ny, nz, sx, sy, sz)
end

---the opposite face
coords.FACE_OPPOSITE = {
    Front = "Back", Back = "Front",
    Right = "Left", Left = "Right",
    Top = "Bottom", Bottom = "Top",
}

---Half-extent of a part along a face's axis, used to place decals and surface
---detail on the correct plane
function coords.face_offset(face_name, sx, sy, sz)
    local nx, ny, nz = coords.face_normal(face_name)
    return nx * sx * 0.5, ny * sy * 0.5, nz * sz * 0.5
end

-- ============================================================================
-- Backend interop -- CFrame to a 4x4 matrix
-- ============================================================================
--
-- LOVE (and therefore Menori) take mat4 uniforms in COLUMN-major order, while a
-- Roblox CFrame is row-major. the transpose happens here once, so no adapter has
-- to remember it. Returned as 16 numbers in the order LOVE expects

---@param sx number|nil per-axis scale baked into the matrix (defaults to 1)
---@return table 16-element column-major matrix
function coords.cframe_to_mat4(cf, sx, sy, sz)
    sx, sy, sz = sx or 1, sy or 1, sz or 1
    -- Column-major: consecutive groups of four are the matrix's columns
    return {
        cf.r00 * sx, cf.r10 * sx, cf.r20 * sx, 0,
        cf.r01 * sy, cf.r11 * sy, cf.r21 * sy, 0,
        cf.r02 * sz, cf.r12 * sz, cf.r22 * sz, 0,
        cf.x, cf.y, cf.z, 1,
    }
end

---Row-major variant, for shaders declared with row-major layout
function coords.cframe_to_mat4_row_major(cf, sx, sy, sz)
    sx, sy, sz = sx or 1, sy or 1, sz or 1
    return {
        cf.r00 * sx, cf.r01 * sy, cf.r02 * sz, cf.x,
        cf.r10 * sx, cf.r11 * sy, cf.r12 * sz, cf.y,
        cf.r20 * sx, cf.r21 * sy, cf.r22 * sz, cf.z,
        0, 0, 0, 1,
    }
end

-- ============================================================================
-- Camera
-- ============================================================================

---Camera CFrame -> the eye/target/up triple a look-at matrix wants
---the target is one stud along the LookVector, any positive distance works, and
---1 keeps the numbers well conditioned
function coords.camera_look_at(cf)
    local lx, ly, lz = coords.look_vector(cf)
    local ux, uy, uz = coords.up_vector(cf)
    return cf.x, cf.y, cf.z,
        cf.x + lx, cf.y + ly, cf.z + lz,
        ux, uy, uz
end

---Roblox Camera.FieldOfView is VERTICAL and in DEGREES
---Backends differ, so convert explicitly rather than passing the raw number
function coords.fov_vertical_radians(field_of_view_degrees)
    return (tonumber(field_of_view_degrees) or 70) * math.pi / 180
end

---Vertical FOV -> horizontal, for a backend that wants horizontal
function coords.fov_vertical_to_horizontal(vertical_radians, aspect)
    return 2 * math.atan(math.tan(vertical_radians * 0.5) * (aspect or 1))
end

-- ============================================================================
-- Lighting
-- ============================================================================

---Sun direction from Roblox's ClockTime and GeographicLatitude
---
---ClockTime is hours 0..24 with 12 = noon (sun overhead) and 6/18 at the
---horizon. GeographicLatitude tilts the arc away from directly overhead
---
---APPROXIMATION, clearly marked: Roblox's exact solar model is not published
---this reproduces the observable behaviour -- sun rises in the east, peaks at
---ClockTime 12 at an altitude set by latitude, sets in the west -- rather than
---claiming to match Roblox's internal maths
---@return number,number,number unit vector pointing FROM the scene TOWARD the sun
function coords.sun_direction(clock_time, geographic_latitude)
    local hours = (tonumber(clock_time) or 12) % 24
    local latitude = (tonumber(geographic_latitude) or 0) * math.pi / 180

    -- Hour angle: 0 at noon, +/-pi at midnight
    local hour_angle = (hours - 12) / 12 * math.pi

    local altitude = math.cos(hour_angle) * math.cos(latitude)
    local east = math.sin(hour_angle)
    local north = math.cos(hour_angle) * math.sin(latitude)

    -- Roblox world axes: +X east, +Y up, +Z south (so north is -Z)
    local x, y, z = east, altitude, -north
    local len = sqrt(x * x + y * y + z * z)
    if len < EPSILON then return 0, 1, 0 end
    return x / len, y / len, z / len
end

---a light's emission direction in world space
---Roblox SpotLight and SurfaceLight emit along the parent part's chosen Face,
---which is why this goes through the authoritative FACE table rather than
---assuming -Z
function coords.light_direction(cf, face_name)
    if face_name == nil then
        return coords.look_vector(cf)
    end
    local nx, ny, nz = coords.face_normal(face_name)
    return coords.direction_to_world(cf, nx, ny, nz)
end

-- ============================================================================
-- Colour
-- ============================================================================
--
-- conf.lua enables gamma-correct rendering, so LOVE linearises sRGB texture
-- reads and converts back on present. Colours supplied as custom vertex
-- attributes or uniforms are NOT converted. Roblox Color3, BrickColor and
-- Lighting colours therefore cross through the helpers below at the GPU
-- boundary. Embedders may disable gamma correction, though: in that mode LOVE
-- leaves color textures in sRGB too, so authored GPU payloads must stay sRGB to
-- match them

---sRGB component (0..1) -> linear. Exact sRGB curve, not the 2.2 approximation
function coords.srgb_to_linear(c)
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

---linear component (0..1) -> sRGB
function coords.linear_to_srgb(c)
    if c <= 0.0031308 then
        return c * 12.92
    end
    return 1.055 * (c ^ (1 / 2.4)) - 0.055
end

---Roblox Color3 (sRGB) -> linear RGB for shader use
function coords.color3_to_linear(r, g, b)
    return coords.srgb_to_linear(r), coords.srgb_to_linear(g), coords.srgb_to_linear(b)
end

local function detect_gpu_linear_space()
    local graphics = love and love.graphics
    local is_gamma_correct = graphics and graphics.isGammaCorrect
    if type(is_gamma_correct) ~= "function" then
        -- workers can parse a scene before a graphics context exists
        return true
    end
    local ok, enabled = pcall(is_gamma_correct)
    if not ok then
        return true
    end
    return enabled == true
end

-- LÖVE fixes this setting when the graphics context is created. cache once:
-- these helpers run for every authored mesh-color component during map load
local detected_gpu_linear_space = detect_gpu_linear_space()

function coords.gpu_color_space_is_linear()
    return detected_gpu_linear_space
end

---Authored sRGB component -> the active custom-shader GPU color space
function coords.srgb_to_gpu(c)
    if coords.gpu_color_space_is_linear() then
        return coords.srgb_to_linear(c)
    end
    return c
end

---Authored Roblox Color3 -> the active custom-shader GPU color space
function coords.color3_to_gpu(r, g, b)
    if coords.gpu_color_space_is_linear() then
        return coords.color3_to_linear(r, g, b)
    end
    return r, g, b
end

return coords
