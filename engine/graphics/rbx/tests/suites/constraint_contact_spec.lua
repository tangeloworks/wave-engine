local suite = {needs_graphics = true}
local rbx = require("engine/graphics/rbx")
local V, C = rbx.Vector3, rbx.CFrame
local function with_world(fn)
    local g = assert(rbx.new({simulate_physics=true, physics_budget_ms=0,
        allow_remote_assets=false, async_loading=false, follow_display_settings=false}))
    local ok, err = xpcall(function() fn(g) end, debug.traceback)
    g:Destroy(); assert(ok, err)
end
local function part(g, fields)
    fields.Parent = g.Workspace
    if fields.Anchored == nil then fields.Anchored = false end
    return g.Instance.new("Part", fields)
end
local function body(g, p)
    return g._core._physics_world.part_to_assembly[rawget(p,"_core_handle_id")].body
end
local function advance(g, n) for _=1,n do g:update(1/60) end end

function suite.run(t, harness)
    local Solver = harness.need("physics/solver.lua")
    local Body = harness.need("physics/body.lua")
    local function contact()
        local a = Body.new({is_static=true})
        local b = Body.new({mass=1,inertia_x=1,inertia_y=1,inertia_z=1})
        local m = {body_a=a,body_b=b,last_step=1,normal_x=0,normal_y=1,normal_z=0,
            friction=.5,points={{px=0,py=0,pz=0,penetration=0,normal_impulse=1}}}
        local s = Solver.new(); s:_prepare({manifolds={m}},1,1/60,0)
        return s,b,m
    end
    t.describe("constraint/contact response and sleep", function()
        t.it("limits diagonal friction to the material's Coulomb cone", function()
            local s,b = contact(); b.vx,b.vz=10,10
            s:_solve_friction_velocity()
            local impulse=math.sqrt((b.vx-10)^2+(b.vz-10)^2)
            t.expect(impulse):to_be_near(.5,1e-8)
        end)
        t.it("releases warm friction when a rope unloads the contact", function()
            local s,b = contact(); local f=s._f[1]
            f.jt1=.4; s:_warm_start(); s._c[1].pn=0
            s:_solve_friction_velocity()
            t.expect(b.vx*b.vx+b.vz*b.vz):to_be_near(0,1e-12)
        end)
        t.it("does not add a rolling brake to a finite contact patch", function()
            local s,b,m=contact()
            m.points={{px=-1,py=0,pz=0,normal_impulse=.5},
                {px=1,py=0,pz=0,normal_impulse=.5}}
            s:_prepare({manifolds={m}},1,1/60,0);b.wx=1
            s:_solve_friction_velocity()
            t.expect(b.wx):to_be_near(1,1e-8)
        end)
        t.it("keeps a rotating body awake even when its centre stays still", function()
            with_world(function(g)
                g.Workspace.Gravity=0
                local p=part(g,{Size=V.new(2,2,2),CFrame=C.new(0,10,0),RotVelocity=V.new(0,2,0)})
                local anchor=part(g,{Anchored=true,CanCollide=false,CFrame=p.CFrame})
                g.Instance.new("RopeConstraint",{Parent=p,Length=0,
                    Attachment0=g.Instance.new("Attachment",{Parent=anchor}),
                    Attachment1=g.Instance.new("Attachment",{Parent=p})})
                advance(g,180)
                t.assert_that(not body(g,p).sleeping,"a freely rotating body was deep-slept")
                t.expect(p.RotVelocity.Y):to_be_near(2,1e-8)
            end)
        end)
        t.it("gives an impulsed body a fresh idle window after deep sleep", function()
            with_world(function(g)
                g.Workspace.Gravity=0
                local p=part(g,{Size=V.new(2,2,2),CFrame=C.new(0,10,0)})
                g:update(0);local w=g._core._physics_world;local b=body(g,p)
                b.deep_timer=2;b.deep_ref_x,b.deep_ref_y,b.deep_ref_z=b.com_x,b.com_y,b.com_z
                b.deep_slept=true;w:sleep_body(b)
                p:ApplyImpulse(V.new(.3*p:GetMass(),0,0));g:update(1/60)
                t.assert_that(not b.sleeping,"stale deep-sleep history swallowed an impulse")
                t.expect(p.Velocity.X):to_be_near(.3,1e-8)
            end)
        end)
        t.it("wakes a slack rope endpoint before this step reaches the limit", function()
            with_world(function(g)
                g.Workspace.Gravity=0
                local a=part(g,{Size=V.new(1,1,1),CFrame=C.new(0,10,0),CanCollide=false})
                local b=part(g,{Size=V.new(1,1,1),CFrame=C.new(1.99,10,0),CanCollide=false})
                local aa=g.Instance.new("Attachment",{Parent=a})
                local ab=g.Instance.new("Attachment",{Parent=b})
                g.Instance.new("RopeConstraint",{Parent=a,Attachment0=aa,Attachment1=ab,Length=2})
                g:update(0);local w=g._core._physics_world;w:sleep_body(body(g,a))
                b.Velocity=V.new(6,0,0);g:update(1/60)
                t.assert_that(not body(g,a).sleeping,"rope used a sleeping endpoint as an infinite mass")
                t.expect(a.Velocity.X+b.Velocity.X):to_be_near(6,1e-7)
                t.assert_that(a.Velocity.X>2,"rope failed to transfer momentum")
            end)
        end)
        t.it("transfers the first contact impulse into a sleeping prop", function()
            with_world(function(g)
                g.Workspace.Gravity=0
                local a=part(g,{Size=V.new(2,2,2),CFrame=C.new(0,10,0)})
                local b=part(g,{Size=V.new(2,2,2),CFrame=C.new(1.999,10,0)})
                g:update(0);g._core._physics_world:sleep_body(body(g,a))
                b.Velocity=V.new(-4,0,0);g:update(1/60)
                t.assert_that(a.Velocity.X < -1,"the first impact bounced off an immovable sleeper")
                t.expect(a.Velocity.X+b.Velocity.X):to_be_near(-4,1e-7)
            end)
        end)
        t.it("does not wake a resting support from the gravity integration increment", function()
            with_world(function(g)
                local a=part(g,{Size=V.new(2,2,2),CFrame=C.new(0,1,0)})
                part(g,{Size=V.new(2,2,2),CFrame=C.new(0,3,0)})
                g:update(0);local w=g._core._physics_world;w:sleep_body(body(g,a))
                g:update(1/60)
                t.assert_that(body(g,a).sleeping,"gravity churned a resting contact awake")
            end)
        end)
    end)
end
return suite
