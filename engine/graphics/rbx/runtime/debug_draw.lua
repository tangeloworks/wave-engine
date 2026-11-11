-- debug-draw helpers, take a project(x,y,z)->sx,sy callback

local DebugDraw = {}

local sqrt = math.sqrt
local abs = math.abs

local function line3(project, ax, ay, az, bx, by, bz)
    local x0, y0 = project(ax, ay, az)
    local x1, y1 = project(bx, by, bz)
    if x0 and x1 then love.graphics.line(x0, y0, x1, y1) end
end
DebugDraw.line = line3

function DebugDraw.aabb(project, lx, ly, lz, rx, ry, rz)
    line3(project, lx, ly, lz, rx, ly, lz); line3(project, rx, ly, lz, rx, ly, rz)
    line3(project, rx, ly, rz, lx, ly, rz); line3(project, lx, ly, rz, lx, ly, lz)
    line3(project, lx, ry, lz, rx, ry, lz); line3(project, rx, ry, lz, rx, ry, rz)
    line3(project, rx, ry, rz, lx, ry, rz); line3(project, lx, ry, rz, lx, ry, lz)
    line3(project, lx, ly, lz, lx, ry, lz); line3(project, rx, ly, lz, rx, ry, lz)
    line3(project, rx, ly, rz, rx, ry, rz); line3(project, lx, ly, rz, lx, ry, rz)
end

-- scalar math not closures, avoids 1 alloc/part/frame on the hot path
function DebugDraw.obox(project, cx, cy, cz, rx, ry, rz, ux, uy, uz, fx, fy, fz)
    -- bottom face (u = -1)
    local a1x, a1y, a1z = cx - rx - ux - fx, cy - ry - uy - fy, cz - rz - uz - fz
    local a2x, a2y, a2z = cx + rx - ux - fx, cy + ry - uy - fy, cz + rz - uz - fz
    local a3x, a3y, a3z = cx + rx - ux + fx, cy + ry - uy + fy, cz + rz - uz + fz
    local a4x, a4y, a4z = cx - rx - ux + fx, cy - ry - uy + fy, cz - rz - uz + fz
    -- top face (u = +1)
    local b1x, b1y, b1z = cx - rx + ux - fx, cy - ry + uy - fy, cz - rz + uz - fz
    local b2x, b2y, b2z = cx + rx + ux - fx, cy + ry + uy - fy, cz + rz + uz - fz
    local b3x, b3y, b3z = cx + rx + ux + fx, cy + ry + uy + fy, cz + rz + uz + fz
    local b4x, b4y, b4z = cx - rx + ux + fx, cy - ry + uy + fy, cz - rz + uz + fz
    line3(project, a1x, a1y, a1z, a2x, a2y, a2z); line3(project, a2x, a2y, a2z, a3x, a3y, a3z)
    line3(project, a3x, a3y, a3z, a4x, a4y, a4z); line3(project, a4x, a4y, a4z, a1x, a1y, a1z)
    line3(project, b1x, b1y, b1z, b2x, b2y, b2z); line3(project, b2x, b2y, b2z, b3x, b3y, b3z)
    line3(project, b3x, b3y, b3z, b4x, b4y, b4z); line3(project, b4x, b4y, b4z, b1x, b1y, b1z)
    line3(project, a1x, a1y, a1z, b1x, b1y, b1z); line3(project, a2x, a2y, a2z, b2x, b2y, b2z)
    line3(project, a3x, a3y, a3z, b3x, b3y, b3z); line3(project, a4x, a4y, a4z, b4x, b4y, b4z)
end

function DebugDraw.part_box(project, part)
    local cf = part.CFrame
    if not cf then return end
    local s = part.Size or {}
    local hx = (s.x or s.X or 1) * 0.5
    local hy = (s.y or s.Y or 1) * 0.5
    local hz = (s.z or s.Z or 1) * 0.5
    local R, U, L = cf.RightVector, cf.UpVector, cf.LookVector
    DebugDraw.obox(project, cf.x, cf.y, cf.z,
        R.x * hx, R.y * hx, R.z * hx,
        U.x * hy, U.y * hy, U.z * hy,
        -L.x * hz, -L.y * hz, -L.z * hz)
