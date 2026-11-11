-- Robot 64 character animation, ported from zKevin's scripts.
-- anim()/trsCF() joint chains are evaluated without globals, descendant scans,
-- waits or per-frame Size/texture writes. Only the supported movement states
-- participate, including public water/pole/rope, held-object and equipment
-- chains. Multiplayer anim2 remains a separate obligation.
local Animation = {}
Animation.__index = Animation
local pi, sin, abs = math.pi, math.sin, math.abs
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function ease(value,target,rate,dt)
    -- Exactly the reference coefficient at 60 Hz, stable at other step lengths.
    return value+(target-value)*(1-(1-rate/60)^(dt*60))
end

local pose_inputs={"sliderp","wallerp","fallerp","longerp","croucherp","lederp","aterp",
    "walktick","walklerp","rotand","botand","potand","on_wall","swiperp","rollerp",
    "swimerp","polerp","roperp","holderp","dancerp","skaterp","flamerp","dab",
    "time","boarderp","scale","shrink"}
local joints={torso=true,head=true,armA=true,armB=true,armC=true,armD=true,legA=true,legB=true}
local pose_caches=setmetatable({},{__mode="k"})

local cos=math.cos

local function matrix_of(cf)
    return {cf.x,cf.y,cf.z,cf.r00,cf.r01,cf.r02,cf.r10,cf.r11,cf.r12,cf.r20,cf.r21,cf.r22}
end

local function new_pose_cache(C)
    local constants={
        head=C.new(0,.8,0),leg=C.new(0,-.7,0),arm=C.new(0,-.4,0),elbow=C.new(0,-.3,0),
        shoulderA=C.new(.5,.6,0),shoulderB=C.new(-.5,.6,0),
        pack=C.new(0,.12,.48),pack_angle=C.Angles(1.44,pi,0),
        bt1=C.new(-.13,.23,.19),bt2=C.new(-.13,-.09,.24),
        bt3=C.new(.13,-.09,.24),bt4=C.new(.13,.23,.19),battery_angle=C.Angles(0,pi/2,-.1),
    }
    local matrices={}
    for name,cf in pairs(constants) do matrices[name]=matrix_of(cf) end
    return {C=C,inputs={},outputs={},template={},constants=constants,matrices=matrices}
end

local function m_translate(m,x,y,z)
    m[1],m[2],m[3]=x,y,z
    m[4],m[5],m[6]=1,0,0
    m[7],m[8],m[9]=0,1,0
    m[10],m[11],m[12]=0,0,1
end

local function m_angles(m,rx,ry,rz)
    local sx,cx=sin(rx),cos(rx)
    local sy,cy=sin(ry),cos(ry)
    local sz,cz=sin(rz),cos(rz)
    local x=0+1*0+0*0+0*0
    local y=0+0*0+cx*0+(-sx)*0
    local z=0+0*0+sx*0+cx*0
    local r00=1*cy+0*0+0*(-sy)
    local r01=1*0+0*1+0*0
    local r02=1*sy+0*0+0*cy
    local r10=0*cy+cx*0+(-sx)*(-sy)
    local r11=0*0+cx*1+(-sx)*0
    local r12=0*sy+cx*0+(-sx)*cy
    local r20=0*cy+sx*0+cx*(-sy)
    local r21=0*0+sx*1+cx*0
    local r22=0*sy+sx*0+cx*cy
    m[1],m[2],m[3]=x+r00*0+r01*0+r02*0,y+r10*0+r11*0+r12*0,z+r20*0+r21*0+r22*0
    m[4],m[5],m[6]=r00*cz+r01*sz+r02*0,r00*(-sz)+r01*cz+r02*0,r00*0+r01*0+r02*1
    m[7],m[8],m[9]=r10*cz+r11*sz+r12*0,r10*(-sz)+r11*cz+r12*0,r10*0+r11*0+r12*1
    m[10],m[11],m[12]=r20*cz+r21*sz+r22*0,r20*(-sz)+r21*cz+r22*0,r20*0+r21*0+r22*1
end

