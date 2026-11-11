-- validate part dimensions before they reach physics or the renderer
-- signed vectors such as velocity and scale have different rules
local Size = {}
local FLOAT_MAX = 3.4028234663852886e38 -- largest finite float32 vertex dimension
local function fail(owner, detail)
    local id = type(owner)=='table' and (owner.referent or owner._referent or owner._id or owner.id) or nil
    local name = type(owner)=='table' and (owner.Name or owner.name or owner._name) or owner
    error('Invalid Size' .. (id and (' referent/id='..tostring(id)) or '')
        .. (name and (' ('..tostring(name)..')') or '') .. ': '..detail, 3)
end
function Size.number(n, owner, axis, public_clamp)
    if type(n)~='number' or n~=n or n==math.huge or n==-math.huge then
        fail(owner, (axis or 'component')..' must be a finite number')
    end
    -- preserve the public setter's existing finite minimum clamp, but never
    -- conceal NaN/-infinity with it. raw imported/physics descriptors keep their
    -- existing signed-size semantics instead of receiving this public clamp
    if public_clamp then n=math.max(0.001,n) end
    if math.abs(n)>FLOAT_MAX then
        fail(owner, (axis or 'component')..' cannot be represented by float32 render dimensions')
    end
    return n
end
function Size.components(value, owner, public_clamp)
    if type(value)~='table' then fail(owner,'expected a three-component numeric vector') end
    return Size.number(value.x or value.X or value[1],owner,'X',public_clamp),
        Size.number(value.y or value.Y or value[2],owner,'Y',public_clamp),
        Size.number(value.z or value.Z or value[3],owner,'Z',public_clamp)
end
function Size.part(part)
    if not part or part.Size==nil then return 1,1,1 end -- absent descriptor default
    return Size.components(part.Size,part)
end
function Size.parsed(part)
    Size.number(part.sx,part,'X');Size.number(part.sy,part,'Y');Size.number(part.sz,part,'Z')
end
function Size.admit(parts)
    for i=1,#(parts or {}) do Size.parsed(parts[i]) end
end
function Size.result(n, owner, what)
    if n~=n or n==math.huge or n==-math.huge then fail(owner,'non-finite derived '..what) end
    return n
end
return Size
