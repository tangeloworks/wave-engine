-- Robot raycasts rebuild their exclusion lists every cast. The engine keeps a
-- normalized descendant id set per RaycastParams while its filter revision and
-- the DataModel hierarchy epoch are unchanged, so the revision advances only
-- when the listed instances (or their order) actually differ.
local RayFilter={}
function RayFilter.assign(params,list)
    local current=rawget(params,'_robot_filter_list')
    local same=current~=nil and #current==#list
    if same then
        for i=1,#list do if current[i]~=list[i] then same=false;break end end
    end
    if not same then
        local copy={};for i=1,#list do copy[i]=list[i] end
        params._robot_filter_list=copy
        params._rbx_filter_revision=(rawget(params,'_rbx_filter_revision')or 0)+1
    end
    params.FilterDescendantsInstances=list
end
return RayFilter
