-- Follow/orbit camera; public RBX camera/query APIs only.
local RayFilter = require('projects/showcase3d/robot64/ray_filter')
local Camera = {}
Camera.__index = Camera
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function Camera.new(world, body, rbx, options)
    options = options or {}
    local params = rbx.RaycastParams.new()
    RayFilter.assign(params, { body })
    params.RespectCanCollide = true
    local self=setmetatable({ world = world, body = body, rbx = rbx, params = params,options=options,
        yaw = options.yaw or -math.pi / 2, pitch = options.pitch or -0.25,
        distance = options.distance or 14, height = options.height or 2,
        free_speed = options.free_speed or 32, sensitivity = options.sensitivity or 0.003,
        fast_multiplier = options.fast_multiplier or 4,
        source_follow = options.source_follow == true, still_camera = options.still_camera,
        dialogue = options.dialogue,
        free = false, position = nil, destroyed = false }, Camera)
    if self.source_follow then
        self.zoom=options.zoom or 2;self.pzom=2;self.pitch=-.4
        self.camcf=rbx.CFrame.new();self.vcf=rbx.CFrame.new();self.camtand=rbx.Vector3.new()
        self.snapcam=0;self.snapto=rbx.Vector3.new();self.firstperson=false;self.yim=rbx.Vector3.new()
        self.source_context=options.source_context;self.params.FilterType='Exclude'
        if options.snapshot_template then
            self.snapshot=require('projects/showcase3d/robot64/source').clone(options.snapshot_template,world,rbx)
            self.snapshot.Parent=options.snapshot_template.Parent
            self.snapshot_force=assert(self.snapshot:FindFirstChild('force'),'Public snapshot camera force missing')
        end
    end
    return self
end

function Camera:_forward()
    local cp = math.cos(self.pitch)
    return self.rbx.Vector3.new(math.cos(self.yaw) * cp, math.sin(self.pitch), math.sin(self.yaw) * cp)
end

---Horizontal direction uses the same yaw as the visible camera, including free return.
function Camera:movement_axes(x, z)
    return -math.sin(self.yaw) * x - math.cos(self.yaw) * z,
        math.cos(self.yaw) * x - math.sin(self.yaw) * z
end

function Camera:set_free(active, snap_follow)
    if self.source_editor then self:set_editor_free(false) end
    active = not not active
    if self.free == active then return end
    if self.source_follow then
        if active then
            assert(self.snapshot,'Public snapshot template required for source snapshot controls')
            local frame=self.world.Workspace.CurrentCamera.CFrame
            self:handoff(frame)
            self.snapshot.CFrame=self.rbx.CFrame.new(frame.Position)
            self.snapshot.Velocity=self.rbx.Vector3.new();self.snapshot.Parent=self.world.Workspace
        else
            self.snapshot.Parent=self.options.snapshot_template.Parent;self.snapshot_force.Force=self.rbx.Vector3.new();self.pzom=0
        end
        self.snapshot_direction=self.rbx.Vector3.new()
        self.free=active;return
    end
    local camera = self.world.Workspace.CurrentCamera
    if camera then
        local cf = camera.CFrame
        self.position = cf.Position
        local look = cf.LookVector
        self.yaw = math.atan2(look.Z, look.X)
        self.pitch = math.atan2(look.Y, math.sqrt(look.X * look.X + look.Z * look.Z))
        self.recovery_direction = not active and look or nil
    end
    self.free = active
    self.follow_target = not active and (self.body.Position + self.rbx.Vector3.new(0, self.height, 0)) or nil
    if not active and snap_follow then self.position, self.recovery_direction = nil, nil end
end

-- Authoring free flight has a separate lifecycle from the public paused
-- snapshot body/force controls; it publishes the native camera directly.
function Camera:set_editor_free(active)
    active=not not active
    if self.source_editor==active then return end
    if active and self.source_follow and self.free then self:set_free(false) end
    self.source_editor=active
    if active then
        local camera=self.world.Workspace.CurrentCamera
        if camera then
            local cf=camera.CFrame;local look=cf.LookVector
            self.position=cf.Position
            self.yaw=math.atan2(look.Z,look.X)
            self.pitch=math.atan2(look.Y,math.sqrt(look.X*look.X+look.Z*look.Z))
        end
        self.recovery_direction=nil;self.follow_target=nil
    end
