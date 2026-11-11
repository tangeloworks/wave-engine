-- Public .06-second faces, regional dot lights, shadow and movement feedback.
-- Presentation consumes the existing equipment cadence; it owns no timer,
-- physics integration, character alpha or replacement particle renderer.
local Presentation={};Presentation.__index=Presentation
local faces={[1]='1451094768',[2]='1451124286',[3]='1451124533',[4]='1451125125',[5]='1451125369'}
local function child(node,name) return node and node:FindFirstChild(name) end
local function need(node,name)
    local value=child(node,name)
    assert(value,'Public presentation dependency missing: '..name)
    return value
end
local function sign(n) return n>0 and 1 or n<0 and -1 or 0 end
function Presentation.new(content,controller,marker,rbx,options)
    options=options or{}
    local self=setmetatable({content=content,controller=controller,marker=marker,rbx=rbx,V=rbx.Vector3,C=rbx.CFrame,
        options=options,random=options.random or math.random,blink=10,face_id=0,display_face_id=0,walkfx=1,dancing=false,
        textures={},events={},reported={},destroyed=false,time=0,flipo=0,spin_cursor=controller.animation.spin_wraps or 0},Presentation)
    self.torso=assert(marker.by_name.torso);self.dot=assert(marker.by_name.dot)
    self.shadow=need(need(marker.model,'trs'),'shadow');self.slide=need(self.torso,'slide');self.splash=need(self.torso,'splash')
    self.lights={need(self.dot,'L1'),need(self.dot,'L2'),need(self.dot,'L3')}
    for id,asset in pairs(faces) do
        local reference='rbxassetid://'..asset
        self.textures[id]=marker.faces and marker.faces[reference] or options.assets and options.assets:resolve(reference)
        if not self.textures[id] then self:_report('character face '..id,'CharacterScript:7424-7443','The authored local texture '..reference..' is unavailable.') end
    end
    -- Append after EquipmentVisual, retaining source cloud-before-blink visual
    -- RNG order. The host keeps gameplay decisions on its own explicit stream.
    if options.equipment then
        self.equipment=options.equipment;self.previous_event=options.equipment.options.on_event
        self.event_handler=function(name,data,record)
            if self.previous_event then self.previous_event(name,data,record) end
            if name=='cadence' then self:cadence(data.counter+1,record and record.time or self.time) end
        end
        options.equipment.options.on_event=self.event_handler
    end
    return self
end
function Presentation:_context() return self.options.context and self.options.context() or{} end
function Presentation:_report(feature,source,reason)
    if self.reported[feature] then return end;self.reported[feature]=true
    local record={feature=feature,source=source,status='unimplemented',reason=reason}
    if self.options.on_unresolved then self.options.on_unresolved(record) else print('[robot64] presentation: '..feature..': '..reason) end
