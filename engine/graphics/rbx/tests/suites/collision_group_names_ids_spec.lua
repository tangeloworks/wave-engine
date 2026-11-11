-- UNRUN private regression suite. Layout/name/ID coverage only; no source-mask pair oracle.
local suite = {}
local ACTUAL_HEX = "01040004ffffffff0744656661756c740104f3ffffff05626565626f0204f5ffffff046974656d0304f9ffffff07736e617063616d"
local function unhex(value)
    return (value:gsub("..", function(pair) return string.char(assert(tonumber(pair, 16))) end))
end
local ACTUAL = unhex(ACTUAL_HEX)
local function row(id, name, mask)
    return string.char(id, 4)..(mask or string.rep(string.char(255), 4))..string.char(#name)..name
end
local SPARSE = string.char(1, 3)..row(31, "omega")..row(0, "Default")..row(5, "alpha")
local function rejected(fn)
    local ok = pcall(fn); assert(not ok, "Expected strict rejection")
end
function suite.run(t, harness)
    local Data = harness.need("physics/collision_group_data.lua")
    local Groups = harness.need("physics/collision_groups.lua")
    local Policy = harness.need("physics/collision_group_policy.lua")
    local Part = harness.need("physics/collision_group_part.lua")
    local Service = harness.need("physics/service.lua")
    local function imported(raw) return Groups.from_descriptor(assert(Data.decode(raw))) end
    local function core(groups)
        local c = { _physics_world={collision_groups=groups or Groups.new()}, changes=0 }
        local dm = { _core=c, _services_by_name={} }; c._datamodel=dm
        local ws = { _properties={CollisionGroupData="old", TouchesUseCollisionGroups=true},
            _datamodel=dm }; dm._services_by_name.Workspace=ws
        function c:_get_collision_group_registry() return self._physics_world.collision_groups end
        function c:_register_collision_group(name, id) return self:_get_collision_group_registry():register(name,id) end
        function c:_on_runtime_part_collision_changed() self.changes=self.changes+1 end
        return c, ws
    end
    local function map(raw, parts, roots)
        local settings={CollisionGroupData=raw, TouchesUseCollisionGroups=false}
        parts=parts or {}; Policy.decorate(parts,settings)
        return {parsed_parts=parts,workspace_settings=settings,instance_roots=roots}
    end
    t.describe("authored collision group names and stable explicit IDs", function()
        t.it("preserves the actual 53 bytes and masks without interpreting pairs", function()
            local desc=assert(Data.decode(ACTUAL)); local g=Groups.from_descriptor(desc)
            assert(desc.raw_hex==ACTUAL_HEX and #desc.raw_data==53 and Data.is_validated(desc))
            assert(g:name_for_id(0)=="Default" and g:name_for_id(1)=="beebo"
                and g:name_for_id(2)=="item" and g:name_for_id(3)=="snapcam")
            local expected={4294967295,4294967283,4294967285,4294967289}
            for i,v in ipairs(expected) do assert(g.source_policy.rows[i].mask_le_u32==v) end
            assert(g.source_policy.raw_data==ACTUAL and g.source_policy.pair_interpretation=="not-applied"
                and g.source_policy.pair_semantics_inferred==false
                and g.source_policy.source_pair_collidability_qualified==false)
            assert(desc.collidable_by_id==nil and desc.pair_convention==nil)
            -- This is the documented names-only policy, not an expected source pair answer.
            assert(g.blocked_count==0)
        end)
        t.it("retains sparse IDs regardless of source row and lookup order", function()
            local g=imported(SPARSE); local c=core(g)
            local s=setmetatable({_core=c},{__index=Service})
            assert(s:GetCollisionGroupId("omega")==31 and s:GetCollisionGroupId("alpha")==5)
            assert(s:GetCollisionGroupName(31)=="omega" and s:GetCollisionGroupName(5)=="alpha"
                and s:GetCollisionGroupName(1)=="")
            local count=g.public_count; local rows=s:GetCollisionGroups()
            assert(#rows==3 and rows[1].name=="Default" and rows[1].id==0
                and rows[2].name=="alpha" and rows[2].id==5
                and rows[3].name=="omega" and rows[3].id==31 and g.public_count==count)
            s:RegisterCollisionGroup("later"); assert(s:GetCollisionGroupId("later")==1)
            assert(s:GetCollisionGroupId("omega")==31 and s:GetCollisionGroupId("alpha")==5)
        end)
        t.it("rejects inferred, forged and mutated descriptors", function()
            rejected(function() Groups.from_descriptor({groups={},by_id={}}) end)
            local desc=assert(Data.decode(ACTUAL)); desc.groups[2].name="changed"
            rejected(function() Groups.from_descriptor(desc) end)
            local inferred=assert(Data.decode(ACTUAL,Data.EXPLICIT_INFERENCE_CONVENTION))
            rejected(function() Groups.from_descriptor(inferred) end)
        end)
        t.it("rejects malformed present layout before publishing a registry", function()
            local old=Groups.new(); local c,ws=core(old)
            local bad={string.char(2)..ACTUAL:sub(2),ACTUAL:sub(1,-2),ACTUAL.."x",
                string.char(1,2)..row(0,"Default")..row(0,"duplicate"),
                string.char(1,2)..row(0,"Default")..row(5,"Default")}
            for _,raw in ipairs(bad) do
                rejected(function() Policy.prepare_map(map(raw,{{collision_group_legacy_id=0}})) end)
                assert(c:_get_collision_group_registry()==old and c._collision_group_load==nil
                    and ws._properties.CollisionGroupData=="old")
            end
        end)
        t.it("resolves numeric source parts and modern names without mutating source nodes", function()
            local source={ClassName="Part",CollisionGroupId=5,Children={}}
            local parts={{collision_group_legacy_id=31},
                {collision_group_source_name="unregistered",collision_group_legacy_id=5}}
            local m=map(SPARSE,parts,{source})
            local token=Policy.prepare_map(m);local c,ws=core()
            local owner=Policy.begin(c,token);Policy.commit(c,owner)
            assert(parts[1].collision_group=="omega" and parts[2].collision_group=="unregistered")
            assert(Policy.resolve_source(c,source)=="alpha" and source.CollisionGroup==nil
                and source.CollisionGroupId==5)
            assert(c._workspace_touches_use_collision_groups==false
                and c._collision_group_source.raw_data==SPARSE
                and c._collision_group_source.names_and_ids_imported==true
                and c._collision_group_source.pair_semantics_inferred==false
                and c._collision_group_source.source_pair_collidability_qualified==false)
            Policy.finish(c,owner);assert(c._collision_group_load==nil)
        end)
        t.it("keeps absent metadata compatibility separate from present unknown IDs", function()
            local absent=map(nil,{{collision_group_legacy_id=7}})
            local token=Policy.prepare_map(absent);local c=core()
            local owner=Policy.begin(c,token);Policy.commit(c,owner)
            assert(absent.parsed_parts[1].collision_group=="Group7"
                and c:_get_collision_group_registry():name_for_id(7)=="Group7"
                and c._collision_group_source.names_and_ids_imported==false)
            Policy.finish(c,owner)
            rejected(function() Policy.prepare_map(map(SPARSE,{{collision_group_legacy_id=7}})) end)
            rejected(function() Policy.prepare_map(map("",{})) end)
        end)
        t.it("publishes numeric changes through the existing collision invalidation path", function()
            local c=core(imported(SPARSE));local p={CollisionGroup="alpha"}
            local invalidated={}
            Part.set_id(c,p,31,function(_,key) invalidated[key]=true end)
            assert(p.CollisionGroup=="omega" and Part.get_id(c,p)==31 and c.changes==1
                and invalidated.CollisionGroup and invalidated.CollisionGroupId)
            Part.set_id(c,p,31);assert(c.changes==1)
            rejected(function() Part.set_id(c,p,7) end);assert(p.CollisionGroup=="omega" and c.changes==1)
            Part.set_name(c,p,"unregistered")
            assert(Part.get_id(c,p)==-1 and c:_get_collision_group_registry().groups.unregistered==nil)
        end)
        t.it("updates passive aliases without physical notifications", function()
            local c=core(imported(SPARSE));local props={CollisionGroup="alpha",CollisionGroupId=5}
            Part.set_passive(c,props,"CollisionGroupId",31)
            assert(props.CollisionGroup=="omega" and props.CollisionGroupId==31 and c.changes==0)
            Part.set_passive(c,props,"CollisionGroup","unknown")
            assert(props.CollisionGroup=="unknown" and props.CollisionGroupId==-1 and c.changes==0)
        end)
        t.it("restores only its saved filter metadata and rejects a replacement Workspace", function()
            local c,ws=core();local old=c:_get_collision_group_registry()
            local token=Policy.prepare_map(map(SPARSE,{}))
            local owner=Policy.begin(c,token);Policy.commit(c,owner);Policy.rollback(c,owner)
            assert(c:_get_collision_group_registry()==old and ws._properties.CollisionGroupData=="old"
                and ws._properties.TouchesUseCollisionGroups==true and c._collision_group_load==nil)
            token=Policy.prepare_map(map(SPARSE,{}));owner=Policy.begin(c,token);Policy.commit(c,owner)
            local foreign={CollisionGroupData="foreign",TouchesUseCollisionGroups=true}
            ws._properties=foreign
            local ok=Policy.recovery_guard(c,owner)
            assert(ok==false and ws._properties==foreign and foreign.CollisionGroupData=="foreign"
                and c._collision_group_load==nil)
        end)
        -- Independent additional cases: UNRUN; insert inside the existing describe.
        t.it("reset discards old names, sparse IDs and public filters together",function()
            local g=imported(SPARSE)
            g:set_collidable("alpha","omega",false)
            assert(g.blocked_count==1 and g:collidable("alpha","omega")==false)
            g:reset()
            assert(g.public_count==1 and g:name_for_id(0)=="Default"
                and g:name_for_id(5)==nil and g:name_for_id(31)==nil
                and g:id_for_name("alpha")==nil and g.source_policy==nil
                and g.blocked_count==0 and g:collidable("alpha","omega")==true)
            g:register("fresh");assert(g:id_for_name("fresh")==1)
        end)
        t.it("old recovery cannot clear a newer load ledger or change its current matrix",function()
            local c,ws=core();local token=Policy.prepare_map(map(SPARSE,{}))
            local old_owner=Policy.begin(c,token);Policy.commit(c,old_owner)
            local committed=c:_get_collision_group_registry()
            local newer_owner={};c._collision_group_load=newer_owner
            local owned,reason=Policy.recovery_guard(c,old_owner)
            assert(owned==false and type(reason)=="string" and c._collision_group_load==newer_owner
                and c:_get_collision_group_registry()==committed
                and ws._properties.CollisionGroupData==SPARSE)
            rejected(function()Policy.finish(c,old_owner)end)
            assert(c._collision_group_load==newer_owner)
        end)
        t.it("replacement Workspace is not restored by a canceled owner and explicit Retry can acquire it",function()
            local c,old_ws=core();local token=Policy.prepare_map(map(SPARSE,{}))
            local owner=Policy.begin(c,token);Policy.commit(c,owner)
            local committed=c:_get_collision_group_registry()
            local props={CollisionGroupData="foreign",TouchesUseCollisionGroups=true}
            local replacement={_properties=props,_datamodel=c._datamodel}
            c._datamodel._services_by_name.Workspace=replacement
            rejected(function()Policy.rollback(c,owner)end)
            assert(c._collision_group_load==nil and c:_get_collision_group_registry()==committed
                and c._datamodel._services_by_name.Workspace==replacement
                and replacement._properties==props and props.CollisionGroupData=="foreign"
                and props.TouchesUseCollisionGroups==true
                and old_ws._properties.CollisionGroupData==SPARSE)
            token=Policy.prepare_map(map(SPARSE,{}));owner=Policy.begin(c,token)
            Policy.commit(c,owner);Policy.finish(c,owner)
            assert(c._collision_group_load==nil and replacement._properties==props
                and props.CollisionGroupData==SPARSE and props.TouchesUseCollisionGroups==false)
        end)
    end)
end
return suite