end

-- The actor flight camera is distinct from the source paused snapshot body.
function Camera:set_actor_flight(active)
    active=not not active
    if self.source_debug==active then return end
    self.source_debug=active
    if active then
        local cf=self.world.Workspace.CurrentCamera.CFrame;local look=cf.LookVector
        self.yaw=math.atan2(look.Z,look.X);self.pitch=math.atan2(look.Y,math.sqrt(look.X*look.X+look.Z*look.Z))
        self.debug_distance=math.max(3,(cf.Position-self.body.Position).Magnitude)
        self.debug_height=(cf.Position-self.body.Position).Y
        self.position=cf.Position;self.yim=self.rbx.Vector3.new()
    else
        if self.body.Parent and self.body.Position then self:handoff(self.world.Workspace.CurrentCamera.CFrame)
        else self.yim=self.rbx.Vector3.new();self.position=nil;self.handoff_frame=nil end
        self.debug_distance,self.debug_height=nil,nil
    end
end

function Camera:flight_direction(x,z,up)
    local V=self.rbx.Vector3;local forward=self:_forward()
    return V.new(-math.sin(self.yaw),0,math.cos(self.yaw))*x-forward*z+V.new(0,up,0)
end

-- Called once after the cinematic writer has retired. Reverse the source
-- pitch/orbit product instead of applying that orbit to an already final pose.
function Camera:handoff(frame,options)
    options=options or {};local V,C=self.rbx.Vector3,self.rbx.CFrame
    assert(frame and frame.Position and frame.LookVector,'Finite final camera pose required')
    local p,l=frame.Position,frame.LookVector
    assert(p.X==p.X and p.Y==p.Y and p.Z==p.Z and p.Magnitude<math.huge and l.Magnitude>1e-6,'Finite final camera pose required')
    local pitch=math.atan2(l.Y,math.sqrt(l.X*l.X+l.Z*l.Z))
    local d=options.distance or (options.zoom and options.zoom*10) or self.zoom and self.zoom*10 or self.distance
    self.pitch,self.yaw=pitch,math.atan2(l.Z,l.X);self.zoom=clamp(d/10,.5,5);d=self.zoom*10
    self.camcf=frame*C.new(0,0,-d)*C.Angles(-pitch,0,0)*C.new(0,0,d)
    self.vcf,self.position,self.distance=frame,p,d
    self.pzom=0;self.camtand=V.new();self.yim=V.new();self.snapcam=0;self.snapto=V.new();self.firstperson=false
    self.follow_target=nil;self.recovery_direction=nil;self.dialogue_frame=nil
    self.handoff_frame=nil;self.handoff_body=nil;self.handoff_first=true
    local camera=self.world.Workspace.CurrentCamera
    if camera then camera.CFrame=frame;camera.Focus=C.new(self.body.Position+V.new(0,2,0)) end
    return true
end

function Camera:source_follow_frame()
    local C=self.rbx.CFrame;local distance=self.zoom*10
    return self.camcf*C.new(0,0,-distance)*C.Angles(self.pitch,0,0)*C.new(0,0,distance)
end

-- A covered map activation publishes a fresh pose at the admitted actor.
-- The cinematic lease remains owned; only this explicit preparation call
-- evaluates the ordinary source camera without its previous writer's lock.
function Camera:prepare_follow(facing)
    if self.destroyed or not self.body.Parent then return false end
    local V,C=self.rbx.Vector3,self.rbx.CFrame
    facing=facing or self.body.CFrame.LookVector
    local horizontal=V.new(facing.X,0,facing.Z)
    if horizontal.Magnitude<1e-6 then horizontal=V.new(math.cos(self.yaw),0,math.sin(self.yaw))end
    local target=self.body.Position+V.new(0,1,0)
    local zoom=self.zoom or self.distance/10
    self.camcf=C.lookAt(target,target+horizontal)*C.new(0,0,zoom*10)
    self.vcf=self.camcf*C.new(0,0,-zoom*10)*C.Angles(self.pitch,0,0)*C.new(0,0,zoom*10)
    self.pzom=0;self.camtand=V.new();self.yim=V.new();self.firstperson=false
    self.snapcam=0;self.snapto=V.new();self.handoff_first=nil;self.handoff_frame=nil
    self.handoff_body=nil;self.follow_target=nil;self.recovery_direction=nil;self.dialogue_frame=nil
    self.touchcam=nil;self.source_regions=nil
    local context={};for k,v in pairs(self.source_context and self.source_context()or{})do context[k]=v end
    context.lockcam=false;context.anicam=nil;context.paused=false;context.pause_visible=false
    context.gotice=false;context.speaker=nil;context.touchcam=nil;context.regions=nil
    local camera=self.world.Workspace.CurrentCamera
    if not camera then return false end
    if self.source_follow then self:_source_update(0,camera,context)
    else self.position=nil;self:update(0)end
    return true
