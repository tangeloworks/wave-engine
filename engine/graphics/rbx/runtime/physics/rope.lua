-- Attachment distance constraints. Numeric rows and dependency indices survive
-- pose updates, retaining solver history without scanning every constraint
-- Roblox contracts: https://create.roblox.com/docs/physics/constraints/rope
-- https://create.roblox.com/docs/physics/constraints/rod
local Rope = {}
local Integrate = runtime_require("physics/integrate.lua")
Rope.slop=1e-4
Rope.velocity_slop=1e-6
Rope.angular_slop=1e-4
local defaults={
    RopeConstraint={Enabled=true,Length=5,Restitution=0,WinchEnabled=false,Visible=false,Thickness=.1},
    RodConstraint={Enabled=true,Length=5,LimitsEnabled=false,LimitAngle0=45,LimitAngle1=45,Visible=false,Thickness=.1},
}
local pose_keys={Parent=true,Destroy=true,CFrame=true,Position=true,Orientation=true,Anchored=true,Size=true}
local physics_keys={Attachment0=true,Attachment1=true,Enabled=true,Length=true,Restitution=true,
    WinchEnabled=true,LimitsEnabled=true,LimitAngle0=true,LimitAngle1=true,Parent=true,Destroy=true}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function workspace(node)
    while node do
        if rawget(node,"_destroyed") then return false end
        if rawget(node,"_class_name")=="Workspace" then return true end
        node=rawget(node,"_parent")
    end
    return false
end
local function dirty(core,c)
    core._rope_dirty=core._rope_dirty or {}
    if core._rope_dirty[c] then return end
    core._rope_dirty[c]=true;rawset(c,"_rope_needs_wake",true)
    local w=core._physics_world;local r=rawget(c,"_rope_row")
    if w and r then
        if not r.ba.is_static then r.ba._rope_wake_pending=true end
        if not r.bb.is_static then r.bb._rope_wake_pending=true end
        if r.ba.sleeping and not r.ba.is_static then w:wake_body(r.ba) end
        if r.bb.sleeping and not r.bb.is_static then w:wake_body(r.bb) end
    end
end
function Rope.invalidate(core,node)
    if not core then return end
    local changed=false
    if not node then
        for c in pairs(core._rope_instances or {}) do dirty(core,c);changed=true end
    else
        if (core._rope_instances or {})[node] then dirty(core,node);changed=true end
        for c in pairs((core._rope_dependencies or {})[node] or {}) do dirty(core,c);changed=true end
    end
    if changed then core._rope_revision=(core._rope_revision or 0)+1 end
end
function Rope.track(node)
    if not defaults[rawget(node,"_class_name")] then return end
    local core=rawget(node,"_core");if not core then return end
    core._rope_instances=core._rope_instances or {}
    if not core._rope_instances[node] then
        core._rope_instances[node]=true;core._rope_registry_revision=(core._rope_registry_revision or 0)+1
    end
    Rope.invalidate(core,node)
end
function Rope.changed(node,key)
    local core=rawget(node,"_core")
    if not core or not core._rope_instances or not next(core._rope_instances) then return end
    if (defaults[rawget(node,"_class_name")] and physics_keys[key])
        or ((core._rope_dependencies or {})[node] and pose_keys[key]) then Rope.invalidate(core,node) end
end
local function unwatch(core,c)
    for n in pairs(rawget(c,"_rope_dependencies") or {}) do
        local dependents=(core._rope_dependencies or {})[n]
        if dependents then
            dependents[c]=nil
            if not next(dependents) then core._rope_dependencies[n]=nil end
        end
    end
end
function Rope.destroy(node)
    local core=rawget(node,"_core");Rope.changed(node,"Destroy")
    if core and core._rope_instances and core._rope_instances[node] then
        unwatch(core,node);core._rope_instances[node]=nil
        core._rope_registry_revision=(core._rope_registry_revision or 0)+1
    end
    rawset(node,"_rope_dependencies",nil);rawset(node,"_rope_row",nil)
end
function Rope.resolve(node,value)
    if type(value)=="number" or type(value)=="string" then
        local dm=rawget(node,"_datamodel");return dm and dm._instance_by_referent[value]
    end
    if type(value)=="table" and rawget(value,"_class_name") then return value end
end
function Rope.public_value(node,key)
    local defs=defaults[rawget(node,"_class_name")];if not defs then return false end
    local p=rawget(node,"_properties")
    if key=="Attachment0" or key=="Attachment1" then return true,Rope.resolve(node,p[key]) end
    if defs[key]~=nil then if p[key]~=nil then return true,p[key] end;return true,defs[key] end
    local d=rawget(node,"_rope_diagnostic")
    if key=="Active" then return true,d and d.status=="bound" or false end
    if key=="CurrentDistance" then return true,d and d.distance or 0 end
    return false
