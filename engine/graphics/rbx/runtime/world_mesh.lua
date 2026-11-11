-- persistent world geometry for native effects. Vertices are Roblox
-- positions, UVs and linear RGBA, submitted into the sorted transparent pass
local WorldMesh = {}
local age_ffi_available, age_ffi = pcall(require,"ffi")
-- one owned 40-byte-per-vertex staging buffer, its pointer never outlives Data
-- existing table uploads remain the fallback when FFI/Data is unavailable
local function new_age_upload_data(capacity)
    if not age_ffi_available or not age_ffi or not love.data
        or type(love.data.newByteData)~="function" then return nil end
    local ok,data=pcall(love.data.newByteData,capacity*40)
    if not ok or not data then return nil end
    local pointer_ok,pointer=pcall(data.getFFIPointer,data)
    if pointer_ok and pointer~=nil then
        local cast_ok,floats=pcall(age_ffi.cast,"float*",pointer)
        if cast_ok and floats~=nil then return data,floats end
    end
    if data.release then data:release() end
    return nil
end
-- match Mesh table float attributes: omitted values become zero, numeric
-- strings are accepted, other non-number values keep the original error
local function age_float_component(value)
    if value==nil then return 0 end
    if type(value)=="number" then return value end
    if type(value)=="string" then
        local number=tonumber(value)
        if number~=nil then return number end
    end
    error("world mesh float component must be a number",2)