end

-- Consume frame input before physics so movement uses this frame's camera yaw.
-- Publish the camera separately, after the ball's final physics pose is visible.
function Camera:read_input(dt, input)
    if self.destroyed then return end
    input = input or {}
    if input.suspended then
        if self.source_follow and self.free then self.snapshot_direction=self.rbx.Vector3.new() end
        return
    end
    if self.source_follow and not self.source_editor and not self.source_debug then return self:_source_input(dt,input) end
    self.look_active=math.abs(input.look_x or 0)+math.abs(input.look_y or 0)>0.0001
    self.yaw = self.yaw + (input.look_x or 0) * self.sensitivity
    self.pitch = clamp(self.pitch - (input.look_y or 0) * self.sensitivity, -1.35, 1.2)
    if (self.free or self.source_editor) and not self.source_debug then
        local camera = self.world.Workspace.CurrentCamera
        if not self.position and not camera then return end
        self.position = self.position or camera.CFrame.Position
        local V, forward = self.rbx.Vector3, self:_forward()
        local right = V.new(-math.sin(self.yaw), 0, math.cos(self.yaw))
        local movement = right * (input.x or 0) - forward * (input.z or 0) + V.new(0, input.up or 0, 0)
        if movement.Magnitude > 1 then movement = movement.Unit end
        local speed = self.free_speed * (input.fast and self.fast_multiplier or 1)
        self.position = self.position + movement * (speed * dt)
    end
end

function Camera:wheel(delta)
    if not self.source_follow or self.source_editor or delta==0 then return end
    self.zoom=clamp(self.zoom-delta*.5,.5,5)
    if delta>0 and self.zoom==.5 then self.firstperson=true elseif delta<0 then self.firstperson=false end
end
function Camera:snap(facing)
    if not self.source_follow or self.source_editor or not facing then return end
    local V,C=self.rbx.Vector3,self.rbx.CFrame
    local point=C.lookAt(V.new(),facing)
    if facing:Dot(self.camcf.LookVector)<-.9 then point=point*C.Angles(0,.1,0) end
    self.snapcam=self.snapcam+1;self.snapto=-point.RightVector
end
function Camera:_source_input(dt,input)
    local V=self.rbx.Vector3;local context=self.source_context and self.source_context() or {}
    local sx,sy=input.source_stick_x or 0,input.source_stick_y or 0
    local mx,my=input.source_mouse_x or input.look_x or 0,input.source_mouse_y or input.look_y or 0
    if input.mouse_look==false then mx,my=0,0 end
    local mouse_divisor=self.options.truly_console and 300 or 250
    local yim=V.new(mx/mouse_divisor,-my/mouse_divisor,0)
    if math.sqrt(sx*sx+sy*sy)>=.2 then yim=V.new(sx*1.3,sy,0)*dt*2.5 end
    if context.gotice then yim=V.new() end
    self.yim=self.yim+yim;self.look_active=yim.Magnitude>1e-4
    self:wheel(input.wheel or 0)
    if input.zoom_in_pressed and self.zoom==.5 then self.firstperson=true end
    if input.zoom_out_pressed then self.firstperson=false end
    self.zoom=clamp(self.zoom-((input.zoom_in and 1 or 0)-(input.zoom_out and 1 or 0))/10,.5,5)
    if input.snap_camera then
        local state=context.state or {};self:snap(state.point_facing or context.facing or self.body.CFrame.LookVector)
    end
    -- Movement reads this frame's pending heading, while camera publication
    -- waits for the final physics pose. Source snapshot movement stays planar.
    local heading=context.scripted_camera_frame or self.camcf*self.rbx.CFrame.Angles(0,-self.yim.X,0)
    self.yaw=math.atan2(heading.LookVector.Z,heading.LookVector.X)
    if self.free then
        -- Source paused snapshot direction is read before this frame's yim
        -- rotates the camera, so it intentionally uses the published heading.
        local yaw=math.atan2(self.vcf.LookVector.Z,self.vcf.LookVector.X)
        local x=-math.sin(yaw)*(input.x or 0)-math.cos(yaw)*(input.z or 0)
        local z=math.cos(yaw)*(input.x or 0)-math.sin(yaw)*(input.z or 0)
        local dir=V.new(x,input.source_snapshot_up or input.up or 0,z)
        if dir.Magnitude>1 then dir=dir.Unit end
        self.snapshot_direction=dir
    end
