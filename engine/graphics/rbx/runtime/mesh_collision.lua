-- prepare collision shapes when a map loads
-- use authored PhysicsData or PhysicalConfigData first, including explicit box shapes
-- otherwise CollisionFidelity selects a box, hull or cached convex decomposition
-- if a mesh cannot be prepared, keep its box and report the reason
local Cook = require("engine/graphics/rbx/collision_cook")
local Mesh = require("engine/graphics/rbx/mesh")

local M = {}

M.CACHE_DIRECTORY = "collision_cache"
local CACHE_MAGIC = "RBXCOLv1"

local MODES = { [0] = "Default", [1] = "Hull", [2] = "Box", [3] = "PreciseConvexDecomposition" }

local function sha(bytes) return love.data.encode("string", "hex", love.data.hash("sha256", bytes)) end

local function mode_name(value)
    if type(value) == "table" then value = value.Name or value.name or value.Value or value.value end
    if tonumber(value) then return MODES[tonumber(value)] or "Default" end
    local name = tostring(value or "Default"):match("([^%.]+)$")
    for _, known in pairs(MODES) do if known == name then return name end end
    return "Default"
end

local function is_csg(class) return class == "UnionOperation" or class == "PartOperation" or class == "NegateOperation" end

-------------------------------------------------------------------- disk cache

