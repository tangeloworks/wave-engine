-- look for gaps inside a glyph stroke by comparing neighboring pixels in ImageData
local Lattice = {}
local function groups(votes)
    local lines,last={},nil
    for i,v in ipairs(votes) do
        if v>=2 then
            if last and i==last+1 then lines[#lines]=(lines[#lines]+i)*.5
            else lines[#lines+1]=i end
            last=i
        end
    end
    return lines
end
local function periodic(lines)
    if #lines<3 then return false end
    local span=lines[#lines]-lines[1]
    -- missing seams are allowed: hinting can move only some shared edges
    for period=2,math.max(2,span/2),.25 do
        local hits=0
        for i=2,#lines do
            local gap=lines[i]-lines[i-1]
            local multiple=math.max(1,math.floor(gap/period+.5))
            if math.abs(gap-multiple*period)<=.75 then hits=hits+1 end
        end
        if hits>=math.max(2,math.ceil((#lines-1)*.8)) then return true end
    end
    return false
end
function Lattice.scan(data,x,y,w,h,opaque)
    x,y=math.max(0,math.floor(x or 0)),math.max(0,math.floor(y or 0))
    w=math.min(math.ceil(w or data:getWidth()),data:getWidth()-x)
    h=math.min(math.ceil(h or data:getHeight()),data:getHeight()-y)
    local ink,mass={},0
    for yy=1,h do
        local row={}; ink[yy]=row
        for xx=1,w do
            local r,g,b,a=data:getPixel(x+xx-1,y+yy-1)
            row[xx]=opaque and (1-math.min(r,g,b)) or a
            mass=mass+row[xx]
        end
    end
    local rows,cols={},{}
    for yy=1,h do rows[yy]=0 end
    for xx=1,w do cols[xx]=0 end
    for yy=2,h-1 do for xx=2,w-1 do
        local a=ink[yy][xx]
        for radius=1,2 do
            if yy>radius and yy+radius<=h then
                local flank=math.min(ink[yy-radius][xx],ink[yy+radius][xx])
                if flank>.9 and a<flank-.06 then rows[yy]=rows[yy]+1; break end
            end
        end
        for radius=1,2 do
            if xx>radius and xx+radius<=w then
                local flank=math.min(ink[yy][xx-radius],ink[yy][xx+radius])
                if flank>.9 and a<flank-.06 then cols[xx]=cols[xx]+1; break end
            end
        end
    end end
    local horizontal,vertical=groups(rows),groups(cols)
    local score=0
    if periodic(horizontal) then score=score+#horizontal end
    if periodic(vertical) then score=score+#vertical end
    return score,{horizontal=horizontal,vertical=vertical,ink_mass=mass}
end
return Lattice