local function m_mul(out,a,b)
    local ax,ay,az,a00,a01,a02,a10,a11,a12,a20,a21,a22=a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12]
    local bx,by,bz,b00,b01,b02,b10,b11,b12,b20,b21,b22=b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12]
    out[1]=ax+a00*bx+a01*by+a02*bz
    out[2]=ay+a10*bx+a11*by+a12*bz
    out[3]=az+a20*bx+a21*by+a22*bz
    out[4]=a00*b00+a01*b10+a02*b20
    out[5]=a00*b01+a01*b11+a02*b21
    out[6]=a00*b02+a01*b12+a02*b22
    out[7]=a10*b00+a11*b10+a12*b20
    out[8]=a10*b01+a11*b11+a12*b21
    out[9]=a10*b02+a11*b12+a12*b22
    out[10]=a20*b00+a21*b10+a22*b20
    out[11]=a20*b01+a21*b11+a22*b21
    out[12]=a20*b02+a21*b12+a22*b22
end

local function m_cframe(C,m)
    return C.from_matrix(m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8],m[9],m[10],m[11],m[12])
end

local m_torso,m_arm_a,m_arm_b,m_elbow,m_work,m_temp={},{},{},{},{},{}

local function same_entries(value,snapshot)
    for key,entry in pairs(value) do if not rawequal(entry,snapshot[key]) then return false end end
    for key in pairs(snapshot) do if value[key]==nil then return false end end
    return true
end

local function snapshot_entries(value,snapshot)
    for key in pairs(snapshot) do snapshot[key]=nil end
    if value then for key,entry in pairs(value) do snapshot[key]=entry end end
end

local function cacheable_template(templates,chosen,C)
    if templates and (type(templates)~="table" or getmetatable(templates)~=nil) then return false end
    if not chosen then return true end
    if type(chosen)~="table" or getmetatable(chosen)~=nil then return false end
    for name,cf in pairs(chosen) do
        if not joints[name] or getmetatable(cf)~=C then return false end
    end
    return true
end

function Animation.new(rbx)
    local self=setmetatable({C=rbx.CFrame,V=rbx.Vector3,poses={}},Animation)
    pose_caches[self]=new_pose_cache(rbx.CFrame)
    self:reset()
    return self
end

function Animation:reset()
    local cache=pose_caches[self]
    if cache then cache.valid=false end
    self.time,self.walktick,self.walklerp=0,0,0
    self.rotand,self.botand,self.potand=0,0,0
    self.fallvr=1
    self.blink,self.blink_clock,self.blink_seed=10,0,1
    self.spin_wraps,self.double_flip_serial=0,0
    self.face_id="rbxassetid://1451094768"
    for _,key in ipairs({"sliderp","wallerp","fallerp","longerp","croucherp","lederp","rollerp","aterp","swiperp","swimerp","polerp","roperp","holderp","dancerp","skaterp","flamerp","dab"}) do self[key]=0 end
    self.boarderp=self.V.new();self.scale=self.V.new(1,1,1);self.shrink=false
    self.double_flips=nil;self.dot_position=nil;self.dot_velocity=self.V.new()
    self.gotice=false
    self.dot_head=nil;self.dot_scale=nil;self.last_position=nil
end

function Animation:event(name, time)
    if name=="jump" then self.fallvr=-self.fallvr
    elseif name=="double" then
        self.botand=self.botand-2;self.fallvr=-self.fallvr
        self.double_flips={next=(time or self.time)+.15,left=3}
    elseif name=="longjump" then self.botand=pi*4
    elseif name=="backflip" then self.botand=-pi*4
    elseif name=="skidjump" then self.potand=pi;self.botand=pi*4
    elseif name=="recovery" or name=="pound" then self.botand=pi*2
    elseif name=="away" then self.botand=-pi*2
    elseif name=="climb" then self.rotand=self.rotand+1
    elseif name=="twirl" then self.potand=self.potand+pi*2
    elseif name=="land" then self.walklerp=0 end
end