local function encode(hulls)
    local parts = { love.data.pack("string", "<c8I4", CACHE_MAGIC, #hulls) }
    for _, hull in ipairs(hulls) do
        parts[#parts + 1] = love.data.pack("string", "<I4I4", #hull.vertices / 3, #hull.faces)
        for i = 1, #hull.vertices do parts[#parts + 1] = love.data.pack("string", "<d", hull.vertices[i]) end
        for _, f in ipairs(hull.faces) do parts[#parts + 1] = love.data.pack("string", "<I2I2I2", f[1], f[2], f[3]) end
    end
    return table.concat(parts)
end

local function decode(bytes)
    local ok, result = pcall(function()
        local magic, count, offset = love.data.unpack("<c8I4", bytes)
        assert(magic == CACHE_MAGIC and count >= 1 and count <= 1024)
        local hulls = {}
        for h = 1, count do
            local vertex_count, face_count
            vertex_count, face_count, offset = love.data.unpack("<I4I4", bytes, offset)
            local hull = { vertices = {}, faces = {} }
            for i = 1, vertex_count * 3 do hull.vertices[i], offset = love.data.unpack("<d", bytes, offset) end
            for i = 1, face_count do
                local a, b, c
                a, b, c, offset = love.data.unpack("<I2I2I2", bytes, offset)
                hull.faces[i] = { a, b, c }
            end
            hulls[h] = hull
        end
        assert(offset == #bytes + 1)
        return hulls
    end)
    return ok and result or nil
end

local function read_cache(key)
    local path = M.CACHE_DIRECTORY .. "/" .. sha(key):sub(1, 40) .. ".bin"
    local bytes = love.filesystem.getInfo(path, "file") and love.filesystem.read(path)
    return bytes and decode(bytes) or nil, path
end

local function write_cache(path, hulls)
    love.filesystem.createDirectory(M.CACHE_DIRECTORY)
    return love.filesystem.write(path, encode(hulls))
end

-------------------------------------------------------------------- sources

-- the part's authored collision bytes: a supplied cooked payload in
-- PhysicsData first, then Roblox's PhysicalConfigData
local function authored_source(part)
    for _, field in ipairs({ "PhysicsData", "PhysicalConfigData" }) do
        local bytes = part[field]
        if type(bytes) == "string" and bytes ~= "" then return field, bytes end
    end
end

-- Authored hulls cleaned for the engine's checks: hulls, description and
-- the number of authored hulls that were degenerate, or "primitive" and its
-- token, or nil when the bytes hold neither
local function parse_authored(field, bytes)
    local parsed, _, failure = Mesh.parse(bytes, { accurate_face_axes = true })
    if parsed and parsed.physics_hulls then
        local hulls = {}
        for _, source in ipairs(parsed.physics_hulls) do
            local points = {}
            for i = 1, #source.vertices, 3 do
                points[#points + 1] = { source.vertices[i], source.vertices[i + 1], source.vertices[i + 2] }
            end
            local hull = Cook.clean_hull(points)
            if hull then hulls[#hulls + 1] = hull end
        end
        if #hulls > 0 then
            return hulls, ("authored %s v%s"):format(field, tostring(parsed.version)), #parsed.physics_hulls - #hulls
        end
    end
    if type(failure) == "table" and failure.primitive and failure.primitive ~= "" then
        return "primitive", failure.primitive
    end
end

-- Part-local triangle positions of the rendered mesh at the part's Size
local function mesh_positions(core, part)
    local parsed = core:_get_or_parse_part_mesh(part)
    if not parsed or not parsed.positions or #parsed.positions < 9 then return nil end
    local t = core:_get_mesh_render_transform(part, parsed)
    local positions = {}
    local source = parsed.positions
    for i = 1, #source, 3 do
        positions[i] = source[i] * t.local_scale_x
        positions[i + 1] = source[i + 1] * t.local_scale_y
        positions[i + 2] = source[i + 2] * t.local_scale_z
    end
    return positions, t
end

local function source_identity(core, part)
    if part.ClassName == "MeshPart" and type(part.MeshId) == "string" and part.MeshId ~= "" then
        local path = core:_resolve_asset_path(part.MeshId, "mesh")
        local bytes = path and love.filesystem.read(path)
        if bytes then return sha(bytes), "mesh" end
    end
    local embedded = part.EmbeddedMeshData
    if type(embedded) == "string" and embedded ~= "" then return sha(embedded), "part", "EmbeddedMeshData" end
    return nil
end

-------------------------------------------------------------------- prepare

local function warn(options, message)
    if options.on_warning then options.on_warning(message) else print("[collision] " .. message) end
end

---prepare collision for every MeshPart and union under `root`
---options.mode forces one fidelity for every part;
---options.ignore_authored cooks even where authored hulls exist
---@return table rows one per prepared part, for reports and the overlay
function M.prepare(world, root, options)
    options = options or {}
    local core = assert(rawget(world, "_core"))
    core._prepared_mesh_collision = core._prepared_mesh_collision or {}
    local memory = core._prepared_mesh_collision
    local rows = {}
    local nodes = { root }
    for _, node in ipairs(root:GetDescendants()) do nodes[#nodes + 1] = node end
    for index, node in ipairs(nodes) do
        local part = rawget(node, "_core_handle")
        local class = part and part.ClassName
        if part and (class == "MeshPart" or is_csg(class)) and not part._collision_decomposition then
            local collides = part.CanCollide ~= false
            local queried = part.CanQuery ~= false
            local mode = options.mode or mode_name(part.CollisionFidelity)
            local row = { path = node:GetFullName(), class = class, mode = mode, collides = collides }
            local field, bytes
            if not options.ignore_authored then field, bytes = authored_source(part) end
            local authored
            if field then
                -- Parts sharing authored bytes share one prepared cache
                local digest = sha(bytes)
                local key = digest .. "|authored|" .. field
                authored = memory[key]
                if not authored then
                    local disk_key = key .. "|clean-v" .. Cook.VERSION
                    local hulls, path = read_cache(disk_key)
                    local description, rejected = "authored " .. field, 0
                    if not hulls then
                        hulls, description, rejected = parse_authored(field, bytes)
                        if type(hulls) == "table" then write_cache(path, hulls) end
                    end
                    if hulls == "primitive" then
                        authored = { primitive = description }
                    elseif hulls then
                        local mesh_size = part.MeshSize
                        local reference = mesh_size and mesh_size.x and mesh_size.x > 0 and mesh_size or part.Size
                        authored = { handle = world:create_collision_decomposition_cache({
                            schema = 2, representation = "convex-components", component_count = #hulls,
                            coordinate_space = "mesh", mesh_sha256 = digest, source_kind = "part", source_field = field,
                            reference_size = { reference.x, reference.y, reference.z }, hulls = hulls,
                        }), components = #hulls, representation = description }
                        if rejected and rejected > 0 then
                            warn(options, ("%s: %d authored hulls were flat or degenerate and were skipped"):format(row.path, rejected))
                        end
                    else
                        authored = { unusable = true }
                        warn(options, ("%s: authored %s is empty; collision comes from the mesh instead"):format(row.path, field))
                    end
                    memory[key] = authored
                end
            end
            if authored and authored.primitive then
                row.representation = "authored primitive " .. tostring(authored.primitive)
            elseif authored and authored.handle then
                world:set_part_collision_decomposition(node, authored.handle)
                row.representation = authored.representation
                row.components = authored.components
            elseif collides and mode ~= "Box" then
                -- only colliding parts are cooked, a query-only part keeps its box
                local identity, source_kind, source_field = source_identity(core, part)
                local positions, transform = mesh_positions(core, part)
                if not identity or not positions then
                    row.representation = "box (no mesh geometry)"
                    warn(options, ("%s: %s collision needs mesh geometry that is unavailable; it collides as its box")
                        :format(row.path, mode))
                else
                    local size = part.Size
                    local params = mode == "Hull" and "hull" or Cook.PRESETS[mode] and mode or "Default"
                    local key = table.concat({ identity, mode, string.format("%.9g,%.9g,%.9g",
                        transform.local_scale_x, transform.local_scale_y, transform.local_scale_z),
                        "cook-v" .. Cook.VERSION }, "|")
                    local cached = memory[key]
                    if not cached then
                        local cooked, path = read_cache(key)
                        local seconds = 0
                        if not cooked then
                            local started = love.timer.getTime()
                            if params == "hull" then
                                local points = {}
                                for i = 1, #positions, 3 do points[#points + 1] = { positions[i], positions[i + 1], positions[i + 2] } end
                                local hull = Cook.clean_hull(points)
                                cooked = hull and { hull } or nil
                            else
                                local ok, result = pcall(Cook.decompose, positions, params)
                                cooked = ok and result or nil
                                if not ok then warn(options, ("%s: decomposition failed (%s)"):format(row.path, tostring(result))) end
                            end
                            seconds = love.timer.getTime() - started
                            if cooked and #cooked > 0 then write_cache(path, cooked) end
                        end
                        if cooked and #cooked > 0 then
                            cached = { handle = world:create_collision_decomposition_cache({
                                schema = 2, representation = "convex-components", component_count = #cooked,
                                coordinate_space = "mesh", mesh_sha256 = identity, source_kind = source_kind,
                                source_field = source_field, reference_size = { size.x, size.y, size.z }, hulls = cooked,
                            }), components = #cooked, seconds = seconds }
                            memory[key] = cached
                        end
                    end
                    if cached then
                        world:set_part_collision_decomposition(node, cached.handle)
                        row.representation = (mode == "Hull" and "convex hull" or "cooked " .. mode)
                        row.components = cached.components
                        row.seconds = cached.seconds
                    else
                        row.representation = "box (cooking failed)"
                        warn(options, ("%s: %s collision could not be cooked; it collides as its box"):format(row.path, mode))
                    end
                end
            else
                row.representation = collides and "box" or "box (query only)"
            end
            rows[#rows + 1] = row
        end
        if options.checkpoint then options.checkpoint("collision:part", index, #nodes) end
    end
    return rows
end

return M
