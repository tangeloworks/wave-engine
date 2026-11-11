-- Ordered source region flags shared by movement and presentation owners.
local Regions={}
function Regions.capture(hits,map,position)
    local result={hits=hits or{},map=map,position=position,light=false,silent=false}
    for _,part in ipairs(result.hits) do
        if part.Parent and map and part:IsDescendantOf(map) then
            if part.Name=='Light' then result.light=true
            elseif part.Name=='silent' then result.silent=true
            elseif part.Name:sub(1,5)=='ToCam' then result.touchcam=part end
        end
    end
    return result
end
return Regions
