-- batch rigid shadow casters that share a texture
-- the pose table lets each caster move without rebuilding the mesh
local ShadowPoseBatch={}
local shadow_array=require('engine/graphics/rbx/runtime/shadow_array')
local MAX_POSES=12
local MIN_SOURCES=4
local MIN_VERTICES=768
local ZERO={0,0,0,0}
local format={{'VertexPosition','float',3},{'VertexTexCoord','float',2},
    {'VertexColor','float',4},{'ShadowPoseIndex','float',1}}
local format_cache=setmetatable({},{__mode='k'})

local function release_entry(entry)
    local mesh=entry and entry.command and entry.command.mesh
    if mesh then pcall(mesh.release,mesh) end
end

function ShadowPoseBatch.release(core)
    for _,entry in ipairs(core._directional_shadow_pose_batch_cache or {}) do
        release_entry(entry)
    end
    core._directional_shadow_pose_batch_cache=nil
end

function ShadowPoseBatch.enabled(core)
    return core.directional_shadow_pose_batch~=false
end

local function has_supported_format(mesh)
    local cached=format_cache[mesh]
    if cached~=nil then return cached or nil end
    local ok,source=pcall(mesh.getVertexFormat,mesh)
    if not ok or type(source)~='table' then
        format_cache[mesh]=false
        return nil
    end
    local expected={{'VertexPosition','float',3},{'VertexNormal','float',3},
        {'VertexTexCoord','float',2},{'VertexColor','float',4}}
    for index,wanted in ipairs(expected) do
        local actual=source[index]
        if type(actual)~='table' or actual[1]~=wanted[1]
            or actual[2]~=wanted[2] or actual[3]~=wanted[3] then
            format_cache[mesh]=false
            return nil
        end
    end
    format_cache[mesh]=true
    return true
end

