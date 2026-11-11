local util = require("engine/graphics/rbx/util")

local bitops = util.make_bitops()
local band = bitops.band
local bxor = bitops.bxor
local lshift = bitops.lshift

local mesh = {}

-- FileMeshLodType values whose range ordering/cost semantics are understood by
-- this renderer. `None` (0), `Unknown` (1), and future enum values remain
-- diagnostic metadata only, they must never silently opt into runtime LOD
local SUPPORTED_RUNTIME_LOD_TYPES = {
    [2] = "RbxSimplifier",
    [3] = "ZeuxMeshOptimizer",
}
local MAX_RUNTIME_RENDER_LODS = 64

local Reader = {}
Reader.__index = Reader

local CSG_OBFUSCATION_XOR = {
    86, 46, 110, 88, 49, 32, 48, 4, 52, 105, 12, 119, 12, 1, 94, 0,
    26, 96, 55, 105, 29, 82, 43, 7, 79, 36, 89, 101, 83, 4, 122,
}

function Reader.new(data)
    return setmetatable({
        data = data or "",
        pos = 1,
        len = #(data or ""),
    }, Reader)
end

function Reader:remaining()
    return self.len - self.pos + 1
end

function Reader:can_read(count)
    count = tonumber(count) or 0
    return count <= 0 or self:remaining() >= count
end

function Reader:skip(count)
    self.pos = math.min(self.len + 1, self.pos + (count or 0))
end

function Reader:read_string(count)
    if not count or count <= 0 then
        return ""
    end
    local last = math.min(self.len, self.pos + count - 1)
    local value = self.data:sub(self.pos, last)
    self.pos = last + 1
    return value
end

function Reader:uint8()
    local value = self.data:byte(self.pos) or 0
    self.pos = self.pos + 1
    return value
end

function Reader:int8()
    local value = self:uint8()
    return value >= 128 and (value - 256) or value
end

function Reader:uint16_le()
    local a = self:uint8()
    local b = self:uint8()
    return a + (b * 256)
end

function Reader:uint32_le()
    local a = self:uint8()
    local b = self:uint8()
    local c = self:uint8()
    local d = self:uint8()
    return a + (b * 256) + (c * 65536) + (d * 16777216)
end

function Reader:float32_le()
    local value
    value, self.pos = love.data.unpack("<f", self.data, self.pos)
    return value
end

local function trim(text)
    return util.trim(text)
end

-- (starts_with/safe_lower prefix matching on the version line is gone: version
-- dispatch now goes through read_mesh_version + MESH_FORMATS so an unknown version
-- gets its own diagnosis instead of silently falling into the CSG probes.)

--------------------------------------------------------------------- diagnostics
--
-- every failure path returns (nil, message, info). `info.code` is a STABLE slug and
-- there is exactly one per distinct failure mode
--
-- why: before this, ~15 structurally different rejections (truncated vertex block,
-- out-of-range face index, unsupported container version, CSGK reference-only blob,
-- ...) all surfaced as one of two prose strings -- "unsupported mesh payload" or a
-- bare nil -- which no caller read. the part then silently fell back to rendering as
-- a Block, which is indistinguishable from "this union really is a box". a code lets
-- the renderer tally and report them (RBX._mesh_decode_report) instead
--
---@param code string      stable slug, e.g. "mesh_v2_truncated_vertices"
---@param message string   human-readable, safe to print
---@param extra table|nil  merged into info; conventional keys: format, version, stage
local function fail(code, message, extra)
    local info = { code = code, message = message }
    if extra then
        for key, value in pairs(extra) do
            info[key] = value
        end
    end
    return nil, message, info
end

-- Roblox .mesh container versions, keyed "<major>.<minor as 2 digits>"
--
-- readers:
--   v1  ASCII vector triples. 1.00 stores studs*2 (hence scale 0.5), 1.01 stores studs
--   v2  binary with self-describing vertex/face strides (2.00, 3.00, 3.01)
--   v4  binary, fixed 40-byte vertex, LOD/bone/subset tables (4.00, 4.01)
--   v5  v4 plus the FACS block (5.00)
--   v6  UNVERIFIED -- see mesh.MESH_FORMATS["6.00"].verified below
--
-- anything NOT in this table is reported as `mesh_version_unrecognised` with the
-- version echoed, instead of falling through to the CSG probes and ending as the
-- generic "unsupported mesh payload"
local MESH_FORMATS = {
    ["1.00"] = { reader = "v1", scale = 0.5, verified = true },
    ["1.01"] = { reader = "v1", scale = 1.0, verified = true },
    ["2.00"] = { reader = "v2", verified = true },
    ["3.00"] = { reader = "v2", verified = false },
    ["3.01"] = { reader = "v2", verified = false },
    ["4.00"] = { reader = "v4", verified = false },
    ["4.01"] = { reader = "v4", verified = false },
    ["5.00"] = { reader = "v5", verified = false },
    -- 6.00 is read with the 5.00 header reader. That reader is HEADER-SIZE DRIVEN
    -- (it seeks from the LF-terminated version line by header_size), so appended header
    -- fields cost nothing. what it cannot know is whether 6.00 changed the 40-byte
    -- vertex or the 12-byte face record: there is no 6.00 file in assets/rbx/asset,
    -- and rbx-dom's vendored spec documents the .rbxl CONTAINER only -- it contains
    -- no mesh-format material at all (verified by full-text grep). So this is
    -- inference, and it is fenced: every structural check still runs, and a layout
    -- mismatch surfaces as `mesh_v6_layout_unverified` rather than as garbage
    -- geometry or a silent Block
    ["6.00"] = { reader = "v6", verified = false },
}

---reads the "version X.YY" line that opens every Roblox .mesh payload
---@return string|nil version_key  normalised "<major>.<minor2>", nil if not a .mesh
---@return table|nil format        MESH_FORMATS entry, nil when the version is unknown
local function read_mesh_version(data)
    local major, minor = data:match("^[Vv][Ee][Rr][Ss][Ii][Oo][Nn]%s+(%d+)%.(%d+)")
    if not major then
        return nil
    end
    local key = string.format("%d.%02d", tonumber(major), tonumber(minor))
    return key, MESH_FORMATS[key]
end

local MAX_BINARY_MESH_VERSION_LINE_BYTES = 64

---Locates and validates the LF-terminated version line of a binary .mesh
---the serialized header begins after LF, not at a fixed byte offset: canonical
---payloads use LF while some valid exporters use CRLF. Bounding the scan prevents
---an unterminated or attacker-sized prefix from being mistaken for binary header
---bytes merely because one of those bytes happens to equal LF later in the file
local function locate_binary_mesh_body_start(data, expected_version)
    local lf = type(data) == "string"
        and data:find("\n", 1, true)
        or nil
    if not lf then
        return nil, "version line has no LF terminator"
    end
    if lf > MAX_BINARY_MESH_VERSION_LINE_BYTES then
        return nil, string.format(
            "version line terminator lies past the %d-byte limit",
            MAX_BINARY_MESH_VERSION_LINE_BYTES)
    end

    local line = data:sub(1, lf - 1)
    if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
    end
    local major, minor = line:match(
        "^[Vv][Ee][Rr][Ss][Ii][Oo][Nn][ \t]+(%d+)%.(%d+)[ \t]*$")
    if not major then
        return nil, "version line contains unexpected bytes"
    end
    local actual_version =
        string.format("%d.%02d", tonumber(major), tonumber(minor))
    if actual_version ~= expected_version then
        return nil, string.format(
            "version line identifies %s, expected %s",
            actual_version, tostring(expected_version))
    end
    return lf + 1
end

local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function dot(ax, ay, az, bx, by, bz)
    return ax * bx + ay * by + az * bz
end

local function normalize_or_fallback(x, y, z, fx, fy, fz)
    local len = math.sqrt(x * x + y * y + z * z)
    if len <= 1e-8 then
        return fx or 0, fy or 1, fz or 0
    end
    return x / len, y / len, z / len
end

local function binary_mesh_faces_are_valid(faces, vertex_count)
    vertex_count = math.floor(tonumber(vertex_count) or 0)
    if vertex_count <= 0 then
        return false, "empty mesh"
    end
    for face_index = 1, #(faces or {}) do
        local face = faces[face_index]
        if type(face) ~= "table" then
            return false, "missing face"
        end
        for corner = 1, 3 do
            local index = tonumber(face[corner])
            if index == nil or index < 1 or index > vertex_count then
                return false, "index value out of range"
            end
        end
    end
    return true
end

