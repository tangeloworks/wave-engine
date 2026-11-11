-- The public final sun has mass1334636800 and uses mass*currentGravity.
-- Literal acceleration/integration expectations also cover ordinary bodies.
local suite={}
function suite.run(t,h)
    local Body=h.need('physics/body.lua')
    local Movers=h.need('physics/movers.lua')
    local Integrate=h.need('physics/integrate.lua')
    local function near(a,b)assert(math.abs(a-b)<1e-7,tostring(a)..' expected '..tostring(b))end
    local function run(mass,gravity)
        local b=Body.new{mass=mass,inertia_x=mass,inertia_y=mass,inertia_z=mass,com_y=-207}
        local movers=Movers.new()
        movers:add(Movers.from_legacy({class_name='BodyForce',force={x=mass*6,y=mass*gravity,z=0}},1,'source-force'))
        local world={part_to_assembly={[1]={body=b}}}
        for _=1,120 do
            Integrate.integrate_velocity({b},1,gravity,1/60,4000)
            movers:apply(world,1/60)
            Integrate.integrate_position({b},1,1/60,4000,4000)
        end
        near(b.vy,0);near(b.com_y,-207);near(b.vx,12)
    end
    t.it('retains ordinary and supplied massive-body force acceleration at normal gravity',function()
        for _,mass in ipairs{.7,3207.7008617647,605538.99191368,1334636800}do run(mass,100)end
    end)
    t.it('uses the same mass-normalized force contract under low gravity',function()
        for _,mass in ipairs{.7,1334636800}do run(mass,40)end
    end)
    t.it('keeps nonfinite force inputs and extreme finite acceleration from poisoning a body',function()
        for _,force in ipairs{{x=0/0,y=math.huge,z=-math.huge},{x=1e300,y=-1e300,z=1e300}}do
            local b=Body.new{mass=1334636800,inertia_x=1,inertia_y=1,inertia_z=1}
            local movers=Movers.new();movers:add(Movers.from_legacy({class_name='BodyForce',force=force},1,'bounded'))
            movers:apply({part_to_assembly={[1]={body=b}}},1/60)
            for _,v in ipairs{b.vx,b.vy,b.vz,b.wx,b.wy,b.wz}do assert(v==v and math.abs(v)<=1e9,'nonfinite/unbounded mover result')end
        end
    end)
    t.it('wakes a parked massive body when its effective authored force changes',function()
        local mass=1334636800
        local b=Body.new{mass=mass,inertia_x=mass,inertia_y=mass,inertia_z=mass}
        local mover=Movers.from_legacy({class_name='BodyForce',force={x=0,y=mass*100,z=0}},1,'parked-source-force')
        local movers=Movers.new();movers:add(mover)
        local wakes=0
        local world={part_to_assembly={[1]={body=b}},wake_body=function(_,body)
            assert(body==b);wakes=wakes+1;body:wake()
        end}
        movers:wake_targets(world)
        b.sleeping=true;b.deep_slept=true
        movers:wake_targets(world);assert(wakes==0,'unchanged parked force woke its body')
        mover.force.y=mass*40
        movers:wake_targets(world)
        assert(wakes==1 and not b.sleeping,'large force edit did not wake its actual target')
        assert(b._mover_sig==b._mover_sig and math.abs(b._mover_sig)<math.huge,'nonfinite force wake signature')
    end)
end
return suite
