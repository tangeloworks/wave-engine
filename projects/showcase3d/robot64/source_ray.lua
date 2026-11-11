-- Project-local compatibility for Roblox Ray closest-point math. Workspace
-- raycasts keep their finite reach; this helper is only the value-type method.
-- Primary contract: Roblox/creator-docs Ray.yaml describes a half-line and
-- warns that ClosestPoint requires a unit direction. The source's nonunit
-- tipping ray uses the historical unnormalized projection deliberately.
-- Corroboration: supplied read-only rbx2022 RbxRay.h:117-131 and
-- LuaAtomicClasses.cpp:179-217; hashes and paths in research/ray-contract.json.
local Ray={};Ray.__index=Ray
Ray.contract={source='https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/datatypes/Ray.yaml',
    status='source-verified-unit-contract-and-nonunit-quirk',
    evidence='projects/showcase3d/robot64/research/ray-contract.json'}
function Ray.new(origin,direction) return setmetatable({Origin=origin,Direction=direction},Ray) end
function Ray:ClosestPoint(point)
    return self.Origin+self.Direction*math.max(0,(point-self.Origin):Dot(self.Direction))
end
function Ray:Distance(point) return (self:ClosestPoint(point)-point).Magnitude end
return Ray
