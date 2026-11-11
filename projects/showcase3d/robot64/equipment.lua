-- Robot 64 equipment, ported from zKevin's scripts. No consumable jetpack fuel meter
-- exists in this source: flyspeed/flypitch are its steering/energy state.
local Equipment={};Equipment.__index=Equipment
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function copy(t) local out={};for k,v in pairs(t or {}) do out[k]=v end;return out end
local names={jetpack='hasfly',skateboard='hasboard',flamethrower='hasflame'}
local function child(node,name) return node and node:FindFirstChild(name) end
Equipment.contracts={
    {source='CharacterScript:1905-1968',feature='physical pickup toggles, mutual exclusion, one second debounce and shrink no-op',status='source-derived'},
    {source='CharacterScript:626-647,1034-1124,844-851,8671-8678,2579-2590',feature='board action priorities and trick combinations',status='source-derived'},
    {source='CharacterScript:8710-8714,8950-8969,9009-9014',feature='board/jetpack forces, steering energy and flame recoil',status='source-derived'},
    {source='CharacterScript:7464-7503,8525-8534',feature='trick cadence, landing bank and timed score challenge',status='source-derived',decision='Source wait(.06) scoreboard cadence retained; compatibility physics damping remains dt*30.'},
    {source='CharacterScript:1966-1968,8736-8739',feature='shrink pickup',status='source-no-op',decision='Do not invent an acquisition branch. Explicit shrink state still publishes half-scale pose/rig and speed6 source branch.'},
}
function Equipment.new(content,controller,rbx,options)
    assert(content and content.world and controller and controller.body,'Equipment requires source content and controller')
    options=options or {}
    local self=setmetatable({content=content,controller=controller,rbx=rbx,V=rbx.Vector3,C=rbx.CFrame,
        options=options,time=0,hasfly=false,hasboard=false,hasflame=false,flameon=false,
        flypitch=0,flyspeed=0,clock=0,counter=0,events={},destroyed=false,
        trick={name=nil,points=0,multiplier=0,continuous=false,score=0}},Equipment)
    self.touch_connection=controller.body.Touched:Connect(function(part)
        if self.destroyed or controller.destroyed or not controller.enabled or controller.frozen
            or (options.canmove and not options.canmove()) then return end
        local map=content.active
        if map and map.Name~='MAKE' and part:IsDescendantOf(map) then
            self.time=options.game_time and options.game_time() or self.time;self:touch(part)
        end
    end)
    self:_sync();return self