end
local format = {{"VertexPosition","float",3},{"VertexTexCoord","float",2},{"VertexColor","float",4}}
local aged_format = {{"VertexPosition","float",3},{"VertexTexCoord","float",2},{"VertexColor","float",4},{"VertexBirthTime","float",1}}
local shader_source = [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uLightEmission;
uniform float uBrightness;
varying vec4 effectTint;
#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 p) {
    effectTint=VertexColor;
    return uProjectionMatrix * uViewRotationMatrix * vec4(p.xyz-uCameraPos,1.0);
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 pixel) {
    vec4 c=Texel(texture, uv)*effectTint;
    return vec4(c.rgb*uBrightness*c.a,c.a*(1.0-uLightEmission));
}
#endif
]]
local function finite(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge
end
local function literal(value)
    assert(finite(value),"finite age sequence component required")
    local s=string.format("%.17g",value)
    if not s:find("[%.eE]") then s=s..".0" end
    return s
end
local function sequence_source(name,points,color)
    local kind=color and "vec3" or "float"
    local function value(point)
        if not color then return literal(point.value) end
        local c=point.color
        return "vec3("..literal(c.r)..","..literal(c.g)..","..literal(c.b)..")"
    end
    assert(type(points)=="table" and #points>=2,"age sequence requires keypoints")
    local code={kind.." "..name.."(float progress) {"}
    for i=2,#points do
        local a,b=points[i-1],points[i]
        assert(finite(a.time) and finite(b.time) and b.time>a.time,"ordered age sequence required")
        code[#code+1]="if (progress <= "..literal(b.time)..") return mix("..value(a)..","..value(b)
            ..", max(0.0,(progress-"..literal(a.time)..")/"..literal(math.max(1e-9,b.time-a.time)).."));"
    end
    code[#code+1]="return "..value(points[#points]).."; }"
    return table.concat(code,"\n")
end
local function age_shader_source(age)
    assert(finite(age.lifetime) and age.lifetime>0,"positive age lifetime required")
    local equations=sequence_source("ageColor",age.color,true).."\n"
        ..sequence_source("ageTransparency",age.transparency,false)
    return [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uAgeTime;
uniform float uLightEmission;
uniform float uBrightness;
varying vec4 effectTint;
varying vec4 ageTint;
#ifdef VERTEX
attribute float VertexBirthTime;
]]..equations..[[
vec4 position(mat4 transform_projection, vec4 p) {
    effectTint=VertexColor;
    float progress=(uAgeTime-VertexBirthTime)/]]..literal(age.lifetime)..[[;
    ageTint=vec4(ageColor(progress),1.0-ageTransparency(progress));
    return uProjectionMatrix * uViewRotationMatrix * vec4(p.xyz-uCameraPos,1.0);
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 pixel) {
    vec4 c=Texel(texture, uv)*effectTint*ageTint;
    return vec4(c.rgb*uBrightness*c.a,c.a*(1.0-uLightEmission));
}
#endif
]]
end
local function lit_source(core,source)
    local lighting=assert(core._effect_lighting_glsl,'Effect lighting shader packet is unavailable')
    source=source:gsub('uniform float uLightEmission;',function()
        return 'uniform float uLightEmission;\nuniform float uLightInfluence;\nvarying vec3 effectWorldPos;\n'..lighting
    end,1)
    source=source:gsub('return uProjectionMatrix %* uViewRotationMatrix %* vec4%(p.xyz%-uCameraPos,1.0%);',
        'effectWorldPos=p.xyz;\n    return uProjectionMatrix * uViewRotationMatrix * vec4(p.xyz-uCameraPos,1.0);',1)
    source=source:gsub('return vec4%(c.rgb%*uBrightness%*c.a,c.a%*%(1.0%-uLightEmission%)%);',[[
    vec3 shaded=c.rgb*uBrightness;
    if (uLightInfluence>0.0) {
        // Billboards/ribbons have actual triangle surfaces but no normal
        // attribute. Their differential plane normal follows their authored
        // geometry, including camera-facing particle orientation.
        vec3 crossNormal=cross(dFdx(effectWorldPos),dFdy(effectWorldPos));
        float normalLength=length(crossNormal);
        vec3 n=normalLength>0.000001 ? crossNormal/normalLength : vec3(0.0,1.0,0.0);
        if (dot(n,uCameraPos-effectWorldPos)<0.0) n=-n;
        vec3 illumination=computeFrameAmbientTerm(n)
            +computeFrameDiffuseTerm(n)*computeDirectionalShadow(effectWorldPos,n)
            +computeLocalLightContribution(n,effectWorldPos);
        shaded=mix(shaded,c.rgb*illumination,clamp(uLightInfluence,0.0,1.0));
    }
    shaded=applyFrameFogAndExposure(shaded,effectWorldPos);
    return vec4(shaded*c.a,c.a*(1.0-uLightEmission));]],1)
    return source
end
local function note_age_state(core,item)
    local first=1
    if item.birth_times and item.count>0 then
        local cutoff=item.age_time-item.age_lifetime
        -- Uploaded birth times are chronological. Search keeps stationary
        -- expiration/centroid exact without a geometry rebuild or upload
        local lo,hi=1,item.count+1
        while lo<hi do
            local middle=math.floor((lo+hi)/2)
            if item.birth_times[middle]<cutoff then lo=middle+1 else hi=middle end
        end
        first=lo
    end
    local live=item.count-first+1
    if live<0 then live=0 end
    if first~=item.live_first or live~=item.live_count then
        item.live_first,item.live_count=first,live
        if live>0 then
            local sums=item.position_sums
            local offset=(first-1)*3
            local tail=item.count*3
            item.sort_x=(sums[tail+1]-sums[offset+1])/live
            item.sort_y=(sums[tail+2]-sums[offset+2])/live
            item.sort_z=(sums[tail+3]-sums[offset+3])/live
            item.mesh:setDrawRange(first,live)
        end
        core._transparent_sort_cache_state=nil
    end
end
local function release_age_shader(core,shader)
    if not shader then return end
    for _,key in ipairs{'_common_camera_uniform_send_state','_common_lighting_uniform_send_state',
        '_depth_common_uniform_send_state','_lighting_debug_uniform_send_state',
        '_directional_shadow_uniform_send_state','_local_light_uniform_support','_local_light_uniform_state',
        '_local_light_uniform_uploaded_counts'}do
        if core[key]then core[key][shader]=nil end
    end
    shader:release()
end
function WorldMesh.create(core, capacity, options)
    capacity = math.max(3,math.floor(tonumber(capacity) or 6))
    local items = core._world_mesh_items
    if not items then items = {}; core._world_mesh_items = items end
    local age=options and options.age
    local item = {kind="world_mesh", count=0, render_priority=0, sort_id=1000000+#items+1,
        light_emission=math.max(0,math.min(1,tonumber(options and options.light_emission)or 0)),
        light_influence=math.max(0,math.min(1,tonumber(options and options.light_influence)or 0)),
        brightness=math.max(0,tonumber(options and options.brightness)or 1)}
    if age then
        item.age_lifetime=age.lifetime
        item.age_lighting=item.light_influence>0
        local source=age_shader_source(age)
        item.age_shader=love.graphics.newShader(item.age_lighting and lit_source(core,source)or source)
        item.age_time=0
        item.birth_times,item.position_sums,item.age_upload_rows={}, {0,0,0}, {}
        item.age_upload_data,item.age_upload_floats=new_age_upload_data(capacity)
        if item.age_upload_data then item.age_upload_bytes=capacity*40 end
        function item:set_age_time(time)
            assert(not self.destroyed and finite(time),"live mesh and finite age time required")
            if self.age_time==time then return end
            self.age_time=time
            note_age_state(core,self)
            -- Fade is visible on every rendered frame, including zero-step
            -- frames and viewport hosts that rely on scene redraw revisions
            core._world_mesh_revision=(core._world_mesh_revision or 0)+1
        end
    end
    items[#items+1] = item
    function item:prepare()
        assert(not self.destroyed,'world mesh is destroyed')
        if not self.mesh then self.mesh=love.graphics.newMesh(age and aged_format or format,capacity,'triangles','stream')end
        -- Compile the existing draw variant without emitting a particle or
        -- touching simulation/age. Actual draw still owns frame uniforms
        if not self.age_shader then
            if self.light_influence>0 then
                if not core._world_mesh_lit_shader then core._world_mesh_lit_shader=love.graphics.newShader(lit_source(core,shader_source))end
            elseif not core._world_mesh_shader then core._world_mesh_shader=love.graphics.newShader(shader_source)end
        end
        return self.mesh
    end
    function item:set_lighting(influence,brightness)
        assert(not self.destroyed and finite(influence)and finite(brightness),'live mesh and finite lighting required')
        influence=math.max(0,math.min(1,influence));brightness=math.max(0,brightness)
        if self.light_influence==influence and self.brightness==brightness then return end
        if age and influence>0 and not self.age_lighting then
            local shader=love.graphics.newShader(lit_source(core,age_shader_source(age)))
            release_age_shader(core,self.age_shader);self.age_shader=shader;self.age_uniform_frame=nil;self.age_lighting=true
        end
        self.light_influence,self.brightness=influence,brightness
        core._world_mesh_revision=(core._world_mesh_revision or 0)+1
    end
    function item:set_light_emission(value)
        assert(not self.destroyed and finite(value),"live mesh and finite emission required")
        value=math.max(0,math.min(1,value))
        if self.light_emission==value then return end
        self.light_emission=value
        core._world_mesh_revision=(core._world_mesh_revision or 0)+1
    end
    function item:update(vertices, count, texture)
        assert(not self.destroyed,"world mesh is destroyed")
        count = math.max(0,math.floor(count or #vertices))
        assert(count <= capacity and count%3 == 0,"invalid triangle vertex count")
        if count == 0 and self.count == 0 then return end
        if age then
            for i=1,count do
                local birth=vertices[i][10]
                assert(finite(birth) and (i==1 or birth>=vertices[i-1][10]),"chronological birth times required")
                assert(i%3==1 or birth==vertices[i-1][10],"one birth time per triangle required")
            end
        end
        self.count = count
        if count > 0 then
            if not self.mesh then self.mesh=love.graphics.newMesh(age and aged_format or format,capacity,"triangles","stream") end
            local uploaded=vertices
            if age then
                -- keep CPU lifetime/centroid data in doubles. GPU times share
                -- this upload epoch, avoiding absolute-clock float drift in
                -- long sessions while retaining the same per-frame fade
                self.age_upload_epoch=self.age_time
                if self.age_upload_floats then
                    uploaded=self.age_upload_data
                    local floats=self.age_upload_floats
                    for i=1,count do
                        local src=vertices[i]
                        local offset=(i-1)*10
                        for component=1,9 do
                            floats[offset+component-1]=age_float_component(src[component])
                        end
                        floats[offset+9]=src[10]-self.age_upload_epoch
                    end
                else
                    uploaded=self.age_upload_rows
                    for i=1,count do
                        local src=vertices[i]
                        local row=uploaded[i]
                        if not row then row={};uploaded[i]=row end
                        for component=1,9 do row[component]=src[component] end
                        row[10]=src[10]-self.age_upload_epoch
                    end
                end
            end
            self.mesh:setVertices(uploaded,1,count)
            self.mesh:setDrawRange(1,count)
            self.mesh:setTexture(texture)
            local x,y,z=0,0,0
            local bounds=self.bounds or{}
            if bounds then
                bounds.min_x,bounds.min_y,bounds.min_z=math.huge,math.huge,math.huge
                bounds.max_x,bounds.max_y,bounds.max_z=-math.huge,-math.huge,-math.huge
            end
            for i=1,count do
                local v=vertices[i];x,y,z=x+v[1],y+v[2],z+v[3]
                if bounds then
                    bounds.min_x,bounds.min_y,bounds.min_z=math.min(bounds.min_x,v[1]),math.min(bounds.min_y,v[2]),math.min(bounds.min_z,v[3])
                    bounds.max_x,bounds.max_y,bounds.max_z=math.max(bounds.max_x,v[1]),math.max(bounds.max_y,v[2]),math.max(bounds.max_z,v[3])
                end
                if age then
                    self.birth_times[i]=v[10]
                    local offset=i*3
                    self.position_sums[offset+1],self.position_sums[offset+2],self.position_sums[offset+3]=x,y,z
                end
            end
            self.sort_x,self.sort_y,self.sort_z=x/count,y/count,z/count
            if bounds then
                bounds.center_x,bounds.center_y,bounds.center_z=(bounds.min_x+bounds.max_x)*.5,(bounds.min_y+bounds.max_y)*.5,(bounds.min_z+bounds.max_z)*.5
                bounds.extent_x,bounds.extent_y,bounds.extent_z=(bounds.max_x-bounds.min_x)*.5,(bounds.max_y-bounds.min_y)*.5,(bounds.max_z-bounds.min_z)*.5
                bounds.radius=math.sqrt(bounds.extent_x^2+bounds.extent_y^2+bounds.extent_z^2)
                self.bounds=bounds
            end
        end
        if age then self.live_first,self.live_count=nil,nil;note_age_state(core,self) end
        core._transparent_sort_cache_state=nil
        core._world_mesh_revision=(core._world_mesh_revision or 0)+1
    end
    function item:destroy()
        if self.destroyed then return end
        self.destroyed,self.count=true,0
        if self.mesh then self.mesh:release();self.mesh=nil end
        if self.age_shader then release_age_shader(core,self.age_shader);self.age_shader=nil end
        self.age_upload_floats=nil
        if self.age_upload_data then self.age_upload_data:release();self.age_upload_data=nil end
        self.age_upload_bytes=nil
        self.birth_times,self.position_sums,self.age_upload_rows=nil,nil,nil
        for i=#items,1,-1 do if items[i]==self then table.remove(items,i);break end end
        core._transparent_sort_cache_state=nil
        core._world_mesh_revision=(core._world_mesh_revision or 0)+1
    end
    return item
end
local function active(item) return not item.destroyed and (item.live_count or item.count)>0 end
-- shared unlit/lit effect programs are bounded renderer resources. Dynamic
-- source effects may first appear after a map is ready, so callers that own
-- a covered resource-preparation phase can make both existing variants ready
-- without allocating effect geometry or changing their simulation lifetime
function WorldMesh.prepare_shared_shaders(core)
    assert(core and core._effect_lighting_glsl,
        "WorldMesh shader preparation requires the effect lighting packet")
    if not core._world_mesh_shader then
        core._world_mesh_shader=love.graphics.newShader(shader_source)
    end
    if not core._world_mesh_lit_shader then
        core._world_mesh_lit_shader=love.graphics.newShader(lit_source(core,shader_source))
    end
    return core._world_mesh_shader,core._world_mesh_lit_shader
end

function WorldMesh.collect(core, source)
    local items=core._world_mesh_items
    if not items or #items==0 then return source end
    local any_active=false
    for i=1,#items do if active(items[i]) then any_active=true;break end end
    if not any_active then return source end
    local cache=core._world_mesh_list_state or {};core._world_mesh_list_state=cache
    if cache.source==source and cache.count==#source
        and cache.effects==core._world_mesh_revision
        and cache.visible==core._visible_transparent_signature
        and cache.scene==core._visible_scene_revision
        and cache.dynamic==core._dynamic_scene_revision then return core._world_mesh_draw_items end
    cache.source,cache.count,cache.effects=source,#source,core._world_mesh_revision
    cache.visible,cache.scene,cache.dynamic=core._visible_transparent_signature,core._visible_scene_revision,core._dynamic_scene_revision
    local out=core._world_mesh_draw_items or {};core._world_mesh_draw_items=out
    local n=0
    for i=1,#source do n=n+1;out[n]=source[i] end
    for i=1,#items do if active(items[i]) then n=n+1;out[n]=items[i] end end
    for i=#out,n+1,-1 do out[i]=nil end
    core._transparent_sort_cache_state=nil
    return out
end
function WorldMesh.shader(core,item)
    if item and item.age_shader then
        local shader=item.age_shader
        if item.age_lighting then core:_send_common_uniforms(shader)end
        if item.age_uniform_frame~=core._draw_scene_pass_id then
            item.age_uniform_frame=core._draw_scene_pass_id
            shader:send("uViewRotationMatrix",core._view_rotation_matrix or core._view_matrix)
            shader:send("uProjectionMatrix",core._projection_matrix)
            local c=core.camera.cframe
            shader:send("uCameraPos",{c.x,c.y,c.z})
        end
        shader:send("uAgeTime",item.age_time-(item.age_upload_epoch or item.age_time))
        return shader
    end
    if item and item.light_influence>0 then
        if not core._world_mesh_lit_shader then core._world_mesh_lit_shader=love.graphics.newShader(lit_source(core,shader_source))end
        core:_send_common_uniforms(core._world_mesh_lit_shader)
        return core._world_mesh_lit_shader
    end
    if not core._world_mesh_shader then core._world_mesh_shader=love.graphics.newShader(shader_source) end
    local shader=core._world_mesh_shader
    if core._world_mesh_uniform_frame==core._draw_scene_pass_id then return shader end
    core._world_mesh_uniform_frame=core._draw_scene_pass_id
    shader:send("uViewRotationMatrix",core._view_rotation_matrix or core._view_matrix)
    shader:send("uProjectionMatrix",core._projection_matrix)
    local c=core.camera.cframe
    shader:send("uCameraPos",{c.x,c.y,c.z})
    return shader
end
return WorldMesh
