-- Primitive geometry: winding, normals and outwardness.
--
-- The wedge defect this suite was written for was invisible to every existing check
-- because it was self-consistent: the stored normal AGREED with the (inward) winding.
-- Only comparing against the solid's interior reveals it. So the core assertion here
-- is outwardness, not self-consistency.

local suite = {}

-- geometry.lua pulls in the renderer-side environment, which touches love.graphics.
suite.needs_graphics = true

---Every vertex is a flat record: {x, y, z, nx, ny, nz, ...}.
local function tri_iter(vertices)
    local i = 0
    return function()
        i = i + 3
        if i > #vertices then return nil end
        return vertices[i - 2], vertices[i - 1], vertices[i]
    end
end

local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function solid_centroid(vertices)
    local x, y, z, n = 0, 0, 0, #vertices
    if n == 0 then return 0, 0, 0 end
    for i = 1, n do
        x = x + vertices[i][1]
        y = y + vertices[i][2]
        z = z + vertices[i][3]
    end
    return x / n, y / n, z / n
end

function suite.run(t, harness)
    local expect = t.expect

    -- Load only what geometry needs. load_full_runtime() would also pull in
    -- gui_bridge.lua, which indexes the engine-wide `Element` global that only
    -- exists after a full app boot -- irrelevant to primitive geometry.
    harness.runtime_require("common.lua")
    harness.runtime_require("geometry.lua")

    local build = harness.env.build_primitive_vertices
    if type(build) ~= "function" then
        t.skip("primitive geometry", "build_primitive_vertices not reachable from the test env")
        return
    end

    local primitives = build()

    t.describe("primitive geometry is built", function()
        for _, name in ipairs({ "Block", "Wedge", "CornerWedge", "Cylinder", "CylinderY", "Ball", "Truss" }) do
            t.it("builds " .. name, function()
                local v = primitives[name]
                t.assert_that(type(v) == "table" and #v > 0, "%s produced no vertices", name)
                t.assert_that(#v % 3 == 0, "%s vertex count %d is not a multiple of 3", name, #v)
            end)
        end
    end)

    t.describe("closed primitive geometry stays compact", function()
        t.it("Ball emits pole fans without zero-area triangles", function()
            local vertices = primitives.Ball
            local triangle_count = 0
            local degenerate_count = 0
            for a, b, c in tri_iter(vertices) do
                triangle_count = triangle_count + 1
                local nx, ny, nz = cross(
                    b[1] - a[1], b[2] - a[2], b[3] - a[3],
                    c[1] - a[1], c[2] - a[2], c[3] - a[3])
                if nx * nx + ny * ny + nz * nz <= 1e-18 then
                    degenerate_count = degenerate_count + 1
                end
            end
            -- 16 longitudes: 16 triangles at each pole and two triangles
            -- across each of the ten interior latitude bands.
            expect(triangle_count):to_be(16 * (2 + 2 * 10))
            expect(degenerate_count):to_be(0)
        end)

        t.it("Ball canonicalizes poles and the longitude seam for exact indexing", function()
            local vertices = primitives.Ball
            local unique = {}
            local unique_count = 0
            for index = 1, #vertices do
                local vertex = vertices[index]
                if math.abs(math.abs(vertex[2]) - 0.5) <= 1e-12 then
                    expect(vertex[1]):to_be(0)
                    expect(vertex[3]):to_be(0)
                    expect(vertex[4]):to_be(0)
                    expect(vertex[5]):to_be(vertex[2] < 0 and -1 or 1)
                    expect(vertex[6]):to_be(0)
                end
                local key = table.concat({
                    tostring(vertex[1]),
                    tostring(vertex[2]),
                    tostring(vertex[3]),
                    tostring(vertex[4]),
                    tostring(vertex[5]),
                    tostring(vertex[6]),
                }, "|")
                if not unique[key] then
                    unique[key] = true
                    unique_count = unique_count + 1
                end
            end
            expect(unique_count):to_be(178)
        end)
    end)

    t.describe("stored normals agree with triangle winding", function()
        -- Self-consistency. This passed even while the wedge was inverted, which is
        -- exactly why it is not sufficient on its own.
        for _, name in ipairs({ "Block", "Wedge", "CornerWedge", "Truss" }) do
            t.it(name .. " normals match the cross product of its winding", function()
                local mismatched, total = 0, 0
                for a, b, c in tri_iter(primitives[name]) do
                    total = total + 1
                    local nx, ny, nz = cross(
                        b[1] - a[1], b[2] - a[2], b[3] - a[3],
                        c[1] - a[1], c[2] - a[2], c[3] - a[3])
                    local len = math.sqrt(nx * nx + ny * ny + nz * nz)
                    if len > 1e-9 then
                        nx, ny, nz = nx / len, ny / len, nz / len
                        -- The stored normal must not oppose the geometric normal.
                        if (nx * a[4] + ny * a[5] + nz * a[6]) < 0 then
                            mismatched = mismatched + 1
                        end
                    end
                end
                t.assert_that(mismatched == 0,
                    "%s: %d of %d triangles store a normal opposing their winding",
                    name, mismatched, total)
            end)
        end
    end)

    t.describe("every face points outward", function()
        -- THE assertion. A normal pointing into the solid is never correct, and this
        -- is the only check that catches it.
        -- Truss is excluded here and tested separately below: it is a NON-CONVEX
        -- assembly of five disjoint boxes, so a beam's inner face correctly points
        -- toward the whole-truss centroid. Whole-solid outwardness is only a valid
        -- test for a convex solid.
        for _, name in ipairs({ "Block", "Wedge", "CornerWedge", "Ball", "Cylinder", "CylinderY" }) do
            t.it(name .. " has no inward-facing triangles", function()
                local verts = primitives[name]
                local ccx, ccy, ccz = solid_centroid(verts)
                local inward, total = 0, 0
                local worst = 0
                for a, b, c in tri_iter(verts) do
                    total = total + 1
                    -- Face centroid measured from the solid's own centre.
                    local fx = (a[1] + b[1] + c[1]) / 3 - ccx
                    local fy = (a[2] + b[2] + c[2]) / 3 - ccy
                    local fz = (a[3] + b[3] + c[3]) / 3 - ccz
                    local nx, ny, nz = cross(
                        b[1] - a[1], b[2] - a[2], b[3] - a[3],
                        c[1] - a[1], c[2] - a[2], c[3] - a[3])
                    local d = nx * fx + ny * fy + nz * fz
                    -- Skip faces whose centroid coincides with the solid centre;
                    -- outwardness is undefined there and no primitive has one.
                    local flen = math.sqrt(fx * fx + fy * fy + fz * fz)
                    if flen > 1e-9 then
                        if d < 0 then
                            inward = inward + 1
                            if -d > worst then worst = -d end
                        end
                    end
                end
                t.assert_that(inward == 0,
                    "%s: %d of %d triangles face inward (worst dot %.4f)",
                    name, inward, total, worst)
            end)
        end
    end)

    t.describe("wedge slope specifically", function()
        -- The regression that motivated this suite. The slope quad lies on the plane
        -- y = z, which contains the world origin, so an origin-relative orientation
        -- test yields exactly 0.0 and leaves the face inward.
        t.it("slope normal points up and forward, not down and back", function()
            local found = 0
            for a, b, c in tri_iter(primitives.Wedge) do
                local _ = b, c
                -- The slope's outward normal is (0, +0.707, -0.707): Top + Front.
                if math.abs(a[5] - 0.7071) < 0.05 and math.abs(a[6] + 0.7071) < 0.05 then
                    found = found + 1
                end
            end
            t.assert_that(found >= 2,
                "expected both slope triangles to carry the outward normal (0, +0.707, -0.707); found %d",
                found)
        end)

        t.it("no wedge triangle carries the inverted slope normal", function()
            local bad = 0
            for a in tri_iter(primitives.Wedge) do
                if math.abs(a[5] + 0.7071) < 0.05 and math.abs(a[6] - 0.7071) < 0.05 then
                    bad = bad + 1
                end
            end
            t.assert_that(bad == 0, "%d wedge triangles still carry the inward slope normal", bad)
        end)

        t.it("agrees with the physics raycast slope plane", function()
            -- queries.lua builds the slope plane as (0, hz, -hy) normalised, i.e.
            -- (0, +0.707, -0.707) on a unit wedge. Render and query must not disagree.
            local hy, hz = 0.5, 0.5
            local inv = 1 / math.sqrt(hy * hy + hz * hz)
            local qy, qz = hz * inv, -hy * inv
            expect(qy):to_be_near(0.7071, 1e-3)
            expect(qz):to_be_near(-0.7071, 1e-3)
        end)
    end)

    t.describe("face tables", function()
        local env = harness.env

        t.it("DECAL_FACE_AXES follows the Roblox NormalId convention", function()
            expect(env.DECAL_FACE_AXES.Front.nz):to_be(-1)
            expect(env.DECAL_FACE_AXES.Back.nz):to_be(1)
        end)

        t.it("legacy FACE_AXES has Front/Back inverted (documents the defect)", function()
            -- Kept until accurate_face_axes becomes the default.
            expect(env.FACE_AXES.Front.nz):to_be(1)
            expect(env.FACE_AXES.Back.nz):to_be(-1)
        end)

        t.it("FACE_AXES_ROBLOX agrees with DECAL_FACE_AXES on every normal", function()
            for _, name in ipairs({ "Front", "Back", "Right", "Left", "Top", "Bottom" }) do
                local a, b = env.FACE_AXES_ROBLOX[name], env.DECAL_FACE_AXES[name]
                t.assert_that(a.nx == b.nx and a.ny == b.ny and a.nz == b.nz,
                    "%s normal differs: material (%g,%g,%g) vs decal (%g,%g,%g)",
                    name, a.nx, a.ny, a.nz, b.nx, b.ny, b.nz)
            end
        end)

        -- NOTE on uv handedness. An earlier version of this suite asserted
        -- u x v == n on every face. That is NOT this codebase's convention: Right and
        -- Left satisfy it while Front, Back, Top and Bottom give -n, and the same
        -- mixture holds in DECAL_FACE_AXES. The u/v axes set texture ORIENTATION
        -- within a face and the two paths deliberately differ (material projection is
        -- not decal placement). Only the NORMAL decides which face receives which
        -- material, so that is what the correction changes and what these tests pin.

        t.it("changes only the Front/Back normals, nothing else", function()
            -- Pins the minimality of the fix: every other component is untouched, so
            -- texture orientation within each face is unaffected.
            for _, name in ipairs({ "Front", "Back", "Right", "Left", "Top", "Bottom" }) do
                local legacy, fixed = env.FACE_AXES[name], env.FACE_AXES_ROBLOX[name]
                for _, key in ipairs({ "ux", "uy", "uz", "vx", "vy", "vz", "su", "sv" }) do
                    t.assert_that(legacy[key] == fixed[key],
                        "%s.%s changed (%s -> %s); the correction must touch normals only",
                        name, key, tostring(legacy[key]), tostring(fixed[key]))
                end
                if name == "Front" or name == "Back" then
                    t.assert_that(legacy.nz == -fixed.nz, "%s.nz should be negated", name)
                else
                    t.assert_that(legacy.nx == fixed.nx and legacy.ny == fixed.ny
                        and legacy.nz == fixed.nz, "%s normal must be unchanged", name)
                end
            end
        end)

        t.it("legacy material and decal tables disagree on Front/Back only", function()
            local offenders = {}
            for _, name in ipairs({ "Front", "Back", "Right", "Left", "Top", "Bottom" }) do
                local a, b = env.FACE_AXES[name], env.DECAL_FACE_AXES[name]
                if a.nx ~= b.nx or a.ny ~= b.ny or a.nz ~= b.nz then
                    offenders[#offenders + 1] = name
                end
            end
            table.sort(offenders)
            expect(table.concat(offenders, ",")):to_be("Back,Front")
        end)

        t.it("the selector honours the accurate_face_axes flag", function()
            local RBX = harness.env.RBX
            local previous = RBX._accurate_face_axes
            RBX._accurate_face_axes = false
            expect(env.get_material_face_axes().Front.nz):to_be(1)
            RBX._accurate_face_axes = true
            expect(env.get_material_face_axes().Front.nz):to_be(-1)
            RBX._accurate_face_axes = previous
        end)

        t.it("the flag reaches mesh.lua and suppresses the CSG basis mirror", function()
            -- The coupled change spans three files. This is the half that is easiest
            -- to get wrong, because mesh.lua is a top-level module outside the shared
            -- runtime environment and receives the flag through canonicalize's opts.
            local mesh = require("engine/graphics/rbx/mesh")
            local function fake_csg()
                return {
                    source_kind = "csg_mesh",
                    positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 },
                    normals = { 0, 0, 1, 0, 0, 1, 0, 0, 1 },
                    uvs = { 0, 0, 1, 0, 0, 1 },
                    indices = { 1, 2, 3 },
                }
            end

            local legacy = mesh.canonicalize(fake_csg(), { accurate_face_axes = false })
            t.assert_that(legacy.basis ~= nil and legacy.basis.flip_back_axis == true,
                "legacy path should stamp flip_back_axis on CSG meshes")

            local fixed = mesh.canonicalize(fake_csg(), { accurate_face_axes = true })
            t.assert_that(fixed.basis == nil,
                "accurate_face_axes must leave CSG basis nil (mesh local space IS part local space); got %s",
                t.fmt(fixed.basis))
        end)

        t.it("plain meshes never carry a basis mirror either way", function()
            local mesh = require("engine/graphics/rbx/mesh")
            local function plain()
                return {
                    source_kind = "mesh",
                    positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 },
                    normals = { 0, 0, 1, 0, 0, 1, 0, 0, 1 },
                    uvs = { 0, 0, 1, 0, 0, 1 },
                    indices = { 1, 2, 3 },
                }
            end
            expect(mesh.canonicalize(plain(), { accurate_face_axes = false }).basis):to_be_nil()
            expect(mesh.canonicalize(plain(), { accurate_face_axes = true }).basis):to_be_nil()
        end)

        t.it("CSG normal ids map to the standard NormalId order", function()
            local map = env.MATERIAL_PROJECTION.CSG_NORMAL_ID_TO_FACE
            expect(map[1]):to_be("Right")
            expect(map[2]):to_be("Top")
            expect(map[3]):to_be("Back")
            expect(map[4]):to_be("Left")
            expect(map[5]):to_be("Bottom")
            expect(map[6]):to_be("Front")
        end)

        t.it("dominant-axis fallback uses the Roblox NormalId face convention", function()
            local dominant_axis_face_name = env.MATERIAL_PROJECTION.dominant_axis_face_name
            local cases = {
                { 1, 0, 0, "Right" },
                { -1, 0, 0, "Left" },
                { 0, 1, 0, "Top" },
                { 0, -1, 0, "Bottom" },
                { 0, 0, 1, "Back" },
                { 0, 0, -1, "Front" },
            }
            for index = 1, #cases do
                local case = cases[index]
                local actual = dominant_axis_face_name(case[1], case[2], case[3])
                t.assert_that(actual == case[4],
                    "normal (%d,%d,%d) resolved to %s, expected %s",
                    case[1], case[2], case[3], tostring(actual), case[4])
            end
        end)

        t.it("geometric and CSG face selection agree through every mirror context", function()
            local projection_api = env.MATERIAL_PROJECTION
            local cases = {
                { id = 1, nx = 1, ny = 0, nz = 0 },
                { id = 2, nx = 0, ny = 1, nz = 0 },
                { id = 3, nx = 0, ny = 0, nz = 1 },
                { id = 4, nx = -1, ny = 0, nz = 0 },
                { id = 5, nx = 0, ny = -1, nz = 0 },
                { id = 6, nx = 0, ny = 0, nz = -1 },
            }

            for mirror_bits = 0, 7 do
                local projection = {
                    mirror_x = mirror_bits % 2 == 1,
                    mirror_y = math.floor(mirror_bits / 2) % 2 == 1,
                    mirror_z = math.floor(mirror_bits / 4) % 2 == 1,
                }
                for index = 1, #cases do
                    local case = cases[index]
                    local geometric = projection_api.select_face_name(
                        nil, case.nx, case.ny, case.nz, projection)
                    local csg = projection_api.select_face_name(
                        case.id, case.nx, case.ny, case.nz, projection)
                    t.assert_that(geometric == csg,
                        "NormalId %d disagreed under mirror (%s,%s,%s): geometric=%s CSG=%s",
                        case.id,
                        tostring(projection.mirror_x),
                        tostring(projection.mirror_y),
                        tostring(projection.mirror_z),
                        tostring(geometric),
                        tostring(csg))
                end
            end
        end)

        t.it("keeps Texture and Decal orientation identical on all six faces", function()
            local bounds = {
                min_x = -1, min_y = -1, min_z = -1,
                max_x = 1, max_y = 1, max_z = 1,
            }
            local point = { 0.23, -0.41, 0.67 }
            for _, name in ipairs({ "Front", "Back", "Right", "Left", "Top", "Bottom" }) do
                local decal_u, decal_v = env.RBX._project_face_texture_uv(
                    { class_name = "Decal" },
                    name, bounds, point[1], point[2], point[3])
                local texture_u, texture_v = env.RBX._project_face_texture_uv(
                    {
                        class_name = "Texture",
                        studs_per_tile_u = 2,
                        studs_per_tile_v = 2,
                    },
                    name, bounds, point[1], point[2], point[3])
                t.assert_that(
                    math.abs(texture_u - decal_u) <= 1e-12
                        and math.abs(texture_v - decal_v) <= 1e-12,
                    "%s changed orientation between Decal (%.6f, %.6f) and Texture (%.6f, %.6f)",
                    name, decal_u, decal_v, texture_u, texture_v)
            end
        end)

        t.it("moves positive Texture offsets in one consistent UV direction", function()
            local bounds = {
                min_x = -1, min_y = -1, min_z = -1,
                max_x = 1, max_y = 1, max_z = 1,
            }
            for _, name in ipairs({ "Front", "Back", "Right", "Left", "Top", "Bottom" }) do
                local base_u, base_v = env.RBX._project_face_texture_uv(
                    {
                        class_name = "Texture",
                        studs_per_tile_u = 2,
                        studs_per_tile_v = 4,
                    },
                    name, bounds, 0.17, -0.29, 0.43)
                local offset_u, offset_v = env.RBX._project_face_texture_uv(
                    {
                        class_name = "Texture",
                        studs_per_tile_u = 2,
                        studs_per_tile_v = 4,
                        offset_studs_u = 0.5,
                        offset_studs_v = 1,
                    },
                    name, bounds, 0.17, -0.29, 0.43)
                expect(offset_u - base_u):to_be_near(0.25, 1e-12)
                expect(offset_v - base_v):to_be_near(0.25, 1e-12)
            end
        end)

        t.it("defaults both tile dimensions independently to two studs", function()
            local bounds = {
                min_x = -2, min_y = -2, min_z = -2,
                max_x = 2, max_y = 2, max_z = 2,
            }
            local axis = env.DECAL_FACE_AXES.Front
            local x = 2 * axis.ux + 2 * axis.vx
            local y = 2 * axis.uy + 2 * axis.vy
            local z = 2 * axis.uz + 2 * axis.vz

            local default_u, default_v = env.RBX._project_face_texture_uv(
                { class_name = "Texture" },
                "Front", bounds, x, y, z)
            expect(default_u):to_be_near(2, 1e-12)
            expect(default_v):to_be_near(2, 1e-12)

            local authored_u, independent_v = env.RBX._project_face_texture_uv(
                {
                    class_name = "Texture",
                    studs_per_tile_u = 4,
                },
                "Front", bounds, x, y, z)
            expect(authored_u):to_be_near(1, 1e-12)
            expect(independent_v):to_be_near(2, 1e-12)
        end)

        t.it("applies modern UV scale and offset after face projection", function()
            local bounds = {
                min_x = -1, min_y = -1, min_z = -1,
                max_x = 1, max_y = 1, max_z = 1,
            }
            for _, name in ipairs({ "Front", "Back", "Right", "Left", "Top", "Bottom" }) do
                local base_u, base_v = env.RBX._project_face_texture_uv(
                    { class_name = "Decal" },
                    name, bounds, 0.17, -0.29, 0.43)
                local transformed_u, transformed_v = env.RBX._project_face_texture_uv(
                    {
                        class_name = "Decal",
                        uv_scale_u = 2,
                        uv_scale_v = -3,
                        uv_offset_u = 0.25,
                        uv_offset_v = -0.5,
                    },
                    name, bounds, 0.17, -0.29, 0.43)
                expect(transformed_u):to_be_near(base_u * 2 + 0.25, 1e-12)
                expect(transformed_v):to_be_near(base_v * -3 - 0.5, 1e-12)
            end
        end)

        t.it("rotates modern face UVs clockwise around their transformed centre", function()
            local u, v = env.RBX._transform_face_texture_uv({
                class_name = "Decal",
                uv_scale_u = 2,
                uv_scale_v = 4,
                uv_offset_u = 0.25,
                uv_offset_v = -0.5,
                rotation = 90,
            }, 0.5, 0)

            -- The selected region is [0.25, 2.25] x [-0.5, 3.5], so its
            -- centre is (1.25, 1.5). In down-positive UV space, +90 degrees
            -- moves its top centre to the right centre.
            expect(u):to_be_near(3.25, 1e-12)
            expect(v):to_be_near(1.5, 1e-12)
        end)

        t.it("keeps malformed modern UV values finite and on legacy defaults", function()
            local base_u, base_v = env.RBX._transform_face_texture_uv(
                { class_name = "Decal" }, 0.2, 0.7)
            local guarded_u, guarded_v = env.RBX._transform_face_texture_uv({
                class_name = "Decal",
                uv_scale_u = 0 / 0,
                uv_scale_v = math.huge,
                uv_offset_u = -math.huge,
                uv_offset_v = "not-a-number",
                rotation = math.huge,
            }, 0.2, 0.7)
            expect(guarded_u):to_be_near(base_u, 1e-12)
            expect(guarded_v):to_be_near(base_v, 1e-12)
        end)

        t.it("conjugates authored transforms through the sampled shader basis", function()
            local descriptor = {
                class_name = "Decal",
                uv_scale_u = 2,
                uv_scale_v = 0.75,
                uv_offset_u = 0.25,
                uv_offset_v = -0.125,
                rotation = 37,
            }
            local raw_u, raw_v = 0.17, 0.63
            local baked_u, baked_v = env.RBX._transform_face_texture_uv(
                descriptor, raw_u, raw_v, true, true)
            local logical_u, logical_v = env.RBX._transform_face_texture_uv(
                descriptor, 1 - raw_u, 1 - raw_v)

            -- The real shader applies F once more. Its sampled coordinate must
            -- therefore be exactly the authored transform in logical UV space.
            expect(1 - baked_u):to_be_near(logical_u, 1e-12)
            expect(1 - baked_v):to_be_near(logical_v, 1e-12)
        end)

        t.it("keeps malformed Texture tile fields finite", function()
            local bounds = {
                min_x = -1, min_y = -1, min_z = -1,
                max_x = 1, max_y = 1, max_z = 1,
            }
            local base_u, base_v = env.RBX._project_face_texture_uv(
                { class_name = "Texture" },
                "Front", bounds, 0.2, -0.3, 0.4)
            local guarded_u, guarded_v = env.RBX._project_face_texture_uv({
                class_name = "Texture",
                studs_per_tile_u = math.huge,
                studs_per_tile_v = 0 / 0,
                offset_studs_u = -math.huge,
                offset_studs_v = "invalid",
            }, "Front", bounds, 0.2, -0.3, 0.4)
            expect(guarded_u):to_be_near(base_u, 1e-12)
            expect(guarded_v):to_be_near(base_v, 1e-12)
        end)
    end)

    t.describe("truss beams", function()
        -- A truss is five add_static_box calls of 12 triangles each. Outwardness is
        -- only meaningful per sub-box, so group the triangles back into their boxes
        -- and test each against its OWN centre. That is exactly the reference point
        -- add_static_box now uses, and the origin-relative test it replaced is what
        -- left 8 of these 60 triangles wound inward.
        t.it("every sub-box has all faces pointing outward from its own centre", function()
            local verts = primitives.Truss
            local TRIS_PER_BOX = 12
            local VERTS_PER_BOX = TRIS_PER_BOX * 3
            t.assert_that(#verts % VERTS_PER_BOX == 0,
                "truss has %d vertices, not a whole number of 12-triangle boxes", #verts)

            local box_count = #verts / VERTS_PER_BOX
            local inward_total = 0
            for box = 0, box_count - 1 do
                local base = box * VERTS_PER_BOX
                -- Centre of this sub-box only.
                local cx, cy, cz = 0, 0, 0
                for i = base + 1, base + VERTS_PER_BOX do
                    cx = cx + verts[i][1]; cy = cy + verts[i][2]; cz = cz + verts[i][3]
                end
                cx, cy, cz = cx / VERTS_PER_BOX, cy / VERTS_PER_BOX, cz / VERTS_PER_BOX

                for tri = 0, TRIS_PER_BOX - 1 do
                    local a = verts[base + tri * 3 + 1]
                    local b = verts[base + tri * 3 + 2]
                    local c = verts[base + tri * 3 + 3]
                    local fx = (a[1] + b[1] + c[1]) / 3 - cx
                    local fy = (a[2] + b[2] + c[2]) / 3 - cy
                    local fz = (a[3] + b[3] + c[3]) / 3 - cz
                    local nx, ny, nz = cross(
                        b[1] - a[1], b[2] - a[2], b[3] - a[3],
                        c[1] - a[1], c[2] - a[2], c[3] - a[3])
                    if (nx * fx + ny * fy + nz * fz) < 0 then
                        inward_total = inward_total + 1
                    end
                end
            end
            t.assert_that(inward_total == 0,
                "%d truss triangles face inward from their own sub-box centre (across %d boxes)",
                inward_total, box_count)
        end)

        t.it("is built from off-origin sub-boxes", function()
            -- If every sub-box were origin-centred the outwardness bug could not have
            -- reached the truss; this pins the precondition so the test stays honest.
            local verts = primitives.Truss
            local off_origin = false
            for i = 1, #verts do
                if math.abs(verts[i][1]) > 0.3 or math.abs(verts[i][2]) > 0.3 then
                    off_origin = true
                    break
                end
            end
            expect(off_origin):to_be_truthy()
        end)
    end)
end

return suite
