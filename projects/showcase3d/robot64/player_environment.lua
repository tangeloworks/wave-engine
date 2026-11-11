-- Public water/pole/rope branches share the campaign body, force and gyro.
-- The host consumes actions once, calls step first, and invokes the classic
-- controller only when this returns false. No second physics/input owner.
local SourceRay=require('projects/showcase3d/robot64/source_ray')
local Environment={};Environment.__index=Environment
local function child(node,name) return node and node:FindFirstChild(name) end
local function need(node,name) return assert(child(node,name),'Environment dependency missing: '..name) end
local function alive(node) return node and node.Parent~=nil end
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function copy(t) local out={};for k,v in pairs(t or {}) do out[k]=v end;return out end
Environment.contracts={
    {source='CharacterScriptDecomp.txt:8086-8159,8713-8722,8928-8930',feature='water transitions, current and swim steering/forces',status='source-derived'},
    {source='CharacterScriptDecomp.txt:1884-1903,650-661,8972-8987',feature='pole contact, climb, orbit, octant snap and jump',status='source-derived'},
    {source='CharacterScriptDecomp.txt:1210-1234,1862-1883,676-685,8334-8357,8994-8996',feature='rope contact, sag, projection, steering, detach and jump',status='source-derived'},
    {source='CharacterScriptDecomp.txt:8125-8134,7622',feature='wind velocity, honey damping, infinite-water inversion',status='source-derived'},
    {source='CharacterScriptDecomp.txt:7620-7622; ball_controller.lua:damping_hz',feature='wait-loop damping cadence',status='unmeasured',decision='Retain the existing classic controller interpretation: source factors exponentiated by dt*30. Historical wait cadence has no matching measured trace.'},
    {source='CharacterScriptDecomp.txt:5401-5444,8740-8764',feature='water/pole/rope joint pose and state blends',status='source-derived',implementation='character_animation.lua'},
    {source='CharacterScriptDecomp.txt:8940,8889-8902',feature='splash state and movement audio presentation',status='source-derived',implementation='source_presentation.lua',reason='The live ParticleEmitter renderer remains explicitly unresolved.'},
    {source='CharacterScriptDecomp.txt:1905-1968,8950-8969,9009-9014',feature='equipment action and force interoperation',status='source-derived',implementation='equipment.lua; optional actions and force_modifier hooks retain one damping owner'},
}
function Environment.new(content,controller,rbx,options)
    assert(content and content.world and controller and controller.body and controller.force,'Environment needs active campaign content/controller')
    options=options or {}
    local self=setmetatable({content=content,controller=controller,rbx=rbx,V=rbx.Vector3,CF=rbx.CFrame,
        options=options,deadzone=options.deadzone or .3,time=0,water_tick=-10,rope_tick=0,
        destroyed=false,events={},unresolved={},reported={},initialized_ropes=setmetatable({},{__mode='k'})},Environment)
    -- Poles/Mid use the original physical Touched contract. Water/wind/honey
    -- use the source region query; expanding pole acquisition to that box would
    -- change its contact radius and corner behavior.
    self.touch_connection=controller.body.Touched:Connect(function(part)
        if self.destroyed or controller.destroyed or not controller.enabled or controller.frozen
            or (options.canmove and not options.canmove()) then return end
        local map=content.active
        if map and map.Name~='MAKE' and part:IsDescendantOf(map) then
            self.time=options.game_time and options.game_time() or self.time;self:_map(map);self:touch(part)
        end
    end)
    return self
end
function Environment:_map(map)
    if self.map~=map then self:retire();self.map=map;self:initialize_ropes(map,self.time) end
end
function Environment:_straight_rope(rope)
    local a,b,mid=need(rope,'PartA'),need(rope,'PartB'),need(rope,'Mid')
    mid.Size=self.V.new(2,2,(a.Position-b.Position).Magnitude)
    mid.CFrame=self.CF.lookAt((a.Position+b.Position)/2,b.Position)
