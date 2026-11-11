-- exact sphere contacts against native Wedge/CornerWedge solids. the five
-- outward planes match geometry.lua and the public raycast shape. Face
-- projections plus finite edge segments give the closest point, including
-- corners and centres inside the solid, without treating the empty half as a box
local Wedge = {}
local sqrt, min, max = math.sqrt, math.min, math.max
local wedge_edges = {{1,2},{2,3},{3,4},{4,1},{4,5},{3,6},{5,6},{1,5},{2,6}}
local corner_edges = {{1,2},{2,3},{3,4},{4,1},{1,5},{2,5},{3,5},{4,5}}

function Wedge.geometry(view, hx, hy, hz)
    local corner = view.Shape == "CornerWedge" or view.ClassName == "CornerWedgePart"
    local g = view._wedge_geometry
    if g and g.hx == hx and g.hy == hy and g.hz == hz and g.corner == corner then return g end
    local inv = 1 / sqrt(hy*hy + hz*hz)
    local vertices = {{-hx,-hy,-hz},{hx,-hy,-hz},{hx,-hy,hz},{-hx,-hy,hz}}
    local planes
    if corner then
        vertices[5] = {hx,hy,-hz}
        local inv_x = 1 / sqrt(hy*hy + hx*hx)
        planes = {{0,-1,0,hy},{1,0,0,hx},{0,0,-1,hz},
            {0,hz*inv,hy*inv,0},{-hy*inv_x,hx*inv_x,0,0}}
    else
        vertices[5], vertices[6] = {-hx,hy,hz}, {hx,hy,hz}
        planes = {{0,-1,0,hy},{0,0,1,hz},{1,0,0,hx},{-1,0,0,hx},
            {0,hz*inv,-hy*inv,0}}
    end
    g = {hx=hx,hy=hy,hz=hz,corner=corner,vertices=vertices,planes=planes,
        edges=corner and corner_edges or wedge_edges}
    view._wedge_geometry = g
    return g
end

-- Signed distance and outward normal, local surface witness and stable feature
function Wedge.closest(g, x, y, z)
    local planes = g.planes
    local furthest, face = -math.huge, 1
    for i = 1, 5 do
        local p = planes[i]
        local d = x*p[1] + y*p[2] + z*p[3] - p[4]
        if d > furthest then furthest, face = d, i end
    end
    if furthest <= 1e-10 then
        local p = planes[face]
        return furthest,p[1],p[2],p[3],x-furthest*p[1],y-furthest*p[2],z-furthest*p[3],face
    end
    -- the most violated plane is a lower bound on distance to the solid. its
    -- projection is the exact answer when it lies on the finite face (the usual
    -- slope contact), so no edge search is needed on the hot path
    local p = planes[face]
    local px,py,pz = x-furthest*p[1],y-furthest*p[2],z-furthest*p[3]
    local on_face = true
    for i = 1, 5 do
        local f = planes[i]
        if px*f[1]+py*f[2]+pz*f[3]-f[4] > 1e-9 then on_face=false;break end
    end
    if on_face then return furthest,p[1],p[2],p[3],px,py,pz,face end
    local best, qx, qy, qz, feature = math.huge, 0, 0, 0, 0
    for i = 1, 5 do
        local p = planes[i]
        local d = x*p[1] + y*p[2] + z*p[3] - p[4]
        local px, py, pz = x-d*p[1], y-d*p[2], z-d*p[3]
        if d*d < best then
            local inside = true
            for j = 1, 5 do
                local f = planes[j]
                if px*f[1] + py*f[2] + pz*f[3] - f[4] > 1e-9 then inside = false; break end
            end
            if inside then best,qx,qy,qz,feature = d*d,px,py,pz,i end
        end
    end
    for i = 1, #g.edges do
        local edge = g.edges[i]
        local a, b = g.vertices[edge[1]], g.vertices[edge[2]]
        local dx, dy, dz = b[1]-a[1], b[2]-a[2], b[3]-a[3]
        local t = max(0,min(1,((x-a[1])*dx+(y-a[2])*dy+(z-a[3])*dz)/(dx*dx+dy*dy+dz*dz)))
        local px, py, pz = a[1]+t*dx, a[2]+t*dy, a[3]+t*dz
        local ex, ey, ez = x-px, y-py, z-pz
        local d2 = ex*ex+ey*ey+ez*ez
        if d2 < best then
            best,qx,qy,qz = d2,px,py,pz
            feature = t == 0 and 200+edge[1] or (t == 1 and 200+edge[2] or 100+i)
        end
    end
    local distance = sqrt(best)
    return distance,(x-qx)/distance,(y-qy)/distance,(z-qz)/distance,qx,qy,qz,feature
end

-- Normal points wedge -> sphere. the existing PGS solver resolves this normal
-- using the same mass, friction, restitution, warm starting and iterations
function Wedge.sphere(w, s, out)
    local dx, dy, dz = s.cx-w.cx, s.cy-w.cy, s.cz-w.cz
    local x = dx*w.u0x + dy*w.u0y + dz*w.u0z
    local y = dx*w.u1x + dy*w.u1y + dz*w.u1z
    local z = dx*w.u2x + dy*w.u2y + dz*w.u2z
    for i = 1, 5 do
        local p = w.wedge.planes[i]
        if x*p[1]+y*p[2]+z*p[3]-p[4] > s.radius then out.count=0; return 0 end
    end
    local d,nx,ny,nz,qx,qy,qz,feature = Wedge.closest(w.wedge,x,y,z)
    if d > s.radius then out.count=0; return 0 end
    local wx = w.u0x*nx + w.u1x*ny + w.u2x*nz
    local wy = w.u0y*nx + w.u1y*ny + w.u2y*nz
    local wz = w.u0z*nx + w.u1z*ny + w.u2z*nz
    out.nx,out.ny,out.nz,out.count = wx,wy,wz,1
    out.points = out.points or {}
    local p = out.points[1] or {}; out.points[1] = p
    p.px = (w.cx+w.u0x*qx+w.u1x*qy+w.u2x*qz + s.cx-wx*s.radius)*.5
    p.py = (w.cy+w.u0y*qx+w.u1y*qy+w.u2y*qz + s.cy-wy*s.radius)*.5
    p.pz = (w.cz+w.u0z*qx+w.u1z*qy+w.u2z*qz + s.cz-wz*s.radius)*.5
    p.penetration, p.feature_id = s.radius-d, 2000+feature
    return 1
end

return Wedge
