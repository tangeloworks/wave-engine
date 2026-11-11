local suite={needs_graphics=true}
local rbx=require("engine/graphics/rbx")
local V,C=rbx.Vector3,rbx.CFrame
local function near(a,b,label)
    assert((a-b).Magnitude<1e-6,(label or "vector")..": "..tostring(a).." vs "..tostring(b))
end
local function fixture(fn)
    local world=assert(rbx.new({simulate_physics=true,allow_remote_assets=false,
        physics_budget_ms=0,follow_display_settings=false}))
    local ok,err=xpcall(function()
        world.Workspace.Gravity=0
        local material=rbx.PhysicalProperties.new(1,0,0,100,100)
        local a=world.Instance.new("Part",{Name="Root",Parent=world.Workspace,
            Size=V.new(2,2,2),Position=V.new(0,20,0),RootPriority=1,Anchored=false,CustomPhysicalProperties=material})
        local b=world.Instance.new("Part",{Name="Member",Parent=world.Workspace,
            Size=V.new(2,4,2),Position=V.new(0,24,0),Anchored=false,CustomPhysicalProperties=material})
        local c0=C.new(0,4,0)*C.Angles(.1,.3,.2)
        local c1=C.new(.4,0,.2)*C.Angles(0,.1,0)
        world.Instance.new("Weld",{Parent=a,Part0=a,Part1=b,C0=c0,C1=c1})
        world:update(1/60)
        local physics=world._core._physics_world
        local ar=rawget(a,"_core_handle")
        local assembly=assert(physics.part_to_assembly[ar._id])
        assert(#assembly.parts==2 and not assembly.body.is_static and math.abs(a.AssemblyMass-24)<1e-6)
        fn(world,a,b,c0*c1:Inverse(),physics,assembly)
    end,debug.traceback)
    world:Destroy();assert(ok,err)
end
function suite.run(t)
    t.describe("dynamic compound rigid pose publication",function()
        t.it("moves either welded member without rebuilding topology or changing mass and velocity",function()
            fixture(function(w,a,b,relative,physics,assembly)
                a.Velocity=V.new(2,3,4);a.RotVelocity=V.new(.1,.2,.3)
                local velocity,angular=a.Velocity,a.RotVelocity
                local rebuilds=physics.assembly_rebuild_count
                local body,offsets=assembly.body,assembly.body.local_offsets
                for i=1,24 do
                    local goal=C.new(i*3,20+i*.25,-i)*C.Angles(.02*i,.03*i,-.01*i)
                    if i%2==1 then a.CFrame=goal else b.CFrame=goal*relative end
                    assert(not physics.assembly_dirty,"Rigid compound pose dirtied whole-world topology")
                    near(a.Position,goal.Position,"root position")
                    near(b.Position,(goal*relative).Position,"member position")
                    near(a.CFrame.LookVector,goal.LookVector,"root orientation")
                    near(b.CFrame.UpVector,(goal*relative).UpVector,"member orientation")
                    near(a.AssemblyCenterOfMass,(a.Position*8+b.Position*16)/24,"mass-weighted COM")
                    near(a.Velocity,velocity,"linear velocity")
                    near(a.RotVelocity,angular,"angular velocity")
                    assert(assembly.body==body and body.local_offsets==offsets and math.abs(a.AssemblyMass-24)<1e-6)
                    w:update(0)
                    assert(physics.assembly_rebuild_count==rebuilds,"Pose publication rebuilt every assembly")
                end
            end)
        end)
        t.it("publishes moved compound members to immediate ray queries and clears their old bounds",function()
            fixture(function(w,a,b,relative,physics)
                local params=rbx.RaycastParams.new()
                params.FilterType=rbx.Enum.RaycastFilterType.Include
                params.FilterDescendantsInstances={b};params.RespectCanCollide=true
                local old=b.Position
                assert(w.Workspace:Raycast(old+V.new(0,0,8),V.new(0,0,-16),params))
                local rebuilds=physics.assembly_rebuild_count
                a.CFrame=C.new(40,30,10)*C.Angles(.1,.4,.2)
                local center=(a.CFrame*relative).Position
                local hit=w.Workspace:Raycast(center+V.new(0,0,8),V.new(0,0,-16),params)
                assert(hit and hit.Instance==b,"New compound pose was absent from an immediate query")
                assert(not w.Workspace:Raycast(old+V.new(0,0,8),V.new(0,0,-16),params),"Old compound bounds remained queryable")
                assert(physics.assembly_rebuild_count==rebuilds,"Immediate compound query rebuilt topology")
            end)
        end)
        t.it("clears a distant member's contacts and wakes a sleeper on its old support",function()
            fixture(function(w,a,b,relative,physics)
                local joint=a:FindFirstChild("Weld")
                joint.C0=C.new(20,0,0);joint.C1=C.new()
                w:update(0)
                local sleeper=w.Instance.new("Part",{Name="Supported",Parent=w.Workspace,
                    Size=V.new(2,2,2),Position=b.Position+V.new(0,2.99,0),Anchored=false})
                for _=1,3 do w:update(1/60) end
                local bid=rawget(b,"_core_handle")._id
                local sid=rawget(sleeper,"_core_handle")._id
                local indexed=physics.manifold_cache.by_part[bid]
                assert(indexed and next(indexed),"Fixture did not create the distant member contact")
                local sleeping_body=physics.part_to_assembly[sid].body
                physics:park_body(sleeping_body)
                assert(sleeping_body.sleeping and physics.broadphase.sleeping_proxies[sleeping_body.id])
                local rebuilds=physics.assembly_rebuild_count
                a.CFrame=a.CFrame+V.new(0,0,30)
                assert(not sleeping_body.sleeping,"Removing the distant welded support did not wake its sleeper")
                indexed=physics.manifold_cache.by_part[bid]
                assert(not indexed or not next(indexed),"Old nonroot contact survived the rigid teleport")
                assert(not physics.assembly_dirty and physics.assembly_rebuild_count==rebuilds)
            end)
        end)
    end)
end
return suite