local function append_metadata_issue(issues, code, message, extra)
    local issue = {
        code = code,
        message = message,
    }
    if extra then
        for key, value in pairs(extra) do
            issue[key] = value
        end
    end
    issues[#issues + 1] = issue
    return issue
end

---normalises the serialized v4+ LOD boundary table without choosing a new LOD
---
---the payload stores FACE OFFSETS, not Lua indices: values are zero-based and the
---end of a range is exclusive. The Lua-facing range also carries explicit one-based
---inclusive fields so a later renderer cannot accidentally apply the offset twice
---invalid boundaries are retained for diagnostics, but are never trusted to truncate
---geometry, malformed optional metadata must not turn otherwise readable faces into
---a missing mesh
local function normalize_v4_lod_metadata(raw_offsets, num_faces, lod_type, lod_hq_count)
    raw_offsets = raw_offsets or {}
    num_faces = math.max(0, math.floor(tonumber(num_faces) or 0))
    local issues = {}
    local ranges = {}
    local offsets = {}

    for index = 1, #raw_offsets do
        offsets[index] = math.floor(tonumber(raw_offsets[index]) or -1)
    end

    if #offsets == 1 then
        append_metadata_issue(issues, "lod_missing_range_end",
            "LOD boundary table has one offset and therefore describes no range")
    elseif #offsets > 1 and offsets[1] ~= 0 then
        append_metadata_issue(issues, "lod_first_offset_not_zero",
            "first LOD face offset is not zero", {
                offset_zero_based = offsets[1],
            })
    end

    for index = 1, math.max(0, #offsets - 1) do
        local start_zero = offsets[index]
        local finish_zero = offsets[index + 1]
        local range_issues = {}
        if start_zero < 0 or start_zero > num_faces then
            append_metadata_issue(range_issues, "lod_start_out_of_bounds",
                "LOD start face offset lies outside the encoded face table", {
                    offset_zero_based = start_zero,
                    encoded_face_count = num_faces,
                })
        end
        if finish_zero < 0 or finish_zero > num_faces then
            append_metadata_issue(range_issues, "lod_end_out_of_bounds",
                "LOD end face offset lies outside the encoded face table", {
                    offset_zero_based = finish_zero,
                    encoded_face_count = num_faces,
                })
        end
        if finish_zero < start_zero then
            append_metadata_issue(range_issues, "lod_offsets_not_monotonic",
                "LOD end face offset precedes its start", {
                    start_zero_based = start_zero,
                    finish_zero_based = finish_zero,
                })
        elseif finish_zero == start_zero then
            append_metadata_issue(range_issues, "lod_range_empty",
                "LOD range contains no faces", {
                    offset_zero_based = start_zero,
                })
        end

        local valid = #range_issues == 0
        local face_count = valid and (finish_zero - start_zero) or 0
        ranges[index] = {
            -- Array/index conventions are deliberately named at every boundary
            lua_index = index,
            lod_index_zero_based = index - 1,
            face_start_zero_based = start_zero,
            face_end_exclusive_zero_based = finish_zero,
            first_face_one_based = valid and (start_zero + 1) or nil,
            last_face_one_based = valid and finish_zero or nil,
            face_count = face_count,
            valid = valid,
            issues = range_issues,
        }
        for issue_index = 1, #range_issues do
            local issue = range_issues[issue_index]
            issue.lod_index_zero_based = index - 1
            issues[#issues + 1] = issue
        end
    end

    if #offsets > 1 and offsets[#offsets] ~= num_faces then
        append_metadata_issue(issues, "lod_last_offset_not_face_count",
            "last LOD face offset does not equal the encoded face count", {
                offset_zero_based = offsets[#offsets],
                encoded_face_count = num_faces,
            })
    end
    if (tonumber(lod_hq_count) or 0) > #ranges then
        append_metadata_issue(issues, "lod_hq_count_out_of_bounds",
            "high-quality LOD count exceeds the number of decoded ranges", {
                high_quality_count = tonumber(lod_hq_count) or 0,
                range_count = #ranges,
            })
    end

    local valid = #issues == 0
    local first_range = ranges[1]
    local first_range_usable = first_range ~= nil
        and first_range.valid == true
        and first_range.face_start_zero_based == 0
    local normalized_lod_type = math.floor(tonumber(lod_type) or 0)
    local runtime_selection_reason
    if not valid then
        runtime_selection_reason = "lod_metadata_invalid"
    elseif #ranges <= 1 then
        runtime_selection_reason = "lod_range_count_insufficient"
    elseif #ranges > MAX_RUNTIME_RENDER_LODS then
        runtime_selection_reason = "lod_range_count_unsupported"
    elseif not SUPPORTED_RUNTIME_LOD_TYPES[normalized_lod_type] then
        runtime_selection_reason = "lod_type_unsupported"
    else
        local previous_cost = math.huge
        for index = 1, #ranges do
            local cost = tonumber(ranges[index].face_count) or 0
            if cost > previous_cost then
                runtime_selection_reason = "lod_cost_not_non_increasing"
                break
            end
            previous_cost = cost
        end
    end
    return {
        source_index_base = 0,
        lua_index_base = 1,
        offset_unit = "face",
        range_end = "exclusive",
        lod_type = normalized_lod_type,
        lod_type_name = SUPPORTED_RUNTIME_LOD_TYPES[normalized_lod_type],
        high_quality_count = math.floor(tonumber(lod_hq_count) or 0),
        offsets_zero_based = offsets,
        ranges = ranges,
        valid = valid,
        issues = issues,
        -- Parsing continues to materialise the same first (highest-detail) range
        -- that the old decoder emitted. Projected-size selection belongs to the
        -- renderer and is intentionally not enabled by this metadata-only change
        runtime_selection_enabled = false,
        runtime_selection_supported = runtime_selection_reason == nil,
        runtime_selection_reason = runtime_selection_reason,
        geometry_lod_index_zero_based = first_range_usable and 0 or nil,
    }
end

---normalises one serialized 72-byte MeshSubset table
---
---MeshSubset is a face/vertex and skinning-palette partition. the record contains no
---material id, `partition_index_zero_based` preserves its serialized ordinal without
---claiming a material mapping the bytes do not provide
local function normalize_v4_subset_metadata(raw_subsets, num_faces, num_verts, bone_count)
    raw_subsets = raw_subsets or {}
    num_faces = math.max(0, math.floor(tonumber(num_faces) or 0))
    num_verts = math.max(0, math.floor(tonumber(num_verts) or 0))
    bone_count = math.max(0, math.floor(tonumber(bone_count) or 0))
    local records = {}
    local issues = {}

    for index = 1, #raw_subsets do
        local raw = raw_subsets[index]
        local face_start = math.floor(tonumber(raw.face_start_zero_based) or -1)
        local face_count = math.floor(tonumber(raw.face_count) or -1)
        local vertex_start = math.floor(tonumber(raw.vertex_start_zero_based) or -1)
        local vertex_count = math.floor(tonumber(raw.vertex_count) or -1)
        local bone_index_count = math.floor(tonumber(raw.bone_index_count) or -1)
        local face_finish = face_start + math.max(face_count, 0)
        local vertex_finish = vertex_start + math.max(vertex_count, 0)
        local record_issues = {}

        if face_start < 0 or face_count < 0 or face_finish > num_faces then
            append_metadata_issue(record_issues, "subset_face_range_out_of_bounds",
                "mesh subset face range lies outside the encoded face table", {
                    face_start_zero_based = face_start,
                    face_count = face_count,
                    encoded_face_count = num_faces,
                })
        end
        if vertex_start < 0 or vertex_count < 0 or vertex_finish > num_verts then
            append_metadata_issue(record_issues, "subset_vertex_range_out_of_bounds",
                "mesh subset vertex range lies outside the encoded vertex table", {
                    vertex_start_zero_based = vertex_start,
                    vertex_count = vertex_count,
                    encoded_vertex_count = num_verts,
                })
        end
        if bone_index_count < 0 or bone_index_count > 26 then
            append_metadata_issue(record_issues, "subset_bone_index_count_out_of_bounds",
                "mesh subset bone palette count exceeds its 26 serialized slots", {
                    bone_index_count = bone_index_count,
                })
        end

        local raw_bone_indices = {}
        local active_bone_indices = {}
        for bone_index = 1, 26 do
            local value = math.floor(tonumber(raw.bone_indices_zero_based
                and raw.bone_indices_zero_based[bone_index]) or 0)
            raw_bone_indices[bone_index] = value
            if bone_index <= math.min(math.max(bone_index_count, 0), 26) then
                active_bone_indices[#active_bone_indices + 1] = value
                if value < 0 or value >= bone_count then
                    append_metadata_issue(record_issues, "subset_bone_index_out_of_bounds",
                        "mesh subset bone palette entry lies outside the bone table", {
                            palette_slot_zero_based = bone_index - 1,
                            bone_index_zero_based = value,
                            encoded_bone_count = bone_count,
                        })
                end
            end
        end

        local valid = #record_issues == 0
        records[index] = {
            lua_index = index,
            partition_index_zero_based = index - 1,
            face_start_zero_based = face_start,
            face_end_exclusive_zero_based = face_finish,
            first_face_one_based = valid and face_count > 0 and (face_start + 1) or nil,
            last_face_one_based = valid and face_count > 0 and face_finish or nil,
            face_count = face_count,
            vertex_start_zero_based = vertex_start,
            vertex_end_exclusive_zero_based = vertex_finish,
            first_vertex_one_based = valid and vertex_count > 0 and (vertex_start + 1) or nil,
            last_vertex_one_based = valid and vertex_count > 0 and vertex_finish or nil,
            vertex_count = vertex_count,
            bone_index_count = bone_index_count,
            bone_indices_zero_based = active_bone_indices,
            raw_bone_indices_zero_based = raw_bone_indices,
            valid = valid,
            issues = record_issues,
        }
        for issue_index = 1, #record_issues do
            local issue = record_issues[issue_index]
            issue.partition_index_zero_based = index - 1
            issues[#issues + 1] = issue
        end
    end

    return {
        source_index_base = 0,
        lua_index_base = 1,
        face_offset_unit = "face",
        vertex_offset_unit = "vertex",
        bone_index_base = 0,
        range_end = "exclusive",
        has_serialized_material_index = false,
        records = records,
        valid = #issues == 0,
        issues = issues,
    }
end

local function collect_binary_mesh_geometry_range(mesh_vertices, faces,
        first_face_zero_based, end_face_zero_based)
    first_face_zero_based = math.max(0, math.floor(
        tonumber(first_face_zero_based) or 0))
    end_face_zero_based = math.min(#faces, math.max(first_face_zero_based,
        math.floor(tonumber(end_face_zero_based) or #faces)))
    local positions, normals, uvs, colors, normal_ids, tangents = {}, {}, {}, {}, {}, {}
    local has_normal_ids = false
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    -- Decide ONCE, up front, whether this mesh has any real tangent, instead of
    -- flipping a flag mid-emit
    --
    -- the old form only appended a tangent when `vertex.tx ~= nil` OR the flag was
    -- already set, so a mesh whose FIRST vertices carried no tangent and whose later
    -- ones did produced a tangent array shorter than 4 per emitted vertex -- silently
    -- misaligning every tangent after that point. an O(V) prepass makes the emit loop
    -- branch on a loop-invariant instead, which also keeps the body small enough to
    -- stay JIT-compiled
    local has_tangents = false
    local has_vertex_colors = false
    for index = 1, #mesh_vertices do
        local vertex = mesh_vertices[index]
        if vertex.tx ~= nil then
            has_tangents = true
        end
        if vertex.r ~= nil then
            has_vertex_colors = true
        end
        if has_tangents and has_vertex_colors then
            break
        end
    end

    for face_index = first_face_zero_based + 1, end_face_zero_based do
        local face = faces[face_index]
        for i = 1, 3 do
            local vertex = mesh_vertices[face[i]]
            if vertex then
                positions[#positions + 1] = vertex.px
                positions[#positions + 1] = vertex.py
                positions[#positions + 1] = vertex.pz
                normals[#normals + 1] = vertex.nx
                normals[#normals + 1] = vertex.ny
                normals[#normals + 1] = vertex.nz
                uvs[#uvs + 1] = vertex.u
                uvs[#uvs + 1] = vertex.v
                if has_vertex_colors then
                    colors[#colors + 1] = vertex.r or 1
                    colors[#colors + 1] = vertex.g or 1
                    colors[#colors + 1] = vertex.b or 1
                    colors[#colors + 1] = vertex.a or 1
                end
                if has_tangents then
                    tangents[#tangents + 1] = vertex.tx or 0
                    tangents[#tangents + 1] = vertex.ty or 0
                    tangents[#tangents + 1] = vertex.tz or -1
                    tangents[#tangents + 1] = vertex.tw or 1
                end
                if vertex.normal_id ~= nil then
                    normal_ids[#normal_ids + 1] = math.floor(vertex.normal_id or 0)
                    has_normal_ids = true
                elseif has_normal_ids then
                    normal_ids[#normal_ids + 1] = 0
                end

                min_x = math.min(min_x, vertex.px)
                min_y = math.min(min_y, vertex.py)
                min_z = math.min(min_z, vertex.pz)
                max_x = math.max(max_x, vertex.px)
                max_y = math.max(max_y, vertex.py)
                max_z = math.max(max_z, vertex.pz)
            end
        end
    end

    if #positions == 0 then
        return nil
    end

    return {
        positions = positions,
        normals = normals,
        uvs = uvs,
        colors = #colors > 0 and colors or nil,
        normal_ids = has_normal_ids and normal_ids or nil,
        tangents = has_tangents and tangents or nil,
        -- the output is a flattened triangle stream. LOD cutoffs may retain
        -- fewer faces than the encoded table, so report the indices that were
        -- actually emitted rather than the raw face-array capacity
        index_count = math.floor(#positions / 3),
        bounds = {
            min_x = min_x,
            min_y = min_y,
            min_z = min_z,
            max_x = max_x,
            max_y = max_y,
            max_z = max_z,
        },
    }
end

local function collect_binary_mesh_geometry(mesh_vertices, faces, lods)
    return collect_binary_mesh_geometry_range(
        mesh_vertices, faces, 0, lods and lods[2] or #faces)
end

local function alias_binary_mesh_geometry_range(parsed, range, range_index)
    return {
        positions = parsed.positions,
        normals = parsed.normals,
        uvs = parsed.uvs,
        colors = parsed.colors,
        normal_ids = parsed.normal_ids,
        tangents = parsed.tangents,
        bounds = parsed.bounds,
        index_count = parsed.index_count,
        lod_index_zero_based =
            range.lod_index_zero_based or (range_index - 1),
        face_count = range.face_count,
        source_face_start_zero_based = range.face_start_zero_based,
        source_face_end_exclusive_zero_based =
            range.face_end_exclusive_zero_based,
    }
end

local function read_binary_mesh_vertex(reader, vertex_size)
    local vertex = {
        px = reader:float32_le(),
        py = reader:float32_le(),
        pz = reader:float32_le(),
        nx = reader:float32_le(),
        ny = reader:float32_le(),
        nz = reader:float32_le(),
        u = reader:float32_le(),
        v = reader:float32_le(),
        -- Color is an optional serialized channel (stride >= 40), not an
        -- implicit white channel. keeping absent colors nil avoids expanding
        -- four redundant Lua numbers per emitted vertex for common 32/36-byte
        -- v2/v3 layouts
        r = nil,
        g = nil,
        b = nil,
        a = nil,
        tx = nil,
        ty = nil,
        tz = nil,
        tw = nil,
    }

    local consumed = 32
    if vertex_size >= 36 then
        local tx = reader:int8()
        local ty = reader:int8()
        local tz = reader:int8()
        local tw = reader:int8()
        consumed = 36
        if tx == 0 and ty == 0 and tz == 0 and tw == 0 then
            -- FOUR ZERO BYTES MEAN "NO TANGENT", not "the tangent is the zero
            -- vector". a zero tangent cannot be normalised, so it can never build a
            -- TBN frame -- it is the absence marker every exporter that does not
            -- compute tangents writes. Measured on assets/rbx/asset: 53 mesh payloads
            -- reach this branch and 52 of them are all-zero for every vertex. Calling
            -- those "has tangents" cost all 52 their projected-UV instancing
            -- (scene.lua `projected_uv_has_tangents`) in exchange for a tangent
            -- attribute made entirely of zeros
            --
            -- the 0x80808080 form below (-128 four times) is Roblox's own explicit
            -- sentinel and is deliberately treated DIFFERENTLY: it is remapped to the
            -- documented default tangent rather than dropped, because that is the
            -- long-standing behaviour and no payload in this corpus exercises it, so
            -- there is nothing to verify a change against
            vertex.tx, vertex.ty, vertex.tz, vertex.tw = nil, nil, nil, nil
        else
            if tx == -128 and ty == -128 and tz == -128 and tw == -128 then
                tx, ty, tz, tw = 0, 0, -128, 127
            end
            vertex.tx = math.max(-1, math.min(1, tx / 127))
            vertex.ty = math.max(-1, math.min(1, ty / 127))
            vertex.tz = math.max(-1, math.min(1, tz / 127))
            vertex.tw = tw < 0 and -1 or 1
        end
    end

    if vertex_size >= 40 then
        vertex.r = reader:uint8() / 255
        vertex.g = reader:uint8() / 255
        vertex.b = reader:uint8() / 255
        vertex.a = reader:uint8() / 255
        consumed = 40
    end

    if vertex_size > consumed then
        reader:skip(vertex_size - consumed)
    end

    return vertex
end

local function read_binary_mesh_faces(reader, num_faces, face_size)
    local faces = {}
    for _ = 1, num_faces do
        faces[#faces + 1] = {
            (reader:uint32_le() or 0) + 1,
            (reader:uint32_le() or 0) + 1,
            (reader:uint32_le() or 0) + 1,
        }
        if face_size > 12 then
            reader:skip(face_size - 12)
        end
    end
    return faces
end

---@param scale number  1.00 stores studs*2, 1.01 stores studs (MESH_FORMATS)
local function parse_version_1_mesh(data, scale)
    scale = scale or 1.0
    local body = data:match("^[^\r\n]*[\r\n]+(.*)$") or ""
    local first_body_line = trim(body:match("^([^\r\n]*)") or "")
    local declared_face_count = first_body_line:match("^%d+$") and tonumber(first_body_line) or nil
    local positions, normals, uvs = {}, {}, {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    for p1, p2, p3, n1, n2, n3, u1, u2 in data:gmatch("%[([^,%]]+),([^,%]]+),([^%]]+)%]%[([^,%]]+),([^,%]]+),([^%]]+)%]%[([^,%]]+),([^,%]]+),([^%]]+)%]") do
        local px = (tonumber(p1) or 0) * scale
        local py = (tonumber(p2) or 0) * scale
        local pz = (tonumber(p3) or 0) * scale
        positions[#positions + 1] = px
        positions[#positions + 1] = py
        positions[#positions + 1] = pz
        normals[#normals + 1] = tonumber(n1) or 0
        normals[#normals + 1] = tonumber(n2) or 0
        normals[#normals + 1] = tonumber(n3) or 0
        uvs[#uvs + 1] = tonumber(u1) or 0
        uvs[#uvs + 1] = 1 - (tonumber(u2) or 0)

        min_x = math.min(min_x, px)
        min_y = math.min(min_y, py)
        min_z = math.min(min_z, pz)
        max_x = math.max(max_x, px)
        max_y = math.max(max_y, py)
        max_z = math.max(max_z, pz)
    end

    if #positions == 0 then
        return fail("mesh_v1_no_vertices",
            "mesh 1.x: body holds no [x,y,z][nx,ny,nz][u,v,w] triples",
            { format = "mesh", stage = "body" })
    end

    if declared_face_count ~= nil and declared_face_count * 9 ~= #positions then
        return fail("mesh_v1_face_count_mismatch", string.format(
            "mesh 1.x: header declares %d faces (%d vertices) but the body holds %d",
            declared_face_count, declared_face_count * 3, math.floor(#positions / 3)),
            {
                format = "mesh",
                stage = "body",
                declared_face_count = declared_face_count,
                actual_vertex_count = math.floor(#positions / 3),
            })
    end

    return {
        positions = positions,
        normals = normals,
        uvs = uvs,
        index_count = math.floor(#positions / 3),
        declared_face_count = declared_face_count,
        uv_transform = {
            flip_u = false,
            flip_v = true,
            source = "version1_parser_v_flip",
        },
        bounds = {
            min_x = min_x,
            min_y = min_y,
            min_z = min_z,
            max_x = max_x,
            max_y = max_y,
            max_z = max_z,
        },
    }
end

---Binary mesh 2.00 / 3.00 / 3.01. Strides are self-describing, so the same reader
---covers all three, the only 3.x delta is the LOD table, which is header-size gated
local function parse_version_2_or_3_mesh(data, version_key)
    local ctx = { format = "mesh", version = version_key }
    local reader = Reader.new(data)
    local body_start, version_line_error =
        locate_binary_mesh_body_start(data, version_key)
    if not body_start then
        return fail("mesh_v2_truncated_header",
            "mesh " .. version_key .. ": invalid binary version line: "
                .. tostring(version_line_error), ctx)
    end
    reader.pos = body_start
    if not reader:can_read(4) then
        return fail("mesh_v2_truncated_header",
            "mesh " .. version_key .. ": file ends inside the 4-byte header prefix", ctx)
    end
    local header_size = reader:uint16_le()
    local vertex_size = reader:uint8()
    local face_size = reader:uint8()
    local lod_size = 0
    local num_lods = 0
    local num_verts = 0
    local num_faces = 0

    if header_size ~= 12 and header_size < 16 then
        return fail("mesh_v2_bad_header_size", string.format(
            "mesh %s: header_size %d is neither the 2.00 value (12) nor a 3.x value (>=16)",
            version_key, header_size), ctx)
    end
    if vertex_size < 32 or face_size < 12 then
        return fail("mesh_v2_bad_strides", string.format(
            "mesh %s: vertex stride %d / face stride %d below the format minimum (32 / 12)",
            version_key, vertex_size, face_size), ctx)
    end

    if header_size > 12 then
        if not reader:can_read(12) then
            return fail("mesh_v2_truncated_header",
                "mesh " .. version_key .. ": file ends inside the 3.x header", ctx)
        end
        lod_size = reader:uint16_le()
        num_lods = reader:uint16_le()
        num_verts = reader:uint32_le()
        num_faces = reader:uint32_le()
    else
        if not reader:can_read(8) then
            return fail("mesh_v2_truncated_header",
                "mesh " .. version_key .. ": file ends inside the vertex/face counts", ctx)
        end
        num_verts = reader:uint32_le()
        num_faces = reader:uint32_le()
    end
    if num_verts <= 0 or num_faces <= 0 then
        return fail("mesh_v2_empty_counts", string.format(
            "mesh %s: header declares %d vertices and %d faces", version_key, num_verts, num_faces),
            ctx)
    end
    if header_size > 12 and lod_size ~= 2 and lod_size ~= 4 then
        return fail("mesh_v2_bad_lod_size", string.format(
            "mesh %s: LOD entry size %d is neither 2 nor 4", version_key, lod_size), ctx)
    end

    local header_end = body_start + header_size
    if header_end > reader.len + 1 then
        return fail("mesh_v2_header_past_eof", string.format(
            "mesh %s: header_size %d runs past the end of a %d-byte file",
            version_key, header_size, reader.len), ctx)
    end
    if reader.pos < header_end then
        reader.pos = header_end
    end

    if not reader:can_read(num_verts * vertex_size) then
        return fail("mesh_v2_truncated_vertices", string.format(
            "mesh %s: %d vertices x %d bytes do not fit in the %d bytes left",
            version_key, num_verts, vertex_size, reader:remaining()), ctx)
    end
    local mesh_vertices = {}
    for _ = 1, num_verts do
        mesh_vertices[#mesh_vertices + 1] = read_binary_mesh_vertex(reader, vertex_size)
    end

    if not reader:can_read(num_faces * face_size) then
        return fail("mesh_v2_truncated_faces", string.format(
            "mesh %s: %d faces x %d bytes do not fit in the %d bytes left",
            version_key, num_faces, face_size, reader:remaining()), ctx)
    end
    local faces = read_binary_mesh_faces(reader, num_faces, face_size)
    local faces_valid, face_error = binary_mesh_faces_are_valid(faces, num_verts)
    if not faces_valid then
        return fail("mesh_v2_bad_face_indices",
            "mesh " .. version_key .. ": " .. tostring(face_error),
            { format = "mesh", version = version_key, detail = face_error })
    end

    local lods = {}
    if header_size > 12 and lod_size > 0 and num_lods > 0 then
        if not reader:can_read(num_lods * lod_size) then
            return fail("mesh_v2_truncated_lods", string.format(
                "mesh %s: %d LOD entries x %d bytes do not fit in the %d bytes left",
                version_key, num_lods, lod_size, reader:remaining()), ctx)
        end
        for _ = 1, num_lods do
            lods[#lods + 1] = lod_size == 2 and reader:uint16_le() or reader:uint32_le()
        end
    end

    local parsed = collect_binary_mesh_geometry(mesh_vertices, faces, lods)
    if not parsed then
        return fail("mesh_v2_no_geometry",
            "mesh " .. version_key .. ": faces reference no readable vertex", ctx)
    end
    parsed.vertex_stride = vertex_size
    parsed.face_stride = face_size
    parsed.header_size = header_size
    return parsed
end

---Binary mesh 4.00 / 4.01 / 5.00 / 6.00
---
---4.x and 5.00 differ only by the trailing FACS pair in the header. 6.00 is read with
---the 5.00 shape -- see the MESH_FORMATS comment for exactly how much of that is
---inference and what fences it
local function parse_version_4_to_6_mesh(data, version_key, format, opts)
    opts = opts or {}
    local ctx = { format = "mesh", version = version_key }
    local reader = Reader.new(data)
    local reader_kind = format.reader
    local vertex_size = 40
    local face_size = 12
    local header_size
    local num_verts
    local num_faces
    local lod_count
    local lod_type
    local lod_hq_count
    local bone_count
    local bone_names_len
    local subset_count
    local facs_format = 0
    local facs_size = 0

    -- a 6.00 rejection is reported under its own code so "the guess was wrong" never
    -- reads like "this 4.x file is corrupt"
    local truncation_code = (reader_kind == "v6") and "mesh_v6_layout_unverified" or nil
    local function reject(code, message, extra)
        return fail(truncation_code or code, message, extra or ctx)
    end

    local body_start, version_line_error =
        locate_binary_mesh_body_start(data, version_key)
    if not body_start then
        return reject("mesh_v4_truncated_header",
            "mesh " .. version_key .. ": invalid binary version line: "
                .. tostring(version_line_error))
    end
    reader.pos = body_start
    if not reader:can_read(4) then
        return reject("mesh_v4_truncated_header",
            "mesh " .. version_key .. ": file ends inside the header prefix")
    end
    header_size = reader:uint16_le()
    local min_header = (reader_kind == "v4") and 24 or 32
    local header_tail = (reader_kind == "v4") and 22 or 30
    if header_size < min_header then
        return reject("mesh_v4_bad_header_size", string.format(
            "mesh %s: header_size %d below the format minimum %d",
            version_key, header_size, min_header))
    end
    if not reader:can_read(header_tail) then
        return reject("mesh_v4_truncated_header", string.format(
            "mesh %s: file ends inside the %d-byte header body", version_key, header_tail))
    end
    lod_type = reader:uint16_le()
    num_verts = reader:uint32_le()
    num_faces = reader:uint32_le()
    lod_count = reader:uint16_le()
    bone_count = reader:uint16_le()
    bone_names_len = reader:uint32_le()
    subset_count = reader:uint16_le()
    lod_hq_count = reader:uint8()
    reader:uint8() -- padding
    if reader_kind ~= "v4" then
        facs_format = reader:uint32_le()
        facs_size = reader:uint32_le()
    end

    if num_verts <= 0 or num_faces <= 0 then
        return reject("mesh_v4_empty_counts", string.format(
            "mesh %s: header declares %d vertices and %d faces", version_key, num_verts, num_faces))
    end

    local header_end = body_start + header_size
    if header_end > reader.len + 1 then
        return reject("mesh_v4_header_past_eof", string.format(
            "mesh %s: header_size %d runs past the end of a %d-byte file",
            version_key, header_size, reader.len))
    end
    if reader.pos < header_end then
        reader.pos = header_end
    end

    if not reader:can_read(num_verts * vertex_size) then
        return reject("mesh_v4_truncated_vertices", string.format(
            "mesh %s: %d vertices x %d bytes do not fit in the %d bytes left",
            version_key, num_verts, vertex_size, reader:remaining()))
    end
    local mesh_vertices = {}
    for _ = 1, num_verts do
        mesh_vertices[#mesh_vertices + 1] = read_binary_mesh_vertex(reader, vertex_size)
    end

    if bone_count > 0 then
        if not reader:can_read(num_verts * 8) then
            return reject("mesh_v4_truncated_envelopes", string.format(
                "mesh %s: %d skinning envelopes do not fit in the %d bytes left",
                version_key, num_verts, reader:remaining()))
        end
        reader:skip(num_verts * 8)
    end

    if not reader:can_read(num_faces * face_size) then
        return reject("mesh_v4_truncated_faces", string.format(
            "mesh %s: %d faces x %d bytes do not fit in the %d bytes left",
            version_key, num_faces, face_size, reader:remaining()))
    end
    local faces = read_binary_mesh_faces(reader, num_faces, face_size)
    local faces_valid, face_error = binary_mesh_faces_are_valid(faces, num_verts)
    if not faces_valid then
        return reject("mesh_v4_bad_face_indices",
            "mesh " .. version_key .. ": " .. tostring(face_error),
            { format = "mesh", version = version_key, detail = face_error })
    end

    local lods = {}
    if not reader:can_read(lod_count * 4) then
        return reject("mesh_v4_truncated_lods", string.format(
            "mesh %s: %d LOD entries do not fit in the %d bytes left",
            version_key, lod_count, reader:remaining()))
    end
    for _ = 1, lod_count do
        lods[#lods + 1] = reader:uint32_le()
    end
    local lod_metadata = normalize_v4_lod_metadata(
        lods, num_faces, lod_type, lod_hq_count)

    if bone_count > 0 then
        if not reader:can_read(bone_count * 60) then
            return reject("mesh_v4_truncated_bones", string.format(
                "mesh %s: %d bone records do not fit in the %d bytes left",
                version_key, bone_count, reader:remaining()))
        end
        reader:skip(bone_count * 60)
    end
    if bone_names_len > 0 then
        if not reader:can_read(bone_names_len) then
            return reject("mesh_v4_truncated_bone_names", string.format(
                "mesh %s: %d-byte bone-name buffer does not fit in the %d bytes left",
                version_key, bone_names_len, reader:remaining()))
        end
        reader:skip(bone_names_len)
    end
    local raw_subsets = {}
    if subset_count > 0 then
        if not reader:can_read(subset_count * 72) then
            return reject("mesh_v4_truncated_subsets", string.format(
                "mesh %s: %d mesh subsets do not fit in the %d bytes left",
                version_key, subset_count, reader:remaining()))
        end
        for subset_index = 1, subset_count do
            local bone_indices = {}
            local record = {
                face_start_zero_based = reader:uint32_le(),
                face_count = reader:uint32_le(),
                vertex_start_zero_based = reader:uint32_le(),
                vertex_count = reader:uint32_le(),
                bone_index_count = reader:uint32_le(),
                bone_indices_zero_based = bone_indices,
            }
            for bone_index = 1, 26 do
                bone_indices[bone_index] = reader:uint16_le()
            end
            raw_subsets[subset_index] = record
        end
    end
    local subset_metadata = normalize_v4_subset_metadata(
        raw_subsets, num_faces, num_verts, bone_count)
    if facs_size > 0 then
        if not reader:can_read(facs_size) then
            return reject("mesh_v4_truncated_facs", string.format(
                "mesh %s: %d-byte FACS block does not fit in the %d bytes left",
                version_key, facs_size, reader:remaining()))
        end
        reader:skip(facs_size)
    end

    -- LOD0 remains the compatibility/top-level geometry. invalid metadata is
    -- ignored (all readable faces are retained) rather than being allowed to
    -- reject or empty an otherwise valid mesh. Valid lower ranges are retained
    -- below as compact render-ready streams for runtime selection
    local geometry_lods = lod_metadata.geometry_lod_index_zero_based == 0 and lods or nil
    local parsed = collect_binary_mesh_geometry(mesh_vertices, faces, geometry_lods)
    if not parsed then
        return reject("mesh_v4_no_geometry",
            "mesh " .. version_key .. ": faces reference no readable vertex")
    end
    parsed.vertex_stride = vertex_size
    parsed.face_stride = face_size
    parsed.header_size = header_size
    parsed.bone_count = bone_count
    parsed.lod_type = lod_type
    parsed.lod_high_quality_count = lod_hq_count
    parsed.lod_offsets_zero_based = lod_metadata.offsets_zero_based
    parsed.lod_ranges = lod_metadata.ranges
    parsed.lod_metadata = lod_metadata
    -- retain every independently flattened, validated LOD so the renderer can
    -- select by projected error without reparsing or holding the much heavier
    -- raw vertex/face graph. `parsed` itself remains LOD0 for compatibility
    if lod_metadata.runtime_selection_supported == true then
        local retained_triangles = 0
        for range_index = 1, #lod_metadata.ranges do
            retained_triangles = retained_triangles
                + (tonumber(lod_metadata.ranges[range_index].face_count) or 0)
        end
        local retained_vertices = retained_triangles * 3
        local vertex_budget = tonumber(opts.max_render_lod_vertices)
        local triangle_budget = tonumber(opts.max_render_lod_triangles)
        if vertex_budget and retained_vertices > vertex_budget then
            parsed.render_lod_limit_reason = "mesh_output_vertex_limit"
        elseif triangle_budget and retained_triangles > triangle_budget then
            parsed.render_lod_limit_reason = "mesh_output_triangle_limit"
        end
        if parsed.render_lod_limit_reason then
            -- Remote workers provide an output budget here. preserve LOD0 for
            -- ordinary parser callers/diagnostics but never allocate the lower
            -- streams merely to discover after the fact that their retained
            -- graph exceeds the job ceiling
            parsed.lod_metadata.runtime_selection_supported = false
            parsed.lod_metadata.runtime_selection_reason =
                "lod_output_budget_exceeded"
        else
            -- LOD0 was already flattened into `parsed`. wrap its arrays by identity
        -- instead of flattening the same face range a second time and discarding
        -- those duplicate arrays immediately before return
            local render_lods = {
                alias_binary_mesh_geometry_range(
                    parsed, lod_metadata.ranges[1], 1),
            }
            local complete = true
            for range_index = 2, #lod_metadata.ranges do
                local range = lod_metadata.ranges[range_index]
                if range.valid == true and (tonumber(range.face_count) or 0) > 0 then
                    local geometry = collect_binary_mesh_geometry_range(
                        mesh_vertices, faces,
                        range.face_start_zero_based,
                        range.face_end_exclusive_zero_based)
                    if geometry then
                        geometry.lod_index_zero_based =
                            range.lod_index_zero_based or (range_index - 1)
                        geometry.face_count = range.face_count
                        geometry.source_face_start_zero_based =
                            range.face_start_zero_based
                        geometry.source_face_end_exclusive_zero_based =
                            range.face_end_exclusive_zero_based
                        render_lods[#render_lods + 1] = geometry
                    else
                        complete = false
                        break
                    end
                else
                    complete = false
                    break
                end
            end
            if complete and #render_lods == #lod_metadata.ranges then
                parsed.render_lods = render_lods
                parsed.lod_metadata.runtime_selection_enabled = true
            else
                parsed.lod_metadata.runtime_selection_supported = false
                parsed.lod_metadata.runtime_selection_reason =
                    "lod_geometry_materialization_failed"
            end
        end
    end
    parsed.mesh_subsets = subset_metadata.records
    parsed.mesh_subset_metadata = subset_metadata
    parsed.facs_format = facs_format
    parsed.facs_size = facs_size
    return parsed
end

local function decode_csg_obfuscated_bytes(data, count, prefix_only)
    if type(data) ~= "string" or data == "" then
        return nil
    end
    local total = math.min(math.max(0, count or #data), #data)
    local chunks = {}
    local bytes = {}
    local unpack_bytes = table.unpack or unpack
    local cycle = #CSG_OBFUSCATION_XOR
    -- Building one table slot per source byte made a 12 MiB CSG corpus create
    -- millions of temporary entries before table.concat. keep one small numeric
    -- scratch buffer and emit bounded strings instead, the XOR position remains
    -- absolute, so chunk boundaries cannot alter the decoded stream
    local chunk_size = 240
    local source_index = 1
    local xor_index = 1
    while source_index <= total do
        local byte_count = math.min(chunk_size, total - source_index + 1)
        for offset = 1, byte_count do
            bytes[offset] = bxor(
                data:byte(source_index),
                CSG_OBFUSCATION_XOR[xor_index])
            source_index = source_index + 1
            xor_index = xor_index + 1
            if xor_index > cycle then xor_index = 1 end
        end
        chunks[#chunks + 1] = string.char(
            unpack_bytes(bytes, 1, byte_count))
    end
    if prefix_only ~= true and total < #data then
        chunks[#chunks + 1] = data:sub(total + 1)
    end
    return table.concat(chunks)
end
mesh._decode_csg_obfuscated_bytes = decode_csg_obfuscated_bytes

local function decode_csg_header(data)
    -- the public partial-stream helper deliberately returns the untouched tail
    -- a format probe needs only ten bytes, however, rebuilding an entire CSGPHS
    -- payload here was pure allocation before that parser immediately rejected
    -- the CSGMDL signature and tried the physics format
    local decoded = decode_csg_obfuscated_bytes(data, 10, true)
    if type(decoded) ~= "string" or #decoded < 10 or decoded:sub(1, 6) ~= "CSGMDL" then
        return nil
    end
    local reader = Reader.new(decoded:sub(7, 10))
    return reader:uint32_le(), decoded:sub(1, 10)
end

local function decode_quantized_csg_component(raw_value)
    local shifted = raw_value - 0x7FFF
    -- this is an offset unsigned quantizer, not a signed int16. 0xFFFF is
    -- one quantization step above the exactly representable +1 value
    -- (0xFFFE) and saturates to the positive endpoint, wrapping it through
    -- int16 instead turns the maximum encoded component into -1.00003
    return math.max(-1, math.min(1, shifted / 32767))
end

local function read_quantized_csg_vector3(reader)
    return decode_quantized_csg_component(reader:uint16_le()),
        decode_quantized_csg_component(reader:uint16_le()),
        decode_quantized_csg_component(reader:uint16_le())
end

---Mean of the vertices actually referenced by `faces`
---
---for a convex hull this point is strictly interior, which is exactly the reference
---a winding test needs. the mesh ORIGIN is not: hulls in a convex decomposition sit
---wherever the decomposition put them, and a hull that does not contain the origin
---has its outward normals judged against a point outside itself, inverting a subset
---of its triangles (measured: 2 of 12 on a unit cube at x in [2,3], signed volume
---2.333 instead of 1.0)
local function reference_point_of(vertices, faces)
    local seen, count = {}, 0
    local sx, sy, sz = 0, 0, 0
    for face_index = 1, #faces do
        local face = faces[face_index]
        for corner = 1, 3 do
            local index = face[corner]
            local v = vertices[index]
            if v and not seen[index] then
                seen[index] = true
                count = count + 1
                sx, sy, sz = sx + v[1], sy + v[2], sz + v[3]
            end
        end
    end
    if count == 0 then
        return 0, 0, 0
    end
    return sx / count, sy / count, sz / count
end

---@param hull_centroid table|nil  {x,y,z} interior reference point; derived from the
---       face-referenced vertices when omitted. MUST be this hull's own interior
---       point -- see reference_point_of
local function collect_triangle_mesh_geometry(vertices, faces, hull_centroid)
    local positions, normals, uvs = {}, {}, {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    local ox, oy, oz
    if hull_centroid then
        ox, oy, oz = hull_centroid[1], hull_centroid[2], hull_centroid[3]
    else
        ox, oy, oz = reference_point_of(vertices, faces)
    end

    for face_index = 1, #faces do
        local face = faces[face_index]
        local a, b, c = vertices[face[1]], vertices[face[2]], vertices[face[3]]
        if a and b and c then
            local ax, ay, az = b[1] - a[1], b[2] - a[2], b[3] - a[3]
            local bx, by, bz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
            local nx, ny, nz = cross(ax, ay, az, bx, by, bz)
            local cx = (a[1] + b[1] + c[1]) / 3 - ox
            local cy = (a[2] + b[2] + c[2]) / 3 - oy
            local cz = (a[3] + b[3] + c[3]) / 3 - oz
            if dot(nx, ny, nz, cx, cy, cz) < 0 then
                b, c = c, b
                nx, ny, nz = -nx, -ny, -nz
            end
            nx, ny, nz = normalize_or_fallback(nx, ny, nz, 0, 1, 0)

            -- avoid allocating a three-element iterator table for every hull
            -- face.  the numeric corner order is the same a,b,c order used by
            -- ipairs, so emitted streams and bounds arithmetic stay identical
            for corner = 1, 3 do
                local v = corner == 1 and a or (corner == 2 and b or c)
                positions[#positions + 1] = v[1]
                positions[#positions + 1] = v[2]
                positions[#positions + 1] = v[3]
                normals[#normals + 1] = nx
                normals[#normals + 1] = ny
                normals[#normals + 1] = nz
                uvs[#uvs + 1] = 0
                uvs[#uvs + 1] = 0
                min_x = math.min(min_x, v[1])
                min_y = math.min(min_y, v[2])
                min_z = math.min(min_z, v[3])
                max_x = math.max(max_x, v[1])
                max_y = math.max(max_y, v[2])
                max_z = math.max(max_z, v[3])
            end
        end
    end

    if #positions == 0 then
        return nil
    end

    return {
        positions = positions,
        normals = normals,
        uvs = uvs,
        bounds = {
            min_x = min_x,
            min_y = min_y,
            min_z = min_z,
            max_x = max_x,
            max_y = max_y,
            max_z = max_z,
        },
    }
end

local function merge_renderable_mesh_geometries(mesh_list)
    if type(mesh_list) ~= "table" or #mesh_list == 0 then
        return nil
    end
    if #mesh_list == 1 then
        return mesh_list[1]
    end

    local positions, normals, uvs = {}, {}, {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    for i = 1, #mesh_list do
        local entry = mesh_list[i]
        if entry then
            util.table_append(positions, entry.positions or {})
            util.table_append(normals, entry.normals or {})
            util.table_append(uvs, entry.uvs or {})
            if entry.bounds then
                min_x = math.min(min_x, entry.bounds.min_x or math.huge)
                min_y = math.min(min_y, entry.bounds.min_y or math.huge)
                min_z = math.min(min_z, entry.bounds.min_z or math.huge)
                max_x = math.max(max_x, entry.bounds.max_x or -math.huge)
                max_y = math.max(max_y, entry.bounds.max_y or -math.huge)
                max_z = math.max(max_z, entry.bounds.max_z or -math.huge)
            end
        end
    end

    if #positions == 0 then
        return nil
    end

    return {
        positions = positions,
        normals = normals,
        uvs = uvs,
        bounds = {
            min_x = min_x,
            min_y = min_y,
            min_z = min_z,
            max_x = max_x,
            max_y = max_y,
            max_z = max_z,
        },
    }
end

local function collect_indexed_mesh_geometry(index_positions, index_normals, index_uvs, index_colors, index_normal_ids, indices)
    local positions, normals, uvs, colors, normal_ids = {}, {}, {}, {}, {}
    local has_normal_ids = type(index_normal_ids) == "table" and #index_normal_ids > 0
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    for i = 1, #indices do
        local vertex_index = math.max(0, math.floor(indices[i] or 0))
        local pos_index = vertex_index * 3 + 1
        local uv_index = vertex_index * 2 + 1
        local color_index = vertex_index * 4 + 1
        local px = index_positions[pos_index] or 0
        local py = index_positions[pos_index + 1] or 0
        local pz = index_positions[pos_index + 2] or 0
        positions[#positions + 1] = px
        positions[#positions + 1] = py
        positions[#positions + 1] = pz
        normals[#normals + 1] = index_normals[pos_index] or 0
        normals[#normals + 1] = index_normals[pos_index + 1] or 1
        normals[#normals + 1] = index_normals[pos_index + 2] or 0
        uvs[#uvs + 1] = index_uvs[uv_index] or 0
        uvs[#uvs + 1] = index_uvs[uv_index + 1] or 0
        colors[#colors + 1] = index_colors[color_index] or 1
        colors[#colors + 1] = index_colors[color_index + 1] or 1
        colors[#colors + 1] = index_colors[color_index + 2] or 1
        colors[#colors + 1] = index_colors[color_index + 3] or 1
        if has_normal_ids then
            normal_ids[#normal_ids + 1] = math.floor(index_normal_ids[vertex_index + 1] or 0)
        end
        min_x = math.min(min_x, px)
        min_y = math.min(min_y, py)
        min_z = math.min(min_z, pz)
        max_x = math.max(max_x, px)
        max_y = math.max(max_y, py)
        max_z = math.max(max_z, pz)
    end

    if #positions == 0 then
        return nil
    end

    return {
        positions = positions,
        normals = normals,
        uvs = uvs,
        colors = #colors > 0 and colors or nil,
        normal_ids = has_normal_ids and normal_ids or nil,
        bounds = {
            min_x = min_x,
            min_y = min_y,
            min_z = min_z,
            max_x = max_x,
            max_y = max_y,
            max_z = max_z,
        },
    }
end

local function read_csg_mesh_vertex(reader, vertex_size)
    local vertex = {
        px = reader:float32_le(),
        py = reader:float32_le(),
        pz = reader:float32_le(),
        nx = reader:float32_le(),
        ny = reader:float32_le(),
        nz = reader:float32_le(),
        r = reader:uint8() / 255,
        g = reader:uint8() / 255,
        b = reader:uint8() / 255,
        a = reader:uint8() / 255,
        normal_id = reader:uint32_le(),
        u = reader:float32_le(),
        v = reader:float32_le(),
    }
    reader:skip(16 + 12 + 16)
    if vertex_size > 84 then
        reader:skip(vertex_size - 84)
    end
    return vertex
end

local function parse_csg_mesh_v2_or_4(data, version)
    local ctx = { format = "csgmdl", version = version }
    local decoded = decode_csg_obfuscated_bytes(data)
    if type(decoded) ~= "string" then
        return fail("csgmdl_deobfuscation_failed",
            "csgmdl v" .. version .. ": payload could not be de-obfuscated", ctx)
    end
    local reader = Reader.new(decoded)
    if reader:read_string(6) ~= "CSGMDL" or reader:uint32_le() ~= version then
        return fail("csgmdl_header_mismatch",
            "csgmdl v" .. version .. ": de-obfuscated header is not CSGMDL v" .. version, ctx)
    end
    reader:skip(32)
    local vertex_count = reader:uint32_le()
    local vertex_size = reader:uint32_le()
    if vertex_size < 84 then
        return fail("csgmdl_vertex_stride_too_small", string.format(
            "csgmdl v%d: vertex stride %d below the format minimum 84", version, vertex_size), ctx)
    end
    local mesh_vertices = {}
    for i = 1, vertex_count do
        mesh_vertices[i] = read_csg_mesh_vertex(reader, vertex_size)
    end
    local face_index_count = reader:uint32_le()
    local face_count = math.floor(face_index_count / 3)
    local faces = {}
    for i = 1, face_count do
        faces[i] = {
            (reader:uint32_le() or 0) + 1,
            (reader:uint32_le() or 0) + 1,
            (reader:uint32_le() or 0) + 1,
        }
    end
    if version == 4 then
        local extra_count = reader:uint32_le()
        if extra_count > 0 then
            reader:skip(extra_count * 4)
        end
    end
    local parsed = collect_binary_mesh_geometry(mesh_vertices, faces)
    if not parsed then
        return fail("csgmdl_no_geometry", string.format(
            "csgmdl v%d: %d faces reference no readable vertex of %d",
            version, face_count, vertex_count), ctx)
    end
    return parsed
end

local function decode_csg_faces_v5_indices(vertex_data, expected_output_count)
    local reader = Reader.new(vertex_data)
    local indices = {}
    local index_out = 0

    for i = 1, expected_output_count do
        if reader:remaining() <= 0 then
            return nil
        end
        local v0 = reader:uint8()
        if band(v0, 0x80) == 0 then
            if band(v0, 0x40) == 0 then
                index_out = index_out + v0
            else
                index_out = index_out + (v0 - 128)
            end
        else
            if reader:remaining() < 2 then
                return nil
            end
            local v1 = reader:uint8()
            local v2 = reader:uint8()
            index_out = index_out + v2 + lshift(v1, 8) + lshift(band(v0, 0x7F), 16)
        end
        indices[i] = band(index_out, 0x7FFFFF)
    end

    if reader:remaining() > 0 then
        return nil
    end
    return indices
end

local function parse_csg_mesh_v5(data, decoded_header)
    local ctx = { format = "csgmdl", version = 5 }
    local payload = (decoded_header or "") .. data:sub(11)
    local reader = Reader.new(payload)
    if reader:read_string(6) ~= "CSGMDL" or reader:uint32_le() ~= 5 then
        return fail("csgmdl_header_mismatch",
            "csgmdl v5: de-obfuscated header is not CSGMDL v5", ctx)
    end

    local position_count = reader:uint16_le()
    local positions = {}
    for _ = 1, position_count do
        positions[#positions + 1] = reader:float32_le()
        positions[#positions + 1] = reader:float32_le()
        positions[#positions + 1] = reader:float32_le()
    end

    local normal_count = reader:uint16_le()
    local normal_data_len = reader:uint32_le()
    local normals = {}
    for _ = 1, normal_count do
        local nx, ny, nz = read_quantized_csg_vector3(reader)
        normals[#normals + 1] = nx
        normals[#normals + 1] = ny
        normals[#normals + 1] = nz
    end
    local expected_normal_len = normal_count * 6
    if normal_data_len > expected_normal_len then
        reader:skip(normal_data_len - expected_normal_len)
    end

    local color_count = reader:uint16_le()
    local colors = {}
    for _ = 1, color_count do
        colors[#colors + 1] = reader:uint8() / 255
        colors[#colors + 1] = reader:uint8() / 255
        colors[#colors + 1] = reader:uint8() / 255
        colors[#colors + 1] = reader:uint8() / 255
    end

    local normal_id_count = reader:uint16_le()
    local normal_ids = {}
    for _ = 1, normal_id_count do
        normal_ids[#normal_ids + 1] = reader:uint8()
    end

    local tex_count = reader:uint16_le()
    local uvs = {}
    for _ = 1, tex_count do
        uvs[#uvs + 1] = reader:float32_le()
        uvs[#uvs + 1] = reader:float32_le()
    end

    local tangent_count = reader:uint16_le()
    local tangent_data_len = reader:uint32_le()
    local expected_tangent_len = tangent_count * 6
    if expected_tangent_len > 0 then
        reader:skip(expected_tangent_len)
    end
    if tangent_data_len > expected_tangent_len then
        reader:skip(tangent_data_len - expected_tangent_len)
    end

    local face_vertex_count = reader:uint32_le()
    local vertex_data_len = reader:uint32_le()
    local vertex_data = reader:read_string(vertex_data_len)
    local marker_kind = reader:uint8()
    reader:uint32_le()
    local range_end = reader:uint32_le()
    if marker_kind == 3 then
        reader:uint32_le()
    elseif marker_kind ~= 2 then
        return fail("csgmdl_v5_bad_range_marker", string.format(
            "csgmdl v5: index-range marker %d is neither 2 nor 3", marker_kind), ctx)
    end

    local indices = decode_csg_faces_v5_indices(vertex_data, face_vertex_count)
    if not indices then
        return fail("csgmdl_v5_index_stream", string.format(
            "csgmdl v5: the %d-byte delta stream does not decode to exactly %d indices",
            vertex_data_len, face_vertex_count), ctx)
    end
    if marker_kind == 3 then
        for i = #indices, range_end + 1, -1 do
            indices[i] = nil
        end
    end

    local parsed = collect_indexed_mesh_geometry(positions, normals, uvs, colors, normal_ids, indices)
    if not parsed then
        return fail("csgmdl_no_geometry",
            "csgmdl v5: the index stream produced no vertices", ctx)
    end
    return parsed
end

---@return table|nil parsed, string|nil reason, table|nil info
---a nil `version` means "this is not a CSGMDL payload at all", which is not an error
---worth reporting -- the caller goes on to try CSGPHS. it is signalled by returning a
---bare nil with no reason
local function parse_csg_mesh_data(data)
    if type(data) ~= "string" or data == "" then
        return nil
    end

    local version, decoded_header = decode_csg_header(data)
    if version == nil then
        return nil
    end

    local parsed, reason, info
    if version == 2 or version == 4 then
        parsed, reason, info = parse_csg_mesh_v2_or_4(data, version)
    elseif version == 5 then
        parsed, reason, info = parse_csg_mesh_v5(data, decoded_header)
    else
        return fail("csgmdl_version_unsupported",
            "csgmdl v" .. tostring(version) .. ": unsupported CSGMDL version (known: 2, 4, 5)",
            { format = "csgmdl", version = version })
    end

    if not parsed then
        return nil, reason, info
    end
    parsed.source_kind = "csg_mesh"
    parsed.version = version
    return parsed
end

local function read_csg_physics_mesh(reader)
    if reader:remaining() < 52 then
        return nil
    end
    if reader:uint32_le() ~= 16 then
        return nil
    end
    for _ = 1, 4 do
        if reader:uint32_le() ~= 0 then
            return nil
        end
    end
    if reader:uint32_le() ~= 16 then
        return nil
    end
    for _ = 1, 3 do
        if reader:uint32_le() ~= 0 then
            return nil
        end
    end
    if reader:uint32_le() ~= 0x3F800000 then
        return nil
    end

    local vertex_component_count = reader:uint32_le()
    if vertex_component_count <= 0 or vertex_component_count % 3 ~= 0 or reader:uint32_le() ~= 4 then
        return nil
    end
    local vertex_count = math.floor(vertex_component_count / 3)
    local vertices = {}
    for i = 1, vertex_count do
        vertices[i] = { reader:float32_le(), reader:float32_le(), reader:float32_le() }
    end

    local face_component_count = reader:uint32_le()
    if face_component_count < 0 or face_component_count % 3 ~= 0 then
        return nil
    end
    local face_count = math.floor(face_component_count / 3)
    local faces = {}
    for i = 1, face_count do
        faces[i] = {
            (reader:uint32_le() or 0) + 1,
            (reader:uint32_le() or 0) + 1,
            (reader:uint32_le() or 0) + 1,
        }
    end
    local parsed = collect_triangle_mesh_geometry(vertices, faces)
    if parsed then
        local flat = {}
        for _,vertex in ipairs(vertices) do
            flat[#flat+1],flat[#flat+2],flat[#flat+3] = vertex[1],vertex[2],vertex[3]
        end
        -- preserve the stored solid independently of the expanded render
        -- triangles. Merging the render stream must not merge separate hulls
        parsed.physics_hull = {vertices=flat,faces=faces}
    end
    return parsed
end

-- CSGPHS v0 carries no geometry at all: the whole body is a short ASCII primitive
-- token. in a measured place, 896 of 896 v0 blobs are exactly "BLOCK", i.e
-- "this union's collision volume is the part box". Rendering the part box is the
-- CORRECT answer for these, not a fallback -- so they must not be counted as decode
-- failures and must not raise the "approximated" warning
local CSG_PHYSICS_PRIMITIVE_TOKENS = {
    BLOCK = "Block",
    BALL = "Ball",
    SPHERE = "Ball",
    CYLINDER = "Cylinder",
    WEDGE = "Wedge",
}

-- resolved once: one place alone had 1018 v8 blobs, and require() is not free
local zstd_module = nil
local function get_zstd()
    if zstd_module == nil then
        local ok, module = pcall(require, "engine/graphics/rbx/zstd")
        zstd_module = (ok and type(module) == "table" and type(module.decompress) == "function")
            and module or false
    end
    return zstd_module or nil
end

---decodes the CSGPHS v8 container. Layout, validated byte-exact against 1018 of
---1018 v8 blobs in one measured place:
---
---  "CSGPHS" u32 version=8 u16 kind      then ONE zstd frame holding
---    u32 hull_count H
---    u32 vertex_count V
---    u32 face_count F            == 2V - 4H  (Euler, per convex hull)
---    u32 max_hull_vertices
---    u32 max_hull_faces
---    u32 reserved                == 0
---    u32 connectivity_bits       == 2F - H
---    u32 connectivity_bytes      == align4(ceil(bits/8))
---    u32 vertex_bytes            == 12V
---    f32[6] aabb (min xyz, max xyz)
---    u8 [connectivity_bytes] connectivity bitstream  -- NOT decoded, see docs
---    f32[3V] vertices
---
---`kind` is 1 exactly when H == 1 and 2 exactly when H > 1 (272/746 split), it is
---NOT a zstd frame count -- every v8 blob holds exactly one frame that consumes the
---payload to its last byte
local CSGPHS_V8 = { format = "csgphs", version = 8 }

local function decode_csg_physics_v8(data)
    local zstd = get_zstd()
    if not zstd then
        return fail("csgphs_v8_zstd_unavailable", "csgphs v8: zstd decoder unavailable", CSGPHS_V8)
    end
    if #data < 13 then
        return fail("csgphs_v8_truncated_container", "csgphs v8: truncated container", CSGPHS_V8)
    end
    local ok, frame = pcall(zstd.decompress, data:sub(13))
    if not ok or type(frame) ~= "string" or #frame < 60 then
        return fail("csgphs_v8_zstd_frame", "csgphs v8: zstd frame did not decode", CSGPHS_V8)
    end

    local reader = Reader.new(frame)
    local hull_count = reader:uint32_le()
    local vertex_count = reader:uint32_le()
    local face_count = reader:uint32_le()
    reader:skip(8) -- max_hull_vertices, max_hull_faces
    reader:skip(4) -- reserved (always 0)
    reader:skip(4) -- connectivity_bits
    local connectivity_bytes = reader:uint32_le()
    local vertex_bytes = reader:uint32_le()
    reader:skip(24) -- aabb

    if hull_count < 1 or vertex_count < 4 then
        return fail("csgphs_v8_degenerate_header", string.format(
            "csgphs v8: degenerate header (%d hulls, %d vertices)", hull_count, vertex_count),
            CSGPHS_V8)
    end
    if vertex_bytes ~= vertex_count * 12 then
        return fail("csgphs_v8_vertex_block_size", string.format(
            "csgphs v8: vertex block is %d bytes but %d vertices need %d",
            vertex_bytes, vertex_count, vertex_count * 12), CSGPHS_V8)
    end
    if face_count ~= 2 * vertex_count - 4 * hull_count then
        return fail("csgphs_v8_euler_violation", string.format(
            "csgphs v8: face count %d violates 2V-4H = %d for %d hulls / %d vertices",
            face_count, 2 * vertex_count - 4 * hull_count, hull_count, vertex_count), CSGPHS_V8)
    end
    if 60 + connectivity_bytes + vertex_bytes ~= #frame then
        return fail("csgphs_v8_section_sizes", string.format(
            "csgphs v8: 60 + %d + %d does not span the %d-byte frame",
            connectivity_bytes, vertex_bytes, #frame), CSGPHS_V8)
    end

    reader:skip(connectivity_bytes)
    local vertices = {}
    for i = 1, vertex_count do
        vertices[i] = { reader:float32_le(), reader:float32_le(), reader:float32_le() }
    end
    return {
        hull_count = hull_count,
        vertex_count = vertex_count,
        face_count = face_count,
        vertices = vertices,
    }
end

local function build_csg_physics_v8_geometry(data)
    local decoded, err, err_info = decode_csg_physics_v8(data)
    if not decoded then
        return nil, err, err_info
    end

    local convex_hull = require("engine/graphics/rbx/convex_hull")
    local faces, info = convex_hull.build(decoded.vertices)
    if not faces or not info then
        return fail("csgphs_v8_degenerate_hull", string.format(
            "csgphs v8: convex hull of the %d-point cloud is degenerate", decoded.vertex_count),
            CSGPHS_V8)
    end

    local parsed = collect_triangle_mesh_geometry(decoded.vertices, faces, info.centroid)
    if not parsed then
        return fail("csgphs_v8_no_triangles", "csgphs v8: hull produced no triangles", CSGPHS_V8)
    end

    parsed.source_kind = "csg_physics"
    parsed.version = 8
    parsed.csg_hull_count = decoded.hull_count
    parsed.csg_source_vertex_count = decoded.vertex_count
    parsed.csg_hull_vertex_count = info.vertex_count
    -- hull_count == 1 means the payload IS a single convex hull, so recomputing its
    -- triangulation from its vertices reproduces the stored shape exactly (verified:
    -- the rebuilt hull matches the stored vertex_count and face_count on every
    -- single-hull blob in the corpus). hull_count > 1 is a convex DECOMPOSITION whose
    -- per-hull partition lives in the undecoded connectivity bitstream, so all we can
    -- honestly produce is the convex hull of the whole cloud: a tighter
    -- over-approximation than the part box, but still an over-approximation
    parsed.csg_exact = (decoded.hull_count == 1)
        and info.euler_ok
        and (info.vertex_count == decoded.vertex_count)
        and (info.face_count == decoded.face_count)
    parsed.csg_approximated = not parsed.csg_exact
    parsed.csg_approximation = parsed.csg_exact and "exact-hull" or "convex-over-approximation"
    return parsed
end

local function parse_csg_physics_data(data)
    if type(data) ~= "string" or data == "" then
        return nil
    end
    local reader = Reader.new(data)
    if reader:read_string(6) ~= "CSGPHS" then
        return nil
    end

    local version = reader:uint32_le()
    local ctx = { format = "csgphs", version = version }
    if version == 0 then
        local token = trim(reader:read_string(reader:remaining()))
        if token == "" then
            -- Measured: 5 payloads in assets/rbx/asset are exactly the 10-byte header
            -- with no body. That is still "the file holds no mesh" -- the same answer
            -- BLOCK gives -- so it must not be reported as corruption. the caller keeps
            -- its part box, which is the correct render either way
            return fail("csgphs_v0_empty",
                "csgphs v0: empty primitive token, no mesh in the file",
                { format = "csgphs", version = 0, primitive = "" })
        end
        if CSG_PHYSICS_PRIMITIVE_TOKENS[token] then
            return fail("csgphs_v0_primitive",
                "csgphs v0: primitive '" .. token .. "', no mesh in the file",
                { format = "csgphs", version = 0, primitive = token })
        end
        return fail("csgphs_v0_unknown_primitive",
            "csgphs v0: unrecognised primitive token '" .. tostring(token) .. "'",
            { format = "csgphs", version = 0, primitive = token })
    end

    if version == 8 then
        return build_csg_physics_v8_geometry(data)
    end

    local meshes = {}
    if version == 3 or version == 5 then
        while reader:remaining() > 0 do
            local parsed = read_csg_physics_mesh(reader)
            if not parsed then
                return fail("csgphs_hull_record", string.format(
                    "csgphs v%d: hull record %d did not decode", version, #meshes + 1), ctx)
            end
            meshes[#meshes + 1] = parsed
        end
    elseif version == 6 then
        if reader:remaining() < 40 then
            return fail("csgphs_v6_truncated_inertia", "csgphs v6: truncated inertia block", ctx)
        end
        reader:skip(40)
        while reader:remaining() > 0 do
            local parsed = read_csg_physics_mesh(reader)
            if not parsed then
                return fail("csgphs_hull_record", string.format(
                    "csgphs v6: hull record %d did not decode", #meshes + 1), ctx)
            end
            meshes[#meshes + 1] = parsed
        end
    elseif version == 7 then
        if reader:remaining() < 41 or reader:uint8() ~= 3 then
            return fail("csgphs_v7_subformat_tag", "csgphs v7: unexpected sub-format tag", ctx)
        end
        reader:skip(40)
        while reader:remaining() > 0 do
            local parsed = read_csg_physics_mesh(reader)
            if not parsed then
                return fail("csgphs_hull_record", string.format(
                    "csgphs v7: hull record %d did not decode", #meshes + 1), ctx)
            end
            meshes[#meshes + 1] = parsed
        end
    else
        return fail("csgphs_version_unsupported",
            "csgphs v" .. tostring(version) .. ": unsupported version (known: 0, 3, 5, 6, 7, 8)",
            ctx)
    end

    local parsed = merge_renderable_mesh_geometries(meshes)
    if not parsed then
        return fail("csgphs_no_geometry", string.format(
            "csgphs v%d: %d hull records produced no triangles", version, #meshes), ctx)
    end
    if parsed then
        parsed.source_kind = "csg_physics"
        parsed.version = version
        parsed.csg_hull_count = #meshes
        parsed.physics_hulls = {}
        for _,entry in ipairs(meshes) do
            parsed.physics_hulls[#parsed.physics_hulls+1] = entry.physics_hull
        end
        -- v3/5/6/7 store every hull explicitly, so the render is the full convex
        -- decomposition. That is still not the union's render mesh (no CSGMDL exists
        -- in these files), a decomposition only has to enclose the same volume
        parsed.csg_exact = false
        parsed.csg_approximated = true
        parsed.csg_approximation = "hull-decomposition"
    end
    return parsed
end

local function compute_bounds(positions)
    if type(positions) ~= "table" or #positions < 3 then
        return nil
    end
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
    for index = 1, #positions, 3 do
        local x = positions[index] or 0
        local y = positions[index + 1] or 0
        local z = positions[index + 2] or 0
        min_x = math.min(min_x, x)
        min_y = math.min(min_y, y)
        min_z = math.min(min_z, z)
        max_x = math.max(max_x, x)
        max_y = math.max(max_y, y)
        max_z = math.max(max_z, z)
    end
    return {
        min_x = min_x,
        min_y = min_y,
        min_z = min_z,
        max_x = max_x,
        max_y = max_y,
        max_z = max_z,
    }
end

local function compute_uv_bounds(uvs)
    if type(uvs) ~= "table" or #uvs < 2 then
        return nil
    end
    local min_u, min_v = math.huge, math.huge
    local max_u, max_v = -math.huge, -math.huge
    local finite_count = 0
    for index = 1, #uvs, 2 do
        local u = tonumber(uvs[index])
        local v = tonumber(uvs[index + 1])
        if u and v and u == u and v == v
            and u ~= math.huge and u ~= -math.huge
            and v ~= math.huge and v ~= -math.huge then
            finite_count = finite_count + 1
            min_u = math.min(min_u, u)
            min_v = math.min(min_v, v)
            max_u = math.max(max_u, u)
            max_v = math.max(max_v, v)
        end
    end
    if finite_count <= 0 then
        return nil
    end
    local epsilon = 1 / 4096
    return {
        min_u = min_u,
        min_v = min_v,
        max_u = max_u,
        max_v = max_v,
        outside_unit = min_u < -epsilon or min_v < -epsilon or max_u > 1 + epsilon or max_v > 1 + epsilon,
    }
end

local function normals_are_usable(parsed)
    if type(parsed) ~= "table" then
        return false
    end
    local positions = parsed.positions or {}
    local normals = parsed.normals or {}
    if #positions == 0 or #normals ~= #positions then
        return false
    end
    for index = 1, #normals, 3 do
        local nx = normals[index] or 0
        local ny = normals[index + 1] or 0
        local nz = normals[index + 2] or 0
        if (nx * nx + ny * ny + nz * nz) > 1e-8 then
            return true
        end
    end
    return false
end

local function make_position_key(x, y, z)
    return string.format("%.5f|%.5f|%.5f", x or 0, y or 0, z or 0)
end

local function recompute_smooth_normals(parsed, crease_degrees)
    if type(parsed) ~= "table" then
        return nil
    end

    local positions = parsed.positions or {}
    local vertex_count = math.floor(#positions / 3)
    if vertex_count < 3 then
        return nil
    end

    local threshold = math.cos(math.rad(tonumber(crease_degrees) or 65))
    -- the render streams are triangle-flattened: a stream vertex belongs to one
    -- face, while the same authored position may occur in many faces.  the old
    -- representation stored {vertex -> {face}} and {position -> vertices}, then
    -- reconstructed and deduplicated the identical position-face list for every
    -- corner.  CSG hulls exercise that path heavily during cold map builds
    --
    -- store the equivalent unique face list once per formatted position instead
    -- Faces are visited in ascending stream order, so this preserves both the old
    -- crease membership and the exact floating-point accumulation order.  keeping
    -- each face field in a dense numeric array also avoids one metadata table per
    -- triangle without changing any arithmetic
    local face_nx, face_ny, face_nz, face_weight = {}, {}, {}, {}
    local vertex_face = {}
    local vertex_position_key = {}
    local shared_position_faces = {}

    local function remember_vertex(vertex_index, face_index)
        local pidx = (vertex_index - 1) * 3 + 1
        local key = make_position_key(positions[pidx], positions[pidx + 1], positions[pidx + 2])
        vertex_face[vertex_index] = face_index
        vertex_position_key[vertex_index] = key
        local bucket = shared_position_faces[key]
        if not bucket then
            bucket = {}
            shared_position_faces[key] = bucket
        end
        -- a malformed/incomplete triangle can clamp two corners to the same
        -- stream vertex.  the previous per-corner used_faces table retained the
        -- first occurrence only, adjacent face indices are monotonic here, so a
        -- last-entry check is exactly equivalent
        if bucket[#bucket] ~= face_index then
            bucket[#bucket + 1] = face_index
        end
    end

    for tri_start = 1, vertex_count, 3 do
        local ia = tri_start
        local ib = math.min(tri_start + 1, vertex_count)
        local ic = math.min(tri_start + 2, vertex_count)
        local aidx = (ia - 1) * 3 + 1
        local bidx = (ib - 1) * 3 + 1
        local cidx = (ic - 1) * 3 + 1
        local ax, ay, az = positions[aidx] or 0, positions[aidx + 1] or 0, positions[aidx + 2] or 0
        local bx, by, bz = positions[bidx] or 0, positions[bidx + 1] or 0, positions[bidx + 2] or 0
        local cx, cy, cz = positions[cidx] or 0, positions[cidx + 1] or 0, positions[cidx + 2] or 0
        local raw_x, raw_y, raw_z = cross(
            bx - ax, by - ay, bz - az,
            cx - ax, cy - ay, cz - az
        )
        local weight = math.sqrt(raw_x * raw_x + raw_y * raw_y + raw_z * raw_z)
        local nx, ny, nz = normalize_or_fallback(raw_x, raw_y, raw_z, 0, 1, 0)
        local face_index = #face_nx + 1
        face_nx[face_index] = nx
        face_ny[face_index] = ny
        face_nz[face_index] = nz
        face_weight[face_index] = math.max(weight, 1e-6)
        remember_vertex(ia, face_index)
        remember_vertex(ib, face_index)
        remember_vertex(ic, face_index)
    end

    local normals = {}
    for vertex_index = 1, vertex_count do
        local base_index = vertex_face[vertex_index] or 1
        local base_nx = face_nx[base_index] or 0
        local base_ny = face_ny[base_index] or 1
        local base_nz = face_nz[base_index] or 0
        local pidx = (vertex_index - 1) * 3 + 1
        local bucket = shared_position_faces[vertex_position_key[vertex_index]]
        local sum_x, sum_y, sum_z = 0, 0, 0

        for bucket_index = 1, #(bucket or {}) do
            local face_index = bucket[bucket_index]
            local nx = face_nx[face_index]
            local ny = face_ny[face_index]
            local nz = face_nz[face_index]
            local agreement = dot(base_nx, base_ny, base_nz, nx, ny, nz)
            if agreement >= threshold then
                local weight = face_weight[face_index]
                sum_x = sum_x + nx * weight
                sum_y = sum_y + ny * weight
                sum_z = sum_z + nz * weight
            end
        end

        normals[pidx], normals[pidx + 1], normals[pidx + 2] = normalize_or_fallback(
            sum_x, sum_y, sum_z,
            base_nx, base_ny, base_nz
        )
    end

    return normals
end

local function build_basis_metadata(parsed, opts)
    local source_kind = type(parsed) == "table" and parsed.source_kind or nil
    if source_kind == "csg_mesh" or source_kind == "csg_physics" then
        -- flip_back_axis negates the part's +Z basis vector at render time, which is a
        -- real geometric reflection of the whole union
        --
        -- it should not exist. Roblox's baked CSG geometry is ALREADY in the union's
        -- local frame -- verified by decoding every union in three maps and comparing
        -- the mesh AABB against InitialSize: every union in three test places
        -- matches exactly and is centred on the part origin. That is the
        -- same statement the `return nil` below makes for plain meshes
        --
        -- Provenance: commit 8b309bab added this at the same time as {-1,-1} for plain
        -- meshes. the plain-mesh half was later proven to be a legacy 180-degree yaw
        -- bug and reverted to nil, the CSG half was never re-derived. it is a
        -- superseded calibration. it is invisible in bounds checks because a symmetric
        -- AABB is invariant under a Z reflection, but it relocates real geometry in
        -- most unions in the test places
        --
        -- removing it is COUPLED to correcting geometry.lua's FACE_AXES: the companion
        -- flag render.lua needs_csg_z_mirror is a Front<->Back face-name swap that
        -- compensates for FACE_AXES having inverted Z naming. drop one without the
        -- other and unions U-mirror on their +/-Z faces. both are therefore gated on
        -- the single `accurate_face_axes` option
        if opts and opts.accurate_face_axes then
            return nil
        end
        return {
            axis_x = 1,
            axis_z = 1,
            flip_back_axis = true,
        }
    end
    -- must stay nil: mesh local space IS part local space. {-1,-1} beats the default = 180deg yaw
    return nil
end

function mesh.canonicalize(parsed, opts)
    if type(parsed) ~= "table" then
        return parsed
    end

    opts = opts or {}
    if not parsed.bounds then
        parsed.bounds = compute_bounds(parsed.positions or {})
    end

    if parsed.source_kind == "csg_physics" or opts.recompute_normals == true or not normals_are_usable(parsed) then
        parsed.normals = recompute_smooth_normals(parsed, opts.crease_degrees or 65) or parsed.normals
    end

    parsed.basis = parsed.basis or build_basis_metadata(parsed, opts)
    parsed.uv_transform = parsed.uv_transform or {
        flip_u = false,
        flip_v = false,
        source = "preserved",
    }
    parsed.vertex_count = parsed.vertex_count or math.floor(#(parsed.positions or {}) / 3)
    parsed.triangle_count = parsed.triangle_count or math.floor((parsed.vertex_count or 0) / 3)
    parsed.index_count = parsed.index_count or parsed.vertex_count or 0
    parsed.has_uvs = type(parsed.uvs) == "table" and #parsed.uvs > 0
    parsed.has_normals = type(parsed.normals) == "table" and #parsed.normals > 0
    parsed.has_vertex_colors = type(parsed.colors) == "table" and #parsed.colors > 0
    parsed.has_tangents = type(parsed.tangents) == "table" and #parsed.tangents > 0
    parsed.uv_bounds = parsed.uv_bounds or compute_uv_bounds(parsed.uvs)
    parsed.uv_outside_unit_range = parsed.uv_bounds and parsed.uv_bounds.outside_unit == true or false
    parsed.winding_flipped = parsed.winding_flipped == true

    -- Lower LODs are independent flattened streams, not a retained copy of the
    -- source vertex/face graph. Canonicalize them once here so every renderer
    -- path (baked, instanced, decals, remote worker publication) sees the same
    -- contract as LOD0. keep the authoritative LOD0 bounds for every level:
    -- MeshPart scaling is defined against the asset bounds and must not resize
    -- as a lower-detail range happens to omit an extremal vertex
    local render_lods = parsed.render_lods
    if type(render_lods) == "table" and #render_lods > 1 then
        local parent_bounds = parsed.bounds
        for index = 1, #render_lods do
            local lod = render_lods[index]
            if type(lod) == "table" then
                lod.source_kind = parsed.source_kind
                lod.format_version = parsed.format_version
                lod.format_verified = parsed.format_verified
                lod.version = parsed.version
                lod.raw_size = parsed.raw_size
                lod.use_vertex_colors = parsed.use_vertex_colors
                lod.basis = parsed.basis
                lod.uv_transform = parsed.uv_transform
                lod.winding_flipped = parsed.winding_flipped
                mesh.canonicalize(lod, opts)
                lod.geometry_bounds = lod.bounds
                lod.bounds = parent_bounds
            end
        end
    end
    return parsed
end

function mesh.choose_preferred(...)
    local best, score = nil, -1
    for i = 1, select("#", ...) do
        local candidate = select(i, ...)
        local candidate_score = 0
        if candidate and candidate.source_kind == "csg_mesh" then
            candidate_score = 4
        elseif candidate and candidate.source_kind == "mesh" then
            candidate_score = 2
        elseif candidate and candidate.source_kind == "csg_physics" then
            candidate_score = 1
        end
        if candidate_score > score then
            best = candidate
            score = candidate_score
        end
    end
    return best
end

---the ONE mesh decoder. runtime/assets.lua used to carry a diverged fork of this
---function and of the twenty helpers below it, the fork is gone
---
---@return table|nil parsed
---@return string|nil reason  human-readable; nil only on success
---@return table|nil info     structured diagnosis, see `fail` -- info.code is a stable
---                           slug, exactly one per distinct failure mode, so callers
---                           can tally instead of pattern-matching prose
function mesh.parse(data, opts)
    opts = opts or {}
    if type(data) ~= "string" then
        return fail("payload_not_a_string", "mesh payload must be a string",
            { format = "unknown" })
    end

    local parsed, reason, info
    local version_key, format = read_mesh_version(data)
    if version_key then
        if not format then
            -- an EXPLICIT answer for a .mesh the decoder does not know, instead of
            -- falling through to the CSG probes and reporting "unsupported mesh
            -- payload" -- which reads like a corrupt file, not like a newer format
            return fail("mesh_version_unrecognised", string.format(
                "mesh %s: unknown container version (known: 1.00 1.01 2.00 3.00 3.01 "
                .. "4.00 4.01 5.00 6.00)", version_key),
                { format = "mesh", version = version_key })
        end
        if format.reader == "v1" then
            parsed, reason, info = parse_version_1_mesh(data, format.scale)
        elseif format.reader == "v2" then
            parsed, reason, info = parse_version_2_or_3_mesh(data, version_key)
        else
            parsed, reason, info = parse_version_4_to_6_mesh(
                data, version_key, format, opts)
        end
        if not parsed then
            return nil, reason, info
        end
        parsed.source_kind = "mesh"
        parsed.format_version = version_key
        parsed.format_verified = format.verified == true
        -- keep the original header for callers that inspect the source mesh version
        parsed.version = (format.reader == "v1")
            and trim(data:match("^([^\r\n]+)") or "")
            or data:sub(1, 12)
    elseif data:sub(1, 7) == "<roblox" then
        -- a nested .rbxm/.rbxlx container. Not a mesh payload and not corrupt: the
        -- caller is expected to walk it (assets.lua extract_renderable_mesh_data_from_
        -- asset) and try the payloads inside. Saying so by name matters -- a container
        -- reported as "no version line, no CSGMDL/CSGPHS/CSGK magic" sends the reader
        -- looking for a mesh format that was never there
        return fail("payload_is_container",
            "payload is a nested Roblox container, not a mesh; walk it for inner payloads",
            { format = "container", binary = data:sub(1, 8) == "<roblox!" })
    elseif data:sub(1, 4) == "CSGK" then
        -- "CSGK" + a 32-char content key. this is a REFERENCE to CSG data held by
        -- Roblox's asset service, not geometry -- there is nothing in the file to
        -- decode. 1 payload in assets/rbx/asset is one of these. it used to reach the
        -- CSGPHS reader, whose `signature == "CSGK"` guard compares a SIX-byte read
        -- against a four-character literal and therefore never fires, so it exited as
        -- the generic "unsupported mesh payload"
        return fail("csgk_reference_only",
            "csgk: content-key reference to external CSG data; the file holds no mesh",
            { format = "csgk", key = data:sub(5, 36) })
    else
        parsed, reason, info = parse_csg_mesh_data(data)
        if not parsed then
            local csgmdl_reason, csgmdl_info = reason, info
            -- keep the CSGPHS reason: "v0 primitive BLOCK" is a legitimate answer (the
            -- file holds no mesh) and must not be reported as corruption
            parsed, reason, info = parse_csg_physics_data(data)
            if not parsed then
                if reason == nil and csgmdl_reason ~= nil then
                    reason, info = csgmdl_reason, csgmdl_info
                end
                if reason == nil then
                    -- Include the leading bytes: this is the only bucket without a
                    -- format, so the head is the only lead the next person has. it is
                    -- how one place's 23 distinct `Model.ModelMeshData` blobs were
                    -- identified as a shared undocumented format (see docs/MESH-DECODER.md)
                    local head = data:sub(1, 8):gsub(".", function(c)
                        return string.format("%02X", c:byte())
                    end)
                    return fail("payload_unrecognised", string.format(
                        "unrecognised mesh payload (%d bytes, head %s; no version line, "
                        .. "no CSGMDL/CSGPHS/CSGK magic)", #data, head),
                        { format = "unknown", head = head })
                end
                return nil, reason, info
            end
        end
    end

    parsed.raw_size = #data
    return mesh.canonicalize(parsed, opts)
end

--- mesh.parse uses these error codes so callers can handle failures without matching messages
mesh.FAILURE_CODES = {
    payload = { "payload_not_a_string", "payload_unrecognised", "payload_is_container" },
    mesh = {
        "mesh_version_unrecognised",
        "mesh_v1_no_vertices", "mesh_v1_face_count_mismatch",
        "mesh_v2_truncated_header", "mesh_v2_bad_header_size", "mesh_v2_bad_strides",
        "mesh_v2_empty_counts", "mesh_v2_bad_lod_size", "mesh_v2_header_past_eof",
        "mesh_v2_truncated_vertices", "mesh_v2_truncated_faces", "mesh_v2_bad_face_indices",
        "mesh_v2_truncated_lods", "mesh_v2_no_geometry",
        "mesh_v4_truncated_header", "mesh_v4_bad_header_size", "mesh_v4_empty_counts",
        "mesh_v4_header_past_eof", "mesh_v4_truncated_vertices", "mesh_v4_truncated_envelopes",
        "mesh_v4_truncated_faces", "mesh_v4_bad_face_indices", "mesh_v4_truncated_lods",
        "mesh_v4_truncated_bones", "mesh_v4_truncated_bone_names", "mesh_v4_truncated_subsets",
        "mesh_v4_truncated_facs", "mesh_v4_no_geometry",
        "mesh_v6_layout_unverified",
    },
    csgmdl = {
        "csgmdl_deobfuscation_failed", "csgmdl_header_mismatch", "csgmdl_vertex_stride_too_small",
        "csgmdl_v5_bad_range_marker", "csgmdl_v5_index_stream", "csgmdl_no_geometry",
        "csgmdl_version_unsupported",
    },
    csgphs = {
        "csgphs_v0_primitive", "csgphs_v0_empty", "csgphs_v0_unknown_primitive",
        "csgphs_v8_zstd_unavailable", "csgphs_v8_truncated_container", "csgphs_v8_zstd_frame",
        "csgphs_v8_degenerate_header", "csgphs_v8_vertex_block_size", "csgphs_v8_euler_violation",
        "csgphs_v8_section_sizes", "csgphs_v8_degenerate_hull", "csgphs_v8_no_triangles",
        "csgphs_hull_record", "csgphs_v6_truncated_inertia", "csgphs_v7_subformat_tag",
        "csgphs_no_geometry", "csgphs_version_unsupported",
    },
    csgk = { "csgk_reference_only" },
}

---Failure codes that mean "the file legitimately holds no mesh", NOT "decoding
---broke". a caller should keep its part box and stay quiet for these
mesh.BENIGN_FAILURE_CODES = {
    csgphs_v0_primitive = true,
    csgphs_v0_empty = true,
    csgk_reference_only = true,
}

mesh.MESH_FORMATS = MESH_FORMATS

---inspect a CSGPHS payload without building its hull geometry
---@return table|nil  { version, kind = "primitive"|"hulls"|"unsupported",
---                     primitive, hull_count, vertex_count, face_count }
function mesh.describe_csg_physics(data)
    if type(data) ~= "string" or #data < 10 or data:sub(1, 6) ~= "CSGPHS" then
        return nil
    end
    local reader = Reader.new(data)
    reader:skip(6)
    local version = reader:uint32_le()
    if version == 0 then
        local token = trim(reader:read_string(reader:remaining()))
        return {
            version = 0,
            kind = "primitive",
            primitive = CSG_PHYSICS_PRIMITIVE_TOKENS[token] or token,
            recognised = CSG_PHYSICS_PRIMITIVE_TOKENS[token] ~= nil,
        }
    end
    if version == 8 then
        local decoded, err = decode_csg_physics_v8(data)
        if not decoded then
            return { version = 8, kind = "unsupported", error = err }
        end
        return {
            version = 8,
            kind = "hulls",
            hull_count = decoded.hull_count,
            vertex_count = decoded.vertex_count,
            face_count = decoded.face_count,
        }
    end
    if version == 3 or version == 5 or version == 6 or version == 7 then
        return { version = version, kind = "hulls" }
    end
    return { version = version, kind = "unsupported" }
end

---raw bytes of a DOM property that carries an opaque blob
---
---MeshData/PhysicsData reach here with different DOM type names depending on where
---they came from, and this used to accept only "BinaryString": the binary parser
---has always tagged them "String" (the binary format has no BinaryString type --
---binary.md:299-315), so an inline mesh blob in a .rbxl was never extracted, and
---the XML parser now tags them "String" too. Accepting the flat string, the legacy
---{ text, value } table and the SharedString wrapper covers every producer
local function blob_bytes(property)
    if type(property) ~= "table" then
        return nil
    end
    local raw = property.value
    if type(raw) == "string" then
        return raw ~= "" and raw or nil
    end
    if type(raw) == "table" then
        local bytes = raw.value or raw.text
        return type(bytes) == "string" and bytes ~= "" and bytes or nil
    end
    return nil
end

function mesh.extract_from_instance(instance)
    if type(instance) ~= "table" then
        return nil
    end

    local properties = instance.properties or {}
    local out = {}
    local model_mesh = properties.ModelMeshData or properties.MeshData
    local physics_data = properties.PhysicsData
    if model_mesh and model_mesh.type == "SharedString" then
        out.meshData = model_mesh.value and model_mesh.value.value or nil
        out.meshShared = model_mesh.value
    else
        out.meshData = blob_bytes(model_mesh)
    end
    out.physicsData = blob_bytes(physics_data)
    out.meshId = properties.MeshId and properties.MeshId.value or properties.MeshID and properties.MeshID.value or nil
    out.textureId = properties.TextureID and properties.TextureID.value or properties.TextureId and properties.TextureId.value or nil
    return out
end

return mesh
