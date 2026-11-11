local suite={}
function suite.run(t,h)
    local N=h.need('physics/narrowphase.lua')
    local function c(shape,x,y,z,sx,sy,sz,qw,qx,qy,qz)
        return N.make_collider({}, {Shape=shape,Size={x=sx,y=sy,z=sz}},x,y,z,qw,qx,qy,qz)
    end
    local function near(a,b) t.expect(a):to_be_near(b,1e-7) end
    local function pair(w,b,nx,ny,nz,depth)
        local o={};t.assert_that(N.collide(w,b,o)>0,'missing contact')
        near(o.nx,nx);near(o.ny,ny);near(o.nz,nz)
        local deepest=0
        for i=1,o.count do local p=o.points[i];deepest=math.max(deepest,p.penetration)
            t.assert_that(p.px==p.px and p.py==p.py and p.pz==p.pz,'nonfinite witness')
        end
        near(deepest,depth)
        local reverse={};near(N.collide(b,w,reverse),o.count)
        near(reverse.nx,-nx);near(reverse.ny,-ny);near(reverse.nz,-nz)
        for i=1,o.count do
            near(reverse.points[i].px,o.points[i].px);near(reverse.points[i].py,o.points[i].py);near(reverse.points[i].pz,o.points[i].pz)
        end
        return o
    end
    t.describe('native wedge block contacts',function()
        t.it('leaves the empty half empty for blocks in both pair orders',function()
            local w=c('Wedge',0,0,0,4,2,8)
            local b=c('Block',0,.8,-3,.2,.2,.2)
            near(N.collide(w,b,{}),0);near(N.collide(b,w,{}),0)
            near(N.collide(c('CornerWedge',0,0,0,4,2,8),c('Block',-1.5,.8,3,.2,.2,.2),{}),0)
        end)
        t.it('reports analytic slope normals and depths after arbitrary yaw',function()
            local ny,nz=4/math.sqrt(17),-1/math.sqrt(17)
            local d=.25*(ny-nz)-.1
            for _,yaw in ipairs({0,.7,math.pi}) do
                local s,co=math.sin(yaw),math.cos(yaw)
                local nx,wz=s*nz,co*nz
                pair(c('Wedge',10,4,-20,4,2,8,math.cos(yaw/2),0,math.sin(yaw/2),0),
                    c('Block',10+nx*d,4+ny*d,-20+wz*d,.5,.5,.5,math.cos(yaw/2),0,math.sin(yaw/2),0),nx,ny,wz,.1)
            end
        end)
        t.it('produces four supporting contacts for a box parallel to the incline',function()
            local angle=-math.atan(.25);local ny,nz=math.cos(angle),math.sin(angle)
            local o=pair(c('Wedge',0,0,0,4,2,8),c('Block',0,ny*.4,nz*.4,1,1,1,math.cos(angle/2),math.sin(angle/2),0,0),0,ny,nz,.1)
            near(o.count,4)
        end)
        t.it('keeps steep slopes inclined instead of replacing them with their box',function()
            local ny,nz=1/math.sqrt(17),-4/math.sqrt(17)
            local d=.25*(ny-nz)-.1
            pair(c('Wedge',0,0,0,4,8,2),c('Block',0,ny*d,nz*d,.5,.5,.5),0,ny,nz,.1)
        end)
        t.it('preserves the finite solid back, sides and flat underside',function()
            local w=c('Wedge',0,0,0,4,2,8)
            pair(w,c('Block',2.4,-.5,2,1,1,1),1,0,0,.1)
            pair(w,c('Block',0,0,4.4,1,1,1),0,0,1,.1)
            local o=pair(w,c('Block',0,-1.4,0,1,1,1),0,-1,0,.1);near(o.count,4)
            near(N.collide(w,c('Block',2.6,0,0,1,1,1),{}),0)
            near(N.collide(w,c('Block',0,0,4.6,1,1,1),{}),0)
        end)
        t.it('uses the second corner-wedge incline and preserves ordinary box contacts',function()
            local nx,ny=-1/math.sqrt(5),2/math.sqrt(5)
            local d=.1*(ny-nx)-.025
            pair(c('CornerWedge',0,0,0,4,2,8),c('Block',nx*d,ny*d,-3,.2,.2,.2),nx,ny,0,.025)
            local o=pair(c('Block',0,0,0,4,2,8),c('Block',0,1.4,0,1,1,1),0,1,0,.1);near(o.count,4)
        end)
        t.it('separates skew finite edges even when every face projection overlaps',function()
            -- Independent separating-plane witness: along n below the box's
            -- maximum is 0.326168462 below the wedge's minimum. No face axis
            -- separates this pose; it requires an edge cross-product axis.
            local q={-.821156428143027,-.19768286096505375,.4232500037551443,-.3278460634525406}
            local w=c('Wedge',0,0,0,4,2,8)
            near(N.collide(w,c('Block',2.621,.627,-.676,1,1,1,unpack(q)),{}),0)
            local o=pair(w,c('Block',2.3611327269319196,.3631431541727059,-.6100357885431765,1,1,1,unpack(q)),
                .6908268481691933,.7014326622151474,-.17535816555378686,.05)
            near(o.count,1)
        end)
        t.it('retains underside contacts with a rotated enclosing box',function()
            local q=math.sin(.13/2)
            local w=c('Wedge',0,0,0,4,2,8)
            local b=c('Block',0,-1.49,0,1,1,1,math.cos(.13/2),0,q,0)
            local o=pair(w,b,0,-1,0,.01);near(o.count,4)
        end)
    end)
end
return suite
