-- bounded screen-space SunRaysEffect approximation, not Roblox's native formula
-- Occlusion is the *rendered* HDR depth attachment, reused read-only at matching
-- dimensions/MSAA. no depth texture sampling, colour/alpha guessing, world replay,
-- shadow permission changes, or collision queries. Blended geometry does not write
-- this depth: partial transparency is non-occluding, not simulated transmission
local Rays={};Rays.__index=Rays
-- existing XML importer compatibility defaults, omitted binary properties remain
-- distinguishable in the descriptor. this is not a new serialized-value claim
Rays.defaults={Enabled=true,Intensity=.25,Spread=1}
local MASK=[[
uniform vec2 uSun;
uniform vec2 uSize;
uniform float uRadius;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 p=transform_projection*vertex_position;
    p.z=p.w; // Only depth-clear sky samples pass LEQUAL; never write depth.
    return p;
}
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 pixel) {
    vec2 d=pixel/uSize-uSun;d.x*=uSize.x/uSize.y;
    float source=1.0-smoothstep(uRadius*.7,uRadius,length(d));
    return vec4(source,source,source,1.0);
}
]]
local FILTER=[[
uniform vec2 uSun;
uniform float uAspect;
uniform float uSpread;
uniform float uIntensity;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 pixel) {
    vec2 stepToSun=(uSun-uv)/32.0;
    vec2 p=uv;
    float sum=0.0;
    for(int i=0;i<32;i++) {
        p+=stepToSun;
        // Out-of-view samples are absent, never edge-clamped light sources.
        if(p.x>=0.0 && p.y>=0.0 && p.x<=1.0 && p.y<=1.0)
            sum+=Texel(tex,p).r;
    }
    vec2 d=uv-uSun;d.x*=uAspect;
    float width=.04+.46*uSpread;
    float envelope=exp(-dot(d,d)/(width*width));
    float energy=(sum/32.0)*envelope*uIntensity;
    // Add radiance without changing the world's premultiplied coverage.
    return vec4(vec3(energy),0.0);
}
]]
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function number(n,default)local v=tonumber(n);return finite(v) and math.max(0,math.min(1,v)) or default end
local function release(r)if r then pcall(function()r:release()end) end end
function Rays.new(graphics)
    return setmetatable({graphics=graphics,uv={0,0},size={0,0},generation=0,allocations=0,releases=0,failures=0,frames=0,last_passes=0},Rays)
end
function Rays:retire()
    for _,key in ipairs({'mask','filtered','mask_shader','filter_shader'}) do
        if self[key] then release(self[key]);self[key]=nil;self.releases=self.releases+1 end
    end
    self.width,self.height,self.samples=nil,nil,nil
    self.valid=false;self.last_passes=0;self.storage_bytes=0
end
function Rays:project(state,core)
    local effect=state and state.post_effects and state.post_effects.sun_rays
    if not effect or effect.Enabled==false then return false,'inactive' end
    local intensity=number(effect.Intensity,Rays.defaults.Intensity)
    if intensity<=0 then return false,'zero_intensity' end
    local sun=state.sun_direction;local v=core and core._view_matrix;local p=core and core._projection_matrix
    if not sun or not v or not p then return false,'camera_unavailable' end
    local x,y,z=sun[1],sun[2],sun[3]
    if not finite(x) or not finite(y) or not finite(z) or y<=0 then return false,'below_horizon' end
    local vx=v[1]*x+v[2]*y+v[3]*z
    local vy=v[5]*x+v[6]*y+v[7]*z
    local vz=v[9]*x+v[10]*y+v[11]*z
    local cw=p[13]*vx+p[14]*vy+p[15]*vz
    if not finite(cw) or cw<=.0001 then return false,'behind_camera' end
    local sx=.5+.5*(p[1]*vx+p[2]*vy+p[3]*vz)/cw
    local sy=.5+.5*(p[5]*vx+p[6]*vy+p[7]*vz)/cw*(core._projection_flip_y<0 and 1 or -1)
    if not finite(sx) or not finite(sy) or sx<-.15 or sx>1.15 or sy<-.15 or sy>1.15 then return false,'outside_guard' end
    local edge=math.min(sx+.15,1.15-sx,sy+.15,1.15-sy)/.15
    local horizon=math.min(1,y/.08)
    self.uv[1],self.uv[2]=sx,sy
    self.intensity=intensity*math.min(1,edge)*horizon
    self.spread=number(effect.Spread,Rays.defaults.Spread)
    local angle=tonumber(state.sky and state.sky.SunAngularSize) or 21
    angle=finite(angle) and math.max(0,math.min(60,angle)) or 21
    self.radius=math.max(.002,math.min(.15,math.tan(math.rad(angle)*.5)*math.abs(p[6])*.5))
    return true
