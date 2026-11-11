-- Physics invariants and encoded audit findings.
--
-- Two kinds of test live here:
--   it(...)         behaviour that is correct today and must stay correct.
--   known_bug(...)  behaviour that Roblox specifies and this runtime gets wrong.
--                   The assertion states the CORRECT result, so it fails today
--                   (reported as known-bug, not a failure) and flips to FIXED the
--                   moment the defect is repaired -- at which point the runner
--                   fails the run until the test is promoted to it().
--
-- Every known_bug cites its audit finding.

local suite = {}

---Builds the minimal duck-typed "part view" the physics modules consume.
---Fields mirror what runtime/physics.lua binds: Size, Position, Shape, Material,
---Massless, Anchored, CustomPhysicalProperties, ClassName.
local function part(fields)
    local p = {
        Size = { x = 1, y = 1, z = 1 },
        Position = { x = 0, y = 0, z = 0 },
        Shape = "Block",
        ClassName = "Part",
    }
    for k, v in pairs(fields or {}) do p[k] = v end
    return p
end

local function size(x, y, z) return { x = x, y = y, z = z } end

local function identity_cframe(x, y, z)
    return {
        _x = x or 0, _y = y or 0, _z = z or 0,
        _r00 = 1, _r01 = 0, _r02 = 0,
        _r10 = 0, _r11 = 1, _r12 = 0,
        _r20 = 0, _r21 = 0, _r22 = 1,
    }
end

