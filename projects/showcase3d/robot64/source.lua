-- Resolve serialized services by class/role. The RBX facade creates only its
-- implemented services; the remaining source services are passive root nodes.
local Source={}
local indexes=setmetatable({},{__mode='k'})
local origins=setmetatable({},{__mode='k'})
local clone_observers=setmetatable({},{__mode='k'})
local sound_defaults=setmetatable({},{__mode='k'})
local sound_fields={'SoundId','Volume','PlaybackSpeed','Pitch','Looped','TimePosition','RollOffMode','RollOffMinDistance','RollOffMaxDistance'}
local references={'Attachment0','Attachment1','Adornee','PrimaryPart','NextSelectionUp','NextSelectionDown','NextSelectionLeft','NextSelectionRight','SelectionImageObject'}
local primitive_vectors={SpecialMesh={'Scale','Offset','VertexColor'}}
local lifetimes=setmetatable({},{__mode='k'})
-- Destruction is distinct from temporary storage. Observe the public event
-- before a writer is queued; Parent=nil alone cannot express this contract.
function Source.lifetime(node)
    if not node then return end
    local token=lifetimes[node]
    if token then return token end
    token={destroyed=false,observed=false};lifetimes[node]=token
    local signal=node.Destroying
    if signal and signal.Connect then
        token.observed=true
        token.connection=signal:Connect(function()
            token.destroyed=true
            local connection=token.connection;token.connection=nil
            if connection then connection:Disconnect()end
        end)
    end
    return token
end
function Source.live(node,token)
    if not node then return false end
    token=token or lifetimes[node]
    if token and token.destroyed then return false end
    -- Small inert fixtures have no Destroying signal; live runtime Instances
    -- use the observed token and may safely remain unparented or in storage.
    return token and token.observed or node.Parent~=nil
end
function Source.integer(raw)
    if type(raw)=='number' then return raw end
    assert(type(raw)=='table' and raw.lo and raw.hi,'Invalid serialized integer')
    local hi=raw.hi
    if raw.signed and hi>=2147483648 then hi=hi-4294967296 end
    local n=hi*4294967296+raw.lo
    assert(math.abs(n)<=9007199254740991,'Source integer exceeds exact Lua number range')
    return n
end
function Source.vector(raw,rbx)
    assert(type(raw)=='table','Invalid serialized Vector3')
    return rbx.Vector3.new(raw.X or raw.x or raw._x or raw[1],raw.Y or raw.y or raw._y or raw[2],raw.Z or raw.z or raw._z or raw[3])
end
function Source.cframe(raw,rbx)
    assert(type(raw)=='table','Invalid serialized CFrame')
    return rbx.CFrame.new(raw.X or raw.x or raw._x,raw.Y or raw.y or raw._y,raw.Z or raw.z or raw._z,
        raw.r00 or raw._r00 or raw.R00,raw.r01 or raw._r01 or raw.R01,raw.r02 or raw._r02 or raw.R02,
        raw.r10 or raw._r10 or raw.R10,raw.r11 or raw._r11 or raw.R11,raw.r12 or raw._r12 or raw.R12,
        raw.r20 or raw._r20 or raw.R20,raw.r21 or raw._r21 or raw.R21,raw.r22 or raw._r22 or raw.R22)
end
function Source.color(raw,rbx)
    assert(type(raw)=='table','Invalid serialized Color3')
    return rbx.Color3.new(raw.R or raw.r or raw._r,raw.G or raw.g or raw._g,raw.B or raw.b or raw._b)
end
function Source.world_space(raw)
    if type(raw)=='table' then raw=raw.Value or raw.value or raw.Name or raw.name end
    return raw==2 or raw=='World' or raw=='Enum.ActuatorRelativeTo.World'
end
local function typed(node,rbx,original)
    -- Read the source getter before generic Clone loses its math metatable.
    -- Every destination gets a fresh typed value, so no mutable clone alias is
    -- introduced. Private scalar support also admits an inert generic copy.
    local class=node.ClassName
    if class=='Sound' and original then
        local defaults=sound_defaults[original]or{}
        for _,key in ipairs(sound_fields)do
            local value=original[key];if value==nil then value=defaults[key]end
            if value~=nil then node[key]=value end
        end
        sound_defaults[node]=defaults
    end
    for _,key in ipairs(primitive_vectors[class] or {}) do
        local value=(original or node)[key]
        if type(value)=='table' then node[key]=Source.vector(value,rbx) end
    end
    if class~='IntValue' and class~='Vector3Value' and class~='CFrameValue' and class~='Color3Value' then return end
    local value=(original or node).Value
    if node.ClassName=='IntValue' then node.Value=Source.integer(value)
    elseif node.ClassName=='Vector3Value' then node.Value=Source.vector(value,rbx)
    elseif node.ClassName=='CFrameValue' then node.Value=Source.cframe(value,rbx)
    elseif node.ClassName=='Color3Value' then node.Value=Source.color(value,rbx)
    end
