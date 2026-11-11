local suite={needs_graphics=true}
local rbx=require('engine/graphics/rbx')
local V,C=rbx.Vector3,rbx.CFrame
function suite.run(t)
    t.describe('public impulse publication across pending topology',function()
        t.it('publishes consumed setter and impulse velocities even at an unchanged solved pose',function()
            local w=assert(rbx.new({simulate_physics=true,allow_remote_assets=false,physics_budget_ms=0,follow_display_settings=false}))
            local ok,err=xpcall(function()
                w.Workspace.Gravity=0
                -- Use the reproduced player-size/axis contact. A one-stud
                -- sphere's sampled tangency can legitimately restitute.
                local wall=w.Instance.new('Part',{Anchored=true,Size=V.new(8,8,.1),Position=V.new(0,10,-2),Parent=w.Workspace})
                local p=w.Instance.new('Part',{Anchored=false,Shape=rbx.Enum.PartType.Ball,Size=V.new(3,3,3),Position=V.new(0,10,0),Parent=w.Workspace})
                w:update(0);p.Velocity=V.new(0,0,-480);w:update(1/60)
                assert(p.Position.Z>=-.451 and p.Velocity.Z==0)
                local frame=p._core_handle.CFrame
                for _,kind in ipairs{'setter','impulse'}do
                    if kind=='setter'then p.Velocity=V.new(0,0,-480)else p:ApplyImpulse(V.new(0,0,-480)*p:GetMass())end
                    assert(math.abs(p.Velocity.Z+480)<1e-8,'External velocity was not published')
                    w:update(1/60)
                    local body=w._core._physics_world.part_to_assembly[p._core_handle._id].body
                    assert(body.vz==0 and p.Velocity.Z==0 and p.AssemblyLinearVelocity.Z==0,'Facade retained a consumed velocity')
                    assert(rawequal(p._core_handle.CFrame,frame),'Velocity-only writeback needlessly replaced the CFrame')
                end
            end,debug.traceback)
            w:Destroy();assert(ok,err)
        end)
        for _,kind in ipairs({'linear','at_position','angular'}) do
            t.it('retains '..kind..' impulse before and after an unrelated assembly rebuild',function()
                local w=assert(rbx.new({simulate_physics=true,allow_remote_assets=false,physics_budget_ms=0,follow_display_settings=false}))
                local ok,err=xpcall(function()
                    w.Workspace.Gravity=0
                    local p=w.Instance.new('Part',{Size=V.new(2,2,2),Position=V.new(0,10,0),Anchored=false,Parent=w.Workspace})
                    local platform=w.Instance.new('Part',{Anchored=true,Position=V.new(30,0,0),Parent=w.Workspace})
                    w:update(0)
                    -- Shape edits force the same assembly refresh that a live
                    -- compound joint/stance change can cause before an impulse.
                    p.Size=V.new(2,3,2)
                    platform.CFrame=C.new(31,0,0)
                    if kind=='linear' then p:ApplyImpulse(V.new(10,0,0)*p:GetMass())
                    elseif kind=='at_position' then p:ApplyImpulseAtPosition(V.new(10,0,0)*p:GetMass(),p.Position+V.new(0,1,0))
                    else p:ApplyAngularImpulse(V.new(0,0,10)) end
                    local linear,angular=p.Velocity,p.RotVelocity
                    assert(kind=='angular' and angular.Magnitude>0.1 or kind~='angular' and linear.X>9.9,'impulse not published')
                    if kind=='at_position' then assert(angular.Magnitude>0.1) end
                    platform.Size=V.new(3,3,3)
                    w.Workspace:Raycast(V.new(31,10,0),V.new(0,-20,0))
                    w:update(1/60)
                    assert((p.Velocity-linear).Magnitude<1e-5,'rebuild erased linear impulse')
                    assert((p.RotVelocity-angular).Magnitude<1e-5,'rebuild erased angular impulse')
                end,debug.traceback)
                w:Destroy();assert(ok,err)
            end)
        end
        t.it('preserves all compound member velocity aliases through a later shape rebuild',function()
            local w=assert(rbx.new({simulate_physics=true,allow_remote_assets=false,physics_budget_ms=0,follow_display_settings=false}))
            local ok,err=xpcall(function()
                w.Workspace.Gravity=0
                local p=w.Instance.new('Part',{Size=V.new(2,2,2),Position=V.new(0,10,0),Anchored=false,CanCollide=false,Parent=w.Workspace})
                local q=w.Instance.new('Part',{Size=V.new(2,2,2),Position=V.new(0,12,0),Anchored=false,CanCollide=false,Parent=w.Workspace})
                w.Instance.new('Weld',{Part0=p,Part1=q,C0=C.new(0,2,0),Parent=p})
                w:update(0)
                p:ApplyImpulseAtPosition(V.new(10,0,0)*(p:GetMass()+q:GetMass()),p.Position+V.new(0,1,1))
                local linear,angular=p.Velocity,p.RotVelocity
                assert(linear.X>9.9 and angular.Magnitude>0.1)
                assert((q.Velocity-linear).Magnitude<1e-5 and (q.RotVelocity-angular).Magnitude<1e-5)
                q.Size=V.new(2,2,3)
                w:update(1/60)
                assert((p.Velocity-linear).Magnitude<1e-5 and (q.Velocity-linear).Magnitude<1e-5)
                assert((p.RotVelocity-angular).Magnitude<1e-5 and (q.RotVelocity-angular).Magnitude<1e-5)
            end,debug.traceback)
            w:Destroy();assert(ok,err)
        end)
    end)
end
return suite
