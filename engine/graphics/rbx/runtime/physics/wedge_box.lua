-- exact convex Wedge/CornerWedge versus block contacts. Geometry comes from
-- wedge.lua, this module only detects contacts for the existing solver
local M = {}
local abs, sqrt, min, max = math.abs, math.sqrt, math.min, math.max
local WF = {{1,4,3,2},{4,5,6,3},{2,3,6},{1,5,4},{1,2,6,5}}
local CF = {{1,4,3,2},{2,3,5},{1,2,5},{3,4,5},{1,5,4}}
local BF = {{2,3,7,6},{1,5,8,4},{5,6,7,8},{1,4,3,2},{4,8,7,3},{1,2,6,5}}
local BE = {{1,2},{4,3},{5,6},{8,7},{1,5},{2,6},{3,7},{4,8},{1,4},{2,3},{5,8},{6,7}}
local BP = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
local BV = {{-1,-1,-1},{1,-1,-1},{1,-1,1},{-1,-1,1},{-1,1,-1},{1,1,-1},{1,1,1},{-1,1,1}}
-- shared scratch, like the existing OBB detector. no scratch escapes a call
local A,B = {v={},n={}},{v={},n={}}
local polygon, clipped, candidates = {},{},{}
local sat = {}
local function point(pool,i,x,y,z)
    local p=pool[i]; if not p then p={};pool[i]=p end
    p[1],p[2],p[3]=x,y,z
    return p
end
local function rotate(c,x,y,z)
    return c.u0x*x+c.u1x*y+c.u2x*z,c.u0y*x+c.u1y*y+c.u2y*z,c.u0z*x+c.u1z*y+c.u2z*z
end
local function build(c,s,is_wedge,hull)
    local vs,ns
    if hull then
        vs,ns=hull.vertices,hull.planes;s.faces,s.edges=hull.faces,hull.edges
    elseif is_wedge then
        vs,ns=c.wedge.vertices,c.wedge.planes
        s.faces,s.edges=c.wedge.corner and CF or WF,c.wedge.edges
    else vs,ns=BV,BP;s.faces,s.edges=BF,BE end
    s.count=#vs
    for i=1,#vs do
        local v=vs[i];local x,y,z=v[1],v[2],v[3]
        if not is_wedge and not hull then x,y,z=x*c.hx,y*c.hy,z*c.hz end
        x,y,z=rotate(c,x,y,z);point(s.v,i,c.cx+x,c.cy+y,c.cz+z)
    end
    for i=1,#ns do local n=ns[i];point(s.n,i,rotate(c,n[1],n[2],n[3])) end
end
local function project(s,x,y,z)
    local lo,hi=math.huge,-math.huge
    for i=1,s.count do local v=s.v[i];local d=v[1]*x+v[2]*y+v[3]*z;lo,hi=min(lo,d),max(hi,d) end
    return lo,hi
end
local function axis(x,y,z,edge,boxedge,face_side)
    local len=sqrt(x*x+y*y+z*z);if len<1e-9 then return true end
    x,y,z=x/len,y/len,z/len
    local al,ah=project(A,x,y,z);local bl,bh=project(B,x,y,z)
    local forward,backward=ah-bl,bh-al
    if forward<=0 or backward<=0 then return false end
    -- Face candidates keep their actual outward orientation. in particular,
    -- the wedge's sloping face has no parallel face on its opposite side
    local depth=forward
    if face_side=='b' or (not face_side and backward<forward) then depth=backward;x,y,z=-x,-y,-z end
    -- prefer a face manifold when an edge axis is numerically tied
    local score=depth+(edge and 1e-5 or 0)
    if score<sat.score then
        sat.score,sat.depth,sat.x,sat.y,sat.z=score,depth,x,y,z
        sat.edge,sat.boxedge=edge,boxedge
    end
    return true
end
local function aligned_face(s,x,y,z)
    local best,index=-math.huge,1
    for i=1,#s.faces do local n=s.n[i];local d=n[1]*x+n[2]*y+n[3]*z;if d>best then best,index=d,i end end
    return index,best
end
local function clip(count,x,y,z,d)
    local n=0
    for i=1,count do
        local p,q=polygon[i],polygon[i%count+1]
        local dp=p[1]*x+p[2]*y+p[3]*z-d
        local dq=q[1]*x+q[2]*y+q[3]*z-d
        if dp<=1e-8 then n=n+1;point(clipped,n,p[1],p[2],p[3]) end
        if (dp<0 and dq>0) or (dp>0 and dq<0) then
            local t=dp/(dp-dq);n=n+1
            point(clipped,n,p[1]+t*(q[1]-p[1]),p[2]+t*(q[2]-p[2]),p[3]+t*(q[3]-p[3]))
        end
    end
    polygon,clipped=clipped,polygon
    return n
