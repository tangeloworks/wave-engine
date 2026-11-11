local suite={}
function suite.run(t,h)
    local A=h.need('physics/assembly.lua')
    local W=h.need('physics/world.lua')
    local function part(shape,size,density,id)
        return {id=id or 1,Shape=shape,Size=size,Position={x=0,y=5,z=0},Anchored=false,CanCollide=true,
            CustomPhysicalProperties={density=density,friction=0,elasticity=0}}
    end
    local function close(a,b) t.expect(a):to_be_near(b,1e-9) end
    t.describe('standalone primitive inertia',function()
        t.it('uses solid local-X cylinder and sphere moments, not their bounding boxes',function()
            local c=A.build({part('Cylinder',{x=4,y=2,z=2},2)}).bodies[1]
            -- Integral of rho*(y*y+z*z) over a radius-one, length-four solid.
            close(c.mass,8*math.pi);close(c.inertia_x,4*math.pi)
            close(c.inertia_y,38*math.pi/3);close(c.inertia_z,38*math.pi/3)
            c:apply_angular_impulse(4*math.pi,0,0);close(c.wx,1)
            local s=A.build({part('Ball',{x=2,y=2,z=2},3)}).bodies[1]
            close(s.mass,4*math.pi)
            for _,k in ipairs({'inertia_x','inertia_y','inertia_z'}) do close(s[k],8*math.pi/5) end
            s:apply_angular_impulse(0,8*math.pi/5,0);close(s.wy,1)
        end)
        t.it('uses the accepted circular extents and preserves box and multi-part approximations',function()
            local c=part('Cylinder',{x=4,y=2,z=6},2)
            close(A.build({c}).bodies[1].inertia_x,4*math.pi)
            local s=part('Ball',{x=4,y=2,z=6},3)
            close(A.build({s}).bodies[1].inertia_x,8*math.pi/5)
            local box=part('Block',{x=2,y=3,z=4},2)
            local b=A.build({box}).bodies[1];close(b.inertia_x,100);close(b.inertia_y,80);close(b.inertia_z,52)
            local child=part('Cylinder',{x=4,y=2,z=2},2,2)
            c.RootPriority=10
            local group=A.build({c,child},{edges={{a=1,b=2}}}).assemblies[1]
            close(group.body.inertia_x,group.mass*(2*2+6*6)/12)
            A.recompute_mass(group);close(group.body.inertia_x,group.mass*40/12)
        end)
        t.it('rotates the cylinder tensor and applies off-centre impulses independently',function()
            local b=A.build({part('Cylinder',{x=4,y=2,z=2},2)}).bodies[1]
            b.qw,b.qx,b.qy,b.qz=math.sqrt(.5),0,0,math.sqrt(.5)
            b:apply_angular_impulse(0,4*math.pi,0)
            close(b.wx,0);close(b.wy,1);close(b.wz,0)
            b.wx,b.wy,b.wz=0,0,0
            -- r=(1,0,0), J=(0,38*pi/3,0), so angular impulse is +Z.
            b:apply_impulse_at(0,38*math.pi/3,0,b.com_x+1,b.com_y,b.com_z)
            close(b.wz,1);close(b.vy,19/12)
        end)
        t.it('preserves fixed-step outcomes and all time at 30/60/144/1000Hz',function()
            local ref
            for _,hz in ipairs({30,60,144,1000}) do
                local w=W.new({enabled=true,collision_enabled=true,gravity=10,budget_ms=0})
                w:set_assemblies(A.build({part('Cylinder',{x=4,y=2,z=2},2)}))
                local b=w.bodies[1];b:apply_angular_impulse(4*math.pi,0,0)
                for i=1,hz do w:step(1/hz) end
                close(b.wx,1);close(b.vy,-10);close(w.time_accounting.simulated_seconds,1)
                assert(w.step_count==60 and w.accumulator_dropped_seconds==0)
                local s={b.qw,b.qx,b.qy,b.qz,b.com_y,w.accumulator}
                if ref then for i,v in ipairs(s) do close(v,ref[i]) end else ref=s end
            end
        end)
        t.it('bounds and retires final-sleep publications through removal, replacement and reset',function()
            local function make()
                local w=W.new({enabled=true,collision_enabled=false,gravity=0,budget_ms=0,sleep_time=.05})
                w:set_assemblies(A.build({part('Cylinder',{x=4,y=2,z=2},2)}))
                local b=w.bodies[1];b:apply_angular_impulse(.02*4*math.pi,0,0)
                for i=1,10 do w:step(1/60);if b.sleeping then break end end
                assert(b.sleeping and #w.sleep_pose_publications==1 and w.sleep_pose_publications[1]==b)
                w:queue_sleep_pose_publication(b);assert(#w.sleep_pose_publications==1)
                return w,b
            end
            local w,b=make();assert(w:remove_singleton_assembly(1));assert(#w.sleep_pose_publications==0 and not b._sleep_pose_index)
            w,b=make();w:set_assemblies(A.build({part('Ball',{x=2,y=2,z=2},3,2)}))
            assert(#w.sleep_pose_publications==0 and not b._sleep_pose_index)
            w,b=make();w:reset();assert(#w.sleep_pose_publications==0 and not b._sleep_pose_index)
            w,b=make();w:step(0);assert(#w.sleep_pose_publications==0 and not b._sleep_pose_index)
        end)
    end)
end
return suite
