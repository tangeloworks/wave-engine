-- Conformance tests for runtime/coords.lua, the centralised coordinate layer.
--
-- coordinate_spec.lua pins the CONVENTIONS against cframe_math.lua.
-- This suite pins the centralised MODULE that every subsystem must route through,
-- including the cases the scattered implementations get wrong: normal transforms
-- under non-uniform scale, the mirror, the face table, and sRGB colour.

local suite = {}

local function cf(x, y, z, r)
    r = r or { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    return {
        x = x, y = y, z = z,
        r00 = r[1], r01 = r[2], r02 = r[3],
        r10 = r[4], r11 = r[5], r12 = r[6],
        r20 = r[7], r21 = r[8], r22 = r[9],
    }
end

local function rot_y(theta)
    local c, s = math.cos(theta), math.sin(theta)
    return cf(0, 0, 0, { c, 0, s, 0, 1, 0, -s, 0, c })
end

local function rot_z(theta)
    local c, s = math.cos(theta), math.sin(theta)
    return cf(0, 0, 0, { c, -s, 0, s, c, 0, 0, 0, 1 })
end

local HALF_PI = math.pi / 2

function suite.run(t, harness)
    local expect = t.expect
    local coords = harness.need("coords.lua")

    local function near3(label, gx, gy, gz, ex, ey, ez, tol)
        tol = tol or 1e-9
        t.assert_that(
            math.abs(gx - ex) <= tol and math.abs(gy - ey) <= tol and math.abs(gz - ez) <= tol,
            "%s: expected (%g, %g, %g), got (%g, %g, %g)", label, ex, ey, ez, gx, gy, gz)
    end


    ---Packs a multi-return into a table. Lua expands a multi-return fully only when
    ---it is the LAST argument, so v3(f()) is what lets an assertion see all three
    ---components instead of silently truncating to the first.
    local function v3(a, b, c) return { a, b, c } end

    ---Compares a packed {x,y,z} against an expected triple.
    local function near_v(label, got, ex, ey, ez, tol)
        near3(label, got[1], got[2], got[3], ex, ey, ez, tol)
    end

    t.describe("coords: identity conversions are deliberate", function()
        t.it("position passes through unchanged", function()
            near_v("position", v3(coords.position(1, -2, 3)), 1, -2, 3)
        end)

        t.it("direction passes through unchanged", function()
            near_v("direction", v3(coords.direction(0, 0, -1)), 0, 0, -1)
        end)

        t.it("size returns absolute extents", function()
            -- A negative Size cannot be authored in Studio but a malformed file can
            -- carry one; abs() here stops it inverting winding downstream.
            near_v("size", v3(coords.size(-4, 2, -6)), 4, 2, 6)
        end)
    end)

    t.describe("coords: basis extraction", function()
        t.it("identity gives +X right, +Y up, -Z look", function()
            local id = cf(0, 0, 0)
            near_v("right", v3(coords.right_vector(id)), 1, 0, 0)
            near_v("up", v3(coords.up_vector(id)), 0, 1, 0)
            near_v("look", v3(coords.look_vector(id)), 0, 0, -1)
        end)

        t.it("back_vector is the negation of look_vector", function()
            local m = rot_y(0.7)
            local lx, ly, lz = coords.look_vector(m)
            near_v("back", v3(coords.back_vector(m)), -lx, -ly, -lz)
        end)

        t.it("determinant of a proper rotation is +1", function()
            expect(coords.determinant(rot_y(1.1))):to_be_near(1, 1e-9)
            expect(coords.is_proper_rotation(rot_z(-0.4))):to_be_truthy()
        end)

        t.it("detects an improper (reflected) frame", function()
            local bad = rot_y(0.7)
            bad.r00, bad.r01, bad.r02 = -bad.r00, -bad.r01, -bad.r02
            expect(coords.is_proper_rotation(bad)):to_be_falsy()
            t.assert_that(coords.determinant(bad) < 0, "expected a negative determinant")
        end)
    end)

    t.describe("coords: point and direction transforms", function()
        t.it("round-trips a point through world and back", function()
            local m = rot_y(0.9)
            m.x, m.y, m.z = 10, -5, 3
            local wx, wy, wz = coords.point_to_world(m, 1, 2, 3)
            near_v("round trip", v3(coords.point_to_local(m, wx, wy, wz)), 1, 2, 3, 1e-9)
        end)

        t.it("direction transform ignores translation", function()
            local m = rot_y(0.5)
            local a, b, c = coords.direction_to_world(m, 0, 0, -1)
            m.x, m.y, m.z = 1000, 1000, 1000
            near_v("direction unaffected by translation", v3(coords.direction_to_world(m, 0, 0, -1)), a, b, c)
        end)

        t.it("Y(+90) maps local -Z to world -X", function()
            near_v("rotated", v3(coords.direction_to_world(rot_y(HALF_PI), 0, 0, -1)), -1, 0, 0, 1e-12)
        end)
    end)

    t.describe("coords: normals under non-uniform scale", function()
        -- This is the case assets.lua:4261-4264 gets wrong by omitting the scale
        -- term entirely. The correct transform divides by scale (inverse-transpose);
        -- the buggy one multiplies by the rotation only.

        t.it("is unchanged by uniform scale", function()
            local id = cf(0, 0, 0)
            near_v("uniform", v3(coords.normal_to_world(id, 0, 1, 0, 3, 3, 3)), 0, 1, 0, 1e-9)
        end)

        t.it("tilts a 45-degree normal correctly under non-uniform scale", function()
            -- A 45-degree slope normal (0, 1, -1)/sqrt(2) on a part stretched 4x in Y.
            -- Correct: divide by scale -> (0, 1/4, -1) normalised.
            local id = cf(0, 0, 0)
            local inv = 1 / math.sqrt(2)
            local nx, ny, nz = coords.normal_to_world(id, 0, inv, -inv, 1, 4, 1)

            local ex, ey, ez = 0, (inv / 4), -inv
            local len = math.sqrt(ex * ex + ey * ey + ez * ez)
            near3("scaled normal", nx, ny, nz, ex / len, ey / len, ez / len, 1e-9)
        end)

        t.it("differs measurably from the rotation-only transform", function()
            -- Quantifies the assets.lua defect: same input, two methods, angle between.
            local id = cf(0, 0, 0)
            local inv = 1 / math.sqrt(2)
            local cx, cy, cz = coords.normal_to_world(id, 0, inv, -inv, 1, 4, 1)
            -- Rotation-only (the buggy path): identity rotation then renormalise.
            local bx, by, bz = 0, inv, -inv
            local dot = cx * bx + cy * by + cz * bz
            local angle = math.deg(math.acos(math.max(-1, math.min(1, dot))))
            t.assert_that(angle > 20,
                "expected a large divergence from the rotation-only transform, got %.1f deg", angle)
            print(string.format("        rotation-only normal is off by %.1f degrees at scale (1,4,1)", angle))
        end)

        t.it("returns a unit vector", function()
            local nx, ny, nz = coords.normal_to_world(rot_y(0.6), 0.3, 0.8, -0.5, 2, 0.5, 3)
            expect(math.sqrt(nx * nx + ny * ny + nz * nz)):to_be_near(1, 1e-9)
        end)

        t.it("survives a zero scale component without NaN", function()
            local nx, ny, nz = coords.normal_to_world(cf(0, 0, 0), 0, 1, 0, 1, 0, 1)
            expect(nx):to_be_finite()
            expect(ny):to_be_finite()
            expect(nz):to_be_finite()
        end)

        t.it("normal_matrix agrees with normal_to_world", function()
            local m = rot_y(0.4)
            local sx, sy, sz = 2, 0.5, 3
            local a, b, c, d, e, f, g, h, i = coords.normal_matrix(m, sx, sy, sz)
            local nx, ny, nz = 0.2, 0.9, -0.4
            local mx = a * nx + b * ny + c * nz
            local my = d * nx + e * ny + f * nz
            local mz = g * nx + h * ny + i * nz
            local len = math.sqrt(mx * mx + my * my + mz * mz)
            near_v("matrix vs function", v3(coords.normal_to_world(m, nx, ny, nz, sx, sy, sz)),
                mx / len, my / len, mz / len, 1e-9)
        end)
    end)

    t.describe("coords: tangents under non-uniform scale", function()
        -- A tangent is dP/dU -- a direction ALONG the surface -- so it follows the
        -- POSITION rule (multiply by scale), the exact opposite of the normal rule
        -- (divide by scale). render.lua used the normal rule on tangents, which
        -- rotated the whole TBN basis on every non-uniformly scaled mesh part.

        ---tangent_to_world_basis with an IDENTITY basis prepended. Written as a
        ---wrapper rather than a `basis()` helper because a multi-return only expands
        ---in the LAST argument position -- a `basis(), tx, ty, ...` call silently
        ---passes ONE number and eight nils.
        local function tangent_id(tx, ty, tz, sx, sy, sz, nx, ny, nz)
            return coords.tangent_to_world_basis(
                1, 0, 0,
                0, 1, 0,
                0, 0, 1,
                tx, ty, tz, sx, sy, sz, nx, ny, nz)
        end

        local function angle_between(ax, ay, az, bx, by, bz)
            local d = ax * bx + ay * by + az * bz
            return math.deg(math.acos(math.max(-1, math.min(1, d))))
        end

        t.it("is unchanged by uniform scale", function()
            near_v("uniform", v3(tangent_id(1, 0, 0, 3, 3, 3)), 1, 0, 0, 1e-9)
        end)

        t.it("multiplies by the scale rather than dividing", function()
            -- Local tangent (1,1,0)/sqrt2 at Size (4,1,2). Position rule -> (4,1,0).
            local inv = 1 / math.sqrt(2)
            local tx, ty, tz = tangent_id(inv, inv, 0, 4, 1, 2)
            local len = math.sqrt(17)
            near3("position rule", tx, ty, tz, 4 / len, 1 / len, 0, 1e-9)
        end)

        t.it("the old normal rule was 61.9 degrees off at Size (4,1,2)", function()
            -- The measured number in docs/ORIENTATION.md. Correct = normalize(4,1,0)
            -- at 14.04 deg from +X; the normal rule gives normalize(0.25,1,0) at
            -- 75.96 deg. This pins the magnitude of the defect, not just its sign.
            local inv = 1 / math.sqrt(2)
            local cx, cy, cz = tangent_id(inv, inv, 0, 4, 1, 2)
            -- The old path: divide by scale, then rotate, then renormalise.
            local bx, by, bz = inv / 4, inv / 1, 0
            local blen = math.sqrt(bx * bx + by * by + bz * bz)
            local angle = angle_between(cx, cy, cz, bx / blen, by / blen, bz / blen)
            expect(angle):to_be_near(61.9275, 1e-3)
        end)

        t.it("carries the sign of the scale, so a mirrored part mirrors its tangent", function()
            -- local_scale_* in render.lua is SIGNED (mesh axis * scale * mirror).
            -- A tangent is a position difference, so it must flip with the geometry;
            -- the normal rule's abs() would have left it pointing the old way.
            near_v("mirrored", v3(tangent_id(1, 0, 0, -2, 1, 1)), -1, 0, 0, 1e-9)
        end)

        t.it("Gram-Schmidt is a no-op when the source basis is already orthogonal", function()
            -- Worth pinning because it corrects the stated premise. For a DIAGONAL S,
            --   (S^-1 n) . (S t) = n^T S^-T S t = n . t
            -- so the inverse-transpose normal rule already preserves perpendicularity
            -- exactly, and an orthogonal mesh-space (n, t) stays orthogonal. The
            -- re-orthogonalisation therefore changes nothing here.
            local id = cf(0, 0, 0)
            local inv = 1 / math.sqrt(2)
            -- n = (0,1,1)/sqrt2, t = (0,1,-1)/sqrt2: perpendicular in mesh space.
            local nx, ny, nz = coords.normal_to_world(id, 0, inv, inv, 1, 4, 2)
            local ax, ay, az = tangent_id(0, inv, -inv, 1, 4, 2)
            local bx, by, bz = tangent_id(0, inv, -inv, 1, 4, 2, nx, ny, nz)
            near3("orthogonalised == raw", bx, by, bz, ax, ay, az, 1e-9)
            expect(ax * nx + ay * ny + az * nz):to_be_near(0, 1e-9)
        end)

        t.it("Gram-Schmidt restores orthogonality when the source basis is skewed", function()
            -- Which is the case that actually occurs: mesh.lua recomputes smooth
            -- normals from a crease angle while keeping the authored per-vertex
            -- tangents, so n . t is routinely non-zero in mesh space.
            local id = cf(0, 0, 0)
            local nx, ny, nz = coords.normal_to_world(id, 0, 1, 0, 4, 1, 2)
            local skew = 1 / math.sqrt(2) -- t = (1,1,0)/sqrt2, 45 deg off the normal
            local rx, ry, rz = tangent_id(skew, skew, 0, 4, 1, 2)
            local ox, oy, oz = tangent_id(skew, skew, 0, 4, 1, 2, nx, ny, nz)
            t.assert_that(math.abs(rx * nx + ry * ny + rz * nz) > 0.2,
                "expected the raw tangent to be skewed, dot was %g", rx * nx + ry * ny + rz * nz)
            expect(ox * nx + oy * ny + oz * nz):to_be_near(0, 1e-9)
            near_v("orthogonalised", { ox, oy, oz }, 1, 0, 0, 1e-9)
        end)

        t.it("returns a unit vector", function()
            local m = rot_y(0.6)
            local tx, ty, tz = coords.tangent_to_world(m, 0.3, 0.8, -0.5, 2, 0.5, 3)
            expect(math.sqrt(tx * tx + ty * ty + tz * tz)):to_be_near(1, 1e-9)
        end)

        t.it("signals 'no tangent' with a zero vector instead of NaN", function()
            -- Tangent parallel to the normal: Gram-Schmidt annihilates it. Zero is
            -- the signal the shaders already test for (dot(vTangent, vTangent) > eps),
            -- so it must not be NaN and must not be a silently wrong direction.
            local tx, ty, tz = tangent_id(0, 1, 0, 1, 1, 1, 0, 1, 0)
            near3("degenerate", tx, ty, tz, 0, 0, 0, 0)
            local zx, zy, zz = tangent_id(1, 0, 0, 0, 0, 0)
            expect(zx):to_be_finite()
            expect(zy):to_be_finite()
            expect(zz):to_be_finite()
        end)

        t.it("the CFrame wrapper agrees with the loose-basis form", function()
            -- The wrapper must read the basis vectors as the COLUMNS of R (the
            -- convention documented at the top of coords.lua); a transpose here
            -- would be invisible for a symmetric rotation, so use an asymmetric one.
            local m = rot_z(0.8)
            local loose = v3(coords.tangent_to_world_basis(
                m.r00, m.r10, m.r20, m.r01, m.r11, m.r21, m.r02, m.r12, m.r22,
                0.4, 0.6, -0.2, 3, 1, 2))
            near_v("wrapper", v3(coords.tangent_to_world(m, 0.4, 0.6, -0.2, 3, 1, 2)),
                loose[1], loose[2], loose[3], 1e-12)
        end)
    end)

    t.describe("coords: winding", function()
        t.it("detects a winding flip from an odd number of negative scales", function()
            expect(coords.scale_flips_winding(-1, 1, 1)):to_be_truthy()
            expect(coords.scale_flips_winding(-1, -1, -1)):to_be_truthy()
        end)

        t.it("an even number of negative scales preserves winding", function()
            expect(coords.scale_flips_winding(-1, -1, 1)):to_be_falsy()
            expect(coords.scale_flips_winding(1, 1, 1)):to_be_falsy()
        end)
    end)

    t.describe("coords: mirroring", function()
        t.it("mirror_x keeps the rotation proper (det stays +1)", function()
            -- The one-sided F*R mirror at scene.lua:9829-9851 produces det -1.
            expect(coords.determinant(coords.mirror_x(rot_y(0.7)))):to_be_near(1, 1e-9)
            expect(coords.determinant(coords.mirror_x(rot_z(-1.2)))):to_be_near(1, 1e-9)
        end)

        t.it("mirror_x negates the X position", function()
            local m = coords.mirror_x(cf(10, 5, -3))
            near3("mirrored position", m.x, m.y, m.z, -10, 5, -3)
        end)

        t.it("mirroring twice is the identity", function()
            local original = rot_y(0.7)
            original.x, original.y, original.z = 4, -2, 9
            local twice = coords.mirror_x(coords.mirror_x(original))
            near3("position", twice.x, twice.y, twice.z, original.x, original.y, original.z, 1e-12)
            for _, k in ipairs({ "r00", "r01", "r02", "r10", "r11", "r12", "r20", "r21", "r22" }) do
                expect(twice[k]):to_be_near(original[k], 1e-12)
            end
        end)

        t.it("mirrors polar and axial vectors oppositely", function()
            -- Linear velocity flips X; angular velocity flips Y and Z.
            near_v("polar", v3(coords.mirror_x_vector(1, 2, 3)), -1, 2, 3)
            near_v("axial", v3(coords.mirror_x_pseudovector(1, 2, 3)), 1, -2, -3)
        end)
    end)

    t.describe("coords: authoritative face table", function()
        t.it("uses the Roblox NormalId directions", function()
            near_v("Front", v3(coords.face_normal("Front")), 0, 0, -1)
            near_v("Back", v3(coords.face_normal("Back")), 0, 0, 1)
            near_v("Right", v3(coords.face_normal("Right")), 1, 0, 0)
            near_v("Left", v3(coords.face_normal("Left")), -1, 0, 0)
            near_v("Top", v3(coords.face_normal("Top")), 0, 1, 0)
            near_v("Bottom", v3(coords.face_normal("Bottom")), 0, -1, 0)
        end)

        t.it("maps the numeric NormalId enum correctly", function()
            expect(coords.FACE_BY_ID[0]):to_be("Right")
            expect(coords.FACE_BY_ID[5]):to_be("Front")
            for id, name in pairs(coords.FACE_BY_ID) do
                expect(coords.FACE_ID[name]):to_be(id)
            end
        end)

        t.it("every face has a right-handed tangent frame", function()
            -- tangent x bitangent must equal the normal, on all six faces.
            for _, name in ipairs(coords.FACE_NAMES) do
                local f = coords.FACE[name]
                local tx, ty, tz = f.tangent[1], f.tangent[2], f.tangent[3]
                local bx, by, bz = f.bitangent[1], f.bitangent[2], f.bitangent[3]
                near3(name .. " tangent frame",
                    ty * bz - tz * by, tz * bx - tx * bz, tx * by - ty * bx,
                    f.normal[1], f.normal[2], f.normal[3], 1e-12)
            end
        end)

        t.it("opposite faces negate", function()
            for name, opposite in pairs(coords.FACE_OPPOSITE) do
                local ax, ay, az = coords.face_normal(name)
                near3(name .. " vs " .. opposite, ax, ay, az,
                    -select(1, coords.face_normal(opposite)),
                    -select(2, coords.face_normal(opposite)),
                    -select(3, coords.face_normal(opposite)))
            end
        end)

        t.it("places a face at the correct half-extent", function()
            near_v("Top of a 4x6x8 part", v3(coords.face_offset("Top", 4, 6, 8)), 0, 3, 0)
            near_v("Front of a 4x6x8 part", v3(coords.face_offset("Front", 4, 6, 8)), 0, 0, -4)
        end)

        t.it("rotates a face normal into world space", function()
            -- Front (-Z) on a part yawed +90 about Y points to world -X.
            near_v("rotated Front", v3(coords.face_normal_to_world(rot_y(HALF_PI), "Front", 1, 1, 1)),
                -1, 0, 0, 1e-9)
        end)
    end)

    t.describe("coords: backend matrix interop", function()
        t.it("produces a column-major mat4 with translation in the last column", function()
            local m = coords.cframe_to_mat4(cf(7, 8, 9))
            expect(#m):to_be(16)
            expect(m[13]):to_be_near(7, 1e-12)
            expect(m[14]):to_be_near(8, 1e-12)
            expect(m[15]):to_be_near(9, 1e-12)
            expect(m[16]):to_be_near(1, 1e-12)
        end)

        t.it("bakes scale into the basis columns", function()
            local m = coords.cframe_to_mat4(cf(0, 0, 0), 2, 3, 4)
            expect(m[1]):to_be_near(2, 1e-12)  -- column 0 = local X * sx
            expect(m[6]):to_be_near(3, 1e-12)  -- column 1 = local Y * sy
            expect(m[11]):to_be_near(4, 1e-12) -- column 2 = local Z * sz
        end)

        t.it("row-major variant is the transpose of the column-major one", function()
            local m = rot_y(0.8)
            m.x, m.y, m.z = 1, 2, 3
            local col = coords.cframe_to_mat4(m)
            local rowm = coords.cframe_to_mat4_row_major(m)
            for r = 0, 3 do
                for c = 0, 3 do
                    expect(rowm[r * 4 + c + 1]):to_be_near(col[c * 4 + r + 1], 1e-12)
                end
            end
        end)
    end)

    t.describe("coords: camera", function()
        t.it("look_at target sits one stud along the LookVector", function()
            local ex, ey, ez, tx, ty, tz = coords.camera_look_at(cf(5, 5, 5))
            near3("eye", ex, ey, ez, 5, 5, 5)
            near3("target", tx, ty, tz, 5, 5, 4) -- looking down -Z
        end)

        t.it("treats FieldOfView as vertical degrees", function()
            expect(coords.fov_vertical_radians(90)):to_be_near(math.pi / 2, 1e-12)
            expect(coords.fov_vertical_radians(nil)):to_be_near(70 * math.pi / 180, 1e-12)
        end)

        t.it("horizontal FOV exceeds vertical on a wide aspect", function()
            local v = coords.fov_vertical_radians(70)
            t.assert_that(coords.fov_vertical_to_horizontal(v, 16 / 9) > v,
                "horizontal FOV should exceed vertical at 16:9")
            expect(coords.fov_vertical_to_horizontal(v, 1)):to_be_near(v, 1e-12)
        end)
    end)

    t.describe("coords: lighting", function()
        t.it("puts the sun overhead at noon on the equator", function()
            near_v("noon sun", v3(coords.sun_direction(12, 0)), 0, 1, 0, 1e-9)
        end)

        t.it("puts the sun below the horizon at midnight", function()
            local _, y = coords.sun_direction(0, 0)
            t.assert_that(y < 0, "midnight sun should be below the horizon, got y=%g", y)
        end)

        t.it("puts the sun on the horizon at dawn and dusk", function()
            local _, y6 = coords.sun_direction(6, 0)
            local _, y18 = coords.sun_direction(18, 0)
            expect(y6):to_be_near(0, 1e-9)
            expect(y18):to_be_near(0, 1e-9)
        end)

        t.it("rises in the east and sets in the west", function()
            local x_morning = coords.sun_direction(9, 0)
            local x_evening = coords.sun_direction(15, 0)
            t.assert_that(x_morning < 0 and x_evening > 0,
                "sun should travel east to west: morning x=%g evening x=%g", x_morning, x_evening)
        end)

        t.it("returns a unit vector at every clock time", function()
            for hour = 0, 23 do
                local x, y, z = coords.sun_direction(hour, 45)
                expect(math.sqrt(x * x + y * y + z * z)):to_be_near(1, 1e-9)
            end
        end)

        t.it("latitude lowers the noon sun off vertical", function()
            local _, y_equator = coords.sun_direction(12, 0)
            local _, y_high = coords.sun_direction(12, 60)
            t.assert_that(y_high < y_equator, "higher latitude should lower the noon sun")
        end)

        t.it("emits a face light along that face, not always -Z", function()
            -- A SurfaceLight on the Top face emits up, regardless of part rotation.
            near_v("Top light", v3(coords.light_direction(cf(0, 0, 0), "Top")), 0, 1, 0)
            near_v("default light", v3(coords.light_direction(cf(0, 0, 0), nil)), 0, 0, -1)
        end)
    end)

    t.describe("coords: sRGB colour", function()
        t.it("round-trips sRGB through linear", function()
            for _, c in ipairs({ 0, 0.02, 0.25, 0.5, 0.75, 1 }) do
                expect(coords.linear_to_srgb(coords.srgb_to_linear(c))):to_be_near(c, 1e-9)
            end
        end)

        t.it("pins the endpoints", function()
            expect(coords.srgb_to_linear(0)):to_be_near(0, 1e-12)
            expect(coords.srgb_to_linear(1)):to_be_near(1, 1e-9)
        end)

        t.it("mid grey darkens when linearised", function()
            -- The classic symptom of the missing conversion: 0.5 sRGB is ~0.214
            -- linear, so treating sRGB as linear renders markedly too bright.
            expect(coords.srgb_to_linear(0.5)):to_be_near(0.2140, 1e-3)
        end)

        t.it("converts a Color3 triple", function()
            local r, g, b = coords.color3_to_linear(0.5, 0.5, 0.5)
            expect(r):to_be_near(0.2140, 1e-3)
            expect(g):to_be_near(r, 1e-12)
            expect(b):to_be_near(r, 1e-12)
        end)
    end)
end

return suite
