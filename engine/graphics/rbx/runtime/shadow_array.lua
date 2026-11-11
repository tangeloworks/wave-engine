-- combine compatible cutout shadow meshes in a texture array
-- sources with incompatible formats keep their own draw commands
local ShadowArray={}
ShadowArray.vertex_versions=setmetatable({},{__mode='k'})
function ShadowArray.invalidate(mesh)
    local version=ShadowArray.vertex_versions[mesh]
    if version~=nil then ShadowArray.vertex_versions[mesh]=version+1 end
end
local function release_entry(entry,keep_texture)
    entry.command.mesh:release()
    if not keep_texture then entry.command.texture_array:release() end
end
function ShadowArray.release(core)
    for _,entry in ipairs(core._directional_shadow_array_cache or {}) do release_entry(entry) end
    core._directional_shadow_array_cache=nil
end
function ShadowArray.enabled(core)
    return core.array_cutout_shadow_geometry~=false
end
local shader_source=[[
#pragma language glsl3
uniform mat4 uShadowMatrix;
uniform ArrayImage uShadowTextures;
uniform float uShadowAlphaTest;
uniform float uShadowAlphaThreshold;
uniform float uShadowIgnoreTextureAlpha;
uniform float uFlipU;
uniform float uFlipV;
varying float vShadowDepth;
varying float vShadowVertexAlpha;
varying float vShadowLayer;
#ifdef VERTEX
attribute float ShadowTextureLayer;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 clipPos=uShadowMatrix*vec4(vertex_position.xyz,1.0);
    vShadowDepth=clipPos.z/max(abs(clipPos.w),0.000001)*0.5+0.5;
    vShadowVertexAlpha=VertexColor.a;
    vShadowLayer=ShadowTextureLayer;
    return clipPos;
}
#endif
#ifdef PIXEL
]]
local shader_pixel=[[
vec4 effect(vec4 color, Image unused_image, vec2 texture_coords, vec2 screen_coords) {
    if (uShadowAlphaTest>0.5) {
        vec2 uv=texture_coords;
        if (uFlipU>0.5) uv.x=1.0-uv.x;
        if (uFlipV>0.5) uv.y=1.0-uv.y;
        float textureAlpha=uShadowIgnoreTextureAlpha>0.5 ? 1.0 : Texel(uShadowTextures,vec3(uv,vShadowLayer)).a;
        if (vShadowVertexAlpha*textureAlpha<uShadowAlphaThreshold) discard;
    }
    return vec4(encodeDirectionalShadowDepth(vShadowDepth),1.0);
}
#endif
]]
local format={{'VertexPosition','float',3},{'VertexTexCoord','float',2},
    {'VertexColor','float',4},{'ShadowTextureLayer','float',1}}