end
function Camera:snapshot_step(dt)
    if not self.source_follow or self.source_editor or not self.free or self.destroyed then return end
    local part,V=self.snapshot,self.rbx.Vector3
    local force=V.new(0,part:GetMass()*self.world.Workspace.Gravity,0)+(self.snapshot_direction or V.new())*700
    local delta=part.Position-self.body.Position
    if delta.Magnitude>55 then force=force-delta.Unit*(delta.Magnitude-55)*60 end
    if delta.Magnitude>65 then part.CFrame=self.rbx.CFrame.new(self.body.Position+delta.Unit*65) end
    self.snapshot_force.Force=force;part.Velocity=part.Velocity*.9^(dt*30)
end
function Camera:first_person_alpha()
    if not self.source_follow or self.source_editor or self.source_debug then return 0 end
    local context=self.source_context and self.source_context() or {}
    return self.zoom*10-self.pzom<=2 and not context.gotice and 1 or 0
end
function Camera:visual_alpha()
    local context=self.source_context and self.source_context() or {}
    return self:first_person_alpha()+((context.map and context.map.Name=='MAKE') and 1 or 0)
end
function Camera:force(controller,dt,dir,held_crouch,force,damping)
    local part=self.touchcam
    if not self.source_follow or self.source_editor or not part or not part.Parent then return force,damping end
    local value=assert(part:FindFirstChild('Pos'),'Source ToCam mask missing').Value
    if value.Y~=0 then
        local remain=self.rbx.Vector3.new(1,1,1)-value
        force=force+(part.Position*remain-controller:_mps()*remain)*400
        damping=damping*value
    end
    return force,damping
end