end

-- square perpendicular to the normal + a normal stub
function DebugDraw.plane(project, px, py, pz, nx, ny, nz, size)
    local nl = sqrt(nx * nx + ny * ny + nz * nz)
    if nl < 1e-6 then return end
    nx, ny, nz = nx / nl, ny / nl, nz / nl
    local ax, ay, az = 0, 1, 0
    if abs(ny) > 0.9 then ax, ay, az = 1, 0, 0 end
    local t1x, t1y, t1z = ny * az - nz * ay, nz * ax - nx * az, nx * ay - ny * ax
    local l1 = sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
    if l1 < 1e-6 then return end
    t1x, t1y, t1z = t1x / l1 * size, t1y / l1 * size, t1z / l1 * size
    local t2x, t2y, t2z = ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
    local c1x, c1y, c1z = px + t1x + t2x, py + t1y + t2y, pz + t1z + t2z
    local c2x, c2y, c2z = px + t1x - t2x, py + t1y - t2y, pz + t1z - t2z
    local c3x, c3y, c3z = px - t1x - t2x, py - t1y - t2y, pz - t1z - t2z
    local c4x, c4y, c4z = px - t1x + t2x, py - t1y + t2y, pz - t1z + t2z
    line3(project, c1x, c1y, c1z, c2x, c2y, c2z); line3(project, c2x, c2y, c2z, c3x, c3y, c3z)
    line3(project, c3x, c3y, c3z, c4x, c4y, c4z); line3(project, c4x, c4y, c4z, c1x, c1y, c1z)
    line3(project, px, py, pz, px + nx * size, py + ny * size, pz + nz * size)
end

function DebugDraw.dot(project, px, py, pz, size)
    local sx, sy = project(px, py, pz)
    if sx then love.graphics.circle("fill", sx, sy, size or 3) end
end

-- nearest face to a world position, via local-space axis distances
function DebugDraw.getSurface(position, part)
    local cf = part.CFrame
    if not cf or not cf.PointToObjectSpace then return "back" end
    local lp = cf:PointToObjectSpace(position)
    local s = part.Size or {}
    local hx = (s.x or s.X or 1) * 0.5
    local hy = (s.y or s.Y or 1) * 0.5
    local hz = (s.z or s.Z or 1) * 0.5
    local rx = hx > 0 and abs(lp.x) / hx or 0
    local ry = hy > 0 and abs(lp.y) / hy or 0
    local rz = hz > 0 and abs(lp.z) / hz or 0
    if rx >= ry and rx >= rz then
        return lp.x >= 0 and "right" or "left"
    elseif ry >= rz then
        return lp.y >= 0 and "top" or "bottom"
    end
    return lp.z >= 0 and "back" or "front"
end

