-- Public trsCF/anim equipment publication and mesh particles. Native generic
-- Native stored FX properties are published by the optional Robot SourceEffects
-- owner; its capability ledger retains unsupported lighting/texture variants.
local Source=require('projects/showcase3d/robot64/source')
local RayFilter=require('projects/showcase3d/robot64/ray_filter')
local Visual={};Visual.__index=Visual
local function child(node,name) return node and node:FindFirstChild(name) end
local function need(node,name) return assert(child(node,name),'Equipment visual dependency missing: '..name) end
local function alive(node) return node and node.Parent~=nil end
local CLOUD_POOL_LIMIT=8
local function components(value)
    return value and (value.X or value.R or value.x or value.r),
        value and (value.Y or value.G or value.y or value.g),
        value and (value.Z or value.B or value.z or value.b)
end
local function cloud_style(template)
    local mesh=need(template,'Mesh');local size=template.Size;local color=template.Color
    local sx,sy,sz=components(size);local cr,cg,cb=components(color)
    local msx,msy,msz=components(mesh.Scale);local ox,oy,oz=components(mesh.Offset)
    local vx,vy,vz=components(mesh.VertexColor)
    return {class=template.ClassName,shape=template.Shape,size_x=sx,size_y=sy,size_z=sz,
        color_r=cr,color_g=cg,color_b=cb,transparency=template.Transparency,reflectance=template.Reflectance,
        material=template.Material,mesh_class=mesh.ClassName,mesh_type=mesh.MeshType,mesh_id=mesh.MeshId,
        texture_id=mesh.TextureId,scale_x=msx,scale_y=msy,scale_z=msz,offset_x=ox,offset_y=oy,offset_z=oz,
        vertex_x=vx,vertex_y=vy,vertex_z=vz}
end
local function cloud_style_matches(style,template)
    if not style then return false end
    local mesh=child(template,'Mesh');if not mesh then return false end
    local sx,sy,sz=components(template.Size);local cr,cg,cb=components(template.Color)
    local msx,msy,msz=components(mesh.Scale);local ox,oy,oz=components(mesh.Offset)
    local vx,vy,vz=components(mesh.VertexColor)
    return style.class==template.ClassName and style.shape==template.Shape
        and style.size_x==sx and style.size_y==sy and style.size_z==sz
        and style.color_r==cr and style.color_g==cg and style.color_b==cb
        and style.transparency==template.Transparency and style.reflectance==template.Reflectance
        and style.material==template.Material and style.mesh_class==mesh.ClassName and style.mesh_type==mesh.MeshType
        and style.mesh_id==mesh.MeshId and style.texture_id==mesh.TextureId
        and style.scale_x==msx and style.scale_y==msy and style.scale_z==msz
        and style.offset_x==ox and style.offset_y==oy and style.offset_z==oz
        and style.vertex_x==vx and style.vertex_y==vy and style.vertex_z==vz
