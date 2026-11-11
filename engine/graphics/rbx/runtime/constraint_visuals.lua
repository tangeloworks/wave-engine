-- visible mechanical constraints are scene geometry, not debug overlays
-- Roblox exposes Visible/Color on Constraint and Thickness on Rope/Rod. both
-- endpoints stay attached even when physics is disabled or both bodies anchor
-- https://create.roblox.com/docs/reference/engine/classes/Constraint
-- https://create.roblox.com/docs/reference/engine/classes/RopeConstraint
-- https://create.roblox.com/docs/reference/engine/classes/RodConstraint
local Visuals = {}
local coords = runtime_require("coords.lua")
local sqrt, abs, sin, cos, pi = math.sqrt, math.abs, math.sin, math.cos, math.pi
local ROPE_SEGMENTS, SIDES = 12, 8

local function finite(value)
    return type(value) == "number" and value == value and abs(value) < math.huge
end

local function in_workspace(node)
    while node do
        if rawget(node, "_destroyed") then return false end
        if rawget(node, "_class_name") == "Workspace" then return true end
        node = rawget(node, "_parent")
    end
    return false
end

-- Compose nested Attachments before the first BasePart, just as physics does
-- Reading the facade CFrame observes current authored/follower/physics poses;
-- physics rows cannot supply inactive, immovable or simulation-disabled ropes
function Visuals.endpoint(attachment)
    if type(attachment) ~= "table" or rawget(attachment, "_class_name") ~= "Attachment"
        or not in_workspace(attachment) then return nil end
    local x, y, z, node = 0, 0, 0, attachment
    while node do
        local class = rawget(node, "_class_name")
        if class == "Bone" then return nil end -- no skeletal world-pose support
        if class == "Attachment" then
            x, y, z = coords.point_to_world(node.CFrame, x, y, z)
        elseif rawget(node, "_core_handle_id") then
            x, y, z = coords.point_to_world(node.CFrame, x, y, z)
            if finite(x) and finite(y) and finite(z) then return x, y, z end
            return nil
        end
        node = rawget(node, "_parent")
    end
end

function Visuals.color(value)
    local r, g, b
    if type(value) == "table" then
        local id = tonumber(value.Number or value.number)
        local brick = id and BRICK_COLORS[id]
        if brick then return brick[1] / 255, brick[2] / 255, brick[3] / 255 end
        local col = value.Color or value
        r, g, b = col.R or col.r or col[1], col.G or col.g or col[2], col.B or col.b or col[3]
    else
        local brick = BRICK_COLORS[tonumber(value) or 194]
        if brick then return brick[1] / 255, brick[2] / 255, brick[3] / 255 end
    end
    r, g, b = tonumber(r) or 163 / 255, tonumber(g) or 162 / 255, tonumber(b) or 165 / 255
    if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
    return math.max(0, math.min(1, r)), math.max(0, math.min(1, g)), math.max(0, math.min(1, b))
end

local function curve_length(dx, dy, dz, sx, sy, sz, sag)
    local length, px, py, pz = 0, 0, 0, 0
    for i = 1, ROPE_SEGMENTS do
        local t = i / ROPE_SEGMENTS
        local drop = 4 * sag * t * (1 - t)
        local x, y, z = dx * t + sx * drop, dy * t + sy * drop, dz * t + sz * drop
        local ex, ey, ez = x - px, y - py, z - pz
        length = length + sqrt(ex * ex + ey * ey + ez * ez)
        px, py, pz = x, y, z
    end
    return length
end

-- Roblox's exact rope tessellation is proprietary. match endpoints, diameter
-- and authored arc length with a bounded downward parabola, not a rigid rod
local function rope_sag(dx, dy, dz, target, distance)
    local sx, sy, sz = 0, -1, 0
    if dx * dx + dz * dz < 1e-10 then
        -- a perfectly vertical slack cable needs a stable bend plane instead
        -- of a doubled-back tube occupying precisely the same line
        sx, sy, sz = .6, -.8, 0
    end
    local low, high = 0, target
    for _ = 1, 14 do
        local middle = (low + high) * .5
        if curve_length(dx, dy, dz, sx, sy, sz, middle) < target then low = middle else high = middle end
    end
    return (low + high) * .5, sx, sy, sz
end

