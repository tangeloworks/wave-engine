-- Translational CCD for moving rigid block/ball members. the regular solver
-- owns resting contacts, friction, restitution and angular response. this pass
-- only prevents a previously separated pair crossing between samples
local I=runtime_require('physics/integrate.lua')
local N=runtime_require('physics/narrowphase.lua')
local Shape=runtime_require('physics/shape.lua')
local Convex=runtime_require('physics/convex_decomposition.lua')
local C={}
local abs,min,max,sqrt=math.abs,math.min,math.max,math.sqrt
local EPS=1e-8

local function supported(c) return c.kind=='block' or c.kind=='mesh' or c.kind=='ball' or c.convex~=nil or c.poly~=nil end
function C.supports_view(view)
    local kind=Shape.kind_of(view)
    return kind=='block'or kind=='mesh'or kind=='ball'or kind=='convex_decomposition'
end
local function axis(c,i) return c['u'..i..'x'],c['u'..i..'y'],c['u'..i..'z'] end
local function radius(c,x,y,z)
    return abs(x*c.u0x+y*c.u0y+z*c.u0z)*c.hx
        +abs(x*c.u1x+y*c.u1y+z*c.u1z)*c.hy
        +abs(x*c.u2x+y*c.u2y+z*c.u2z)*c.hz
end

-- exact swept SAT for OBBs with fixed orientation. Normal points A -> B
local function boxes(a,b,dx,dy,dz)
    local px,py,pz=b.cx-a.cx,b.cy-a.cy,b.cz-a.cz
    local enter,leave=-math.huge,math.huge
    local nx,ny,nz=0,0,0
    local function test(x,y,z)
        local norm=x*x+y*y+z*z
        if norm<1e-12 then return true end
        local r=radius(a,x,y,z)+radius(b,x,y,z)
        local p=px*x+py*y+pz*z;local v=dx*x+dy*y+dz*z
        if abs(v)<1e-12 then return abs(p)<=r end
        local lo,hi=(-r-p)/v,(r-p)/v
        if lo>hi then lo,hi=hi,lo end
        if lo>enter then
            enter=lo;local s=(p+v*lo)<0 and -1 or 1;s=s/sqrt(norm)
            nx,ny,nz=x*s,y*s,z*s
        end
        leave=min(leave,hi)
        return enter<=leave
    end
    for i=0,2 do
        local x,y,z=axis(a,i);if not test(x,y,z) then return end
        x,y,z=axis(b,i);if not test(x,y,z) then return end
    end
    for i=0,2 do for j=0,2 do
        local x,y,z=axis(a,i);local u,v,w=axis(b,j)
        if not test(y*w-z*v,z*u-x*w,x*v-y*u) then return end
    end end
    if enter>=-EPS and enter<1-EPS and leave>EPS then return max(0,enter),nx,ny,nz end
end

local function balls(a,b,dx,dy,dz)
    local x,y,z=b.cx-a.cx,b.cy-a.cy,b.cz-a.cz
    local r=a.radius+b.radius;local aa=dx*dx+dy*dy+dz*dz
    local bb=x*dx+y*dy+z*dz;local cc=x*x+y*y+z*z-r*r
    if cc< -EPS or aa<EPS or bb>=0 then return end
    local disc=bb*bb-aa*cc;if disc<0 then return end
    local t=(-bb-sqrt(disc))/aa
    if t>=-EPS and t<1-EPS then
        t=max(0,t);x,y,z=x+dx*t,y+dy*t,z+dz*t
        local n=sqrt(x*x+y*y+z*z);return t,x/n,y/n,z/n
    end
end