end
function Visual.new(content,controller,marker,equipment,rbx,options)
    options=options or {}
    local self=setmetatable({content=content,controller=controller,marker=marker,equipment=equipment,rbx=rbx,
        C=rbx.CFrame,V=rbx.Vector3,options=options,random=options.random or math.random,particles={},
        cloud_pool_enabled=options.cloud_pool_enabled==true,cloud_pool={},cloud_entries={},melts={},
        reported={},time=0,destroyed=false,flamecf=rbx.CFrame.new()},Visual)
    self.trs=need(marker.model,'trs');self.jetpack=need(self.trs,'jetpack');self.board=need(self.trs,'board');self.flame=need(self.trs,'flamethrower')
    self.booster=need(self.jetpack,'booster');self.w1=need(self.board,'w1');self.w2=need(self.board,'w2')
    self.board_cool=need(self.board,'cool')
    for kind,name in pairs({dab='pose4',flame='pose5'}) do
        local clone=Source.clone(need(content.rf,name),content.world,rbx);local pose={}
        for _,part in ipairs(clone:GetChildren()) do if part:IsA('BasePart') then pose[part.Name]=part.CFrame end end
        marker.templates[kind]=pose;clone:Destroy()
    end
    self.scaled_parts={}
    self.head_top=need(marker.by_name.head,'top');self.antenna_beam=need(marker.by_name.head,'Beam')
    local resize_children=marker.model:GetChildren()
    for _,part in ipairs(self.trs:GetChildren()) do resize_children[#resize_children+1]=part end
    for _,part in ipairs(resize_children) do
        if part:IsA('BasePart') then local os=child(part,'OS');if os then self.scaled_parts[#self.scaled_parts+1]={part=part,size=os.Value} end end
    end
    self.params=rbx.RaycastParams.new();self.params.FilterType='Exclude';self.params.RespectCanCollide=false
    local previous=equipment.options.on_event
    self.previous_event=previous
    self.event_handler=function(name,data,record) if previous then previous(name,data,record) end;self:handle_event(name,data) end
    equipment.options.on_event=self.event_handler
    return self
end
function Visual:_report(feature,source,reason)
    if self.reported[feature] then return end;self.reported[feature]=true
    local record={feature=feature,source=source,status='unimplemented',reason=reason}
    if self.options.on_unresolved then self.options.on_unresolved(record) else print('[robot64] equipment: '..feature..': '..reason) end
end
function Visual:_sound(name)
    local sound=child(self.marker.by_name.torso,name)
    if not sound then
        local starter=Source.service(self.content.world,'StarterPlayer');local scripts=child(starter,'StarterPlayerScripts')
        sound=child(child(scripts,'CharacterScript'),name)
    end
    if self.options.on_sound then self.options.on_sound(sound,name)
    elseif sound and self.options.assets then
        local vol=child(sound,'vol');self.options.assets:play('equipment-'..name,sound.SoundId,vol and vol.Value or 1,false,sound.PlaybackSpeed or 1)
    elseif sound and sound.Play then sound:Play() end
end
function Visual:_cloud_pool_storage()
    local storage=self.cloud_pool_storage
    if alive(storage) then return storage end
    storage=self.content.world.Instance.new('Folder',{Name='__equipment_cloud_pool'})
    storage.Parent=self.content.rf;self.cloud_pool_storage=storage
    return storage
end
function Visual:_clear_cloud_pool()
    local pool=self.cloud_pool
    for i=#pool,1,-1 do
        local entry=pool[i];pool[i]=nil
        local part=entry and entry.part
        if part then
            self.cloud_entries[part]=nil
            if alive(part) then part:Destroy() end
        end
    end
    local storage=self.cloud_pool_storage
    if alive(storage) then storage:Destroy() end
    self.cloud_pool_storage=nil
end
function Visual:_take_cloud(template)
    local pool=self.cloud_pool
    if #pool==0 then return nil end
    local entry=pool[#pool]
    if not entry or entry.template~=template or not cloud_style_matches(entry.template_style,template)
        or not alive(entry.part) then
        -- A source replacement/style mutation must never reuse stale cloned
        -- bytes; the small pool is discarded and the normal clone path wins.
        self:_clear_cloud_pool();return nil
    end
    pool[#pool]=nil
    return entry
end
function Visual:_store_cloud(entry)
    local part=entry and entry.part
    if not part or not alive(part) then return end
    if not self.cloud_pool_enabled or self.destroyed or #self.cloud_pool>=CLOUD_POOL_LIMIT then
        self.cloud_entries[part]=nil;part:Destroy();return
    end
    local preserve=self.content.world.preserve_dynamic_geometry_while_stored
    if type(preserve)~='function' then
        self.cloud_entries[part]=nil;part:Destroy();return
    end
    preserve(self.content.world,part)
    part.Parent=self:_cloud_pool_storage()
    self.cloud_pool[#self.cloud_pool+1]=entry
end
function Visual:particle(name,count,stationary,frame,size,shrink)
    local V,C,random=self.V,self.C,self.random
    frame=frame or self.controller.body.CFrame-V.new(0,2.5,0)
    local seed=random()*3.14
    for i=1,count do
        local template=need(self.content.rf,name)
        local entry=self.cloud_pool_enabled and name=='cloud' and self:_take_cloud(template) or nil
        local part=entry and entry.part or Source.clone(template,self.content.world,self.rbx)
        part.Anchored=true;part.CanCollide=false
        local direction=count==1 and V.new(random(-30,30),random(-30,30),random(-30,30))/80
            or C.Angles(0,i/count*2*math.pi+seed,0).LookVector
        part.CFrame=frame*C.Angles(random()*math.pi,random()*math.pi,random()*math.pi)+direction
        need(part,'speed').Value=direction*4+V.new(0,2,0)+(not stationary and self.controller.body.Velocity/2 or V.new())
        need(part,'rs').Value=V.new(random(-30,30)/20,random(-30,30)/20,random(-30,30)/20)
        need(part,'shrink').Value=shrink or 1
        local mesh=need(part,'Mesh')
        local base_scale=entry and entry.base_scale or Source.vector(mesh.Scale,self.rbx)
        mesh.Scale=base_scale* (size or 1)*(.7+random()*.3)
        -- Publish the complete authored particle into an independently owned
        -- native draw chunk. Expiration retires that chunk, never the level.
        if not entry then
            self.content.world:retain_dynamic_geometry(part)
            local preserve=self.content.world.preserve_dynamic_geometry_while_stored
            if self.cloud_pool_enabled and name=='cloud' and type(preserve)=='function' then
                entry={part=part,template=template,template_style=cloud_style(template),base_scale=base_scale}
                preserve(self.content.world,part)
            end
        end
        part.Parent=need(self.content.world.Workspace,'debris')
        if entry then self.cloud_entries[part]=entry end
        self.particles[#self.particles+1]=part
    end
end
function Visual:handle_event(name,data)
    if self.destroyed then return end
    if name=='pickup' or name=='lost-jetpack' then
        self:particle('cloud',data.cloud,true,self.marker.by_name.torso.CFrame)
        if data.sound then self:_sound(data.sound) end
    elseif name=='sound' then self:_sound(data.sound)
    elseif name=='cadence' then
        local s=self.controller.state
        if s.skid or (s.sliding and s.ground) then self:particle('cloud',1)
        elseif data.bees and data.flying and data.counter%3==0 then
            self:particle('bees',1,nil,self.jetpack.CFrame*self.C.new(0,-.9,-.2),2,8)
        elseif data.flying and not data.bees then
            self:particle('cloud',1,nil,self.jetpack.CFrame*self.C.new(data.counter%2==0 and -.3 or .3,-.9,-.2),.4)
        elseif (1-self.controller.animation.walklerp)*self.controller.animation.wallerp*(1-self.controller.animation.lederp)*(1-self.controller.animation.skaterp)>.6 then
            self:particle('cloud',1,nil,self.marker.by_name.torso.CFrame*self.C.new(0,0,-1))
        end
    end
end
function Visual:_melt(hit)
    if child(hit,'steam') then return end
    local steam=Source.clone(need(self.content.rf,'steam'),self.content.world,self.rbx);steam.Parent=hit
    self.melts[#self.melts+1]={part=hit,steam=steam,start=self.time,melting=true}
    if not self.options.source_effects then self:_report('ice steam emitter','CharacterScript:5326-5339','A local source particle presentation owner is required.')end
end
function Visual:_flame_hit()
    local ignored={self.controller.body,self.marker.model}
    for _,name in ipairs({'fakes','debris'}) do local node=child(self.content.world.Workspace,name);if node then ignored[#ignored+1]=node end end
    RayFilter.assign(self.params,ignored)
    local hit=self.content.world.Workspace:Raycast(self.flame.Position-self.flamecf.LookVector*2,self.flamecf.LookVector*17,self.params)
    local part=hit and hit.Instance
    if part and part.Name=='ice' then self:_melt(part)
    elseif part and (part.Name=='col' or part.Parent and part.Parent.Name=='vis' and child(part.Parent.Parent,'col')) then
        if part.Parent.Name=='vis' then part=need(part.Parent.Parent,'col') end
        if self.options.on_enemy_hit then self.options.on_enemy_hit(part,part.CFrame+self.V.new(0,1,0),true)
        else self:_report('flame enemy hit','CharacterScript:5356-5368','Actual actor touch callback is required; no damage substitute is applied.') end
    end
end
-- body_frame optionally replaces the body's pose, e.g. interpolated between
-- physics steps by the host, so the board and flamethrower follow the rig.
function Visual:update(dt,game_time,alpha,body_frame)
    if self.destroyed then return end
    body_frame=body_frame or self.controller.body.CFrame
    self.time=game_time or self.time+dt;alpha=alpha or 0
    local e,s,c,C,V=self.equipment,self.controller.state,self.controller,self.C,self.V
    local torso=self.marker.by_name.torso.CFrame;local scale=c.animation.scale or V.new(1,1,1)
    local function offset(x,y,z) return C.new(x*scale.X,y*scale.Y,z*scale.Z) end
    -- Rescale only on a scale change. Source writes the same OS-based sizes
    -- every animation frame; immutable base-size publication is equivalent.
    if self.scale_x~=scale.X or self.scale_y~=scale.Y or self.scale_z~=scale.Z then
        for _,entry in ipairs(self.scaled_parts) do if alive(entry.part) then entry.part.Size=entry.size*scale end end
        self.head_top.Position=V.new(0,.8*scale.Y,0)
        self.antenna_beam.Width0=.2*scale.Y;self.antenna_beam.Width1=.2*scale.Y
        local hat=child(self.trs,'hat');local os=child(hat,'OS');if os then hat.Size=os.Value*scale end
        self.scale_x,self.scale_y,self.scale_z=scale.X,scale.Y,scale.Z
    end
    self.jetpack.Transparency=e.hasfly and alpha or 1;self.booster.Transparency=self.jetpack.Transparency
    if e.hasfly then
        self.jetpack.CFrame=torso*offset(0,.2,1)
        self.booster.Size=V.new(1.3079999685287476,.8299999833106995,.6069999933242798)*(1+self.random()/10)
        self.booster.CFrame=torso*offset(0,-.6,1)
        local bees=e.options.bees and e.options.bees() or false
        local texture=bees and 'rbxassetid://1238502458' or 'rbxassetid://1129631027'
        if self.options.assets then texture=assert(self.options.assets:resolve(texture),'Public jetpack texture missing '..texture) end
        self.jetpack.TextureId=texture;self.booster.TextureId=texture
    end
    local trail_a,trail_b=need(self.jetpack,'TrailA'),need(self.jetpack,'TrailB')
    trail_a.Enabled=s.flying and e.flyspeed>2.7 or false;trail_b.Enabled=trail_a.Enabled
    if s.flying then
        need(self.jetpack,'gastB').Position=V.new(-.2*math.sin(-c.animation.potand)-1.7,-.468,.119)
        need(self.jetpack,'gastC').Position=V.new(.2*math.sin(c.animation.potand)+1.7,-.468,.119)
        if trail_a.Enabled and not self.options.source_effects then self:_report('jetpack trails','CharacterScript:8964-8970','A local source trail presentation owner is required.') end
    end
    self.board.Transparency=e.hasboard and alpha or 1;self.w1.Transparency=self.board.Transparency;self.w2.Transparency=self.board.Transparency
    -- Public8540–8552 resets the board emitter each active movement frame,
    -- then enables it only for skating on either genuine lava ground name.
    local ground=c.ground_hit and c.ground_hit.Instance
    self.board_cool.Enabled=s.skate==true and not not s.ground and ground~=nil and (ground.Name=='lava'or ground.Name=='lava2')or false
    local root=body_frame-V.new(0,1,0);self.board.CFrame=root*c.animation:evaluate(self.marker.templates).board
    if e.hasboard then
        self.w1.CFrame=self.board.CFrame*offset(0,-.4,-1.2)*C.Angles(-self.time*10*c.animation.skaterp,0,0)
        self.w2.CFrame=self.board.CFrame*offset(0,-.4,1.2)*C.Angles(-self.time*10*c.animation.skaterp,0,0)
    end
    self.flame.Transparency=e.hasflame and alpha or 1
    local emitter=need(need(self.flame,'pcl'),'p');emitter.Enabled=e.hasflame and e.flameon or false
    if e.hasflame then
        local target=torso;local dir=e.dir or V.new()
        if not s.ground then target=body_frame*C.Angles(-math.pi/2-dir:Dot(body_frame.LookVector)*math.pi/2,dir:Dot(body_frame.RightVector)*math.pi/2,0) end
        self.flamecf=self.flamecf:Lerp(target,math.min(1,dt*10))
        local arm=self.marker.by_name.armC
        self.flame.CFrame=(self.flamecf-self.flamecf.Position+(arm.Position-arm.CFrame.UpVector/2))*C.new(0,1,-.9)
        e.flame_frame=self.flame.CFrame
        if e.flameon then
            if not self.options.source_effects then self:_report('flamethrower emitter','CharacterScript:5315','A local source particle presentation owner is required.')end
            self:_flame_hit()
        end
    end
    for i=#self.particles,1,-1 do
        local part=self.particles[i]
        if alive(part) then
            local rs=need(part,'rs').Value
            part.CFrame=part.CFrame*C.Angles(rs.X*dt,rs.Y*dt,rs.Z*dt)+need(part,'speed').Value*dt
            local mesh=need(part,'Mesh');mesh.Scale=Source.vector(mesh.Scale,self.rbx)-V.new(1,1,1)*need(part,'shrink').Value*dt/10
            if mesh.Scale.X<=0 then
                local entry=self.cloud_entries[part]
                if entry then self:_store_cloud(entry) else part:Destroy() end
                table.remove(self.particles,i)
            end
        else self.cloud_entries[part]=nil;table.remove(self.particles,i) end
    end
    for i=#self.melts,1,-1 do
        local melt=self.melts[i];local part=melt.part
        if not alive(part) then table.remove(self.melts,i)
        elseif melt.melting and self.time-melt.start<.2 then
            local amount=math.min(1,dt*2);local frame=part.CFrame
            part.Size=part.Size-V.new(amount,amount*1.5,amount);part.CFrame=frame-V.new(0,amount*1.5/2,0)
        elseif melt.melting then
            melt.melting=false;melt.finish=self.time+10;melt.steam.Enabled=false;melt.steam.Name='notsteam'
            if part.Size.Y<1.5 or part.Size.X<1.5 then part.Transparency=1;part.CanCollide=false;melt.remove_part=true end
        elseif self.time>=melt.finish then
            if melt.remove_part then part:Destroy() elseif alive(melt.steam) then melt.steam:Destroy() end
            table.remove(self.melts,i)
        end
    end
end
function Visual:retire()
    for _,part in ipairs(self.particles) do
        self.cloud_entries[part]=nil
        if alive(part) then part:Destroy() end
    end
    self:_clear_cloud_pool()
    for _,melt in ipairs(self.melts) do if alive(melt.steam) then melt.steam:Destroy() end end
    self.particles={};self.cloud_entries={};self.melts={};self.scale_x=nil;self.scale_y=nil;self.scale_z=nil
    self.jetpack.Transparency=1;self.booster.Transparency=1;self.board.Transparency=1;self.w1.Transparency=1;self.w2.Transparency=1;self.flame.Transparency=1
    need(self.jetpack,'TrailA').Enabled=false;need(self.jetpack,'TrailB').Enabled=false;need(need(self.flame,'pcl'),'p').Enabled=false
    self.board_cool.Enabled=false
end
function Visual:destroy()
    if self.destroyed then return end;self:retire();self.destroyed=true
    if self.equipment.options.on_event==self.event_handler then self.equipment.options.on_event=self.previous_event end
end
return Visual
