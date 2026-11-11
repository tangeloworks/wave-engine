-- shared by the native UI bridge and the legacy SurfaceGui/ScreenGui painter
-- Windowing the source (rather than a screen scissor) also works after rotation
local Image = {}
local empty = {}
function Image.draw(node, texture, w, h)
    if w <= 0 or h <= 0 then return end
    local iw, ih = texture:getDimensions()
    local offset, size = node.image_rect_offset or empty, node.image_rect_size or empty
    local x, y = offset.x or 0, offset.y or 0
    local sw, sh = size.x or 0, size.y or 0
    if sw == 0 or sh == 0 then x, y, sw, sh = 0, 0, iw, ih end
    -- Negative ImageRectSize identifies the opposite crop endpoint. mirror
    -- this excerpt in its destination rect, never the whole atlas texture
    local flip_x, flip_y = sw < 0, sh < 0
    if flip_x then x, sw = x + sw, -sw end
    if flip_y then y, sh = y + sh, -sh end
    local mode, slice = node.scale_type or "stretch", node.slice_center or empty
    local tile = node.tile_size
    local tw = tile and (w * tile.x.scale + tile.x.offset) or sw
    local th = tile and (h * tile.y.scale + tile.y.offset) or sh
    tw, th = math.max(1, tw), math.max(1, th)
    local scale = math.max(0, node.slice_scale or 1)
    local l,t,r,b=slice.x0 or 0,slice.y0 or 0,slice.x1 or 0,slice.y1 or 0
    local cache = node._image_layout
    if not cache then cache = {rows = {}}; node._image_layout = cache end
    if cache.w~=w or cache.h~=h or cache.iw~=iw or cache.ih~=ih
        or cache.x~=x or cache.y~=y or cache.sw~=sw or cache.sh~=sh
        or cache.mode~=mode or cache.tw~=tw or cache.th~=th or cache.scale~=scale
        or cache.flip_x~=flip_x or cache.flip_y~=flip_y
        or cache.l~=l or cache.t~=t or cache.r~=r or cache.b~=b then
        cache.w,cache.h,cache.iw,cache.ih=w,h,iw,ih
        cache.x,cache.y,cache.sw,cache.sh=x,y,sw,sh
        cache.mode,cache.tw,cache.th,cache.scale=mode,tw,th,scale
        cache.flip_x,cache.flip_y=flip_x,flip_y
        cache.l,cache.t,cache.r,cache.b,cache.count=l,t,r,b,0
        local function rect(sx, sy, cw, ch, dx, dy, dw, dh)
            if cw <= 0 or ch <= 0 or dw <= 0 or dh <= 0 then return end
            cache.count = cache.count + 1
            local row = cache.rows[cache.count]
            if not row then row = {}; cache.rows[cache.count] = row end
            if row.quad then row.quad:setViewport(sx, sy, cw, ch, iw, ih)
            else row.quad = love.graphics.newQuad(sx, sy, cw, ch, iw, ih) end
            -- mirror every destination tile/slice around the complete GUI
            -- rect, including partial tiles, so ordering and seams stay intact
            row.x = flip_x and w - dx or dx
            row.y = flip_y and h - dy or dy
            row.sx = (flip_x and -1 or 1) * dw/cw
            row.sy = (flip_y and -1 or 1) * dh/ch
        end
        if mode == "fit" then
            local s = math.min(w/sw, h/sh)
            rect(x,y,sw,sh,(w-sw*s)/2,(h-sh*s)/2,sw*s,sh*s)
        elseif mode == "crop" then
            local s = math.max(w/sw,h/sh)
            rect(x+(sw-w/s)/2,y+(sh-h/s)/2,w/s,h/s,0,0,w,h)
        elseif mode == "tile" then
            for dy = 0, h-1e-6, th do
                for dx = 0, w-1e-6, tw do
                    local dw, dh = math.min(tw,w-dx), math.min(th,h-dy)
                    rect(x,y,sw*dw/tw,sh*dh/th,dx,dy,dw,dh)
                end
            end
        elseif mode == "slice" and node.slice_center then
            local l = math.max(0,math.min(sw,slice.x0))
            local r = math.max(l,math.min(sw,slice.x1))
            local t = math.max(0,math.min(sh,slice.y0))
            local b = math.max(t,math.min(sh,slice.y1))
            local s = math.min(scale,w/math.max(1e-9,l+sw-r),h/math.max(1e-9,t+sh-b))
            local xs, ys = {0,l,r,sw}, {0,t,b,sh}
            local xd, yd = {0,l*s,w-(sw-r)*s,w}, {0,t*s,h-(sh-b)*s,h}
            for j=1,3 do for i=1,3 do
                rect(x+xs[i],y+ys[j],xs[i+1]-xs[i],ys[j+1]-ys[j],
                    xd[i],yd[j],xd[i+1]-xd[i],yd[j+1]-yd[j])
            end end
        else rect(x,y,sw,sh,0,0,w,h) end
        -- release surplus tile quads when a resize or mode change shrinks layout
        for i=#cache.rows,cache.count+1,-1 do cache.rows[i].quad:release();cache.rows[i]=nil end
    end
    for i=1,cache.count do
        local r = cache.rows[i]
        love.graphics.draw(texture,r.quad,r.x,r.y,0,r.sx,r.sy)
    end
end
return Image
