local suite = {}

function suite.run(t,h)
    local N = h.need("physics/narrowphase.lua")
    local function collider(shape,x,y,z,yaw,radius)
        radius = radius or 1
        local size = shape == "Ball" and {x=radius*2,y=radius*2,z=radius*2} or {x=4,y=2,z=8}
        return N.make_collider({}, {Shape=shape,Size=size},x,y,z,
            math.cos((yaw or 0)/2),0,math.sin((yaw or 0)/2),0)
    end
    local function check_contact(w,s,nx,ny,nz,penetration)
        local out = {}
        t.expect(N.collide(w,s,out)):to_be(1)
        t.expect(out.nx):to_be_near(nx,1e-8)
        t.expect(out.ny):to_be_near(ny,1e-8)
        t.expect(out.nz):to_be_near(nz,1e-8)
        t.expect(out.points[1].penetration):to_be_near(penetration,1e-8)
        local x,y,z = out.points[1].px,out.points[1].py,out.points[1].pz
        t.expect(N.collide(s,w,out)):to_be(1)
        t.expect(out.nx):to_be_near(-nx,1e-8)
        t.expect(out.ny):to_be_near(-ny,1e-8)
        t.expect(out.nz):to_be_near(-nz,1e-8)
        t.expect(out.points[1].px):to_be_near(x,1e-8)
        t.expect(out.points[1].py):to_be_near(y,1e-8)
        t.expect(out.points[1].pz):to_be_near(z,1e-8)
    end
    t.describe("native wedge sphere contacts",function()
        t.it("uses the inclined face normal in both pair orders and after rotation",function()
            local ny,nz = 4/math.sqrt(17),-1/math.sqrt(17)
            for _,yaw in ipairs({0,.7,math.pi}) do
                local s,c = math.sin(yaw),math.cos(yaw)
                local nx,wz = s*nz,c*nz
                check_contact(collider("Wedge",10,4,-20,yaw),
                    collider("Ball",10+nx*.75,4+ny*.75,-20+wz*.75),nx,ny,wz,.25)
            end
        end)
        t.it("does not collide with the empty half of a wedge's bounding box",function()
            local out = {}
            t.expect(N.collide(collider("Wedge",0,0,0),collider("Ball",0,.8,-3,0,.1),out)):to_be(0)
            t.expect(N.collide(collider("CornerWedge",0,0,0),collider("Ball",-1.5,.8,3,0,.1),out)):to_be(0)
        end)
        t.it("resolves finite edges and vertices without extending the slope plane",function()
            local ny,nz = 4/math.sqrt(17),-1/math.sqrt(17)
            local nx = -1/math.sqrt(2); ny,nz = ny/math.sqrt(2),nz/math.sqrt(2)
            check_contact(collider("Wedge",0,0,0),
                collider("Ball",-2+nx*.5,ny*.5,nz*.5,0,.75),nx,ny,nz,.25)
            local n = 1/math.sqrt(3)
            check_contact(collider("Wedge",0,0,0),
                collider("Ball",2+n*.5,-1-n*.5,4+n*.5,0,.75),n,-n,n,.25)
            t.expect(N.collide(collider("Wedge",0,0,0),collider("Ball",6,0,0,0,.1),{})):to_be(0)
        end)
        t.it("preserves solid sides and separates an embedded sphere along its nearest face",function()
            check_contact(collider("Wedge",0,0,0),collider("Ball",0,-.8,2,0,.5),0,-1,0,.7)
            check_contact(collider("Wedge",0,0,0),collider("Ball",2.5,-.5,2,0,.75),1,0,0,.25)
        end)
        t.it("uses both CornerWedge slopes with the Roblox apex at positive X, negative Z",function()
            local ny,nz = 4/math.sqrt(17),1/math.sqrt(17)
            check_contact(collider("CornerWedge",0,0,0),
                collider("Ball",1.8,ny*.5,nz*.5,0,.75),0,ny,nz,.25)
            local nx; nx,ny = -1/math.sqrt(5),2/math.sqrt(5)
            check_contact(collider("CornerWedge",0,0,0),
                collider("Ball",nx*.5,ny*.5,-3,0,.75),nx,ny,0,.25)
        end)
    end)
end
return suite
