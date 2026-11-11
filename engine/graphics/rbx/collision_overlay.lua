-- Developer view of collision: hull wireframes coloured by where their
-- geometry came from, live contact points with their normals, and the
-- bounds of moving bodies, drawn over the frame with a short summary
-- Lines are batched into one mesh, nothing here touches the simulation
local Overlay = {}
Overlay.__index = Overlay

local COLORS = {
    authored = { 0.35, 0.95, 0.45, 0.85 },
    cooked = { 0.3, 0.85, 1, 0.85 },
    hull = { 1, 0.85, 0.25, 0.85 },
    primitive = { 1, 0.55, 0.2, 0.85 },
    box = { 0.75, 0.78, 0.82, 0.45 },
    query = { 0.6, 0.5, 0.9, 0.35 },
    contact = { 1, 0.2, 0.25, 1 },
    normal = { 1, 0.45, 0.45, 1 },
    bounds = { 1, 1, 1, 0.7 },
}

local function category(row)
    local representation = row and row.representation or ""
    if representation:match("^authored primitive") then return "primitive" end
    if representation:match("^authored") then return "authored" end
    if representation:match("^cooked") then return "cooked" end
    if representation:match("^convex hull") then return "hull" end
    return "box"
end

---@param world table an RBX DataModel
---@param rbx table the rbx module, for Vector3
function Overlay.new(world, rbx)
    return setmetatable({ world = world, rbx = rbx, parts = {}, rows = {}, geometry = setmetatable({}, { __mode = "k" }),
        vertices = {}, count = 0 }, Overlay)
end