end
function Environment:initialize_ropes(root,game_time)
    self.time=game_time or self.time
    local nodes={root};for _,node in ipairs(root:GetDescendants()) do nodes[#nodes+1]=node end
    for _,node in ipairs(nodes) do
        if node.Name=='ropemod' and not self.initialized_ropes[node] then
            self:_straight_rope(node);self.initialized_ropes[node]=true
            self.controller.state.rope=nil;self:_debounce(.3)
        end
    end
end
function Environment:activate(map,game_time)
    self.time=game_time or self.time;self:_map(map)
end
function Environment:_event(name,data)
    data=data or {};data.name=name;data.time=self.time
    self.events[#self.events+1]=data
    if #self.events>100 then table.remove(self.events,1) end
    if self.options.on_event then self.options.on_event(name,data) end
end
function Environment:_report(feature)
    if self.reported[feature] then return end
    self.reported[feature]=true;self.unresolved[#self.unresolved+1]={feature=feature,status='unimplemented'}
end
function Environment:_horizontal(v,y) return self.V.new(v.X,y or 0,v.Z) end
function Environment:_mps() return self.controller.body.Position-self.V.new(0,1,0) end
function Environment:_clear_support()
    local c,s=self.controller,self.controller.state
    s.ground=nil;s.wall=nil;s.ledge=nil;s.skid=nil;c.ground_hit=nil;c.support=nil;c.pheight=nil
end
function Environment:_release_pound()
    local c,s=self.controller,self.controller.state
    if s.owned_anchor then c.body.Anchored=false;s.owned_anchor=nil end
    s.pound_release=nil;s.pound=false
end
function Environment:_debounce(seconds)
    self.controller.state.debounce=true;self.owns_debounce=true;self.debounce_until=self.time+seconds
end
function Environment:_detach_rope()
    local s=self.controller.state;local rope=s.rope
    if not rope then return end
    local a,b,mid=child(rope,'PartA'),child(rope,'PartB'),child(rope,'Mid')
    if alive(rope) and a and b and mid then
        self:_straight_rope(rope)
    end
    s.rope=nil;self:_debounce(.3);self:_event('rope-detach',{rope=rope})
end
function Environment:touch(part)
    if self.destroyed or not alive(part) then return false end
    local c,s=self.controller,self.controller.state
    if part.Name=='Mid' and not s.debounce and not s.swimming and not s.pole then
        local rope=part.Parent
        -- Validate all required identities before taking ownership of the body.
        need(rope,'PartA');need(rope,'PartB');need(rope,'Mid')
        if s.rope==rope then return true end
        if s.rope then
            self:_detach_rope()
            local point=self.CF.lookAt(self:_horizontal(c.body.Position),self:_horizontal(part.Position))
            c.body.CFrame=c.body.CFrame+point.LookVector*2
            c.body.Velocity=point.LookVector*self:_horizontal(c.body.Velocity).Magnitude;c.facing=point.LookVector
        else self:_event('rope-grind',{trick='50-50 Grind',points=50,multiplier=1}) end
        s.rope=rope;self.rope_tick=self.time+(c.body.Velocity.Y>0 and -3 or c.body.Velocity.Y>-30 and -1.4 or 0)
        s.flying=false;s.sliding=false;s.rolling=false;s.longjump=false;s.attack=false
        self:_release_pound();self:_clear_support();self:_event('rope-attach',{rope=rope})
        return true
    elseif part.Name=='pole' and not s.pole and not s.debounce and not s.swimming and not s.rope and not s.wall
        and not (self.options.holding and self.options.holding()) then
        s.pole=part
        if (self:_horizontal(c.body.Position)-self:_horizontal(part.Position)).Magnitude>.1 then
            c.facing=self.CF.lookAt(self:_horizontal(c.body.Position),self:_horizontal(part.Position)).LookVector
        end
        local finished=child(part,'finished');if finished then finished.Value=true end
        s.sliding=false;s.longjump=false;s.flying=false;s.skate=false;s.attack=false;s.rolling=false
        self:_clear_support();self:_event('pole-attach',{pole=part});return true
    elseif part.Name=='shrink' then return true -- public touched branch is intentionally a no-op
    elseif part.Name=='jetpack' or part.Name=='skateboard' or part.Name=='flamethrower' then
        return false -- Equipment owns these source pickup contacts.
    end
    return false
end
function Environment:_water(next_water)
    local c,s=self.controller,self.controller.state
    self.water=next_water
    if not s.swimming and next_water then
        s.swimming=true;self.water_tick=self.time
        s.sliding=false;s.longjump=false;s.flying=false;s.skate=false;s.rolling=false
        self:_release_pound();self:_clear_support();self:_event('water-enter',{water=next_water})
        self:_report('swimming splash particle rendering')
    elseif s.swimming and not next_water then
        s.swimming=false;self.water_tick=self.time;s.sliding=true
        local v=c.body.Velocity;if v.Y>0 then c.body.Velocity=self:_horizontal(v,v.Y*1.5) end
        self:_event('water-exit')
    end
end
function Environment:_probe(dt)
    local c=self.controller;local map=self.content.active
    local p=self:_mps();local V=self.V
    local multiplier=self.options.region_multiplier and self.options.region_multiplier() or 1
    local held=self.options.holding and self.options.holding() or c.state.holding
    local lower=V.new(1.6,held and held.Name=='crayon' and 2 or 0,1.6)*multiplier
    local upper=V.new(1.600000023841858,2,1.600000023841858)*multiplier
    local hits=self.content.world.Workspace:FindPartsInRegion3WithIgnoreList(
        self.rbx.Region3.new(p-lower,p+upper),c.ignore or {c.body},math.huge)
    self.source_regions=require('projects/showcase3d/robot64/source_regions').capture(hits,map,p)
    local water;self.slowed=false
    for _,part in ipairs(hits) do
        if alive(part) and part:IsDescendantOf(map) then
            if part.Name=='water' and p.Y<part.Position.Y+part.Size.Y/2 then water=part
            elseif part.Name=='wind' then c.body.Velocity=c.body.Velocity+need(part,'force').Value*dt*150
            elseif part.Name=='honey' then self.slowed=true end
        end
    end
    if self.infwater then water=not water and self.content.world.Workspace or nil end
    self:_water(water)
end
function Environment:_rope_geometry(dir)
    local c,s,V,CF=self.controller,self.controller.state,self.V,self.CF
    local rope=s.rope;local a,b,mid=need(rope,'PartA'),need(rope,'PartB'),need(rope,'Mid')
    local mps=self:_mps();local direction=(b.Position-a.Position).Unit
    local ray=SourceRay.new(a.Position,direction)
    local ends=math.min(1,math.max(0,1-(a.Position-mps).Magnitude/10)+math.max(0,1-(b.Position-mps).Magnitude/10))
    local tense=child(rope,'tense')~=nil
    local factor=(tense and 0 or 1)*(s.skate and 0 or 1)
    local rope_height=math.sin((self.time-self.rope_tick-.2)*8)*5*(1-ends)*math.max(0,1-(self.time-self.rope_tick)/2)*factor*(tense and 0 or 1)
    local sag=(b.Position-a.Position).Magnitude/10*(1-ends)*factor
    mid.CFrame=CF.new(ray:ClosestPoint(mps+V.new(0,sag-1.7-rope_height)))+V.new(0,-sag+rope_height)
    local delta=mid.Position-(mps-V.new(0,1.7000000476837158,0))
    c.body.CFrame=c.body.CFrame+delta;mps=mps+delta
    dir=self:_horizontal(direction*dir:Dot(direction))
    if s.skate then
        local sign=c.facing:Dot(direction)>=0 and 1 or -1
        dir=self:_horizontal(direction*sign);c.facing=CF.lookAt(V.new(),dir).LookVector
    end
    if CF.lookAt(b.Position,a.Position).LookVector:Dot(CF.lookAt(b.Position,mps).LookVector)<0 then
        c.body.CFrame=c.body.CFrame-c.body.Position+b.Position+V.new(0,2.200000047683716,0)
    end
    self.rope_height=rope_height;return dir
end
function Environment:_jump(input)
    local c,s,V,CF=self.controller,self.controller.state,self.V,self.CF
    if not input.jump or s.debounce then return false end
    if s.pole then
        c:cvt(V.new(0,30,0)-c.facing*30)
        c.facing=(CF.lookAt(V.new(),c.facing)*CF.Angles(0,math.pi,0)).LookVector
        s.pole=nil;s.double=false;self:_debounce(.2);self:_event('pole-jump',{sound='jump2'});return true
    elseif s.rope then
        c:cvt(self:_horizontal(c.body.Velocity,50));s.double=false
        self:_detach_rope();c:_lock(.3);self:_event('rope-jump',{});return true
    end
    return false
end
function Environment:_forces(dt,dir,input,camera)
    local c,s,V,CF=self.controller,self.controller.state,self.V,self.CF
    local gravity,mass=self.content.world.Workspace.Gravity,c.body:GetMass()
    local force,damping,speed
    if s.swimming then
        local up=input.jump_axis or (input.jump_held and 1 or 0)
        -- Source todive is LeftShift/ButtonR2 (tocrouch), not E/ButtonX (dive).
        local down=input.dive_axis or (input.crouch and 1 or 0)
        assert(finite(up) and finite(down),'Swim action axes must be finite')
        if dir.Magnitude>.2 then c.facing=CF.lookAt(V.new(),c.facing):Lerp(CF.lookAt(V.new(),dir),dt*3).LookVector end
        s.attack=false;s.pole=nil
        local current=child(self.water,'current')
        force=dir*120+V.new(0,gravity*mass+(up-down)*120)+(current and current.Value*10 or V.new())
        damping=V.new(.8999999761581421,.8999999761581421,.8999999761581421)
        speed=math.min(1,dir.Magnitude+math.abs(up-down))*1.4
    elseif s.pole then
        local pole=s.pole;assert(pole.Size.X>0,'Pole diameter must be positive')
        local climb=dir:Dot(camera.LookVector)
        if c.body.Position.Y>pole.Position.Y+pole.Size.Y/2 then climb=math.min(0,climb)
        elseif c.body.Position.Y<pole.Position.Y-pole.Size.Y/2+2 then climb=math.max(0,climb) end
        s.rolling=false;if math.abs(climb)<.4 then climb=0 end
        force=self:_horizontal(pole.Position-self:_mps()-c.facing*(pole.Size.X/2+1))*500+V.new(0,gravity*mass+climb*600)
        damping=V.new(.10000000149011612,.10000000149011612,.10000000149011612);speed=dir.Magnitude
        if dir.Magnitude>self.deadzone then
            local yaw=math.abs(climb)<.4 and dir:Dot(camera.RightVector)*dt*4/pole.Size.X^.5 or 0
            c.facing=(CF.lookAt(V.new(),c.facing)*CF.Angles(0,yaw,0)).LookVector
        elseif pole.Size.X<8 then
            local octant=math.floor(4*math.atan2(-c.facing.X,-c.facing.Z)/math.pi+.5)%8
            c.facing=CF.Angles(0,octant*math.pi/4,0).LookVector
        end
    elseif s.rope then
        if dir.Magnitude>.2 then
            if s.crouch then c.facing=CF.lookAt(V.new(),c.facing):Lerp(CF.lookAt(V.new(),dir),dt*5).LookVector
            else c.facing=CF.lookAt(V.new(),dir).LookVector end
        end
        force=dir*600+V.new(0,gravity*mass)
        damping=V.new(.10000000149011612,.10000000149011612,.10000000149011612);speed=dir.Magnitude*.8
    end
    if self.options.force_modifier then
        local changed,changed_damping,changed_speed=self.options.force_modifier(c,dt,dir,input.crouch==true,force,damping)
        force=changed or force;damping=changed_damping or damping;speed=changed_speed or speed
    end
    local ticks=dt*(c.damping_hz or 30);local honey=self.slowed and .7^ticks or 1
    local velocity=c.body.Velocity;c.force.Force=force
    c.body.Velocity=V.new(velocity.X*damping.X^ticks,velocity.Y*damping.Y^ticks,velocity.Z*damping.Z^ticks)*honey
    c.visual_velocity=velocity;c.visual_speed=speed;c.walk=c.walk+(speed-c.walk)*math.min(1,dt*4)
    self.force,self.damping,self.speed=force,damping,speed
end
function Environment:step(dt,actions,camera,game_time)
    local input=copy(actions)
    if self.destroyed then return false,input end
    assert(finite(dt) and dt>=0 and finite(game_time),'Environment requires finite nonnegative dt and gameplay time')
    local c=self.controller;local map=self.content.active
    if not map or map.Name=='MAKE' or c.destroyed or not c.enabled or c.frozen then return false,input end
    self.time=game_time
    self:_map(map)
    if self.owns_debounce and game_time>=(self.debounce_until or math.huge) then c.state.debounce=nil;self.owns_debounce=nil;self.debounce_until=nil end
    self:_probe(dt)
    local s=c.state
    if s.pole and not alive(s.pole) then s.pole=nil end
    if s.rope and not alive(s.rope) then s.rope=nil end
    if self.options.actions and (s.swimming or s.pole or s.rope) then
        local dir=self.V.new(input.x or 0,0,input.z or 0);if dir.Magnitude>1 then dir=dir.Unit end
        input=self.options.actions(c,dt,input,dir) or input
    end
    if self:_jump(input) then input.jump=false end
    if not (s.swimming or s.pole or s.rope) then return false,input end
    if input.crouch_pressed then s.crouch=true;s.skate=false end
    if s.crouch and not input.crouch and not c:_ray(self:_mps(),self.V.new(0,4,0)) then s.crouch=false end
    self:_clear_support();input.jump=false;input.dive=false;input.twirl=false;input.crouch_pressed=false
    local dir=self.V.new(input.x or 0,0,input.z or 0);if dir.Magnitude>1 then dir=dir.Unit end
    if s.rope then dir=self:_rope_geometry(dir) end
    c.time=c.time+dt;c:_advance()
    self:_forces(dt,dir,input,camera or self.content.world.Workspace.CurrentCamera.CFrame)
    c:_publish_gyro()
    -- The maintained animation clock includes the source's water/pole/rope
    -- state blends and eight joint chains; emitter/audio is separate.
    c.animation:advance(dt,c,dir,input.crouch==true)
    return true,input
end
function Environment:after_classic(dt)
    if self.destroyed or not self.slowed then return end
    local c=self.controller;c.body.Velocity=c.body.Velocity*.7^(dt*(c.damping_hz or 30))
end
function Environment:reset_player()
    if self.controller then
        local s=self.controller.state
        if s.rope then self:_detach_rope() end
        s.pole=nil;s.swimming=false;s.rope=nil
        if self.owns_debounce then s.debounce=nil end
    end
    self.water=nil;self.slowed=false;self.owns_debounce=nil;self.debounce_until=nil
end
function Environment:retire()
    self:reset_player();self.map=nil;self.infwater=nil;self.source_regions=nil
end
function Environment:destroy()
    if self.destroyed then return end
    if self.touch_connection then self.touch_connection:Disconnect();self.touch_connection=nil end
    self:retire();self.destroyed=true;self.content=nil;self.controller=nil
end
return Environment
