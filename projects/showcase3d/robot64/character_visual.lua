-- Source-derived vis model, using the selected place's local assets.
-- The sandbox place supplies ReplicatedFirst/vis, so only the public rig
-- path of the port is kept here.
local Animation=require("projects/showcase3d/robot64/character_animation")
local publications=setmetatable({},{__mode="k"})
local Visual={}
Visual.__index=Visual

function Visual.new(world,body,rbx,options)
    options=options or {}
    local self=setmetatable({body=body,rbx=rbx,parts={},by_name={},destroyed=false},Visual)
    local templates,model
    assert(options.public_source,"The sandbox character requires the place's ReplicatedFirst/vis rig")
    model,self.parts,self.by_name,templates,self.faces=require('projects/showcase3d/robot64/public_rig').build(world,rbx,body,assert(options.assets))
    self.templates=templates
    self.idle=Animation.new(rbx);self.idle.templates=templates
    self.model=model
    local ok,err=xpcall(function()
        -- The public face belongs to the actual mesh and follows its
        -- triangle projection, rather than a separate carrier plane.
        self.face=assert(self.by_name.head:FindFirstChild('face'),'Public head face missing')
        self.face.Texture=self.faces['rbxassetid://1451094768']
        self.head_frame=self.by_name.head:FindFirstChild('dcf') or world.Instance.new("CFrameValue",{Name="dcf",Parent=self.by_name.head})
        self.dot_velocity=self.by_name.dot:FindFirstChild('vel') or world.Instance.new("Vector3Value",{Name="vel",Parent=self.by_name.dot})
        -- The rig's authored attachment Beam is the antenna; the Robot
        -- SourceEffects owner draws it.
        self:update_visual(rbx.Vector3.new(0,0,-1),0)
    end,debug.traceback)
    if not ok then model:Destroy();error(err,0) end
    return self
end

-- body_frame optionally replaces the body's pose, e.g. interpolated between
-- physics steps by the host.
function Visual:update_visual(facing,spin,animation,body_frame)
    if self.destroyed or self.body.Parent==nil then return end
    local V,C=self.rbx.Vector3,self.rbx.CFrame
    animation=animation or self.idle
    animation.templates=self.templates
    body_frame=body_frame or self.body.CFrame
    local position=body_frame.Position
    local cache=publications[self]
    if not cache or not rawequal(cache.C,C) or not rawequal(cache.V,V)
        or cache.mul~=C.__mul or cache.sub~=C.__sub or cache.vector~=V.new then
        cache={C=C,V=V,mul=C.__mul,sub=C.__sub,vector=V.new,
            parts=setmetatable({},{__mode="k"})}
        publications[self]=cache
    end
    if getmetatable(body_frame)~=C or not rawequal(cache.body,body_frame) then
        cache.body,cache.root=body_frame,body_frame-V.new(0,1,0)
    end
    local root=cache.root
    local poses=animation:evaluate(self.templates)
    for _,item in ipairs(self.parts) do
        local pose=poses[item.name]
        if pose then
            local entry=cache.parts[item]
            if getmetatable(pose)~=C or not entry
                or not rawequal(entry.root,root) or not rawequal(entry.pose,pose) then
                if not entry then entry={};cache.parts[item]=entry end
                entry.root,entry.pose,entry.frame=root,pose,root*pose
            end
            -- Retain the public write even when its arithmetic is unchanged:
            -- it repairs external edits and preserves notification order.
            item.part.CFrame=entry.frame
        end
    end
    local head=self.by_name.head.CFrame
    if animation.sync_dot then animation:sync_dot(head,animation.scale or V.new(1,1,1),position) end
    local dot=animation.dot_position and animation.dot_position+(position-(animation.last_position or position))
        or head.Position+head.UpVector*(2*(animation.scale and animation.scale.Y or 1))
    self.by_name.dot.CFrame=C.new(dot)
    if self.face_id~=animation.face_id then
        self.face.Texture=assert(self.faces[animation.face_id],"Unknown Beebo face: "..tostring(animation.face_id))
        self.face_id=animation.face_id
    end
    self.dot_velocity.Value=animation.dot_velocity
    self.head_frame.Value=head
end

function Visual:destroy()
    if self.destroyed then return end
    self.destroyed=true
    self.model:Destroy()
end
return Visual