end
function Presentation:_event(name,data)
    self.events[#self.events+1]={name=name,time=self.time,data=data}
    if #self.events>100 then table.remove(self.events,1) end
end
function Presentation:cadence(counter,game_time)
    if self.destroyed then return end
    local context=self:_context();if context.paused then return end
    self.time=game_time or self.time;self.counter=counter
    self.blink=self.blink-1
    if self.blink<0 then self.blink=self.blink+20+self.random(4)*10 end
    local dancing=self.controller.state.dancing
    if context.gotice or dancing then self.face_id=2
    elseif self.time-(context.damage_time or self.damage_time or-50)<2 then self.face_id=3
    elseif self.blink==2 or self.blink==0 then self.face_id=4
    elseif self.blink==1 then self.face_id=5
    else self.face_id=1 end
    self.display_face_id=self.face_id
    self:_event('face',{id=self.face_id,blink=self.blink,counter=counter})
    self:_publish_face(context)
end
function Presentation:_publish_face(context)
    local id=self.display_face_id
    if not context.paused and context.talkto and context.talking
        and (context.player_textbox or context.textbox_background=='rbxassetid://1442127057') and math.sin(self.time*50)>.5 then
        id=2;self.display_face_id=id
    end
    if self.textures[id] then self.marker.face.Texture=self.textures[id] end
end
function Presentation:begin_dialogue(speaker)
    if not speaker or not speaker.Parent or not speaker.Size or not speaker.CFrame then return false end
    -- Source carry1635 captures fresh Values for every admitted speaker. Its
    -- later FindFirstChild keeps the first baseline if that speaker repeats.
    local factory=self.content.world and self.content.world.Instance
    if factory then
        factory.new('Vector3Value',{Name='sz',Parent=speaker,Value=speaker.Size})
        factory.new('CFrameValue',{Name='cf',Parent=speaker,Value=speaker.CFrame})
    end
    self.speaker=speaker
    self.speaker_size=child(speaker,'sz') and child(speaker,'sz').Value or speaker.Size
    self.speaker_frame=child(speaker,'cf') and child(speaker,'cf').Value or speaker.CFrame
    return true
end
function Presentation:_dialogue(context)
    local speaker=context.talkto
    if not speaker or not speaker.FindFirstChild or not speaker.Parent or not speaker.Size or not speaker.CFrame then return end
    if self.speaker~=speaker and not self:begin_dialogue(speaker) then return end
    if context.talking then
        if not(context.player_textbox or context.textbox_background=='rbxassetid://1442127057') then
            local sine,cosine=math.sin(self.time*20),math.cos(self.time*20)
            speaker.Size=self.speaker_size+self.V.new(sine,cosine,sine)/8
            speaker.CFrame=self.speaker_frame+self.V.new(0,cosine,0)/16
        end
    else speaker.Size=self.speaker_size;speaker.CFrame=self.speaker_frame end
end
function Presentation:dance(dir)
    if self.destroyed then return false end
    local s=self.controller.state;dir=dir or self.controller.movement_direction or self.V.new()
    if s.ground and dir.Magnitude<.3 and not(s.swimming or s.rope or s.pole or s.sliding or s.crouch or s.attack or s.skate) then
        s.dancing=true;self.dancing=true;return true
    end
    return false
end
function Presentation:actions(controller,dt,input,dir)
    local context=self:_context();local s=controller.state
    local movable=not context.paused and not context.talkto and context.canmove~=false
    if movable and input.jump then s.dancing=false end
    local map=self.content.active;local map_name=map and map.Name
    if movable and input.dive and not controller.onejump and map_name~='Boss' and map_name~='MAKE' then s.dancing=false end
    if s.crouch or s.attack then s.dancing=false end
    if not(s.swimming or s.pole or s.ledge or s.crouch) and dir.Magnitude>.2
        and(s.rope or s.ground and controller.time-(s.landed or 0)>.2) then s.dancing=false end
    self.dancing=s.dancing==true
    return input
end
function Presentation:damage(game_time)
    -- The campaign cinematic owns the source damage sound and physical pack/
    -- battery debris. This hook only preserves the independent face timestamp.
    self.damage_time=game_time or self.time
end
function Presentation:event(name,time,controller)
    if self.destroyed then return end
    controller=controller or self.controller
    self.time=self.options.game_time and self.options.game_time() or time or self.time
    local sound=({jump='jump',longjump='jump',backflip='jump2',away='jump2',climb='jump2',
        recovery='jump2',walljump='jump2',['pole-jump']='jump2',double='djump',twirl='smack',dive='dive',land='land'})[name]
    if sound then self:_sound(sound) end
    local particle=self.options.particle
    if particle then
        if name=='jump' or name=='longjump' or name=='backflip' then particle('cloud',1)
        elseif name=='double' then
            particle('cloud',1,true);self.double_clouds={cursor=controller.animation.double_flip_serial or 0,left=3}
        elseif name=='land' then particle('cloud',controller.last_land and controller.last_land.pound and 8 or 3,true) end
    end
    if name=='twirl' then self.last_potand=controller.animation.potand end
    if name=='damage' then self:damage(self.time) end
end
function Presentation:_sound(name)
    local sound=need(self.torso,name);local vol=child(sound,'vol')
    sound.Volume=vol and vol.Value or 1 -- exact psound3213, including pole vol.5
    if self.options.on_sound then self.options.on_sound(sound,name)
    elseif self.options.assets and sound.SoundId then self.options.assets:play('presentation-'..name,sound.SoundId,sound.Volume,false,sound.PlaybackSpeed or 1)
    else self:_report('movement sound playback','CharacterScript:8895-8902','Authored sound state is selected; a native audio owner is required.') end
    self:_event('sound',{name=name,sound=sound})
end
function Presentation:_lights(context)
    local regions=self.options.regions and self.options.regions() or context.regions or{}
    self.source_regions=regions;self.silent=regions.silent==true
    local active=regions.light==true
    self.dot.Material=(active and self.rbx.Enum.Material.Neon or self.rbx.Enum.Material.SmoothPlastic).Value
    self.lights[1].Enabled=active;self.lights[2].Enabled=active;self.lights[3].Enabled=active and not context.firstperson
    if self.lights[3].Enabled then
        if not self.options.character_flare then self:_report('dot billboard flare','CharacterScript:8119','The source L3 BillboardGui is enabled, but the character flare has no registered native world UI surface.')end
    end
end
function Presentation:_shadow()
    local origin=self.torso.Position;local direction=self.V.new(0,-30,0)
    local hit=self.options.cast and self.options.cast(origin,direction) or not self.options.cast and self.controller:_ray(origin,direction)
    local position=hit and hit.Position or origin+direction
    self.shadow_hit=hit;self.shadow_position=position
    if hit then
        local scale=self.controller.state.scale or self.controller.animation.scale or self.V.new(1,1,1)
        local size=((position.Y-origin.Y)/10+3)*(scale.X+scale.Z)*.7
        self.shadow.Size=self.V.new(size,1,size)
        self.shadow.CFrame=self.C.lookAt(position,position+hit.Normal)*self.C.Angles(-math.pi/2,0,0)*self.C.new(0,-.4,0)
    else self.shadow.Size=self.V.new();self.shadow.CFrame=self.C.new(0,-10000,0) end
    local animation=self.controller.animation
    self.slide_volume=animation.sliderp*(1-animation.swimerp)*math.min(1,position.Y-origin.Y+2.6)
    self.slide.Volume=self.slide_volume
end
function Presentation:update(dt,game_time)
    if self.destroyed then return end
    self.time=game_time or self.time;local context=self:_context()
    self:_lights(context);self:_publish_face(context)
    if context.paused then return end
    self:_dialogue(context)
    local s=self.controller.state;self.dancing=s.dancing==true
    if s.crouch or s.attack then s.dancing=false;self.dancing=false end
    local flipo=math.floor(self.controller.animation.botand/(2*math.pi)+.5)
    if flipo~=self.flipo and not context.gotice then self.flipo=flipo;self:_sound('flip') end
    local spins=self.controller.animation.spin_wraps or 0
    local wraps=math.max(0,spins-self.spin_cursor);self.spin_cursor=spins
    if not context.gotice then for _=1,wraps do self:_sound('spin') end end
    local clouds=self.double_clouds
    if clouds then
        local serial=self.controller.animation.double_flip_serial or 0
        local count=math.min(clouds.left,math.max(0,serial-clouds.cursor));clouds.cursor=serial
        for _=1,count do if self.options.particle then self.options.particle('cloud',1,true) end end
        clouds.left=clouds.left-count
        if clouds.left==0 or not self.controller.animation.double_flips then self.double_clouds=nil end
    end
    self:_shadow()
    local value=sign(math.sin(self.controller.animation.walktick*14))
    if value~=self.walkfx and(not s.double and not s.swimming or s.wall or s.pole) then
        self.walkfx=value
        if s.pole then self:_sound('pole')
        else self:_sound('s'..(s.ground and(child(s.ground,'step') or s.ground.Name=='step') and'b' or'a')..self.random(5)) end
    end
    self.splash.Enabled=s.swimming==true and self.time-(context.water_tick or-10)<1
    if self.splash.Enabled and not self.options.source_effects then self:_report('swimming splash emitter','CharacterScript:8927,8940','A local source particle presentation owner is required.')end
end
function Presentation:activate(map)
    self.map=map;self.controller.state.dancing=self.dancing or nil
end
function Presentation:retire()
    self.dancing=self.controller.state.dancing==true;self.map=nil;self.source_regions=nil;self.silent=false
    self.shadow_hit=nil;self.shadow_position=nil;self.splash.Enabled=false;self.double_clouds=nil
    self.speaker=nil;self.speaker_size=nil;self.speaker_frame=nil
    for _,light in ipairs(self.lights) do light.Enabled=false end
end
function Presentation:reset_all()
    self.blink=10;self.face_id=0;self.display_face_id=0;self.walkfx=1;self.damage_time=nil;self.counter=nil;self.dancing=false;self.flipo=0
    self.spin_cursor=self.controller.animation.spin_wraps or 0
    self.double_clouds=nil;self.last_potand=nil
    self.controller.state.dancing=nil
end
function Presentation:destroy()
    if self.destroyed then return end
    if self.equipment and self.equipment.options.on_event==self.event_handler then self.equipment.options.on_event=self.previous_event end
    self:retire();self.destroyed=true
end
Presentation.contracts={
    {source='CharacterScript:7418-7443',feature='common cadence blink and reward/dance/damage face priority',status='source-derived'},
    {source='CharacterScript:1812-1816,461,1033,8729,8814',feature='dance acquisition, action cancellation and movement cancellation',status='source-derived'},
    {source='CharacterScript:7823-7826,8116-8119,8125',feature='dot material/light/billboard state and silent region',status='source-derived'},
    {source='CharacterScript:8870-8879,8895-8902,8927,8940',feature='authentic shadow, slide volume, footstep choice and splash state',status='source-derived'},
    {source='CharacterScript:1635-1654,8915-8925',feature='source speaker baseline Values, dialogue jiggle and player-mouth publication',status='source-derived'},
    {source='CharacterScript:7421 math.random(4),8901 math.random(5)',feature='visual random stream',status='offline-adaptation',decision='The host shares its explicit presentation RNG with visual clouds; quest decisions keep a separate stream. No measured historical call-order parity is claimed.'},
}
return Presentation
