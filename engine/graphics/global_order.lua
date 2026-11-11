-- Opt-in Global ZIndex painting. Layout and input continue to use the actual
-- widget tree, only paint commands are ordered across parent boundaries
local Global={}
local Surface=require('engine/graphics/surface')
local function child_rect(entry,rect,scroll)
    local offset=scroll and scroll.enabled and scroll.canvasPosition
    if not offset then return rect end
    local result=entry.scroll_rect
    if not result then
        result={position=rect.position.clone and rect.position:clone()or{x=0,y=0},
            size=rect.size.clone and rect.size:clone()or{x=0,y=0},_v=0};entry.scroll_rect=result
    end
    local c,s=math.cos(rect.rotation or 0),math.sin(rect.rotation or 0)
    local ox,oy=offset.x or 0,offset.y or 0
    local x,y=rect.position.x-c*ox+s*oy,rect.position.y-s*ox-c*oy
    local w,h=rect.size.x,rect.size.y
    if result.position.x~=x or result.position.y~=y or result.size.x~=w or result.size.y~=h
        or result.rotation~=rect.rotation or result._ax~=rect._ax or result._ay~=rect._ay then
        result.position.x,result.position.y=x,y;result.size.x,result.size.y=w,h
        result.rotation,result._ax,result._ay=rect.rotation,rect._ax,rect._ay
        result._v=result._v+1
    end
    return result
end
local function child_clip(entry,inherited,rect,clipped)
    if not clipped then return inherited end
    local x,y,w,h=rect.position.x,rect.position.y,rect.size.x,rect.size.y
    if (rect.rotation or 0)~=0 then x,y,w,h=Element._rect_bounds(rect)end
    if inherited then
        local right,bottom=math.min(x+w,inherited.x+inherited.w),math.min(y+h,inherited.y+inherited.h)
        x,y=math.max(x,inherited.x),math.max(y,inherited.y)
        w,h=math.max(0,right-x),math.max(0,bottom-y)
    end
    local clip=entry.child_clip or {};entry.child_clip=clip
    clip.x,clip.y,clip.w,clip.h=x,y,w,h
    clip.rect,clip.parent=rect,inherited
    clip.rotated=math.abs(rect.rotation or 0)>1e-6 or inherited and inherited.rotated
    return clip
end
-- Global Z order may interleave children of different viewports. keep one
-- reusable scratch surface per root, masking each native content draw against
-- its actual ancestor rectangles. the main output needs no stencil attachment
local function draw_rotated_clip(entry,state)
    local clip=entry.clip
    local x,y=math.floor(clip.x),math.floor(clip.y)
    local w,h=math.max(1,math.ceil(clip.x+clip.w)-x),math.max(1,math.ceil(clip.y+clip.h)-y)
    local canvas=state.clip_canvas
    if not canvas or canvas:getWidth()<w or canvas:getHeight()<h
        or not Surface.matches(canvas,canvas:getWidth(),canvas:getHeight()) then
        local cw,ch=math.max(w,canvas and canvas:getWidth() or 0),math.max(h,canvas and canvas:getHeight() or 0)
        if canvas then canvas:release()end
        if state.clip_stencil then state.clip_stencil:release()end
        canvas=Surface.new_canvas(cw,ch);state.clip_canvas=canvas
        state.clip_stencil=Surface.new_canvas(cw,ch,{format='stencil8',readable=false})
    end
    local mapping=rawget(Element,'_clip_coordinate_transform')
    love.graphics.push('all')
    rawset(Element,'_clip_coordinate_transform',nil)
    local ok,err=pcall(function()
        love.graphics.origin();love.graphics.setCanvas({canvas,depthstencil=state.clip_stencil})
        love.graphics.setShader();love.graphics.setScissor();love.graphics.setStencilTest()
        love.graphics.setDepthMode('always',false);love.graphics.setMeshCullMode('none')
        love.graphics.setColorMask(true,true,true,true)
        love.graphics.setBlendMode('alpha','alphamultiply');love.graphics.clear(0,0,0,0,0)
        love.graphics.translate(-x,-y)
        local count,ancestor=0,clip
        while ancestor do
            local rect=ancestor.rect
            love.graphics.stencil(function()love.graphics.polygon('fill',Element._rect_corners(rect))end,'increment',1,true)
            count=count+1;ancestor=ancestor.parent
        end
        love.graphics.setStencilTest('equal',count)
        entry.node:draw(entry.parent_rect,true)
    end)
    rawset(Element,'_clip_coordinate_transform',mapping)
    love.graphics.pop() -- also restores the complete output/temporary stencil target
    if not ok then error(err,0)end
    love.graphics.push('all');love.graphics.setShader()
    Element._draw_cached_canvas(canvas,x,y)
    love.graphics.pop()
end
local function order_less(a,b)
    if a.z~=b.z then return a.z<b.z end
    return a.sequence<b.sequence
end
function Global.collect(root,parent_rect,state,excluded)
    state=state or {entries={},order={}}
    local count,dirty=0,false
    local function visit(node,parent,clip)
        if node.visible==false or excluded and excluded[node] then return end
        count=count+1
        local entry=state.entries[count]
        if not entry then entry={};state.entries[count]=entry;dirty=true end
        local z=node.zindex or 0
        if entry.node~=node or entry.z~=z then dirty=true end
        entry.node,entry.z,entry.sequence,entry.parent_rect,entry.clip=node,z,count,parent,clip
        local rect=node:get_screen_rect(parent)
        entry.rect=rect
        local sc=node.scroll
        local frame=rect
        if node.destretch_isolate_children then
            local options=entry.child_options or {ignore_destretch_size=true};entry.child_options=options
            frame=node:get_screen_rect(parent,options)
        end
        local descendant_clip=child_clip(entry,clip,frame,node.scissor==true or sc and sc.enabled)
        local descendant_rect=child_rect(entry,frame,sc)
        for _,child in ipairs(node.children or {})do visit(child,descendant_rect,descendant_clip)end
    end
    visit(root,parent_rect,nil)
    if #state.entries~=count then dirty=true end
    for i=#state.entries,count+1,-1 do state.entries[i]=nil end
    if dirty then
        for i=1,count do state.order[i]=state.entries[i]end
        for i=#state.order,count+1,-1 do state.order[i]=nil end
        table.sort(state.order,order_less)
        state.sorts=(state.sorts or 0)+1
    end
    state.count=count
    return state.order,state
end
function Global.draw(root,parent_rect,state,excluded)
    local order;order,state=Global.collect(root,parent_rect,state,excluded)
    for _,entry in ipairs(order)do
        local clip=entry.clip
        if not clip or clip.w>0 and clip.h>0 then
            if clip and clip.rotated then draw_rotated_clip(entry,state)
            else
                if clip then Element._push_clip_scissor(clip.x,clip.y,clip.w,clip.h)end
                -- Native content only, layout, callbacks and retained
                -- textures continue to belong to the real widget tree
                local ok,err=pcall(entry.node.draw,entry.node,entry.parent_rect,true)
                if clip then Element._pop_clip_scissor()end
                if not ok then error(err,0)end
            end
        end
    end
    return state
end
return Global