end
function Source.prepare(world,rbx,checkpoint)
    assert(checkpoint==nil or type(checkpoint)=='function','Source checkpoint must be a function')
    local function stage(unit,index,total)if checkpoint then checkpoint('source:'..unit,index,total)end end
    local function batch(unit,index,total)if index%256==0 or index==total then stage(unit,index,total)end end
    local index={}
    stage('snapshot',0,1)
    local nodes=world:GetDescendants()
    stage('snapshot',1,1)
    for i,node in ipairs(nodes) do
        if node.Referent then index[node.Referent]=node end
        origins[node]=node.Referent
        typed(node,rbx)
        batch('nodes',i,#nodes)
    end
    stage('publish',0,1)
    indexes[world]=index
    return index
end
-- The maintained workspace supplies the ignore-list region query only. Filter
-- its complete result by the supplied source whitelist before applying the
-- source result limit; unrelated objects must not consume that limit.
function Source.region_whitelist(workspace,region,include,max_parts)
    local result={};max_parts=max_parts or 20
    if max_parts<=0 then return result end
    for _,part in ipairs(workspace:FindPartsInRegion3WithIgnoreList(region,{},math.huge)) do
        for _,root in ipairs(include) do
            if part==root or part:IsDescendantOf(root) then
                result[#result+1]=part;break
            end
        end
        if #result>=max_parts then break end
    end
    return result
end
-- Native Clone owns the detached tree through typed/reference preparation.
-- Source templates are never temporarily rewritten, including across yields.
-- Ordered identities retain duplicate child names and clone-local references.
function Source.clone(source,world,rbx,loading)
    assert(loading==nil or type(loading)=='table','Source Clone loading context must be a table or nil')
    if loading==nil then loading={}end
    local index=indexes[world] or Source.prepare(world,rbx)
    local prepared=false
    local clone=source:Clone(loading,function(result,owner)
        local saved,pairs_by_source,local_refs={},{},{}
        local pair_count=0
        local function pair(a,b)
            pairs_by_source[a]=b;if a.Referent then local_refs[a.Referent]=b end
            origins[b]=origins[a]or a.Referent
            typed(b,rbx,a)
            for _,key in ipairs(references)do
                if a[key]~=nil then saved[#saved+1]={node=a,key=key,value=a[key]}end
            end
            if a.ClassName=='ObjectValue'and a.Value~=nil then
                saved[#saved+1]={node=a,key='Value',value=a.Value}
            end
            local ac,bc=a:GetChildren(),b:GetChildren()
            assert(#ac==#bc,'Source Clone child identity changed')
            pair_count=pair_count+1
            if pair_count%32==0 then owner:checkpoint('source:clone-nodes',pair_count)end
            for i,child in ipairs(ac)do pair(child,bc[i])end
        end
        pair(source,result)
        for i,entry in ipairs(saved)do
            local ref=entry.value;local target
            if type(ref)=='table'and ref.ClassName then target=pairs_by_source[ref]or ref
            elseif ref~=-1 and ref~='-1'then target=local_refs[ref]or index[ref]end
            pairs_by_source[entry.node][entry.key]=target
            if i%32==0 then owner:checkpoint('source:clone-references',i,#saved)end
        end
        owner:checkpoint('source:clone-prepared',pair_count,pair_count)
        local observer_count=0
        for callback in pairs(clone_observers[world]or{})do
            callback(result,source,owner)
            observer_count=observer_count+1
            owner:checkpoint('source:clone-observers',observer_count)
        end
        prepared=true
    end)
    assert(prepared,'Native Clone preparation callback was not admitted')
    return clone
end
-- Preserve authored identity without reusing a clone's runtime Referent.
-- Presentation catalogs can resolve descendants of templates and clones of
-- clones while every runtime instance retains its own native identity.
function Source.origin(node)return node and(origins[node]or node.Referent)end
function Source.describe(world,node)
    if not node then return end
    local origin=Source.origin(node);local original=indexes[world]and indexes[world][origin]
    return {source_referent=origin,source_path=original and original:GetFullName()or nil,
        runtime_path=node:GetFullName(),class=node.ClassName}
end
function Source.observe_clones(world,callback)
    assert(type(callback)=='function','Source clone observer must be a function')
    local observers=clone_observers[world]or{};clone_observers[world]=observers;observers[callback]=true
    local connection={Connected=true}
    function connection:Disconnect()
        if not self.Connected then return end;self.Connected=false;observers[callback]=nil
    end
    return connection
end
function Source.service(world,class)
    local live=world:FindService(class);if live then return live end
    for _,node in ipairs(world:GetChildren()) do if node.ClassName==class then return node end end
    error('Required public source service is absent: '..class,2)
end
return Source