-- Result CFrames are relative to mps (one stud below Char), in the exact
-- multiplication order used by anim(). The output table is reused per rig.
function Animation:evaluate(templates)
    local C=self.C
    local cache=pose_caches[self]
    if not cache or cache.C~=C then cache=new_pose_cache(C);pose_caches[self]=cache end
    if self.gotice then
        local collection=assert(templates and templates.collection,'Public collection pose missing')
        -- CharacterScript anim's gotice branch writes rf.pose relative to mps,
        -- with no locomotion blend or scale multiplication. Nonmatching
        -- accessory channels retain their preceding source pose.
        for name,frame in pairs(collection) do self.poses[name]=frame end
        cache.valid=false
        return self.poses
    end
    local kind=self.swiperp>.01 and 'skid' or self.rollerp>.01 and 'roll' or self.dab>.01 and 'dab' or self.flamerp>.01 and 'flame'
    local blend=kind=='skid' and self.swiperp or kind=='roll' and self.rollerp or kind=='dab' and self.dab or kind=='flame' and self.flamerp or 0
    local chosen=templates and templates[kind]
    local active_template=blend>0 and chosen or nil
    local pose=self.poses
    -- State fields and template tables may be edited directly. Only immutable
    -- frame values are shared; replacing a returned pose invalidates the cache.
    local cacheable=getmetatable(pose)==nil and cacheable_template(templates,active_template,C)
    local unchanged=cacheable and cache.valid and rawequal(cache.pose,pose)
        and rawequal(cache.chosen,active_template) and same_entries(pose,cache.outputs)
        and (not active_template or same_entries(active_template,cache.template))
    if unchanged then
        for _,key in ipairs(pose_inputs) do
            if self[key]~=cache.inputs[key] then unchanged=false;break end
        end
        if unchanged then return pose end
    end
    cache.valid=false
    local k=cache.constants
    local scale=self.scale
    local scaled=scale and (scale.X~=1 or scale.Y~=1 or scale.Z~=1)
    local slide,wall,fall,long=self.sliderp,self.wallerp,self.fallerp,self.longerp
    local crouch,ledge,attack=self.croucherp,self.lederp,self.aterp
    local swim,pole,rope=self.swimerp,self.polerp,self.roperp
    local hold,dance,skate=self.holderp,self.dancerp,self.skaterp
    local grn=1-abs(fall)
    local nrm=(1-hold)*(1-crouch)*(1-ledge)*(1-pole)*(1-attack)*(1-dance)
    local wtk=sin(self.walktick*14)*self.walklerp
    local wallslide=(1-self.walklerp)*wall*(1-ledge)*(1-skate)
    local bounce=abs(wtk)*(.8*grn)/(rope+1)*(1-swim)
    local swing=wtk*-1.2*grn/(rope+1)/(pole+1)+fall*(1-slide)*(1-long)*(1-attack)+sin(self.time*6)*dance
    local ax=slide*2-long+crouch+(-swim-self.walklerp*swim-(skate+self.rotand*skate)*.4)*nrm+pole+swing*pole/2+wallslide
    local ay=swing*nrm*(1-swim)+hold+swing*dance/2*(1-hold)
    local az=.6+(self.walklerp*.7*grn*nrm*(1-swim)+abs(fall)*nrm)*(1-rope)+rope*.7+hold/2+attack*(1-hold)-(abs(swing)*dance-dance)*(1-hold)
    local bx=(slide/2+(skate+self.rotand*skate)*.4+wallslide)*nrm+hold/2+crouch*(1-hold)+pole*(1-hold)+(sin(self.time*3)*dance/4+dance/2)*(1-hold)
    local bz=fall*.8*(1-long)*nrm
    local hip=grn*1.4-slide*1.4-crouch-wall
    if scaled then
        local function offset(x,y,z) return scaled and C.new(x*scale.X,y*scale.Y,z*scale.Z) or C.new(x,y,z) end
        local function constant(name)
            local cf=k[name]
            return scaled and (cf-cf.Position+cf.Position*scale) or cf
        end
        local torso=offset(0,-hip+swim*1.4+skate*.4+abs(-swing)*dance/9+wall-slide*1.4,0)
            *C.Angles(0,0,self.rotand+wtk*crouch/5+wtk*pole/12)
            *C.Angles(self.botand+abs(self.rotand)/2*wall,self.potand+sin(self.walktick*7)*swim*.1-skate*1.5+swing*dance/8,0)
            *offset(0,(self.on_wall and bounce/2 or bounce)/(pole*3+1)+hip,crouch*.5)
        pose.torso=torso
        pose.head=torso*constant('head')*C.Angles(slide-long+crouch*.8+pole/2,skate-wallslide,self.rotand*.2+swing*dance/4)*constant('head')
        pose.legA=torso*offset(.35,-.5+wtk*crouch/3+crouch/2,-.15-crouch/3)
            *C.Angles(-swing*(1-dance*.8)*(1-swim/2)*(1-crouch/2)*(1-pole)+pole/2+swing*pole/4+long-slide/2+ledge-self.rotand*skate/4+wallslide,0,-rope*.3-pole*.3+attack/4+.1+skate/4+math.min(0,swing*dance/2))*constant('leg')
        pose.legB=torso*offset(-.35,-.5-wtk*crouch/3+crouch/2,-.15-crouch/3)
            *C.Angles(swing*(1-dance*.8)*(1-swim/2)*(1-crouch/2)*(1-pole)+pole/2-swing*pole/4+long-slide/2+ledge-self.rotand*skate/2+wallslide,0,rope*.3+pole*.3-attack/4-.1-skate/4+math.max(0,swing*dance/2))*constant('leg')
        pose.armA=torso*constant('shoulderA')*C.Angles(ax+ledge,ay,az)*constant('arm')
        pose.armB=torso*constant('shoulderB')*C.Angles(ax+ledge,ay*(-hold*2+1),-az)*constant('arm')
        local elbow=dance==0 and constant('elbow') or offset(0,-.3-abs(swing*dance/8),0)
        pose.armC=pose.armA*elbow*C.Angles(bx+math.max(0,swing)*(1-swim)*(1-hold)+ledge/2*(1-hold),pole,bz)*constant('arm')
        pose.armD=pose.armB*elbow*C.Angles(bx+math.max(0,-swing)*(1-swim)*(1-hold)+ledge/2*(1-hold),-pole,bz)*constant('arm')
        if templates then
            if blend>0 and chosen then
                for name,cf in pairs(chosen) do
                    if pose[name] then
                        if self.shrink then cf=cf-cf.Position+cf.Position*scale end
                        pose[name]=pose[name]:Lerp(kind=='skid' and cf or torso*cf,blend)
                    end
                end
            end
        end
        torso=pose.torso
        pose.pack=torso*constant('pack')*k.pack_angle
        pose.bt1=torso*constant('bt1')*k.battery_angle
        pose.bt2=torso*constant('bt2')*k.battery_angle
        pose.bt3=torso*constant('bt3')*k.battery_angle
        pose.bt4=torso*constant('bt4')*k.battery_angle
        pose.board=(torso*offset(0,-1.7,0)*C.Angles(0,1.5,-self.rotand*(1-wall)*grn))
            :Lerp(torso*offset(0,0,1)*C.Angles(1.5,1,0),1-skate)
            *C.Angles(self.boarderp.X*skate,self.boarderp.Y*skate,self.boarderp.Z*skate)
    else
        local m=cache.matrices
        local work,temp=m_work,m_temp
        m_translate(work,0,-hip+swim*1.4+skate*.4+abs(-swing)*dance/9+wall-slide*1.4,0)
        m_angles(temp,0,0,self.rotand+wtk*crouch/5+wtk*pole/12);m_mul(work,work,temp)
        m_angles(temp,self.botand+abs(self.rotand)/2*wall,self.potand+sin(self.walktick*7)*swim*.1-skate*1.5+swing*dance/8,0);m_mul(work,work,temp)
        m_translate(temp,0,(self.on_wall and bounce/2 or bounce)/(pole*3+1)+hip,crouch*.5);m_mul(m_torso,work,temp)
        local torso=m_cframe(C,m_torso)
        pose.torso=torso
        m_mul(work,m_torso,m.head)
        m_angles(temp,slide-long+crouch*.8+pole/2,skate-wallslide,self.rotand*.2+swing*dance/4);m_mul(work,work,temp)
        m_mul(work,work,m.head);pose.head=m_cframe(C,work)
        m_translate(temp,.35,-.5+wtk*crouch/3+crouch/2,-.15-crouch/3);m_mul(work,m_torso,temp)
        m_angles(temp,-swing*(1-dance*.8)*(1-swim/2)*(1-crouch/2)*(1-pole)+pole/2+swing*pole/4+long-slide/2+ledge-self.rotand*skate/4+wallslide,0,-rope*.3-pole*.3+attack/4+.1+skate/4+math.min(0,swing*dance/2));m_mul(work,work,temp)
        m_mul(work,work,m.leg);pose.legA=m_cframe(C,work)
        m_translate(temp,-.35,-.5-wtk*crouch/3+crouch/2,-.15-crouch/3);m_mul(work,m_torso,temp)
        m_angles(temp,swing*(1-dance*.8)*(1-swim/2)*(1-crouch/2)*(1-pole)+pole/2-swing*pole/4+long-slide/2+ledge-self.rotand*skate/2+wallslide,0,rope*.3+pole*.3-attack/4-.1-skate/4+math.max(0,swing*dance/2));m_mul(work,work,temp)
        m_mul(work,work,m.leg);pose.legB=m_cframe(C,work)
        m_mul(work,m_torso,m.shoulderA)
        m_angles(temp,ax+ledge,ay,az);m_mul(work,work,temp)
        m_mul(m_arm_a,work,m.arm);pose.armA=m_cframe(C,m_arm_a)
        m_mul(work,m_torso,m.shoulderB)
        m_angles(temp,ax+ledge,ay*(-hold*2+1),-az);m_mul(work,work,temp)
        m_mul(m_arm_b,work,m.arm);pose.armB=m_cframe(C,m_arm_b)
        local elbow=m.elbow
        if dance~=0 then
            elbow=m_elbow
            m_translate(elbow,0,-.3-abs(swing*dance/8),0)
        end
        m_mul(work,m_arm_a,elbow)
        m_angles(temp,bx+math.max(0,swing)*(1-swim)*(1-hold)+ledge/2*(1-hold),pole,bz);m_mul(work,work,temp)
        m_mul(work,work,m.arm);pose.armC=m_cframe(C,work)
        m_mul(work,m_arm_b,elbow)
        m_angles(temp,bx+math.max(0,-swing)*(1-swim)*(1-hold)+ledge/2*(1-hold),-pole,bz);m_mul(work,work,temp)
        m_mul(work,work,m.arm);pose.armD=m_cframe(C,work)
        local blended=false
        if templates then
            if blend>0 and chosen then
                for name,cf in pairs(chosen) do
                    if pose[name] then
                        if self.shrink then cf=cf-cf.Position+cf.Position*scale end
                        pose[name]=pose[name]:Lerp(kind=='skid' and cf or torso*cf,blend)
                        blended=true
                    end
                end
            end
        end
        torso=pose.torso
        if blended then
            m_torso[1],m_torso[2],m_torso[3]=torso.x,torso.y,torso.z
            m_torso[4],m_torso[5],m_torso[6]=torso.r00,torso.r01,torso.r02
            m_torso[7],m_torso[8],m_torso[9]=torso.r10,torso.r11,torso.r12
            m_torso[10],m_torso[11],m_torso[12]=torso.r20,torso.r21,torso.r22
        end
        m_mul(work,m_torso,m.pack);m_mul(work,work,m.pack_angle);pose.pack=m_cframe(C,work)
        m_mul(work,m_torso,m.bt1);m_mul(work,work,m.battery_angle);pose.bt1=m_cframe(C,work)
        m_mul(work,m_torso,m.bt2);m_mul(work,work,m.battery_angle);pose.bt2=m_cframe(C,work)
        m_mul(work,m_torso,m.bt3);m_mul(work,work,m.battery_angle);pose.bt3=m_cframe(C,work)
        m_mul(work,m_torso,m.bt4);m_mul(work,work,m.battery_angle);pose.bt4=m_cframe(C,work)
        pose.board=(torso*C.new(0,-1.7,0)*C.Angles(0,1.5,-self.rotand*(1-wall)*grn))
            :Lerp(torso*C.new(0,0,1)*C.Angles(1.5,1,0),1-skate)
            *C.Angles(self.boarderp.X*skate,self.boarderp.Y*skate,self.boarderp.Z*skate)
    end
    if cacheable then
        for _,key in ipairs(pose_inputs) do cache.inputs[key]=self[key] end
        snapshot_entries(pose,cache.outputs)
        snapshot_entries(active_template,cache.template)
        cache.pose,cache.chosen,cache.valid=pose,active_template,true
    end
    return pose