end
function Rays:ensure(post)
    local width,height,samples=post.scene_width,post.scene_height,post.scene_samples
    if not post.scene_depth then return false,'no_scene_depth' end
    if self.mask and self.width==width and self.height==height and self.samples==samples then return true end
    -- build privately, failures release all new resources, never mark a mixed
    -- target generation valid. no handles to the depth attachment are retained
    local made={}
    local ok,err=pcall(function()
        local g=self.graphics
        made[1]=g.newShader(MASK);made[2]=g.newShader(FILTER)
        made[3]=g.newCanvas(width,height,{format='r8',msaa=samples,readable=true})
        assert(made[3]:getMSAA()==post.scene_depth:getMSAA(),'sun mask/depth MSAA mismatch')
        made[4]=g.newCanvas(math.max(1,math.ceil(width/4)),math.max(1,math.ceil(height/4)),{format='rgba16f',msaa=0,readable=true})
        made[3]:setFilter('linear','linear');made[4]:setFilter('linear','linear')
        made[3]:setWrap('clamp','clamp');made[4]:setWrap('clamp','clamp')
    end)
    if not ok then for _,r in ipairs(made)do release(r)end;return false,tostring(err) end
    self:retire()
    self.mask_shader,self.filter_shader,self.mask,self.filtered=unpack(made)
    self.width,self.height,self.samples=width,height,samples
    self.size[1],self.size[2]=width,height
    self.allocations=self.allocations+4
    -- Logical colour storage incl multisample colour plus resolved mask, driver
    -- allocation/granularity and the existing shared depth are not total VRAM
    self.storage_bytes=width*height*(samples>0 and samples+1 or 1)+math.ceil(width/4)*math.ceil(height/4)*8
    return true
end
function Rays:apply(post,state,core)
    self.last_passes=0;self.valid=false
    local active,reason=self:project(state,core)
    if not active then
        self.skip_reason=reason
        if reason=='inactive' or reason=='zero_intensity' then
            if self.mask or self.mask_shader then self:retire() end
        end
        return false
    end
    local ready,err=self:ensure(post)
    if not ready then self.failures=self.failures+1;self.failure_reason=err;return false end
    local g=self.graphics
    g.push('all')
    local ok,message=xpcall(function()
        g.origin();g.setScissor();g.setStencilTest();g.setMeshCullMode('none');g.setColor(1,1,1,1)
        g.setColorMask(true,true,true,true);g.setWireframe(false)
        g.setBlendMode('replace','premultiplied')
        g.setCanvas({self.mask,depthstencil=post.scene_depth})
        g.clear(0,0,0,0,false,false) -- preserve shared depth and stencil
        g.setDepthMode('lequal',false)
        self.mask_shader:send('uSun',self.uv);self.mask_shader:send('uSize',self.size);self.mask_shader:send('uRadius',self.radius)
        g.setShader(self.mask_shader);g.rectangle('fill',0,0,self.width,self.height)
        g.setCanvas(self.filtered);g.clear(0,0,0,0);g.setDepthMode('always',false)
        local shader=self.filter_shader
        shader:send('uSun',self.uv);shader:send('uAspect',self.width/self.height)
        shader:send('uSpread',self.spread);shader:send('uIntensity',self.intensity)
        g.setShader(shader);g.draw(self.mask,0,0,0,self.filtered:getWidth()/self.width,self.filtered:getHeight()/self.height)
        -- all preparatory uploads succeeded before touching the HDR scene
        g.setCanvas(post.scene_canvas);g.setBlendMode('add','premultiplied');g.setShader()
        g.draw(self.filtered,0,0,0,self.width/self.filtered:getWidth(),self.height/self.filtered:getHeight())
    end,debug.traceback)
    g.pop()
    if not ok then self.failures=self.failures+1;self.failure_reason=tostring(message);return false end
    self.valid=true;self.generation=self.generation+1;self.frames=self.frames+1
    self.last_passes=3;self.failure_reason=nil;self.skip_reason=nil
    return true
end
return Rays
