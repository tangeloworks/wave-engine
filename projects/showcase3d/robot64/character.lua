-- Ball collision body with an independent vis rig or procedural marker.
local Character = {}

function Character.create(world, rbx, options)
    options = options or {}
    local V, C, Color = rbx.Vector3, rbx.CFrame, rbx.Color3
    if options.public_source then
        local template=assert(require('projects/showcase3d/robot64/source').service(world,'ReplicatedFirst'):FindFirstChild('char'),'Public char missing')
        local Source=require('projects/showcase3d/robot64/source')
        local body=Source.clone(template,world,rbx);body.Name='Char';body.Transparency=1;body.CollisionGroupId=1
        -- The stored public template is anchored. The public start/arrival
        -- releases its live character; template anchoring is not a gameplay
        -- default or a controller freeze to restore after a cinematic.
        body.Anchored=false
        local vector_force=body:FindFirstChild('VectorForce')
        assert(vector_force,'Public character VectorForce missing')
        local attachment=vector_force.Attachment0
        if type(attachment)~='table' then attachment=body:FindFirstChild('Center') end
        local frame=attachment and attachment.CFrame
        local position=frame and (frame.Position or frame.position or frame) or attachment and attachment.Position
        local x=position and (position.X or position.x or position[1])
        local y=position and (position.Y or position.y or position[2])
        local z=position and (position.Z or position.z or position[3])
        assert(vector_force.ApplyAtCenterOfMass==true or (x and y and z and x*x+y*y+z*z<1e-12),
            'Public character VectorForce attachment must apply at center of mass')
        local relative=vector_force.RelativeTo
        assert(Source.world_space(relative),
            'Public character VectorForce must apply in world space')
        vector_force:Destroy()
        local force=world.Instance.new('BodyForce',{Name='BodyForce',Force=V.new(),Parent=body})
        body.Parent=world.Workspace
        local Visual=require('projects/showcase3d/robot64/character_visual')
        local ok,visual=pcall(Visual.new,world,body,rbx,options)
        if not ok then body:Destroy();error(visual,0) end
        return body,force,visual
    end
    local body = world.Instance.new("Part", {
        Name = "Char", Position = V.new(0, 21, 0), Size = V.new(3, 3, 3),
        Shape = rbx.Enum.PartType.Ball, Anchored = false,
        Transparency = options.visual == "vis" and 1 or 0,
        TopSurface = rbx.Enum.SurfaceType.Smooth, BottomSurface = rbx.Enum.SurfaceType.Smooth,
        Color = Color.fromRGB(159, 161, 172),
        CustomPhysicalProperties = rbx.PhysicalProperties.new(0.07, 0, 0, 100, 100),
        Parent = world.Workspace,
    })
    -- FormFactor is not exposed by this runtime. Equal dimensions provide the
    -- requested symmetric collision body without assigning unsupported metadata.
    local force = world.Instance.new("BodyForce", { Name = "BodyForce", Force = V.new(), Parent = body })
    -- ReplicatedFirst/char/BodyGyro in the supplied local template. This drives
    -- the collision body's orientation; articulated animation stays independent.
    world.Instance.new("BodyGyro", {Name="BodyGyro", P=3000, D=300,
        MaxTorque=V.new(5000,5000,5000), CFrame=body.CFrame, Parent=body})
    if options.visual == "vis" then
        local Visual = require("projects/showcase3d/robot64/character_visual")
        local ok, visual = pcall(Visual.new, world, body, rbx,options)
        if not ok then body:Destroy(); error(visual, 0) end
        return body, force, visual
    end
    -- BodyForce applies world-space force at the center of mass. The independent
    -- noncolliding arrow supplies visual facing/spin independently of collisions.
    local marker = { body = body, parts = {}, destroyed = false }
    local definitions = {
        { "FacingShaft", V.new(0.24, 0.18, 1.25), C.new(0, 1.48, 0), Color.fromRGB(245, 218, 81) },
        { "FacingLeft", V.new(0.24, 0.18, 0.65), C.new(-0.22, 1.48, -0.45) * C.Angles(0, -0.7, 0), Color.fromRGB(239, 99, 57) },
        { "FacingRight", V.new(0.24, 0.18, 0.65), C.new(0.22, 1.48, -0.45) * C.Angles(0, 0.7, 0), Color.fromRGB(239, 99, 57) },
    }
    for _, definition in ipairs(definitions) do
        local part = world.Instance.new("Part", { Name = definition[1], Size = definition[2],
            Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false,
            Color = definition[4], Parent = body })
        marker.parts[#marker.parts + 1] = { part = part, local_pose = definition[3] }
    end
    function marker:update_visual(facing, spin)
        if self.destroyed then return end
        facing = facing or V.new(0, 0, -1)
        if facing.Magnitude < 0.001 then facing = V.new(0, 0, -1) end
        local pose = C.lookAt(body.Position, body.Position + facing) * C.Angles(0, spin or 0, 0)
        for _, item in ipairs(self.parts) do item.part.CFrame = pose * item.local_pose end
    end
    function marker:destroy()
        if self.destroyed then return end
        self.destroyed = true
        for _, item in ipairs(self.parts) do item.part:Destroy() end
    end
    marker:update_visual()
    return body, force, marker
end

return Character