end

function Animation:advance(dt,controller,dir,crouch_held)
    local s=controller.state
    self.time=controller.time or self.time+dt
    local flips=self.double_flips
    if flips then
        if s.ground or s.wall or s.rope or s.sliding then self.double_flips=nil
        else
            while flips.left>0 and self.time+1e-9>=flips.next do
                self.fallvr=-self.fallvr;flips.left=flips.left-1;flips.next=flips.next+.15
                self.double_flip_serial=self.double_flip_serial+1
            end
            if flips.left==0 then self.double_flips=nil end
        end
    end
    local normal=controller.ground_hit and controller.ground_hit.Normal or self.V.new()
    local facing=controller.state.flying and controller.state.equipment_pose_facing or controller.facing
    local right=controller.state.flying and controller.state.equipment_pose_facing
        and self.C.lookAt(self.V.new(),facing).RightVector or controller:_right()
    local velocity=controller.visual_velocity or controller.body.Velocity
    local unit=velocity.Magnitude>.2 and velocity.Unit or self.V.new()
    local roll=s.rope and sin(self.time)/4 or s.wall and clamp(-s.wall_normal:Dot(right)*6,-1.5,1.5)
        or s.ground and (clamp((controller.gyro and controller.body.CFrame.LookVector or facing):Dot(right)
            *dir.Magnitude*1.5,-.8,.8)-normal:Dot(right)) or 0
    self.rotand=ease(self.rotand,roll,6,dt)
    local pitch
    if s.ledge or s.rope or s.pole or s.attack then pitch=0
    elseif s.skate then pitch=clamp(s.ground and -facing:Dot(normal) or velocity.Y/40,-.8,.8)
    elseif s.swimming then pitch=-1.4+clamp(velocity.Y/20,-.8,.8)
    elseif s.flying then pitch=(s.equipment_pose_pitch or s.flypitch or 0)-1.4
    elseif s.wall then pitch=(1.5-abs(self.rotand))*math.max(0,unit.Y)
    elseif s.sliding then pitch=-1.3+clamp(s.ground and -facing:Dot(normal) or velocity.Y/40,-.8,.8)
    elseif s.ground then pitch=-dir.Magnitude/5-normal:Dot(facing)-(s.crouch and 1.2 or 0)
    elseif s.rolling then pitch=0
    else pitch=clamp(velocity.Y/40,-1,1) end
    self.botand=ease(self.botand,pitch,s.longjump and not s.pound and 3 or 6,dt)
    if s.attack then
        self.potand=self.potand-dt*(20+(crouch_held and 10 or 0))
        if self.potand<0 then self.potand=self.potand+2*pi;self.spin_wraps=self.spin_wraps+1 end
    else self.potand=ease(self.potand,s.flying and clamp(-controller.body.CFrame.LookVector:Dot(right)*dir.Magnitude*8,-1,1) or 0,(s.skate or s.flying) and 3 or 8,dt) end
    self.sliderp=ease(self.sliderp,(s.sliding or s.swimming) and 1 or 0,10,dt)
    self.wallerp=ease(self.wallerp,s.wall and 1 or 0,10,dt)
    self.fallerp=ease(self.fallerp,(s.ground or s.wall or s.sliding or s.rope or s.pole or s.swimming or s.skate) and 0 or self.fallvr,10,dt)
    self.longerp=ease(self.longerp,s.longjump and 1 or 0,10,dt)
    self.croucherp=ease(self.croucherp,s.crouch and s.ground and not s.sliding and 1 or 0,10,dt)
    self.lederp=ease(self.lederp,s.ledge and 1 or 0,10,dt)
    self.rollerp=ease(self.rollerp,s.rolling and 1 or 0,10,dt)
    self.aterp=ease(self.aterp,s.attack and 1 or 0,10,dt)
    self.swiperp=ease(self.swiperp,s.skid and 1 or 0,10,dt)
    self.roperp=ease(self.roperp,s.rope and 1 or 0,10,dt)
    self.polerp=ease(self.polerp,s.pole and 1 or 0,10,dt)
    self.swimerp=ease(self.swimerp,s.swimming and 1 or 0,10,dt)
    self.holderp=ease(self.holderp,s.holding and 1 or 0,10,dt)
    self.dancerp=ease(self.dancerp,s.dancing and 1 or 0,10,dt)
    self.skaterp=ease(self.skaterp,s.skate and 1 or 0,10,dt)
    local flameon=s.equipment_pose_flameon
    if flameon==nil then flameon=s.flameon end
    self.flamerp=ease(self.flamerp,flameon and 1 or 0,10,dt)
    self.boarderp=self.boarderp+(self.V.new(0,0,-normal:Dot(right))-self.boarderp)*math.min(1,dt*6)
    self.shrink=s.shrink==true;self.scale=s.scale or (self.shrink and self.V.new(.5,.5,.5) or self.V.new(1,1,1))
    local speed=controller.visual_speed or 0
    if s.skate then speed=0
    elseif s.wall then
        local basis=controller.gyro and (controller.body.CFrame-controller.body.Position)
            or self.C.lookAt(self.V.new(),facing)
        local world_torso=basis*(self.poses.torso or self.C.new())
        speed=clamp(world_torso.LookVector:Dot(velocity)/10,0,1)
    end
    self.walklerp=ease(self.walklerp,speed,4,dt)
    self.walktick=self.walktick+dt*speed*(1-abs(self.fallerp))
    self.on_wall=s.wall~=nil
    self:evaluate(self.templates)
    self:_dot(dt,controller.body.Position,facing,controller.gyro and controller.body.CFrame)
    self:_face(dt)
