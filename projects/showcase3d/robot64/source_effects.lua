-- Source FX state is local to Robot. Geometry uses the existing depth-tested
-- world mesh API; no facade properties, source assets or renderer are replaced.
local Source=require('projects/showcase3d/robot64/source')
local Effects={};Effects.__index=Effects
local scalar_beam=require('projects/showcase3d/robot64/beam_geometry')
local kinds={ParticleEmitter=true,Trail=true,Beam=true}
local particle_keys={'Enabled','Rate','Lifetime','Speed','Acceleration','Drag','Rotation','RotSpeed','Color','Size','Transparency','Texture','SpreadAngle','EmissionDirection','LockedToPart','VelocityInheritance','TimeScale','Orientation','Shape','ShapeStyle','ShapeInOut','ShapePartial','FlipbookLayout','Squash','WindAffectsDrag','ZOffset','LightInfluence','LightEmission','Brightness'}
local ribbon_keys={'Enabled','Attachment0','Attachment1','Lifetime','MinLength','MaxLength','WidthScale','Color','Transparency','Texture','TextureMode','TextureLength','TextureSpeed','Width0','Width1','CurveSize0','CurveSize1','Segments','FaceCamera','ZOffset','LightInfluence','LightEmission','Brightness'}
local property_keys={ParticleEmitter={},Trail={},Beam={}}
for _,key in ipairs(particle_keys)do property_keys.ParticleEmitter[key]=true end
for _,key in ipairs(ribbon_keys)do property_keys.Trail[key]=true;property_keys.Beam[key]=true end
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
local function numeric(value,default)
    if type(value)=='table' then value=value.Value or value.value end
    return tonumber(value)or default
end
local function particle_style(p)
    local emission=clamp(numeric(p.LightEmission,0),0,1)
    local influence=clamp(numeric(p.LightInfluence,0),0,1)
    local brightness=math.max(0,numeric(p.Brightness,1))
    return {key=table.concat({tostring(p.Texture),tostring(emission),tostring(influence),tostring(brightness)},'|'),
        emission=emission,influence=influence,brightness=brightness}
end
local function xyz(value,V)
    if getmetatable(value)==V then return value end
    value=value or {};return V.new(value.X or value.x or 0,value.Y or value.y or 0,value.Z or value.z or 0)
end
local function points(value)
    return type(value)=='table'and(value.Keypoints or value.keypoints or value)or value
end
local function sequence_key(p,i,default,offsets)
    return numeric(p[i].Value or p[i].value,default)+(offsets and offsets[i]or 0)
end
local function sequence_segment(p,i,t,default,offsets)
    local a,b=p[i-1],p[i];local at=a.Time or a.time
    local ka,kb=sequence_key(p,i-1,default,offsets),sequence_key(p,i,default,offsets)
    return ka+(kb-ka)*clamp((t-at)/math.max(1e-9,(b.Time or b.time)-at),0,1)
