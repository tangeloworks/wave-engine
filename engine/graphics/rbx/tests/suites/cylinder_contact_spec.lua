local suite={}
function suite.run(t,h)
    local N=h.need('physics/narrowphase.lua')
    local World=h.need('physics/world.lua');local Assembly=h.need('physics/assembly.lua')
    local I=h.need('physics/integrate.lua')
    local function collider(kind,size,pos,q,id)
        q=q or {1,0,0,0}
        return N.make_collider({},{id=id or 1,ClassName='Part',Shape=kind,Size={x=size[1],y=size[2],z=size[3]}},pos[1],pos[2],pos[3],unpack(q))
    end
    local function pair(kind,pos,size)
        return collider('Cylinder',{4,2,2},{0,0,0}),collider(kind,size or {.2,.2,.2},pos,nil,2)
    end
    t.describe('finite cylinder analytic contact geometry',function()
        local cases={
            {'side','Ball',{0,1.05,0},.05,{0,1,0}},
            {'cap','Ball',{2.05,0,0},.05,{1,0,0}},
            {'rim','Ball',{2.05,1.05,0},.1-math.sqrt(.005),{math.sqrt(.5),math.sqrt(.5),0}},
            {'side','Block',{0,1.05,0},.05,{0,1,0}},
            {'cap','Block',{2.05,0,0},.05,{1,0,0}},
            {'rim','Block',{2.05,.75,.75},nil,nil},
        }
        for _,case in ipairs(cases) do t.it(case[2]..' '..case[1]..' witnesses and reversed normal',function()
            local a,b=pair(case[2],case[3]);local o,p={},{}
            local n=N.collide(a,b,o);t.assert_that(n>0,'positive '..case[1]..' contact lost')
            t.expect(N.collide(b,a,p)):to_be(n)
            t.expect(o.nx*o.nx+o.ny*o.ny+o.nz*o.nz):to_be_near(1,1e-7)
            t.expect(p.nx):to_be_near(-o.nx,1e-7);t.expect(p.ny):to_be_near(-o.ny,1e-7);t.expect(p.nz):to_be_near(-o.nz,1e-7)
            if case[4] then t.expect(o.points[1].penetration):to_be_near(case[4],2e-6) end
            if case[5] then for i,k in ipairs({'nx','ny','nz'}) do t.expect(o[k]):to_be_near(case[5][i],.001) end end
            for i=1,n do for _,k in ipairs({'px','py','pz','penetration'}) do t.expect(o.points[i][k]):to_be_finite();t.expect(p.points[i][k]):to_be_near(o.points[i][k],1e-7) end end
        end) end
        for _,kind in ipairs({'Ball','Block'}) do
            t.it(kind..' separation, near tangent, overlap, arbitrary global pose',function()
                for _,item in ipairs({{{0,.9,.9},false},{{0,1.10001,0},false},{{0,1.09999,0},true},{{0,.8,0},true}}) do
                    local a,b=pair(kind,item[1]);t.expect(N.collide(a,b,{})>0):to_be(item[2])
                    local q={math.cos(.57),math.sin(.57)/math.sqrt(3),math.sin(.57)/math.sqrt(3),math.sin(.57)/math.sqrt(3)}
                    local x,y,z=I.rotate_vec(q[1],q[2],q[3],q[4],item[1][1],item[1][2],item[1][3])
                    a=collider('Cylinder',{4,2,2},{13,-7,5},q)
                    b=collider(kind,{.2,.2,.2},{13+x,-7+y,5+z},q,2)
                    t.expect(N.collide(a,b,{})>0):to_be(item[2])
                end
            end)
        end
        t.it('emits four cap support points and three exact side support points',function()
            local a,b=pair('Block',{2.4,0,0},{1,6,6});local o={};t.expect(N.collide(a,b,o)):to_be(4)
            a,b=pair('Block',{0,1.4,0},{6,1,6});t.expect(N.collide(a,b,o)):to_be(3)
        end)
        t.it('handles coincident centres and independently rotated box bounds',function()
            for _,kind in ipairs({'Ball','Block'}) do
                local a,b=pair(kind,{0,0,0});local o={};t.assert_that(N.collide(a,b,o)>0)
                t.expect(o.nx):to_be_finite();t.expect(o.points[1].penetration):to_be_finite()
            end
            for i=1,24 do
                local angle=i*.137;local q={math.cos(angle),math.sin(angle)/math.sqrt(3),math.sin(angle)/math.sqrt(3),math.sin(angle)/math.sqrt(3)}
                local a=collider('Cylinder',{4,2,2},{0,0,0})
                -- Every such box fits inside a radius sqrt(3)*.1 sphere; the
                -- corner centre is farther from the cylinder than that bound.
                local b=collider('Block',{.2,.2,.2},{0,.9,.9},q,2);t.expect(N.collide(a,b,{})):to_be(0)
                -- Conversely every rotated box contains its radius-.1 sphere.
                b=collider('Block',{.2,.2,.2},{2.02,1.02,0},q,2);t.assert_that(N.collide(a,b,{})>0)
            end
        end)
        t.it('reports bounded-query failure and invalid data explicitly',function()
            local C=h.need('physics/cylinder.lua');local a,b=pair('Block',{0,1.05,0})
            t.expect(function() C.box(a,b,{}, {gjk=0}) end):to_error()
            t.expect(function() C.box(a,b,{}, {epa=0}) end):to_error()
            a.hx=0/0;t.expect(function() N.collide(a,b,{}) end):to_error()
        end)
        t.it('preserves X-length versus circular Y/Z-radius descriptor ownership',function()
            local a=collider('Cylinder',{.2,2,6},{0,0,0})
            t.expect(a.hx):to_be(.1);t.expect(a.radius):to_be(1)
            local b=collider('Ball',{.2,.2,.2},{0,1.05,0},nil,2)
            t.assert_that(N.collide(a,b,{})>0)
            b=collider('Ball',{.2,.2,.2},{0,0,1.2},nil,2);t.expect(N.collide(a,b,{})):to_be(0)
        end)
        t.it('keeps established non-cylinder pair outputs',function()
            local a=collider('Ball',{2,2,2},{0,0,0});local b=collider('Ball',{2,2,2},{1.8,0,0},nil,2);local o={}
            t.expect(N.collide(a,b,o)):to_be(1);t.expect(o.nx):to_be(1);t.expect(o.points[1].penetration):to_be_near(.2,1e-9)
            b=collider('Block',{2,2,2},{1.8,0,0},nil,2);t.expect(N.collide(a,b,o)):to_be(1);t.expect(o.points[1].px):to_be_near(.8,1e-9)
            a=collider('Block',{2,2,2},{0,0,0});t.expect(N.collide(a,b,o)):to_be(4);t.expect(o.nx):to_be(1);t.expect(o.points[1].penetration):to_be_near(.2,1e-9)
        end)
    end)
    local function view(id,kind,size,pos,anchored,q,elasticity)
        q=q or {1,0,0,0};local m={I.quat_to_matrix(unpack(q))}
        local cf={};for i,k in ipairs({'r00','r01','r02','r10','r11','r12','r20','r21','r22'}) do cf[k]=m[i] end
        return {id=id,ClassName='Part',Shape=kind,Size={x=size[1],y=size[2],z=size[3]},Position={x=pos[1],y=pos[2],z=pos[3]},
            CFrameRef=cf,Anchored=anchored,CanCollide=true,CustomPhysicalProperties={density=1,friction=0,elasticity=elasticity or 0,friction_weight=1,elasticity_weight=1},_test_q=q}
    end
    local function world(parts,gravity)
        local w=World.new({enabled=true,collision_enabled=true,gravity=gravity or 0,budget_ms=0})
        w:set_assemblies(Assembly.build(parts))
        for _,p in ipairs(parts) do
            local b=w.part_to_assembly[p.id].body;local q=p._test_q or {1,0,0,0}
            b.qw,b.qx,b.qy,b.qz=unpack(q);b:update_world_inertia()
            b.local_offsets={{view=p,lx=0,ly=0,lz=0,qw=1,qx=0,qy=0,qz=0}}
        end
        return w
    end
    t.describe('production fixed-step cylinder response',function()
        for _,kind in ipairs({'Ball','Block'}) do for _,mode in ipairs({'cylinder_static','other_static','both_dynamic'}) do for _,e in ipairs({0,1}) do for _,reversed in ipairs({false,true}) do
            t.it(kind..' '..mode..' restitution '..e..' reverse='..tostring(reversed),function()
                local aid,bid=reversed and 2 or 1,reversed and 1 or 2
                local a=view(aid,'Cylinder',{4,2,2},{0,0,0},mode=='cylinder_static',nil,e)
                local b=view(bid,kind,{.4,.4,.4},{0,1.195,0},mode=='other_static',nil,e)
                local w=world({a,b});local ba,bb=w.part_to_assembly[aid].body,w.part_to_assembly[bid].body
                if ba.is_static then bb.vy=-2 elseif bb.is_static then ba.vy=2 else ba.vy=1;bb.vy=-1 end
                local momentum=ba.mass*ba.vy+bb.mass*bb.vy;local energy=.5*(ba.mass*ba.vy^2+bb.mass*bb.vy^2)
                w:step(1/60);t.assert_that(w.manifold_cache.contact_count>0,'real contact not solved')
                t.expect(bb.vy-ba.vy):to_be_near(2*e,kind=='Ball' and 1e-7 or .005)
                if mode=='both_dynamic' then
                    t.expect(ba.mass*ba.vy+bb.mass*bb.vy):to_be_near(momentum,1e-7)
                    local after=.5*(ba.mass*(ba.vx^2+ba.vy^2+ba.vz^2)+bb.mass*(bb.vx^2+bb.vy^2+bb.vz^2))
                    t.assert_that(after<=energy+1e-6,'contact injected linear energy')
                end
                print(string.format('[p4d-impact] %s %s e=%g contacts=%d vyA=%.12g vyB=%.12g',kind,mode,e,w.manifold_cache.contact_count,ba.vy,bb.vy))
            end)
        end end end end
        for _,mode in ipairs({'cap','side'}) do
            t.it('keeps a '..mode..'-resting cylinder stably supported',function()
                local q=mode=='cap' and {math.sqrt(.5),0,0,math.sqrt(.5)} or {1,0,0,0}
                local y=mode=='cap' and 2 or 1
                local floor=view(1,'Block',{20,1,20},{0,-.5,0},true)
                local cyl=view(2,'Cylinder',{4,2,2},{0,y,0},false,q)
                local w=world({floor,cyl},10);local b=w.part_to_assembly[2].body;local maxpen,maxdrift,contactsteps,minpoints=0,0,0,4
                for step=1,300 do
                    w:step(1/60)
                    local fresh=0
                    for _,m in ipairs(w.manifold_cache.list) do if m.last_step==w.step_index then fresh=fresh+#m.points end end
                    if fresh>0 then contactsteps=contactsteps+1;minpoints=math.min(minpoints,fresh) end
                    maxdrift=math.max(maxdrift,math.sqrt(b.com_x^2+b.com_z^2))
                    for _,m in ipairs(w.manifold_cache.list) do if m.last_step==w.step_index then for _,p in ipairs(m.points) do maxpen=math.max(maxpen,p.penetration) end end end
                    t.assert_that(b.com_y>y-.04 and b.com_y<y+.04,'support height drift: %.12g',b.com_y)
                end
                t.assert_that(contactsteps>20,'insufficient actual contact steps')
                t.assert_that(maxpen<.04 and maxdrift<.02,'support instability pen=%.12g drift=%.12g',maxpen,maxdrift)
                t.expect(w.accumulator_dropped_seconds):to_be(0)
                print(string.format('[p4d-rest] %s pen=%.12g drift=%.12g contactsteps=%d minpoints=%d y=%.12g sleep=%s',mode,maxpen,maxdrift,contactsteps,minpoints,b.com_y,tostring(b.sleeping)))
            end)
        end
        for _,kind in ipairs({'Ball','Block'}) do
            t.it(kind..' contact trajectory matches 30/60/144/1000Hz schedules',function()
                local expected
                for _,hz in ipairs({30,60,144,1000}) do
                    local w=world({view(1,'Cylinder',{20,2,2},{0,0,0},true),view(2,kind,{.4,.4,.4},{0,1.2,0},false)},10)
                    local b=w.part_to_assembly[2].body;b.vx=1
                    for _=1,hz*2 do w:step(1/hz) end
                    t.expect(w.time_accounting.simulated_seconds):to_be_near(2,1e-10);t.expect(w.accumulator_dropped_seconds):to_be(0)
                    local state={b.com_x,b.com_y,b.com_z,b.vx,b.vy,b.vz,b.qw,b.qx,b.qy,b.qz}
                    if expected then for i,x in ipairs(state) do t.expect(x):to_be_near(expected[i],1e-8) end else expected=state end
                    print(string.format('[p4d-schedule] %s hz=%d steps=%d sim=%.12g contact=%d y=%.12g',kind,hz,w.step_count,w.time_accounting.simulated_seconds,w.manifold_cache.contact_count,b.com_y))
                end
            end)
        end
        t.it('maintains six moving bodies in a bounded ten-body contact workload',function()
            local parts={view(1,'Block',{30,1,22},{3,-.5,3},true)}
            local moving={}
            for i=1,3 do
                local cid,bid,sid=i*3-1,i*3,i*3+1
                parts[#parts+1]=view(cid,'Cylinder',{4,2,2},{-4,1,(i-1)*4},false)
                parts[#parts+1]=view(bid,'Ball',{.4,.4,.4},{-4,4.2,-4-i*3},false)
                parts[#parts+1]=view(sid,'Cylinder',{20,2,2},{0,3,-4-i*3},true)
                moving[#moving+1]=cid;moving[#moving+1]=bid
            end
            local w=world(parts,10);w._profile_totals={}
            for _,id in ipairs(moving) do w.part_to_assembly[id].body.vx=1 end
            local trace={};local maximum_penetration,total_points,contact_steps=0,0,0
            local start=love.timer.getTime()
            for step=1,300 do
                w:step(1/60)
                local fresh=0;local contacts={}
                for _,m in ipairs(w.manifold_cache.list) do if m.last_step==w.step_index then
                    fresh=fresh+#m.points
                    for _,p in ipairs(m.points) do maximum_penetration=math.max(maximum_penetration,p.penetration) end
                    if step==1 or step==60 or step==180 or step==300 then
                        local points={}
                        for _,p in ipairs(m.points) do points[#points+1]={position={p.px,p.py,p.pz},penetration=p.penetration,normal_impulse=p.normal_impulse} end
                        contacts[#contacts+1]={a=m.part_a_id,b=m.part_b_id,normal={m.normal_x,m.normal_y,m.normal_z},points=points}
                    end
                end end
                if fresh>0 then contact_steps=contact_steps+1 end
                total_points=total_points+fresh
                if step==1 or step==60 or step==180 or step==300 then
                    local bodies={}
                    for _,id in ipairs(moving) do local b=w.part_to_assembly[id].body
                        bodies[#bodies+1]={id=id,position={b.com_x,b.com_y,b.com_z},velocity={b.vx,b.vy,b.vz},sleeping=b.sleeping}
                    end
                    trace[#trace+1]={step=step,contacts=contacts,bodies=bodies}
                end
            end
            local wall=love.timer.getTime()-start
            local record={scope='CPU production World/Assembly/solver control; no DataModel/renderer, no FPS claim',
                root_application_clamp='NOT EXERCISED; finite synthetic fixed inputs',bodies=10,dynamic_bodies=6,
                shapes={Block=1,Cylinder=6,Ball=3},contact_steps=contact_steps,total_contact_points=total_points,
                maximum_penetration=maximum_penetration,world=w.time_accounting,ending_remainder=w.accumulator,
                cpu_totals=w._profile_totals,wall_seconds=wall,trace=trace,heap_kib=collectgarbage('count')}
            love.filesystem.write('p4d-contact-control.json',require('engine/graphics/rbx/tests/profile_record').encode(record))
            print(string.format('[p4d-control] steps=%d active=%d contacts=%d points=%d maxpen=%.12g wall=%.6g record=%s',
                w.step_count,w.time_accounting.executed_steps,contact_steps,total_points,maximum_penetration,wall,love.filesystem.getSaveDirectory()..'/p4d-contact-control.json'))
            t.expect(w.time_accounting.executed_steps):to_be(300);t.expect(w.time_accounting.idle_steps):to_be(0)
            t.assert_that(contact_steps>=280,'contact workload was not sustained')
            t.assert_that(maximum_penetration<.04,'excessive contact penetration %.12g',maximum_penetration)
            t.expect(w.time_accounting.simulated_seconds):to_be_near(5,1e-10)
            t.expect(w.accumulator_dropped_seconds):to_be(0);t.expect(w.accumulator):to_be_near(0,1e-10)
            for _,id in ipairs(moving) do
                local b=w.part_to_assembly[id].body
                t.expect(b.com_x):to_be_near(1,.02);t.expect(b.sleeping):to_be(false)
            end
        end)
        t.it('off-centre rim impulse rotates the dynamic cylinder',function()
            local w=world({view(1,'Cylinder',{4,2,2},{0,0,0},false),view(2,'Ball',{.2,.2,.2},{2.05,1.05,0},true)})
            local b=w.part_to_assembly[1].body;b.vx=2;w:step(1/60)
            t.assert_that(w.manifold_cache.contact_count>0 and b.wz<-.001,'expected negative angular rim response, got %.12g',b.wz)
        end)
        t.it('retains the existing collision-group filter before contact generation',function()
            local a=view(1,'Cylinder',{4,2,2},{0,0,0},true);a.CollisionGroup='CylinderGroup'
            local b=view(2,'Ball',{.2,.2,.2},{0,1.05,0},false);b.CollisionGroup='ProbeGroup'
            local w=world({a,b});w.collision_groups:register('CylinderGroup');w.collision_groups:register('ProbeGroup')
            w.collision_groups:set_collidable('CylinderGroup','ProbeGroup',false);w:step(1/60)
            t.expect(w.manifold_cache.contact_count):to_be(0)
            w.collision_groups:set_collidable('CylinderGroup','ProbeGroup',true);w:step(1/60)
            t.assert_that(w.manifold_cache.contact_count>0)
        end)
    end)
    t.describe('native cylinder empty corner',function()
        t.it('rejects the sphere in the enclosing box corner',function()
            local a=N.make_collider({},{id=1,Shape='Cylinder',Size={x=4,y=2,z=2}},0,0,0)
            local b=N.make_collider({},{id=2,Shape='Ball',Size={x=.2,y=.2,z=.2}},0,.9,.9)
            local out={};local n=N.collide(a,b,out)
            print('[p4d-corner] kind='..a.kind..' hx='..a.hx..' hy='..a.hy..' hz='..a.hz..' contacts='..n..' penetration='..tostring(out.points and out.points[1] and out.points[1].penetration))
            t.expect(n):to_be(0)
        end)
        t.it('leaves the empty-corner body unmoved in the production world',function()
            local w=World.new({enabled=true,collision_enabled=true,gravity=0,budget_ms=0})
            w:set_assemblies(Assembly.build({{id=1,ClassName='Part',Shape='Cylinder',Size={x=4,y=2,z=2},Position={x=0,y=0,z=0},Anchored=true,CanCollide=true},
                {id=2,ClassName='Part',Shape='Ball',Size={x=.2,y=.2,z=.2},Position={x=0,y=.9,z=.9},Anchored=false,CanCollide=true}}))
            w:step(1/60);local b=w.part_to_assembly[2].body
            print(string.format('[p4d-response] contacts=%d y=%.12g z=%.12g vy=%.12g vz=%.12g',w.manifold_cache.contact_count,b.com_y,b.com_z,b.vy,b.vz))
            t.expect(w.manifold_cache.contact_count):to_be(0);t.expect(b.com_y):to_be_near(.9,1e-10);t.expect(b.com_z):to_be_near(.9,1e-10)
        end)
    end)
end
return suite