end

-- Reference .06-second face cadence, with a per-character deterministic RNG
-- instead of touching the application's global random stream.
function Animation:_face(dt)
    self.blink_clock=self.blink_clock+dt
    while self.blink_clock+1e-9>=.06 do
        self.blink_clock=self.blink_clock-.06
        self.blink=self.blink-1
        if self.blink<0 then
            self.blink_seed=(self.blink_seed*16807)%2147483647
            self.blink=self.blink+20+(self.blink_seed%4+1)*10
        end
    end
    self.face_id=self.blink==1 and "rbxassetid://1451125369"
        or (self.blink==2 or self.blink==0) and "rbxassetid://1451125125"
        or "rbxassetid://1451094768"
end

function Animation:_dot(dt,position,facing,body_frame)
    local V,C=self.V,self.C
    local root=body_frame and body_frame-V.new(0,1,0)
        or C.lookAt(position-V.new(0,1,0),position-V.new(0,1,0)+facing)
    local head=root*self.poses.head
    local scale_y=self.scale and self.scale.Y or 1
    local target=head.Position+head.UpVector*(2*scale_y)
    self:sync_dot(head,self.scale or V.new(1,1,1),position)
    if not self.dot_position then self.dot_position=target end
    -- Source spring/clamp, on the same bounded fixed cadence as movement.
    local remaining=dt
    while remaining>1e-9 do
        local step=math.min(1/60,remaining);remaining=remaining-step
        local delta=target-self.dot_position
        self.dot_velocity=self.dot_velocity+delta*step*8-self.dot_velocity*math.min(1,step*5)
        -- Requested shrink repair: the public floor used an unscaled1.5,
        -- unlike its scaled target/reach. Keep all spring bounds local-scale.
        local floor=head.Position.Y+head.UpVector.Y*1.5*scale_y
        if self.dot_position.Y<floor then self.dot_position=V.new(self.dot_position.X,floor,self.dot_position.Z) end
        local offset=self.dot_position-target
        if offset.Magnitude>2*scale_y then self.dot_position=target+offset.Unit*(1.9*scale_y);self.dot_velocity=V.new()
        else self.dot_position=self.dot_position+self.dot_velocity*step*10 end
    end
    self.last_position=position
    self.dot_head=head;self.dot_scale=self.scale or V.new(1,1,1)