local function vertex(record, x, y, z, nx, ny, nz)
    local index = record.vertex_count + 1
    record.vertex_count = index
    local row = record.vertices[index]
    if not row then row = {}; record.vertices[index] = row end
    row[1], row[2], row[3], row[4], row[5], row[6] = x, y, z, nx, ny, nz
    row[7], row[8], row[9], row[10], row[11], row[12] = record.gpu_r, record.gpu_g, record.gpu_b, 1, 0, 0
    local bounds = record.bounds
    bounds.min_x, bounds.max_x = math.min(bounds.min_x, x), math.max(bounds.max_x, x)
    bounds.min_y, bounds.max_y = math.min(bounds.min_y, y), math.max(bounds.max_y, y)
    bounds.min_z, bounds.max_z = math.min(bounds.min_z, z), math.max(bounds.max_z, z)
end

local function ring_vertex(record, ring, side)
    local point = ring[side % SIDES + 1]
    vertex(record, point[1], point[2], point[3], point[4], point[5], point[6])
end

local function rebuild(record)
    local dx, dy, dz = record.bx - record.ax, record.by - record.ay, record.bz - record.az
    local distance = sqrt(dx * dx + dy * dy + dz * dz)
    record.distance, record.vertex_count = distance, 0
    record.gpu_r, record.gpu_g, record.gpu_b = coords.color3_to_gpu(record.r, record.g, record.b)
    local bounds = record.bounds
    bounds.min_x, bounds.min_y, bounds.min_z = math.huge, math.huge, math.huge
    bounds.max_x, bounds.max_y, bounds.max_z = -math.huge, -math.huge, -math.huge
    local sag, sx, sy, sz, segments = 0, 0, -1, 0, 1
    if record.class == "RopeConstraint" and record.length > distance + 1e-4 then
        segments = ROPE_SEGMENTS
        sag, sx, sy, sz = rope_sag(dx, dy, dz, record.length, distance)
    end
    record.sag, record.segments = sag, segments
    if distance < 1e-8 and sag < 1e-8 then return end
    local ex, ey, ez = dz, 0, -dx
    local el = sqrt(ex * ex + ez * ez)
    if el < 1e-8 then ex, ey, ez = 0, 0, 1 else ex, ez = ex / el, ez / el end
    local radius = record.thickness * .5
    for i = 0, segments do
        local t = i / segments
        local drop, slope = 4 * sag * t * (1 - t), 4 * sag * (1 - 2 * t)
        local x, y, z = record.ax + dx * t + sx * drop, record.ay + dy * t + sy * drop, record.az + dz * t + sz * drop
        local tx, ty, tz = dx + sx * slope, dy + sy * slope, dz + sz * slope
        local tl = sqrt(tx * tx + ty * ty + tz * tz)
        if tl < 1e-8 then tx, ty, tz, tl = 0, 1, 0, 1 end
        tx, ty, tz = tx / tl, ty / tl, tz / tl
        local fx, fy, fz = ty * ez - tz * ey, tz * ex - tx * ez, tx * ey - ty * ex
        local fl = sqrt(fx * fx + fy * fy + fz * fz)
        fx, fy, fz = fx / fl, fy / fl, fz / fl
        local ring = record.rings[i + 1]
        if not ring then ring = {}; record.rings[i + 1] = ring end
        ring.x, ring.y, ring.z, ring.tx, ring.ty, ring.tz = x, y, z, tx, ty, tz
        for side = 0, SIDES - 1 do
            local c, s = cos(side * 2 * pi / SIDES), sin(side * 2 * pi / SIDES)
            local nx, ny, nz = ex * c + fx * s, ey * c + fy * s, ez * c + fz * s
            local row = ring[side + 1]
            if not row then row = {}; ring[side + 1] = row end
            row[1], row[2], row[3], row[4], row[5], row[6] = x + radius * nx, y + radius * ny, z + radius * nz, nx, ny, nz
        end
    end
    for i = 1, segments do
        local a, b = record.rings[i], record.rings[i + 1]
        for side = 0, SIDES - 1 do
            ring_vertex(record, a, side); ring_vertex(record, b, side); ring_vertex(record, b, side + 1)
            ring_vertex(record, a, side); ring_vertex(record, b, side + 1); ring_vertex(record, a, side + 1)
        end
    end
    for _, index in ipairs({1, segments + 1}) do
        local ring, sign = record.rings[index], index == 1 and -1 or 1
        for side = 0, SIDES - 1 do
            vertex(record, ring.x, ring.y, ring.z, ring.tx * sign, ring.ty * sign, ring.tz * sign)
            local a, b = ring[side + 1], ring[(side + 1) % SIDES + 1]
            vertex(record, a[1], a[2], a[3], ring.tx * sign, ring.ty * sign, ring.tz * sign)
            vertex(record, b[1], b[2], b[3], ring.tx * sign, ring.ty * sign, ring.tz * sign)
        end
    end
