local suite={}
function suite.run(t,h)
    local A=h.need('physics/assembly.lua')
    local World=h.need('physics/world.lua')
    local function part(id,massless,x)
        return {id=id,Size={x=2,y=3,z=4},Position={x=x or 0,y=5,z=0},Massless=massless,Anchored=false,
            CanCollide=true,Shape='Block',CustomPhysicalProperties={density=2,friction=0,elasticity=0}}
    end
    t.it('P4g standalone root retains authored Massless while gaining its physical contribution',function()
        local p={id=1,Size={x=2,y=3,z=4},Position={x=0,y=0,z=0},Massless=true,Anchored=false,Shape='Block'}
        local a=A.build({p}).assemblies[1]
        assert(p.Massless and a.root_part==p and a.part_count==1)
        t.expect(a.body.mass):to_be_near(16.8,1e-9)
    end)
    t.it('P4g keeps non-root Massless contributions excluded in existing rigid groups',function()
        local root,leaf=part(1,true,0),part(2,true,10);root.RootPriority=10
        local r=A.build({root,leaf},{edges={{a=1,b=2}}});local a=r.assemblies[1]
        assert(a.root_part==root and a.part_count==2 and root.Massless and leaf.Massless)
        t.expect(a.mass):to_be(48);t.expect(a.com_x):to_be(0)
        leaf.Massless=false;A.recompute_mass(a);t.expect(a.mass):to_be(96);t.expect(a.com_x):to_be(5)
        leaf.Massless=true;A.recompute_mass(a);t.expect(a.mass):to_be(48)
        local separate=A.build({root,leaf});assert(#separate.assemblies==2)
        for _,s in ipairs(separate.assemblies) do t.expect(s.mass):to_be(48) end
    end)
    t.it('P4g mass, inertia and linear/angular impulses match independent box expectations',function()
        for _,massless in ipairs({false,true}) do
            local b=A.build({part(1,massless)}).bodies[1]
            t.expect(b.mass):to_be(48);t.expect(b.inv_mass):to_be_near(1/48,1e-12)
            t.expect(b.inertia_x):to_be(100);t.expect(b.inertia_y):to_be(80);t.expect(b.inertia_z):to_be(52)
            b:apply_impulse(48,0,0);b:apply_angular_impulse(0,0,52)
            t.expect(b.vx):to_be(1);t.expect(b.wz):to_be(1)
        end
    end)
    t.it('P4g free-fall and impulse schedules match controls at 30/60/144/1000Hz',function()
        local reference
        for _,hz in ipairs({30,60,144,1000}) do for _,massless in ipairs({false,true}) do
            local p=part(1,massless);local w=World.new({enabled=true,collision_enabled=true,gravity=10,budget_ms=0})
            w:set_assemblies(A.build({p}));local b=w.bodies[1];b:apply_impulse(48,0,0);b:apply_angular_impulse(0,0,52)
            for i=1,hz do w:step(1/hz) end
            assert(w.step_count==60 and w.accumulator_dropped_seconds==0)
            t.expect(w.time_accounting.simulated_seconds):to_be_near(1,1e-10)
            t.expect(b.com_x):to_be_near(1,1e-10);t.expect(b.vy):to_be_near(-10,1e-10)
            local s={b.com_x,b.com_y,b.com_z,b.vx,b.vy,b.vz,b.qw,b.qx,b.qy,b.qz,b.wx,b.wy,b.wz}
            if reference then for i,x in ipairs(s) do t.expect(x):to_be_near(reference[i],1e-8) end else reference=s end
        end end
    end)
end
return suite
