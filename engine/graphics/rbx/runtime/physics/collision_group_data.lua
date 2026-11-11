-- PRIVATE UNAPPLIED candidate. no runtime source registration or default policy
-- Byte layout fit is established separately from the named bit-policy inference
local M={}
local CONVENTION='lsb-id-bit1-means-collidable'
local provenance=setmetatable({},{__mode='k'})
local ROW_KEYS={'ordinal','row_offset_zero_based','id','row_marker','mask_offset_zero_based',
    'mask_hex_le','mask_le_u32','mask_le_i32','name_offset_zero_based','name_byte_length','name_hex','name'}
local function hex(raw)
    return(raw:gsub('.',function(char)return string.format('%02x',string.byte(char))end))
end
local function utf8_name(raw)
    local index=1
    while index<=#raw do
        local a=raw:byte(index)
        if a==0 then return false end
        if a<128 then index=index+1
        else
            local count,low,high
            if a>=194 and a<=223 then count,low,high=2,128,191
            elseif a==224 then count,low,high=3,160,191
            elseif(a>=225 and a<=236)or(a>=238 and a<=239)then count,low,high=3,128,191
            elseif a==237 then count,low,high=3,128,159
            elseif a==240 then count,low,high=4,144,191
            elseif a>=241 and a<=243 then count,low,high=4,128,191
            elseif a==244 then count,low,high=4,128,143
            else return false end
            if index+count-1>#raw then return false end
            local second=raw:byte(index+1)
            if second<low or second>high then return false end
            for offset=2,count-1 do
                local byte=raw:byte(index+offset)
                if byte<128 or byte>191 then return false end
            end
            index=index+count
        end
    end
    return true
end
local function bit(mask,id)
    -- every u32 integer and division by this power of two is exact in Lua's
    -- double integer range. no signed-mask normalization or bit-library default
    return math.floor(mask/2^id)%2==1
end
local function copy_rows(rows)
    local copy={}
    for index,row in ipairs(rows)do
        local item={};for _,key in ipairs(ROW_KEYS)do item[key]=row[key]end;copy[index]=item
    end
    return copy
end
local function copy_pairs(rows,pairs)
    if not pairs then return nil end
    local copy={}
    for _,left in ipairs(rows)do
        copy[left.id]={}
        for _,right in ipairs(rows)do copy[left.id][right.id]=pairs[left.id][right.id]end
    end
    return copy
end

function M.decode(raw,convention)
    if type(raw)~='string'then return nil,'Literal original byte string required' end
    if convention~=nil and convention~=CONVENTION then return nil,'Unsupported explicit pair convention' end
    local index=1
    local function take(count)
        if index+count-1>#raw then return nil,'Truncated field at byte '..(index-1)end
        local start=index;index=index+count;return raw:sub(start,index-1)
    end
    local version,reason=take(1);if not version then return nil,reason end
    version=version:byte()
    if version~=1 then return nil,'Unsupported observed-layout version' end
    local count;count,reason=take(1);if not count then return nil,reason end
    count=count:byte()
    if count>32 then return nil,'Group count exceeds narrow32-ID layout' end
    local rows,ids,names={},{},{}
    for ordinal=0,count-1 do
        local row_offset=index-1
        local id,marker,mask,length,name
        id,reason=take(1);if not id then return nil,reason end;id=id:byte()
        marker,reason=take(1);if not marker then return nil,reason end;marker=marker:byte()
        if id>=32 or ids[id]then return nil,'Invalid or duplicate explicit group ID' end
        if marker~=4 then return nil,'Unsupported row marker; meaning remains unknown' end
        local mask_offset=index-1
        mask,reason=take(4);if not mask then return nil,reason end
        local a,b,c,d=mask:byte(1,4)
        local unsigned=a+b*256+c*65536+d*16777216
        local signed=unsigned>=2147483648 and unsigned-4294967296 or unsigned
        length,reason=take(1);if not length then return nil,reason end;length=length:byte()
        local name_offset=index-1
        if length==0 then return nil,'Empty name is not admitted' end
        name,reason=take(length);if not name then return nil,reason end
        if not utf8_name(name)then return nil,'Unsupported UTF8 name or NUL' end
        if names[name]then return nil,'Duplicate group name' end
        ids[id]=true;names[name]=true
        rows[#rows+1]={ordinal=ordinal,row_offset_zero_based=row_offset,id=id,row_marker=marker,
            mask_offset_zero_based=mask_offset,mask_hex_le=hex(mask),mask_le_u32=unsigned,mask_le_i32=signed,
            name_offset_zero_based=name_offset,name_byte_length=length,name_hex=hex(name),name=name}
    end
    if index~=#raw+1 then return nil,'Trailing bytes are not silently ignored' end
    local pairs
    if convention~=nil then
        pairs={}
        for _,left in ipairs(rows)do
            pairs[left.id]={}
            for _,right in ipairs(rows)do
                local forward,reverse=bit(left.mask_le_u32,right.id),bit(right.mask_le_u32,left.id)
                if forward~=reverse then return nil,'Asymmetric inferred pair; no AND/OR or fallback' end
                pairs[left.id][right.id]=forward
            end
        end
    end
    local result={schema=1,status='decoded-observed-layout-only',marker='module-owned-observed-v1',
        raw_data=raw,raw_hex=hex(raw),version_byte=version,group_count=count,byte_count=#raw,
        consumed_bytes=#raw,groups=copy_rows(rows),collidable_by_id=copy_pairs(rows,pairs),
        pair_convention=convention,pair_semantics_inferred=convention~=nil,
        marker_meaning='unknown; only observed marker4 admitted',
        native_collision_semantics_verified=false,historical_collision_parity_verified=false,
        runtime_imported=false,source_identity_verified_by_decoder=false}
    result.by_id={};result.by_name={}
    for _,row in ipairs(result.groups)do result.by_id[row.id]=row;result.by_name[row.name]=row end
    -- these independent private rows/matrix are not shared with the consumer
    provenance[result]={raw=raw,rows=rows,pairs=pairs,convention=convention}
    return result
