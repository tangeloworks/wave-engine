-- follow the place's gravity, including its low-gravity maps
local Gravity = { normal = 100, low = 40, mode = 'source' }
function Gravity.effective(settings)
    return settings and settings:FindFirstChild('lowgrav') and Gravity.low or Gravity.normal
end
function Gravity.apply(world, settings)
    local value = Gravity.effective(settings)
    world.Workspace.Gravity = value
    return value
end
return Gravity
