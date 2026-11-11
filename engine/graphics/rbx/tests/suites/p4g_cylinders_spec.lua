local suite={}
function suite.run(t,h)
    local N=h.need('physics/narrowphase.lua')
    local World=h.need('physics/world.lua');local Assembly=h.need('physics/assembly.lua')
    local I=h.need('physics/integrate.lua')
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
    local function energy(b)
        if b.is_static then return 0 end
        local x,y,z=I.rotate_vec(b.qw,-b.qx,-b.qy,-b.qz,b.wx,b.wy,b.wz)
        return .5*(b.mass*(b.vx*b.vx+b.vy*b.vy+b.vz*b.vz)+b.inertia_x*x*x+b.inertia_y*y*y+b.inertia_z*z*z)
    end

    t.it('P4g parallel empty-corner cylinders have no contact',function()
        local p={id=1,Shape='Cylinder',Size={x=4,y=2,z=2}}
        local a=N.make_collider({},p,0,0,0);p.id=2;local b=N.make_collider({},p,0,1.5,1.5)
        t.expect(N.collide(a,b,{})):to_be(0)
    end)
    local function collider(id,size,pos,angle)
        return N.make_collider({},{id=id,Shape='Cylinder',Size={x=size[1],y=size[2],z=size[3]}},
            pos[1],pos[2],pos[3],math.cos((angle or 0)/2),0,0,math.sin((angle or 0)/2))
    end
    t.describe('P4g finite cylinder pair geometry',function()
        local cases={
            {'parallel side',{0,1.9,0},0,.1,{0,1,0},3},
            {'parallel cap',{3.9,0,0},0,.1,{1,0,0},4},
            {'parallel cap/rim',{3.95,1.9,0},0,.05,{1,0,0}},
            {'perpendicular side',{0,0,1.9},math.pi/2,.1,{0,0,1}},
            {'skew side',{0,0,1.9},.3,.1,{0,0,1}},
            {'nearly parallel side',{0,0,1.9},1e-5,.1,{0,0,1}},
            {'oblique cap/rim',{3.7,.1,0},.25},
            {'coincident parallel',{0,0,0},0},
            {'coincident perpendicular',{0,0,0},math.pi/2},
        }
        for _,case in ipairs(cases) do t.it(case[1]..' positive witnesses and reversed order',function()
            local a=collider(1,{4,2,2},{0,0,0});local b=collider(2,{4,2,2},case[2],case[3]);local o,r={},{}
            local count=N.collide(a,b,o);assert(count>0 and count<=4)
            assert(N.collide(b,a,r)==count)
            if case[6] then assert(count==case[6]) end
            t.expect(o.nx^2+o.ny^2+o.nz^2):to_be_near(1,1e-7)
            for _,k in ipairs({'nx','ny','nz'}) do t.expect(r[k]):to_be_near(-o[k],1e-10) end
            if case[4] then t.expect(o.points[1].penetration):to_be_near(case[4],2e-6) end
            if case[5] then for i,k in ipairs({'nx','ny','nz'}) do t.expect(o[k]):to_be_near(case[5][i],.001) end end
            for i=1,count do for _,k in ipairs({'px','py','pz','penetration'}) do
                t.expect(o.points[i][k]):to_be_finite();t.expect(r.points[i][k]):to_be_near(o.points[i][k],1e-10)
            end end
            print(string.format('[p4g-geometry] %s points=%d depth=%.12g normal=%.8g,%.8g,%.8g query=%d',case[1],count,o.points[1].penetration,o.nx,o.ny,o.nz,o.query_iterations or 0))
        end) end
        t.it('handles near tangency, unequal dimensions, antiparallel and transformed axes',function()
            local a=collider(1,{4,2,2},{0,0,0})
            for _,angle in ipairs({0,1e-5,.3,math.pi/2}) do
                assert(N.collide(a,collider(2,{4,2,2},{0,0,2.00001},angle),{})==0)
                assert(N.collide(a,collider(2,{4,2,2},{0,0,1.99999},angle),{})>0)
            end
            local o={};assert(N.collide(a,collider(2,{2,1,3},{0,1.49,0},math.pi),o)>0)
            t.expect(o.points[1].penetration):to_be_near(.01,2e-6)
            local q={math.cos(.3),math.sin(.3)/math.sqrt(3),math.sin(.3)/math.sqrt(3),math.sin(.3)/math.sqrt(3)}
            local function transformed(id,x,y,z)
                local px,py,pz=I.rotate_vec(q[1],q[2],q[3],q[4],x,y,z)
                return N.make_collider({},{id=id,Shape='Cylinder',Size={x=4,y=2,z=2}},10+px,20+py,30+pz,unpack(q))
            end
            o={};assert(N.collide(transformed(1,0,0,0),transformed(2,0,1.9,0),o)>0)
            t.expect(o.points[1].penetration):to_be_near(.1,2e-6)
        end)
        t.it('keeps query exhaustion explicit and invalid descriptors rejected',function()
            local C=h.need('physics/cylinder.lua');local a=collider(1,{4,2,2},{0,0,0});local b=collider(2,{4,2,2},{0,0,1.9},.3)
            for _,limits in ipairs({{gjk=0},{epa=0}}) do
                local ok,e=pcall(C.cylinder,a,b,{},limits);assert(not ok and tostring(e):find('limit',1,true))
            end
            a.hx=0/0;assert(not pcall(N.collide,a,b,{}))
        end)
    end)
    t.describe('P4g actual cylinder pair solver',function()
        for _,axis in ipairs({'side','cap'}) do for _,mode in ipairs({'a_static','b_static','both_dynamic'}) do for _,e in ipairs({0,1}) do
            t.it(axis..' '..mode..' restitution '..e,function()
                local position=axis=='side' and {0,1.995,0} or {3.995,0,0}
                local a=view(1,'Cylinder',{4,2,2},{0,0,0},mode=='a_static',nil,e)
                local b=view(2,'Cylinder',{4,2,2},position,mode=='b_static',nil,e)
                local w=world({a,b});local ba,bb=w.part_to_assembly[1].body,w.part_to_assembly[2].body
                local key=axis=='side' and 'vy' or 'vx'
                if ba.is_static then bb[key]=-2 elseif bb.is_static then ba[key]=2 else ba[key]=1;bb[key]=-1 end
                local momentum=ba.mass*ba[key]+bb.mass*bb[key];local before_energy=energy(ba)+energy(bb)
                w:step(1/60);assert(w.manifold_cache.contact_count>0)
                t.expect(bb[key]-ba[key]):to_be_near(2*e,.005)
                if mode=='both_dynamic' then
                    t.expect(ba.mass*ba[key]+bb.mass*bb[key]):to_be_near(momentum,1e-7)
                    assert(energy(ba)+energy(bb)<=before_energy+1e-6,'contact injected energy')
                end
            end)
        end end end
        for _,case in ipairs({{'perpendicular',math.pi/2,{0,0,1.995},'vz'},
            {'skew',.3,{0,0,1.995},'vz'}, {'oblique cap/rim',.25,{4.18,.1,0},'vx'}}) do
            for _,mode in ipairs({'a_static','b_static','both_dynamic'}) do
                t.it(case[1]..' actual impulse response '..mode,function()
                    local q={math.cos(case[2]/2),0,0,math.sin(case[2]/2)}
                    local w=world({view(1,'Cylinder',{4,2,2},{0,0,0},mode=='a_static'),
                        view(2,'Cylinder',{4,2,2},case[3],mode=='b_static',q)})
                    local a,b=w.part_to_assembly[1].body,w.part_to_assembly[2].body;local k=case[4]
                    if a.is_static then b[k]=-2 elseif b.is_static then a[k]=2 else a[k]=1;b[k]=-1 end
                    local before=energy(a)+energy(b);local momentum={}
                    for _,axis in ipairs({'vx','vy','vz'}) do momentum[axis]=a.mass*a[axis]+b.mass*b[axis] end
                    w:step(1/60)
                    if w.manifold_cache.contact_count==0 then
                        print('[p4g-impact-missing] '..case[1]..' '..mode..' candidates='..tostring(w.manifold_cache.member_test_count)..' survivors='..tostring(w.manifold_cache.member_survivor_count))
                        for _,body in ipairs({a,b}) do print('[p4g-impact-body]',body.id,body.com_x,body.com_y,body.com_z,body.qw,body.qx,body.qy,body.qz) end
                    end
                    assert(w.manifold_cache.contact_count>0)
                    assert(b[k]-a[k]>-1.95,'no limiting impulse in the independently known separating direction')
                    assert(energy(a)+energy(b)<=before+1e-6,'inelastic impact added kinetic energy')
                    if mode=='both_dynamic' then for axis,value in pairs(momentum) do
                        t.expect(a.mass*a[axis]+b.mass*b[axis]):to_be_near(value,1e-7)
                    end end
                    for _,body in ipairs({a,b}) do for _,key in ipairs({'vx','vy','vz','wx','wy','wz'}) do t.expect(body[key]):to_be_finite() end end
                    print(string.format('[p4g-impact] %s %s relative=%.9g energy_before=%.9g after=%.9g',case[1],mode,b[k]-a[k],before,energy(a)+energy(b)))
                end)
            end
        end
        for _,mode in ipairs({'cap','side'}) do
            t.it('stable '..mode..' support with retained manifold',function()
                local q=mode=='cap' and {math.sqrt(.5),0,0,math.sqrt(.5)} or {1,0,0,0}
                local a=view(1,'Cylinder',{4,4,4},{0,-2,0},true,q)
                local y=mode=='cap' and 2 or 1
                local b=view(2,'Cylinder',{4,2,2},{0,y,0},false,q)
                local w=world({a,b},10);local body=w.part_to_assembly[2].body;local maxpen,drift,contactsteps=0,0,0
                for i=1,300 do
                    w:step(1/60)
                    if w.manifold_cache.contact_count>0 then contactsteps=contactsteps+1 end
                    for _,m in ipairs(w.manifold_cache.list) do if m.last_step==w.step_index then for _,p in ipairs(m.points) do maxpen=math.max(maxpen,p.penetration) end end end
                    drift=math.max(drift,math.sqrt(body.com_x^2+body.com_z^2))
                    assert(math.abs(body.com_y-y)<.04,'support height changed')
                end
                assert(maxpen<.04 and drift<.02 and contactsteps>20)
                print(string.format('[p4g-rest] %s maxpen=%.12g drift=%.12g contactsteps=%d',mode,maxpen,drift,contactsteps))
            end)
        end
        t.it('matches equal-duration 30/60/144/1000Hz contact schedules',function()
            local expected
            for _,hz in ipairs({30,60,144,1000}) do
                local w=world({view(1,'Cylinder',{10,4,4},{0,-2,0},true),view(2,'Cylinder',{4,2,2},{0,1,0},false)},10)
                local b=w.part_to_assembly[2].body;b.vx=.1
                for i=1,hz*2 do w:step(1/hz) end
                t.expect(w.time_accounting.simulated_seconds):to_be_near(2,1e-10);assert(w.accumulator_dropped_seconds==0)
                local s={b.com_x,b.com_y,b.com_z,b.vx,b.vy,b.vz,b.qw,b.qx,b.qy,b.qz}
                if expected then for i,n in ipairs(s) do t.expect(n):to_be_near(expected[i],1e-8) end else expected=s end
            end
        end)
    end)
end
return suite