---index the collidable and queryable parts under `root`, with the rows that
---mesh_collision.prepare returned for it
function Overlay:refresh(root, rows)
    self.parts, self.rows = {}, {}
    for _, row in ipairs(rows or {}) do self.rows[row.path] = row end
    local nodes = { root }
    for _, node in ipairs(root:GetDescendants()) do nodes[#nodes + 1] = node end
    for _, node in ipairs(nodes) do
        if node:IsA("BasePart") and (node.CanCollide or node.CanQuery) then
            self.parts[#self.parts + 1] = node
        end
    end
    local summary = {}
    for _, row in pairs(self.rows) do
        local key = category(row) .. (row.collides and "" or " (query)")
        local entry = summary[key] or { parts = 0, hulls = 0 }
        entry.parts = entry.parts + 1
        entry.hulls = entry.hulls + (row.components or 0)
        summary[key] = entry
    end
    self.summary = summary
end

-- Part-local hull edges of a decomposed part, cached until its size changes
function Overlay:_edges(node)
    local size = node.Size
    local cached = self.geometry[node]
    if cached and cached.x == size.X and cached.y == size.Y and cached.z == size.Z then return cached end
    local data = self.world:get_part_collision_decomposition(node)
    if not data then return nil end
    local edges, seen = {}, {}
    for _, hull in ipairs(data.hulls) do
        local v = hull.vertices
        for _, f in ipairs(hull.faces) do
            for k = 1, #f do
                local a, b = f[k], f[k % #f + 1]
                local ia, ib = (a - 1) * 3, (b - 1) * 3
                local key = string.format("%.4f,%.4f,%.4f|%.4f,%.4f,%.4f", v[ia + 1], v[ia + 2], v[ia + 3], v[ib + 1], v[ib + 2], v[ib + 3])
                local reverse = string.format("%.4f,%.4f,%.4f|%.4f,%.4f,%.4f", v[ib + 1], v[ib + 2], v[ib + 3], v[ia + 1], v[ia + 2], v[ia + 3])
                if not seen[key] and not seen[reverse] then
                    seen[key] = true
                    edges[#edges + 1] = { v[ia + 1], v[ia + 2], v[ia + 3], v[ib + 1], v[ib + 2], v[ib + 3] }
                end
            end
        end
    end
    cached = { x = size.X, y = size.Y, z = size.Z, edges = edges, hulls = #data.hulls }
    self.geometry[node] = cached
    return cached
end

-------------------------------------------------------------------- drawing

function Overlay:_begin(width, height)
    local camera = self.world.Workspace.CurrentCamera
    local cf = camera.CFrame
    local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
    local origin = cf.Position
    self.view = {
        ox = origin.X, oy = origin.Y, oz = origin.Z,
        rx = right.X, ry = right.Y, rz = right.Z, ux = up.X, uy = up.Y, uz = up.Z, lx = look.X, ly = look.Y, lz = look.Z,
        focal = (height / 2) / math.tan(math.rad(camera.FieldOfView or 70) / 2), cx = width / 2, cy = height / 2,
    }
    self.count = 0
end

local NEAR = 0.1

-- one world segment as a screen-space quad of `thickness` pixels
function Overlay:_segment(x1, y1, z1, x2, y2, z2, color, thickness)
    local v = self.view
    local ax, ay, az = x1 - v.ox, y1 - v.oy, z1 - v.oz
    local bx, by, bz = x2 - v.ox, y2 - v.oy, z2 - v.oz
    local da = ax * v.lx + ay * v.ly + az * v.lz
    local db = bx * v.lx + by * v.ly + bz * v.lz
    if da < NEAR and db < NEAR then return end
    if da < NEAR then
        local t = (NEAR - da) / (db - da)
        ax, ay, az, da = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, NEAR
    elseif db < NEAR then
        local t = (NEAR - db) / (da - db)
        bx, by, bz, db = bx + (ax - bx) * t, by + (ay - by) * t, bz + (az - bz) * t, NEAR
    end
    local sx1 = v.cx + (ax * v.rx + ay * v.ry + az * v.rz) / da * v.focal
    local sy1 = v.cy - (ax * v.ux + ay * v.uy + az * v.uz) / da * v.focal
    local sx2 = v.cx + (bx * v.rx + by * v.ry + bz * v.rz) / db * v.focal
    local sy2 = v.cy - (bx * v.ux + by * v.uy + bz * v.uz) / db * v.focal
    local dx, dy = sx2 - sx1, sy2 - sy1
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-3 then return end
    local nx, ny = -dy / length * thickness * 0.5, dx / length * thickness * 0.5
    local out, n = self.vertices, self.count
    local r, g, b, a = color[1], color[2], color[3], color[4]
    local function put(x, y)
        n = n + 1
        local row = out[n]
        if not row then row = {}; out[n] = row end
        row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8] = x, y, 0, 0, r, g, b, a
    end
    put(sx1 + nx, sy1 + ny); put(sx2 + nx, sy2 + ny); put(sx2 - nx, sy2 - ny)
    put(sx1 + nx, sy1 + ny); put(sx2 - nx, sy2 - ny); put(sx1 - nx, sy1 - ny)
    self.count = n
end

function Overlay:_box(cf, hx, hy, hz, color, thickness)
    local corners = {}
    local index = 0
    for _, x in ipairs({ -hx, hx }) do for _, y in ipairs({ -hy, hy }) do for _, z in ipairs({ -hz, hz }) do
        index = index + 1
        corners[index] = cf * self.rbx.Vector3.new(x, y, z)
    end end end
    -- Corners are ordered x-major: 1..4 at -x, 5..8 at +x, within each, y then z
    for _, e in ipairs({ { 1, 2 }, { 1, 3 }, { 2, 4 }, { 3, 4 }, { 5, 6 }, { 5, 7 }, { 6, 8 }, { 7, 8 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }) do
        local a, b = corners[e[1]], corners[e[2]]
        self:_segment(a.X, a.Y, a.Z, b.X, b.Y, b.Z, color, thickness)
    end
end

function Overlay:_part(node)
    local row = self.rows[node:GetFullName()]
    local kind = category(row)
    local color = node.CanCollide and COLORS[kind] or COLORS.query
    local cf = node.CFrame
    local edges = (kind == "authored" or kind == "cooked" or kind == "hull") and self:_edges(node)
    if edges then
        -- Rotation columns: right, up and back (the negated look vector)
        local p, rv, uv, lv = cf.Position, cf.RightVector, cf.UpVector, cf.LookVector
        local px, py, pz = p.X, p.Y, p.Z
        local r00, r01, r02 = rv.X, uv.X, -lv.X
        local r10, r11, r12 = rv.Y, uv.Y, -lv.Y
        local r20, r21, r22 = rv.Z, uv.Z, -lv.Z
        for _, e in ipairs(edges.edges) do
            local ax, ay, az = e[1], e[2], e[3]
            local bx, by, bz = e[4], e[5], e[6]
            self:_segment(px + r00 * ax + r01 * ay + r02 * az, py + r10 * ax + r11 * ay + r12 * az, pz + r20 * ax + r21 * ay + r22 * az,
                px + r00 * bx + r01 * by + r02 * bz, py + r10 * bx + r11 * by + r12 * bz, pz + r20 * bx + r21 * by + r22 * bz,
                color, 1.2)
        end
        return edges.hulls
    end
    local size = node.Size
    self:_box(cf, size.X / 2, size.Y / 2, size.Z / 2, color, 1)
    return 0
end

-- Live contacts of the last physics step: a square at each point and a
-- one-stud line along its normal
function Overlay:_contacts()
    local core = rawget(self.world, "_core")
    local physics = core and core._physics_world
    local cache = physics and physics.manifold_cache
    if not cache then return 0 end
    local step, count = physics.step_index, 0
    for _, m in ipairs(cache.list) do
        if m.last_step == step then
            for _, p in ipairs(m.points) do
                count = count + 1
                local s = 0.08
                self:_segment(p.px - s, p.py, p.pz, p.px + s, p.py, p.pz, COLORS.contact, 4)
                self:_segment(p.px, p.py - s, p.pz, p.px, p.py + s, p.pz, COLORS.contact, 4)
                self:_segment(p.px, p.py, p.pz, p.px + m.normal_x, p.py + m.normal_y, p.pz + m.normal_z, COLORS.normal, 1.5)
            end
        end
    end
    return count
end

---draw over the current frame. `focus` limits the wireframes to parts near
---a point (usually the player) within `radius` studs
function Overlay:draw(width, height, focus, radius, font)
    self:_begin(width, height)
    radius = radius or 70
    local drawn, hulls = 0, 0
    for _, node in ipairs(self.parts) do
        if node.Parent then
            local size = node.Size
            local reach = radius + math.max(size.X, size.Y, size.Z) * 0.5
            if not focus or (node.Position - focus).Magnitude < reach then
                hulls = hulls + self:_part(node)
                drawn = drawn + 1
                if not node.Anchored then
                    -- the moving body's broadphase bounds: its world AABB
                    local cf = node.CFrame
                    local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
                    local hx = math.abs(r.X) * size.X / 2 + math.abs(u.X) * size.Y / 2 + math.abs(l.X) * size.Z / 2
                    local hy = math.abs(r.Y) * size.X / 2 + math.abs(u.Y) * size.Y / 2 + math.abs(l.Y) * size.Z / 2
                    local hz = math.abs(r.Z) * size.X / 2 + math.abs(u.Z) * size.Y / 2 + math.abs(l.Z) * size.Z / 2
                    self:_box(self.rbx.CFrame.new(node.Position), hx, hy, hz, COLORS.bounds, 1)
                end
            end
        end
    end
    local contacts = self:_contacts()
    if self.count > 0 then
        if not self.mesh or self.capacity < self.count then
            if self.mesh then self.mesh:release() end
            self.capacity = math.max(self.count, (self.capacity or 0) * 2, 6000)
            self.mesh = love.graphics.newMesh({ { "VertexPosition", "float", 2 }, { "VertexTexCoord", "float", 2 },
                { "VertexColor", "float", 4 } }, self.capacity, "triangles", "stream")
        end
        self.mesh:setVertices(self.vertices, 1, self.count)
        self.mesh:setDrawRange(1, self.count)
        love.graphics.push("all")
        love.graphics.origin()
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(self.mesh)
        love.graphics.pop()
    end
    -- Summary panel
    local lines = { ("Collision: %d parts drawn, %d hulls, %d contacts"):format(drawn, hulls, contacts) }
    local keys = {}
    for key in pairs(self.summary or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local entry = self.summary[key]
        lines[#lines + 1] = ("  %-18s %4d parts %5d hulls"):format(key, entry.parts, entry.hulls)
    end
    lines[#lines + 1] = "  green authored, cyan cooked, yellow hull,"
    lines[#lines + 1] = "  orange authored box, grey box, white moving bounds"
    love.graphics.push("all")
    love.graphics.origin()
    if font then love.graphics.setFont(font) end
    local f = love.graphics.getFont()
    local w = 0
    for _, line in ipairs(lines) do w = math.max(w, f:getWidth(line)) end
    local h = #lines * f:getHeight()
    love.graphics.setColor(0.04, 0.05, 0.07, 0.7)
    love.graphics.rectangle("fill", 12, height - h - 28, w + 16, h + 12, 6, 6)
    love.graphics.setColor(0.95, 0.96, 0.98, 1)
    for index, line in ipairs(lines) do love.graphics.print(line, 20, height - h - 22 + (index - 1) * f:getHeight()) end
    love.graphics.pop()
    return { parts = drawn, hulls = hulls, contacts = contacts }
end

function Overlay:destroy()
    if self.mesh then self.mesh:release(); self.mesh = nil end
end

return Overlay
