-- Background SurfaceGui work must be opt-in. Visible canvases still render on
-- first use through the normal per-frame visibility queue.

local suite = {}

suite.needs_graphics = true

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
    "geometry.lua",
    "assets.lua",
    "render.lua",
    "surface.lua",
    "lifecycle.lua",
}

function suite.run(t, harness)
    local expect = t.expect
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local runtime = harness.env.RBX

    t.describe("SurfaceGui background preload", function()
        t.it("does no settled background work by default and renders first-visible content", function()
            local game, create_error = runtime.new({
                render_backend = "menori",
                enable_skybox = false,
                allow_remote_asset_fetch = false,
                physics_enabled = false,
                shader_quality = "fast",
                msaa = 0,
            })
            assert(game, create_error)
            local core = game._core
            expect(core.surface_gui_background_preload_budget_per_update):to_be(0)

            local surface_gui = {
                runtime_id = "surface-gui-preload-test",
                enabled = true,
            }
            local part = { Size = { x = 4, y = 4, z = 1 } }
            local ensure_count = 0
            local canvas = {}
            core._surface_gui_entries = {
                { surface_gui = surface_gui, part = part },
            }
            core._ensure_surface_gui_runtime_texture = function(_, gui)
                ensure_count = ensure_count + 1
                gui._runtime_state = {
                    rendered = true,
                    canvas = canvas,
                    last_bound_texture = canvas,
                }
                return canvas, "surface-gui-preload-test", true
            end
            core._set_surface_gui_batch_texture = function(_, batch, texture)
                batch._test_bound_texture = texture
            end

            expect(core:_preload_surface_gui_canvases()):to_be(0)
            expect(ensure_count):to_be(0)
            expect(core._surface_gui_stats.preloaded_batch_count):to_be(0)

            local visible_batch = {
                key = "surface-gui-preload-test",
                surface_gui_runtime_id = surface_gui.runtime_id,
                surface_gui_ref = surface_gui,
                surface_gui_part_ref = part,
            }
            core._surface_gui_frame_id = 1
            core:_update_surface_gui_canvases({ visible_batch })
            expect(ensure_count):to_be(1)
            expect(surface_gui._runtime_state.rendered):to_be(true)
            expect(visible_batch._test_bound_texture):to_be(canvas)
            expect(core._surface_gui_stats.updated_batch_count):to_be(1)

            game:Destroy()
        end)
        t.it("publishes every first-visible canvas even while the camera moves", function()
            for _,motion in ipairs({"moving", "settling", "steady"}) do
                local game, err = runtime.new({render_backend="menori", enable_skybox=false,
                    allow_remote_asset_fetch=false, physics_enabled=false, shader_quality="fast", msaa=0})
                assert(game, err)
                local core=game._core
                core._camera_motion_state=motion
                local batches, ensured={},0
                core._ensure_surface_gui_runtime_texture=function(_,gui)
                    ensured=ensured+1
                    local canvas={}
                    gui._runtime_state={rendered=true,canvas=canvas,last_bound_texture=canvas}
                    return canvas,gui.runtime_id,true
                end
                core._set_surface_gui_batch_texture=function(_,batch,texture)batch.bound=texture end
                for i=1,13 do
                    local gui={runtime_id="first-visible-"..i,enabled=true}
                    batches[i]={surface_gui_ref=gui,surface_gui_part_ref={Size={x=4,y=4,z=1}},
                        surface_gui_runtime_id=gui.runtime_id}
                end
                batches[14]=batches[1] -- a repeated draw packet is not a second producer
                core:_update_surface_gui_canvases(batches)
                expect(ensured):to_be(13)
                expect(core._surface_gui_stats.deferred_batch_count):to_be(0)
                for _,batch in ipairs(batches)do
                    expect(batch.surface_gui_ref._runtime_state.rendered):to_be(true)
                    expect(batch.bound):to_be(batch.surface_gui_ref._runtime_state.canvas)
                end
                core:_update_surface_gui_canvases(batches)
                expect(ensured):to_be(13) -- unchanged visible content reuses the canvas
                game:Destroy()
            end
        end)
        t.it("publishes a visible content change while the camera moves", function()
            local game,err=runtime.new({render_backend="menori",enable_skybox=false,
                allow_remote_asset_fetch=false,physics_enabled=false,shader_quality="fast",msaa=0})
            assert(game,err)
            local core=game._core;core._camera_motion_state="moving"
            local old,new={},{}
            local gui={runtime_id="changed-visible",enabled=true,_content_dirty=true,
                _runtime_state={rendered=true,canvas=old,last_bound_texture=old}}
            local batch={surface_gui_ref=gui,surface_gui_part_ref={Size={x=4,y=4,z=1}},
                surface_gui_runtime_id=gui.runtime_id}
            local ensured=0
            core._ensure_surface_gui_runtime_texture=function(_,g)
                ensured=ensured+1;g._content_dirty=false
                g._runtime_state={rendered=true,canvas=new,last_bound_texture=new}
                return new,g.runtime_id,true
            end
            core._set_surface_gui_batch_texture=function(_,b,texture)b.bound=texture end
            core:_update_surface_gui_canvases({batch})
            expect(ensured):to_be(1)
            expect(batch.bound):to_be(new)
            expect(core._surface_gui_stats.deferred_batch_count):to_be(0)
            game:Destroy()
        end)
    end)
end

return suite
