local suite = {}
local reuse_selected = type(jit)=="table" and type(jit.status)=="function" and jit.status()==false
local h = require("engine/graphics/rbx/tests/harness")
h.runtime_require("common.lua"); h.runtime_require("scene.lua"); h.runtime_require("assets.lua")
local ffi = require("ffi")
local capture, apply = h.env.rbx_snapshot_item_vertices, h.env.rbx_fast_bake_apply
local static = {6,7,8,9,10,11,12,19}
local changing = {0,1,2,3,4,5,13,14,15,16,17,18}
local poses = {
    {1,0,0, 0,1,0, 0,0,1, 0,0,0},
    {0,-1,0, 1,0,0, 0,0,1, 10,20,30},
    {.31,-.78,.21, .61,.29,-.41, -.22,.32,.91, -4.125,6.75,-8.25},
    {-1,0,0, 0,1,0, 0,0,-1, -.25,.125,.75},
}

-- Frozen pre-optimization scalar stores, independent of the snapshot builder
-- and candidate apply function. A fresh destination supplies every reference.
local function reference(src, count, m00,m01,m02,m10,m11,m12,m20,m21,m22,tx,ty,tz)
    local dst = ffi.new("float[?]",count*20)
    local offset = 0
    for _ = 1,count do
        local x,y,z = src[offset],src[offset+1],src[offset+2]
        dst[offset] = m00*x+m01*y+m02*z+tx
        dst[offset+1] = m10*x+m11*y+m12*z+ty
        dst[offset+2] = m20*x+m21*y+m22*z+tz
        local nx,ny,nz = src[offset+3],src[offset+4],src[offset+5]
        dst[offset+3] = m00*nx+m01*ny+m02*nz
        dst[offset+4] = m10*nx+m11*ny+m12*nz
        dst[offset+5] = m20*nx+m21*ny+m22*nz
        dst[offset+6] = src[offset+6]
        dst[offset+7] = src[offset+7]
        dst[offset+8] = src[offset+8]
        dst[offset+9] = src[offset+9]
        dst[offset+10] = src[offset+10]
        dst[offset+11] = src[offset+11]
        dst[offset+12] = src[offset+12]
        local tx1,ty1,tz1 = src[offset+13],src[offset+14],src[offset+15]
        dst[offset+13] = m00*tx1+m01*ty1+m02*tz1
        dst[offset+14] = m10*tx1+m11*ty1+m12*tz1
        dst[offset+15] = m20*tx1+m21*ty1+m22*tz1
        local bx1,by1,bz1 = src[offset+16],src[offset+17],src[offset+18]
        dst[offset+16] = m00*bx1+m01*by1+m02*bz1
        dst[offset+17] = m10*bx1+m11*by1+m12*bz1
        dst[offset+18] = m20*bx1+m21*by1+m22*bz1
        dst[offset+19] = src[offset+19]
        offset = offset+20
    end
    return ffi.string(dst,count*80)
end

local function rows(count, shift)
    local result = {}
    for vertex=1,count do
        local row = {}
        for lane=1,20 do row[lane] = (shift or 0)+vertex*.125+lane*.03125 end
        result[vertex] = row
    end
    return result
