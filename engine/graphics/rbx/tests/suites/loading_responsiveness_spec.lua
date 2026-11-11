local suite = {}
function suite.run(t, h)
    for _, m in ipairs({'common.lua','gui.lua','parser.lua','scene.lua','datamodel.lua','assets.lua','render.lua','lifecycle.lua'}) do h.runtime_require(m) end
    local R = h.env.RBX
    local Policy, Groups = h.need('physics/collision_group_policy.lua'), h.need('physics/collision_groups.lua')
    local function fixture(run)
        local old = love.timer.getTime
        local now, seen = 0, {}
        love.timer.getTime = function() return now end
        local core = setmetatable({parts={},_load_stage_times={},
            _physics_world={collision_groups=Groups.new()}}, {__index=R})
        function core:_get_collision_group_registry() return self._physics_world.collision_groups end
        for i=1,80 do core.parts[i]={ClassName='MeshPart', MeshId='fixture-'..i, Transparency=0, id=i} end
        function core:_get_or_parse_part_mesh(part)
            seen[#seen+1]=part.id; now=now+.001
            if self.fail then error('injected source failure') end
            return nil -- unavailable sources retain their normal fallback later
        end
        function core:_end_load_gc_window() end
        function core:_clear_full_build_mesh_resolution_memo() end
        function core:_recover_failed_map_apply(path, owner, captured)
            assert(path=='fixture' and captured==true and owner==self._collision_group_load)
            Policy.rollback(self, owner)
            return true
        end
        local function start()
            local s={phase='building', map_path='fixture',started_at=now,build_slice_seconds=.0025}
            -- Production application begins and commits this exact owner
            -- before contact-source preparation. Keep its real finish,
            -- cancellation and failed-generation rules in the isolated test.
            local parts={};Policy.decorate(parts,{})
            s.collision_policy_owner=Policy.begin(core,Policy.prepare_map({parsed_parts=parts}))
            Policy.commit(core,s.collision_policy_owner);s.apply_started=true
            core._async_map_load=s
            local cp=core:_create_async_map_checkpoint(s)
            s.build_coroutine=coroutine.create(function()
                core.result=core:_prepare_contact_mesh_sources(cp)
                return {}
            end)
            return s
        end
        local ok,err=xpcall(function() run(core,start,seen,function()return now end) end,debug.traceback)
        local cleanup_ok,cleanup_error=pcall(function()
            if core._async_map_load then core:_cancel_async_map_load() end
            assert(core._collision_group_load==nil,'Preparation fixture leaked its exact policy owner')
        end)
        love.timer.getTime=old
        if not ok then error(err,0) end
        assert(cleanup_ok,cleanup_error)
    end
    t.describe('resumable contact source acquisition',function()
        t.it('processes each required source once over bounded resumptions with intervening event opportunities',function()
            fixture(function(c,start,seen,clock)
                local s=start();local turns=0
                while c._async_map_load do
                    local before=#seen;c:_pump_async_map_load();turns=turns+1
                    assert(#seen-before<=8,'one resumption exceeded eight source acquisitions')
                    assert(turns<20)
                end
                assert(#seen==80 and turns==11)
                for i=1,80 do assert(seen[i]==i) end
                assert(math.abs(clock()-.080)<1e-9)
                assert(c.result.blocks==10 and c.result.source_calls==80)
                assert(math.abs(c.result.longest_block_ms-8)<1e-8)
                assert(s.build_checkpoint==nil and c:_service_async_map_load(1)==0)
                -- Turns are opportunities for root events, not proof of OS input.
            end)
        end)
        t.it('observes later raw source changes without snapshotting appearance or bounds',function()
            fixture(function(c,start,seen)
                start();c:_pump_async_map_load();assert(#seen==8)
                c.parts[9].id=109;c.parts[10]._destroyed=true
                c.parts[11].Transparency=1
                while c._async_map_load do c:_pump_async_map_load() end
                assert(seen[9]==109 and seen[10]==12 and #seen==78)
                for _,p in ipairs(c.parts)do assert(p._rb_cache==nil and p._contact_ao_top==nil)end
            end)
        end)
        t.it('continues bounded texture publication between acquisition blocks instead of starving workers',function()
            fixture(function(c,start,seen)
                local drains=0
                c._drain_texture_prefetch=function(self)
                    drains=drains+1
                    if drains==1 then self.parts[9].id=209 end
                end
                start();c:_pump_async_map_load()
                assert(drains==1 and #seen==8)
                while c._async_map_load do c:_pump_async_map_load() end
                assert(drains==10 and seen[9]==209)
            end)
        end)
        t.it('abandons preparation on cancellation/replacement and permits a valid subsequent generation',function()
            fixture(function(c,start,seen)
                local old=start();c:_pump_async_map_load();assert(#seen==8)
                c:_cancel_async_map_load();assert(old.build_checkpoint==nil)
                assert(c:_service_async_map_load(1)==0 and #seen==8)
                start();while c._async_map_load do c:_pump_async_map_load() end
                assert(#seen==88 and c._last_map_load_status.success)
            end)
        end)
        t.it('propagates a source exception and recovers on the next load without extra settled work',function()
            fixture(function(c,start,seen)
                start();c:_pump_async_map_load();c.fail=true;c:_pump_async_map_load()
                assert(c._async_map_load==nil and not c._last_map_load_status.success)
                c.fail=false;start();while c._async_map_load do c:_pump_async_map_load() end
                assert(c._last_map_load_status.success and #seen==89)
                love.timer.getTime=function()error('settled clock access')end
                assert(c:_service_async_map_load(1)==0)
            end)
        end)
    end)
end
return suite
