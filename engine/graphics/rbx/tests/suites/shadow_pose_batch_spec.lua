local suite={needs_graphics=true}
local rbx=require('engine/graphics/rbx')
local pose_batches=require('engine/graphics/rbx/runtime/shadow_pose_batch')
local shadow_array=require('engine/graphics/rbx/runtime/shadow_array')

local function released(resource)
    return not pcall(resource.getVertexCount or resource.getWidth,resource)
end

local function cascades()
    local out={}
    for index=1,3 do
        out[index]={
            matrix={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1},
            atlas_matrix={1/3,0,0,0,0,1,0,0,0,0,1,0,
                (index-2)*2/3,0,0,1},
        }
    end
    return out
end

local function capture(core,commands)
    local canvas=love.graphics.newCanvas(192,64,{format='rgba8',readable=true,msaa=0})
    love.graphics.push('all')
    love.graphics.setCanvas({canvas,depth=true})
    love.graphics.clear(1,1,1,1,true,true)
    love.graphics.setDepthMode('less',true)
    love.graphics.setColor(1,1,1,1)
    love.graphics.setBlendMode('replace','alphamultiply')
    love.graphics.setMeshCullMode('none')
    love.graphics.origin()
    local draws=core:_draw_directional_shadow_commands(cascades(),commands)
    love.graphics.pop()
    local image=canvas:newImageData()
    canvas:release()
    return image,draws
end

local function pose(x,index)
    -- Include a nonuniform affine basis as well as translation. The production
    -- direct caster consumes the same three rows, so this catches a row/column
    -- mismatch that a translation-only witness would miss.
    local angle=(index or 0)*.19
    local c,s=math.cos(angle),math.sin(angle)
    return {rows={{c*1.15,-s*.78,0,x},{s*1.15,c*.78,0,(index or 0)*.015},
        {0,0,1,0}}}
end

local function source_mesh(texture)
    local format={{'VertexPosition','float',3},{'VertexNormal','float',3},
        {'VertexTexCoord','float',2},{'VertexColor','float',4},
        {'VertexReflectance','float',1},{'VertexTangent','float',3},
        {'VertexBitangent','float',3},{'VertexContactAO','float',1}}
    local function row(x,y,u,v,alpha)
        return {x,y,.1,0,0,1,u,v,1,1,1,alpha,0,1,0,0,0,1,0,1}
    end
    -- The production threshold intentionally avoids rebuilding a derived
    -- stream for tiny sources. Keep this witness above that threshold while
    -- repeating the same cutout triangles, so direct and packed coverage is
    -- still pixel-identical.
    local vertices={}
    for _=1,32 do
        vertices[#vertices+1]=row(-.22,-.22,0,0,1)
        vertices[#vertices+1]=row(.22,-.22,1,0,.8)
        vertices[#vertices+1]=row(.22,.22,1,1,1)
        vertices[#vertices+1]=row(-.22,-.22,0,0,1)
        vertices[#vertices+1]=row(.22,.22,1,1,1)
        vertices[#vertices+1]=row(-.22,.22,0,1,.7)
    end
    local mesh=love.graphics.newMesh(format,vertices,'triangles','static')
    mesh:setTexture(texture)
    return mesh
end

function suite.run(t)
    t.it('batches contiguous rigid cutout casters without changing cascade pixels',function()
        local world=assert(rbx.new{simulate_physics=false,allow_remote_assets=false,
            follow_display_settings=false})
        local core=world._core
        local owned,derived={},nil
        local ok,err=xpcall(function()
            if not core._directional_shadow_pose_batch_shader then return end
            local pixels=love.image.newImageData(8,8)
            for y=0,7 do for x=0,7 do
                pixels:setPixel(x,y,.8,.7,.6,((x+y)%3==0) and .4 or 1)
            end end
            local texture=love.graphics.newImage(pixels,{linear=false})
            pixels:release()
            texture:setFilter('nearest','nearest')
            owned[#owned+1]=texture
            local commands={}
            for index=1,4 do
                local mesh=source_mesh(texture)
                owned[#owned+1]=mesh
                local x=(index-2.5)*.42
                commands[index]={kind='textured',mesh=mesh,rigid_pose=pose(x,index),
                    alpha_test=true,alpha_threshold=.003,
                    bounds={min_x=x-.22,max_x=x+.22,min_y=-.22,max_y=.22,
                        min_z=.1,max_z=.1}}
            end
            local packed=pose_batches.compact(core,commands)
            assert(#packed==1 and packed[1].kind=='rigid_pose_batch',
                'compatible rigid casters did not batch: '..tostring(core._shadow_stats.pose_batch_error))
            derived=packed[1].mesh
            local old_tile=core._directional_shadow_tile_size
            core._directional_shadow_tile_size=64
            local direct,direct_draws=capture(core,commands)
            local combined,combined_draws=capture(core,packed)
            assert(direct:getString()==combined:getString(),'rigid pose batch changed shadow pixels')
            assert(direct_draws==12 and combined_draws==3,
                ('unexpected shadow draw reduction %d -> %d'):format(direct_draws,combined_draws))
            direct:release();combined:release()

            local prior=packed[1].mesh
            for index,command in ipairs(commands) do
                local x=(index-2.5)*.42+.08
                command.rigid_pose=pose(x,index)
                command.bounds.min_x,command.bounds.max_x=x-.22,x+.22
            end
            packed=pose_batches.compact(core,commands)
            assert(packed[1].mesh==prior,'pose-only update rebuilt immutable batch geometry')
            local moved_direct,moved_direct_draws=capture(core,commands)
            local moved_combined,moved_combined_draws=capture(core,packed)
            assert(moved_direct:getString()==moved_combined:getString(),
                'pose-only update changed shadow pixels')
            assert(moved_direct_draws==12 and moved_combined_draws==3,
                'pose-only update changed draw reduction')
            moved_direct:release();moved_combined:release()
            core._directional_shadow_tile_size=old_tile

            shadow_array.invalidate(commands[1].mesh)
            packed=pose_batches.compact(core,commands)
            assert(packed[1].mesh~=prior and released(prior),
                'source vertex invalidation reused stale shadow batch geometry')
            derived=packed[1].mesh

            local before,after={kind='static'},{kind='static'}
            local ordered={before,commands[1],commands[2],commands[3],commands[4],after}
            local ordered_packed=pose_batches.compact(core,ordered)
            assert(#ordered_packed==3 and ordered_packed[1]==before
                and ordered_packed[3]==after,
                'contiguous pose aggregation changed source command order')
            commands[2].unstable_shadow_index_map=true
            assert(pose_batches.compact(core,commands)==commands,
                'unsupported dynamic source did not keep individual commands')
            assert(released(derived),'retired pose-batch mesh survived fallback')
            derived=nil
        end,debug.traceback)
        pose_batches.release(core)
        for _,resource in ipairs(owned) do pcall(resource.release,resource) end
        world:Destroy()
        assert(ok,err)
    end)
end

return suite