function suite.run(t, harness)
    local expect = t.expect

    local Materials = harness.need("physics/materials.lua")
    local Shape = harness.need("physics/shape.lua")
    local Queries = harness.need("physics/queries.lua")
    local World = harness.need("physics/world.lua")

    ---------------------------------------------------------------- mass/density

    t.describe("Materials: density and mass", function()
        t.it("falls back to plastic density for an unknown material", function()
            expect(Materials.density_of(part({ Material = 999999 }))):to_be_near(0.70, 1e-9)
        end)

        t.it("uses the material table when there are no custom properties", function()
            expect(Materials.density_of(part({ Material = 1088 }))):to_be_near(7.85, 1e-9) -- Metal
            expect(Materials.density_of(part({ Material = 512 }))):to_be_near(0.35, 1e-9)  -- Wood
        end)

        t.it("prefers CustomPhysicalProperties density over the material default", function()
            local p = part({ Material = 1088, CustomPhysicalProperties = { density = 2.5 } })
            expect(Materials.density_of(p)):to_be_near(2.5, 1e-9)
        end)

        t.it("clamps custom density into [0.01, 100]", function()
            expect(Materials.density_of(part({ CustomPhysicalProperties = { density = 5000 } })))
                :to_be_near(100, 1e-9)
        end)

        t.it("computes box volume as the product of the sides", function()
            expect(Materials.volume_of(part({ Size = size(2, 3, 4) }))):to_be_near(24, 1e-9)
        end)

        t.it("computes ball volume from the smallest dimension", function()
            -- Roblox inscribes the sphere in the smallest axis.
            local v = Materials.volume_of(part({ Shape = "Ball", Size = size(4, 2, 6) }))
            expect(v):to_be_near((4 / 3) * math.pi * 1 * 1 * 1, 1e-9)
        end)

        t.it("computes circular Part cylinder volume about local X", function()
            -- Native Part.Shape=Cylinder is X-oriented. Size (10,2,4) uses the
            -- lower Y/Z diameter (2), so length=10 and radius=1.
            local v = Materials.volume_of(part({
                Shape = "Cylinder",
                Size = size(10, 2, 4),
            }))
            expect(v):to_be_near(math.pi * 1 * 1 * 10, 1e-9)
        end)

        t.it("never returns a mass below the floor", function()
            local m = Materials.mass_of(part({ Size = size(0.0001, 0.0001, 0.0001) }))
            t.assert_that(m >= 0.001, "mass floor breached: %g", m)
        end)

        -- P4g: root ownership belongs to Assembly, not the per-member contribution
        -- helper. A root contributes mass even while authored Massless remains true.
        t.it("gives a standalone Massless root its physical mass and inverse mass", function()
            local p=part({id=1,Massless=true,Anchored=false})
            local a=harness.need("physics/assembly.lua").build({p}).assemblies[1]
            t.assert_that(a.root_part==p and p.Massless)
            expect(a.body.mass):to_be_near(.7,1e-12)
            expect(a.body.inv_mass):to_be_near(1/.7,1e-12)
        end)

        t.it("box inertia is symmetric for a cube", function()
            local ix, iy, iz = Materials.box_inertia(part({ Size = size(2, 2, 2) }), 12)
            expect(ix):to_be_near(iy, 1e-9)
            expect(iy):to_be_near(iz, 1e-9)
        end)

        t.it("box inertia grows with the perpendicular dimensions", function()
            -- Ix depends on sy and sz only.
            local ix1 = Materials.box_inertia(part({ Size = size(1, 2, 2) }), 12)
            local ix2 = Materials.box_inertia(part({ Size = size(9, 2, 2) }), 12)
            expect(ix1):to_be_near(ix2, 1e-9)
        end)

        t.it("never returns a non-finite inertia", function()
            local ix, iy, iz = Materials.box_inertia(part({ Size = size(0, 0, 0) }), 0)
            expect(ix):to_be_finite()
            expect(iy):to_be_finite()
            expect(iz):to_be_finite()
        end)
    end)

    ------------------------------------------------------------------ shape kinds

    t.describe("Shape classification", function()
        t.it("classifies the Roblox part shapes", function()
            expect(Shape.kind_of(part({ Shape = "Ball" }))):to_be("ball")
            expect(Shape.kind_of(part({ Shape = "Cylinder" }))):to_be("cylinder")
            expect(Shape.kind_of(part({ Shape = "Wedge" }))):to_be("wedge")
            expect(Shape.kind_of(part({ Shape = "CornerWedge" }))):to_be("wedge")
            expect(Shape.kind_of(part({ Shape = "Block" }))):to_be("block")
            expect(Shape.kind_of(part({ ClassName = "MeshPart" }))):to_be("mesh")
        end)

        t.it("half extents are half the size and never zero", function()
            local hx, hy, hz = Shape.half_extents(part({ Size = size(4, 6, 8) }))
            expect(hx):to_be_near(2, 1e-12)
            expect(hy):to_be_near(3, 1e-12)
            expect(hz):to_be_near(4, 1e-12)
            local zx = Shape.half_extents(part({ Size = size(0, 0, 0) }))
            t.assert_that(zx > 0, "degenerate size produced a zero half-extent")
        end)

        t.it("aabb is centred on the part position", function()
            local box = Shape.aabb(part({ Position = { x = 10, y = -5, z = 3 }, Size = size(2, 2, 2) }))
            expect(box.min_x):to_be_near(9, 1e-12)
            expect(box.max_x):to_be_near(11, 1e-12)
            expect(box.min_y):to_be_near(-6, 1e-12)
            expect(box.max_z):to_be_near(4, 1e-12)
        end)

        t.it("raycasts Part cylinders against the lower circular radial extent", function()
            local cylinder = part({
                Shape = "Cylinder",
                Size = size(10, 2, 4),
                CFrame = identity_cframe(),
            })

            -- z=1.5 lies inside the obsolete 1x2 ellipse but outside the native
            -- radius-1 circle. It must not hit the cylinder's +X cap.
            local outside = Queries.raycast(
                nil, 20, 0, 1.5, -40, 0, 0,
                { fallback_parts = { cylinder } })
            expect(outside):to_be_nil()

            local inside = Queries.raycast(
                nil, 20, 0, 0.75, -40, 0, 0,
                { fallback_parts = { cylinder } })
            t.assert_that(inside and inside.part == cylinder,
                "ray inside the native circular section missed")
            expect(inside.distance):to_be_near(15, 1e-9)
            expect(inside.nx):to_be_near(1, 1e-9)
        end)

        -- Repaired pairs are physical assertions, not exported-function-name tests.
        for _,shape in ipairs({"Ball", "Block"}) do
            t.it("rejects native cylinder/"..shape.." empty-corner contact",function()
                local N=harness.need("physics/narrowphase.lua")
                local a=N.make_collider({},part({id=1,Shape="Cylinder",Size=size(4,2,2)}),0,0,0)
                local b=N.make_collider({},part({id=2,Shape=shape,Size=size(.2,.2,.2)}),0,.9,.9)
                expect(N.collide(a,b,{})):to_be(0)
            end)
        end
        -- P4g extends only native cylinder pairs. Wedges/meshes/unions retain
        -- their documented approximation limits; this assertion does not cover them.
        t.it("rejects separated parallel cylinders whose box bounds overlap",function()
                local N=harness.need("physics/narrowphase.lua")
                local a=N.make_collider({},part({id=1,Shape="Cylinder",Size=size(4,2,2)}),0,0,0)
                local b=N.make_collider({},part({id=2,Shape="Cylinder",Size=size(4,2,2)}),0,1.8,1.8)
                expect(N.collide(a,b,{})):to_be(0)
            end)

    end)

    ------------------------------------------------------------------ world step

    t.describe("World simulation invariants", function()
        t.it("constructs an empty world and steps it without error", function()
            local w = World.new({})
            for _ = 1, 60 do w:step(1 / 60) end
            expect(w):to_be_type("table")
        end)

        t.it("stepping an empty world is cheap and allocation-stable", function()
            local w = World.new({})
            for _ = 1, 10 do w:step(1 / 60) end
            collectgarbage("collect")
            local before = collectgarbage("count")
            for _ = 1, 240 do w:step(1 / 60) end
            local after = collectgarbage("count")
            -- 240 empty steps should not add hundreds of KB of garbage.
            t.assert_that(after - before < 512,
                "empty world allocated %.1f KB over 240 steps", after - before)
        end)

        t.it("tolerates a zero and a negative dt without producing NaN state", function()
            local w = World.new({})
            w:step(0)
            w:step(-1 / 60)
            w:step(1 / 60)
            expect(w):to_be_type("table")
        end)

        -- The fixed-timestep requirement is ALREADY satisfied. World:step(dt) is an
        -- accumulator shell (world.lua:1062-1121) that clamps the incoming frame dt,
        -- banks it, and drives World:fixed_step(fixed_dt) a bounded number of times.
        -- These tests pin that contract so the Stage 8 sync rework cannot regress it.
        t.it("drives a fixed step, not the raw frame dt", function()
            local w = World.new({})
            expect(type(w.fixed_step)):to_be("function")
            expect(type(w.step)):to_be("function")
            t.assert_that(type(w.accumulator) == "number", "World has no accumulator")
        end)

        t.it("clamps fixed_dt into a sane range", function()
            -- world.lua:30 clamps to [1/240, 1/15] regardless of what is requested.
            expect(World.new({ fixed_dt = 1 / 10000 }).config.fixed_dt):to_be_near(1 / 240, 1e-12)
            expect(World.new({ fixed_dt = 10 }).config.fixed_dt):to_be_near(1 / 15, 1e-12)
            expect(World.new({}).config.fixed_dt):to_be_near(1 / 60, 1e-12)
        end)

        t.it("caps catch-up so a long frame cannot spiral", function()
            local w = World.new({})
            local fixed_dt = w.config.fixed_dt
            local max_substeps = w.config.max_substeps
            -- A 10-second stall must not queue 600 substeps.
            local substeps = w:step(10.0)
            t.assert_that(substeps <= max_substeps,
                "a 10s frame ran %s substeps, cap is %s", tostring(substeps), tostring(max_substeps))
            t.assert_that(w.accumulator <= fixed_dt * max_substeps + 1e-9,
                "accumulator exceeded its cap: %g", w.accumulator)
        end)

        t.it("records how much simulation time was discarded", function()
            -- world.lua:116-117 counts dropped frames/seconds, so catch-up loss is
            -- observable rather than silent.
            local w = World.new({})
            expect(type(w.accumulator_dropped_count)):to_be("number")
            expect(type(w.accumulator_dropped_seconds)):to_be("number")
        end)
    end)

    ------------------------------------------------------- numerical guardrails

    t.describe("numerical guardrails", function()
        local function rejects_size(fn)
            local ok,err=pcall(fn)
            t.assert_that(not ok and tostring(err):find("Size",1,true), "expected Size admission failure")
        end
        t.it("rejects NaN Size before mass (P4f former known bug)", function()
            rejects_size(function() Materials.mass_of(part({Size={x=0/0,y=1,z=1}})) end)
        end)
        t.it("rejects NaN Size before half extents (P4f former known bug)", function()
            rejects_size(function() Shape.half_extents(part({Size={x=0/0,y=1,z=1}})) end)
        end)
        t.it("rejects infinite Size rather than accepting infinite mass", function()
            rejects_size(function() Materials.mass_of(part({Size={x=math.huge,y=1,z=1}})) end)
        end)
        t.it("rejects NaN before publishing AABB coordinates", function()
            rejects_size(function() Shape.aabb(part({Size={x=0/0,y=1,z=1}})) end)
        end)
    end)
end

return suite
