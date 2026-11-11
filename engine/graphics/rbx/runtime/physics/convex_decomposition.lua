-- Offline convex-component caches. no cooking, asset fetch, or enclosing-box
-- fallback is performed here. Sphere/ray tests use the same finite solids;
-- polyhedron contacts reuse the engine SAT/face manifold and cylinder contacts
-- reuse its bounded GJK/EPA. Faces shared with or covered by another hull of
-- the same body are internal: contacts along them are dropped, so seams
-- between hulls do not push. Hull pairs that agree with the deepest normal
-- are merged and reduced to four points, keeping one normal per part pair
local M={}
local Size=runtime_require('size_validation.lua')
local Poly=runtime_require('physics/wedge_box.lua')
local Cylinder=runtime_require('physics/cylinder.lua')
local abs,sqrt,min,max=math.abs,math.sqrt,math.min,math.max
local function finite(v)return type(v)=='number'and v==v and abs(v)<math.huge end
local function xyz(v)return v.x or v.X or v[1],v.y or v.Y or v[2],v.z or v.Z or v[3]end
local function dense_array(array,count,message)
    local actual=0
    for key in next,array do
        assert(type(key)=='number'and key==math.floor(key)and key>=1 and key<=count,message)
        actual=actual+1
    end
    assert(actual==count,message)
end
local function face_index(id,count)
    assert(finite(id)and id==math.floor(id)and id>=1 and id<=count,'Invalid hull face index')
    return id
end
local function admit_edge(rows,a,b)
    local lo,hi,direction
    if a<b then lo,hi,direction=a,b,1 else lo,hi,direction=b,a,-1 end
    local row=rows[lo]
    if not row then row={};rows[lo]=row end
    local edge=row[hi]
    if edge then edge[1]=edge[1]+1;edge[2]=edge[2]+direction
    else row[hi]={1,direction}end
end
local function unit(x,y,z)local n=sqrt(x*x+y*y+z*z);assert(n>1e-12,'Convex cache has degenerate geometry');return x/n,y/n,z/n end
local function plane(a,b,c)
    local x,y,z=b[1]-a[1],b[2]-a[2],b[3]-a[3]
    local u,v,w=c[1]-a[1],c[2]-a[2],c[3]-a[3]
    local nx,ny,nz=unit(y*w-z*v,z*u-x*w,x*v-y*u)
    return{nx,ny,nz,nx*a[1]+ny*a[2]+nz*a[3]}
