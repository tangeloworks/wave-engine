-- one private traversal counter. Callback failures retain their identity so
-- optional GUI fallback cannot turn a canceled load into successful admission
local Progress={};Progress.__index=Progress
function Progress.new(checkpoint,stage,batch)
    if checkpoint==nil then return nil end
    assert(type(checkpoint)=='function','Loading checkpoint must be a function')
    return setmetatable({checkpoint=checkpoint,stage=stage,batch=batch or 32,count=0},Progress)
end
function Progress:mark(stage,index,total)
    local ok,err=pcall(self.checkpoint,stage or self.stage,index,total)
    if not ok then self.failed=err;error(err,0)end
end
function Progress:step(stage)
    self.count=self.count+1
    if self.count%self.batch==0 then self:mark(stage,self.count)end
end
return Progress