-- One finite cast using the source collision contract: visual/player/picks/
-- enemy collision parts and noncolliding surfaces do not shorten the boom.
function Camera:_source_cast(origin,direction,context)
    local ignored={self.body};if context.visual then ignored[#ignored+1]=context.visual end
    if self.snapshot then ignored[#ignored+1]=self.snapshot end
    for _,part in ipairs(context.ignore or {}) do ignored[#ignored+1]=part end
    local ws=self.world.Workspace
    for _,name in ipairs({'fakes','debris'}) do local node=ws.FindFirstChild and ws:FindFirstChild(name);if node then ignored[#ignored+1]=node end end
    if context.map then
        local picks=context.map:FindFirstChild('picks');if picks then ignored[#ignored+1]=picks end
    end
    RayFilter.assign(self.params,ignored)
    local seen={}
    while true do
        local hit=ws:Raycast(origin,direction,self.params)
        if not hit then return nil end
        if hit.Instance.Name~='pole' then return hit end
        assert(not seen[hit.Instance],'Source camera cast returned an excluded instance')
        seen[hit.Instance]=true;ignored[#ignored+1]=hit.Instance;RayFilter.assign(self.params,ignored)
    end
end
function Camera:_source_update(dt,camera,activation_context)
    local V,C=self.rbx.Vector3,self.rbx.CFrame
    local context=activation_context or(self.source_context and self.source_context() or {});local s=context.state or {};local animation=context.animation or {}
    if self.handoff_first then
        self.handoff_first=nil
        if not context.scripted_camera_frame then
            camera.CFrame=self.vcf;camera.Focus=C.new(self.body.Position+V.new(0,2,0));return
        end
    end
    local map=context.map;local map_name=map and map.Name or ''
    local paused=context.paused or self.free;local pause_visible=context.pause_visible and not self.free
    -- context.body_frame is the host's interpolated body pose, when given.
    local body_frame=context.body_frame or self.body.CFrame
    local mps=body_frame and body_frame-V.new(0,1,0) or C.new(self.body.Position-V.new(0,1,0))
    if self.free then mps=mps-mps.Position+self.snapshot.Position-V.new(0,2,0) end
    local horizontal=function(v) return V.new(v.X,0,v.Z) end
    local speaker=not self.source_editor and self.dialogue and self.dialogue() or context.speaker
    -- Map retirement clears source talkto. Ignore a stale host callback whose
    -- native Instance has already been detached/destroyed at that boundary.
    if speaker and (not speaker.Parent or not speaker.Position) then speaker=nil end
    local touchcam=context.touchcam;local camcf=self.camcf;local campitch=self.pitch;local zoom=self.zoom
    local yim=self.yim;self.yim=V.new()
    local regions=context.regions
    if not self.free and regions and regions.map==map then
        self.source_regions=regions
    elseif map and map_name~='MAKE' and map_name~='Boss' and self.world.Workspace.FindPartsInRegion3WithIgnoreList then
        local p=mps.Position
        local held=s.holding;local multiplier=context.region_multiplier or 1
        local hits=self.world.Workspace:FindPartsInRegion3WithIgnoreList(self.rbx.Region3.new(p-V.new(1.6,held and held.Name=='crayon' and 2 or 0,1.6)*multiplier,p+V.new(1.600000023841858,2,1.600000023841858)*multiplier),{self.body,context.visual},math.huge)
        self.source_regions=require('projects/showcase3d/robot64/source_regions').capture(hits,map,p)
    else self.source_regions=require('projects/showcase3d/robot64/source_regions').capture({},map,mps.Position) end
    touchcam=touchcam or self.source_regions.touchcam
    self.touchcam=touchcam
    if touchcam then
        local source=assert(touchcam.Parent:FindFirstChild('Cam'..touchcam.Name:sub(6)),'Source ToCam target missing')
        local mask=assert(touchcam:FindFirstChild('Pos'),'Source ToCam mask missing').Value
        if mask.Y==0 then
            camcf=camcf:Lerp(C.new(mps.X,source.Position.Y-20,mps.Z+20),math.min(1,dt*8));campitch=-1.5607963267948965
        else
            local pos=assert(source:FindFirstChild('Pos'),'Source Cam mask missing').Value
            camcf=camcf:Lerp(source.CFrame-source.Position*pos+mps.Position*pos+V.new(0,3,0),math.min(1,dt*8))
            campitch=campitch+(-.2-campitch)*dt*6
        end
        zoom=2;self.firstperson=false
        local walkto=touchcam:FindFirstChild('walkto')
        if walkto and self.options.on_walkto then self.options.on_walkto(walkto.Value,touchcam) end
    end
    if not touchcam and not speaker and not pause_visible then
        campitch=clamp(campitch+yim.Y,-1.5,1.5)
        if self.snapcam>0 then
            local dot=camcf.LookVector:Dot(self.snapto);yim=V.new(dot/5,yim.Y,0)
            if math.abs(dot)<.01 then self.snapcam=0 end
        end
        if yim.Magnitude>1e-4 or (self.still_camera and self.still_camera()) or paused or self.firstperson or map_name=='MAKE' then
            camcf=(camcf-camcf.Position+mps.Position+V.new(0,2,0))*C.Angles(0,-yim.X,0)*C.new(0,0,zoom*10)
        else
            camcf=C.lookAt(horizontal(camcf.Position),horizontal(mps.Position))*C.new(0,0,-(horizontal(camcf.Position)-horizontal(mps.Position)).Magnitude+zoom*10)+V.new(0,mps.Y+2,0)
        end
        if yim.Magnitude<=.2 and not (self.still_camera and self.still_camera()) and not paused and not self.firstperson and map_name~='MAKE' then
            if s.flying then campitch=campitch+((s.flypitch or 0)-.3-campitch)*dt
            elseif s.swimming then campitch=campitch+((animation.botand or 0)+1-campitch)*dt
            elseif (context.gtick or 0)-(context.watertick or -10)<3 then campitch=campitch+(-.4-campitch)*dt end
        end
    elseif speaker then
        self.firstperson=false
        local eye,target=mps.Position,speaker.Position;local basis=C.lookAt(horizontal(eye),horizontal(target))
        campitch=campitch-campitch*dt*8
        eye=eye+basis.LookVector-basis.RightVector*8*(self.talk_side or 1)
        target=target-basis.LookVector+basis.UpVector*2
        camcf=camcf:Lerp(C.lookAt(eye,target+V.new(0,-target.Y+eye.Y,0)),math.min(1,dt*5))
    end
    local vcf=context.scripted_camera_frame or self.vcf
    if not context.lockcam and not pause_visible then vcf=camcf*C.new(0,0,-zoom*10)*C.Angles(campitch,0,0)*C.new(0,0,zoom*10)
    elseif context.lockcam and context.anicam then vcf=vcf:Lerp(context.anicam,math.min(1,dt*(context.anidamp or 1)))
    else self.firstperson=false;self.pzom=0 end
    local hit=self:_source_cast(mps.Position+V.new(0,2,0),-vcf.LookVector*(zoom*10+1),context)
    self.last_cast_hit=hit and hit.Instance or nil
    if context.anicam or context.lockcam or speaker or touchcam then hit=nil;self.pzom=0;self.firstperson=false end
    if not pause_visible and map_name~='MAKE' then
        if hit then
            if math.abs(hit.Normal.Y)<.6 then self.camtand=self.camtand+horizontal(hit.Normal).Unit*dt*zoom/4 end
            self.pzom=(vcf.Position-vcf.LookVector-hit.Position).Magnitude
        else self.pzom=math.max(0,self.pzom-dt*40) end
    end
    if self.firstperson then self.pzom=zoom*10 end
    if not context.lockcam and not paused then vcf=vcf*C.new(0,0,-self.pzom)
    elseif paused and not pause_visible then vcf=vcf*C.new(0,0,-zoom*10) end
    self.camtand=self.camtand-self.camtand*dt*8;camcf=camcf+self.camtand*dt*800
    if context.gotice and not context.lockcam then vcf=mps*C.new(0,3,-20)*C.Angles(0,math.pi,0) end
    if type(camera.FieldOfView)=='number' then camera.FieldOfView=camera.FieldOfView+((s.flying and 70+(s.flyspeed or 0)*3 or 70)-camera.FieldOfView)*dt end
    self.camcf,self.vcf,self.pitch,self.zoom=camcf,vcf,campitch,zoom
    self.position=vcf.Position;self.yaw=math.atan2(vcf.LookVector.Z,vcf.LookVector.X);self.distance=zoom*10
    if not context.scripted_camera_frame then camera.CFrame=vcf end
    camera.Focus=C.new(mps.Position+V.new(0,2,0))
end

function Camera:begin_dialogue(speaker)
    local V,C=self.rbx.Vector3,self.rbx.CFrame
    local horizontal=function(v)return V.new(v.X,0,v.Z)end
    local basis=C.lookAt(horizontal(self.body.Position),horizontal(speaker.Position))
    local side=horizontal(self.world.Workspace.CurrentCamera.CFrame.LookVector):Dot(basis.RightVector)
    self.talk_side=side>0 and 1 or side<0 and -1 or 0
    if not self.source_follow then self.dialogue_frame=self.world.Workspace.CurrentCamera.CFrame end
end

function Camera:update(dt, input)
    if self.destroyed then return end
    if input then self:read_input(dt, input) end -- Compatibility for a single post-physics call.
    local camera = self.world.Workspace.CurrentCamera
    if not camera then return end -- Map loading may publish the active camera later.
    if self.published_camera ~= camera then
        camera.CameraType = self.rbx.Enum.CameraType.Scriptable
        self.published_camera = camera
    end
    local V, C = self.rbx.Vector3, self.rbx.CFrame
    if self.source_debug then
        local forward=self:_forward();local horizontal=V.new(forward.X,0,forward.Z)
        if horizontal.Magnitude<1e-6 then horizontal=V.new(math.cos(self.yaw),0,math.sin(self.yaw))end
        self.position=self.body.Position-horizontal.Unit*(self.debug_distance or self.distance)+V.new(0,self.debug_height or self.height,0)
        camera.CFrame=C.lookAt(self.position,self.position+forward);camera.Focus=C.new(self.body.Position);return
    end
    if self.source_follow and not self.source_editor then return self:_source_update(dt,camera) end
    local speaker=not self.source_editor and self.dialogue and self.dialogue()
    if speaker and speaker.Parent then
        -- Public CharacterScript8189-8198: horizontal framing at mps, one
        -- stud toward the speaker and eight studs to the recorded camera side.
        local mps=self.body.Position-V.new(0,1,0)
        local basis=C.lookAt(V.new(mps.X,0,mps.Z),V.new(speaker.Position.X,0,speaker.Position.Z))
        local eye=mps+basis.LookVector-basis.RightVector*8*(self.talk_side or 1)
        local target=speaker.Position-basis.LookVector+basis.UpVector*2
        target=V.new(target.X,eye.Y,target.Z)
        self.pitch=self.pitch*(1-math.min(1,dt*8))
        self.dialogue_frame=(self.dialogue_frame or camera.CFrame):Lerp(C.lookAt(eye,target),math.min(1,dt*5))
        camera.CFrame=self.dialogue_frame*C.new(0,0,-self.distance)*C.Angles(self.pitch,0,0)*C.new(0,0,self.distance)
        camera.Focus=C.new(target);self.position=camera.CFrame.Position;self.follow_target=nil
        return
    end
    self.dialogue_frame=nil
    local forward = self:_forward()
    if self.free or self.source_editor then
        self.position = self.position or camera.CFrame.Position
        camera.CFrame = C.lookAt(self.position, self.position + forward)
        camera.Focus = C.new(self.position + forward * self.distance)
    else
        local target = self.body.Position + V.new(0, self.height, 0)
        local tracking=self.source_follow and not (self.still_camera and self.still_camera())
            and not self.look_active and not self.recovery_direction
        if tracking and self.position then
            local dx,dz=target.X-self.position.X,target.Z-self.position.Z
            if dx*dx+dz*dz>0.00000001 then self.yaw=math.atan2(dz,dx);forward=self:_forward() end
        end
        -- Translate eye and target together. Smoothing only the eye against a
        -- fixed-step target makes the ball wobble, especially above physics Hz.
        -- Orbit and recovery change only the offset relative to that target.
        if self.position and self.follow_target and not tracking then
            self.position = self.position + (target - self.follow_target)
        end
        self.follow_target = target
        local wanted = target - forward * self.distance
        local blend = 1 - math.exp(-12 * dt)
        local next_position
        if self.recovery_direction and self.position then
            next_position = self.position + (wanted - self.position) * blend
        else
            -- Orbit follows the same yaw used by movement. Ease only the boom
            -- length after an obstruction, not a second delayed camera heading.
            local distance = self.position and (self.position - target).Magnitude or self.distance
            distance = distance + (self.distance - distance) * blend
            next_position = target - forward * distance
        end
        -- Clamp after smoothing too: a returning free camera cannot ease through a wall.
        local offset = next_position - target
        if offset.Magnitude > 0.01 then
            local hit = self.world.Workspace:Raycast(target, offset, self.params)
            if hit then next_position = target + offset.Unit * math.max(0.05, hit.Distance - 0.35) end
        end
        self.position = next_position
        local look_target = target
        if self.recovery_direction then
            local desired = target - self.position
            if desired.Magnitude > 0.001 then
                desired = desired.Unit
                local direction = self.recovery_direction + (desired - self.recovery_direction) * blend
                if direction.Magnitude > 0.001 then direction = direction.Unit else direction = desired end
                look_target = self.position + direction
                self.recovery_direction = (desired - direction).Magnitude > 0.001 and direction or nil
            end
        end
        camera.CFrame = C.lookAt(self.position, look_target)
        camera.Focus = C.new(target)
    end
end

function Camera:destroy()
    if self.destroyed then return end;self.destroyed=true
    if self.snapshot then self.snapshot:Destroy();self.snapshot=nil end
end
return Camera