-- Developer world overlay. CPU data is scalar-owned and bounded, it never calls
-- a resolver, query, collider constructor (which writes caches), or world update
local LIMIT, RADIUS, CONTACT_LIMIT = 128, 120, 128
local I, Shape
local templates = {}
local function template(kind)
    if templates[kind] then return templates[kind] end
    local a = {}; templates[kind] = a
    local function seg(x,y,z,u,v,w) a[#a+1]={x,y,z,u,v,w} end
    if kind == 'ball' or kind == 'cylinder' then
        for j=0,23 do
            local c,s=math.cos(j*math.pi/12),math.sin(j*math.pi/12)
            local d,t=math.cos((j+1)*math.pi/12),math.sin((j+1)*math.pi/12)
            if kind=='ball' then
                seg(0,c,s,0,d,t);seg(c,0,s,d,0,t);seg(c,s,0,d,t,0)
            else
                seg(-1,c,s,-1,d,t);seg(1,c,s,1,d,t)
                if j%6==0 then seg(-1,c,s,1,c,s) end
            end
        end
    else
        for _,v in ipairs({-1,1}) do for _,w in ipairs({-1,1}) do
            seg(-1,v,w,1,v,w);seg(v,-1,w,v,1,w);seg(v,w,-1,v,w,1)
        end end
    end
    return a
end
local function state_name(b) return not b and 'UNKNOWN' or b.is_static and 'STATIC' or b.sleeping and 'SLEEP' or 'AWAKE' end
local colors={STATIC={.6,.75,1},SLEEP={1,.6,.1},AWAKE={.15,1,.35},UNKNOWN={1,1,1},RENDER={.1,.9,1},CONTACT={1,.2,.8}}
-- Immutable, camera-facing stroke glyphs. Separate from the collision outline
local state_glyphs={
    STATIC={letter='S',{.4,.5,-.4,.5},{-.4,.5,-.4,0},{-.4,0,.4,0},{.4,0,.4,-.5},{.4,-.5,-.4,-.5}},
    AWAKE={letter='A',{-.4,-.5,0,.5},{0,.5,.4,-.5},{-.2,0,.2,0}},
    SLEEP={letter='Z',{-.4,.5,.4,.5},{.4,.5,-.4,-.5},{-.4,-.5,.4,-.5}},
    UNKNOWN={letter='?',{-.4,.3,-.4,.5},{-.4,.5,.4,.5},{.4,.5,.4,.1},{.4,.1,0,-.1},{0,-.1,0,-.2},{-.05,-.5,.05,-.5}},
}
local function options(core)
    local g=rawget(_G,'G');local d=g and g.debug or {}
    local layer=d.rbx_layer or 'collision'
    if not core._physics_world and layer~='render' then layer='render' end
    return layer,d.rbx_depth=='xray' and 'xray' or 'depth'
end
-- bounded max-heap over the existing 128 entry slots. Equal distances keep
-- the original scan's first-slot eviction rule, so selection/order is unchanged
local function farther(entries,a,b)
    local da,db=entries[a].distance,entries[b].distance
    return da>db or (da==db and a<b)
end
local function slot(s,id,name,x,y,z)
    s.total=s.total+1
    local d=(x-s.camx)^2+(y-s.camy)^2+(z-s.camz)^2
    if d>RADIUS*RADIUS then return end
    local heap=s.selection_heap
    local index=s.count+1
    local replacing=index>LIMIT
    if replacing then
        index=heap[1]
        if d>=s.entries[index].distance then return end
    else s.count=index end
    local e=s.entries[index];if not e then e={};s.entries[index]=e end
    e.id,e.name,e.cx,e.cy,e.cz,e.distance=id,name,x,y,z,d
    if replacing then
        local at=1
        while at*2<=s.count do
            local child=at*2
            if child<s.count and farther(s.entries,heap[child+1],heap[child]) then child=child+1 end
            if not farther(s.entries,heap[child],index) then break end
            heap[at]=heap[child];at=child
        end
        heap[at]=index
    else
        local at=s.count
        while at>1 do
            local parent=math.floor(at/2)
            if not farther(s.entries,index,heap[parent]) then break end
            heap[at]=heap[parent];at=parent
        end
        heap[at]=index
    end
    return e
end
local function axes(e,qw,qx,qy,qz)
    e.rx,e.ux,e.fx,e.ry,e.uy,e.fy,e.rz,e.uz,e.fz=I.quat_to_matrix(qw,qx,qy,qz)
end
local function member(s,b,v,x,y,z,qw,qx,qy,qz,cf)
    if v._part and v._part._destroyed then return end
    local e=slot(s,v.id,(v._part and v._part.Name) or tostring(v.id),x,y,z)
    if not e then return end
    -- only the bounded candidate set keeps these synchronous temporary handles
    -- Hydrate final winners below, then clear all handles before publishing/draw
    e._body,e._view,e._cf=b,v,cf
    e._qw,e._qx,e._qy,e._qz=qw,qx,qy,qz
end
local function prepare_member(e)
    local b,v,cf=e._body,e._view,e._cf
    local qw,qx,qy,qz=e._qw,e._qx,e._qy,e._qz
    if cf then qw,qx,qy,qz=I.quat_from_matrix(cf.r00,cf.r01,cf.r02,cf.r10,cf.r11,cf.r12,cf.r20,cf.r21,cf.r22) end
    e.kind=v._nc_kind or Shape.kind_of(v)
    if v._nc_cached then e.hx,e.hy,e.hz=v._nc_hx,v._nc_hy,v._nc_hz
    else e.hx,e.hy,e.hz=Shape.half_extents(v) end
    e.radius=e.kind=='cylinder' and math.min(e.hy,e.hz) or math.min(e.hx,e.hy,e.hz)
    axes(e,qw,qx,qy,qz)
    e.state=state_name(b);e.collidable=v.CanCollide~=false
    e.approx=e.kind=='mesh' or e.kind=='wedge' or (v._part and v._part.ClassName=='UnionOperation')
    e.vx,e.vy,e.vz=b.vx or 0,b.vy or 0,b.vz or 0
    e.comx,e.comy,e.comz=b.com_x,b.com_y,b.com_z
    e.brx,e.bux,e.bfx,e.bry,e.buy,e.bfy,e.brz,e.buz,e.bfz=I.quat_to_matrix(b.qw or 1,b.qx or 0,b.qy or 0,b.qz or 0)
    e._body,e._view,e._cf=nil,nil,nil
    e._qw,e._qx,e._qy,e._qz=nil,nil,nil,nil
end
local function collect(core,s)
    I=I or runtime_require('physics/integrate.lua');Shape=Shape or runtime_require('physics/shape.lua')
    s.scans=s.scans+1;s.count=0;s.total=0;s.unknown=0
    s.selection_heap=s.selection_heap or {}
    s.layer,s.mode=options(core)
    local cam=core.camera.cframe;s.camx,s.camy,s.camz=cam.x,cam.y,cam.z
    local w=core._physics_world;s.tick=w and w.step_index or nil
    if s.layer=='render' then
        for _,p in ipairs(core.parts or {}) do if not p._destroyed then
            -- this is exactly the renderer's culling cache, not a new asset lookup
            local a=p._rb_cache
            if a and a.cf==p.CFrame and a.remote_mesh_revision==(core._remote_mesh_asset_revision or 0) then
                local e=slot(s,p._id,p.Name,(a.min_x+a.max_x)/2,(a.min_y+a.max_y)/2,(a.min_z+a.max_z)/2)
                if e then
                    e.hx,e.hy,e.hz=(a.max_x-a.min_x)/2,(a.max_y-a.min_y)/2,(a.max_z-a.min_z)/2
                    axes(e,1,0,0,0);e.kind='bounds';e.approx=false;e.collidable=true
                    local asm=w and w.part_to_assembly[p._id];e.state=state_name(asm and asm.body)
                    e.lod=p._mesh_lod_index or 'not exposed';e.resource_revision=a.remote_mesh_revision
                end
            else s.total=s.total+1;s.unknown=s.unknown+1 end
        end end
    elseif s.layer=='broadphase' and w.broadphase then
        for _,map in ipairs({w.broadphase.static_proxies,w.broadphase.dynamic_proxies,w.broadphase.sleeping_proxies}) do
            for id,p in pairs(map) do local a=p.aabb
                local e=slot(s,id,'proxy '..id,(a[1]+a[4])/2,(a[2]+a[5])/2,(a[3]+a[6])/2)
                if e then
                    e.hx,e.hy,e.hz=(a[4]-a[1])/2,(a[5]-a[2])/2,(a[6]-a[3])/2
                    axes(e,1,0,0,0);e.kind='proxy';e.approx=false;e.collidable=true
                    local asm=w.assemblies_by_id[id];e.state=state_name(asm and asm.body)
                end
            end
        end
    elseif w then
        for _,b in ipairs(w.bodies) do
            if b.is_static then
                for _,v in ipairs(b.assembly.parts) do
                    local p,cf=v.Position,v.CFrameRef
                    if cf then
                        member(s,b,v,p.x,p.y,p.z,nil,nil,nil,nil,cf)
                    else s.unknown=s.unknown+1;s.total=s.total+1 end
                end
            elseif b.local_offsets then
                for _,o in ipairs(b.local_offsets) do
                    local x,y,z=I.rotate_vec(b.qw,b.qx,b.qy,b.qz,o.lx,o.ly,o.lz)
                    local qw,qx,qy,qz=I.quat_mul(b.qw,b.qx,b.qy,b.qz,o.qw or 1,o.qx or 0,o.qy or 0,o.qz or 0)
                    member(s,b,o.view,b.com_x+x,b.com_y+y,b.com_z+z,qw,qx,qy,qz)
                end
            else s.unknown=s.unknown+1;s.total=s.total+1 end
        end
    end
    for k=1,s.count do
        local e=s.entries[k]
        if e._body then prepare_member(e) end
    end
    -- entries contain only scalar values. no retired body/resource handles survive
    for k=s.count+1,#s.entries do s.entries[k]=nil end
    for k=s.count+1,#s.selection_heap do s.selection_heap[k]=nil end
    table.sort(s.entries,function(a,b) if a.distance==b.distance then return a.id<b.id end;return a.distance<b.distance end)
    for k in pairs(s.counts) do s.counts[k]=0 end
    for k=1,s.count do local e=s.entries[k]
        s.counts[e.kind]=(s.counts[e.kind] or 0)+1;s.counts[e.state]=(s.counts[e.state] or 0)+1
        if e.approx then s.counts.approx=s.counts.approx+1 end
    end
end
local shader_code=[[
#ifdef VERTEX
attribute vec3 DebugEnd;
attribute vec2 DebugCorner;
uniform mat4 DebugView;
uniform mat4 DebugProjection;
uniform vec2 DebugViewport;
vec4 position(mat4 unused, vec4 a) {
    vec4 p=DebugProjection*DebugView*a;
    vec4 q=DebugProjection*DebugView*vec4(DebugEnd,1.0);
    // Homogeneous near clipping before the pixel-width expansion. The GPU
    // clips far/side planes normally; no 2D projection streak across w=0.
    float dp=p.z+p.w, dq=q.z+q.w;
    if(dp<0.0 && dq<0.0) return vec4(0.0,0.0,2.0,1.0);
    if(dp<0.0) p=mix(p,q,dp/(dp-dq));
    if(dq<0.0) q=mix(q,p,dq/(dq-max(p.z+p.w,0.0)));
    vec2 d=(q.xy/q.w-p.xy/p.w)*DebugViewport;
    float n=length(d);
    vec2 side=n>0.00001 ? vec2(-d.y,d.x)/n : vec2(1.0,0.0);
    vec4 r=mix(p,q,DebugCorner.x);
    r.xy+=side*DebugCorner.y*1.5/DebugViewport*r.w;
    return r;
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image image, vec2 uv, vec2 screen) { return color; }
#endif
]]
local format={{'VertexPosition','float',3},{'DebugEnd','float',3},{'DebugCorner','float',2},{'VertexColor','float',4}}
local corners={{0,-1},{1,-1},{1,1},{0,-1},{1,1},{0,1}}
local MAX_SEGMENTS=LIMIT*86+CONTACT_LIMIT*4+512
local function line(s,ax,ay,az,bx,by,bz,r,g,b)
    if s.monochrome then r,g,b=1,1,1 end -- internal capture-only common palette
    if s.segments>=MAX_SEGMENTS then s.segment_omitted=s.segment_omitted+1;return end
    if ax~=ax or ay~=ay or az~=az or bx~=bx or by~=by or bz~=bz then s.segment_omitted=s.segment_omitted+1;return end
    s.segments=s.segments+1
    local n=(s.segments-1)*6
    for j=1,6 do
        local v=s.vertices[n+j];if not v then v={};s.vertices[n+j]=v end
        local dirty=v[1]~=ax or v[2]~=ay or v[3]~=az or v[4]~=bx or v[5]~=by or v[6]~=bz or v[9]~=r or v[10]~=g or v[11]~=b
        if dirty then
            v[1],v[2],v[3],v[4],v[5],v[6]=ax,ay,az,bx,by,bz
            v[7],v[8],v[9],v[10],v[11],v[12]=corners[j][1],corners[j][2],r,g,b,1
            s.mesh:setVertex(n+j,v);s.uploads=s.uploads+1
        end
    end
end
local function point(e,x,y,z)
    return e.cx+e.rx*x+e.ux*y+e.fx*z,e.cy+e.ry*x+e.uy*y+e.fy*z,e.cz+e.rz*x+e.uz*y+e.fz*z
end
local function geometry(core,s)
    s.segments=0;s.segment_omitted=0;s.contact_count=0;s.contact_total=0
    s.cue_count=0;s.contact_drawn=0;s.monochrome=core._debug_wire_monochrome==true
    local cam=core.camera.cframe
    local _,height=core:_get_projection_dimensions()
    for k=1,s.count do local e=s.entries[k]
        local rgb=colors[s.layer=='render' and 'RENDER' or e.state];local r,g,b=rgb[1],rgb[2],rgb[3]
        local hx,hy,hz=e.hx,e.hy,e.hz
        if e.kind=='ball' then hx,hy,hz=e.radius,e.radius,e.radius
        elseif e.kind=='cylinder' then hy,hz=e.radius,e.radius end
        local shape=template(e.kind)
        for j=1,#shape do local v=shape[j]
            local ax,ay,az=point(e,v[1]*hx,v[2]*hy,v[3]*hz)
            local bx,by,bz=point(e,v[4]*hx,v[5]*hy,v[6]*hz)
            line(s,ax,ay,az,bx,by,bz,r,g,b)
        end
        if s.layer=='motion' then
            line(s,e.comx,e.comy,e.comz,e.comx+e.vx*.25,e.comy+e.vy*.25,e.comz+e.vz*.25,1,1,.1)
            line(s,e.comx,e.comy,e.comz,e.comx+e.brx,e.comy+e.bry,e.comz+e.brz,1,.1,.1)
            line(s,e.comx,e.comy,e.comz,e.comx+e.bux,e.comy+e.buy,e.comz+e.buz,.1,1,.1)
            line(s,e.comx,e.comy,e.comz,e.comx+e.bfx,e.comy+e.bfy,e.comz+e.bfz,.1,.4,1)
        end
        -- a 12-pixel glyph above the world-axis top, with a short association
        -- stem. World vertices pass through the same shader/depth as outlines
        local top=math.abs(e.ry)*hx+math.abs(e.uy)*hy+math.abs(e.fy)*hz
        local tx,ty,tz=e.cx,e.cy+top,e.cz
        local depth=-((tx-cam.x)*cam.r02+(ty-cam.y)*cam.r12+(tz-cam.z)*cam.r22)
        -- Canvas projection may flip Y. its magnitude sets world size, the
        -- camera's actual up/right axes still determine readable glyphs
        local scale=24*math.max(.5,depth)/(height*math.abs(core._projection_matrix[6]))
        e.cue_x,e.cue_y,e.cue_z=tx+cam.r01*scale,ty+cam.r11*scale,tz+cam.r21*scale
        e.cue_scale=scale;e.cue_first_segment=s.segments+1
        local glyph=state_glyphs[e.state] or state_glyphs.UNKNOWN;e.cue=glyph.letter
        for j=1,#glyph do local v=glyph[j]
            line(s,e.cue_x+scale*(cam.r00*v[1]+cam.r01*v[2]),e.cue_y+scale*(cam.r10*v[1]+cam.r11*v[2]),e.cue_z+scale*(cam.r20*v[1]+cam.r21*v[2]),
                e.cue_x+scale*(cam.r00*v[3]+cam.r01*v[4]),e.cue_y+scale*(cam.r10*v[3]+cam.r11*v[4]),e.cue_z+scale*(cam.r20*v[3]+cam.r21*v[4]),r,g,b)
        end
        line(s,tx,ty,tz,e.cue_x-cam.r01*scale*.65,e.cue_y-cam.r11*scale*.65,e.cue_z-cam.r21*scale*.65,r,g,b)
        e.cue_segment_count=s.segments-e.cue_first_segment+1;s.cue_count=s.cue_count+1
    end
    if s.layer=='motion' then
        local w=core._physics_world
        for _,m in ipairs(w and w.manifold_cache.list or {}) do
            if m.last_step==w.step_index and (m.inactive_frames or 0)==0
                and not (m.view_a._part and m.view_a._part._destroyed)
                and not (m.view_b._part and m.view_b._part._destroyed) then
                for _,p in ipairs(m.points) do
                    s.contact_total=s.contact_total+1
                    if s.contact_count<CONTACT_LIMIT then
                        s.contact_count=s.contact_count+1
                        local n=s.contact_count;local c=s.contacts[n];if not c then c={};s.contacts[n]=c end
                        c.tick,c.x,c.y,c.z,c.nx,c.ny,c.nz=w.step_index,p.px,p.py,p.pz,m.normal_x,m.normal_y,m.normal_z
                        c.a,c.b=m.part_a_id,m.part_b_id
                        -- internal untimed OFF/ON oracle: collect the same live
                        -- snapshot, suppress only its pixels, never the solve
                        if not core._debug_contacts_hidden then
                            line(s,c.x,c.y,c.z,c.x+c.nx*.6,c.y+c.ny*.6,c.z+c.nz*.6,1,.2,.8)
                            line(s,c.x-.1,c.y,c.z,c.x+.1,c.y,c.z,1,.2,.8)
                            line(s,c.x,c.y-.1,c.z,c.x,c.y+.1,c.z,1,.2,.8)
                            s.contact_drawn=s.contact_drawn+1
                        end
                    end
                end
            end
        end
        for k=s.contact_count+1,#s.contacts do s.contacts[k]=nil end
        for _,r in ipairs(core._debug_raycasts or {}) do line(s,r.ox,r.oy,r.oz,r.hx,r.hy,r.hz,1,1,.1) end
        for _,r in ipairs(core._debug_regions or {}) do
            for _,v in ipairs(template('block')) do
                local function pos(x,y,z) return x<0 and r.minx or r.maxx,y<0 and r.miny or r.maxy,z<0 and r.minz or r.maxz end
                local ax,ay,az=pos(v[1],v[2],v[3]);local bx,by,bz=pos(v[4],v[5],v[6])
                line(s,ax,ay,az,bx,by,bz,.1,.6,1)
            end
        end
    end
    s.mesh:setDrawRange(1,math.max(1,s.segments*6))
end
function DebugDraw.world(core)
    local started=love.timer.getTime()
    local s=core._debug_wire
    if not s then
        s={entries={},vertices={},contacts={},counts={approx=0},scans=0,uploads=0,segments=0};core._debug_wire=s
    end
    if not core._debug_wire_mesh then
        core._debug_wire_mesh=love.graphics.newMesh(format,MAX_SEGMENTS*6,'triangles','dynamic')
        s.vertices={}
    end
    if not core._debug_wire_shader then core._debug_wire_shader=love.graphics.newShader(shader_code) end
    s.mesh=core._debug_wire_mesh
    collect(core,s);geometry(core,s)
    local shader=core._debug_wire_shader
    love.graphics.push('all')
    local ok,err=xpcall(function()
        love.graphics.origin();love.graphics.setScissor();love.graphics.setStencilTest();love.graphics.setWireframe(false)
        love.graphics.setColorMask(true,true,true,true);love.graphics.setColor(1,1,1,1)
        love.graphics.setShader(shader);love.graphics.setMeshCullMode('none');love.graphics.setBlendMode('alpha','alphamultiply')
        love.graphics.setDepthMode(s.mode=='xray' and 'always' or 'lequal',false)
        shader:send('DebugView',core._view_matrix);shader:send('DebugProjection',core._projection_matrix)
        local w,h=core:_get_projection_dimensions();shader:send('DebugViewport',{w,h})
        if s.segments>0 then love.graphics.draw(s.mesh) end
    end,debug.traceback)
    love.graphics.pop();if not ok then error(err,0) end
    s.cpu_ms=(love.timer.getTime()-started)*1000
    s.avg_cpu_ms=s.avg_cpu_ms and (s.avg_cpu_ms*.94+s.cpu_ms*.06) or s.cpu_ms
end
function DebugDraw.legend(core)
    local s=core._debug_wire;if not s then return {'RBX debug: awaiting scene draw'} end
    local c=s.counts
    local lines={
        'RBX debug | 0 toggle | F7 layer | F8 depth / X-RAY',
        string.format('%s | %s | nearest %d / %d within %d studs; omitted %d, unknown %d',s.layer,s.mode,s.count,s.total,RADIUS,s.total-s.count,s.unknown),
        string.format('S static/anchored %d | A awake %d | Z sleeping %d | ? unavailable %d',c.STATIC or 0,c.AWAKE or 0,c.SLEEP or 0,c.UNKNOWN or 0),
        string.format('State glyphs %d/%d | cap128 | detailed labels nearest %d/%d',s.cue_count,s.count,math.min(6,s.count),s.count),
        'Box approximations: mesh / union / wedge. SpecialMesh retains parent collider.',
        'Cylinder: Ball/Block/Cylinder tested; other pairs approximated; no general CCD.',
        core._physics_world and ('Physics '..(core.physics_enabled and 'enabled' or 'DISABLED')..' | tick '..tostring(s.tick)..' | islands: unavailable') or 'Physics disabled / unbound (debug does not create a world)',
        string.format('Scene CPU submission %.3f ms | draws %d (excludes this world overlay)',core._last_draw_submission_ms or 0,(core._draw_stats or {}).draw_call_count or 0),
    }
    if s.layer=='render' then lines[#lines+1]='Render: cached culling AABBs; selected LOD uses its conservative render envelope. Cyan; glyph = body state.' end
    if s.layer=='broadphase' then lines[#lines+1]='Broadphase: actual proxy bounds, including expansion; NOT contact surfaces.' end
    if s.layer=='motion' then lines[#lines+1]=string.format('Contacts %d / %d at tick %s (retained on zero-step frames); velocity yellow = 0.25 seconds',s.contact_count,s.contact_total,tostring(s.tick)) end
    if s.segment_omitted>0 then lines[#lines+1]='Segment cap omitted '..s.segment_omitted end
    s.label_cache=s.label_cache or {}
    for k=1,math.min(6,s.count) do local e=s.entries[k]
        local row=s.label_cache[k];if not row then row={};s.label_cache[k]=row end
        if row.id~=e.id or row.name~=e.name or row.state~=e.state or row.kind~=e.kind or row.approx~=e.approx or row.collidable~=e.collidable then
            row.id,row.name,row.state,row.kind,row.approx,row.collidable=e.id,e.name,e.state,e.kind,e.approx,e.collidable
            row.text=string.format('%s [%s] %s %s%s%s',tostring(e.name),tostring(e.id),e.state,e.kind,e.approx and ' BOX APPROX' or '',e.collidable==false and ' CanCollide=false' or '')
            s.label_formats=(s.label_formats or 0)+1
        end
        lines[#lines+1]=row.text
    end
    return lines
end
return DebugDraw