local function source(command,index)
    if command.shadow_static_member==true or command.kind~='textured'
        or command.alpha_test~=true or command.unstable_shadow_index_map
        or command.ranges and #command.ranges>0 or not command.rigid_pose
        or not command.mesh then
        return nil
    end
    local mesh=command.mesh
    local vertex_map=mesh:getVertexMap()
    if mesh:getDrawMode()~='triangles' or (vertex_map and #vertex_map>0)
        or not has_supported_format(mesh) then
        return nil
    end
    local vertices=mesh:getVertexCount()
    if vertices<3 or vertices%3~=0 then return nil end
    local texture=mesh:getTexture()
    if not texture or (texture.getTextureType
        and texture:getTextureType()~='2d') then
        return nil
    end
    return {command=command,index=index,mesh=mesh,texture=texture,
        vertices=vertices,version=shadow_array.version(mesh),
        alpha_threshold=command.alpha_threshold or 0,
        ignore_texture_alpha=command.ignore_texture_alpha==true,
        flip_u=command.flip_u==true,flip_v=command.flip_v==true}
end

local function compatible(a,b)
    return a.texture==b.texture
        and a.alpha_threshold==b.alpha_threshold
        and a.ignore_texture_alpha==b.ignore_texture_alpha
        and a.flip_u==b.flip_u and a.flip_v==b.flip_v
end

local function same_geometry(entry,group)
    if entry.texture~=group.sources[1].texture
        or entry.alpha_threshold~=group.sources[1].alpha_threshold
        or entry.ignore_texture_alpha~=group.sources[1].ignore_texture_alpha
        or entry.flip_u~=group.sources[1].flip_u
        or entry.flip_v~=group.sources[1].flip_v then
        return false
    end
    local old=entry._shadow_pose_batch_sources or {}
    if #old~=#group.sources then return false end
    for index,source_row in ipairs(group.sources) do
        local prior=old[index]
        if not prior or prior.mesh~=source_row.mesh
            or prior.version~=source_row.version
            or prior.vertices~=source_row.vertices then
            return false
        end
    end
    return true
end

local function snapshot(group,command)
    local sources={}
    for index,source_row in ipairs(group.sources) do
        sources[index]={mesh=source_row.mesh,version=source_row.version,
            vertices=source_row.vertices}
    end
    local first=group.sources[1]
    return {command=command,texture=first.texture,
        alpha_threshold=first.alpha_threshold,
        ignore_texture_alpha=first.ignore_texture_alpha,
        flip_u=first.flip_u,flip_v=first.flip_v,
        _shadow_pose_batch_sources=sources}
end

local function build(group)
    local temporary={}
    local ok,result=xpcall(function()
        local data=love.data.newByteData(group.vertices*40)
        temporary[#temporary+1]=data
        local floats=require('ffi').cast('float*',data:getFFIPointer())
        local offset=0
        for pose_index,source_row in ipairs(group.sources) do
            for vertex=1,source_row.vertices do
                local x,y,z,nx,ny,nz,u,v,r,g,b,a=
                    source_row.mesh:getVertex(vertex)
                floats[offset],floats[offset+1],floats[offset+2]=x,y,z
                floats[offset+3],floats[offset+4]=u,v
                floats[offset+5],floats[offset+6],floats[offset+7],floats[offset+8]=r,g,b,a
                floats[offset+9]=pose_index-1
                offset=offset+10
            end
        end
        assert(offset==group.vertices*10,'shadow pose batch vertex count mismatch')
        local mesh=love.graphics.newMesh(format,group.vertices,'triangles','static')
        temporary[#temporary+1]=mesh
        mesh:setVertices(data)
        mesh:setTexture(group.sources[1].texture)
        local rows={}
        for index=1,MAX_POSES*3 do rows[index]=ZERO end
        return {kind='rigid_pose_batch',mesh=mesh,bounds={},
            alpha_test=true,
            alpha_threshold=group.sources[1].alpha_threshold,
            ignore_texture_alpha=group.sources[1].ignore_texture_alpha,
            flip_u=group.sources[1].flip_u,flip_v=group.sources[1].flip_v,
            pose_rows=rows,pose_count=#group.sources,
            contiguous_pose_batch=true}
    end,debug.traceback)
    local result_mesh=ok and result and result.mesh or nil
    for _,resource in ipairs(temporary) do
        if resource~=result_mesh then pcall(resource.release,resource) end
    end
    return ok and result or nil,not ok and result or nil
end

local function update_pose_packet(entry,group)
    local command=entry.command
    local bounds=command.bounds
    bounds.min_x,bounds.min_y,bounds.min_z=math.huge,math.huge,math.huge
    bounds.max_x,bounds.max_y,bounds.max_z=-math.huge,-math.huge,-math.huge
    local rows=command.pose_rows
    for pose_index,source_row in ipairs(group.sources) do
        local pose=source_row.command.rigid_pose
        local pose_rows=pose and pose.rows
        local first,second,third=pose_rows and pose_rows[1],
            pose_rows and pose_rows[2],pose_rows and pose_rows[3]
        local source_bounds=source_row.command.bounds
        if type(first)~='table' or type(second)~='table'
            or type(third)~='table' or type(source_bounds)~='table' then
            return false
        end
        for lane=1,4 do
            if type(first[lane])~='number' or type(second[lane])~='number'
                or type(third[lane])~='number' then
                return false
            end
        end
        local min_x,min_y,min_z=source_bounds.min_x,source_bounds.min_y,
            source_bounds.min_z
        local max_x,max_y,max_z=source_bounds.max_x,source_bounds.max_y,
            source_bounds.max_z
        if type(min_x)~='number' or type(min_y)~='number'
            or type(min_z)~='number' or type(max_x)~='number'
            or type(max_y)~='number' or type(max_z)~='number' then
            return false
        end
        local base=(pose_index-1)*3
        rows[base+1],rows[base+2],rows[base+3]=first,second,third
        bounds.min_x,bounds.min_y,bounds.min_z=math.min(bounds.min_x,min_x),
            math.min(bounds.min_y,min_y),math.min(bounds.min_z,min_z)
        bounds.max_x,bounds.max_y,bounds.max_z=math.max(bounds.max_x,max_x),
            math.max(bounds.max_y,max_y),math.max(bounds.max_z,max_z)
    end
    for index=#group.sources*3+1,MAX_POSES*3 do rows[index]=ZERO end
    command.pose_count=#group.sources
    return bounds.min_x<=bounds.max_x and bounds.min_y<=bounds.max_y
        and bounds.min_z<=bounds.max_z
end

local function find_previous(previous,used,group)
    for index,entry in ipairs(previous) do
        if not used[index] and same_geometry(entry,group) then
            return entry,index
        end
    end
end

local function select_group(core,group,previous,used,current,replacements,selected,stats)
    local entry,entry_index=find_previous(previous,used,group)
    local built=false
    if not entry then
        local command,error_message=build(group)
        if not command then
            stats.pose_batch_error=tostring(error_message)
            return false
        end
        entry=snapshot(group,command)
        built=true
    end
    if not update_pose_packet(entry,group) then
        if built then release_entry(entry) end
        stats.pose_batch_error='invalid_pose_or_bounds'
        return false
    end
    if entry_index then
        used[entry_index]=true
        stats.pose_batch_geometry_reuses=(stats.pose_batch_geometry_reuses or 0)+1
    else
        stats.pose_batch_actual_mesh_builds=(stats.pose_batch_actual_mesh_builds or 0)+1
        stats.pose_batch_upload_bytes=(stats.pose_batch_upload_bytes or 0)+group.vertices*40
        if core._note_gpu_upload_bytes then core:_note_gpu_upload_bytes(group.vertices*40) end
    end
    current[#current+1]=entry
    local first=group.sources[1]
    replacements[first.index]=entry.command
    for _,source_row in ipairs(group.sources) do selected[source_row.index]=true end
    return true
end

function ShadowPoseBatch.compact(core,commands)
    if not ShadowPoseBatch.enabled(core) or not core._directional_shadow_pose_batch_shader
        or not love.data then
        ShadowPoseBatch.release(core)
        return commands
    end
    local started=love.timer.getTime()
    local stats=core._shadow_stats or {}
    core._shadow_stats=stats
    local previous=core._directional_shadow_pose_batch_cache or {}
    local current,used,replacements,selected={}, {}, {}, {}
    local source_count,batch_count,vertex_count=0,0,0
    local index=1
    while index<=#commands do
        local first=source(commands[index],index)
        if not first then
            index=index+1
        else
            local run={first}
            local next_index=index+1
            while next_index<=#commands do
                local next_source=source(commands[next_index],next_index)
                if not next_source or not compatible(first,next_source) then break end
                run[#run+1]=next_source
                next_index=next_index+1
            end
            local cursor=1
            while cursor<=#run do
                local remaining=#run-cursor+1
                local take=math.min(MAX_POSES,remaining)
                if remaining>take and remaining-take<MIN_SOURCES then
                    take=take-(MIN_SOURCES-(remaining-take))
                end
                local group={sources={},vertices=0}
                for offset=0,take-1 do
                    local source_row=run[cursor+offset]
                    group.sources[#group.sources+1]=source_row
                    group.vertices=group.vertices+source_row.vertices
                end
                if #group.sources>=MIN_SOURCES
                    and group.vertices>=MIN_VERTICES
                    and select_group(core,group,previous,used,current,
                        replacements,selected,stats) then
                    source_count=source_count+#group.sources
                    batch_count=batch_count+1
                    vertex_count=vertex_count+group.vertices
                end
                cursor=cursor+take
            end
            index=next_index
        end
    end
    for previous_index,entry in ipairs(previous) do
        if not used[previous_index] then release_entry(entry) end
    end
    core._directional_shadow_pose_batch_cache=current
    stats.pose_batch_refreshes=(stats.pose_batch_refreshes or 0)+1
    stats.pose_batch_last_source_commands=source_count
    stats.pose_batch_last_batches=batch_count
    stats.pose_batch_last_vertices=vertex_count
    stats.pose_batch_last_draws_saved=source_count-batch_count
    stats.pose_batch_build_seconds=(stats.pose_batch_build_seconds or 0)
        +love.timer.getTime()-started
    if batch_count<=0 then return commands end
    local out={}
    for command_index,command in ipairs(commands) do
        if replacements[command_index] then out[#out+1]=replacements[command_index] end
        if not selected[command_index] then out[#out+1]=command end
    end
    return out
end

return ShadowPoseBatch