end
function Rope.write(node,key,value)
    local cls=rawget(node,"_class_name");local defs=defaults[cls];if not defs then return false end
    if key=="Active" or key=="CurrentDistance" then error(key.." is read-only",3) end
    if key=="Attachment0" or key=="Attachment1" then
        if value~=nil and (type(value)~="table" or rawget(value,"_class_name")~="Attachment"
            or rawget(value,"_datamodel")~=rawget(node,"_datamodel")) then error(key.." must be an Attachment in this DataModel or nil",3) end
    elseif defs[key]==nil then return false
    elseif type(defs[key])=="boolean" then
        if type(value)~="boolean" then error(key.." must be boolean",3) end
    elseif not finite(value) or value<0 or (key=="Restitution" and value>1)
        or ((key=="LimitAngle0" or key=="LimitAngle1") and value>180) then error("invalid "..cls.."."..key,3) end
    local p=rawget(node,"_properties");if p[key]==value then return true end
    p[key]=value;if physics_keys[key] then Rope.changed(node,key) end
    return true
end
local function watch_ancestors(node,deps)
    -- Detached ancestors stay observable so returning them to Workspace rebinds
    while node do deps[node]=true;node=rawget(node,"_parent") end
end
local function attachment_anchor(a,w,deps)
    watch_ancestors(a,deps)
    if not a or rawget(a,"_destroyed") or not workspace(a) then return nil,"missing/outside-Workspace attachment" end
    if rawget(a,"_class_name")=="Bone" then return nil,"Bone transform unsupported" end
    if rawget(a,"_class_name")~="Attachment" then return nil,"endpoint is not an Attachment" end
    local local_cf=CFrame.new();local chain={};local at=a
    while at do
        deps[at]=true;chain[#chain+1]={referent=rawget(at,"_referent"),class=rawget(at,"_class_name"),name=rawget(at,"_name")}
        local cls=rawget(at,"_class_name")
        if cls=="Bone" then return nil,"Bone transform unsupported" end
        if cls=="Attachment" then local_cf=at.CFrame*local_cf
        elseif rawget(at,"_core_handle_id") then
            local asm=w.part_to_assembly[rawget(at,"_core_handle_id")]
            if not asm or not asm.body then return nil,"body/assembly unavailable" end
            local world_cf=at.CFrame*local_cf;local b=asm.body
            local x,y,z=world_cf.X,world_cf.Y,world_cf.Z
            if not finite(x) or not finite(y) or not finite(z) then return nil,"non-finite anchor" end
            local lx,ly,lz=Integrate.rotate_vec(b.qw,-b.qx,-b.qy,-b.qz,x-b.com_x,y-b.com_y,z-b.com_z)
            local axis=world_cf.RightVector
            local ux,uy,uz=Integrate.rotate_vec(b.qw,-b.qx,-b.qy,-b.qz,axis.X,axis.Y,axis.Z)
            local ancestor=rawget(at,"_parent")
            while ancestor do
                deps[ancestor]=true;chain[#chain+1]={referent=rawget(ancestor,"_referent"),class=rawget(ancestor,"_class_name"),name=rawget(ancestor,"_name")}
                ancestor=rawget(ancestor,"_parent")
            end
            return {body=b,lx=lx,ly=ly,lz=lz,ux=ux,uy=uy,uz=uz,part=rawget(at,"_referent"),part_id=rawget(at,"_core_handle_id"),
                attachment=rawget(a,"_referent"),chain=chain,local_position={local_cf.X,local_cf.Y,local_cf.Z},world_position={x,y,z}}
        end
        at=rawget(at,"_parent")
    end
    return nil,"no ancestor BasePart"
end
function Rope.geometry(r)
    local a,b=r.ba,r.bb
    r.rax,r.ray,r.raz=Integrate.rotate_vec(a.qw,a.qx,a.qy,a.qz,r.a.lx,r.a.ly,r.a.lz)
    r.rbx,r.rby,r.rbz=Integrate.rotate_vec(b.qw,b.qx,b.qy,b.qz,r.b.lx,r.b.ly,r.b.lz)
    local dx=b.com_x+r.rbx-a.com_x-r.rax;local dy=b.com_y+r.rby-a.com_y-r.ray;local dz=b.com_z+r.rbz-a.com_z-r.raz
    local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
    r.distance=distance;r.diagnostic.distance=distance
    if distance>1e-10 then r.nx,r.ny,r.nz=dx/distance,dy/distance,dz/distance;return true end
    if r.length==0 then
        dx=b.vx+b.wy*r.rbz-b.wz*r.rby-a.vx-a.wy*r.raz+a.wz*r.ray
        dy=b.vy+b.wz*r.rbx-b.wx*r.rbz-a.vy-a.wz*r.rax+a.wx*r.raz
        dz=b.vz+b.wx*r.rby-b.wy*r.rbx-a.vz-a.wx*r.ray+a.wy*r.rax
        local speed=math.sqrt(dx*dx+dy*dy+dz*dz)
        if speed>Rope.velocity_slop then r.nx,r.ny,r.nz=dx/speed,dy/speed,dz/speed;return true end
        r.nx,r.ny,r.nz=r.nx or 1,r.ny or 0,r.nz or 0
        return true
    end
    if r.kind=="rod" and r.length>0 then
        -- Compressed coincident ends retain their previous direction, or the
        -- first attachment primary axis on initial bind
        if not r.nx then r.nx,r.ny,r.nz=Integrate.rotate_vec(a.qw,a.qx,a.qy,a.qz,r.a.ux,r.a.uy,r.a.uz) end
        return true
    end
    return false
end
local function diagnostic_anchor(a)
    return a and {attachment=a.attachment,part=a.part,part_id=a.part_id,body_id=a.body.id,assembly_id=a.body.id,
        static=a.body.is_static,chain=a.chain,local_position=a.local_position,world_position=a.world_position}
end
local function bind(core,w,c)
    local rod=rawget(c,"_class_name")=="RodConstraint"
    local previous=rawget(c,"_rope_row");local d=rawget(c,"_rope_diagnostic") or {}
    d.referent=rawget(c,"_referent");d.kind=rod and "rod" or "rope";d.enabled=c.Enabled;d.length=c.Length
    d.restitution=not rod and c.Restitution or 0;d.winch=not rod and c.WinchEnabled or false;d.reason=nil
    rawset(c,"_rope_diagnostic",d);unwatch(core,c)
    local deps={};rawset(c,"_rope_dependencies",deps);watch_ancestors(c,deps)
    local a,ea=attachment_anchor(c.Attachment0,w,deps);local b,eb=attachment_anchor(c.Attachment1,w,deps)
    for n in pairs(deps) do
        local dependents=core._rope_dependencies[n] or {};core._rope_dependencies[n]=dependents;dependents[c]=true
    end
    d.a=diagnostic_anchor(a);d.b=diagnostic_anchor(b);d.resolved=a~=nil and b~=nil
    local r
    if not workspace(c) then d.status="outside_workspace"
    elseif not a or not b then d.status="unresolved";d.reason=ea or eb
    elseif not finite(c.Length) or c.Length<0 or not finite(d.restitution) or d.restitution<0 or d.restitution>1
        or (rod and (not finite(c.LimitAngle0) or c.LimitAngle0<0 or c.LimitAngle0>180
            or not finite(c.LimitAngle1) or c.LimitAngle1<0 or c.LimitAngle1>180)) then d.status="invalid_parameters"
    elseif d.winch then d.status="unsupported_winch"
    elseif not c.Enabled then d.status="disabled"
    else
        local compatible=previous and previous.ba==a.body and previous.bb==b.body
            and previous.length==c.Length and previous.a.attachment==a.attachment and previous.b.attachment==b.attachment
        r=compatible and previous or {owner=c,impulse=0}
        r.ba,r.bb,r.a,r.b=a.body,b.body,a,b;r.kind=d.kind;r.length=c.Length;r.restitution=d.restitution;r.diagnostic=d
        r.limits_enabled=rod and c.LimitsEnabled or false
        r.limit0=rod and math.rad(c.LimitAngle0) or math.pi;r.limit1=rod and math.rad(c.LimitAngle1) or math.pi
        Rope.geometry(r)
        if a.body==b.body then d.status="same_body";r=nil
        elseif a.body.inv_mass==0 and b.body.inv_mass==0 then d.status="immovable";r=nil
        else
            d.status="bound"
            if rawget(c,"_rope_needs_wake") then
                if not a.body.is_static then a.body._rope_wake_pending=true end
                if not b.body.is_static then b.body._rope_wake_pending=true end
                if a.body.sleeping and not a.body.is_static then w:wake_body(a.body) end
                if b.body.sleeping and not b.body.is_static then w:wake_body(b.body) end
            end
        end
    end
    rawset(c,"_rope_row",r);rawset(c,"_rope_needs_wake",nil)
    w.rope_rebind_count=(w.rope_rebind_count or 0)+1
    return r~=previous
end
function Rope.sync(core,w)
    local revision=core._rope_revision or 0;local registry=core._rope_registry_revision or 0
    local topology=w._rope_bound_topology~=w._rope_topology_revision
    local structural=w._rope_bound_registry~=registry or not w._rope_nodes
    if not structural and not topology and w._rope_bound_revision==revision then return end
    core._rope_dependencies=core._rope_dependencies or {}
    if structural then
        local nodes={};for c in pairs(core._rope_instances or {}) do nodes[#nodes+1]=c end
        table.sort(nodes,function(a,b) return tostring(rawget(a,"_referent") or a)<tostring(rawget(b,"_referent") or b) end)
        w._rope_nodes=nodes
    end
    local list_changed=structural or topology
    if topology then
        for _,c in ipairs(w._rope_nodes) do bind(core,w,c) end
    else
        for c in pairs(core._rope_dirty or {}) do
            if (core._rope_instances or {})[c] and not rawget(c,"_destroyed") then
                if bind(core,w,c) then list_changed=true end
            end
        end
    end
    if list_changed then
        local rows,diagnostics={},{}
        for _,c in ipairs(w._rope_nodes) do
            local r=rawget(c,"_rope_row");if r then rows[#rows+1]=r end
            local d=rawget(c,"_rope_diagnostic");if d then diagnostics[#diagnostics+1]=d end
        end
        w.ropes=rows;w.rope_diagnostics=diagnostics
    end
    core._rope_dirty={};w._rope_bound_revision=revision;w._rope_bound_registry=registry
    w._rope_bound_topology=w._rope_topology_revision
end
local function moving(b,after_forces)
    if b.is_static or b.sleeping then return false end
    local y=b.vy-(after_forces and b._step_gravity_vy or 0)
    local radius=b:bounding_radius()
    -- Connected-neighbour linear wake threshold documented by Roblox:
    -- https://create.roblox.com/docs/physics/sleep-system
    return b.vx*b.vx+y*y+b.vz*b.vz>.48*.48
        or (b.wx*b.wx+b.wy*b.wy+b.wz*b.wz)*radius*radius>.59*.59
end
function Rope.wake(w,dt,after_forces)
    -- a quiet awake neighbour must not restart a resting chain's sleep timer
    for _=1,#(w.ropes or {}) do
        local changed=false
        for _,r in ipairs(w.ropes) do
            -- Fully awake links need no activation work. keep pending links in
            -- the traversal so a wake still propagates through a whole chain
            if r.ba.sleeping or r.bb.sleeping or r.ba._rope_wake_pending or r.bb._rope_wake_pending then
                Rope.geometry(r)
                local err=r.distance-r.length
                local strained=(r.kind=="rod" and math.abs(err) or err)>Rope.slop*4
                local a,b=r.ba,r.bb
                local vx=b.vx+b.wy*r.rbz-b.wz*r.rby-a.vx-a.wy*r.raz+a.wz*r.ray
                local vy=b.vy+b.wz*r.rbx-b.wx*r.rbz-a.vy-a.wz*r.rax+a.wx*r.raz
                local vz=b.vz+b.wx*r.rby-b.wy*r.rbx-a.vz-a.wx*r.ray+a.wy*r.rax
                local reaches_limit=err+(vx*r.nx+vy*r.ny+vz*r.nz)*(dt or 0)>=-Rope.slop
                if (r.kind=="rod" or reaches_limit or err>=-Rope.slop) and (strained
                    or r.ba._rope_wake_pending or r.bb._rope_wake_pending
                    or moving(r.ba,after_forces) or moving(r.bb,after_forces)) then
                    if not r.ba.is_static and not r.ba._rope_wake_pending then r.ba._rope_wake_pending=true;changed=true end
                    if not r.bb.is_static and not r.bb._rope_wake_pending then r.bb._rope_wake_pending=true;changed=true end
                    if not r.ba.is_static and r.ba.sleeping then w:wake_body(r.ba,true);changed=true end
                    if not r.bb.is_static and r.bb.sleeping then w:wake_body(r.bb,true);changed=true end
                end
            end
        end
        if not changed then break end
    end
    for _,r in ipairs(w.ropes or {}) do r.ba._rope_wake_pending=nil;r.bb._rope_wake_pending=nil end
end
return Rope