end
local function emit(out,i,x,y,z,depth,feature)
    out.points=out.points or {};local p=out.points[i]
    if not p then p={};out.points[i]=p end
    p.px,p.py,p.pz,p.penetration,p.feature_id=x,y,z,depth,feature
end
local function face_contacts(out)
    local af,ad=aligned_face(A,sat.x,sat.y,sat.z)
    local bf,bd=aligned_face(B,-sat.x,-sat.y,-sat.z)
    local ref,inc,fi,side=A,B,af,0
    if bd>ad then ref,inc,fi,side=B,A,bf,1 end
    local normal=ref.n[fi];local x,y,z=normal[1],normal[2],normal[3]
    local ii=aligned_face(inc,-x,-y,-z)
    local rf,inf=ref.faces[fi],inc.faces[ii]
    local count=#inf
    for i=1,count do local p=inc.v[inf[i]];point(polygon,i,p[1],p[2],p[3]) end
    local cx,cy,cz=0,0,0
    for i=1,#rf do local p=ref.v[rf[i]];cx,cy,cz=cx+p[1]/#rf,cy+p[2]/#rf,cz+p[3]/#rf end
    for i=1,#rf do
        local p,q=ref.v[rf[i]],ref.v[rf[i%#rf+1]]
        local ex,ey,ez=q[1]-p[1],q[2]-p[2],q[3]-p[3]
        local nx,ny,nz=ey*z-ez*y,ez*x-ex*z,ex*y-ey*x
        if nx*(cx-p[1])+ny*(cy-p[2])+nz*(cz-p[3])>0 then nx,ny,nz=-nx,-ny,-nz end
        count=clip(count,nx,ny,nz,nx*p[1]+ny*p[2]+nz*p[3])
        if count==0 then return 0 end
    end
    local rp=ref.v[rf[1]];local plane=x*rp[1]+y*rp[2]+z*rp[3]
    local n=0
    for i=1,count do
        local p=polygon[i];local depth=plane-x*p[1]-y*p[2]-z*p[3]
        if depth>=-1e-8 then
            n=n+1;local v=point(candidates,n,p[1]+x*depth*.5,p[2]+y*depth*.5,p[3]+z*depth*.5)
            v.depth=max(0,depth);v.used=false
            v.feature=sat.generic_edge and(800000+side*20000000+fi*4096+ii*8+i)or(4000+side*1000+fi*100+ii*10+i)
        end
    end
    -- retain depth then spatial coverage when clipping creates >4 vertices
    -- this avoids selecting four adjacent corners of an octagonal overlap
    for i=1,min(4,n) do
        local best,index=-1,1
        for j=1,n do
            local p=candidates[j]
            if not p.used then
                local score=p.depth
                if i>1 then
                    score=math.huge
                    for k=1,i-1 do local q=out.points[k];score=min(score,(p[1]-q.px)^2+(p[2]-q.py)^2+(p[3]-q.pz)^2) end
                end
                if score>best then best,index=score,j end
            end
        end
        local p=candidates[index];p.used=true;emit(out,i,p[1],p[2],p[3],p.depth,p.feature)
    end
    return min(4,n)
end
local function support_edge(s,dir,x,y,z)
    local best,index=-math.huge,1
    for i=1,#s.edges do
        local e=s.edges[i];local a,b=s.v[e[1]],s.v[e[2]]
        local dx,dy,dz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
        local cross=(dy*dir[3]-dz*dir[2])^2+(dz*dir[1]-dx*dir[3])^2+(dx*dir[2]-dy*dir[1])^2
        if cross<1e-12*(dx*dx+dy*dy+dz*dz) then
            local score=(a[1]+b[1])*x+(a[2]+b[2])*y+(a[3]+b[3])*z
            if score>best then best,index=score,i end
        end
    end
    local e=s.edges[index];return s.v[e[1]],s.v[e[2]],index
end
local edge_dir,box_dir={},{}
local function edge_contacts(out)
    local e=A.edges[sat.edge];local p,q=A.v[e[1]],A.v[e[2]]
    local dx,dy,dz=q[1]-p[1],q[2]-p[2],q[3]-p[3];local len=sqrt(dx*dx+dy*dy+dz*dz)
    edge_dir[1],edge_dir[2],edge_dir[3]=dx/len,dy/len,dz/len
    if sat.generic_edge then
        local be=B.edges[sat.boxedge];local bp,bq=B.v[be[1]],B.v[be[2]]
        local bx,by,bz=bq[1]-bp[1],bq[2]-bp[2],bq[3]-bp[3];local length=sqrt(bx*bx+by*by+bz*bz)
        box_dir[1],box_dir[2],box_dir[3]=bx/length,by/length,bz/length
    else
        local axisn=B.n[sat.boxedge*2-1]
        box_dir[1],box_dir[2],box_dir[3]=axisn[1],axisn[2],axisn[3]
    end
    local a,b,ai=support_edge(A,edge_dir,sat.x,sat.y,sat.z)
    local c,d,bi=support_edge(B,box_dir,-sat.x,-sat.y,-sat.z)
    local ux,uy,uz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
    local vx,vy,vz=d[1]-c[1],d[2]-c[2],d[3]-c[3]
    local rx,ry,rz=a[1]-c[1],a[2]-c[2],a[3]-c[3]
    local aa,bb,ab=ux*ux+uy*uy+uz*uz,vx*vx+vy*vy+vz*vz,ux*vx+uy*vy+uz*vz
    local ar,br=ux*rx+uy*ry+uz*rz,vx*rx+vy*ry+vz*rz
    local denom=aa*bb-ab*ab
    local s=denom>1e-12 and max(0,min(1,(ab*br-bb*ar)/denom)) or 0
    local t=(ab*s+br)/bb
    if t<0 then t=0;s=max(0,min(1,-ar/aa)) elseif t>1 then t=1;s=max(0,min(1,(ab-ar)/aa)) end
    emit(out,1,(a[1]+s*ux+c[1]+t*vx)*.5,(a[2]+s*uy+c[2]+t*vy)*.5,(a[3]+s*uz+c[3]+t*vz)*.5,sat.depth,
        sat.generic_edge and(50000000+ai*4096+bi)or(6000+ai*20+bi))
    return 1
end
function M.collide(w,b,out)
    out.count=0;build(w,A,true);build(b,B,false)
    sat.score=math.huge;sat.edge=nil;sat.boxedge=nil;sat.generic_edge=false
    for i=1,#A.faces do local n=A.n[i];if not axis(n[1],n[2],n[3],nil,nil,'a') then return 0 end end
    for i=1,6 do local n=B.n[i];if not axis(n[1],n[2],n[3],nil,nil,'b') then return 0 end end
    for i=1,#A.edges do
        local e=A.edges[i];local p,q=A.v[e[1]],A.v[e[2]]
        local x,y,z=q[1]-p[1],q[2]-p[2],q[3]-p[3]
        for j=1,3 do local n=B.n[j*2-1]
            if not axis(y*n[3]-z*n[2],z*n[1]-x*n[3],x*n[2]-y*n[1],i,j) then return 0 end
        end
    end
    out.nx,out.ny,out.nz=sat.x,sat.y,sat.z
    out.count=sat.edge and edge_contacts(out) or face_contacts(out)
    return out.count
end
-- explicit offline polyhedra, or the unchanged native block/wedge solids
function M.collide_polyhedra(a,b,out,ah,bh)
    out.count=0;build(a,A,a.kind=='wedge',ah);build(b,B,b.kind=='wedge',bh)
    sat.score=math.huge;sat.edge=nil;sat.boxedge=nil;sat.generic_edge=true
    for i=1,#A.faces do local n=A.n[i];if not axis(n[1],n[2],n[3],nil,nil,'a')then return 0 end end
    for i=1,#B.faces do local n=B.n[i];if not axis(n[1],n[2],n[3],nil,nil,'b')then return 0 end end
    for i,e in ipairs(A.edges)do
        local p,q=A.v[e[1]],A.v[e[2]];local x,y,z=q[1]-p[1],q[2]-p[2],q[3]-p[3]
        for j,f in ipairs(B.edges)do
            local u,v=B.v[f[1]],B.v[f[2]];local bx,by,bz=v[1]-u[1],v[2]-u[2],v[3]-u[3]
            if not axis(y*bz-z*by,z*bx-x*bz,x*by-y*bx,i,j)then return 0 end
        end
    end
    out.nx,out.ny,out.nz=sat.x,sat.y,sat.z
    out.count=sat.edge and edge_contacts(out)or face_contacts(out)
    return out.count
end
return M
