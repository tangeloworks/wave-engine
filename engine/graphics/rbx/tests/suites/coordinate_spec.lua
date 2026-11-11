-- Coordinate-system and CFrame conformance.
--
-- These are the reference tests for Stage 2 (centralised coordinate layer). They
-- pin the conventions the whole runtime must agree on, so that when the scattered
-- axis swaps are consolidated, any change of meaning shows up here rather than as
-- a visual glitch in one subsystem.
--
-- ROBLOX CONVENTIONS BEING PINNED (verified against Roblox documentation):
--   * Right-handed, Y up, and a part/camera looks down its LOCAL -Z.
--   * CFrame carries position (x,y,z) and a row-major rotation matrix R00..R22,
--     where world = translation + R * localPoint.
--   * The basis vectors are the COLUMNS of R:
--         RightVector = ( R00, R10, R20 )      -- local +X
--         UpVector    = ( R01, R11, R21 )      -- local +Y
--         LookVector   = (-R02,-R12,-R22)      -- local -Z, hence the negation
--   * NormalId face directions in part-local space:
--         Front = -Z   Back = +Z   Right = +X   Left = -X   Top = +Y   Bottom = -Y
--     (Front being -Z is the single most commonly inverted convention in this
--     codebase -- see geometry.lua FACE_AXES vs DECAL_FACE_AXES in the audit.)
--   * a * b composes b into a's local space: (a*b).R = a.R*b.R and
--     (a*b).t = a.t + a.R*b.t.

local suite = {}

local function rot_x(theta)
    local c, s = math.cos(theta), math.sin(theta)
    return { x = 0, y = 0, z = 0,
        r00 = 1, r01 = 0, r02 = 0,
        r10 = 0, r11 = c, r12 = -s,
        r20 = 0, r21 = s, r22 = c }
end

local function rot_y(theta)
    local c, s = math.cos(theta), math.sin(theta)
    return { x = 0, y = 0, z = 0,
        r00 = c, r01 = 0, r02 = s,
        r10 = 0, r11 = 1, r12 = 0,
        r20 = -s, r21 = 0, r22 = c }
end

local function rot_z(theta)
    local c, s = math.cos(theta), math.sin(theta)
    return { x = 0, y = 0, z = 0,
        r00 = c, r01 = -s, r02 = 0,
        r10 = s, r11 = c, r12 = 0,
        r20 = 0, r21 = 0, r22 = 1 }
end

local function at(x, y, z)
    return { x = x, y = y, z = z,
        r00 = 1, r01 = 0, r02 = 0,
        r10 = 0, r11 = 1, r12 = 0,
        r20 = 0, r21 = 0, r22 = 1 }
end

-- Returned as tables, not multiple values: a multi-return spliced into the middle
-- of an argument list is truncated to one value in Lua, which silently corrupts
-- assertions like near3(label, look_vector(cf), 0, 0, -1).
local function right_vector(cf) return { cf.r00, cf.r10, cf.r20 } end
local function up_vector(cf) return { cf.r01, cf.r11, cf.r21 } end
local function look_vector(cf) return { -cf.r02, -cf.r12, -cf.r22 } end

-- Determinant of the rotation block. Must be +1 for a proper rotation; a value
-- of -1 means a reflection sneaked in (the loaded-map X-mirror defect).
local function det(cf)
    return cf.r00 * (cf.r11 * cf.r22 - cf.r12 * cf.r21)
        - cf.r01 * (cf.r10 * cf.r22 - cf.r12 * cf.r20)
        + cf.r02 * (cf.r10 * cf.r21 - cf.r11 * cf.r20)
end

local HALF_PI = math.pi / 2