local function source(core,command,index)
    if command.kind~='textured' or not command.alpha_test or command.rigid_pose or command.unstable_shadow_index_map or not command.mesh then return end
    local mesh=command.mesh
    if mesh:getDrawMode()~='triangles' then return end
    local texture=mesh:getTexture()
    local meta=core._texture_sampler_debug_by_texture and core._texture_sampler_debug_by_texture[texture]
    if not texture or not meta or not meta.resolved or texture:getTextureType()~='2d' then return end
    local pixel_format=texture:getFormat()
    if pixel_format~='rgba8' and pixel_format~='srgba8' then return end
    local offsets,total={},1
    for _,attribute in ipairs(mesh:getVertexFormat()) do
        if attribute[1]=='VertexPosition' or attribute[1]=='VertexTexCoord' or attribute[1]=='VertexColor' then
            if attribute[2]~='float' then return end
            offsets[attribute[1]]={total,attribute[3]}
        end
        total=total+attribute[3]
    end
    if not offsets.VertexPosition or offsets.VertexPosition[2]~=3 or not offsets.VertexTexCoord
        or offsets.VertexTexCoord[2]~=2 or not offsets.VertexColor or offsets.VertexColor[2]~=4 then return end
    local map=mesh:getVertexMap()
    local count=map and #map or mesh:getVertexCount()
    local ranges=command.ranges or {{1,count}}
    local active=0
    for _,range in ipairs(ranges) do
        if range[1]<1 or range[2]<=0 or range[1]+range[2]-1>count or range[2]%3~=0 or (range[1]-1)%3~=0 then return end
        active=active+range[2]
    end
    if active==0 then return end
    local width,height=texture:getPixelDimensions()
    local min,mag,anisotropy=texture:getFilter()
    local mip,sharpness=texture:getMipmapFilter()
    local wrap_u,wrap_v=texture:getWrap()
    local mipmaps=texture:getMipmapCount()>1
    local texture_key=table.concat({width,height,min,mag,anisotropy,mip or 'none',sharpness or 0,
        wrap_u,wrap_v,tostring(mipmaps)},':')
    local key=table.concat({texture_key,tostring(command.alpha_threshold),
        tostring(command.ignore_texture_alpha),tostring(command.flip_u),tostring(command.flip_v)},':')
    if ShadowArray.vertex_versions[mesh]==nil then ShadowArray.vertex_versions[mesh]=0 end
    return {command=command,index=index,texture=texture,meta=meta,map=map,ranges=ranges,offsets=offsets,
        vertex_version=ShadowArray.vertex_versions[mesh],
        active=active,key=key,texture_key=texture_key,width=width,height=height,min=min,mag=mag,anisotropy=anisotropy,
        mip=mip,sharpness=sharpness,wrap_u=wrap_u,wrap_v=wrap_v,mipmaps=mipmaps}