-- a sphere's squared distance to a box is quadratic between the times its
-- centre crosses each face plane. this includes rounded edges/corners exactly;
-- simply expanding the OBB would stop near-misses at its square corners
local function sphere_box(s,b,dx,dy,dz)
    local x,y,z=s.cx-b.cx,s.cy-b.cy,s.cz-b.cz
    local p={x*b.u0x+y*b.u0y+z*b.u0z,x*b.u1x+y*b.u1y+z*b.u1z,x*b.u2x+y*b.u2y+z*b.u2z}
    local v={dx*b.u0x+dy*b.u0y+dz*b.u0z,dx*b.u1x+dy*b.u1y+dz*b.u1z,dx*b.u2x+dy*b.u2y+dz*b.u2z}
    local h={b.hx,b.hy,b.hz};local cuts={0,1};local distance=0
    for i=1,3 do
        local d=max(0,abs(p[i])-h[i]);distance=distance+d*d
        if abs(v[i])>EPS then for _,side in ipairs({-1,1}) do
            local t=(side*h[i]-p[i])/v[i];if t>0 and t<1 then cuts[#cuts+1]=t end
        end end
    end
    if distance<s.radius*s.radius-EPS then return end
    table.sort(cuts)
    for k=1,#cuts-1 do
        local lo,hi=cuts[k],cuts[k+1];local mid=(lo+hi)*.5
        local aa,bb,cc=0,0,-s.radius*s.radius
        for i=1,3 do
            local pm=p[i]+v[i]*mid
            if abs(pm)>h[i] then
                local q=p[i]-(pm<0 and -h[i] or h[i])
                aa=aa+v[i]*v[i];bb=bb+q*v[i];cc=cc+q*q
            end
        end
        local disc=bb*bb-aa*cc
        if aa>EPS and disc>=0 then
            local t=(-bb-sqrt(disc))/aa
            if t>=lo-EPS and t<=hi+EPS and t<1-EPS then
                t=max(0,t);local normal={}
                for i=1,3 do
                    local q=p[i]+v[i]*t;normal[i]=q-max(-h[i],min(h[i],q))
                end
                local nx=normal[1]*b.u0x+normal[2]*b.u1x+normal[3]*b.u2x
                local ny=normal[1]*b.u0y+normal[2]*b.u1y+normal[3]*b.u2y
                local nz=normal[1]*b.u0z+normal[2]*b.u1z+normal[3]*b.u2z
                local length=sqrt(nx*nx+ny*ny+nz*nz)
                if length>EPS then return t,-nx/length,-ny/length,-nz/length end
            end
        end
    end
end

local function rotate(c,x,y,z)
    return x*c.u0x+y*c.u1x+z*c.u2x,x*c.u0y+y*c.u1y+z*c.u2y,x*c.u0z+y*c.u1z+z*c.u2z
end
local function projection(c,x,y,z)
    local center=c.cx*x+c.cy*y+c.cz*z
    if not c.poly then local r=radius(c,x,y,z);return center-r,center+r end
    local lx,ly,lz=x*c.u0x+y*c.u0y+z*c.u0z,x*c.u1x+y*c.u1y+z*c.u1z,x*c.u2x+y*c.u2y+z*c.u2z
    local lo,hi=math.huge,-math.huge
    for _,v in ipairs(c.poly.vertices)do local d=v[1]*lx+v[2]*ly+v[3]*lz;lo=min(lo,d);hi=max(hi,d)end
    return lo+center,hi+center
end
local function poly_sweep(a,b,dx,dy,dz)
    local enter,leave=-math.huge,math.huge;local nx,ny,nz
    local function test(x,y,z)
        local length=sqrt(x*x+y*y+z*z);if length<1e-10 then return true end
        x,y,z=x/length,y/length,z/length
        local al,ah=projection(a,x,y,z);local bl,bh=projection(b,x,y,z)
        local lo,hi=bl-ah,bh-al;local speed=dx*x+dy*y+dz*z
        if abs(speed)<1e-12 then return lo<=0 and hi>=0 end
        local first,last=-hi/speed,-lo/speed;local sign=-1
        if first>last then first,last=last,first;sign=1 end
        if first>enter then enter=first;nx,ny,nz=x*sign,y*sign,z*sign end
        leave=min(leave,last);return enter<=leave
    end
    local function faces(c)
        if c.poly then for _,p in ipairs(c.poly.planes)do if not test(rotate(c,p[1],p[2],p[3]))then return false end end
        else for i=0,2 do if not test(axis(c,i))then return false end end end
        return true
    end
    if not faces(a)or not faces(b)then return end
    local function edges(c)
        local out={}
        if c.poly then for _,e in ipairs(c.poly.edges)do local p,q=c.poly.vertices[e[1]],c.poly.vertices[e[2]];out[#out+1]={rotate(c,q[1]-p[1],q[2]-p[2],q[3]-p[3])}end
        else for i=0,2 do out[#out+1]={axis(c,i)}end end
        return out
    end
    for _,u in ipairs(edges(a))do for _,v in ipairs(edges(b))do
        if not test(u[2]*v[3]-u[3]*v[2],u[3]*v[1]-u[1]*v[3],u[1]*v[2]-u[2]*v[1])then return end
    end end
    if enter>=-EPS and enter<1-EPS and leave>EPS then return max(0,enter),nx,ny,nz end
end
local function sphere_poly(s,b,dx,dy,dz)
    local x,y,z=s.cx-b.cx,s.cy-b.cy,s.cz-b.cz
    local px,py,pz=x*b.u0x+y*b.u0y+z*b.u0z,x*b.u1x+y*b.u1y+z*b.u1z,x*b.u2x+y*b.u2y+z*b.u2z
    local vx,vy,vz=dx*b.u0x+dy*b.u0y+dz*b.u0z,dx*b.u1x+dy*b.u1y+dz*b.u1z,dx*b.u2x+dy*b.u2y+dz*b.u2z
    local bounds=b.poly.bounds;local near,far=0,1
    for i,p in ipairs{px,py,pz}do
        local speed=({vx,vy,vz})[i];local lo,hi=bounds[i]-s.radius,bounds[i+3]+s.radius
        if abs(speed)<1e-12 then if p<lo or p>hi then return end
        else local a,c=(lo-p)/speed,(hi-p)/speed;if a>c then a,c=c,a end;near=max(near,a);far=min(far,c);if near>far then return end end
    end
    local time=0
    -- conservative advancement of the exact finite-convex distance. a sphere
    -- reaches rounded edges/corners, rather than an expanded square bound
    for iteration=1,64 do
        local d,nx,ny,nz=Convex.closest(b.poly,px+vx*time,py+vy*time,pz+vz*time)
        local gap=d-s.radius
        if iteration==1 and gap< -EPS then return end
        if gap<=1e-8 then local wx,wy,wz=rotate(b,nx,ny,nz);return time,-wx,-wy,-wz end
        local approach=-(vx*nx+vy*ny+vz*nz);if approach<=1e-12 then return end
        time=time+gap/approach;if time>=1-EPS then return end
    end
    error('Convex sphere sweep did not converge')
end
local function piece(c,h)
    return {kind='convex_piece',poly=h,cx=c.cx,cy=c.cy,cz=c.cz,
        u0x=c.u0x,u0y=c.u0y,u0z=c.u0z,u1x=c.u1x,u1y=c.u1y,u1z=c.u1z,u2x=c.u2x,u2y=c.u2y,u2z=c.u2z}
end
local function primitives(a,b,dx,dy,dz)
    if a.poly or b.poly then
        if a.kind=='ball'then return sphere_poly(a,b,-dx,-dy,-dz)end
        if b.kind=='ball'then local t,x,y,z=sphere_poly(b,a,dx,dy,dz);if t then return t,-x,-y,-z end;return end
        return poly_sweep(a,b,dx,dy,dz)
    end
    if not supported(a) or not supported(b) then return end
    if a.kind=='ball' and b.kind=='ball' then return balls(a,b,dx,dy,dz) end
    if a.kind=='ball' then return sphere_box(a,b,-dx,-dy,-dz) end
    if b.kind=='ball' then
        local t,x,y,z=sphere_box(b,a,dx,dy,dz)
        if t then return t,-x,-y,-z end;return
    end
    return boxes(a,b,dx,dy,dz)
end
function C.sweep(a,b,dx,dy,dz)
    if not supported(a)or not supported(b)then return end
    if not a.convex and not b.convex then return primitives(a,b,dx,dy,dz)end
    local best,nx,ny,nz,ai,bi=1
    for i=1,(a.convex and #a.convex or 1)do for j=1,(b.convex and #b.convex or 1)do
        local ca=a.convex and piece(a,a.convex[i])or a
        local cb=b.convex and piece(b,b.convex[j])or b
        local t,x,y,z=primitives(ca,cb,dx,dy,dz)
        if t and t<best then best,nx,ny,nz,ai,bi=t,x,y,z,i,j end
    end end
    if nx then return best,nx,ny,nz,ai,bi end
end

local function allowed(world,a,b)
    if a.CanCollide==false or b.CanCollide==false then return false end
    if not world.collision_groups:collidable(a.CollisionGroup,b.CollisionGroup) then return false end
    if next(world.no_collision) then
        local x,y=tostring(a.id),tostring(b.id)
        if world.no_collision[x<y and x..':'..y or y..':'..x] then return false end
    end
    return true
end

-- called before the bound static view is updated. only physics-callback edits
-- are prescribed motion, ordinary API teleports retain their existing meaning
function C.record_static(world,body,view,newcf)
    if not world._ccd_collecting or not world.config.ccd_enabled or view.CanCollide==false then return end
    local old=view.CFrameRef;if not old or not newcf then return end
    local motions=world._ccd_static_motions
    if not motions then motions={};world._ccd_static_motions=motions end
    local m=motions[body.id]
    if not m then
        m={body=body,view=view,cf=old};motions[body.id]=m
    end
    m.dx,m.dy,m.dz=newcf.x-m.cf.x,newcf.y-m.cf.y,newcf.z-m.cf.z
    m.rotating=false
    for _,key in ipairs({'r00','r01','r02','r10','r11','r12','r20','r21','r22'}) do
        if abs((newcf[key] or 0)-(m.cf[key] or 0))>1e-6 then m.rotating=true end
    end
end

function C.capture(world)
    for i=1,world.active_count do
        local b=world.active_bodies[i]
        b._ccd_x,b._ccd_y,b._ccd_z=b.com_x,b.com_y,b.com_z
        b._ccd_qw,b._ccd_qx,b._ccd_qy,b._ccd_qz=b.qw,b.qx,b.qy,b.qz
        b._ccd_epoch=world.step_index
    end
end

local function motion(world,b)
    local prescribed=world._ccd_static_motions and world._ccd_static_motions[b.id]
    local m=b._ccd_record or {members={}};b._ccd_record=m
    if m.epoch==world.step_index then return m end
    m.epoch=world.step_index;m.body=b;m.count=0
    m.x,m.y,m.z=b.com_x,b.com_y,b.com_z
    m.dx,m.dy,m.dz=0,0,0;m.prescribed=nil
    local qw,qx,qy,qz=b.qw,b.qx,b.qy,b.qz
    if prescribed and not prescribed.rotating and prescribed.body==b then
        m.prescribed=true;m.dx,m.dy,m.dz=prescribed.dx,prescribed.dy,prescribed.dz
        m.x,m.y,m.z=b.com_x-m.dx,b.com_y-m.dy,b.com_z-m.dz
    elseif not b.is_static and b._ccd_epoch==world.step_index then
        m.x,m.y,m.z=b._ccd_x,b._ccd_y,b._ccd_z
        m.dx,m.dy,m.dz=b.com_x-m.x,b.com_y-m.y,b.com_z-m.z
        qw,qx,qy,qz=b._ccd_qw,b._ccd_qx,b._ccd_qy,b._ccd_qz
    end
    m.lx,m.ly,m.lz=math.huge,math.huge,math.huge
    m.rx,m.ry,m.rz=-math.huge,-math.huge,-math.huge
    m.minhalf=math.huge
    local offsets=b.local_offsets or {}
    for i=1,b.part_count or #b.parts do
        local view=b.parts[i]
        if view.CanCollide~=false then
            local x,y,z,w,ax,ay,az
            if b.is_static then
                local cf=m.prescribed and prescribed.cf or view.CFrameRef
                if cf then
                    x,y,z=cf.x,cf.y,cf.z
                    w,ax,ay,az=I.quat_from_matrix(cf.r00,cf.r01,cf.r02,cf.r10,cf.r11,cf.r12,cf.r20,cf.r21,cf.r22)
                else
                    local p=view.Position or {}
                    x,y,z=p.x or p.X or 0,p.y or p.Y or 0,p.z or p.Z or 0
                    w,ax,ay,az=1,0,0,0
                end
            else
                local o=offsets[i]
                if o then
                    x,y,z=I.rotate_vec(qw,qx,qy,qz,o.lx,o.ly,o.lz)
                    x,y,z=m.x+x,m.y+y,m.z+z
                    w,ax,ay,az=I.quat_mul(qw,qx,qy,qz,o.qw or 1,o.qx or 0,o.qy or 0,o.qz or 0)
                else x,y,z=m.x,m.y,m.z;w,ax,ay,az=qw,qx,qy,qz end
            end
            if x then
                local index=m.count+1;local c=m.members[index] or {};m.members[index]=c
                N.make_collider(c,view,x,y,z,w,ax,ay,az);c.view=view
                if supported(c) then
                    m.count=index;m.minhalf=min(m.minhalf,c.hx,c.hy,c.hz)
                    local hx,hy,hz=radius(c,1,0,0),radius(c,0,1,0),radius(c,0,0,1)
                    m.lx=min(m.lx,x-hx);m.ly=min(m.ly,y-hy);m.lz=min(m.lz,z-hz)
                    m.rx=max(m.rx,x+hx);m.ry=max(m.ry,y+hy);m.rz=max(m.rz,z+hz)
                end
            end
        end
    end
    return m
end

local function hit(world,a,b)
    if a.count==0 or b.count==0 then return end
    local dx,dy,dz=b.dx-a.dx,b.dy-a.dy,b.dz-a.dz
    local threshold=.5*min(a.minhalf,b.minhalf)
    -- Prescribed obstacles must not pass through a contact merely because
    -- their per-step travel is below the fast-body CCD threshold
    if not a.prescribed and not b.prescribed and dx*dx+dy*dy+dz*dz<threshold*threshold then return end
    local best,nx,ny,nz=1
    for i=1,a.count do for j=1,b.count do
        local ca,cb=a.members[i],b.members[j]
        if allowed(world,ca.view,cb.view) then
            local t,x,y,z=C.sweep(ca,cb,dx,dy,dz)
            if t and t<best then best,nx,ny,nz=t,x,y,z end
        end
    end end
    if best<1 then return best,nx,ny,nz end
end

-- exact member sweeps replace the old compound-union AABB for supported
-- geometry. a torso's half-depth must not be extended down to a sphere foot
-- Unsupported candidate shapes retain the existing legacy fallback
local function tunnel_or_deep(world,a,b,dx,dy,dz,nx,ny,nz)
    local travel=abs(dx*nx+dy*ny+dz*nz)
    local thickness=b.kind=='ball' and 2*b.radius or 2*radius(b,nx,ny,nz)
    if thickness<travel then return true end
    local x,y,z=a.cx+dx-b.cx,a.cy+dy-b.cy,a.cz+dz-b.cz
    local inside
    if b.kind=='ball' then inside=x*x+y*y+z*z<=b.radius*b.radius
    else inside=abs(x*b.u0x+y*b.u0y+z*b.u0z)<=b.hx
        and abs(x*b.u1x+y*b.u1y+z*b.u1z)<=b.hy
        and abs(x*b.u2x+y*b.u2y+z*b.u2z)<=b.hz end
    if inside then return true end
    local out=world._ccd_overlap_out or {};world._ccd_overlap_out=out
    local cx,cy,cz=a.cx,a.cy,a.cz
    a.cx,a.cy,a.cz=cx+dx,cy+dy,cz+dz
    local endpoint_overlap=N.collide(a,b,out)>0
    a.cx,a.cy,a.cz=cx,cy,cz
    -- leave a shallow sampled landing to the existing contact solver, which
    -- supplies friction, restitution and the off-centre angular impulse
    return not endpoint_overlap
end
function C.static(world,body)
    for _,v in ipairs(body.parts) do
        local kind=Shape.kind_of(v)
        if v.CanCollide~=false and kind~='block' and kind~='mesh' and kind~='ball' and kind~='convex_decomposition' then return false end
    end
    local a=motion(world,body)
    if a.count==0 then return true end
    local best,nx,ny,nz=1;local fallback=false
    world.broadphase:collect_region(a.lx+min(0,a.dx),a.ly+min(0,a.dy),a.lz+min(0,a.dz),
        a.rx+max(0,a.dx),a.ry+max(0,a.dy),a.rz+max(0,a.dz),function(target)
        if not target.is_static or target==body then return end
        local prescribed=world._ccd_static_motions and world._ccd_static_motions[target.id]
        if prescribed and not prescribed.rotating then return end
        for _,v in ipairs(target.parts) do
            local kind=Shape.kind_of(v)
            if v.CanCollide~=false and kind~='block' and kind~='mesh' and kind~='ball' and kind~='convex_decomposition' then fallback=true end
        end
        local b=motion(world,target)
        for i=1,a.count do for j=1,b.count do
            local ca,cb=a.members[i],b.members[j]
            if allowed(world,ca.view,cb.view) then
                local t,x,y,z=C.sweep(ca,cb,-a.dx,-a.dy,-a.dz)
                if t and t<best and a.dx*x+a.dy*y+a.dz*z>EPS
                    and tunnel_or_deep(world,ca,cb,a.dx,a.dy,a.dz,x,y,z) then best,nx,ny,nz=t,x,y,z end
            end
        end end
    end)
    -- an unsupported neighbour must not send the already tested decomposed
    -- geometry back through an enclosing-bound sweep. return the exact result
    -- alongside a request to test only the remaining legacy members
    if fallback then return false,a,best,nx,ny,nz end
    if best<1 then
        a.dx,a.dy,a.dz=a.dx*best,a.dy*best,a.dz*best
        body.com_x,body.com_y,body.com_z=a.x+a.dx,a.y+a.dy,a.z+a.dz
        local approach=body.vx*nx+body.vy*ny+body.vz*nz
        if approach>0 then body.vx,body.vy,body.vz=body.vx-approach*nx,body.vy-approach*ny,body.vz-approach*nz end
        world.ccd_clamp_count=(world.ccd_clamp_count or 0)+1
    end
    return true
end

function C.resolve(world,dt)
    local list={};local maxx,maxy,maxz=0,0,0
    for i=1,world.active_count do
        local b=world.active_bodies[i]
        if b.inv_mass>0 then
            local dx,dy,dz=b.com_x-(b._ccd_x or b.com_x),b.com_y-(b._ccd_y or b.com_y),b.com_z-(b._ccd_z or b.com_z)
            maxx=max(maxx,abs(dx));maxy=max(maxy,abs(dy));maxz=max(maxz,abs(dz))
            local travel2=dx*dx+dy*dy+dz*dz
            if travel2>EPS then
                for j=1,b.part_count or #b.parts do
                    local p=b.parts[j]
                    if p.CanCollide~=false then
                        local hx,hy,hz=Shape.half_extents(p)
                        if travel2>(.25*min(hx,hy,hz))^2 then list[#list+1]=motion(world,b);break end
                    end
                end
            end
        end
    end
    for _,p in pairs(world._ccd_static_motions or {}) do
        local asm=world.part_to_assembly[p.view.id]
        if not p.rotating and asm and asm.body==p.body then list[#list+1]=motion(world,p.body) end
    end
    -- a transferred impulse can create a second collision in the same interval
    -- (a projectile pushes a crate toward a wall). Revisit the small candidate
    -- set, never add fixed steps or repeat public simulation callbacks
    for pass=1,4 do
    local events,seen={},{}
    for _,a in ipairs(list) do
        local travel2=a.dx*a.dx+a.dy*a.dy+a.dz*a.dz
        if a.count>0 and travel2>EPS*EPS and (a.prescribed or travel2>(.25*a.minhalf)^2) then
            local function candidate(body)
                if body==a.body or (body.is_static and (not a.prescribed or a.body.is_static)) then return end
                local x,y=a.body.id,body.id;local key=x<y and x..':'..y or y..':'..x
                if seen[key] then return end;seen[key]=true
                local b=motion(world,body)
                local t,nx,ny,nz=hit(world,a,b)
                if t then events[#events+1]={a=a,b=b,t=t,nx=nx,ny=ny,nz=nz} end
            end
            -- Proxies still describe the sampled start poses. Expanding by the
            -- largest target travel includes targets approaching from outside
            world.broadphase:collect_region(a.lx+min(0,a.dx)-maxx,a.ly+min(0,a.dy)-maxy,a.lz+min(0,a.dz)-maxz,
                a.rx+max(0,a.dx)+maxx,a.ry+max(0,a.dy)+maxy,a.rz+max(0,a.dz)+maxz,candidate)
        end
    end
    table.sort(events,function(a,b) return a.t<b.t end)
    local resolved=0
    for _,e in ipairs(events) do
        local a,b=e.a,e.b;local ba,bb=a.body,b.body
        local t,nx,ny,nz=hit(world,a,b)
        if t then
            local ia,ib=ba.inv_mass,bb.inv_mass
            local avx,avy,avz=ba.vx,ba.vy,ba.vz
            local bvx,bvy,bvz=bb.vx,bb.vy,bb.vz
            if a.prescribed then avx,avy,avz=a.dx/dt,a.dy/dt,a.dz/dt end
            if b.prescribed then bvx,bvy,bvz=b.dx/dt,b.dy/dt,b.dz/dt end
            local approach=(bvx-avx)*nx+(bvy-avy)*ny+(bvz-avz)*nz
            local crossing=-((b.dx-a.dx)*nx+(b.dy-a.dy)*ny+(b.dz-a.dz)*nz)*(1-t)
            if (approach< -EPS or crossing>EPS) and ia+ib>0 then
                local impulse=max(0,-approach)/(ia+ib)
                local correction=max(0,crossing)/(ia+ib)
                local function advance(m,body,inv,sign,vx,vy,vz)
                    if inv==0 then return end
                    world:wake_body(body,true)
                    body.vx,body.vy,body.vz=vx+sign*impulse*inv*nx,vy+sign*impulse*inv*ny,vz+sign*impulse*inv*nz
                    -- preserve nonpenetration even if an earlier static sweep
                    -- has already zeroed velocity at a later wall on this path
                    m.dx=m.dx+sign*correction*inv*nx
                    m.dy=m.dy+sign*correction*inv*ny
                    m.dz=m.dz+sign*correction*inv*nz
                    body.com_x,body.com_y,body.com_z=m.x+m.dx,m.y+m.dy,m.z+m.dz
                    C.static(world,body)
                    if pass==1 then
                        local found=false;for _,item in ipairs(list) do if item==m then found=true;break end end
                        if not found then list[#list+1]=m end
                    end
                end
                advance(a,ba,ia,-1,avx,avy,avz);advance(b,bb,ib,1,bvx,bvy,bvz)
                world.ccd_relative_contact_count=(world.ccd_relative_contact_count or 0)+1
                resolved=resolved+1
            end
        end
    end
    if resolved==0 then break end
    end
    world._ccd_static_motions=nil
end
return C