end
local function pack(source)
    local flat=ffi.new("float[?]",#source*20)
    for vertex,row in ipairs(source) do
        for lane=1,20 do flat[(vertex-1)*20+lane-1]=row[lane] or 0 end
    end
    return flat
end
local function with_snapshots(fn)
    local owned={}
    local function snapshot(vertices)
        local result=assert(capture({cpu_vertices=vertices}),"snapshot creation failed")
        owned[#owned+1]=result.dst_data
        return result
    end
    local ok,err=xpcall(function()fn(snapshot)end,debug.traceback)
    for _,data in ipairs(owned) do pcall(data.release,data) end
    assert(ok,err)
end
local function check(snapshot,pose,label)
    local expected=reference(snapshot.src,snapshot.count,unpack(pose))
    apply(snapshot,unpack(pose))
    local actual=snapshot.dst_data:getString()
    if actual~=expected then
        local first=1
        while actual:byte(first)==expected:byte(first) do first=first+1 end
        local lane=math.floor((first-1)/4)
        error((label or "pose")..": float lane="..lane.." expected="
            ..love.data.encode("string","hex",expected:sub(lane*4+1,lane*4+4)).." actual="
            ..love.data.encode("string","hex",actual:sub(lane*4+1,lane*4+4)),0)
    end
end

local function repeated_rows(seeds, count)
    local result = {}
    for vertex=1,count do
        local seed=seeds[(vertex-1)%#seeds+1]
        local row={}
        for lane=1,20 do row[lane]=seed[lane] end
        result[vertex]=row
    end
    return result
end
local function assert_no_reuse(state)
    assert(state.unique_offsets==nil and state.duplicate_offsets==nil
        and state.duplicate_pointers==nil
        and state.rotation_offsets==nil and state.rotation_count==nil
        and state.rotation_pointers==nil and state.rotation_duplicate_count==nil
        and state.unique_count==nil and state.duplicate_count==nil,
        "ineligible snapshot retained a duplicate-row map")
end
local function assert_selected_counts(state, unique_count, duplicate_count)
    if reuse_selected then
        assert(state.unique_count==unique_count and state.duplicate_count==duplicate_count,
            "interpreter snapshot did not select expected row reuse")
    else
        assert_no_reuse(state)
    end
end
local function assert_offsets(state, canonical, source_rows)
    assert_selected_counts(state,#canonical,state.count-#canonical)
    if not reuse_selected then return end
    assert(state.unique_count==#canonical and state.duplicate_count==state.count-#canonical,
        "unexpected number of canonical or duplicate rows")
    assert(type(state.unique_offsets)=="cdata" and type(state.duplicate_offsets)=="cdata",
        "offsets are not compact owned arrays")
    assert(ffi.sizeof(state.unique_offsets)==#canonical*4
        and ffi.sizeof(state.duplicate_offsets)==state.duplicate_count*8,"offset allocation exceeds payload")
    local first={}
    for index,offset in ipairs(canonical) do
        assert(state.unique_offsets[index-1]==offset,"canonical order changed")
        first[offset]=true
    end
    local duplicate=0
    for row=0,state.count-1 do
        local offset=row*20
        if not first[offset] then
            local expected=source_rows[row+1]*20
            assert(state.duplicate_offsets[duplicate*2]==offset,"duplicate destination changed")
            assert(state.duplicate_offsets[duplicate*2+1]==expected,"duplicate is not first occurrence")
            assert(first[expected] and expected<offset,"invalid or chained duplicate source")
            assert(ffi.string(state.src+offset,80)==ffi.string(state.src+expected,80),
                "map merged distinct source bytes")
            duplicate=duplicate+1
        end
    end
    assert(duplicate==state.duplicate_count)
end

local function shared_triplet_rows(shift)
    local seeds=rows(32,shift)
    for _,row in ipairs(seeds) do
        row[4],row[5],row[6]=1,-2,3
        row[14],row[15],row[16]=-4,5,-6
        row[17],row[18],row[19]=1,-2,3
    end
    return repeated_rows(seeds,96)
end
local function assert_no_rotation(state)
    assert(state.rotation_offsets==nil and state.rotation_count==nil
        and state.rotation_pointers==nil and state.rotation_duplicate_count==nil,
        "ineligible snapshot retained rotation metadata")
end
local function assert_rotation(state, representatives, copies)
    if not reuse_selected then assert_no_reuse(state);return end
    assert(state.rotation_count==#representatives and state.rotation_duplicate_count==copies,
        "rotation triplet counts differ from independent fixture expectations")
    assert(type(state.rotation_offsets)=="cdata" and ffi.sizeof(state.rotation_offsets)==4*#representatives,
        "rotation representatives are not bounded owned offsets")
    assert(type(state.rotation_pointers)=="table" and #state.rotation_pointers==copies*2,
        "rotation copies are not bounded owned pointer pairs")
    for i,offset in ipairs(representatives) do
        assert(state.rotation_offsets[i-1]==offset,"rotation representative is not first occurrence")
    end
end

function suite.run(t)
    t.it("matches every 80-byte row against fresh original stores over consecutive poses",function()
        with_snapshots(function(snapshot)
            local source=rows(7)
            for lane=1,20 do source[1][lane]=lane end
            local state=snapshot(source)
            local source_bytes=ffi.string(state.src,state.count*80)
            for cycle=1,5 do
                for index,pose in ipairs(poses) do check(state,pose,cycle.."/"..index) end
            end
            apply(state,unpack(poses[2]))
            local expected={8,21,33, -5,4,6, 7,8,9,10,11,12,13, -15,14,16, -18,17,19,20}
            for lane=1,20 do assert(state.dst[lane-1]==expected[lane],"literal lane "..lane) end
            assert(ffi.string(state.src,state.count*80)==source_bytes,"pose mutated owned source")
        end)
    end)
    t.it("initializes poisoned allocation bytes and never feeds previous transformed lanes back",function()
        with_snapshots(function(snapshot)
            local original=love.data.newByteData
            love.data.newByteData=function(size)
                local data=original(size)
                ffi.fill(data:getFFIPointer(),data:getSize(),0xCD)
                return data
            end
            local ok,state=xpcall(function()return snapshot(rows(3))end,debug.traceback)
            love.data.newByteData=original
            assert(ok,state)
            assert(state.dst_data:getString()==ffi.string(state.src,state.count*80),
                "snapshot left allocation contents in initialized attributes")
            for cycle=1,8 do
                for vertex=0,state.count-1 do
                    for _,lane in ipairs(changing) do state.dst[vertex*20+lane]=0/0 end
                end
                check(state,poses[cycle%#poses+1],"poisoned previous pose")
            end
        end)
    end)
    t.it("owns table and flat sources after their original payloads change",function()
        with_snapshots(function(snapshot)
            local source=rows(4)
            local flat=pack(source)
            local table_state=snapshot(source)
            local flat_state=snapshot({vbuf=flat,vbuf_n=80})
            local expected=ffi.string(flat,320)
            assert(ffi.cast("void*",flat_state.src)~=ffi.cast("void*",flat),"flat source was aliased")
            source[1][1],source[1][7]=10000,-1234
            source[2]=rows(1,900)[1]
            source[5]=rows(1,800)[1]
            ffi.fill(flat,320,0xA5)
            assert(ffi.string(table_state.src,320)==expected and ffi.string(flat_state.src,320)==expected,
                "caller mutation replaced captured source bytes")
            for _,pose in ipairs(poses) do
                check(table_state,pose,"table ownership")
                check(flat_state,pose,"flat ownership")
                assert(table_state.dst_data:getString()==flat_state.dst_data:getString())
            end
        end)
    end)
    t.it("retains original static-lane signed zeros, infinities and quiet NaN payloads",function()
        with_snapshots(function(snapshot)
            local flat=pack(rows(2))
            local bits=ffi.cast("uint32_t*",flat)
            local patterns={0x80000000,0,0x7F800000,0xFF800000,0x7FC12345,0xFFC54321,0x00000001,0x7FC00000}
            for vertex=0,1 do
                for index,lane in ipairs(static) do bits[vertex*20+lane]=patterns[index] end
            end
            local state=snapshot({vbuf=flat,vbuf_n=40})
            local original=ffi.string(state.src,160)
            for cycle=1,12 do check(state,poses[cycle%#poses+1],"static special values") end
            assert(ffi.string(state.src,160)==original,"scalar initialization changed source payload")
            local output=ffi.cast("uint32_t*",state.dst)
            assert(output[6]==0x80000000 and output[7]==0,"signed-zero static fields changed")
            assert(output[8]==0x7F800000 and output[9]==0xFF800000,"infinity static fields changed")
        end)
    end)
    t.it("recreates independent initialized buffers when a source or vertex count is replaced",function()
        with_snapshots(function(snapshot)
            local old=snapshot(rows(2))
            check(old,poses[3],"old source")
            local retained=old.dst_data:getString()
            local replacement=snapshot(rows(5,30))
            assert(old.count==2 and replacement.count==5)
            assert(ffi.cast("void*",old.dst)~=ffi.cast("void*",replacement.dst),"replacement reused live output storage")
            for _,pose in ipairs(poses) do check(replacement,pose,"replacement") end
            assert(old.dst_data:getString()==retained,"replacement overwrote retained output")
            old.dst_data:release()
            local recreated=snapshot(rows(2,-30))
            for _,pose in ipairs(poses) do
                check(recreated,pose,"recreated")
                check(replacement,pose,"surviving replacement")
            end
        end)
    end)
    t.it("selects the startup execution path and preserves interleaved-row output and ownership",function()
        with_snapshots(function(snapshot)
            local seeds=rows(3)
            local order={seeds[1],seeds[2],seeds[1],seeds[3],seeds[2],seeds[3]}
            local source=repeated_rows(order,96)
            local flat=pack(source)
            local expected=ffi.string(flat,96*80)
            local table_state=snapshot(source)
            local flat_state=snapshot({vbuf=flat,vbuf_n=96*20})
            local first={0,1,0,3,1,3}
            local source_rows={}
            for row=1,96 do source_rows[row]=first[(row-1)%#first+1] end
            for _,state in ipairs({table_state,flat_state}) do assert_offsets(state,{0,20,60},source_rows) end
            source[1][1],source[2][7]=123456,-654321
            ffi.fill(flat,96*80,0xA5)
            collectgarbage("collect")
            for _,state in ipairs({table_state,flat_state}) do
                assert(ffi.string(state.src,96*80)==expected,"captured source is not independently owned")
                for cycle=1,12 do
                    for row=0,95 do
                        for _,lane in ipairs(changing) do state.dst[row*20+lane]=0/0 end
                    end
                    check(state,poses[(cycle-1)%#poses+1],"interleaved duplicate pose "..cycle)
                end
                assert(ffi.string(state.src,96*80)==expected,"reuse mutated immutable source")
            end
            assert(table_state.dst_data:getString()==flat_state.dst_data:getString(),"table/flat reuse differ")
        end)
    end)
    t.it("keeps every attribute seam and signed-zero row distinct",function()
        with_snapshots(function(snapshot)
            local seed=rows(1)[1]
            local source=repeated_rows({seed},92)
            for lane=1,20 do source[lane+1][lane]=source[lane+1][lane]+1 end
            source[22][7],source[23][7]=0,0
            for row=24,92 do
                local original=source[(row-1)%23+1]
                for lane=1,20 do source[row][lane]=original[lane] end
            end
            local flat=pack(source)
            local bits=ffi.cast("uint32_t*",flat)
            for row=22,91,23 do bits[row*20+6]=0x80000000 end
            local state=snapshot({vbuf=flat,vbuf_n=92*20})
            local canonical,source_rows={},{}
            for row=0,22 do canonical[row+1]=row*20 end
            for row=0,91 do source_rows[row+1]=row%23 end
            assert_offsets(state,canonical,source_rows)
            assert(ffi.cast("uint32_t*",state.src)[21*20+6]==0
                and ffi.cast("uint32_t*",state.src)[22*20+6]==0x80000000,"zero fixture lost its sign")
            for cycle=1,8 do check(state,poses[(cycle-1)%#poses+1],"attribute seam pose") end
        end)
    end)
    t.it("omits reuse maps for unique rows and bounded-out snapshot sizes",function()
        with_snapshots(function(snapshot)
            local unique=snapshot(rows(64))
            assert_no_reuse(unique)
            for _,pose in ipairs(poses) do check(unique,pose,"unique rows") end
            local sparse_rows=rows(64)
            for lane=1,20 do sparse_rows[64][lane]=sparse_rows[1][lane] end
            local sparse=snapshot(sparse_rows)
            assert_no_reuse(sparse)
            for _,pose in ipairs(poses) do check(sparse,pose,"sparse duplicates") end
            for _,count in ipairs({1,63,65537}) do
                local flat=ffi.new("float[?]",count*20)
                local first=pack(rows(1))
                for row=0,count-1 do ffi.copy(flat+row*20,first,80) end
                local state=snapshot({vbuf=flat,vbuf_n=count*20})
                assert_no_reuse(state)
                check(state,poses[2],"outside reuse bound "..count)
            end
        end)
    end)
    t.it("uses scalar source fallback for nonfinite values in any vertex lane",function()
        with_snapshots(function(snapshot)
            local patterns={0x7FC12345,0x7F800000,0xFF800000}
            for lane=0,19 do
                local flat=pack(repeated_rows(rows(1),64))
                ffi.cast("uint32_t*",flat)[63*20+lane]=patterns[lane%#patterns+1]
                local state=snapshot({vbuf=flat,vbuf_n=64*20})
                assert_no_reuse(state)
                check(state,poses[2],"nonfinite source lane "..lane)
                check(state,poses[3],"nonfinite source second pose "..lane)
            end
        end)
    end)
    t.it("preserves scalar behavior for nonfinite and nonnumeric transform inputs",function()
        with_snapshots(function(snapshot)
            local state=snapshot(repeated_rows(rows(2),64))
            assert_selected_counts(state,2,62)
            for index=1,12 do
                local pose={unpack(poses[3])}
                pose[index]=index%2==0 and math.huge or -math.huge
                check(state,pose,"infinite transform component "..index)
                pose[index]=0/0
                check(state,pose,"NaN transform component "..index)
                check(state,poses[2],"finite transform after fallback")
                pose[index]=tostring(poses[3][index])
                check(state,pose,"numeric string transform component "..index)
            end
            local bad={unpack(poses[2])}
            bad[1]="not a number"
            local reference_ok=pcall(reference,state.src,state.count,unpack(bad))
            local candidate_ok=pcall(apply,state,unpack(bad))
            assert(not reference_ok and not candidate_ok,"invalid transform no longer raises")
            check(state,poses[4],"finite transform after invalid input")
        end)
    end)
    t.it("owns selected-path buffers and optional maps across attribute changes and replacement",function()
        with_snapshots(function(snapshot)
            local old=snapshot(repeated_rows(rows(2),64))
            check(old,poses[3],"old repeated source")
            local retained=old.dst_data:getString()
            local source=repeated_rows(rows(2,30),96)
            source[95][7],source[96][13]=-.125,123
            local replacement=snapshot(source)
            assert_selected_counts(old,2,62)
            assert_selected_counts(replacement,4,92)
            if reuse_selected then
                assert(ffi.cast("void*",old.unique_offsets)~=ffi.cast("void*",replacement.unique_offsets),
                    "replacement aliases old offsets")
                assert(type(old.duplicate_pointers)=="table" and type(replacement.duplicate_pointers)=="table"
                    and old.duplicate_pointers~=replacement.duplicate_pointers,"replacement aliases pointer storage")
                assert(old.duplicate_pointers[1]~=replacement.duplicate_pointers[1],
                    "replacement pointer still targets live old storage")
            end
            assert(ffi.cast("void*",old.dst)~=ffi.cast("void*",replacement.dst),"replacement aliases old storage")
            for _,pose in ipairs(poses) do check(replacement,pose,"replacement repeated source") end
            assert(old.dst_data:getString()==retained,"replacement changed live old output")
            local retired=setmetatable({old,old.duplicate_pointers},{__mode="v"})
            old.dst_data:release()
            old=nil
            collectgarbage("collect")
            assert(retired[1]==nil and retired[2]==nil,"retired snapshot or scatter pointers were retained")
            local recreated=snapshot(repeated_rows(rows(1,-30),65))
            assert_selected_counts(recreated,1,64)
            for _,pose in ipairs(poses) do
                check(recreated,pose,"recreated duplicate source")
                check(replacement,pose,"surviving replacement source")
            end
        end)
    end)
    t.it("avoids offset allocation in JIT mode or survives either allocation failure in interpreter mode",function()
        with_snapshots(function(snapshot)
            for fail_at=1,2 do
                local original_new=ffi.new
                local allocation_count=0
                ffi.new=function(ctype,...)
                    if ctype=="uint32_t[?]" then
                        allocation_count=allocation_count+1
                        if allocation_count==fail_at then error("injected offset allocation failure") end
                    end
                    return original_new(ctype,...)
                end
                local ok,state=xpcall(function()
                    return snapshot(repeated_rows(rows(2),64))
                end,debug.traceback)
                ffi.new=original_new
                assert(ok,state)
                assert(allocation_count==(reuse_selected and fail_at or 0),
                    "optional allocation attempts do not match selected execution path")
                assert(state.count==64 and state.src~=nil and state.dst_data:getSize()==64*80,
                    "optional allocation discarded required storage")
                assert_no_reuse(state)
                for _,pose in ipairs(poses) do check(state,pose,"offset allocation fallback "..fail_at) end
            end
        end)
    end)
    t.it("retains actual scatter argument objects and current owner addresses through poses and GC",function()
        with_snapshots(function(snapshot)
            local source=repeated_rows(rows(3),96)
            local state=snapshot(source)
            local owner=setmetatable({state.dst_data},{__mode="v"})
            source=nil
            local arguments={}
            local original_copy=ffi.copy
            local scatter_count,cycle=0,0
            ffi.copy=function(destination,origin,size)
                scatter_count=scatter_count+1
                assert(reuse_selected,"JIT path unexpectedly scattered rows")
                assert(size==80 and scatter_count<=state.duplicate_count,"scatter changed payload bounds")
                local index=(scatter_count-1)*2
                assert(destination==state.dst+state.duplicate_offsets[index],"scatter destination escaped current owner")
                assert(origin==state.dst+state.duplicate_offsets[index+1],"scatter source is not current canonical output")
                if cycle==1 then
                    arguments[index+1],arguments[index+2]=destination,origin
                else
                    assert(rawequal(arguments[index+1],destination) and rawequal(arguments[index+2],origin),
                        "scatter recomputed pointer objects between poses")
                end
                return original_copy(destination,origin,size)
            end
            local ok,err=xpcall(function()
                for pose_index=1,12 do
                    cycle,scatter_count=pose_index,0
                    collectgarbage("collect")
                    assert(owner[1]==state.dst_data,"snapshot lost destination owner")
                    check(state,poses[(pose_index-1)%#poses+1],"scatter pointer pose "..pose_index)
                    assert(scatter_count==(reuse_selected and state.duplicate_count or 0),"scatter count changed")
                end
            end,debug.traceback)
            ffi.copy=original_copy
            assert(ok,err)
            if reuse_selected then
                assert(type(state.duplicate_pointers)=="table" and #state.duplicate_pointers==#arguments,
                    "snapshot does not own every scatter pointer")
                for index,pointer in ipairs(arguments) do
                    assert(rawequal(state.duplicate_pointers[index],pointer),"scatter pointer is not snapshot-owned")
                end
            else
                assert_no_reuse(state)
                assert(#arguments==0,"JIT path retained scatter arguments")
            end
        end)
    end)
    t.it("shares exact cross-role triplets before full-row copies through twelve poses and GC",function()
        with_snapshots(function(snapshot)
            local state=snapshot(shared_triplet_rows())
            assert_selected_counts(state,32,64)
            assert_rotation(state,{3,13},94)
            local expected={{16,3}}
            for row=1,31 do
                expected[#expected+1]={row*20+3,3}
                expected[#expected+1]={row*20+13,13}
                expected[#expected+1]={row*20+16,3}
            end
            assert(#expected==94)
            local prior,cycle,rotations,full_rows={},0,0,0
            local original_copy=ffi.copy
            ffi.copy=function(destination,origin,size)
                assert(reuse_selected,"JIT path unexpectedly copied triplets or rows")
                if size==12 then
                    rotations=rotations+1
                    assert(full_rows==0 and rotations<=94,"triplet copies must finish before row copies")
                    local pair=expected[rotations]
                    assert(destination==state.dst+pair[1] and origin==state.dst+pair[2],
                        "triplet copy changed destination or first representative")
                    local index=(rotations-1)*2+1
                    assert(rawequal(destination,state.rotation_pointers[index])
                        and rawequal(origin,state.rotation_pointers[index+1]),"triplet pointer escaped snapshot ownership")
                    if cycle==1 then prior[index],prior[index+1]=destination,origin
                    else assert(rawequal(prior[index],destination) and rawequal(prior[index+1],origin),
                        "triplet pointer objects changed between poses") end
                else
                    assert(size==80 and rotations==94 and full_rows<64,"full-row copy preceded complete rotations")
                    local row=32+full_rows
                    assert(destination==state.dst+row*20 and origin==state.dst+(row%32)*20,
                        "full-row copies changed original row order")
                    full_rows=full_rows+1
                end
                return original_copy(destination,origin,size)
            end
            local ok,err=xpcall(function()
                for pose_index=1,12 do
                    cycle,rotations,full_rows=pose_index,0,0
                    for row=0,95 do for _,lane in ipairs(changing) do state.dst[row*20+lane]=0/0 end end
                    collectgarbage("collect")
                    check(state,poses[(pose_index-1)%#poses+1],"cross-role rotation pose "..pose_index)
                    assert(rotations==(reuse_selected and 94 or 0) and full_rows==(reuse_selected and 64 or 0),
                        "selected path changed copy counts")
                end
            end,debug.traceback)
            ffi.copy=original_copy
            assert(ok,err)
        end)
    end)
    t.it("keeps three numerically equal signed-zero triplets distinct",function()
        with_snapshots(function(snapshot)
            local source=shared_triplet_rows()
            for _,row in ipairs(source) do
                for _,lane in ipairs({4,14,17}) do row[lane],row[lane+1],row[lane+2]=0,0,1 end
            end
            local flat=pack(source);local bits=ffi.cast("uint32_t*",flat)
            for row=0,95 do bits[row*20+13]=0x80000000;bits[row*20+17]=0x80000000 end
            local state=snapshot({vbuf=flat,vbuf_n=96*20})
            assert_selected_counts(state,32,64);assert_rotation(state,{3,13,16},93)
            assert(state.src[3]==state.src[13] and state.src[4]==state.src[17],"zero fixture is not numerically equal")
            assert(ffi.string(state.src+3,12)~=ffi.string(state.src+13,12)
                and ffi.string(state.src+13,12)~=ffi.string(state.src+16,12),"zero fixture lost distinct bytes")
            for index=1,12 do check(state,poses[(index-1)%#poses+1],"signed-zero rotation pose") end
        end)
    end)
    t.it("keeps full-row reuse without sparse rotation reuse",function()
        with_snapshots(function(snapshot)
            local seeds=rows(32)
            for row,vertex in ipairs(seeds) do
                for role,lane in ipairs({4,14,17}) do
                    vertex[lane],vertex[lane+1],vertex[lane+2]=row*100+role*10+1,row*100+role*10+2,row*100+role*10+3
                end
            end
            for lane=4,6 do seeds[32][lane]=seeds[1][lane] end -- One copy out of 96 vectors.
            local state=snapshot(repeated_rows(seeds,96))
            assert_selected_counts(state,32,64);assert_no_rotation(state)
            for index=1,12 do check(state,poses[(index-1)%#poses+1],"sparse rotation pose") end
        end)
    end)
    t.it("uses contiguous fallback for exceptional transforms on rotation-eligible snapshots",function()
        with_snapshots(function(snapshot)
            local state=snapshot(shared_triplet_rows())
            assert_selected_counts(state,32,64);assert_rotation(state,{3,13},94)
            local original_copy=ffi.copy;local calls=0
            ffi.copy=function(...)calls=calls+1;return original_copy(...)end
            local ok,err=xpcall(function()
                for index=1,12 do
                    for _,value in ipairs({math.huge,-math.huge,0/0,tostring(poses[3][index])}) do
                        local pose={unpack(poses[3])};pose[index]=value;calls=0
                        check(state,pose,"rotation fallback component "..index)
                        assert(calls==0,"exceptional transform used cached rotation copies")
                    end
                end
                local invalid={unpack(poses[3])};invalid[5]="invalid"
                local baseline_ok=pcall(reference,state.src,state.count,unpack(invalid))
                local actual_ok=pcall(apply,state,unpack(invalid))
                assert(not baseline_ok and not actual_ok,"invalid transform stopped raising")
            end,debug.traceback)
            ffi.copy=original_copy;assert(ok,err)
            for _,pose in ipairs(poses) do check(state,pose,"rotation after exceptional transform") end
        end)
    end)
    t.it("discards all optional metadata when the third offset allocation fails",function()
        with_snapshots(function(snapshot)
            local original_new=ffi.new;local attempts=0
            ffi.new=function(ctype,...)
                if ctype=="uint32_t[?]" then
                    attempts=attempts+1
                    if attempts==3 then error("injected rotation offset allocation failure") end
                end
                return original_new(ctype,...)
            end
            local ok,state=xpcall(function()return snapshot(shared_triplet_rows())end,debug.traceback)
            ffi.new=original_new;assert(ok,state)
            assert(attempts==(reuse_selected and 3 or 0),"third optional allocation was not selected correctly")
            assert(state.count==96 and state.dst_data:getSize()==96*80,"optional failure discarded required payload")
            assert_no_reuse(state)
            for _,pose in ipairs(poses) do check(state,pose,"rotation allocation fallback") end
        end)
    end)
    t.it("rebuilds independently owned rotation pointers after source mutation and recreation",function()
        with_snapshots(function(snapshot)
            local source=shared_triplet_rows()
            local flat=pack(source);local old=snapshot({vbuf=flat,vbuf_n=96*20})
            assert_rotation(old,{3,13},94);check(old,poses[2],"old rotation owner")
            local retained=old.dst_data:getString()
            local source_bytes=ffi.string(old.src,96*80)
            ffi.fill(flat,96*80,0xA5);source=nil;flat=nil;collectgarbage("collect")
            assert(ffi.string(old.src,96*80)==source_bytes,"rotation cache aliased caller payload")
            local changed=shared_triplet_rows(50)
            for _,row in ipairs(changed) do row[4]=42 end
            local replacement=snapshot(changed)
            assert_selected_counts(replacement,32,64);assert_rotation(replacement,{3,13,16},93)
            if reuse_selected then
                assert(old.rotation_pointers~=replacement.rotation_pointers
                    and old.rotation_pointers[1]~=replacement.rotation_pointers[1],"rotation replacement aliases old destination")
            end
            for _,pose in ipairs(poses) do check(replacement,pose,"replacement rotation owner") end
            assert(old.dst_data:getString()==retained,"replacement changed old rotation output")
            local retired=setmetatable({old,old.rotation_pointers},{__mode="v"})
            old.dst_data:release();old=nil;collectgarbage("collect")
            assert(retired[1]==nil and retired[2]==nil,"rotation pointers retained a retired snapshot")
            local recreated=snapshot(shared_triplet_rows(-10));assert_rotation(recreated,{3,13},94)
            for _,pose in ipairs(poses) do
                check(recreated,pose,"recreated rotation owner")
                check(replacement,pose,"surviving rotation owner")
            end
        end)
    end)
end
return suite
