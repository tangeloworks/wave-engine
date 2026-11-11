-- pure retained-geometry accounting shared by the remote worker and manager
--
-- v4+ FileMesh results can own several independently flattened render streams
-- LOD0 intentionally aliases the top-level arrays, so counting mesh tables (or
-- trusting only top-level vertex_count) either double-counts aliases or misses
-- every lower LOD. this helper counts unique vertex and triangle streams by
-- their retained array identity and performs no per-element traversal

local Accounting = {}

local MAX_RETAINED_STREAMS = 4096

local function checked_count(value)
    if value == nil then return nil, true end
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric or numeric == math.huge
        or numeric == -math.huge or numeric < 0 then
        return nil, false
    end
    return math.floor(numeric), true
end

local function array_triangle_count(value)
    if type(value) ~= "table" then return nil end
    if #value > 0 and type(value[1]) == "table" then
        return #value
    end
    return math.floor(#value / 3)
end

local function larger_stream(first_array, first_count,
        second_array, second_count)
    if second_count ~= nil
        and (first_count == nil or second_count > first_count) then
        return second_array, second_count
    end
    return first_array, first_count
end

local function stream_counts(stream)
    local declared_vertices, vertices_valid =
        checked_count(stream.vertex_count)
    if not vertices_valid then
        return nil, nil, nil, nil, "invalid_vertex_count"
    end
    local declared_triangles, triangles_valid =
        checked_count(stream.triangle_count)
    if not triangles_valid then
        return nil, nil, nil, nil, "invalid_triangle_count"
    end

    local positions = type(stream.positions) == "table"
        and stream.positions or nil
    local vertices = type(stream.vertices) == "table"
        and stream.vertices or nil
    -- accept both canonical flattened `positions` and manager-injected
    -- `vertices`, but do not let an empty preferred field mask a populated
    -- fallback representation
    local vertex_array, derived_vertices = larger_stream(
        positions, positions and math.floor(#positions / 3) or nil,
        vertices, vertices and #vertices or nil)
    local vertex_count = math.max(
        declared_vertices or 0, derived_vertices or 0)

    local indices = type(stream.indices) == "table"
        and stream.indices or nil
    local faces = type(stream.faces) == "table"
        and stream.faces or nil
    local triangle_array, derived_triangles = larger_stream(
        indices, array_triangle_count(indices),
        faces, array_triangle_count(faces))
    if (derived_triangles or 0) == 0 and vertex_array then
        -- Canonical RBX `positions` and manager-test `vertices` are both
        -- flattened triangle streams after decode
        local flattened_triangles = vertex_array == positions
            and math.floor(#vertex_array / 9)
            or math.floor(#vertex_array / 3)
        if flattened_triangles > 0 then
            triangle_array, derived_triangles =
                vertex_array, flattened_triangles
        end
    end
    local triangle_count = math.max(
        declared_triangles or 0, derived_triangles or 0)

    return vertex_count, triangle_count,
        vertex_array or stream, triangle_array or vertex_array or stream
end

---collects counts and the new identity keys without mutating the supplied seen
---sets. Callers can reject an over-budget graph atomically, then commit keys
function Accounting.collect(decoded, seen_vertex_streams, seen_triangle_streams)
    if type(decoded) ~= "table" then
        return nil, nil, nil, nil, "decoded_not_table"
    end
    seen_vertex_streams = seen_vertex_streams or {}
    seen_triangle_streams = seen_triangle_streams or {}
    local local_vertices, local_triangles = {}, {}
    local new_vertex_keys, new_triangle_keys = {}, {}
    local vertex_total, triangle_total = 0, 0
    local stream_count = 0

    local function account(stream)
        if type(stream) ~= "table" then return true end
        stream_count = stream_count + 1
        if stream_count > MAX_RETAINED_STREAMS then
            return false, "retained_stream_limit"
        end
        local vertices, triangles, vertex_key, triangle_key, reason =
            stream_counts(stream)
        if reason then return false, reason end
        if not seen_vertex_streams[vertex_key]
            and not local_vertices[vertex_key] then
            local_vertices[vertex_key] = true
            new_vertex_keys[#new_vertex_keys + 1] = vertex_key
            vertex_total = vertex_total + vertices
        end
        if not seen_triangle_streams[triangle_key]
            and not local_triangles[triangle_key] then
            local_triangles[triangle_key] = true
            new_triangle_keys[#new_triangle_keys + 1] = triangle_key
            triangle_total = triangle_total + triangles
        end
        return true
    end

    local ok, reason = account(decoded)
    if not ok then return nil, nil, nil, nil, reason end
    local lods = decoded.render_lods
    if type(lods) == "table" then
        for index = 1, #lods do
            ok, reason = account(lods[index])
            if not ok then return nil, nil, nil, nil, reason end
        end
    end
    return vertex_total, triangle_total,
        new_vertex_keys, new_triangle_keys
end

function Accounting.commit(seen_vertex_streams, seen_triangle_streams,
        new_vertex_keys, new_triangle_keys)
    for index = 1, #(new_vertex_keys or {}) do
        seen_vertex_streams[new_vertex_keys[index]] = true
    end
    for index = 1, #(new_triangle_keys or {}) do
        seen_triangle_streams[new_triangle_keys[index]] = true
    end
end

Accounting.max_retained_streams = MAX_RETAINED_STREAMS

return Accounting