end
local function build(group,borrowed_array)
    local images,temporary={},{}
    local ok,result=xpcall(function()
        local timings={};local stage=love.timer.getTime()
        if not borrowed_array then for _,source in ipairs(group.textures) do
            -- Alpha bleed changes RGB only. Shadow sampling consumes unchanged
            -- alpha, decode call-owned bytes rather than retaining another cache
            local data=love.image.newImageData(source.meta.resolved);temporary[#temporary+1]=data
            assert(data:getFormat()=='rgba8','unsupported source format')
            assert(data:getWidth()==source.width and data:getHeight()==source.height,'source dimensions changed')
            images[#images+1]=data
        end end
        timings.decode=love.timer.getTime()-stage;stage=love.timer.getTime()
        local first=group.sources[1]
        local array=borrowed_array or love.graphics.newArrayImage(images,{mipmaps=first.mipmaps,linear=true})
        if not borrowed_array then
            temporary[#temporary+1]=array
            array:setFilter(first.min,first.mag,first.anisotropy);array:setWrap(first.wrap_u,first.wrap_v)
            array:setMipmapFilter(first.mip,first.sharpness or 0)
        end
        timings.texture=love.timer.getTime()-stage;stage=love.timer.getTime()
        local data=love.data.newByteData(group.vertices*40);temporary[#temporary+1]=data
        local ptr=require('ffi').cast('float*',data:getFFIPointer())
        local offset=0
        local bounds={min_x=math.huge,min_y=math.huge,min_z=math.huge,
            max_x=-math.huge,max_y=-math.huge,max_z=-math.huge}
        for _,source in ipairs(group.sources) do
            local position = source.offsets.VertexPosition[1]
            local uv = source.offsets.VertexTexCoord[1]
            local color = source.offsets.VertexColor[1]
            local layer = group.layers[source.texture] - 1
            for _, range in ipairs(source.ranges) do
                for index = range[1], range[1] + range[2] - 1 do
                    local vertex = source.map and source.map[index] or index
                    local row = {source.command.mesh:getVertex(vertex)}
                    local x, y, z = row[position], row[position + 1], row[position + 2]
                    ptr[offset], ptr[offset + 1], ptr[offset + 2] = x, y, z
                    ptr[offset + 3], ptr[offset + 4] = row[uv], row[uv + 1]
                    for lane = 0, 3 do ptr[offset + 5 + lane] = row[color + lane] end
                    ptr[offset + 9] = layer
                    offset = offset + 10
                    bounds.min_x, bounds.min_y, bounds.min_z = math.min(bounds.min_x,x), math.min(bounds.min_y,y), math.min(bounds.min_z,z)
                    bounds.max_x, bounds.max_y, bounds.max_z = math.max(bounds.max_x,x), math.max(bounds.max_y,y), math.max(bounds.max_z,z)
                end
            end
        end
        local mesh=love.graphics.newMesh(format,group.vertices,'triangles','static');temporary[#temporary+1]=mesh
        mesh:setVertices(data)
        timings.geometry=love.timer.getTime()-stage
        return {kind='textured_array',mesh=mesh,texture_array=array,bounds=bounds,
            array_build_timing=timings,
            alpha_test=true,alpha_threshold=first.command.alpha_threshold,
            ignore_texture_alpha=first.command.ignore_texture_alpha,
            flip_u=first.command.flip_u,flip_v=first.command.flip_v,compact_cutout=true}
    end,debug.traceback)
    for _,resource in ipairs(temporary) do
        if not ok or (resource~=result.mesh and resource~=result.texture_array) then resource:release() end
    end
    return ok and result or nil,not ok and result or nil
end
local function same_textures(entry,group)
    local old=entry._shadow_array_sources
    if entry.texture_key~=group.sources[1].texture_key or #old.textures~=#group.textures then return false end
    for i,source in ipairs(group.textures) do if source.texture~=old.textures[i] then return false end end
    return true
end
local function same_geometry(entry,group)
    local old=entry._shadow_array_sources.sources
    if #old~=#group.sources then return false end
    for i,source in ipairs(group.sources) do
        local prior=old[i]
        if prior.mesh~=source.command.mesh or prior.version~=source.vertex_version or #prior.ranges~=#source.ranges then return false end
        local cursor=0
        for j,range in ipairs(source.ranges) do
            if range[1]~=prior.ranges[j][1] or range[2]~=prior.ranges[j][2] then return false end
            for index=range[1],range[1]+range[2]-1 do
                cursor=cursor+1
                if (source.map and source.map[index] or index)~=prior.indices[cursor] then return false end
            end
        end
        if cursor~=#prior.indices then return false end
    end
    return true
end
local function snapshot(group,command)
    local sources,textures={},{}
    for i,source in ipairs(group.textures) do textures[i]=source.texture end
    for i,source in ipairs(group.sources) do
        local ranges,indices={},{}
        for j,range in ipairs(source.ranges) do
            ranges[j]={range[1],range[2]}
            for index=range[1],range[1]+range[2]-1 do indices[#indices+1]=source.map and source.map[index] or index end
        end
        sources[i]={mesh=source.command.mesh,version=source.vertex_version,ranges=ranges,indices=indices}
    end
    return {key=group.sources[1].key,texture_key=group.sources[1].texture_key,command=command,
        _shadow_array_sources={sources=sources,textures=textures}}
end
function ShadowArray.compact(core,commands,depth_glsl)
    if not ShadowArray.enabled(core) or not love.graphics.getTextureTypes().array then ShadowArray.release(core);return commands end
    local started=love.timer.getTime()
    local stats=core._shadow_stats or {};core._shadow_stats=stats
    if not core._directional_shadow_array_shader then
        local ok,shader=pcall(love.graphics.newShader,shader_source..depth_glsl..shader_pixel)
        if not ok then stats.array_error=tostring(shader);return commands end
        core._directional_shadow_array_shader=shader
    end
    local groups,order={},{}
    for index,command in ipairs(commands) do
        local candidate=source(core,command,index)
        if candidate then
            local group=groups[candidate.key]
            if not group then group={sources={},textures={},layers={},vertices=0};groups[candidate.key]=group;order[#order+1]=group end
            group.sources[#group.sources+1]=candidate;group.vertices=group.vertices+candidate.active
            if not group.layers[candidate.texture] then
                group.textures[#group.textures+1]=candidate;group.layers[candidate.texture]=#group.textures
            end
        end
    end
    local selected,replacements={},{}
    local previous=core._directional_shadow_array_cache or {}
    local current,used={},{}
    core._directional_shadow_array_cache=current
    local total_bytes,total_vertices,source_count,group_count=0,0,0,0
    local uploaded_bytes,storage_bytes,built_groups=0,0,0
    local decode_seconds,texture_seconds,geometry_seconds=0,0,0
    for _,group in ipairs(order) do
        local first=group.sources[1]
        local bytes=first.width*first.height*4*#group.textures*(first.mipmaps and 4/3 or 1)
        if #group.sources>1 and #group.textures<=64 and total_bytes+bytes<=16777216
            and total_vertices+group.vertices<=262144 then
            local old,old_index
            for i,entry in ipairs(previous) do
                if not used[i] and same_textures(entry,group) then old,old_index=entry,i;break end
            end
            local identical=old and same_geometry(old,group)
            local replacement,err
            if identical then
                replacement=old.command
                stats.array_geometry_reuses=(stats.array_geometry_reuses or 0)+1
            else replacement,err=build(group,old and old.command.texture_array) end
            if replacement then
                replacement.alpha_threshold=first.command.alpha_threshold
                replacement.ignore_texture_alpha=first.command.ignore_texture_alpha
                replacement.flip_u,replacement.flip_v=first.command.flip_u,first.command.flip_v
                if old then
                    used[old_index]=true
                    if not identical then release_entry(old,true) end
                    stats.array_texture_reuses=(stats.array_texture_reuses or 0)+1
                end
                current[#current+1]=identical and old or snapshot(group,replacement)
                replacements[first.index]=replacement
                for _,source in ipairs(group.sources) do selected[source.index]=true end
                total_bytes,total_vertices=total_bytes+bytes,total_vertices+group.vertices
                source_count,group_count=source_count+#group.sources,group_count+1
                if not identical then
                    decode_seconds=decode_seconds+replacement.array_build_timing.decode
                    texture_seconds=texture_seconds+replacement.array_build_timing.texture
                    geometry_seconds=geometry_seconds+replacement.array_build_timing.geometry
                    replacement.array_build_timing=nil
                    stats.array_actual_mesh_builds=(stats.array_actual_mesh_builds or 0)+1
                    stats.array_actual_texture_builds=(stats.array_actual_texture_builds or 0)+(old and 0 or 1)
                    uploaded_bytes=uploaded_bytes+group.vertices*40+(old and 0 or first.width*first.height*4*#group.textures)
                    built_groups=built_groups+1
                end
                local width,height=first.width,first.height
                for mip=1,replacement.texture_array:getMipmapCount() do
                    storage_bytes=storage_bytes+width*height*4*#group.textures
                    width,height=math.max(1,math.floor(width/2)),math.max(1,math.floor(height/2))
                end
            else stats.array_error=err end
        end
    end
    for i,entry in ipairs(previous) do if not used[i] then release_entry(entry) end end
    if group_count==0 then return commands end
    local out={}
    for index,command in ipairs(commands) do
        if replacements[index] then out[#out+1]=replacements[index] end
        if not selected[index] then out[#out+1]=command end
    end
    stats.array_source_commands,stats.array_groups=source_count,group_count
    stats.array_vertices,stats.array_texture_bytes=total_vertices,storage_bytes
    stats.array_upload_bytes=(stats.array_upload_bytes or 0)+uploaded_bytes
    stats.array_builds=(stats.array_builds or 0)+(built_groups>0 and 1 or 0)
    stats.array_refreshes=(stats.array_refreshes or 0)+1
    stats.array_build_seconds=(stats.array_build_seconds or 0)+love.timer.getTime()-started
    stats.array_decode_seconds=(stats.array_decode_seconds or 0)+decode_seconds
    stats.array_texture_seconds=(stats.array_texture_seconds or 0)+texture_seconds
    stats.array_geometry_seconds=(stats.array_geometry_seconds or 0)+geometry_seconds
    if core._note_gpu_upload_bytes and uploaded_bytes>0 then core:_note_gpu_upload_bytes(uploaded_bytes) end
    return out
end
return ShadowArray
