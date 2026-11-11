-- Scalar implementation of the authored source beam equations. Scratch stores
-- private samples only; published rows contain numbers, never borrowed vectors.
local M={}
function M.prepare(fx,record,p,camera,numeric,clamp,vertex)
    local batch=record.batch;batch.count=0
    batch.light_emission=clamp(numeric(p.LightEmission,0),0,1)
    batch.light_influence=clamp(numeric(p.LightInfluence,0),0,1)
    batch.brightness=math.max(0,numeric(p.Brightness,1))
    if p.Enabled~=true then fx:_upload(batch,nil,768);return end
    local a,b=fx:_attachment(record,'Attachment0'),fx:_attachment(record,'Attachment1')
    if not a or not b then fx:_upload(batch,nil,768);return end
    local texture,available=fx:_image(p.Texture,record,true)
    if not available then fx:_upload(batch,nil,768);return end
    local segments=math.floor(numeric(p.Segments,10))
    if segments<1 or segments>128 then
        fx:_report(record,'Segments','The source beam segment count is outside the bounded 1–128 contract.','bounded-capacity')
        fx:_upload(batch,nil,768);return
    end
    local mode=numeric(p.TextureMode,0)
    if mode~=0 and mode~=1 and mode~=2 then
        fx:_report(record,'TextureMode','Unsupported beam texture mode.');fx:_upload(batch,nil,768);return
    end
    local p0,p3=a.Position,b.Position
    local ar,br=a.RightVector,b.RightVector
    local c0,c1=numeric(p.CurveSize0,0),numeric(p.CurveSize1,0)
    local x0,y0,z0=p0.X,p0.Y,p0.Z;local x3,y3,z3=p3.X,p3.Y,p3.Z
    local x1,y1,z1=x0+ar.X*c0,y0+ar.Y*c0,z0+ar.Z*c0
    local x2,y2,z2=x3-br.X*c1,y3-br.Y*c1,z3-br.Z*c1
    local samples=record.beam_samples
    if not samples then samples={};record.beam_samples=samples end
    local length=0
    for i=0,segments do
        local t=i/segments;local k=1-t
        local wa,wb,wc,wd=k*k*k,3*k*k*t,3*k*t*t,t*t*t
        local x,y,z=x0*wa+x1*wb+x2*wc+x3*wd,y0*wa+y1*wb+y2*wc+y3*wd,z0*wa+z1*wb+z2*wc+z3*wd
        if i>0 then
            local prev=samples[i];local dx,dy,dz=x-prev.x,y-prev.y,z-prev.z
            length=length+math.sqrt(dx*dx+dy*dy+dz*dz)
        end
        local sample=samples[i+1]
        if not sample then sample={};samples[i+1]=sample end
        sample.x,sample.y,sample.z,sample.distance,sample.t=x,y,z,length,t
    end
    local cp,cr=camera.Position,camera.RightVector
    local au,bu=a.UpVector,b.UpVector
    local cx,cy,cz=cp.X,cp.Y,cp.Z
    local texlength=math.max(1e-9,numeric(p.TextureLength,1))
    local previous_ax,previous_ay,previous_az,previous_bx,previous_by,previous_bz
    local previous_u,previous_r,previous_g,previous_blue,previous_alpha
    for i=1,segments+1 do
        local sample=samples[i];local t=sample.t
        local wa,wb,wc=3*(1-t)^2,6*(1-t)*t,3*t*t
        local tx,ty,tz=(x1-x0)*wa+(x2-x1)*wb+(x3-x2)*wc,
            (y1-y0)*wa+(y2-y1)*wb+(y3-y2)*wc,(z1-z0)*wa+(z2-z1)*wb+(z3-z2)*wc
        if math.sqrt(tx*tx+ty*ty+tz*tz)<1e-8 then tx,ty,tz=x3-x0,y3-y0,z3-z0 end
        local sx,sy,sz
        if p.FaceCamera==true then
            local dx,dy,dz=cx-sample.x,cy-sample.y,cz-sample.z
            sx,sy,sz=ty*dz-tz*dy,tz*dx-tx*dz,tx*dy-ty*dx
        else
            sx,sy,sz=au.X*(1-t)+bu.X*t,au.Y*(1-t)+bu.Y*t,au.Z*(1-t)+bu.Z*t
        end
        local side_length=math.sqrt(sx*sx+sy*sy+sz*sz)
        if side_length<1e-8 then sx,sy,sz=cr.X,cr.Y,cr.Z
        else sx,sy,sz=sx/side_length,sy/side_length,sz/side_length end
        local width=(numeric(p.Width0,1)*(1-t)+numeric(p.Width1,1)*t)*.5
        local dx,dy,dz=cx-sample.x,cy-sample.y,cz-sample.z
        local distance=math.sqrt(dx*dx+dy*dy+dz*dz);local z=numeric(p.ZOffset,0)
        local ox,oy,oz=0,0,0
        if distance>1e-8 then ox,oy,oz=(dx/distance)*z,(dy/distance)*z,(dz/distance)*z end
        local px,py,pz=sample.x+ox,sample.y+oy,sample.z+oz
        local ux,uy,uz=sx*width,sy*width,sz*width
        local ax,ay,az,bx,by,bz=px-ux,py-uy,pz-uz,px+ux,py+uy,pz+uz
        local u=(mode==0 and t*texlength or sample.distance/texlength)-fx.time*numeric(p.TextureSpeed,0)
        local r,g,blue,alpha=fx:_ribbon_color(p,t)
        if i>1 then
            vertex(batch,previous_ax,previous_ay,previous_az,previous_u,0,previous_r,previous_g,previous_blue,previous_alpha)
            vertex(batch,previous_bx,previous_by,previous_bz,previous_u,1,previous_r,previous_g,previous_blue,previous_alpha)
            vertex(batch,bx,by,bz,u,1,r,g,blue,alpha)
            vertex(batch,previous_ax,previous_ay,previous_az,previous_u,0,previous_r,previous_g,previous_blue,previous_alpha)
            vertex(batch,bx,by,bz,u,1,r,g,blue,alpha);vertex(batch,ax,ay,az,u,0,r,g,blue,alpha)
        end
        previous_ax,previous_ay,previous_az,previous_bx,previous_by,previous_bz=ax,ay,az,bx,by,bz
        previous_u,previous_r,previous_g,previous_blue,previous_alpha=u,r,g,blue,alpha
    end
    fx:_upload(batch,texture,768)
end
return M