end
local function prepare(raw,sx,sy,sz)
    local g={vertices={},planes={},faces={},edges={}}
    local cx,cy,cz=0,0,0
    for i=1,#raw.vertices,3 do
        local p={raw.vertices[i]*sx,raw.vertices[i+1]*sy,raw.vertices[i+2]*sz};g.vertices[#g.vertices+1]=p
        cx,cy,cz=cx+p[1],cy+p[2],cz+p[3]
    end
    cx,cy,cz=cx/#g.vertices,cy/#g.vertices,cz/#g.vertices
    local groups={};local tolerance=1e-7*max(1,abs(sx),abs(sy),abs(sz))
    for _,f in ipairs(raw.faces)do
        local p=plane(g.vertices[f[1]],g.vertices[f[2]],g.vertices[f[3]])
        if cx*p[1]+cy*p[2]+cz*p[3]>p[4]then p={-p[1],-p[2],-p[3],-p[4]}end
        for _,v in ipairs(g.vertices)do assert(v[1]*p[1]+v[2]*p[2]+v[3]*p[3]-p[4]<=tolerance*10,'Cache component is not convex')end
        local group
        for _,q in ipairs(groups)do
            if abs(p[1]-q.plane[1])+abs(p[2]-q.plane[2])+abs(p[3]-q.plane[3])<1e-7 and abs(p[4]-q.plane[4])<tolerance then group=q;break end
        end
        if not group then group={plane=p,vertices={}};groups[#groups+1]=group end
        for _,id in ipairs(f)do group.vertices[id]=true end
    end
    -- merge each coplanar triangulated face into its ordered convex polygon
    -- this prevents selecting a distant triangle instead of a supporting face
    for _,group in ipairs(groups)do
        local p=group.plane;local nx,ny,nz=p[1],p[2],p[3]
        local ux,uy,uz
        if abs(nx)<.8 then ux,uy,uz=unit(0,nz,-ny)else ux,uy,uz=unit(-nz,0,nx)end
        local vx,vy,vz=ny*uz-nz*uy,nz*ux-nx*uz,nx*uy-ny*ux
        local face={};local x,y,z=0,0,0
        for id in pairs(group.vertices)do face[#face+1]=id;local v=g.vertices[id];x,y,z=x+v[1],y+v[2],z+v[3]end
        x,y,z=x/#face,y/#face,z/#face
        table.sort(face,function(a,b)
            local av,bv=g.vertices[a],g.vertices[b]
            local ax,ay,az=av[1]-x,av[2]-y,av[3]-z;local bx,by,bz=bv[1]-x,bv[2]-y,bv[3]-z
            return math.atan2(ax*vx+ay*vy+az*vz,ax*ux+ay*uy+az*uz)<math.atan2(bx*vx+by*vy+bz*vz,bx*ux+by*uy+bz*uz)
        end)
        g.planes[#g.planes+1]=p;g.faces[#g.faces+1]=face
    end
    local seen={}
    for _,f in ipairs(g.faces)do for i=1,#f do
        local a,b=f[i],f[i%#f+1];local lo,hi
        if a<b then lo,hi=a,b else lo,hi=b,a end
        local row=seen[lo];if not row then row={};seen[lo]=row end
        if not row[hi]then row[hi]=true;g.edges[#g.edges+1]={a,b}end
    end end
    assert(#g.planes>=4,'Convex component must enclose a three-dimensional solid')
    local first=g.vertices[1];g.bounds={first[1],first[2],first[3],first[1],first[2],first[3]}
    for _,v in ipairs(g.vertices)do for i=1,3 do g.bounds[i]=min(g.bounds[i],v[i]);g.bounds[i+3]=max(g.bounds[i+3],v[i])end end
    for i=1,3 do assert(g.bounds[i+3]-g.bounds[i]>1e-10,'Convex cache has zero volume extent')end
    return g
end
function M.validate(data,checkpoint)
    assert(checkpoint==nil or type(checkpoint)=='function','Collision cache checkpoint must be a function')
    assert(type(data)=='table'and(data.schema==1 or data.schema==2)and data.coordinate_space=='mesh','Expected supported offline mesh collision schema')
    assert(type(data.mesh_sha256)=='string'and #data.mesh_sha256==64 and data.mesh_sha256:match('^[0-9a-f]+$'),'Expected verified source mesh SHA256')
    -- 'mesh' binds to the part's resolved mesh asset bytes, 'part' to bytes
    -- stored in one of the part's own fields (authored or embedded data)
    local source_kind=data.source_kind or'mesh'
    assert(source_kind=='mesh'or(source_kind=='part'and type(data.source_field)=='string'),'Invalid collision source binding')
    local rx,ry,rz=xyz(assert(data.reference_size,'Cache requires its source mesh reference size'))
    assert(finite(rx)and finite(ry)and finite(rz)and rx>0 and ry>0 and rz>0,'Invalid mesh reference size')
    assert(type(data.hulls)=='table','Collision components must be an array')
    -- Schema 1 is the historical cooked-hull API. Schema 2 makes the producer
    -- and cardinality explicit. Triangle shells are surface approximation,
    -- not cooked PCD: their storage budget is measured in coordinates/faces
    local count=data.component_count
    if data.schema==1 and count==nil then count=0;for _ in next,data.hulls do count=count+1 end end
    assert(finite(count)and count==math.floor(count)and count>0,'Invalid explicit collision component count')
    dense_array(data.hulls,count,'Convex components must be a dense array')
    local shell=data.schema==2 and data.representation=='triangle-shell-approximation'
    assert(data.schema==1 or shell or data.representation=='convex-components','Unsupported collision representation')
    if shell then
        assert(data.triangle_count==count and finite(data.half_thickness)and data.half_thickness>0,'Invalid triangle shell metadata')
        -- at most 1M coordinates / 524K faces per asset, no pieces are dropped
        assert(count*18<=1048576 and count*8<=524288,'Triangle shell collision storage budget exceeded')
    else assert(count<=1024,'Invalid convex component count')end
    local own={schema=data.schema,representation=data.representation,component_count=count,
        triangle_count=data.triangle_count,half_thickness=data.half_thickness,
        coordinate_space='mesh',mesh_sha256=data.mesh_sha256,source_kind=source_kind,source_field=data.source_field,
        reference_size={rx,ry,rz},hulls={}}
    for hull_index=1,count do
        local h=rawget(data.hulls,hull_index)
        assert(type(h)=='table','Invalid convex component')
        assert(type(h.vertices)=='table'and #h.vertices>=12 and #h.vertices<=3072 and #h.vertices%3==0,'Invalid hull vertex count')
        assert(type(h.faces)=='table'and #h.faces>=4 and #h.faces<=2048,'Invalid hull face count')
        if shell then assert(#h.vertices==18 and #h.faces==8,'Triangle shell must be a complete six-vertex prism')end
        dense_array(h.vertices,#h.vertices,'Hull vertices must be a dense array')
        dense_array(h.faces,#h.faces,'Hull faces must be a dense array')
        local raw={vertices={},faces={}};local cx,cy,cz=0,0,0
        for i=1,#h.vertices do local v=rawget(h.vertices,i);assert(finite(v),'Non-finite hull vertex');raw.vertices[i]=v end
        local edges,used={},{};local vertex_count=#h.vertices/3
        for i=1,#h.vertices,3 do cx,cy,cz=cx+raw.vertices[i],cy+raw.vertices[i+1],cz+raw.vertices[i+2]end
        cx,cy,cz=cx/vertex_count,cy/vertex_count,cz/vertex_count
        assert(finite(cx)and finite(cy)and finite(cz),'Convex cache centroid overflow')
        for i=1,#h.faces do
            local f=rawget(h.faces,i)
            assert(type(f)=='table'and #f==3,'Offline faces must be triangles')
            dense_array(f,3,'Offline triangle has a missing or extra index')
            local a=face_index(rawget(f,1),vertex_count)
            local b=face_index(rawget(f,2),vertex_count)
            local c=face_index(rawget(f,3),vertex_count)
            assert(a~=b and a~=c and b~=c,'Repeated hull face vertex')
            local ai,bi,ci=(a-1)*3+1,(b-1)*3+1,(c-1)*3+1
            local ax,ay,az=raw.vertices[ai],raw.vertices[ai+1],raw.vertices[ai+2]
            local ux,uy,uz=raw.vertices[bi]-ax,raw.vertices[bi+1]-ay,raw.vertices[bi+2]-az
            local vx,vy,vz=raw.vertices[ci]-ax,raw.vertices[ci+1]-ay,raw.vertices[ci+2]-az
            local nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
            local length=nx*nx+ny*ny+nz*nz
            assert(finite(length)and length>1e-24,'Convex cache has degenerate triangle geometry')
            -- input triangles may have either winding. normalize only the
            -- owned copy using the convex component's interior centroid, then
            -- require opposite directions on every twice-incident edge
            if nx*(cx-ax)+ny*(cy-ay)+nz*(cz-az)>0 then b,c=c,b end
            raw.faces[i]={a,b,c};used[a],used[b],used[c]=true,true,true
            admit_edge(edges,a,b);admit_edge(edges,b,c);admit_edge(edges,c,a)
        end
        for lo,row in pairs(edges)do for hi,edge in pairs(row)do
            if edge[1]~=2 then
                error('Convex cache must be a closed manifold: mesh '..data.mesh_sha256..' hull '..hull_index..' edge '..lo..':'..hi..' incidence '..edge[1])
            end
            assert(edge[2]==0,'Convex cache edge orientation is inconsistent')
        end end
        for id=1,vertex_count do assert(used[id],'Unused hull vertex')end
        raw._geometry=prepare(raw,1,1,1);own.hulls[#own.hulls+1]=raw
        if checkpoint then checkpoint('collision:hull',hull_index,count)end
    end
    M.mark_internal(own.hulls)
    return own
end
-- a face is internal when the point just outside its centre lies inside
-- another hull of the same body: solid continues across it
local function strictly_inside(g,x,y,z,margin)
    local b=g.bounds
    if x<b[1]or y<b[2]or z<b[3]or x>b[4]or y>b[5]or z>b[6]then return false end
    for _,p in ipairs(g.planes)do if x*p[1]+y*p[2]+z*p[3]-p[4]>-margin then return false end end
    return true
end
function M.mark_internal(hulls)
    for i,raw in ipairs(hulls)do
        local g=raw._geometry;local internal={}
        local size=0;for k=1,3 do size=max(size,g.bounds[k+3]-g.bounds[k])end
        local step,margin=size*1e-3,size*1e-6
        for f,face in ipairs(g.faces)do
            local x,y,z=0,0,0
            for _,id in ipairs(face)do local v=g.vertices[id];x,y,z=x+v[1],y+v[2],z+v[3]end
            x,y,z=x/#face,y/#face,z/#face
            local p=g.planes[f];x,y,z=x+p[1]*step,y+p[2]*step,z+p[3]*step
            for j,other in ipairs(hulls)do
                if j~=i and strictly_inside(other._geometry,x,y,z,margin)then internal[f]=true;break end
            end
        end
        g.internal=internal
    end
end
-- Opaque owner-bound handles share validated immutable topology between parts
-- caller tables are copied once, neither handle fields nor diagnostic output
-- expose that topology. raw cache input remains supported by the setter
local handles=setmetatable({},{__mode='k'})
function M.create_cache(owner,data,checkpoint)
    assert(owner~=nil,'Collision cache needs an owner')
    local cache=M.validate(data,checkpoint)
    local handle=setmetatable({},{__metatable='offline collision cache',
        __newindex=function()error('Collision cache handles are immutable',2)end})
    handles[handle]={owner=owner,cache=cache}
    return handle,{type='convex_decomposition',hulls=#cache.hulls,mesh_sha256=cache.mesh_sha256}
end
function M.resolve_cache(owner,data)
    local entry=handles[data]
    if entry then
        assert(entry.owner==owner,'Collision cache belongs to another DataModel')
        return entry.cache
    end
    return M.validate(data)
end
function M.geometry(view)
    local part=view._part or view;local cache=part._collision_decomposition
    if not cache then return end
    local x,y,z=Size.part(view);local old=part._cd_scaled
    if old and old.cache==cache and old.x==x and old.y==y and old.z==z then return old.hulls end
    local r=cache.reference_size;local hulls={};local hx,hy,hz=0,0,0
    local sx,sy,sz=x/r[1],y/r[2],z/r[3]
    assert(sx~=0 and sy~=0 and sz~=0,'Convex geometry cannot scale to zero')
    for _,raw in ipairs(cache.hulls)do
        local base=raw._geometry
        local g={vertices={},planes={},faces=base.faces,edges=base.edges,bounds={},internal=base.internal}
        for _,v in ipairs(base.vertices)do g.vertices[#g.vertices+1]={v[1]*sx,v[2]*sy,v[3]*sz}end
        for _,p in ipairs(base.planes)do
            local nx,ny,nz=p[1]/sx,p[2]/sy,p[3]/sz;local length=sqrt(nx*nx+ny*ny+nz*nz)
            g.planes[#g.planes+1]={nx/length,ny/length,nz/length,p[4]/length}
        end
        for i,s in ipairs({sx,sy,sz})do g.bounds[i]=min(base.bounds[i]*s,base.bounds[i+3]*s);g.bounds[i+3]=max(base.bounds[i]*s,base.bounds[i+3]*s)end
        hx=max(hx,abs(g.bounds[1]),abs(g.bounds[4]))
        hy=max(hy,abs(g.bounds[2]),abs(g.bounds[5]))
        hz=max(hz,abs(g.bounds[3]),abs(g.bounds[6]))
        if sx*sy*sz<0 then
            g.faces={};for i,f in ipairs(base.faces)do local reversed={};for j=#f,1,-1 do reversed[#reversed+1]=f[j]end;g.faces[i]=reversed end
        end
        hulls[#hulls+1]=g
    end
    part._cd_scaled={cache=cache,x=x,y=y,z=z,hulls=hulls,hx=hx,hy=hy,hz=hz}
    return hulls
end
function M.half_extents(view)
    M.geometry(view);local part=view._part or view;local g=part._cd_scaled
    return g.hx,g.hy,g.hz
end
-- Signed distance and nearest surface witness of a finite convex polyhedron
function M.closest(g,x,y,z)
    local furthest,face=-math.huge,1
    for i,p in ipairs(g.planes)do local d=x*p[1]+y*p[2]+z*p[3]-p[4];if d>furthest then furthest,face=d,i end end
    local p=g.planes[face]
    if furthest<=1e-10 then return furthest,p[1],p[2],p[3],x-furthest*p[1],y-furthest*p[2],z-furthest*p[3],face end
    local best,qx,qy,qz,id=math.huge,0,0,0,0
    for i,p in ipairs(g.planes)do
        local d=x*p[1]+y*p[2]+z*p[3]-p[4]
        if d*d<best then
            local px,py,pz=x-d*p[1],y-d*p[2],z-d*p[3];local inside=true
            for _,f in ipairs(g.planes)do if px*f[1]+py*f[2]+pz*f[3]-f[4]>1e-8 then inside=false;break end end
            if inside then best,qx,qy,qz,id=d*d,px,py,pz,i end
        end
    end
    for i,e in ipairs(g.edges)do
        local a,b=g.vertices[e[1]],g.vertices[e[2]];local dx,dy,dz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
        local t=max(0,min(1,((x-a[1])*dx+(y-a[2])*dy+(z-a[3])*dz)/(dx*dx+dy*dy+dz*dz)))
        local px,py,pz=a[1]+t*dx,a[2]+t*dy,a[3]+t*dz;local ex,ey,ez=x-px,y-py,z-pz;local d=ex*ex+ey*ey+ez*ez
        if d<best then best,qx,qy,qz,id=d,px,py,pz,1000+i end
    end
    local d=sqrt(best);assert(d>0,'Invalid convex nearest witness')
    return d,(x-qx)/d,(y-qy)/d,(z-qz)/d,qx,qy,qz,id
end
function M.ray_local(hulls,ox,oy,oz,dx,dy,dz,maxdist)
    local best,nx,ny,nz=maxdist,nil,nil,nil
    for _,h in ipairs(hulls)do
        local near,far,enter=-math.huge,math.huge,nil
        for i,p in ipairs(h.planes)do
            local n=dx*p[1]+dy*p[2]+dz*p[3];local d=ox*p[1]+oy*p[2]+oz*p[3]-p[4]
            if abs(n)<1e-12 then if d>0 then enter=nil;far=-math.huge;break end
            else
                local t=-d/n
                if n<0 then if t>near then near,enter=t,i end else far=min(far,t)end
                if near>far then enter=nil;break end
            end
        end
        -- preserve the existing finite-convex ray rule: origin-inside misses
        if enter and near>1e-5 and near<=best and near<=far then
            local p=h.planes[enter];best,nx,ny,nz=near,p[1],p[2],p[3]
        end
    end
    if nx then return best,nx,ny,nz end
end
local function rotate(c,x,y,z)return c.u0x*x+c.u1x*y+c.u2x*z,c.u0y*x+c.u1y*y+c.u2y*z,c.u0z*x+c.u1z*y+c.u2z*z end
local function local_point(c,x,y,z)
    x,y,z=x-c.cx,y-c.cy,z-c.cz
    return x*c.u0x+y*c.u0y+z*c.u0z,x*c.u1x+y*c.u1y+z*c.u1z,x*c.u2x+y*c.u2y+z*c.u2z
end
local function sphere(a,h,b,out)
    local x,y,z=local_point(a,b.cx,b.cy,b.cz);local bounds=h.bounds;local r=b.radius
    if x<bounds[1]-r or y<bounds[2]-r or z<bounds[3]-r or x>bounds[4]+r or y>bounds[5]+r or z>bounds[6]+r then out.count=0;return 0 end
    local d,nx,ny,nz,qx,qy,qz,id=M.closest(h,x,y,z)
    if d>r then out.count=0;return 0 end
    nx,ny,nz=rotate(a,nx,ny,nz);qx,qy,qz=rotate(a,qx,qy,qz)
    qx,qy,qz=qx+a.cx,qy+a.cy,qz+a.cz
    out.nx,out.ny,out.nz=nx,ny,nz;out.count=1;out.points=out.points or{};local p=out.points[1]or{};out.points[1]=p
    p.px,p.py,p.pz=(qx+b.cx-nx*r)*.5,(qy+b.cy-ny*r)*.5,(qz+b.cz-nz*r)*.5
    p.penetration,p.feature_id=r-d,id;return 1
end
local scratch={points={}}
local function world_hull(c,h)
    local vertices={}
    for _,v in ipairs(h.vertices)do local x,y,z=rotate(c,v[1],v[2],v[3]);vertices[#vertices+1]={x=x+c.cx,y=y+c.cy,z=z+c.cz}end
    return{vertices=vertices,cx=c.cx,cy=c.cy,cz=c.cz,hx=c.hx,hy=c.hy,hz=c.hz,
        u0x=c.u0x,u0y=c.u0y,u0z=c.u0z,u1x=c.u1x,u1y=c.u1y,u1z=c.u1z,u2x=c.u2x,u2y=c.u2y,u2z=c.u2z}
end
-- true when world normal n (pointing a -> b) leaves hull h of body c
-- through an internal face, `sign` -1 tests the opposite direction
local function along_internal(c,h,nx,ny,nz,sign)
    local internal=h.internal
    if not internal or next(internal)==nil then return false end
    local lx=(nx*c.u0x+ny*c.u0y+nz*c.u0z)*sign
    local ly=(nx*c.u1x+ny*c.u1y+nz*c.u1z)*sign
    local lz=(nx*c.u2x+ny*c.u2y+nz*c.u2z)*sign
    for f in pairs(internal)do
        local p=h.planes[f]
        if p[1]*lx+p[2]*ly+p[3]*lz>.98 then return true end
    end
    return false
end
local SAME_NORMAL=.95
local candidates,merged={},{}
local function take(list,index)
    local item=list[index];if not item then item={points={}};list[index]=item end
    return item
end
-- keep the deepest point, the one furthest from it, then the points that
-- add the most area: the usual four-point manifold reduction
local function reduce(points,count,out)
    local function copy(dst,src)dst.px,dst.py,dst.pz,dst.penetration,dst.feature_id=src.px,src.py,src.pz,src.penetration,src.feature_id end
    out.points=out.points or{}
    if count<=4 then for k=1,count do local q=out.points[k]or{};out.points[k]=q;copy(q,points[k])end;return count end
    local chosen={}
    local best=1;for k=2,count do if points[k].penetration>points[best].penetration then best=k end end
    chosen[1]=best
    local far,fd=nil,-1
    for k=1,count do local p,q=points[k],points[best];local dx,dy,dz=p.px-q.px,p.py-q.py,p.pz-q.pz;local d=dx*dx+dy*dy+dz*dz
        if d>fd then far,fd=k,d end end
    chosen[2]=far
    local function area(a,b,c)
        local ux,uy,uz=b.px-a.px,b.py-a.py,b.pz-a.pz;local vx,vy,vz=c.px-a.px,c.py-a.py,c.pz-a.pz
        local x,y,z=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx;return x*x+y*y+z*z
    end
    local third,ta=nil,-1
    for k=1,count do if k~=best and k~=far then local a=area(points[best],points[far],points[k]);if a>ta then third,ta=k,a end end end
    chosen[3]=third
    local fourth,fa=nil,-1
    for k=1,count do if k~=best and k~=far and k~=third then
        local p=points[k]
        local a=area(points[best],points[far],p)+area(points[far],points[third],p)+area(points[third],points[best],p)
        if a>fa then fourth,fa=k,a end
    end end
    chosen[4]=fourth
    local n=0
    for _,k in ipairs(chosen)do if k then n=n+1;local q=out.points[n]or{};out.points[n]=q;copy(q,points[k])end end
    return n
end
function M.collide(a,b,out)
    if not a.convex then local n=M.collide(b,a,out);if n>0 then out.nx,out.ny,out.nz=-out.nx,-out.ny,-out.nz end;return n end
    out.count=0
    local nb=b.convex and #b.convex or 1
    local used,deepest,deepest_index,fallback,fallback_depth=0,-math.huge,nil,nil,-math.huge
    for i,ha in ipairs(a.convex)do for j=1,nb do
        local hb=b.convex and b.convex[j]
        local count
        if b.kind=='ball'then count=sphere(a,ha,b,scratch)
        elseif b.kind=='cylinder'then count=Cylinder.convex(world_hull(a,ha),b,scratch)
        else count=Poly.collide_polyhedra(a,b,scratch,ha,hb)end
        if count>0 then
            local depth=0;for k=1,count do depth=max(depth,scratch.points[k].penetration)end
            local internal=along_internal(a,ha,scratch.nx,scratch.ny,scratch.nz,1)
                or(hb and along_internal(b,hb,scratch.nx,scratch.ny,scratch.nz,-1))
            used=used+1
            local c=take(candidates,used)
            c.nx,c.ny,c.nz,c.count,c.depth,c.internal=scratch.nx,scratch.ny,scratch.nz,count,depth,internal
            for k=1,count do
                local p=scratch.points[k];local q=c.points[k]or{};c.points[k]=q
                q.px,q.py,q.pz,q.penetration=p.px,p.py,p.pz,p.penetration
                q.feature_id=((i-1)*nb+j-1)*100000000+p.feature_id
            end
            if not internal and depth>deepest then deepest,deepest_index=depth,used end
            if depth>fallback_depth then fallback,fallback_depth=used,depth end
        end
    end end
    if used==0 then return 0 end
    -- every pair along an internal face: keep the deepest so nothing sinks
    local lead=candidates[deepest_index or fallback]
    out.nx,out.ny,out.nz=lead.nx,lead.ny,lead.nz
    if b.kind=='ball'or b.kind=='cylinder'then
        out.count=reduce(lead.points,lead.count,out);return out.count
    end
    local count=0
    for index=1,used do
        local c=candidates[index]
        if (index==deepest_index or index==fallback and not deepest_index)
            or(not c.internal and c.nx*lead.nx+c.ny*lead.ny+c.nz*lead.nz>SAME_NORMAL)then
            for k=1,c.count do
                local p=c.points[k];local duplicate=false
                for m=1,count do
                    local q=merged[m];local dx,dy,dz=p.px-q.px,p.py-q.py,p.pz-q.pz
                    if dx*dx+dy*dy+dz*dz<1e-6 then
                        duplicate=true
                        if p.penetration>q.penetration then merged[m]=p end
                        break
                    end
                end
                if not duplicate then count=count+1;merged[count]=p end
            end
        end
    end
    out.count=reduce(merged,count,out)
    for m=1,count do merged[m]=nil end
    return out.count
end
return M