function suite.run(t, harness)
    local expect = t.expect
    local CF = harness.need("physics/cframe_math.lua")

    local function near3(label, gx, gy, gz, ex, ey, ez, tol)
        tol = tol or 1e-9
        t.assert_that(
            math.abs(gx - ex) <= tol and math.abs(gy - ey) <= tol and math.abs(gz - ez) <= tol,
            "%s: expected (%g, %g, %g), got (%g, %g, %g)", label, ex, ey, ez, gx, gy, gz)
    end

    ---Compares a {x,y,z} basis vector against an expected triple.
    local function near_v(label, v, ex, ey, ez, tol)
        near3(label, v[1], v[2], v[3], ex, ey, ez, tol)
    end

    ------------------------------------------------------------------ identity

    t.describe("CFrame identity", function()
        t.it("unpacks a nil CFrame as the identity", function()
            local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = CF.unpack(nil)
            near3("position", x, y, z, 0, 0, 0)
            near3("row0", r00, r01, r02, 1, 0, 0)
            near3("row1", r10, r11, r12, 0, 1, 0)
            near3("row2", r20, r21, r22, 0, 0, 1)
        end)

        t.it("identity has basis +X right, +Y up, -Z look", function()
            local id = CF.identity()
            near_v("RightVector", right_vector(id), 1, 0, 0)
            near_v("UpVector", up_vector(id), 0, 1, 0)
            near_v("LookVector", look_vector(id), 0, 0, -1)
        end)

        t.it("identity is a proper rotation (det == +1)", function()
            expect(det(CF.identity())):to_be_near(1, 1e-12)
        end)

        t.it("identity composed with itself is the identity", function()
            expect(CF.is_identity(CF.mul(CF.identity(), CF.identity()))):to_be_truthy()
        end)

        t.it("inverse of identity is the identity", function()
            expect(CF.is_identity(CF.inv(CF.identity()))):to_be_truthy()
        end)
    end)

    -------------------------------------------------------- 90-degree rotations

    t.describe("90-degree axis rotations", function()
        t.it("rot X(+90) sends the look vector from -Z to +Y", function()
            -- Rotating (0,0,-1) about +X by +90 degrees yields (0,+1,0).
            near_v("LookVector", look_vector(rot_x(HALF_PI)), 0, 1, 0, 1e-12)
        end)

        t.it("rot X(+90) leaves RightVector on +X", function()
            near_v("RightVector", right_vector(rot_x(HALF_PI)), 1, 0, 0, 1e-12)
        end)

        t.it("rot Y(+90) sends the look vector from -Z to -X", function()
            near_v("LookVector", look_vector(rot_y(HALF_PI)), -1, 0, 0, 1e-12)
        end)

        t.it("rot Y(+90) sends RightVector from +X to -Z", function()
            near_v("RightVector", right_vector(rot_y(HALF_PI)), 0, 0, -1, 1e-12)
        end)

        t.it("rot Z(+90) sends RightVector from +X to +Y", function()
            near_v("RightVector", right_vector(rot_z(HALF_PI)), 0, 1, 0, 1e-12)
        end)

        t.it("rot Z(+90) leaves the look vector on -Z", function()
            near_v("LookVector", look_vector(rot_z(HALF_PI)), 0, 0, -1, 1e-12)
        end)

        t.it("all three 90-degree rotations stay proper (det == +1)", function()
            expect(det(rot_x(HALF_PI))):to_be_near(1, 1e-12)
            expect(det(rot_y(HALF_PI))):to_be_near(1, 1e-12)
            expect(det(rot_z(HALF_PI))):to_be_near(1, 1e-12)
        end)

        t.it("four 90-degree steps about each axis return to the identity", function()
            for _, mk in ipairs({ rot_x, rot_y, rot_z }) do
                local acc = CF.identity()
                for _ = 1, 4 do acc = CF.mul(acc, mk(HALF_PI)) end
                local ok, mp, mr = CF.approx_equal(acc, CF.identity(), 1e-9, 1e-9)
                t.assert_that(ok, "four quarter turns drifted: pos %g rot %g", mp, mr)
            end
        end)
    end)

    ------------------------------------------------------ combined rotations

    t.describe("combined rotations", function()
        t.it("composition is not commutative (X*Y differs from Y*X)", function()
            local xy = CF.mul(rot_x(HALF_PI), rot_y(HALF_PI))
            local yx = CF.mul(rot_y(HALF_PI), rot_x(HALF_PI))
            expect(CF.approx_equal(xy, yx, 1e-9, 1e-9)):to_be_falsy()
        end)

        t.it("X(90) then Y(90) maps local -Z to -X in world space", function()
            -- Applying Y first in X's local frame: look = Rx * (Ry * (0,0,-1)).
            -- Ry(90)*(0,0,-1) = (-1,0,0); Rx(90)*(-1,0,0) = (-1,0,0).
            near_v("LookVector", look_vector(CF.mul(rot_x(HALF_PI), rot_y(HALF_PI))), -1, 0, 0, 1e-12)
        end)

        t.it("a composed rotation stays orthonormal", function()
            local m = CF.mul(CF.mul(rot_x(0.7), rot_y(-1.3)), rot_z(2.1))
            expect(det(m)):to_be_near(1, 1e-9)
            -- every basis column must be unit length
            for _, axis in ipairs({ right_vector(m), up_vector(m), look_vector(m) }) do
                local ax, ay, az = axis[1], axis[2], axis[3]
                expect(math.sqrt(ax * ax + ay * ay + az * az)):to_be_near(1, 1e-9)
            end
        end)

        t.it("inverse of a composed rotation undoes it", function()
            local m = CF.mul(CF.mul(rot_x(0.4), rot_y(1.1)), rot_z(-0.9))
            expect(CF.is_identity(CF.mul(m, CF.inv(m)), 1e-9, 1e-9)):to_be_truthy()
        end)
    end)

    -------------------------------------------------------- negative coordinates

    t.describe("negative coordinates", function()
        t.it("round-trips a negative translation through inverse", function()
            local cf = at(-12.5, -3.25, -100.75)
            expect(CF.is_identity(CF.mul(cf, CF.inv(cf)), 1e-9, 1e-9)):to_be_truthy()
        end)

        t.it("inverse of a pure negative translation negates it", function()
            local inv = CF.inv(at(-12.5, -3.25, -100.75))
            near3("inverse translation", inv.x, inv.y, inv.z, 12.5, 3.25, 100.75, 1e-9)
        end)

        t.it("transforms a point under a rotated, negatively-placed frame", function()
            -- Frame at (-10,-20,-30) rotated +90 about Y. Local +X maps to world -Z.
            local cf = CF.mul(at(-10, -20, -30), rot_y(HALF_PI))
            local x, y, z = CF.transform_point(cf, 1, 0, 0)
            near3("transformed point", x, y, z, -10, -20, -31, 1e-9)
        end)

        t.it("keeps determinant +1 with negative translation", function()
            expect(det(CF.mul(at(-5, -5, -5), rot_z(1.0)))):to_be_near(1, 1e-9)
        end)
    end)

    ------------------------------------------------------ nested model transforms

    t.describe("nested model transforms", function()
        t.it("nesting is associative", function()
            local a = CF.mul(at(10, 0, 0), rot_y(HALF_PI))
            local b = CF.mul(at(0, 5, 0), rot_x(0.3))
            local c = CF.mul(at(0, 0, -2), rot_z(-0.8))
            local left = CF.mul(CF.mul(a, b), c)
            local right = CF.mul(a, CF.mul(b, c))
            local ok, mp, mr = CF.approx_equal(left, right, 1e-9, 1e-9)
            t.assert_that(ok, "(a*b)*c != a*(b*c): pos %g rot %g", mp, mr)
        end)

        t.it("composing then transforming equals transforming step by step", function()
            local parent = CF.mul(at(3, -4, 5), rot_y(0.6))
            local child = CF.mul(at(-1, 2, 0.5), rot_x(-1.2))
            local px, py, pz = 0.25, -0.5, 2

            local cx, cy, cz = CF.transform_point(child, px, py, pz)
            local wx, wy, wz = CF.transform_point(parent, cx, cy, cz)

            local dx, dy, dz = CF.transform_point(CF.mul(parent, child), px, py, pz)
            near3("nested transform", dx, dy, dz, wx, wy, wz, 1e-9)
        end)

        t.it("three levels of nesting stay stable to 1e-9", function()
            local l1 = CF.mul(at(100, 0, 0), rot_y(0.4))
            local l2 = CF.mul(at(0, 50, 0), rot_x(0.9))
            local l3 = CF.mul(at(0, 0, 25), rot_z(-0.2))
            local world = CF.mul(CF.mul(l1, l2), l3)
            expect(det(world)):to_be_near(1, 1e-9)
            -- Inverting the whole chain must return to the origin.
            local ox, oy, oz = CF.transform_point(CF.mul(CF.inv(world), world), 0, 0, 0)
            near3("origin round-trip", ox, oy, oz, 0, 0, 0, 1e-8)
        end)
    end)

    -------------------------------------------------------- camera look direction

    t.describe("camera orientation", function()
        t.it("an unrotated camera looks down -Z", function()
            near_v("LookVector", look_vector(CF.identity()), 0, 0, -1)
        end)

        t.it("yawing the camera +90 about Y turns it to face -X", function()
            near_v("LookVector", look_vector(rot_y(HALF_PI)), -1, 0, 0, 1e-12)
        end)

        t.it("pitching the camera +90 about X turns it to face +Y", function()
            near_v("LookVector", look_vector(rot_x(HALF_PI)), 0, 1, 0, 1e-12)
        end)

        t.it("look, up and right form a right-handed set", function()
            local cf = CF.mul(rot_y(0.8), rot_x(-0.35))
            local rv, uv, lv = right_vector(cf), up_vector(cf), look_vector(cf)
            local rx, ry, rz = rv[1], rv[2], rv[3]
            local ux, uy, uz = uv[1], uv[2], uv[3]
            local lx, ly, lz = lv[1], lv[2], lv[3]
            -- right x up = -look  (because look is -Z, not +Z)
            local cxx = ry * uz - rz * uy
            local cyy = rz * ux - rx * uz
            local czz = rx * uy - ry * ux
            near3("right x up", cxx, cyy, czz, -lx, -ly, -lz, 1e-9)
        end)
    end)

    ------------------------------------------------------------ face directions

    t.describe("NormalId face directions", function()
        -- The single authoritative table Stage 4 will consolidate on.
        local FACES = {
            { "Front", 0, 0, -1 },
            { "Back", 0, 0, 1 },
            { "Right", 1, 0, 0 },
            { "Left", -1, 0, 0 },
            { "Top", 0, 1, 0 },
            { "Bottom", 0, -1, 0 },
        }

        t.it("has the six Roblox face normals in part-local space", function()
            for _, f in ipairs(FACES) do
                local name, ex, ey, ez = f[1], f[2], f[3], f[4]
                local x, y, z = CF.transform_point(CF.identity(), ex, ey, ez)
                near3("face " .. name, x, y, z, ex, ey, ez)
            end
        end)

        t.it("Front is -Z and Back is +Z (not the reverse)", function()
            expect(FACES[1][4]):to_be(-1)
            expect(FACES[2][4]):to_be(1)
        end)

        t.it("opposite faces are exact negations", function()
            local pairs_ = { { 1, 2 }, { 3, 4 }, { 5, 6 } }
            for _, p in ipairs(pairs_) do
                local a, b = FACES[p[1]], FACES[p[2]]
                near3(a[1] .. " vs " .. b[1], a[2], a[3], a[4], -b[2], -b[3], -b[4])
            end
        end)

        t.it("rotating a part by Y(+90) sends its Front face normal to -X", function()
            -- Front (0,0,-1) rotated +90 about Y -> (-1,0,0).
            local cf = rot_y(HALF_PI)
            local x, y, z = cf.r00 * 0 + cf.r01 * 0 + cf.r02 * -1,
                cf.r10 * 0 + cf.r11 * 0 + cf.r12 * -1,
                cf.r20 * 0 + cf.r21 * 0 + cf.r22 * -1
            near3("rotated Front normal", x, y, z, -1, 0, 0, 1e-12)
        end)

        t.it("rotating a part by X(+90) sends its Top face normal to +Z", function()
            -- Top (0,1,0) rotated +90 about X -> (0,0,1).
            local cf = rot_x(HALF_PI)
            local x, y, z = cf.r01, cf.r11, cf.r21
            near3("rotated Top normal", x, y, z, 0, 0, 1, 1e-12)
        end)
    end)

    --------------------------------------------------- reflection / handedness

    t.describe("handedness guards", function()
        t.it("a proper rotation never has a negative determinant", function()
            for _, m in ipairs({ rot_x(0.3), rot_y(-2.2), rot_z(1.7),
                CF.mul(rot_x(0.5), rot_z(-0.5)) }) do
                t.assert_that(det(m) > 0, "determinant went negative: %g", det(m))
            end
        end)

        t.it("detects an X-mirror as an improper transform", function()
            -- The one-sided F*R mirror at scene.lua:9829-9851 produces det == -1.
            -- This test documents the signature so Stage 2 can assert against it.
            local m = rot_y(0.7)
            local mirrored = {
                x = -m.x, y = m.y, z = m.z,
                r00 = -m.r00, r01 = -m.r01, r02 = -m.r02,
                r10 = m.r10, r11 = m.r11, r12 = m.r12,
                r20 = m.r20, r21 = m.r21, r22 = m.r22,
            }
            t.assert_that(det(mirrored) < 0,
                "one-sided mirror should be improper, det = %g", det(mirrored))
        end)

        t.it("conjugation mirror F*R*F stays proper", function()
            -- The correct mirror at scene.lua:3506-3563 keeps det == +1.
            local m = rot_y(0.7)
            local conj = {
                x = -m.x, y = m.y, z = m.z,
                r00 = m.r00, r01 = -m.r01, r02 = -m.r02,
                r10 = -m.r10, r11 = m.r11, r12 = m.r12,
                r20 = -m.r20, r21 = m.r21, r22 = m.r22,
            }
            expect(det(conj)):to_be_near(1, 1e-9)
        end)
    end)

    ----------------------------------------------------------- weld relations

    t.describe("weld / joint frames", function()
        t.it("weld relation p0*c0 == p1*c1 holds for a derived p1", function()
            local p0 = CF.mul(at(5, 10, -3), rot_y(0.9))
            local c0 = CF.mul(at(1, 0, 0), rot_x(0.2))
            local c1 = CF.mul(at(0, -2, 0), rot_z(-0.4))
            local p1 = CF.weld_part1_cframe(p0, c0, c1)
            local ok, mp, mr = CF.weld_relation_ok(p0, c0, p1, c1, 1e-9, 1e-9)
            t.assert_that(ok, "weld relation broken: pos %g rot %g", mp, mr)
        end)

        t.it("a Motor6D transform of identity equals the plain weld", function()
            local p0 = CF.mul(at(0, 4, 0), rot_z(0.3))
            local c0 = at(0, 1, 0)
            local c1 = at(0, -1, 0)
            local weld = CF.weld_part1_cframe(p0, c0, c1)
            local motor = CF.motor6d_part1_cframe(p0, c0, CF.identity(), c1)
            local ok, mp, mr = CF.approx_equal(weld, motor, 1e-9, 1e-9)
            t.assert_that(ok, "motor6d(identity) != weld: pos %g rot %g", mp, mr)
        end)

        t.it("orthonormalize repairs a drifted rotation without moving it far", function()
            local m = rot_y(0.5)
            m.r00 = m.r00 + 1e-3
            m.r11 = m.r11 - 8e-4
            local fixed = CF.orthonormalize_rot(m)
            expect(det(fixed)):to_be_near(1, 1e-9)
            local _, mr = CF.diff(m, fixed)
            t.assert_that(mr < 5e-3, "orthonormalize moved the frame too far: %g", mr)
        end)
    end)
end

return suite
