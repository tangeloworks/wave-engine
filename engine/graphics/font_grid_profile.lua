-- recognize pixel fonts whose H, M and E are made of rectangles on a shared grid
-- leave composite glyphs and unrecognized fonts on the usual outline path
local Grid = {}
function Grid.inspect(bytes)
    local function inspect()
        local n=#bytes
        local function u8(p) assert(p>=1 and p<=n); return bytes:byte(p) end
        local function u16(p) return u8(p)*256+u8(p+1) end
        local function s16(p) local v=u16(p); return v>=32768 and v-65536 or v end
        local function u32(p) return u16(p)*65536+u16(p+2) end
        local function bit(v,b) return math.floor(v/b)%2==1 end
        if bytes:sub(1,4)~="\0\1\0\0" and bytes:sub(1,4)~="true" then return end
        local count=u16(5); if count>128 then return end
        local tables={}
        for i=0,count-1 do
            local p=13+i*16; local offset,length=u32(p+8)+1,u32(p+12)
            assert(offset>=1 and offset+length-1<=n)
            tables[bytes:sub(p,p+3)]={offset,length}
        end
        for _,tag in ipairs({"head","cmap","loca","glyf","maxp"}) do if not tables[tag] then return end end
        if tables.fpgm or tables.prep then return end -- intentional font hint programs own their policy
        local head,cmap,loca,glyf=tables.head[1],tables.cmap[1],tables.loca[1],tables.glyf[1]
        local em=u16(head+18); if em<16 then return end
        local longLoca=s16(head+50)==1
        local glyphCount=u16(tables.maxp[1]+4)
        local function glyph_id(cp)
            for i=0,u16(cmap+2)-1 do
                local p=cmap+4+i*8; local platform=u16(p)
                if platform==0 or platform==3 then
                    local s=cmap+u32(p+4); local format=u16(s)
                    if format==4 then
                        local segments=u16(s+6)/2
                        for j=0,segments-1 do
                            local finish=u16(s+14+j*2)
                            local start=u16(s+16+segments*2+j*2)
                            if cp>=start and cp<=finish then
                                local delta=s16(s+16+segments*4+j*2)
                                local r=s+16+segments*6+j*2; local offset=u16(r)
                                if offset==0 then return (cp+delta)%65536 end
                                local id=u16(r+offset+2*(cp-start))
                                return id==0 and 0 or (id+delta)%65536
                            end
                        end
                    elseif format==12 then
                        local groups=u32(s+12); if groups>65536 then return end
                        for j=0,groups-1 do
                            local g=s+16+j*12; local start,finish=u32(g),u32(g+4)
                            if cp>=start and cp<=finish then return u32(g+8)+cp-start end
                        end
                    end
                end
            end
        end
        local cellW,cellH,total,shared=nil,nil,0,0
        for _,cp in ipairs({72,77,69}) do
            local id=glyph_id(cp); if not id or id==0 or id>=glyphCount then return end
            local offset=longLoca and u32(loca+id*4) or u16(loca+id*2)*2
            local p=glyf+offset; local contours=s16(p)
            if contours<4 or contours>2048 then return end
            for j=0,contours-1 do if u16(p+10+j*2)~=(j+1)*4-1 then return end end
            local q=p+10+contours*2; if u16(q)~=0 then return end
            q=q+2
            local points=contours*4; local flags={}
            while #flags<points do
                local flag=u8(q); q=q+1; if not bit(flag,1) then return end
                local repeats=0
                if bit(flag,8) then repeats=u8(q); q=q+1 end
                if #flags+repeats+1>points then return end
                for _=0,repeats do flags[#flags+1]=flag end
            end
            local xs,ys={},{}
            for axis=1,2 do
                local values=axis==1 and xs or ys; local short=axis==1 and 2 or 4
                local same=axis==1 and 16 or 32; local value=0
                for i,flag in ipairs(flags) do
                    local delta=0
                    if bit(flag,short) then delta=u8(q); q=q+1; if not bit(flag,same) then delta=-delta end
                    elseif not bit(flag,same) then delta=s16(q); q=q+2 end
                    value=value+delta; values[i]=value
                end
            end
            local cells={}; local originX,originY=xs[1],ys[1]
            for i=1,points,4 do
                local x0,x1=math.min(xs[i],xs[i+1],xs[i+2],xs[i+3]),math.max(xs[i],xs[i+1],xs[i+2],xs[i+3])
                local y0,y1=math.min(ys[i],ys[i+1],ys[i+2],ys[i+3]),math.max(ys[i],ys[i+1],ys[i+2],ys[i+3])
                if not cellW then cellW,cellH=x1-x0,y1-y0 end
                if cellW<=0 or cellH<=0 or x1-x0~=cellW or y1-y0~=cellH then return end
                if (x0-originX)%cellW~=0 or (y0-originY)%cellH~=0 then return end
                for j=i,i+3 do
                    local k=i+(j-i+1)%4
                    if xs[j]~=xs[k] and ys[j]~=ys[k] then return end
                    if xs[j]==xs[k] and ys[j]==ys[k] then return end
                end
                cells[x0..":"..y0]={x0,y0}; total=total+1
            end
            for _,c in pairs(cells) do
                if cells[(c[1]+cellW)..":"..c[2]] then shared=shared+1 end
                if cells[c[1]..":"..(c[2]+cellH)] then shared=shared+1 end
            end
        end
        if shared<6 then return end
        return {pixel=true,hinting="none",remediate=false,kind="shared-cell-outlines",
            units_per_em=em,cell_width=cellW,cell_height=cellH,native_ppem=em/cellH,
            sampled_cells=total,shared_edges=shared}
    end
    local ok,result=pcall(inspect)
    return ok and result or nil
end
return Grid