end
function Equipment:_event(name,data)
    local record={name=name,time=self.time,data=data};self.events[#self.events+1]=record
    if #self.events>100 then table.remove(self.events,1) end
    if self.options.on_event then self.options.on_event(name,data,record) end
end
function Equipment:_sync()
    local s=self.controller.state
    s.hasfly=self.hasfly;s.hasboard=self.hasboard;s.hasflame=self.hasflame
    s.flameon=self.flameon;s.flypitch=self.flypitch;s.flyspeed=self.flyspeed
end
-- Project debug ownership suspends transient actions, never equipment stock.
-- The shared source cadence still advances while the world is simulating.
function Equipment:suspend_actions(active)
    self.debug_suspended=active==true
    if not self.debug_suspended then return end
    self.flameon=false;self.flypitch=0;self.flyspeed=0
    local s=self.controller.state;s.flying=false;s.skate=false
    local t=self.trick;t.name=nil;t.points=0;t.multiplier=0;t.continuous=false;t.gap=false
    self:_sync()
end
function Equipment:equip(kind,enabled)
    local key=names[kind];assert(key,'Unknown source equipment '..tostring(kind))
    self[key]=enabled==nil and not self[key] or enabled==true
    for _,other in pairs(names) do if other~=key then self[other]=false end end
    local s=self.controller.state;s.flying=false;s.skate=false
    self:_sync();return self[key]
end
function Equipment:grant(kind)
    local key=names[kind];assert(key,'Unknown source equipment '..tostring(kind))
    self[key]=true;self:_sync();return true
end
function Equipment:touch(part)
    local s=self.controller.state;local name=part.Name
    if name=='shrink' then return true end -- Public source branch deliberately returns.
    if names[name] and not s.debounce then
        s.debounce=true;self.debounce_until=self.time+1
        local enabled=self:equip(name)
        if self.options.set_health then self.options.set_health(4) end
        self:_event('pickup',{kind=name,enabled=enabled,cloud=8,sound=enabled and 'powerup' or nil})
        return true
    elseif name=='gap' and s.skate then
        local title=child(part,'title');assert(title,'Source gap lacks title')
        self:add_trick(title.Value,500,1,false,true);self:_event('sound',{sound='gap'});return true
    end
    return nil
end
function Equipment:add_trick(name,points,multiplier,continuous,gap)
    local t=self.trick;t.name=name;t.points=t.points+points;t.multiplier=t.multiplier+multiplier
    t.continuous=continuous==true;t.gap=gap==true
end
function Equipment:deposit_score()
    local t=self.trick;t.score=t.score+t.points*t.multiplier
    t.name=nil;t.points=0;t.multiplier=0;t.continuous=false;t.gap=false
    return t.score
end
function Equipment:set_board_race(deadline)
    assert(type(deadline)=='number' or deadline=='','Source board timer must be deadline or suspended empty string')
    self:grant('skateboard');self.timer=deadline;self.deadline_processed=false
end
function Equipment:trick_status()
    local t=self.trick
    return {visible=self.controller.state.skate==true,name=t.name or '',points=t.points,multiplier=t.multiplier,
        continuous=t.continuous,score=t.score,gap=t.gap,time=self.timer=='' and '' or self.timer and math.max(0,math.floor(self.timer-self.time)) or nil}
end
function Equipment:_contacts()
    local c,s=self.controller,self.controller.state
    if (s.ground and not s.jumping) or s.wall then s.flying=false end
    if s.wall and s.wall~=self.last_wall and s.skate then self:add_trick('Wallride',100,1,true) end
    if s.rope and not self.last_rope then self:add_trick('50-50 Grind',50,1,true) end
    self.last_wall,self.last_rope=s.wall,s.rope
    -- landed belongs to the controller clock, which also advances scripted
    -- poses. Session gameplay time excludes loading and can have a different
    -- epoch; source gtick - timeland compares values from one clock.
    if s.ground and not s.jumping and c.time-(s.landed or c.time)>.5 then self:deposit_score() end
end
function Equipment:update(dt,actions,camera,game_time)
    if self.destroyed then return end
    self.time=game_time or self.time+dt;self.camera=camera or self.content.world.Workspace.CurrentCamera.CFrame
    self.dir=self.V.new((actions or {}).x or 0,0,(actions or {}).z or 0);if self.dir.Magnitude>1 then self.dir=self.dir.Unit end
    local s=self.controller.state
    if self.debounce_until and self.time>=self.debounce_until then s.debounce=nil;self.debounce_until=nil end
    self:_sync();self:_contacts()
end
function Equipment:advance_cadence(dt,game_time)
    if self.destroyed then return end
    self.time=game_time or self.time+dt
    local s=self.controller.state
    self.clock=self.clock+dt
    while self.clock+1e-9>=.06 do
        self.clock=self.clock-.06;local t=self.trick
        if self.debug_suspended then
            -- No score/task mutation while assisted flight owns the actor.
        elseif s.skate and not (self.options.gotice and self.options.gotice()) then
            if t.continuous then t.points=t.points+1 end
        else
            t.name=nil;t.points=0;t.multiplier=0;t.continuous=false;t.gap=false
            if not self.timer_visible then t.score=0 end
        end
        self:_event('cadence',{counter=self.counter,flying=s.flying,bees=self.options.bees and self.options.bees() or false})
        self.counter=self.counter+1
        self.timer_visible=self.timer=='' or type(self.timer)=='number' and self.timer>self.time
        if not self.debug_suspended and type(self.timer)=='number' and self.time>self.timer and self.time<self.timer+1
            and self.content.active and self.content.active.Name=='knoddy' then
            self.deadline_processed=true;local score=self:deposit_score()
            if score>=9000 then
                local coolbro=child(self.content.active,'Coolbro');local task=child(coolbro,'task')
                if task and task.Value==1 then
                    task.Value=2
                    if self.options.on_reward then self.options.on_reward('Scoring Radical Points',10,self.V.new(-214,82,56)) end
                end
            end
        end
    end
end
function Equipment:actions(c,dt,actions,dir)
    local input=copy(actions);local s=c.state
    self:_sync();self:_contacts()
    local map=self.content.active
    if not map or map.Name=='Boss' or map.Name=='MAKE' or c.onejump or not c.input_enabled
        or (self.options.canmove and not self.options.canmove()) then return input end
    -- Source crouch cancels the board before jump/dive edges are dispatched.
    if input.crouch_pressed then
        s.skate=false;s.dancing=false
        if s.flying then
            s.crouch=true;s.flying=false;s.sliding=false;s.pound=true;s.rolling=true;s.double=true;s.longjump=true
            c.animation.botand=2*math.pi
            if not c.body.Anchored then c.body.Anchored=true;s.owned_anchor=true end
            s.pound_release=c.time+.4;input.crouch_pressed=false
        end
    end
    if input.jump and s.skate and not (s.debounce or s.pound or s.attack or s.ledge or s.wall) then
        input.jump=false
        if s.ground and not s.jumping and s.ground.Name~='Slide' then
            self:add_trick('Ollie',5,0,false)
            c:cvt(c:_velocity(math.max(0,c.animation.botand*40)+40));c:_lock(.3)
            self:_event('sound',{sound='jump'})
        elseif s.rope then input.jump=true end -- Environment owns source detach geometry.
    end
    if input.dive then
        s.dancing=false
        if self.hasboard and not (s.crouch or s.rope or s.pole or s.swimming or s.pound) then
            input.dive=false
            if not s.skate then s.longjump=false;s.skate=true;c.animation.potand=2*math.pi
            elseif not s.ground and c.animation.boarderp.Z>-.2 then
                self:add_trick('Kickflip',100,1,false)
                c.animation.boarderp=c.animation.boarderp+self.V.new(0,0,-6.2831854820251465)
            end
        elseif self.hasflame then input.dive=false;self.flameon=not self.flameon;self:_sync()
        elseif not (s.swimming or s.ledge or s.wall) then
            if not (s.sliding or s.pole or s.rope or s.attack or s.pound) and self.hasfly and not s.double then
                input.dive=false;s.double=true;s.flying=true;s.sliding=true;s.longjump=false;s.rolling=false;s.pound=false
                self.flypitch=.5;self.flyspeed=2;self:_sync()
                local grounded=s.ground~=nil;c.body.Anchored=false;s.owned_anchor=nil
                c:cvt(c.facing*50+self.V.new(0,grounded and 40 or 20,0))
                c.animation.potand=2*math.pi*c.animation.fallvr;c:_lock(.3)
                self:_event('sound',{sound='dive'})
            elseif s.flying and not s.debounce and not (s.ground and not s.jumping and s.ground.Name~='Slide') then
                input.dive=false;s.debounce=true;self.debounce_until=self.time+.5
                c.animation.potand=c.animation.potand+2*math.pi*c.animation.fallvr
            end
        end
    end
    if input.twirl and not (s.jumping or s.attack or s.pole or s.rope or s.wall or s.ledge or s.pound)
        and not (s.ground and s.ground.Name=='Slide') then
        s.flying=false;s.dancing=false
        if s.skate then self:add_trick('The Iron Man',50,1,true) end
    end
    if (input.jump or input.dive) and s.wall and not s.jumping then self:add_trick('Wall jump',100,1,false) end
    return input
end
function Equipment:steer(c,dt,dir)
    local s=c.state
    if s.skate and not s.sliding then
        if dir.Magnitude>.2 and s.ground then c:_turn(dir,dt*3) end
        return true
    end
    return false
end
function Equipment:force(c,dt,dir,held_crouch,force,damping)
    local s,V,C=c.state,self.V,self.C;local speed
    s.equipment_pose_flameon=self.flameon
    if not (s.swimming or s.ledge) then
        if s.skate then
            local hit=not s.jumping and c.probe_hit or nil
            local point=c.probe_position or (hit and hit.Position)
            local gravity,mass=c.workspace.Gravity,c.body:GetMass()
            force=(hit and c.facing*170 or dir*50)+(hit and V.new(0,(point.Y+2-c:_mps().Y)*300+gravity*mass/2,0) or V.new())
            damping=hit and V.new(.8999999761581421,.20000000298023224,.8999999761581421) or V.new(.9800000190734863,1,.9800000190734863)
            s.sliding=false;s.swimming=false;speed=0
        elseif s.flying then
            local camera=self.camera or c.workspace.CurrentCamera.CFrame
            s.equipment_pose_facing=c.facing;s.equipment_pose_pitch=self.flypitch
            local low=self.flyspeed<1 and 1-self.flyspeed or 0
            self.flypitch=clamp(self.flypitch-self.flypitch*dt/2+dir:Dot(camera.LookVector)/(1+low*3)*dt*1.3-(self.flyspeed<1 and dt or 0),-1,1)
            local tilted=C.lookAt(V.new(),c.facing)*C.Angles(self.flypitch,0,0)
            self.flyspeed=math.max(0,self.flyspeed-self.flypitch*dt)
            force=tilted.LookVector*50*(self.flyspeed>3 and self.flyspeed/3+2 or self.flyspeed)+V.new(0,c.workspace.Gravity*c.body:GetMass(),0)
            damping=V.new(.949999988079071,.949999988079071,.949999988079071)
            c.facing=(C.lookAt(V.new(),c.facing)*C.Angles(0,-dir:Dot(camera.RightVector)*dt*3.5,0)).LookVector
            self:_sync()
        end
    end
    if self.flameon then
        local frame=self.flame_frame
        if frame then force=force-frame.LookVector*V.new(1,.800000011920929,1)*80 end
        if not self.hasflame then self.flameon=false;self:_sync() end
    end
    -- Explicit source shrink state is supported; the source pickup never sets it.
    if s.shrink and not (s.swimming or s.ledge or s.skate or s.flying or s.pole or s.wall or s.rope) then
        local support=s.ground and V.new(0,(c.ground_hit.Position.Y+(s.crouch and not s.sliding and 1 or 2)-c:_mps().Y)*300+c.workspace.Gravity*c.body:GetMass()/2,0)
            or V.new(0,s.pound and -30 or 0,0)
        force=(force-support)*3+support
    end
    return force,damping,speed
end
function Equipment:reset_player()
    local s=self.controller.state;s.flying=false;s.skate=false
    self.debounce_until=nil;self.last_wall=nil;self.last_rope=nil;self:_sync()
end
function Equipment:damage()
    if self.hasfly then self.hasfly=false;self.controller.state.flying=false;self:_event('lost-jetpack',{cloud=8}) end
    self:_sync()
end
function Equipment:activate(map,options)
    self:retire();self.map=map;options=options or {}
    for _,part in ipairs(map:GetDescendants()) do
        if part:IsA('BasePart') and (names[part.Name] or part.Name=='shrink' or part.Name=='gap') then self.content.triggers[part]=true end
    end
    if options.tofly then
        self.hasfly=true;local s=self.controller.state;s.flying=true;s.sliding=true;s.double=true;s.attack=false;s.pound=false;s.rolling=false;s.longjump=false
    end
    self:_sync()
end
function Equipment:retire()
    self.hasfly=false;self.hasboard=false;self.hasflame=false
    -- Source TeleMap clears ownership, but flameon/the last aim frame survive
    -- until the next force branch applies recoil once and then clears flameon.
    self.map=nil
    self:reset_player()
end
function Equipment:reset_all()
    self:retire();self.flypitch=0;self.flyspeed=0;self.flameon=false;self.flame_frame=nil;self.timer=nil;self.deadline_processed=false
    self.clock=0;self.counter=0;self.timer_visible=false
    self.trick={name=nil,points=0,multiplier=0,continuous=false,score=0};self:_sync()
end
function Equipment:destroy()
    if self.destroyed then return end
    self.destroyed=true;if self.touch_connection then self.touch_connection:Disconnect() end;self:retire()
end
return Equipment
