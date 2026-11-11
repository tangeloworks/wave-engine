-- Headless generic normalization and face-space regressions. Pixel rendering
-- and native graphics-state checks are a separate graphics fixture.
local suite={needs_graphics=false}
function suite.run(t,h)
    h.runtime_require('common.lua');h.runtime_require('gui.lua');h.runtime_require('parser.lua');h.runtime_require('scene.lua');h.runtime_require('geometry.lua')
    local R,V,C=h.env.RBX,h.env.Vector3,h.env.CFrame
    t.it('uses each geometric face frame and its exact inverse for rotated non-square source surfaces',function()
        local part={ClassName='Part',Shape='Block',Size=V.new(8,3,5),CFrame=C.new(13,-2,8)*C.Angles(.47,-.91,.23)}
        local axes={Front={V.new(1,0,0),V.new(0,1,0),V.new(0,0,-1),8,3},Back={V.new(-1,0,0),V.new(0,1,0),V.new(0,0,1),8,3},
            Right={V.new(0,0,1),V.new(0,1,0),V.new(1,0,0),5,3},Left={V.new(0,0,-1),V.new(0,1,0),V.new(-1,0,0),5,3},
            Top={V.new(0,0,1),V.new(-1,0,0),V.new(0,1,0),5,8},Bottom={V.new(0,0,1),V.new(1,0,0),V.new(0,-1,0),5,8}}
        for face,a in pairs(axes)do
            for _,resolution in ipairs{{1013,317},{2026,634}}do
                local gui={face=face,sizing_mode='FixedSize',canvas_size={x=resolution[1],y=resolution[2]},z_offset=77}
                local halfnormal=math.abs(a[3].X)*4+math.abs(a[3].Y)*1.5+math.abs(a[3].Z)*2.5
                for _,uv in ipairs{{0,0},{1,0},{0,1},{1,1},{.23,.79}}do
                    local localpoint=a[3]*halfnormal+a[1]*((uv[1]-.5)*a[4])+a[2]*((.5-uv[2])*a[5])
                    local oracle=part.CFrame:PointToWorldSpace(localpoint)
                    local point,normal=R._surface_gui_canvas_to_world(gui,part,uv[1]*resolution[1],uv[2]*resolution[2])
                    assert((point-oracle).Magnitude<1e-9,'face map '..face)
                    local x,y,depth,inside=R._surface_gui_world_to_canvas(gui,part,point)
                    assert(math.abs(x-uv[1]*resolution[1])<1e-8 and math.abs(y-uv[2]*resolution[2])<1e-8 and math.abs(depth)<1e-9)
                    local _,_,above=R._surface_gui_world_to_canvas(gui,part,point+normal*.75);assert(math.abs(above-.75)<1e-9)
                end
                gui.sizing_mode='PixelsPerStud';gui.pixels_per_stud=73
                local w,height=R._get_surface_gui_canvas_size(gui,part);assert(w==a[4]*73 and height==a[5]*73)
                local midpoint=R._surface_gui_canvas_to_world(gui,part,w*.5,height*.5)
                assert((midpoint-part.CFrame:PointToWorldSpace(a[3]*halfnormal)).Magnitude<1e-9)
            end
        end
    end)
    t.it('explicit Adornee selects its live transform, and depth ordering never lifts the canvas',function()
        local original={ClassName='Part',Size=V.new(4,2,1),CFrame=C.new()}
        local actual={ClassName='Part',Size=V.new(7,3,2),CFrame=C.new(10,6,-5)*C.Angles(.2,.3,.4)}
        local gui={face='Front',canvas_size={x=333,y=91},adornee={_core_handle=actual},z_offset=-4}
        local a=R._surface_gui_canvas_to_world(gui,original,123,45);gui.z_offset=100
        local b=R._surface_gui_canvas_to_world(gui,original,123,45);assert((a-b).Magnitude==0)
        local expected=actual.CFrame:PointToWorldSpace(V.new((123/333-.5)*7,(.5-45/91)*3,-1))
        assert((a-expected).Magnitude<1e-9)
    end)
    t.it('source root clipping default and zero alpha styles preserve explicit false and authored depth/lighting',function()
        local gui=R._parse_surface_gui_instance{ClassName='SurfaceGui',ZOffset=2.5,Children={{ClassName='TextLabel',Text='Plain',TextStrokeTransparency=1,
            BorderSizePixel=0,BackgroundTransparency=1},{ClassName='TextLabel',Text='Styled',TextStrokeTransparency=0,BorderSizePixel=3}}}
        assert(gui.clips_descendants==true and gui.z_offset==2.5 and not gui.always_on_top)
        local explicit=R._parse_surface_gui_instance{ClassName='SurfaceGui',ClipsDescendants=false,AlwaysOnTop=false,LightInfluence=.4,Brightness=2}
        assert(explicit.clips_descendants==false);local influence,brightness=R._surface_gui_lighting(explicit);assert(influence==.4 and brightness==2)
        explicit.always_on_top=true;influence,brightness=R._surface_gui_lighting(explicit);assert(influence==0 and brightness==1)
        assert(gui.nodes[1].text_stroke_transparency==1 and gui.nodes[1].border_size==0 and gui.nodes[2].text_stroke_transparency==0 and gui.nodes[2].border_size==3)
    end)
    t.it('actual EnumItem writes preserve face, sizing and text alignment rather than collapsing to defaults',function()
        local N=R._gui_normalizers
        for _,face in ipairs{'Right','Left','Top','Bottom','Front','Back'}do assert(N.face(R.Enum.NormalId[face])==face)end
        assert(N.sizing_mode(R.Enum.SurfaceGuiSizingMode.PixelsPerStud)=='PixelsPerStud')
        assert(N.sizing_mode(R.Enum.SurfaceGuiSizingMode.FixedSize)=='FixedSize')
        assert(N.text_alignment(R.Enum.TextXAlignment.Left,'x')=='left')
        assert(N.text_alignment(R.Enum.TextYAlignment.Bottom,'y')=='bottom')
    end)
end
return suite
