local suite = {}

function suite.run(t, h)
    local Body = h.need('physics/body.lua')
    local zero_fields = {
        'sleep_timer', 'active_index', 'vx', 'vy', 'vz', 'wx', 'wy', 'wz',
        'force_x', 'force_y', 'force_z', 'torque_x', 'torque_y', 'torque_z',
        'qx', 'qy', 'qz', 'inertia_x', 'inertia_y', 'inertia_z',
        'inv_mass', 'inv_inertia_x', 'inv_inertia_y', 'inv_inertia_z',
        'wii_xx', 'wii_yy', 'wii_zz', 'wii_xy', 'wii_xz', 'wii_yz',
    }
    t.describe('rigid body storage semantics', function()
        t.it('exposes independent positive-zero defaults and owns every mutable collection', function()
            local a = Body.new({is_static=true, mass=9})
            local b = Body.new({is_static=true, mass=9})
            assert(a.sleeping==false and a.rotation_locked==false and a.qw==1)
            assert(a.parts~=b.parts and a.local_offsets~=b.local_offsets)
            for _,key in ipairs(zero_fields) do
                assert(a[key]==0 and 1/a[key]==math.huge, key..' default differs')
                a[key]=17
                assert(b[key]==0, key..' mutation escaped its body')
                a[key]=0
            end
            a:sleep();assert(a.sleeping and not b.sleeping)
            a.local_offsets[1]={};assert(#b.local_offsets==0)
        end)
        t.it('preserves nonzero authored inertia, signed zero and anchoring transitions', function()
            local b=Body.new({is_static=true,mass=2,inertia_x=4,inertia_y=5,inertia_z=-0.0})
            assert(b.mass==2 and b.inertia_x==4 and b.inertia_y==5 and 1/b.inertia_z==-math.huge)
            b:apply_impulse(4,6,8);assert(b.vx==0 and b.vy==0 and b.vz==0)
            b.is_static=false;b:set_mass_properties(2,4,5,8)
            b:apply_impulse(4,6,8)
            assert(b.vx==2 and b.vy==3 and b.vz==4)
            assert(b.inv_mass==.5 and b.wii_xx==.25 and b.wii_yy==.2 and b.wii_zz==.125)
            b:set_rotation_locked(true);assert(b.wii_xx==0 and b.inv_inertia_x==0)
            b:set_rotation_locked(false);assert(b.wii_xx==.25)
            b.is_static=true;b:set_mass_properties(2,0,0,0)
            b:apply_impulse(100,100,100)
            assert(b.vx==2 and b.vy==3 and b.vz==4 and b.inv_mass==0)
            assert(b.wii_xx==0 and b.wii_yy==0 and b.wii_zz==0)
        end)
        t.it('records retained storage for a fixed set of static bodies', function()
            collectgarbage('collect')
            local before=collectgarbage('count');local bodies={}
            for i=1,4096 do
                local b=Body.new({id=i,is_static=true,mass=3,com_x=i})
                -- The real binding path writes orientation and initial velocity.
                b.qw,b.qx,b.qy,b.qz=1,0,0,0;b.vx,b.vy,b.vz=0,0,0;b.wx,b.wy,b.wz=0,0,0
                b:update_world_inertia();bodies[i]=b
            end
            collectgarbage('collect');local retained=collectgarbage('count')-before
            local keys=0;for _ in pairs(bodies[1])do keys=keys+1 end
            print(string.format('[body-storage] bodies=%d retained_kib=%.6f raw_fields_per_body=%d',#bodies,retained,keys))
            assert(bodies[4096].com_x==4096 and bodies[4096].inv_mass==0)
        end)
    end)
end

return suite
