-- shape descriptor + aabb only, no contacts (thats narrowphase)

local Shape = {}
local Size = runtime_require("size_validation.lua")

local MIN_SIZE = 0.001

local function clamp_size(value)
    value = math.abs(tonumber(value) or 1)
    if value < MIN_SIZE then
        return MIN_SIZE
    end
    return value
end

local function position_components(part)
    local position = part and part.Position or nil
    return position and (position.x or position.X) or 0,
        position and (position.y or position.Y) or 0,
        position and (position.z or position.Z) or 0
end

-- Wedges retain their native shape for sphere contacts, mesh contacts use boxes
function Shape.kind_of(part)
    if type(part) ~= "table" then
        return "block"
    end
    if part._collision_decomposition or(part._part and part._part._collision_decomposition)then return 'convex_decomposition'end
    local shape = part.Shape
    if shape == "Ball" then
        return "ball"
    elseif shape == "Cylinder" then
        return "cylinder"
    elseif shape == "Wedge" or shape == "CornerWedge" then
        return "wedge"
    end
    if part.ClassName == "MeshPart" then
        return "mesh"
    end
    return "block"
end

function Shape.half_extents(part)
    if part._collision_decomposition or(part._part and part._part._collision_decomposition)then
        return runtime_require('physics/convex_decomposition.lua').half_extents(part)
    end
    local x, y, z = Size.part(part)
    local sx, sy, sz = clamp_size(x), clamp_size(y), clamp_size(z)
    return sx * 0.5, sy * 0.5, sz * 0.5
end

function Shape.aabb(part, margin)
    local x, y, z = position_components(part)
    local hx, hy, hz = Shape.half_extents(part)
    margin = tonumber(margin) or 0
    hx, hy, hz = hx + margin, hy + margin, hz + margin
    return {
        min_x = x - hx, min_y = y - hy, min_z = z - hz,
        max_x = x + hx, max_y = y + hy, max_z = z + hz,
    }
end

return Shape