end

-- Cinematic scale publication can occur between fixed controller steps.
-- Carry a flexible spring's local displacement once across a scale boundary;
-- reset only at discontinuous actor translation, never scale world position.
function Animation:sync_dot(head,scale,position)
    local previous=self.dot_scale;local old_head=self.dot_head
    local moved=self.last_position and (position-self.last_position).Magnitude>8
    if moved then
        self.dot_position=head.Position+head.UpVector*(2*scale.Y);self.dot_velocity=self.V.new()
    elseif self.dot_position and old_head and previous
        and (previous.X~=scale.X or previous.Y~=scale.Y or previous.Z~=scale.Z) then
        local ratio=self.V.new(scale.X/math.max(1e-6,previous.X),scale.Y/math.max(1e-6,previous.Y),scale.Z/math.max(1e-6,previous.Z))
        self.dot_position=head:PointToWorldSpace(old_head:PointToObjectSpace(self.dot_position)*ratio)
        self.dot_velocity=head:VectorToWorldSpace(old_head:VectorToObjectSpace(self.dot_velocity)*ratio)
    end
    if moved or not previous or previous.X~=scale.X or previous.Y~=scale.Y or previous.Z~=scale.Z then
        self.dot_head=head;self.dot_scale=scale;self.last_position=position
    end
end

return Animation
