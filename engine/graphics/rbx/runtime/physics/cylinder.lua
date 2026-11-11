-- Native X-axis, circular, flat-ended cylinder contacts. private narrowphase helper
-- Sphere query is analytic. Box query uses exact support mappings, bounded GJK/EPA
-- and an analytic cap-disk / side-segment manifold when a box face is supporting
-- Cylinder pairs use exact parallel disk/interval contacts or the same bounded
-- convex query with two cylinder supports. no geometry tessellation is involved
-- no external implementation copied. Query failures raise an explicit error, they
-- are never converted to a separation or to an undisclosed box/capsule fallback
local C = {}
local abs,sqrt,min,max=math.abs,math.sqrt,math.min,math.max
local function finite(x) return type(x)=='number' and x==x and abs(x)<math.huge end
local function clamp(x,a,b) return max(a,min(b,x)) end
local function v(x,y,z) return {x=x,y=y,z=z} end
local function sub(a,b) return v(a.x-b.x,a.y-b.y,a.z-b.z) end
local function neg(a) return v(-a.x,-a.y,-a.z) end
local function dot(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
local function cross(a,b) return v(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) end
local function scale(a,s) return v(a.x*s,a.y*s,a.z*s) end
local function norm(a) local d=sqrt(dot(a,a));return d>1e-15 and scale(a,1/d) or nil end
local function axis(c,i) return v(c['u'..i..'x'],c['u'..i..'y'],c['u'..i..'z']) end
local function centre(c) return v(c.cx,c.cy,c.cz) end
local function point(out,i,p,pen,id)
    out.points=out.points or {};local q=out.points[i] or {};out.points[i]=q
    q.px,q.py,q.pz=p.x,p.y,p.z;q.penetration=pen;q.feature_id=id
end
local function emit(out,n,p,pen,id)
    out.nx,out.ny,out.nz=n.x,n.y,n.z;out.count=1;point(out,1,p,pen,id);return 1
end
local function validate(c)
    for _,k in ipairs({'cx','cy','cz','hx','hy','hz','u0x','u0y','u0z','u1x','u1y','u1z','u2x','u2y','u2z'}) do
        if not finite(c[k]) then error('cylinder contact: non-finite descriptor '..k,3) end
    end
    if c.hx<=0 or c.hy<=0 or c.hz<=0 then error('cylinder contact: non-positive extent',3) end
end
local function local_point(c,p)
    local d=sub(p,centre(c));return v(dot(d,axis(c,0)),dot(d,axis(c,1)),dot(d,axis(c,2)))
end
local function world_vector(c,p)
    return v(c.u0x*p.x+c.u1x*p.y+c.u2x*p.z,c.u0y*p.x+c.u1y*p.y+c.u2y*p.z,c.u0z*p.x+c.u1z*p.y+c.u2z*p.z)
end
local function world_point(c,p)
    local q=world_vector(c,p);q.x=q.x+c.cx;q.y=q.y+c.cy;q.z=q.z+c.cz;return q
end

-- Normal cylinder -> sphere, closest point on the finite solid, including rim
function C.sphere(c,s,out)
    validate(c);validate(s)
    local p=local_point(c,centre(s));local r=min(c.hy,c.hz);local h=c.hx
    local rho=sqrt(p.y*p.y+p.z*p.z)
    local q=v(clamp(p.x,-h,h),p.y,p.z)
    if rho>r then q.y=q.y*r/rho;q.z=q.z*r/rho end
    local d=sub(p,q);local dist=sqrt(dot(d,d));local n,pen,id
    if dist>1e-12 then
        if dist>s.radius then out.count=0;return 0 end
        n=scale(d,1/dist);pen=s.radius-dist
        id=(abs(p.x)>h and rho>r) and 1203 or (abs(p.x)>h and 1202 or 1201)
    else
        local cap=h-abs(p.x);local side=r-rho
        if cap<=side then
            n=v(p.x>=0 and 1 or -1,0,0);q.x=n.x*h;pen=cap+s.radius;id=1204
        else
            n=rho>1e-12 and v(0,p.y/rho,p.z/rho) or v(0,1,0)
            q.y=n.y*r;q.z=n.z*r;pen=side+s.radius;id=1205
        end
    end
    -- Midpoint of opposing surface witnesses, with the established positive-depth convention
    local nw=world_vector(c,n);local cw=world_point(c,q)
    local sw=v(s.cx-nw.x*s.radius,s.cy-nw.y*s.radius,s.cz-nw.z*s.radius)
    return emit(out,nw,v((cw.x+sw.x)*.5,(cw.y+sw.y)*.5,(cw.z+sw.z)*.5),pen,id)
end

local function support(c,d,is_cylinder)
    if c.vertices then
        local best,index=-math.huge,1
        for i,p in ipairs(c.vertices)do local distance=dot(p,d);if distance>best then best,index=distance,i end end
        return c.vertices[index]
    end
    local x,y,z=dot(d,axis(c,0)),dot(d,axis(c,1)),dot(d,axis(c,2))
    local px=x>=0 and c.hx or -c.hx;local py,pz
    if is_cylinder then
        local length=sqrt(y*y+z*z);local radius=min(c.hy,c.hz)
        if length>1e-15 then py,pz=radius*y/length,radius*z/length else py,pz=0,0 end
    else py=y>=0 and c.hy or -c.hy;pz=z>=0 and c.hz or -c.hz end
    return world_point(c,v(px,py,pz))
end
local function minkowski(c,b,d,second_cylinder)
    local a=support(c,d,true);local q=support(b,neg(d),second_cylinder)
    local p=sub(a,q);p.a=a;p.b=q;return p
end
local function perpendicular(d)
    local a=abs(d.x)<abs(d.y) and v(1,0,0) or v(0,1,0)
    return cross(d,a)
end
local function line(s)
    local a,b=s[1],s[2];local ab=sub(b,a);local ao=neg(a)
    if dot(ab,ao)<=0 then s[2]=nil;return ao end
    local d=cross(cross(ab,ao),ab)
    if dot(d,d)<1e-24 then d=perpendicular(ab) end
    return d
end
local function triangle(s)
    local a,b,c=s[1],s[2],s[3];local ab,ac,ao=sub(b,a),sub(c,a),neg(a)
    local n=cross(ab,ac)
    if dot(n,n)<1e-24 then s[3]=nil;return line(s) end
    if dot(cross(n,ac),ao)>0 then
        if dot(ac,ao)>0 then s[2]=c;s[3]=nil;return line(s) end
        s[3]=nil;return line(s)
    elseif dot(cross(ab,n),ao)>0 then s[3]=nil;return line(s) end
    if dot(n,ao)<0 then s[2],s[3]=c,b;return neg(n) end
    return n
end
local function simplex(s)
    if #s==2 then return line(s) end
    if #s==3 then return triangle(s) end
    local a=s[1]
    for _,ids in ipairs({{2,3,4},{3,4,2},{4,2,3}}) do
        local b,c,o=s[ids[1]],s[ids[2]],s[ids[3]]
        local n=cross(sub(b,a),sub(c,a))
        if dot(n,sub(o,a))>0 then n=neg(n);b,c=c,b end
        if dot(n,neg(a))>1e-14 then
            s[2],s[3],s[4]=b,c,nil;return triangle(s)
        end
    end
    return nil -- tetrahedron contains origin (possibly on its boundary)
end
local function gjk(c,b,limit,second_cylinder)
    local d=sub(centre(b),centre(c));if dot(d,d)<1e-20 then d=v(1,0,0) end
    local s={minkowski(c,b,d,second_cylinder)};d=neg(s[1])
    for i=1,limit do
        if dot(d,d)<1e-24 then d=v(0,1,0) end
        d=assert(norm(d),'cylinder convex query: degenerate GJK direction')
        local p=minkowski(c,b,d,second_cylinder)
        if dot(p,d)<0 then return nil,i end -- a genuine supporting separating plane
        table.insert(s,1,p);d=simplex(s)
        if not d then return s,i end
    end
    error('cylinder convex query: GJK iteration limit (not proven separated)',3)
end
local function face(vertices,i,j,k,opposite)
    local a,b,c=vertices[i],vertices[j],vertices[k]
    local n=norm(cross(sub(b,a),sub(c,a)));if not n then return nil end
    if (opposite and dot(n,sub(vertices[opposite],a))>0) or (not opposite and dot(n,a)<0) then
        j,k=k,j;n=neg(n)
    end
    local distance=dot(n,a)
    if distance< -1e-8 then error('cylinder convex query: invalid EPA seed',3) end
    return {i=i,j=j,k=k,n=n,d=max(0,distance)}
end
local function witnesses(vertices,f)
    local a,b,c=vertices[f.i],vertices[f.j],vertices[f.k]
    local ab,ac=sub(b,a),sub(c,a);local ap=sub(scale(f.n,f.d),a)
    local aa,bb,cc,ad,bd=dot(ab,ab),dot(ab,ac),dot(ac,ac),dot(ap,ab),dot(ap,ac)
    local denominator=aa*cc-bb*bb
    if abs(denominator)<1e-24 then error('cylinder convex query: degenerate EPA witness',3) end
    local wb=(cc*ad-bb*bd)/denominator;local wc=(aa*bd-bb*ad)/denominator;local wa=1-wb-wc
    return v((a.a.x+a.b.x)*wa*.5+(b.a.x+b.b.x)*wb*.5+(c.a.x+c.b.x)*wc*.5,
        (a.a.y+a.b.y)*wa*.5+(b.a.y+b.b.y)*wb*.5+(c.a.y+c.b.y)*wc*.5,
        (a.a.z+a.b.z)*wa*.5+(b.a.z+b.b.z)*wb*.5+(c.a.z+c.b.z)*wc*.5)
end
local function epa(c,b,vertices,tolerance,limit,second_cylinder)
    local faces={face(vertices,1,2,3,4),face(vertices,1,4,2,3),face(vertices,1,3,4,2),face(vertices,2,4,3,1)}
    if #faces~=4 then error('cylinder convex query: degenerate EPA seed',3) end
    for iteration=1,limit do
        local nearest=faces[1]
        for i=2,#faces do if faces[i].d<nearest.d then nearest=faces[i] end end
        local p=minkowski(c,b,nearest.n,second_cylinder)
        if dot(nearest.n,p)-nearest.d<=tolerance then return nearest.n,nearest.d,witnesses(vertices,nearest),iteration end
        local edges={};local keep={}
        local function edge(i,j)
            for k=#edges,1,-1 do if edges[k][1]==j and edges[k][2]==i then table.remove(edges,k);return end end
            edges[#edges+1]={i,j}
        end
        for _,f in ipairs(faces) do
            if dot(f.n,sub(p,vertices[f.i]))>1e-12 then edge(f.i,f.j);edge(f.j,f.k);edge(f.k,f.i)
            else keep[#keep+1]=f end
        end
        if #edges==0 then error('cylinder convex query: EPA failed to expand',3) end
        vertices[#vertices+1]=p;local id=#vertices
        for _,e in ipairs(edges) do local f=face(vertices,e[1],e[2],id);if f then keep[#keep+1]=f end end
        faces=keep
        if #faces==0 or #faces>260 then error('cylinder convex query: EPA face bound exceeded',3) end
    end
    error('cylinder convex query: EPA iteration limit (not proven separated)',3)
end

-- Clip the exact circular cap or side generator to a supporting box face
-- this is a contact set, not a polygon used to approximate cylinder intersection
local function face_manifold(c,b,n,depth,out,tol)
    local axes={axis(b,0),axis(b,1),axis(b,2)};local halves={b.hx,b.hy,b.hz}
    local selected
    for i=1,3 do if abs(dot(n,axes[i]))>1-1e-6 then selected=i;break end end
    if not selected then return false end
    local exact=scale(axes[selected],dot(n,axes[selected])>=0 and 1 or -1)
    local pa=support(c,exact,true);local pb=support(b,neg(exact),false)
    local exact_depth=dot(sub(pa,pb),exact)
    if exact_depth<0 or exact_depth>depth+tol*4 then return false end
    local ax=axis(c,0);local alignment=dot(ax,exact);local radial=abs(alignment)<1e-7
    local cap=abs(alignment)>1-1e-7
    if not radial and not cap then return false end
    n=exact;depth=exact_depth
    local side={};for i=1,3 do if i~=selected then side[#side+1]=i end end
    local points={}
    local function inside(p)
        local d=sub(p,centre(b))
        for _,i in ipairs(side) do if abs(dot(d,axes[i]))>halves[i]+tol then return false end end
        return true
    end
    local function add(p)
        if not inside(p) then return end
        for _,q in ipairs(points) do local d=sub(p,q);if dot(d,d)<tol*tol then return end end
        points[#points+1]=p
    end
    if radial then
        local mid=world_point(c,v(0,dot(n,axis(c,1))*min(c.hy,c.hz),dot(n,axis(c,2))*min(c.hy,c.hz)))
        local lo,hi=-c.hx,c.hx
        for _,i in ipairs(side) do
            local a=dot(sub(mid,centre(b)),axes[i]);local slope=dot(ax,axes[i])
            if abs(slope)<1e-12 then if abs(a)>halves[i]+tol then return false end
            else local u=(-halves[i]-a)/slope;local z=(halves[i]-a)/slope;lo=max(lo,min(u,z));hi=min(hi,max(u,z)) end
        end
        if lo>hi then return false end
        -- the interval midpoint is also on the exact generator. Solve it first:
        -- a centred impact then needs no cancelling endpoint torques in finite PGS
        for _,s in ipairs({(lo+hi)*.5,lo,hi}) do add(v(mid.x+ax.x*s,mid.y+ax.y*s,mid.z+ax.z*s)) end
    else
        local sign=alignment>=0 and 1 or -1;local radius=min(c.hy,c.hz)
        local cc=world_point(c,v(sign*c.hx,0,0));local u,vert=axis(c,1),axis(c,2)
        -- circle extremal support points in each rectangle tangent direction
        for _,i in ipairs(side) do
            local x,y=dot(axes[i],u),dot(axes[i],vert);local length=sqrt(x*x+y*y)
            for _,sgn in ipairs({-1,1}) do add(world_point(c,v(sign*c.hx,sgn*radius*x/length,sgn*radius*y/length))) end
        end
        local corners={}
        for _,signs in ipairs({{-1,-1},{1,-1},{1,1},{-1,1}}) do
            local q=centre(b)
            for k,i in ipairs(side) do q.x=q.x+axes[i].x*halves[i]*signs[k];q.y=q.y+axes[i].y*halves[i]*signs[k];q.z=q.z+axes[i].z*halves[i]*signs[k] end
            local d=dot(sub(cc,q),n);q.x=q.x+n.x*d;q.y=q.y+n.y*d;q.z=q.z+n.z*d
            corners[#corners+1]=q
            local vq=sub(q,cc);if dot(vq,vq)<=radius*radius+tol*tol then add(q) end
        end
        for i=1,4 do
            local a=corners[i];local e=sub(corners[i%4+1],a);local o=sub(a,cc)
            local aa=dot(e,e);local bb=2*dot(o,e);local dd=bb*bb-4*aa*(dot(o,o)-radius*radius)
            if dd>=0 then
                for _,sgn in ipairs({-1,1}) do local s=(-bb+sgn*sqrt(dd))/(2*aa)
                    if s>=0 and s<=1 then add(v(a.x+e.x*s,a.y+e.y*s,a.z+e.z*s)) end
                end
            end
        end
    end
    if #points==0 then return false end
    -- Deterministic spread: four extremes, then remaining distinct candidates
    local chosen={};local used={}
    if radial then chosen[1]=points[1];used[1]=true end
    for _,i in ipairs(side) do for _,sgn in ipairs({-1,1}) do
        local best,index=-math.huge,1
        for k,p in ipairs(points) do local d=sgn*dot(p,axes[i]);if d>best then best=d;index=k end end
        if not used[index] then chosen[#chosen+1]=points[index];used[index]=true end
    end end
    for k,p in ipairs(points) do if #chosen>=min(4,#points) then break end;if not used[k] then chosen[#chosen+1]=p end end
    out.count=#chosen;out.nx,out.ny,out.nz=n.x,n.y,n.z
    for i,p in ipairs(chosen) do point(out,i,v(p.x-n.x*depth*.5,p.y-n.y*depth*.5,p.z-n.z*depth*.5),depth,(cap and 1300 or 1400)+selected*10+i) end
    return true
end
function C.box(c,b,out,limits)
    validate(c);validate(b)
    local tolerance=1e-7*max(1,c.hx,c.hy,c.hz,b.hx,b.hy,b.hz)
    local simplex_points,gi=gjk(c,b,limits and limits.gjk or 48)
    out.query_iterations=gi
    if not simplex_points then out.count=0;return 0 end
    local n,depth,p,ei=epa(c,b,simplex_points,tolerance,limits and limits.epa or 128)
    out.query_iterations=gi+ei
    if not face_manifold(c,b,n,depth,out,tolerance) then emit(out,n,p,depth,1500) end
    return out.count
end
-- Parallel finite cylinders are products of an interval and a circular disk
-- their exact separation/depth avoids an EPA degeneracy along a whole generator
-- the contact set samples exact supporting features, never polygonal collision
local function parallel_pair(a,b,out)
    local ax=axis(a,0);local ab=sub(centre(b),centre(a));local x=dot(ab,ax)
    local radial=sub(ab,scale(ax,x));local rho=sqrt(dot(radial,radial))
    local ra,rb=min(a.hy,a.hz),min(b.hy,b.hz)
    local side,cap=ra+rb-rho,a.hx+b.hx-abs(x)
    out.query_iterations=0
    if side<0 or cap<0 then out.count=0;return 0 end
    if side<cap then
        local n=rho>1e-15 and scale(radial,1/rho) or axis(a,1)
        local lo,hi=max(-a.hx,x-b.hx),min(a.hx,x+b.hx)
        local mid=scale(n,ra-side*.5);local count=0
        for _,s in ipairs({(lo+hi)*.5,lo,hi}) do
            if count==0 or hi-lo>1e-8 then
                local p=centre(a);p.x=p.x+mid.x+ax.x*s;p.y=p.y+mid.y+ax.y*s;p.z=p.z+mid.z+ax.z*s
                count=count+1;point(out,count,p,side,1600+count)
            end
        end
        out.nx,out.ny,out.nz=n.x,n.y,n.z;out.count=count;return count
    end
    local n=scale(ax,x>=0 and 1 or -1)
    local u=rho>1e-15 and scale(radial,1/rho) or axis(a,1);local w=cross(ax,u)
    if rho<=1e-12 then
        -- a centred normal impact is one linear constraint, not four cancelling
        -- angular impulses. Solve its exact central contact first, retain three
        -- circular support points for tipping resistance, within the 4-row budget
        local r=min(ra,rb);local center=centre(a);local shift=a.hx-cap*.5
        for i,p in ipairs({{0,0},{r,0},{-.5*r,math.sqrt(3)*.5*r},{-.5*r,-math.sqrt(3)*.5*r}}) do
            point(out,i,v(center.x+n.x*shift+u.x*p[1]+w.x*p[2],center.y+n.y*shift+u.y*p[1]+w.y*p[2],
                center.z+n.z*shift+u.z*p[1]+w.z*p[2]),cap,1700+i)
        end
        out.nx,out.ny,out.nz=n.x,n.y,n.z;out.count=4;return 4
    end
    local candidates={};local tolerance=1e-10*max(1,ra,rb)
    local function add(s,t)
        if s*s+t*t>ra*ra+tolerance or (s-rho)^2+t*t>rb*rb+tolerance then return end
        for _,p in ipairs(candidates) do if abs(p[1]-s)+abs(p[2]-t)<1e-10 then return end end
        candidates[#candidates+1]={s,t}
    end
    for _,p in ipairs({{0,0},{rho,0},{ra,0},{-ra,0},{0,ra},{0,-ra},
        {rho+rb,0},{rho-rb,0},{rho,rb},{rho,-rb}}) do add(p[1],p[2]) end
    if rho>1e-15 and rho>=abs(ra-rb) then
        local s=(ra*ra-rb*rb+rho*rho)/(2*rho);local t=sqrt(max(0,ra*ra-s*s));add(s,t);add(s,-t)
    end
    assert(#candidates>0,'cylinder/cylinder: empty parallel cap intersection')
    local chosen,used={},{}
    for _,coord in ipairs({1,2}) do for _,sgn in ipairs({-1,1}) do
        local best,index=-math.huge,1
        for i,p in ipairs(candidates) do if p[coord]*sgn>best then best,index=p[coord]*sgn,i end end
        if not used[index] then chosen[#chosen+1]=candidates[index];used[index]=true end
    end end
    local center=centre(a);local shift=a.hx-cap*.5
    for i,p in ipairs(chosen) do
        point(out,i,v(center.x+n.x*shift+u.x*p[1]+w.x*p[2],center.y+n.y*shift+u.y*p[1]+w.y*p[2],
            center.z+n.z*shift+u.z*p[1]+w.z*p[2]),cap,1700+i)
    end
    out.nx,out.ny,out.nz=n.x,n.y,n.z;out.count=#chosen;return out.count
end
function C.cylinder(a,b,out,limits)
    validate(a);validate(b)
    -- Canonical query ordering preserves witness/feature identity under pair reversal
    if a.part_id and b.part_id and a.part_id>b.part_id then
        local count=C.cylinder(b,a,out,limits)
        if count>0 then out.nx,out.ny,out.nz=-out.nx,-out.ny,-out.nz end
        return count
    end
    local cross_axes=cross(axis(a,0),axis(b,0))
    if dot(cross_axes,cross_axes)<=1e-24 and not limits then return parallel_pair(a,b,out) end
    local tolerance=1e-7*max(1,a.hx,a.hy,a.hz,b.hx,b.hy,b.hz)
    local seed,gi=gjk(a,b,limits and limits.gjk or 48,true);out.query_iterations=gi
    if not seed then out.count=0;return 0 end
    local n,depth,p,ei=epa(a,b,seed,tolerance,limits and limits.epa or 128,true)
    out.query_iterations=gi+ei
    return emit(out,n,p,depth,1800)
end
-- a provided finite convex support map against the native circular cylinder
-- existing cylinder paths and their analytic special cases remain unchanged
function C.convex(hull,cylinder,out,limits)
    validate(hull);validate(cylinder)
    assert(type(hull.vertices)=='table'and #hull.vertices>=4,'Expected finite convex support vertices')
    local seed,gi=gjk(hull,cylinder,limits and limits.gjk or 64,true);out.query_iterations=gi
    if not seed then out.count=0;return 0 end
    local tolerance=1e-7*max(1,hull.hx,hull.hy,hull.hz,cylinder.hx,cylinder.hy,cylinder.hz)
    local n,depth,p,ei=epa(hull,cylinder,seed,tolerance,limits and limits.epa or 128,true)
    out.query_iterations=gi+ei;return emit(out,n,p,depth,1900)
end
return C
