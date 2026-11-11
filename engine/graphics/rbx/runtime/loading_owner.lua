-- Native constructor resources belong to this operation until transfer. no
-- loaded runtime, sibling renderer or shared resource cache belongs to it
local Owner={};Owner.__index=Owner
function Owner.new(loading)
    loading=loading or{}
    assert(loading.checkpoint==nil or type(loading.checkpoint)=='function','Loading checkpoint must be a function')
    assert(loading.on_owner==nil or type(loading.on_owner)=='function','Loading owner callback must be a function')
    local self=setmetatable({loading=loading,resources={},order={},cleanups={},closed=false,cancelled=false},Owner)
    if loading.on_owner then loading.on_owner(self)end
    return self
end
function Owner:own(resource,temporary)
    assert(not self.closed,'Constructor owner is retired')
    assert(resource and type(resource.release)=='function','Constructor resource must have release')
    if not self.resources[resource]then
        self.resources[resource]={resource=resource,temporary=temporary==true}
        self.order[#self.order+1]=resource
    end
    return resource
end
function Owner:forget(resource)self.resources[resource]=nil end
function Owner:cleanup(callback)
    assert(not self.closed and type(callback)=='function','Constructor cleanup requires its live owner')
    self.cleanups[#self.cleanups+1]=callback
end
function Owner:checkpoint(stage,index,total)
    assert(not self.closed,'Constructor owner was canceled')
    if self.loading.checkpoint then self.loading.checkpoint(stage,index,total)end
    assert(not self.closed,'Constructor owner was canceled during a checkpoint')
end
local function release(entry)
    local resource=entry.resource
    if type(resource.isReleased)=='function'then
        local ok,released=pcall(resource.isReleased,resource)
        if not ok then return false,released end
        if released then return true end
    end
    return pcall(resource.release,resource)
end
function Owner:_release(temporary_only)
    local errors={}
    for i=#self.order,1,-1 do
        local resource=self.order[i];local entry=self.resources[resource]
        if entry and(not temporary_only or entry.temporary)then
            local ok,err=release(entry);if not ok then errors[#errors+1]=tostring(err)end
            self.resources[resource]=nil
        end
    end
    return #errors==0,errors
end
function Owner:cancel()
    if self.closed then return false end
    self.closed=true;self.cancelled=true
    local errors={}
    for i=#self.cleanups,1,-1 do
        local ok,err=pcall(self.cleanups[i]);if not ok then errors[#errors+1]=tostring(err)end
    end
    local _,resource_errors=self:_release(false)
    for _,err in ipairs(resource_errors)do errors[#errors+1]=err end
    self.order={};self.cleanups={};self.loading={}
    return #errors==0,errors
end
function Owner:commit()
    assert(not self.closed,'Constructor owner cannot commit after cancellation')
    local ok,errors=self:_release(true)
    if not ok then return false,errors end
    self.closed=true;self.resources={};self.order={};self.cleanups={};self.loading={}
    return true
end
return Owner