end

function M.is_validated(value)
    if type(value)~='table'or getmetatable(value)~=nil then return false end
    local owned=provenance[value]
    if not owned or value.marker~='module-owned-observed-v1' or value.raw_data~=owned.raw
        or value.raw_hex~=hex(owned.raw) or value.schema~=1 or value.status~='decoded-observed-layout-only'
        or value.version_byte~=1 or value.group_count~=#owned.rows
        or value.byte_count~=#owned.raw or value.consumed_bytes~=#owned.raw
        or value.pair_convention~=owned.convention or value.pair_semantics_inferred~=(owned.convention~=nil)
        or value.marker_meaning~='unknown; only observed marker4 admitted'
        or value.native_collision_semantics_verified~=false or value.historical_collision_parity_verified~=false
        or value.runtime_imported~=false or value.source_identity_verified_by_decoder~=false
        or type(value.groups)~='table' or getmetatable(value.groups)~=nil or #value.groups~=#owned.rows
        or type(value.by_id)~='table' or type(value.by_name)~='table'
        or getmetatable(value.by_id)~=nil
        or getmetatable(value.by_name)~=nil then return false end
    for key in pairs(value.groups)do
        if type(key)~='number'or key%1~=0 or key<1 or key>#owned.rows then return false end
    end
    for index,row in ipairs(owned.rows)do
        local observed=value.groups[index]
        if type(observed)~='table'or getmetatable(observed)~=nil then return false end
        for _,key in ipairs(ROW_KEYS)do if observed[key]~=row[key]then return false end end
        if value.by_id[row.id]~=observed or value.by_name[row.name]~=observed then return false end
    end
    local valid_ids,valid_names={},{}
    for _,row in ipairs(owned.rows)do valid_ids[row.id]=true;valid_names[row.name]=true end
    for id in pairs(value.by_id)do if not valid_ids[id]then return false end end
    for name in pairs(value.by_name)do if not valid_names[name]then return false end end
    if not owned.pairs then return value.collidable_by_id==nil end
    if type(value.collidable_by_id)~='table'or getmetatable(value.collidable_by_id)~=nil then return false end
    for id in pairs(value.collidable_by_id)do if not valid_ids[id]then return false end end
    for _,left in ipairs(owned.rows)do
        local observed=value.collidable_by_id[left.id]
        if type(observed)~='table'or getmetatable(observed)~=nil then return false end
        for id in pairs(observed)do if not valid_ids[id]then return false end end
        for _,right in ipairs(owned.rows)do if observed[right.id]~=owned.pairs[left.id][right.id]then return false end end
    end
    return true
end

function M.name_for_id(value,id)
    if not M.is_validated(value)then return nil,'Strict module-owned decoded descriptor required' end
    if type(id)~='number'or id%1~=0 or id<0 or id>=32 then return nil,'Invalid explicit group ID' end
    local row=value.by_id[id]
    if not row then return nil,'Group ID absent from serialized descriptor' end
    return row.name
end

M.EXPLICIT_INFERENCE_CONVENTION=CONVENTION
return M
