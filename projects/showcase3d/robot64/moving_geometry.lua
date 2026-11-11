-- Public controller moving-folder branch, translated without executing Source.
-- Source poses are authored values; Content:_index performs its start/endo
-- relocation once when activating a clone. This system never mutates templates.
local Moving={};Moving.__index=Moving
local SourceRay=require('projects/showcase3d/robot64/source_ray')
local Source=require('projects/showcase3d/robot64/source')
local function child(node,name) return node and node:FindFirstChild(name) end
local function need(node,name) return assert(child(node,name),'Moving geometry dependency missing: '..name) end
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
Moving.contracts={
    {source='CharacterScriptDecomp.txt:7716-7750',feature='rotating, cog, tipping, rider displacement and facing',status='source-derived'},
    {source='CharacterScriptDecomp.txt:7752-7760,7786-7817',feature='endpoint interpolation, swing, orbit and ledge displacement',status='source-derived'},
    {source='CharacterScriptDecomp.txt:7761-7783',feature='Knoddy endpoint decisions and timed projectile attack',status='unimplemented',reason='Boss attack state, coroutine timing, and projectile ownership require the boss system.'},
    {source='ball_controller.lua:_follow_support',feature='avoid applying platform displacement twice',status='integration-repair',decision='Refresh the controller support world point after source carry; retain its local contact point.'},
    {source='CharacterScriptDecomp.txt:7719',feature='cog real-time phase',status='source-derived',decision='Use an independent monotonic real-time clock; content.wall_time may inject the host clock. Swing and orbit use the supplied gameplay time.'},
    {source='CharacterScriptDecomp.txt:7733',feature='tipping creak audio',status='source-derived',decision='The facade has no Sound:Play method; route its authored SoundId, Volume and PlaybackSpeed through the existing local Assets service.'},
    {source='CharacterScriptDecomp.txt:7725; research/ray-contract.json',feature='nonunit tipping Ray distance',status='source-derived',decision='Preserve legacy Roblox unnormalized projection, verified against supplied RbxRay.h and LuaAtomicClasses.cpp; leave finite Workspace raycasts unchanged.'},
}
function Moving.new(content,controller,rbx,options)
    assert(content and content.world,'Moving geometry needs active content')
    assert(controller and controller.body and controller.state,'Moving geometry needs the campaign controller')
    local clock=content.wall_time or function() return love.timer.getTime() end
    return setmetatable({content=content,controller=controller,rbx=rbx,V=rbx.Vector3,CF=rbx.CFrame,
        wall_time=clock,options=options or {},destroyed=false,unresolved={},unresolved_by_part=setmetatable({},{__mode='k'}),
        sound_names=setmetatable({},{__mode='k'}),next_sound=0},Moving)
end
function Moving:_retire_sounds()
    if self.content.assets then for _,name in pairs(self.sound_names) do self.content.assets:stop(name) end end
    self.sound_names=setmetatable({},{__mode='k'})
end
function Moving:_drop_folder()
    for _,connection in ipairs(self.folder_connections or{})do connection:Disconnect()end
    self.folder_connections={};self.folder_parts=nil;self.folder=nil
