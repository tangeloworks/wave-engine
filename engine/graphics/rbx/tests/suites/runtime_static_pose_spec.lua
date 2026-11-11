local suite={needs_graphics=true}
local rbx=require('engine/graphics/rbx')
local V,C=rbx.Vector3,rbx.CFrame
local function fixture(fn)
    local w=assert(rbx.new({simulate_physics=true,allow_remote_assets=false,physics_budget_ms=0,follow_display_settings=false}))
    local function part(name,position,anchored,size)
        return w.Instance.new('Part',{Name=name,Position=position,Size=size or V.new(2,2,2),Anchored=anchored,Parent=w.Workspace})
    end
    local ok,err=xpcall(function() fn(w,part) end,debug.traceback);w:Destroy();assert(ok,err)
end
function suite.run(t)
    t.describe('anchored singleton pose publication',function()
        t.it('keeps bodies and topology stable during repeated collidable platform transforms',function()
            fixture(function(w,part)
                w.Workspace.Gravity=0
                local platform=part('moving',V.new(0,0,0),true,V.new(8,1,8))
                local free=part('unrelated',V.new(80,10,0),false)
                w:update(1/60)
                local world=w._core._physics_world
                local anchor=world.part_to_assembly[platform._core_handle._id]
                local dynamic=world.part_to_assembly[free._core_handle._id].body
                local rebuilds=world.assembly_rebuild_count
                for i=1,60 do
                    platform.CFrame=C.new(i*.1,0,0)*C.Angles(0,i*.02,0);w:update(1/60)
                    assert(world.part_to_assembly[platform._core_handle._id]==anchor,'moving singleton replaced assembly')
                    assert(world.part_to_assembly[free._core_handle._id].body==dynamic,'unrelated body replaced')
                end
                assert(world.assembly_rebuild_count==rebuilds,'pose updates rebuilt topology')
                assert((platform.AssemblyCenterOfMass-platform.Position).Magnitude<1e-6,'COM stale')
            end)
        end)
        t.it('immediately updates translated and rotated query bounds without a simulation step',function()
            fixture(function(w,part)
                local p=part('bar',V.new(0,5,0),true,V.new(2,2,10));w:update(1/60)
                local params=rbx.RaycastParams.new();params.RespectCanCollide=true
                assert(w.Workspace:Raycast(V.new(0,10,4),V.new(0,-10,0),params).Instance==p)
                p.CFrame=C.new(20,5,0)*C.Angles(0,math.pi/2,0)
                assert(not w.Workspace:Raycast(V.new(0,10,4),V.new(0,-10,0),params),'old static bound survived')
                assert(w.Workspace:Raycast(V.new(24,10,0),V.new(0,-10,0),params).Instance==p,'new rotated bound missing')
            end)
        end)
        t.it('keeps huge singleton query bounds current across an adjacent hash range',function()
            fixture(function(w,part)
                local p=part('wide query surface',V.new(0,5,0),true,V.new(2048,.25,2048))
                p.CanCollide=false;p.CanQuery=true;w:update(1/60)
                local params=rbx.RaycastParams.new();params.FilterType=rbx.Enum.RaycastFilterType.Include
                params.FilterDescendantsInstances={p}
                local old=V.new(-1020,15,0)
                assert(w.Workspace:Raycast(old,V.new(0,-20,0),params).Instance==p,'initial wide static query missed')
                local world=w._core._physics_world
                local raw=assert(rawget(p,'_core_handle'))
                local proxy=assert(world.broadphase.static_proxies[world.part_to_assembly[raw._id].id])
                assert(#proxy.cells>=4096,'fixture did not exercise a large static footprint')
                local rebuilds=world.assembly_rebuild_count
                p.Position=V.new(32,5,0)
                assert(world.assembly_rebuild_count==rebuilds,'wide singleton pose rebuilt topology')
                assert(not w.Workspace:Raycast(old,V.new(0,-20,0),params),'old wide static query survived range shift')
                local moved=V.new(1040,15,0)
                assert(w.Workspace:Raycast(moved,V.new(0,-20,0),params).Instance==p,'new wide static query missed range shift')
            end)
        end)
        t.it('removes stale contacts and wakes a body when its old support is translated away',function()
            fixture(function(w,part)
                local platform=part('support',V.new(0,0,0),true,V.new(10,1,10))
                local cube=part('resting',V.new(0,1.5,0),false)
                for _=1,180 do w:update(1/60) end
                local world=w._core._physics_world;local old_y=cube.Position.Y
                local body=world.part_to_assembly[cube._core_handle._id].body
                assert(body.sleeping,'fixture did not settle asleep')
                platform.Position=V.new(30,0,0)
                assert(not body.sleeping,'old-support neighbor remained asleep')
                assert(not next(world.manifold_cache.by_part[platform._core_handle._id] or {}),'old contacts survived teleport')
                for _=1,20 do w:update(1/60) end
                assert(cube.Position.Y<old_y-2,'unsupported body did not fall')
            end)
        end)
        t.it('wakes only neighbors overlapping the new rotated bounds',function()
            fixture(function(w,part)
                w.Workspace.Gravity=0
                local p=part('bar',V.new(0,5,0),true,V.new(10,2,2))
                local near=part('new neighbor',V.new(24,9,0),false)
                local far=part('unrelated sleeper',V.new(70,30,0),false)
                for _=1,90 do w:update(1/60) end
                local world=w._core._physics_world
                local near_body=world.part_to_assembly[near._core_handle._id].body
                local far_body=world.part_to_assembly[far._core_handle._id].body
                assert(near_body.sleeping and far_body.sleeping,'fixture sleepers missing')
                p.CFrame=C.new(20,5,0)*C.Angles(0,0,math.pi/4)
                assert(not near_body.sleeping,'new rotated overlap remained asleep')
                assert(far_body.sleeping,'unrelated sleeper woke')
            end)
        end)
        t.it('publishes queryable noncollidable singleton motion without rebuilding',function()
            fixture(function(w,part)
                local p=part('query marker',V.new(0,5,0),true);p.CanCollide=false;w:update(1/60)
                local world=w._core._physics_world;local before=world.assembly_rebuild_count
                p.Position=V.new(20,5,0)
                local hit=w.Workspace:Raycast(V.new(20,10,0),V.new(0,-10,0))
                assert(hit and hit.Instance==p,'query marker not published')
                assert(world.assembly_rebuild_count==before,'query marker rebuilt topology')
            end)
        end)
        t.it('wakes new neighbors even while the static index awaits rebuilding',function()
            fixture(function(w,part)
                w.Workspace.Gravity=0
                local p=part('moving',V.new(0,5,0),true,V.new(10,2,2))
                local near=part('sleeping target',V.new(24,9,0),false)
                for _=1,90 do w:update(1/60) end
                local world=w._core._physics_world
                local body=world.part_to_assembly[near._core_handle._id].body
                assert(body.sleeping,'fixture did not sleep')
                -- Exercise the lazy static-index rebuild state directly; the
                -- assembly graph remains built, so pose publication is legal.
                world.broadphase_statics_dirty=true
                p.CFrame=C.new(20,5,0)*C.Angles(0,0,math.pi/4)
                assert(not body.sleeping,'dirty index hid the new wake region')
                local params=rbx.RaycastParams.new()
                params.FilterType=rbx.Enum.RaycastFilterType.Include
                params.FilterDescendantsInstances={p}
                assert(w.Workspace:Raycast(V.new(22,15,0),V.new(0,-20,0),params).Instance==p)
                assert(not world.broadphase_statics_dirty,'query did not refresh the static index')
            end)
        end)
        t.it('refreshes a pose moved while collision was disabled on reenable',function()
            fixture(function(w,part)
                local p=part('moving',V.new(0,5,0),true);w:update(1/60)
                local world=w._core._physics_world
                local config={};for key,value in pairs(world.config) do config[key]=value end
                config.collision_enabled=false;world:set_config(config)
                p.Position=V.new(60,5,0)
                assert(world.broadphase_statics_dirty,'disabled collision retained a clean obsolete index')
                config.collision_enabled=true;world:set_config(config)
                local hit=w.Workspace:Raycast(V.new(60,10,0),V.new(0,-10,0))
                assert(hit and hit.Instance==p,'reenabled collision kept old static bounds')
                assert(not w.Workspace:Raycast(V.new(0,10,0),V.new(0,-10,0)),'old pose survived reenable')
            end)
        end)
        t.it('retains compound anchored Weld propagation and rebuild fallback',function()
            fixture(function(w,part)
                local a=part('anchor',V.new(0,10,0),true)
                local b=part('attached',V.new(3,10,0),false)
                w.Instance.new('Weld',{Part0=a,Part1=b,C0=C.new(3,0,0),Parent=a});w:update(1/60)
                a.CFrame=C.new(20,10,0)*C.Angles(0,math.pi/2,0);w:update(1/60)
                assert((b.Position-(a.CFrame*C.new(3,0,0)).Position).Magnitude<1e-5,'compound pose stopped following')
            end)
        end)
        t.it('rebuilds adjacency-derived joints when legacy surface welding is enabled',function()
            fixture(function(w,part)
                w._core.physics_surface_welds=true
                local a=part('studs',V.new(0,10,0),true)
                local b=part('inlet',V.new(20,12,0),true)
                a.TopSurface=rbx.Enum.SurfaceType.Studs
                b.BottomSurface=rbx.Enum.SurfaceType.Inlet
                w:update(1/60)
                local world=w._core._physics_world
                local aid,bid=a._core_handle._id,b._core_handle._id
                assert(world.part_to_assembly[aid]~=world.part_to_assembly[bid],'fixture already welded')
                b.Position=V.new(0,12,0)
                assert(world.assembly_dirty,'surface adjacency change skipped topology rebuild')
                w:update(1/60)
                assert(world.part_to_assembly[aid]==world.part_to_assembly[bid],'touching legacy surfaces did not weld')
            end)
        end)
        t.it('keeps a stored runtime part out of physics until Workspace activates its final properties',function()
            fixture(function(w)
                w.Workspace.Gravity=0
                local stored=w.Instance.new('Part',{Name='stored query marker',Position=V.new(0,5,0),Size=V.new(2,2,2),
                    Anchored=true,CanCollide=false,CanQuery=true,CanTouch=false})
                local raw=assert(rawget(stored,'_core_handle'))
                assert(raw._workspace_active==false and raw._physics_excluded==true,
                    'new detached part entered the active physics set')
                w:update(1/60)
                assert(not w.Workspace:Raycast(V.new(0,10,0),V.new(0,-20,0)),
                    'stored query marker leaked into Workspace')
                stored.Parent=w.Workspace
                assert(raw._workspace_active==true and raw.CanCollide==false and raw.CanQuery==true and raw.CanTouch==false,
                    'Workspace activation lost stored collision/query properties')
                w:update(1/60)
                local hit=w.Workspace:Raycast(V.new(0,10,0),V.new(0,-20,0))
                assert(hit and hit.Instance==stored,'activated query marker was not registered')
                stored.Parent=nil
                assert(raw._workspace_active==false,'stored marker did not leave active membership')
                assert(not w.Workspace:Raycast(V.new(0,10,0),V.new(0,-20,0)),
                    'unparented marker remained queryable')

                local direct=w.Instance.new('Part',{Name='direct query marker',Position=V.new(20,5,0),Size=V.new(2,2,2),
                    Anchored=true,CanCollide=false,CanQuery=true,Parent=w.Workspace})
                local direct_raw=assert(rawget(direct,'_core_handle'))
                assert(direct_raw._workspace_active==true,'initial Workspace parent did not activate membership')
                w:update(1/60)
                local direct_hit=w.Workspace:Raycast(V.new(20,10,0),V.new(0,-20,0))
                assert(direct_hit and direct_hit.Instance==direct,'initial Workspace parent was not queryable')
            end)
        end)
        t.it('does not rebuild clean topology when an already-unbound stored marker departs Workspace',function()
            fixture(function(w)
                local marker=w.Instance.new('Part',{Name='released stored marker',Position=V.new(0,5,0),
                    Size=V.new(2,2,2),Anchored=true,CanCollide=false,CanQuery=true,Parent=w.Workspace})
                w:update(1/60)
                local world=w._core._physics_world;local raw=assert(rawget(marker,'_core_handle'))
                assert(world.part_to_assembly[raw._id],'fixture marker was not bound before release')
                assert(world:remove_singleton_assembly(raw._id),'fixture could not release singleton body')
                assert(world.part_to_assembly[raw._id]==nil and not world.assembly_dirty,
                    'fixture did not establish a clean unbound member')
                local rebuilds=world.assembly_rebuild_count
                marker.Parent=nil
                assert(raw._workspace_active==false and raw._physics_removed_inplace==true,
                    'stored unbound marker did not complete membership cleanup')
                w:update(0)
                assert(world.assembly_rebuild_count==rebuilds and not world.assembly_dirty,
                    'stored no-body removal rebuilt unrelated topology')
                assert(not w.Workspace:Raycast(V.new(0,10,0),V.new(0,-20,0)),
                    'stored no-body marker remained queryable')
            end)
        end)
    end)
end
return suite
