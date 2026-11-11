-- Passive public templates remain in ReplicatedFirst. Each activation owns a
-- clone, local room debris, indexed interactions and presentation lists.
local Content={};Content.__index=Content
local Source=require('projects/showcase3d/robot64/source')
local Gravity=require('projects/showcase3d/robot64/gravity_policy')
local function child(node,name) return node and node:FindFirstChild(name) end
local function value(node,name,default) local item=child(node,name);if item then return item.Value end;return default end
Content.value=value
function Content.new(world,rbx,session,assets,checkpoint)
    assert(checkpoint==nil or type(checkpoint)=='function','Content checkpoint must be a function')
    Source.prepare(world,rbx,checkpoint)
    Gravity.apply(world)
    local function stage(unit,index,total)if checkpoint then checkpoint('content:'..unit,index,total)end end
    stage('source-ready',1,1)
    local rf=require('projects/showcase3d/robot64/source').service(world,'ReplicatedFirst')
    local maps=assert(child(rf,'maps'),'Public ReplicatedFirst/maps missing')
    -- errorlog's authored-default relocation, resolved by class/service role.
    local default
    for _,node in ipairs(world.Workspace:GetChildren()) do
        if child(node,'spawn') and child(node,'settings') then default=node;node.Parent=maps end
    end
    local self=setmetatable({world=world,rbx=rbx,rf=rf,session=session,assets=assets,
        maps=maps,default=default,templates={},map_order={},generation=0,enemy_revision=0},Content)
    -- The renderer selects the first Sky. Store original Lighting templates
    -- passively so each source map's copy is the only active authored sky.
    self.source_lighting=world.Instance.new('Folder',{Name='RobotSourceLighting',Parent=rf})
    for _,entry in ipairs(world.Lighting:GetChildren()) do
        if entry.ClassName=='Sky' then entry.Parent=self.source_lighting end
    end
    for _,map in ipairs(maps:GetChildren()) do
        assert(not self.templates[map.Name],'Duplicate map identity '..map.Name)
        self.templates[map.Name]=map;self.map_order[#self.map_order+1]=map.Name
    end
    stage('templates-ready',#self.map_order,#self.map_order)
    return self
end
function Content:retire()
    if self.audio then self.audio:retire()end
    self.generation=self.generation+1
    self.enemy_revision=self.enemy_revision+1
    local shared=self._spin_shared_pose_state
    if shared then
        local core=rawget(self.world,'_core')
        if core and core._clear_shared_instanced_group_pose then
            core:_clear_shared_instanced_group_pose(shared.group,true)
        end
        self._spin_shared_pose_state=nil
    end
    if self.active then self.active:Destroy();self.active=nil end
    if self.rooms then self.rooms:Destroy();self.rooms=nil end
    self.triggers={};self.spin={};self.moving={};self.actors={};self.marker_replacements={}
    if not self.audio then for _,name in ipairs({'bgm','bgmW','bgmA','bgmC','bgmP'})do self.assets:stop(name)end end
    for _,node in ipairs(self.world.Lighting:GetChildren()) do if node.Name=='copy' then node:Destroy() end end
end
function Content:is_active(node)
    return node and node.Parent and self.active and (node==self.active or node:IsDescendantOf(self.active)) or false
end
function Content:set_room(room,active)
    assert(room and Source.live(room,Source.lifetime(room)),'Cannot activate a retired public room')
    local parent=active and self.active or self.rooms
    if room.Parent~=parent then room.Parent=parent;self.enemy_revision=self.enemy_revision+1 end
    if active and self.tree_collision then self.tree_collision:apply(room)end
    self.room=active and room.Name or nil
end
function Content:retire_collider(col)
    if self.triggers then self.triggers[col]=nil end
    self.enemy_revision=self.enemy_revision+1
end
function Content:_pickup(marker,name)
    local template=assert(child(self.rf,name),'Missing public pickup template '..name)
    local item=Source.clone(template,self.world,self.rbx);item.CFrame=self.rbx.CFrame.new(marker.Position)
    if name=='vanilcream' then item.Name='icedcream' end
    if child(item,'pos') then item.pos.Value=marker.Position end
    for _,key in ipairs({'id','desc'}) do
        if child(marker,key) and child(item,key) then item[key].Value=marker[key].Value end
    end
    item.Parent=marker.Parent;self.marker_replacements[marker]=item;marker:Destroy()
    self.spin[#self.spin+1]={part=item,origin=item.CFrame};self.triggers[item]=true
    return item
end
function Content:_index(map)
    -- clouds use the controller's top probes, leaving their underside open
    for _, part in ipairs(map:GetDescendants()) do
        if part:IsA('BasePart') and (part.Name == 'cloudy' or part.Name == 'weakcloudy') then
            part.CanCollide = false
            part.CanQuery = true
        end
    end
    while child(map,'GROUP') do
        local group=map.GROUP
        for _,node in ipairs(group:GetChildren()) do node.Parent=map end
        group:Destroy()
    end
    for _,node in ipairs(map:GetChildren()) do
        local name=node.Name
        if name=='candy2' then
            for i=1,6 do
                local candy=Source.clone(self.rf.candy,self.world,self.rbx)
                candy.CFrame=self.rbx.CFrame.new((node.CFrame*self.rbx.CFrame.Angles(0,i/6*math.pi*2,0)*self.rbx.CFrame.new(0,0,-node.Size.X)).Position)
                if child(candy,'pos') then candy.pos.Value=candy.Position end
                candy.Parent=map;self.spin[#self.spin+1]={part=candy,origin=candy.CFrame};self.triggers[candy]=true
            end
            node:Destroy()
        elseif name=='candy' or name=='hcandy' or name=='egg' or name=='battery' then self:_pickup(node,name)
        elseif name=='jetpack'or name=='skateboard'or name=='flamethrower'then
            local visual=assert(child(node,'vis'),'Public equipment visual missing: '..name)
            assert(child(visual,'pos'),'Public equipment visual has no source position').Value=node.Position
            self.spin[#self.spin+1]={part=visual,origin=self.rbx.CFrame.new(node.Position)}
        elseif name=='icedcream' then
            local collected=self.session:has_collectible(value(node,'id'))
            local postgame=child(node,'postgame')
            if postgame and not self.session:has_collectible(54) then node:Destroy()
            else self:_pickup(node,collected and 'notcream' or postgame and 'vanilcream' or 'icedcream') end
        elseif name:sub(1,6)=='unlock' then
            local required=tonumber(name:sub(7))
            if required and (self.session.state.progress or 0)>=required then node:Destroy() end
        elseif name=='enemy' then
            -- ModuleScript is source evidence only; factories own per-enemy state.
            local family=value(node,'id')
            local template=child(child(self.rf,'enemies'),family)
            assert(template,'Unknown public enemy '..tostring(family))
            local model=Source.clone(template,self.world,self.rbx);model.col.CFrame=node.CFrame;model.Parent=map;node:Destroy()
            self.enemy_models=self.enemy_models or {};self.enemy_models[#self.enemy_models+1]={model=model,family=family,root=map}
            self.enemy_revision=self.enemy_revision+1
            self.triggers[model.col]=true
        elseif name=='door' and child(node,'load') then
            local room=node.load.Value
            assert(room,'Door room referent missing')
            room.Parent=self.rooms;self.triggers[node]=true
        elseif node:IsA('BasePart') and (name=='door' or name=='TeleMap' or name=='lava' or name=='kill' or name=='water'
            or name=='battery' or name=='breakable' or name=='bounds' or name=='bounds2'
            or name:sub(1,3)=='TPa' or child(node,'tx')) then self.triggers[node]=true
        end
    end
    local moving=child(map,'moving')
    if moving then for _,part in ipairs(moving:GetChildren()) do
        if part:IsA('BasePart') then
            if child(part,'endo') then
                if child(part,'start') then part.start.Value=part.Position end
                part.endo.Value=part.Position+part.endo.Value
                self.moving[#self.moving+1]={part=part,origin=part.CFrame,start=part.Position,finish=part.endo.Value}
            elseif child(part,'start') then part.start.Value=part.Position end
        end
    end end
end
-- Build destination collision on a detached source clone. Source membership,
-- registries and player pose remain intact until this succeeds.
function Content:prepare_destination(name,options,prepare)
    local template=options.map or assert(self.templates[name],'Unknown public map '..tostring(name))
    local stage=options.stage;local loading=stage and stage:loading_context()
    local map=options.prepared_map or options.map or Source.clone(template,self.world,self.rbx,loading)
    if stage then stage.prepared_map=map end
    local ok,result=pcall(function()
        assert(child(map,'settings'),'Public map settings missing: '..name)
        assert(options.position or child(map,'spawn'),'Public map has no spawn or transition position: '..name)
        return prepare(map)
    end)
    if not ok then
        if not options.map then map:Destroy()end
        if stage then stage.prepared_map=nil end
        error(result,0)
    end
    return map,result
end
function Content:activate(name,options)
    options=options or {};local template=options.map or assert(self.templates[name],'Unknown public map '..tostring(name))
    local loading=options.stage and options.stage.loading_context and options.stage:loading_context()
    local map=options.prepared_map or options.map or Source.clone(template,self.world,self.rbx,loading)
    local spawn=child(map,'spawn');local spawn_frame=spawn and spawn.CFrame
    self:retire();self.enemy_models={}
    self.rooms=self.world.Instance.new('Folder',{Name='RobotLocalRooms',Parent=self.rf})
    self.active=map;map.Parent=self.world.Workspace
    if options.stage then options.stage.prepared_map=nil end
    self.spawn=spawn_frame;self.safe=spawn_frame;self.room=nil
    self:_index(map)
    if spawn then spawn:Destroy() end
    local settings=assert(child(map,'settings'),'Public map settings missing: '..name)
    Gravity.apply(self.world,settings)
    self.onejump=child(settings,'onejump')~=nil
    local lighting=child(settings,'lighting')
    if lighting then for _,entry in ipairs(lighting:GetChildren()) do
        if entry.ClassName=='Sky' then
            local sky=Source.clone(entry,self.world,self.rbx);sky.Name='copy';sky.Parent=self.world.Lighting
            if self.session:has_collectible(54)then sky.SunTextureId='rbxasset://sky/sun.jpg'end
        elseif entry.ClassName:match('Value$') then self.world.Lighting[entry.Name]=entry.Value end
    end end
    if self.session.nightmode then self.world.Lighting.TimeOfDay=0;self.world.Lighting.FogColor=self.rbx.Color3.new(0,0,0)end
    if not self.audio then for _,name_audio in ipairs({'bgm','bgmW','bgmA','bgmC','bgmP'}) do
        local id=value(settings,name_audio)
        if id then self.assets:play(name_audio,'rbxassetid://'..tostring(id),name_audio=='bgm' and .5 or 0,true) end
    end end
    if options.room then
        local room=child(self.rooms,options.room);assert(room,'Unknown local room '..options.room)
        self:set_room(room,true)
    end
    return map,options.position or (spawn_frame and spawn_frame.Position)
end

local SPIN_POSE_EPSILON=1e-6
local function close_spin_pose(a,b) return math.abs(a-b)<=SPIN_POSE_EPSILON end
local function core_handle(part)
    return type(part)=='table' and (rawget(part,'_core_handle') or part) or nil
end
local function same_spin_basis(frame,base,translation_x,translation_y,translation_z,origin_x,origin_y,origin_z)
    return frame and close_spin_pose(frame.x,translation_x+origin_x)
        and close_spin_pose(frame.y,translation_y+origin_y)
        and close_spin_pose(frame.z,translation_z+origin_z)
        and close_spin_pose(frame.r00,base.r00) and close_spin_pose(frame.r01,base.r01)
        and close_spin_pose(frame.r02,base.r02) and close_spin_pose(frame.r10,base.r10)
        and close_spin_pose(frame.r11,base.r11) and close_spin_pose(frame.r12,base.r12)
        and close_spin_pose(frame.r20,base.r20) and close_spin_pose(frame.r21,base.r21)
        and close_spin_pose(frame.r22,base.r22)
end

function Content:_build_spin_shared_pose_state(core)
    if not core or core._shared_instance_pose_supported~=true then return nil end
    local group,members,facades,origins,member_lookup,rows=nil,{},{},{},{},{}
    local member_count=0
    for index=1,#self.spin do
        local item=self.spin[index];local facade=item and item.part
        if facade and self:is_active(facade) then
            local part=core_handle(facade);local ref=part and part._instanced_ref
            if ref and ref.fast==true and ref.group then
                if group and group~=ref.group then return nil end
                group=ref.group
                local row=tonumber(ref.row)
                local origin=item.origin and item.origin.Position
                if not row or row<1 or row~=math.floor(row) or rows[row]
                    or not origin then return nil end
                rows[row]=true;members[row]=part;facades[row]=facade
                origins[row]={origin.x,origin.y,origin.z};member_lookup[part]=true
                member_count=member_count+1
            end
        end
    end
    local count=group and math.floor(tonumber(group.count) or 0) or 0
    if not group or group.generation~=(core._instance_generation or 0)
        or group.variant~='fast' or group.projected~=nil or group.light_cell_key~=nil
        or member_count~=count or count<2 then return nil end
    for row=1,count do if not rows[row] or not members[row] then return nil end end
    local base=members[1].CFrame;local first_origin=origins[1]
    if not base or not first_origin then return nil end
    local translation_x,translation_y,translation_z=base.x-first_origin[1],base.y-first_origin[2],base.z-first_origin[3]
    for row=1,count do
        local frame=members[row].CFrame;local origin=origins[row]
        if not same_spin_basis(frame,base,translation_x,translation_y,translation_z,origin[1],origin[2],origin[3]) then
            return nil
        end
    end
    return {group=group,generation=core._instance_generation or 0,spin_count=#self.spin,
        active_root=self.active,members=members,facades=facades,origins=origins,member_lookup=member_lookup,
        member_count=count,base_cframe=base,base_translation_x=translation_x,
        base_translation_y=translation_y,base_translation_z=translation_z,
        pose_epoch=group._shared_instance_pose_epoch or 0}
end

function Content:_spin_shared_pose_state_is_live(state,core)
    if not state or not core or state.generation~=(core._instance_generation or 0)
        or state.group.generation~=(core._instance_generation or 0)
        or state.active_root~=self.active or state.spin_count~=#self.spin then return false end
    for row=1,state.member_count do
        local facade=state.facades[row]
        if not facade or not facade.Parent then return false end
    end
    return true
end

function Content:_begin_spin_shared_pose(basis)
    local world=self.world
    local core=type(world)=='table' and rawget(world,'_core') or nil
    if not core or core._shared_instance_pose_supported~=true
        or not core._begin_shared_instanced_group_pose then return nil,nil end
    local state=self._spin_shared_pose_state
    if not self:_spin_shared_pose_state_is_live(state,core) then
        if state and core._clear_shared_instanced_group_pose then
            core:_clear_shared_instanced_group_pose(state.group,true)
        end
        state=self:_build_spin_shared_pose_state(core)
        self._spin_shared_pose_state=state
    end
    if not state then return nil,nil end
    local pose=core:_begin_shared_instanced_group_pose(state,basis)
    if not pose and state.pose_epoch~=(state.group._shared_instance_pose_epoch or 0) then
        self._spin_shared_pose_state=nil
        state=self:_build_spin_shared_pose_state(core)
        if state then
            self._spin_shared_pose_state=state
            pose=core:_begin_shared_instanced_group_pose(state,basis)
        end
    end
    return pose,state
end

function Content:_finish_spin_shared_pose(pose,state,basis)
    local complete=pose~=nil and state~=nil
    if complete then
        for row=1,state.member_count do
            local frame=state.members[row].CFrame;local origin=state.origins[row]
            if not same_spin_basis(frame,basis,basis.x,basis.y,basis.z,origin[1],origin[2],origin[3]) then
                complete=false;break
            end
        end
    end
    local world=self.world
    local core=type(world)=='table' and rawget(world,'_core') or nil
    local retained=core and core._end_shared_instanced_group_pose
        and core:_end_shared_instanced_group_pose(pose,complete)
    if retained~=true then self._spin_shared_pose_state=nil end
    return retained==true
end

-- The Good edition poses spinners within 60 studs of the camera every frame
-- and the rest every fifth frame at full quality (CharacterScript 3856-3858,
-- 3982-3985); camera_position is the published camera's position.
local SPIN_RANGE,SPIN_CADENCE=60,5
function Content:update_presentation(dt,camera_position)
    self.presentation_time=(self.presentation_time or 0)+dt
    self.spin_frame=(self.spin_frame or 0)+1
    local all_frame=self.spin_frame%SPIN_CADENCE==0 or not camera_position
    local basis,shared_pose,shared_state
    if #self.spin>0 then
        local t=self.presentation_time
        basis=self.rbx.CFrame.Angles(math.sin(t*5)/3,t*5,math.cos(t*5)/3)
            +self.rbx.Vector3.new(0,math.sin(t*2)/2,0)
        shared_pose,shared_state=self:_begin_spin_shared_pose(basis)
    end
    local cx,cy,cz
    if camera_position then cx,cy,cz=camera_position.X,camera_position.Y,camera_position.Z end
    for i=#self.spin,1,-1 do
        local item=self.spin[i]
        local near=all_frame
        if not near then
            local o=item.origin.Position
            local dx,dy,dz=o.X-cx,o.Y-cy,o.Z-cz
            near=dx*dx+dy*dy+dz*dz<SPIN_RANGE*SPIN_RANGE
        end
        if not item.part.Parent then table.remove(self.spin,i)
        elseif near and self:is_active(item.part) then
            local t=self.presentation_time
            if not basis then
                basis=self.rbx.CFrame.Angles(math.sin(t*5)/3,t*5,math.cos(t*5)/3)
                    +self.rbx.Vector3.new(0,math.sin(t*2)/2,0)
            end
            item.part.CFrame=basis+item.origin.Position
        end
    end
    if shared_pose then self:_finish_spin_shared_pose(shared_pose,shared_state,basis) end
end
function Content:destroy() self:retire() end
return Content