end
function Moving:_parts(folder)
    if self.folder~=folder then
        self:_drop_folder();self.folder=folder
        local lifetime=Source.lifetime(folder)
        local function refresh()
            if not Source.live(folder,lifetime)then self:_drop_folder();return end
            self.folder_parts=folder:GetChildren()
            for _,part in ipairs(self.folder_parts)do Source.lifetime(part)end
        end
        refresh()
        for _,name in ipairs({'ChildAdded','ChildRemoved'})do
            local signal=folder[name]
            if signal and signal.Connect then self.folder_connections[#self.folder_connections+1]=signal:Connect(refresh)end
        end
        self.folder_observed=#self.folder_connections==2
    elseif not self.folder_observed then
        self.folder_parts=folder:GetChildren()
    end
    return self.folder_parts
end
function Moving:_play_sound(sound)
    local assets=assert(self.content.assets,'Moving audio requires the local asset service')
    local name=self.sound_names[sound]
    if not name then self.next_sound=self.next_sound+1;name='RobotMoving:'..self.next_sound;self.sound_names[sound]=name end
    return assets:play(name,sound.SoundId,sound.Volume,sound.Looped,sound.PlaybackSpeed or sound.Pitch or 1)
end
function Moving:_unresolved(part,feature)
    local seen=self.unresolved_by_part[part]
    if not seen then seen={};self.unresolved_by_part[part]=seen end
    if seen[feature] then return end
    seen[feature]=true
    self.unresolved[#self.unresolved+1]={part=part,feature=feature,source='CharacterScriptDecomp.txt:7761-7783',status='unimplemented'}
end
function Moving:_support(part)
    local c=self.controller;local record=c.support
    if record and record.part==part then
        record.world_point=part.CFrame:PointToWorldSpace(record.local_point)
    end
end
function Moving:_translate(part,target)
    local c,s=self.controller,self.controller.state
    local delta=target-part.Position
    if s.ground==part or s.ledge==part then
        if s.ledge_point then s.ledge_point=s.ledge_point+delta end
        c.body.CFrame=c.body.CFrame+delta
    end
    part.CFrame=part.CFrame-part.Position+target
    if s.ground==part or s.ledge==part then self:_support(part) end
end
function Moving:_rotate(part,dt,real_time)
    local c,V,CF=self.controller,self.V,self.CF
    local rotate=need(part,'rotate')
    if part.Name=='cog' then
        rotate.Value=V.new(0,math.sin(real_time*math.pi*4*1.0833333333333333)>0 and 30 or 0,0)
    elseif part.Name=='tipping' then
        local speed=need(part,'speed')
        if c.state.ground==part then
            local half=part.Size.X/2
            local offset=part.CFrame.UpVector*part.Size.Y/2
            local ray=SourceRay.new(part.Position-part.CFrame.RightVector*half+offset,part.CFrame.RightVector*half+offset)
            local torque=ray:Distance(c.body.Position)/-20000+1
            speed.Value=speed.Value+torque*dt*10
        else
            speed.Value=speed.Value+(speed.Value*.1-speed.Value)*dt+part.CFrame.RightVector.Y*-10*dt
        end
        local sound=need(part,'Sound');local timer=need(sound,'ti')
        timer.Value=timer.Value+math.min(8,math.abs(speed.Value))*dt
        if timer.Value>.5 then self:_play_sound(sound);timer.Value=0 end
        rotate.Value=V.new(0,0,speed.Value)
    end
    local radians=rotate.Value*dt/20
    local turn=CF.Angles(radians.X,radians.Y,radians.Z)
    part.CFrame=part.CFrame*turn
    if c.state.ground==part then
        local basis=part.CFrame-part.Position
        local world_turn=basis*turn*basis:Inverse()
        local touch=c.touchcam and child(c.touchcam,'Pos')
        local mask=touch and touch.Value or V.new(1,1,1)
        local relative=CF.new((c.body.Position-part.Position)*mask)
        local target=(CF.new(part.Position)*world_turn*relative).Position
        local look=(world_turn*relative).LookVector
        local yaw=math.atan2(-look.X,-look.Z)
        -- Desired point/facing and physical body orientation are distinct.
        c.facing=(CF.lookAt(V.new(),c.facing)*CF.Angles(0,yaw,0)).LookVector
        local previous=c.body.Position
        c.body.CFrame=c.body.CFrame*CF.Angles(0,yaw,0)-previous+target
        self:_support(part)
    end
end
function Moving:_endpoint(part,dt)
    local lerp=need(part,'lerp')
    local wait,back,speed=need(lerp,'wait'),need(lerp,'back'),need(lerp,'speed')
    if wait.Value>0 then wait.Value=wait.Value-dt;return end
    assert(finite(speed.Value) and speed.Value>0,'Source moving interpolation speed must be positive')
    lerp.Value=lerp.Value+(back.Value and dt or -dt)/speed.Value
    if lerp.Value>=1 or lerp.Value<=0 then
        lerp.Value=math.min(1,math.max(0,lerp.Value));wait.Value=2;back.Value=not back.Value
        if child(part,'knoddy') and not (self.options.on_knoddy_endpoint
            and self.options.on_knoddy_endpoint(part,back.Value)) then self:_unresolved(part,'Knoddy endpoint decisions and projectile attack') end
        if not Source.live(part,Source.lifetime(part))then return end
    end
    self:_translate(part,need(part,'start').Value:Lerp(need(part,'endo').Value,lerp.Value))
end
function Moving:step(dt,game_time)
    if self.destroyed then return false end
    assert(finite(dt) and dt>=0,'Moving geometry requires a finite nonnegative dt')
    assert(finite(game_time),'Moving geometry requires finite gameplay time')
    local map=self.content.active
    if self.map~=map then self:_retire_sounds();self:_drop_folder();self.map=map end
    local folder=child(map,'moving')
    if not folder or map.Name=='MAKE' then self:_drop_folder();return true end
    local real_time=self.wall_time();assert(finite(real_time),'Moving geometry real-time clock is invalid')
    for _,part in ipairs(self:_parts(folder)) do
        if Source.live(part,Source.lifetime(part))and part.Parent==folder and part:IsA('BasePart') then
            if child(part,'rotate') then self:_rotate(part,dt,real_time) end
            if child(part,'endo') then self:_endpoint(part,dt) end
            if part.Name=='swing' then
                local target=need(part,'start').Value+part.CFrame.LookVector*math.cos(game_time*math.pi/4)*40
                    +self.V.new(0,math.cos(game_time*math.pi/2)*20+20,0)
                if child(part,'circle') then target=part.start.Value+part.CFrame.LookVector*160 end
                self:_translate(part,target)
            end
            if part.Name=='orbit' then
                local parent=need(part,'par').Value;assert(parent and parent.ClassName,'Orbit parent reference must resolve to a source clone')
                local lifetime=Source.lifetime(parent)
                local angle=game_time*.7+need(part,'order').Value*math.pi/2
                if parent.Parent and Source.live(parent,lifetime)then self:_translate(part,(parent.CFrame*self.CF.new(math.sin(angle)*20,math.cos(angle)*20,0)).Position)end
            end
            if child(part,'knoddy') then
                part.knoddy.CFrame=part.CFrame*self.CF.new(0,2.3,0)
                need(part,'glass').CFrame=part.CFrame*self.CF.new(0,4.46,0)
            end
        end
    end
    return true
end
function Moving:destroy()
    if self.destroyed then return end
    self:_retire_sounds();self:_drop_folder();self.destroyed=true;self.content=nil;self.controller=nil;self.map=nil
    self.unresolved={};self.unresolved_by_part=setmetatable({},{__mode='k'})
end
return Moving