end
local function number_sequence(value,t,default,offsets)
    if type(value)=='number'then return value end
    local p=points(value);if type(p)~='table'or #p==0 then return default end
    -- Two and three keypoints (the authored shapes) resolve without an inner
    -- loop so per-particle JIT traces stay intact; results are identical.
    local n=#p
    if n==2 then
        if t<=(p[2].Time or p[2].time) then return sequence_segment(p,2,t,default,offsets)end
        return sequence_key(p,2,default,offsets)
    elseif n==3 then
        if t<=(p[2].Time or p[2].time) then return sequence_segment(p,2,t,default,offsets)end
        if t<=(p[3].Time or p[3].time) then return sequence_segment(p,3,t,default,offsets)end
        return sequence_key(p,3,default,offsets)
    end
    for i=2,#p do
        local a,b=p[i-1],p[i];local at,bt=a.Time or a.time,b.Time or b.time
        if t<=bt then
            local ka,kb=sequence_key(p,i-1,default,offsets),sequence_key(p,i,default,offsets)
            return ka+(kb-ka)*clamp((t-at)/math.max(1e-9,bt-at),0,1)
        end
    end
    return sequence_key(p,#p,default,offsets)
end
local function rgb(value)
    return value.R or value.r or 1,value.G or value.g or 1,value.B or value.b or 1
end
local function color_segment(p,i,t)
    local a,b=p[i-1],p[i];local at,bt=a.Time or a.time,b.Time or b.time
    local k=clamp((t-at)/math.max(1e-9,bt-at),0,1)
    local ar,ag,ab=rgb(a.Value or a.color);local br,bg,bb=rgb(b.Value or b.color)
    return ar+(br-ar)*k,ag+(bg-ag)*k,ab+(bb-ab)*k
end
local function color_sequence(value,t)
    local p=points(value)
    if type(p)~='table'then return 1,1,1 end
    if p.R or p.r then return rgb(p)end
    local n=#p
    if n==0 then return 1,1,1 end
    if n==2 then
        if t<=(p[2].Time or p[2].time) then return color_segment(p,2,t)end
        return rgb(p[2].Value or p[2].color)
    elseif n==3 then
        if t<=(p[2].Time or p[2].time) then return color_segment(p,2,t)end
        if t<=(p[3].Time or p[3].time) then return color_segment(p,3,t)end
        return rgb(p[3].Value or p[3].color)
    end
    for i=2,#p do
        local a,b=p[i-1],p[i];local at,bt=a.Time or a.time,b.Time or b.time
        if t<=bt then
            local k=clamp((t-at)/math.max(1e-9,bt-at),0,1)
            local ar,ag,ab=rgb(a.Value or a.color);local br,bg,bb=rgb(b.Value or b.color)
            return ar+(br-ar)*k,ag+(bg-ag)*k,ab+(bb-ab)*k
        end
    end
    return rgb(p[#p].Value or p[#p].color)
end
-- World meshes accept linear vertex RGB, whereas source Color3 is sRGB.
local function linear(v)v=clamp(v,0,1);return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
local function own_random()
    if love.math and love.math.newRandomGenerator then
        local generator=love.math.newRandomGenerator(64064)
        return function()return generator:random()end
    end
    local state=64064
    return function()state=state*48271%2147483647;return state/2147483647 end
end
local function within(node,root)
    if not node then return false end
    if node==root then return true end
    -- Instances answer through their raw ancestry; plain fixtures walk Parent.
    local descendant_of=node.IsDescendantOf
    if descendant_of then return descendant_of(node,root)==true end
    node=node.Parent
    while node do if node==root then return true end;node=node.Parent end
    return false
end
local function row(batch,point,u,v,r,g,b,a)
    batch.count=batch.count+1;local vertex=batch.vertices[batch.count]
    if not vertex then vertex={};batch.vertices[batch.count]=vertex end
    vertex[1],vertex[2],vertex[3]=point.X,point.Y,point.Z
    vertex[4],vertex[5],vertex[6],vertex[7],vertex[8],vertex[9]=u,v,r,g,b,a
end
local function quad(batch,a,b,c,d,ua,ub,ar,ag,ab,aa,br,bg,bb,ba)
    row(batch,a,ua,0,ar,ag,ab,aa);row(batch,b,ua,1,ar,ag,ab,aa);row(batch,c,ub,1,br,bg,bb,ba)
    row(batch,a,ua,0,ar,ag,ab,aa);row(batch,c,ub,1,br,bg,bb,ba);row(batch,d,ub,0,br,bg,bb,ba)
end
-- Particle corners already resolve against a single public camera basis.
-- Write numeric components into the existing retained vertex rows, avoiding
-- temporary Vector3 objects without changing source operation/triangle order.
local function particle_vertex(batch,x,y,z,u,v,r,g,b,a)
    batch.count=batch.count+1;local item=batch.vertices[batch.count]
    if not item then item={};batch.vertices[batch.count]=item end
    item[1],item[2],item[3]=x,y,z
    item[4],item[5],item[6],item[7],item[8],item[9]=u,v,r,g,b,a
end
local function particle_quad(batch,px,py,pz,rx,ry,rz,ux,uy,uz,r,g,b,a)
    local x1,y1,z1=px-rx+ux,py-ry+uy,pz-rz+uz
    local x2,y2,z2=px-rx-ux,py-ry-uy,pz-rz-uz
    local x3,y3,z3=px+rx-ux,py+ry-uy,pz+rz-uz
    local x4,y4,z4=px+rx+ux,py+ry+uy,pz+rz+uz
    particle_vertex(batch,x1,y1,z1,0,0,r,g,b,a);particle_vertex(batch,x2,y2,z2,0,1,r,g,b,a);particle_vertex(batch,x3,y3,z3,1,1,r,g,b,a)
    particle_vertex(batch,x1,y1,z1,0,0,r,g,b,a);particle_vertex(batch,x3,y3,z3,1,1,r,g,b,a);particle_vertex(batch,x4,y4,z4,1,0,r,g,b,a)
end
function Effects.new(world,rbx,assets,options)
    options=options or {}
    local checkpoint=options.checkpoint
    assert(checkpoint==nil or type(checkpoint)=='function','Source FX loading checkpoint must be a function')
    -- Without a catalog every emitter reads its live Instance properties.
    local data=options.catalog or {instances={}}
    local self=setmetatable({world=world,rbx=rbx,V=rbx.Vector3,C=rbx.CFrame,assets=assert(assets),options=options,
        random=options.random or own_random(),catalog={},records={},by_node={},pending=setmetatable({},{__mode='k'}),roots={},
        particles={},active={},cursor=1,time=0,images={},batches={},style_users={},reports={},report_keys={},report_total=0,dropped=0,
        image_entries=0,max_textures=options.max_textures or 64,
        max_particles=options.max_particles or 8192,max_samples=options.max_trail_samples or 2048,max_instances=options.max_instances or 1024},Effects)
    self.scalar_beams = options.scalar_beams ~= false
    assert(self.max_particles>=1 and self.max_particles%1==0 and self.max_samples>=2 and self.max_samples%1==0 and self.max_instances>=1,'positive integral FX capacity required')
    for index,record in ipairs(data.instances)do
        if kinds[record.class]then self.catalog[tostring(record.referent)]=record end
        if checkpoint and index%256==0 then checkpoint('source-fx:catalog-index',index,#data.instances)end
    end
    for i=1,self.max_particles do
        self.particles[i]={alive=false}
        if checkpoint and i%256==0 then checkpoint('source-fx:particle-pool',i,self.max_particles)end
    end
    self.observer=Source.observe_clones(world,function(clone)
        if kinds[clone.ClassName]then self.pending[clone]=true end
        -- Source.clone publishes one prepared root to observers. Continuous
        -- producers may be nested below a Part/Attachment or editor model.
        for _,node in ipairs(clone:GetDescendants())do
            if kinds[node.ClassName]then self.pending[node]=true end
        end
    end)
    return self
end
function Effects:_report(record,feature,reason,status)
    local key=tostring(record and record.definition.referent or 'global')..':'..feature
    if self.report_keys[key]then return end
    self.report_total=self.report_total+1
    local report={feature=feature,status=status or 'unsupported',reason=reason,
        referent=record and record.definition.referent,path=record and record.definition.path}
    if #self.reports>=256 then local old=table.remove(self.reports,1);self.report_keys[old.key]=nil end
    report.key=key;self.reports[#self.reports+1]=report;self.report_keys[key]=true
    if self.options.on_unresolved then self.options.on_unresolved(report)else print('[robot64] effects: '..feature..': '..reason)end
end
function Effects:_get(record,key)
    local value=record.node[key]
    if value~=nil then return value end
    local property=record.definition.properties[key]
    return property and property.value
end
function Effects:_properties(record)
    -- Native Instance Changed is synchronous with the authoritative property
    -- setter. One owned listener observes zero-step authoring/cosmetic writes,
    -- so update and prepare can share the same unchanged property snapshot.
    -- Signal-less fixtures retain direct polling rather than stale values.
    if record.property_connection and not record.properties_dirty then return record.props end
    local result=record.props or {};record.props=result
    for _,key in ipairs(record.kind=='ParticleEmitter'and particle_keys or ribbon_keys)do result[key]=self:_get(record,key)end
    if record.kind=='ParticleEmitter'then
        local style=particle_style(result);local previous=record.particle_style
        if not previous or previous.key~=style.key then
            if previous then
                local users=self.style_users[previous.key]-1
                self.style_users[previous.key]=users>0 and users or nil
            end
            self.style_users[style.key]=(self.style_users[style.key]or 0)+1
            record.particle_style=style
        end
    end
    record.properties_dirty=false
    return result
end
function Effects:_scope(node)
    for i=#self.roots,1,-1 do local root=self.roots[i];if within(node,root.node)then return root.scope end end
end
function Effects:_add(node,scope)
    if self.by_node[node]then self.by_node[node].scope=scope;return self.by_node[node]end
    local definition=self.catalog[tostring(Source.origin(node))]
    if not definition or definition.class~=node.ClassName then
        definition={referent=tostring(Source.origin(node) or node.Name),class=node.ClassName,properties={},path=node:GetFullName()}
    end
    if #self.records>=self.max_instances then self:_report(nil,'instance-capacity','The bounded live FX registry is full.');return end
    local record={node=node,definition=definition,scope=scope,kind=node.ClassName,fraction=0,samples={},head=0,count=0,distance=0,generation=0,batch={vertices={},count=0}}
    self.by_node[node]=record;self.records[#self.records+1]=record;self.pending[node]=nil
    local changed=node.Changed
    if changed and type(changed.Connect)=='function'then
        local keys=property_keys[record.kind]
        record.property_connection=changed:Connect(function(key)
            if not record.retired and keys[key]then record.properties_dirty=true end
        end)
        record.properties_dirty=true
    end
    local p=self:_properties(record)
    return record
end
function Effects:register(root,options)
    assert(not self.destroyed,'SourceEffects is destroyed');options=options or {}
    local scope=type(options)=='string'and options or options.scope or 'map'
    local found=false;for _,entry in ipairs(self.roots)do if entry.node==root then entry.scope=scope;found=true;break end end
    if not found then self.roots[#self.roots+1]={node=root,scope=scope}end
    if kinds[root.ClassName]then self:_add(root,scope)end
    for _,node in ipairs(root:GetDescendants())do if kinds[node.ClassName]then self:_add(node,scope)end end
    return self
end
function Effects:_frame(node)
    if not node or not node.Parent then return end
    if node.ClassName=='Attachment'then
        local parent=self:_frame(node.Parent);if not parent then return end
        local frame=node.CFrame
        if getmetatable(frame)~=self.C then frame=Source.cframe(frame or {},self.rbx) end
        return parent*frame
    end
    if node.IsA and node:IsA('BasePart')then return node.CFrame end
end
function Effects:_attachment(record,key)
    local node=self:_properties(record)[key]
    -- Source.clone binds references to clone-local Instances. A raw original
    -- referent must never accidentally connect to a different clone generation.
    if type(node)~='table'or node.ClassName~='Attachment'or not within(node,self.world.Workspace)then
        self:_report(record,key,'The source attachment endpoint is absent or not a live clone-local Attachment.');return
    end
    return self:_frame(node)
end
function Effects:_image(reference,record,allow_empty)
    if reference==nil or reference==''then
        if allow_empty then return nil,true end
        self:_report(record,'missing-texture','A particle texture is empty; no replacement sprite is generated.','missing-dependency');return nil,false
    end
    reference=tostring(reference)
    if self.images[reference]~=nil then return self.images[reference]or nil,self.images[reference]~=false end
    if self.image_entries>=self.max_textures then self:_report(record,'texture-capacity','The bounded owned texture cache is full.','bounded-capacity');return nil,false end
    self.image_entries=self.image_entries+1
    local path=self.assets:resolve(reference,'texture')
    if not path then self.images[reference]=false;self:_report(record,'missing-texture:'..reference,'The authored texture is unavailable locally.','missing-dependency');return nil,false end
    local ok,image=pcall(love.graphics.newImage,path)
    if not ok then self.images[reference]=false;self:_report(record,'texture-decode:'..reference,tostring(image),'missing-dependency');return nil,false end
    image:setWrap(record.kind=='ParticleEmitter'and 'clamp'or 'repeat','clamp');self.images[reference]=image;return image,true
end
function Effects:_range(value,default)
    if type(value)=='number'then return value end
    if not value then return default end
    local lo,hi=value.Min or value.min,value.Max or value.max
    return lo+self.random()*(hi-lo)
end
function Effects:_envelopes(value)
    local offsets={};for i,p in ipairs(points(value)or{})do
        local envelope=numeric(p.Envelope or p.envelope,0)
        offsets[i]=envelope~=0 and (self.random()*2-1)*envelope or 0
    end
    return offsets
end
function Effects:_supported(record,p)
    for _,key in ipairs({'Orientation','Shape','ShapeStyle','ShapeInOut','FlipbookLayout'})do
        if numeric(p[key],0)~=0 then self:_report(record,key,'This non-authored variant is outside the camera-facing Box/Volume/Outward/no-flipbook contract.');return false end
    end
    if p.WindAffectsDrag==true or numeric(p.ShapePartial,1)~=1 then self:_report(record,'shape-or-wind','Non-authored shape partial/wind simulation is unsupported.');return false end
    for _,point in ipairs(points(p.Squash)or{})do
        if numeric(point.Value or point.value,0)~=0 then self:_report(record,'Squash','Non-authored squash deformation is unsupported.');return false end
    end
    return true
end
function Effects:emit(emitter,count)
    if self.destroyed or not emitter then return 0,'FX renderer or emitter is unavailable' end
    if not within(emitter,self.world.Workspace)then return 0,'Emitter is outside Workspace' end
    local record=self.by_node[emitter]or self:_add(emitter,self:_scope(emitter)or 'map')
    if not record or record.kind~='ParticleEmitter'then return 0,'No matching source ParticleEmitter catalog entry' end
    local p=self:_properties(record);if not self:_supported(record,p)then return 0,'Unsupported particle variant' end
    local frame=self:_frame(emitter.Parent);if not frame then return 0,'Emitter parent has no live source transform' end
    local _,available=self:_image(p.Texture,record,false);if not available then return 0,'Authored particle texture unavailable' end
    local V,C=self.V,self.C;local parent=emitter.Parent
    local size=parent.ClassName=='Attachment'and V.new()or parent.Size or V.new()
    local part=parent.ClassName=='Attachment'and parent.Parent or parent
    local normal=numeric(p.EmissionDirection,1)
    local directions=self.emission_directions
    if not directions then
        directions={[0]=V.new(1,0,0),[1]=V.new(0,1,0),[2]=V.new(0,0,1),[3]=V.new(-1,0,0),[4]=V.new(0,-1,0),[5]=V.new(0,0,-1)}
        self.emission_directions=directions;self.emission_axes={}
    end
    local direction=directions[normal];if not direction then self:_report(record,'EmissionDirection','Invalid source NormalId.');return 0 end
    local spread=p.SpreadAngle or {};local spreadx=spread.X or spread.x or 0;local spready=spread.Y or spread.y or 0
    local axis=self.emission_axes[normal]
    if not axis then axis=C.lookAt(V.new(),direction);self.emission_axes[normal]=axis end
    local emitted=0
    count=math.max(0,math.floor(count or 1));if count>self.max_particles then self.dropped=self.dropped+count-self.max_particles;count=self.max_particles;self:_report(nil,'particle-capacity','Burst count exceeds the bounded particle pool.','bounded-capacity')end
    for _=1,count do
        local life=self:_range(p.Lifetime,1)
        if life>0 then
            local particle=self.particles[self.cursor];self.cursor=self.cursor%self.max_particles+1
            if not particle.alive then self.active[#self.active+1]=particle else self.dropped=self.dropped+1;self:_report(nil,'particle-capacity','The oldest pooled particle is reused at capacity.','bounded-capacity')end
            particle.alive=true;particle.record=record;particle.age=0;particle.life=life;particle.frame=frame
            local offset=V.new((self.random()-.5)*size.X,(self.random()-.5)*size.Y,(self.random()-.5)*size.Z)
            particle.position=frame*offset
            local yaw=math.rad((self.random()-.5)*spreadx);local pitch=math.rad((self.random()-.5)*spready)
            local facing=axis*C.Angles(pitch,yaw,0)
            particle.velocity=(frame-frame.Position)*facing.LookVector*self:_range(p.Speed,0)+xyz(part.Velocity,V)*numeric(p.VelocityInheritance,0)
            particle.angle=math.rad(self:_range(p.Rotation,0));particle.rotation=math.rad(self:_range(p.RotSpeed,0))
            particle.size_offsets=self:_envelopes(p.Size);particle.alpha_offsets=self:_envelopes(p.Transparency)
            emitted=emitted+1
        end
    end
    return emitted
end
function Effects:clear(emitter)
    for i=#self.active,1,-1 do local particle=self.active[i];if not emitter or particle.record.node==emitter then particle.alive=false;table.remove(self.active,i)end end
    local record=emitter and self.by_node[emitter];if record and record.kind=='Trail'then record.count=0;record.head=0;record.previous=nil end
end
function Effects:_trail_sample(record,p)
    local a,b=self:_attachment(record,'Attachment0'),self:_attachment(record,'Attachment1')
    if p.Enabled~=true or not a or not b then
        if record.enabled then record.generation=record.generation+1;record.previous=nil end
        record.enabled=false;return
    end
    record.enabled=true;local ap,bp=a.Position,b.Position;local previous=record.previous
    local travel=previous and math.max((ap-previous.a).Magnitude,(bp-previous.b).Magnitude)or 0
    if previous and travel<numeric(p.MinLength,.1)then return end
    record.distance=record.distance+(previous and ((ap+bp)*.5-(previous.a+previous.b)*.5).Magnitude or 0)
    record.head=record.head%self.max_samples+1;local sample=record.samples[record.head]or{};record.samples[record.head]=sample
    if record.count==self.max_samples and self.time-(sample.birth or -math.huge)<numeric(p.Lifetime,1)then
        self.dropped=self.dropped+1;self:_report(record,'trail-capacity','The bounded trail ring replaces its oldest still-live sample.','bounded-capacity')
    end
    sample.a,sample.b,sample.birth,sample.distance,sample.generation=ap,bp,self.time,record.distance,record.generation
    record.previous=sample;record.count=math.min(self.max_samples,record.count+1)
end
-- Per-record integration inputs are identical for every particle of one
-- emitter in one update, so they are resolved once per record and update.
function Effects:_integration_parameters(record,dt,epoch)
    local p=record.props
    local step=dt*clamp(numeric(p.TimeScale,1),0,1)
    local acceleration=xyz(p.Acceleration,self.V)
    record.integration_epoch=epoch;record.integration_step=step
    record.integration_half=.5*step*step;record.integration_drag=2^(-numeric(p.Drag,0)*step)
    record.integration_ax,record.integration_ay,record.integration_az=acceleration.X,acceleration.Y,acceleration.Z
    record.locked_to_part=p.LockedToPart==true
    if record.locked_to_part and record.motion_epoch~=epoch then
        record.motion_epoch=epoch
        record.motion_frame=self:_frame(record.node.Parent);record.motion_from=nil
    end
end
function Effects:_motion_change(record,from)
    record.motion_from=from
    record.motion_change=record.motion_frame*from:Inverse()
    record.motion_rotation=record.motion_change-record.motion_change.Position
end
function Effects:update(dt)
    if self.destroyed then return end
    assert(type(dt)=='number'and dt>=0 and dt<math.huge,'finite nonnegative FX dt required')
    self.time=self.time+dt
    self.motion_epoch=(self.motion_epoch or 0)+1
    for i=#self.roots,1,-1 do if self.roots[i].node.Parent==nil then table.remove(self.roots,i)end end
    for node in pairs(self.pending)do local scope=self:_scope(node);if scope then self:_add(node,scope)end end
    for i=#self.records,1,-1 do
        local record=self.records[i]
        if not within(record.node,self.world.Workspace)then
            record.workspace_active=false;record.fraction=0
            if record.kind=='Trail'then record.count=0;record.head=0;record.previous=nil end
            if record.node.Parent==nil then self:_remove(record);table.remove(self.records,i)end
        else record.workspace_active=true;self:_properties(record)end
    end
    local active,epoch,new_vector=self.active,self.motion_epoch,self.V.new
    -- Owner sampling walks Instances; keep it out of the arithmetic loop below.
    for i=1,#active do
        local record=active[i].record
        if record.integration_epoch~=epoch then self:_integration_parameters(record,dt,epoch)end
    end
    local kept=0
    for i=1,#active do
        local particle=active[i];local record=particle.record
        local step=record.integration_step;particle.age=particle.age+step
        if not particle.alive or record.retired or not record.workspace_active or particle.age>=particle.life then particle.alive=false
        else
            if record.locked_to_part then
                -- All live particles from one emitter observe the same owner
                -- pose in this synchronous update. Share that sample and the
                -- identical change matrix; integrate every particle separately.
                local frame=record.motion_frame
                if frame then
                    if record.motion_from~=particle.frame then self:_motion_change(record,particle.frame)end
                    particle.position=record.motion_change*particle.position
                    particle.velocity=record.motion_rotation*particle.velocity;particle.frame=frame
                end
            end
            local position,velocity=particle.position,particle.velocity
            local ax,ay,az=record.integration_ax,record.integration_ay,record.integration_az
            local half,drag=record.integration_half,record.integration_drag
            local px,py,pz,vx,vy,vz=position.X,position.Y,position.Z,velocity.X,velocity.Y,velocity.Z
            -- Publish the same two immutable vectors without intermediate
            -- multiply/add vectors; source arithmetic and ordering stay exact.
            particle.position=new_vector(px+vx*step+ax*half,py+vy*step+ay*half,pz+vz*step+az*half)
            particle.velocity=new_vector((vx+ax*step)*drag,(vy+ay*step)*drag,(vz+az*step)*drag)
            particle.angle=particle.angle+particle.rotation*step
            kept=kept+1;active[kept]=particle
        end
    end
    for i=#active,kept+1,-1 do active[i]=nil end
    for _,record in ipairs(self.records)do
        if record.workspace_active then
            local p=record.props
            if record.kind=='ParticleEmitter'and p.Enabled==true then
                record.fraction=record.fraction+math.max(0,numeric(p.Rate,0))*dt*clamp(numeric(p.TimeScale,1),0,1)
                local count=math.floor(record.fraction+1e-9);record.fraction=math.max(0,record.fraction-count)
                if count>0 then self:emit(record.node,count)end
            elseif record.kind=='Trail'then self:_trail_sample(record,p)end
        end
    end
end
function Effects:_upload(batch,texture,max_vertices)
    local wanted=batch.count
    if wanted>0 and (not batch.mesh or batch.capacity<wanted)then
        local capacity=math.min(max_vertices,math.max(6,(batch.capacity or 192)*2))
        while capacity<wanted do capacity=math.min(max_vertices,capacity*2)end
        if batch.mesh then batch.mesh:destroy()end
        batch.capacity=capacity;batch.mesh=self.world:create_world_mesh(capacity,{light_emission=batch.light_emission,
            light_influence=batch.light_influence,brightness=batch.brightness})
    end
    if batch.mesh then
        if batch.mesh.set_light_emission then batch.mesh:set_light_emission(batch.light_emission or 0)end
        batch.mesh:set_lighting(batch.light_influence or 0,batch.brightness or 1)
        batch.mesh:update(batch.vertices,wanted,texture)
    end
end
function Effects:_ribbon_color(p,t)
    local r,g,b=color_sequence(p.Color,t)
    return linear(r),linear(g),linear(b),clamp(1-number_sequence(p.Transparency,t,0),0,1)
end
function Effects:_trail_prepare(record,p)
    local batch=record.batch;batch.count=0
    batch.light_emission=clamp(numeric(p.LightEmission,0),0,1)
    batch.light_influence=clamp(numeric(p.LightInfluence,0),0,1);batch.brightness=math.max(0,numeric(p.Brightness,1))
    local texture,available=self:_image(p.Texture,record,true);if not available then self:_upload(batch,nil,(self.max_samples-1)*6);return end
    local lifetime=math.max(1e-9,numeric(p.Lifetime,1));local list={};local max_length=numeric(p.MaxLength,0)
    for i=1,record.count do
        local sample=record.samples[(record.head-record.count+i-1)%self.max_samples+1]
        if self.time-sample.birth<lifetime and (max_length<=0 or record.distance-sample.distance<=max_length)then list[#list+1]=sample end
    end
    local first,last=list[1],list[#list];local length=math.max(1e-9,first and last.distance-first.distance or 1)
    local texlength=math.max(1e-9,numeric(p.TextureLength,1));local mode=numeric(p.TextureMode,0)
    if mode~=0 and mode~=1 and mode~=2 then self:_report(record,'TextureMode','Unsupported trail texture mode.');self:_upload(batch,nil,(self.max_samples-1)*6);return end
    if p.FaceCamera==true then self:_report(record,'FaceCamera','Non-authored camera-facing trails are unsupported.');self:_upload(batch,nil,(self.max_samples-1)*6);return end
    local previous
    for _,sample in ipairs(list)do
        local t=clamp((self.time-sample.birth)/lifetime,0,1);local width=number_sequence(p.WidthScale,t,1)
        local mid=(sample.a+sample.b)*.5;local half=(sample.b-sample.a)*(.5*width)
        local u=mode==0 and (sample.distance-first.distance)/length*texlength or (sample.distance-(mode==1 and last.distance or 0))/texlength
        local r,g,b,a=self:_ribbon_color(p,t)
        if previous and previous.sample.generation==sample.generation then quad(batch,previous.a,previous.b,mid+half,mid-half,previous.u,u,previous.r,previous.g,previous.blue,previous.alpha,r,g,b,a)end
        previous={sample=sample,a=mid-half,b=mid+half,u=u,r=r,g=g,blue=b,alpha=a}
    end
    self:_upload(batch,texture,(self.max_samples-1)*6)
end
local function bezier(a,b,c,d,t)
    local k=1-t;return a*(k*k*k)+b*(3*k*k*t)+c*(3*k*t*t)+d*(t*t*t)
end
function Effects:_beam_prepare_legacy(record,p,camera)
    record.batch.light_emission=clamp(numeric(p.LightEmission,0),0,1)
    record.batch.light_influence=clamp(numeric(p.LightInfluence,0),0,1);record.batch.brightness=math.max(0,numeric(p.Brightness,1))
    local batch=record.batch;batch.count=0
    if p.Enabled~=true then self:_upload(batch,nil,768);return end
    local a,b=self:_attachment(record,'Attachment0'),self:_attachment(record,'Attachment1')
    if not a or not b then self:_upload(batch,nil,768);return end
    local texture,available=self:_image(p.Texture,record,true);if not available then self:_upload(batch,nil,768);return end
    local segments=math.floor(numeric(p.Segments,10))
    if segments<1 or segments>128 then self:_report(record,'Segments','The source beam segment count is outside the bounded 1â€“128 contract.','bounded-capacity');self:_upload(batch,nil,768);return end
    local p0,p3=a.Position,b.Position;local p1=p0+a.RightVector*numeric(p.CurveSize0,0);local p2=p3-b.RightVector*numeric(p.CurveSize1,0)
    local samples={};local length=0
    for i=0,segments do
        local t=i/segments;local position=bezier(p0,p1,p2,p3,t)
        if i>0 then length=length+(position-samples[i].position).Magnitude end
        samples[i+1]={position=position,distance=length,t=t}
    end
    local mode=numeric(p.TextureMode,0);local texlength=math.max(1e-9,numeric(p.TextureLength,1));local previous
    if mode~=0 and mode~=1 and mode~=2 then self:_report(record,'TextureMode','Unsupported beam texture mode.');self:_upload(batch,nil,768);return end
    for i,sample in ipairs(samples)do
        local t=sample.t;local tangent=(p1-p0)*(3*(1-t)^2)+(p2-p1)*(6*(1-t)*t)+(p3-p2)*(3*t*t)
        if tangent.Magnitude<1e-8 then tangent=p3-p0 end
        local side=p.FaceCamera==true and tangent:Cross(camera.Position-sample.position)or a.UpVector*(1-t)+b.UpVector*t
        if side.Magnitude<1e-8 then side=camera.RightVector else side=side.Unit end
        local width=(numeric(p.Width0,1)*(1-t)+numeric(p.Width1,1)*t)*.5
        local offset=(camera.Position-sample.position);local z=numeric(p.ZOffset,0)
        local position=sample.position+(offset.Magnitude>1e-8 and offset.Unit*z or self.V.new())
        local u=(mode==0 and t*texlength or sample.distance/texlength)-self.time*numeric(p.TextureSpeed,0)
        local r,g,blue,alpha=self:_ribbon_color(p,t)
        if previous then quad(batch,previous.a,previous.b,position+side*width,position-side*width,previous.u,u,previous.r,previous.g,previous.blue,previous.alpha,r,g,blue,alpha)end
        previous={a=position-side*width,b=position+side*width,u=u,r=r,g=g,blue=blue,alpha=alpha}
    end
    self:_upload(batch,texture,768)
end
function Effects:_beam_prepare(record,p,camera)
    if self.scalar_beams then return scalar_beam.prepare(self,record,p,camera,numeric,clamp,particle_vertex) end
    return self:_beam_prepare_legacy(record,p,camera)
end
function Effects:prepare()
    if self.destroyed then return end
    local camera=self.world.Workspace.CurrentCamera;if not camera then return end
    local cf=camera.CFrame
    local camera_position,right,up=cf.Position,cf.RightVector,cf.UpVector
    local cx,cy,cz=camera_position.X,camera_position.Y,camera_position.Z
    local rx0,ry0,rz0,ux0,uy0,uz0=right.X,right.Y,right.Z,up.X,up.Y,up.Z
    -- Cosmetics and authoring controls may publish properties on zero-step
    -- frames too; observe their live state immediately before world drawing.
    for _,record in ipairs(self.records)do self:_properties(record)end
    for _,batch in pairs(self.batches)do batch.count=0 end
    for _,particle in ipairs(self.active)do
        if particle.alive then
            local p=particle.record.props
            local style=particle.record.particle_style or particle_style(p)
            local reference=style.key
            local texture,available=self:_image(p.Texture,particle.record,false)
            if available then
                local batch=self.batches[reference];if not batch then batch={vertices={},count=0,texture=texture,
                    light_emission=style.emission,light_influence=style.influence,brightness=style.brightness};self.batches[reference]=batch end
                local t=clamp(particle.age/particle.life,0,1);local size=math.max(0,number_sequence(p.Size,t,1,particle.size_offsets))*.5
                local alpha=clamp(1-number_sequence(p.Transparency,t,0,particle.alpha_offsets),0,1)
                local r,g,b=color_sequence(p.Color,t);r,g,b=linear(r),linear(g),linear(b)
                local cosine,sine=math.cos(particle.angle),math.sin(particle.angle)
                local point=particle.position
                local qx,qy,qz=point.X,point.Y,point.Z
                local dx,dy,dz=cx-qx,cy-qy,cz-qz
                local distance=math.sqrt(dx*dx+dy*dy+dz*dz);local z=numeric(p.ZOffset,0)
                local ox,oy,oz=0,0,0
                if distance>1e-8 then ox,oy,oz=(dx/distance)*z,(dy/distance)*z,(dz/distance)*z end
                local px,py,pz=qx+ox,qy+oy,qz+oz
                -- Source ZOffset biases depth without resizing the sprite on
                -- screen. The public mesh API has no depth-bias uniform, so
                -- preserve projection by scaling the shifted view-plane quad.
                if distance>1e-8 then size=size*math.max(0,(distance-z)/distance)end
                -- Positive source Rotation/RotSpeed rotate clockwise on screen.
                local rx,ry,rz=(rx0*cosine-ux0*sine)*size,(ry0*cosine-uy0*sine)*size,(rz0*cosine-uz0*sine)*size
                local ux,uy,uz=(ux0*cosine+rx0*sine)*size,(uy0*cosine+ry0*sine)*size,(uz0*cosine+rz0*sine)*size
                particle_quad(batch,px,py,pz,rx,ry,rz,ux,uy,uz,r,g,b,alpha)
            end
        end
    end
    for reference,batch in pairs(self.batches)do
        -- Keep empty buffers for the next burst of a resident producer, but
        -- release obsolete styles after edits/removal/map retirement. Shared
        -- styles stay owned until their final producer and particles leave.
        if batch.count>0 or self.style_users[reference]then
            self:_upload(batch,batch.texture,self.max_particles*6)
        else
            if batch.mesh then batch.mesh:destroy()end
            self.batches[reference]=nil
        end
    end
    for _,record in ipairs(self.records)do
        if within(record.node,self.world.Workspace)then
            if record.kind=='Trail'then self:_trail_prepare(record,record.props)
            elseif record.kind=='Beam'then self:_beam_prepare(record,record.props,cf)end
        elseif record.batch.mesh then record.batch.mesh:update({},0)end
    end
end
function Effects:prepare_resources(checkpoint)
    local prepared=0
    for index,record in ipairs(self.records)do
        if not record.retired and within(record.node,self.world.Workspace)then
            local p=self:_properties(record)
            local texture,available=self:_image(p.Texture,record,record.kind~='ParticleEmitter')
            assert(available,'Required source effect texture failed: '..tostring(p.Texture))
            local batch,maximum
            if record.kind=='ParticleEmitter'then
                local style=record.particle_style;batch=self.batches[style.key]
                if not batch then batch={vertices={},count=0,texture=texture,light_emission=style.emission,
                    light_influence=style.influence,brightness=style.brightness};self.batches[style.key]=batch end
                maximum=self.max_particles*6
            else
                batch=record.batch;maximum=record.kind=='Trail'and(self.max_samples-1)*6 or 768
                batch.light_emission=clamp(numeric(p.LightEmission,0),0,1)
                batch.light_influence=clamp(numeric(p.LightInfluence,0),0,1);batch.brightness=math.max(0,numeric(p.Brightness,1))
            end
            if not batch.mesh then
                batch.capacity=math.min(maximum,384)
                batch.mesh=self.world:create_world_mesh(batch.capacity,{light_emission=batch.light_emission,
                    light_influence=batch.light_influence,brightness=batch.brightness})
            end
            batch.mesh:prepare();prepared=prepared+1
        end
        if checkpoint then checkpoint('destination:effect-resources',index,#self.records)end
    end
    return prepared
end
function Effects:_remove(record)
    if record.retired then return end
    record.retired=true;self.by_node[record.node]=nil
    record.beam_samples=nil
    local style=record.particle_style
    if style then
        local users=self.style_users[style.key]-1
        self.style_users[style.key]=users>0 and users or nil
        record.particle_style=nil
    end
    if record.property_connection then record.property_connection:Disconnect();record.property_connection=nil end
    if record.batch.mesh then record.batch.mesh:destroy();record.batch.mesh=nil end
end
function Effects:retireMap()
    if self.destroyed then return end
    for i=#self.records,1,-1 do if self.records[i].scope=='map'then self:_remove(self.records[i]);table.remove(self.records,i)end end
    for i=#self.roots,1,-1 do if self.roots[i].scope=='map'then table.remove(self.roots,i)end end
    for i=#self.active,1,-1 do if self.active[i].record.retired then self.active[i].alive=false;table.remove(self.active,i)end end
    self:prepare()
end
function Effects:stats()
    local result={particles=#self.active,instances=#self.records,vertices=0,meshes=0,dropped=self.dropped,unresolved=self.report_total,max_particles=self.max_particles,max_trail_samples=self.max_samples}
    for _,batch in pairs(self.batches)do result.vertices=result.vertices+batch.count;if batch.mesh then result.meshes=result.meshes+1 end end
    for _,record in ipairs(self.records)do result.vertices=result.vertices+record.batch.count;if record.batch.mesh then result.meshes=result.meshes+1 end end
    return result
end
function Effects:destroy()
    if self.destroyed then return end;self.destroyed=true
    if self.observer then self.observer:Disconnect();self.observer=nil end
    for _,record in ipairs(self.records)do self:_remove(record)end
    for _,batch in pairs(self.batches)do if batch.mesh then batch.mesh:destroy()end end
    for _,image in pairs(self.images)do if image then image:release()end end
    self.records={};self.by_node={};self.pending={};self.roots={};self.active={};self.batches={};self.style_users={};self.images={}
end
return Effects