end

function Visuals.prepare(core)
    local registry = core._rope_instances
    local state = core._constraint_visual_state
    if not registry or not next(registry) then
        if state then state.count, state.vertex_count, state.records = 0, 0, {} end
        return nil
    end
    if not state then
        state = {records = {}, vertices = {}, bounds = {}, generation = 0, uploads = 0}
        core._constraint_visual_state = state
    end
    state.generation = state.generation + 1
    local dirty, count = false, 0
    for node in pairs(registry) do
        local class = rawget(node, "_class_name")
        if (class == "RopeConstraint" or class == "RodConstraint") and node.Visible == true and in_workspace(node) then
            local ax, ay, az = Visuals.endpoint(node.Attachment0)
            local bx, by, bz = Visuals.endpoint(node.Attachment1)
            local thickness, length = tonumber(node.Thickness) or .1, tonumber(node.Length) or 5
            if ax and bx and finite(thickness) and thickness > 0 and finite(length) and length >= 0 then
                local r, g, b = Visuals.color(node.Color)
                local record = state.records[node]
                if not record then
                    record = {vertices = {}, rings = {}, bounds = {}}
                    state.records[node], dirty = record, true
                end
                record.seen = state.generation
                count = count + 1
                if record.ax ~= ax or record.ay ~= ay or record.az ~= az or record.bx ~= bx or record.by ~= by or record.bz ~= bz
                    or record.thickness ~= thickness or record.length ~= length or record.r ~= r or record.g ~= g or record.b ~= b then
                    record.ax, record.ay, record.az, record.bx, record.by, record.bz = ax, ay, az, bx, by, bz
                    record.class, record.thickness, record.length, record.r, record.g, record.b = class, thickness, length, r, g, b
                    rebuild(record)
                    dirty = true
                end
            end
        end
    end
    for node, record in pairs(state.records) do
        if record.seen ~= state.generation then state.records[node], dirty = nil, true end
    end
    state.count = count
    if dirty then
        local total, bounds = 0, state.bounds
        bounds.min_x, bounds.min_y, bounds.min_z = math.huge, math.huge, math.huge
        bounds.max_x, bounds.max_y, bounds.max_z = -math.huge, -math.huge, -math.huge
        for _, record in pairs(state.records) do
            for index = 1, record.vertex_count do total = total + 1; state.vertices[total] = record.vertices[index] end
            if record.vertex_count > 0 then
                for _, axis in ipairs({"x", "y", "z"}) do
                    bounds["min_" .. axis] = math.min(bounds["min_" .. axis], record.bounds["min_" .. axis])
                    bounds["max_" .. axis] = math.max(bounds["max_" .. axis], record.bounds["max_" .. axis])
                end
            end
        end
        for index = total + 1, #state.vertices do state.vertices[index] = nil end
        state.vertex_count = total
        if total > 0 then
            if not core._constraint_visual_mesh or (state.capacity or 0) < total then
                if core._constraint_visual_mesh then core._constraint_visual_mesh:release() end
                state.capacity = math.max(256, total * 2)
                core._constraint_visual_mesh = love.graphics.newMesh(core._static_vertex_format, state.capacity, "triangles", "dynamic")
            end
            core._constraint_visual_mesh:setVertices(state.vertices, 1, total)
            core._constraint_visual_mesh:setDrawRange(1, total)
            core._static_mesh_unit_alpha = core._static_mesh_unit_alpha or setmetatable({}, {__mode = "k"})
            core._static_mesh_unit_alpha[core._constraint_visual_mesh] = true
            state.uploads = state.uploads + 1
        end
    end
    if (state.vertex_count or 0) == 0 then return nil end
    return state
end

return Visuals
