-- Read the exact supplied public template. Pose CFrames are already relative
-- to mps in CharacterScript toonvis; do not recompute them around the torso.
local Rig={}
function Rig.build(world,rbx,body,assets)
    local rf=require('projects/showcase3d/robot64/source').service(world,'ReplicatedFirst')
    local model=require('projects/showcase3d/robot64/source').clone(assert(rf:FindFirstChild('vis'),'Public vis missing'),world,rbx)
    model.Parent=body
    -- Public setupvis disables the local username label (source3377).
    for _,node in ipairs(model:GetDescendants()) do
        if node.ClassName=='BillboardGui' and node.Name=='BillboardGui' then node.Enabled=false end
    end
    local parts,by_name={},{}
    for _,part in ipairs(model:GetDescendants()) do
        if part:IsA('BasePart') then
            part.Anchored=true;part.CanCollide=false;part.CanQuery=false;part.CanTouch=false
            local core_part=rawget(part,'_core_handle')
            if core_part then core_part._retain_animation_visibility_packet=true end
            by_name[part.Name]=part
            if part.Parent==model or part.Name=='pack' or part.Name:match('^bt[1-4]$') then
                parts[#parts+1]={part=part,name=part.Name}
            else part.Transparency=1 end
        end
    end
    local templates={}
    for name,source in pairs({collection='pose',roll='pose2',skid='pose3'}) do
        templates[name]={}
        local pose=require('projects/showcase3d/robot64/source').clone(assert(rf:FindFirstChild(source),'Public pose missing '..source),world,rbx)
        for _,part in ipairs(pose:GetChildren()) do
            if part:IsA('BasePart') then templates[name][part.Name]=part.CFrame end
        end
        pose:Destroy()
    end
    local faces={}
    for _,id in ipairs({'1451094768','1451125125','1451125369','1451124286'}) do
        faces['rbxassetid://'..id]=assert(assets:resolve('rbxassetid://'..id),'Public Beebo face missing '..id)
    end
    return model,parts,by_name,templates,faces
end
return Rig
