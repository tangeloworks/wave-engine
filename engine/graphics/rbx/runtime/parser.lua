RBX._material_variants = RBX._material_variants
    or runtime_require("material_variants.lua")

RBX._size_validation = RBX._size_validation or runtime_require("size_validation.lua")
RBX._collision_group_policy = RBX._collision_group_policy or runtime_require("physics/collision_group_policy.lua")
RBX._collision_group_part = RBX._collision_group_part or runtime_require("physics/collision_group_part.lua")

BinaryReader = {}
BinaryReader.__index = BinaryReader

function BinaryReader.new(data)
    return setmetatable({
        data = data or "",
        pos = 1,
        len = #(data or ""),
    }, BinaryReader)
end

function BinaryReader:remaining()
    return self.len - self.pos + 1
end

function BinaryReader:skip(count)
    self.pos = math.min(self.len + 1, self.pos + (count or 0))
end

function BinaryReader:read_string(count)
    local c = math.max(0, count or 0)
    if c == 0 then
        return ""
    end
    local end_pos = self.pos + c - 1
    if end_pos > self.len then
        end_pos = self.len
    end
    local value = self.data:sub(self.pos, end_pos)
    self.pos = end_pos + 1
    return value
end

function BinaryReader:uint8()
    local b = self.data:byte(self.pos) or 0
    self.pos = self.pos + 1
    return b
end

function BinaryReader:int8()
    local b = self:uint8()
    if b >= 128 then
        return b - 256
    end
    return b
end

function BinaryReader:uint16_le()
    local a = self:uint8()
    local b = self:uint8()
    return a + b * 256
end

function BinaryReader:int16_le()
    local u = self:uint16_le()
    if u >= 32768 then
        return u - 65536
    end
    return u
end

function BinaryReader:uint32_le()
    local a = self:uint8()
    local b = self:uint8()
    local c = self:uint8()
    local d = self:uint8()
    return a + b * 256 + c * 65536 + d * 16777216
end

function BinaryReader:int32_le()
    local u = self:uint32_le()
    if u >= 2147483648 then
        return u - 4294967296
    end
    return u
end

function uint32_to_float(v)
    local sign = band(v, 0x80000000) ~= 0 and -1 or 1
    local exponent = band(rshift(v, 23), 0xFF)
    local mantissa = band(v, 0x7FFFFF)

    if exponent == 0 then
        if mantissa == 0 then
            return 0
        end
        return sign * (mantissa / 8388608) * 2 ^ (-126)
    end

    if exponent == 255 then
        if mantissa == 0 then
            return sign * math.huge
        end
        return 0 / 0
    end

    return sign * (1 + mantissa / 8388608) * 2 ^ (exponent - 127)
end

function BinaryReader:float32_le()
    local value
    value, self.pos = love.data.unpack("<f", self.data, self.pos)
    return value
end

function BinaryReader:float64_le()
    local value
    value, self.pos = love.data.unpack("<d", self.data, self.pos)
    return value
end

function read_binary_string(reader)
    local size = reader:uint32_le()
    if size <= 0 then
        return ""
    end
    return reader:read_string(size)
end

function interleaved_uint8(reader, count)
    local values = {}
    for i = 1, count do
        values[i] = reader:uint8()
    end
    return values
end

function interleaved_uint32(reader, count)
    local values = {}
    if count <= 0 then
        return values
    end

    local start = reader.pos
    local data = reader.data
    local stride = count
    for i = 0, count - 1 do
        local b0 = data:byte(start + i) or 0
        local b1 = data:byte(start + stride + i) or 0
        local b2 = data:byte(start + 2 * stride + i) or 0
        local b3 = data:byte(start + 3 * stride + i) or 0
        values[i + 1] = b0 * 16777216 + b1 * 65536 + b2 * 256 + b3
    end
    reader.pos = start + count * 4
    return values
end

function interleaved_int32(reader, count)
    local raw = interleaved_uint32(reader, count)
    for i = 1, count do
        local value = raw[i]
        if value % 2 == 1 then
            raw[i] = -((value + 1) / 2)
        else
            raw[i] = value / 2
        end
    end
    return raw
end

function interleaved_float(reader, count)
    local raw = interleaved_uint32(reader, count)
    for i = 1, count do
        local value = raw[i]
        local exponent = rshift(value, 24)
        if exponent == 0 then
            raw[i] = 0
        else
            local mantissa = band(rshift(value, 1), 0x7FFFFF)
            local out = 2 ^ (exponent - 127) * (1 + mantissa / 8388607)
            if band(value, 1) == 1 then
                out = -out
            end
            raw[i] = out
        end
    end
    return raw
end

function decode_lz4_block(input, expected_size)
    -- ffi lz4 decoder when size is known: the pure-lua path allocates 1 string/byte = seconds on big blobs
    if expected_size and expected_size > 0 then
        local ok_mod, binary_codec = pcall(require, "engine/graphics/rbx/binary")
        if ok_mod and binary_codec and binary_codec.decode_lz4_raw then
            local ok, decoded = pcall(binary_codec.decode_lz4_raw, input, expected_size)
            if ok and type(decoded) == "string" then
                if #decoded > expected_size then
                    return decoded:sub(1, expected_size)
                end
                return decoded
            end
        end
    end

    local in_pos = 1
    local in_len = #input
    local out = {}
    local out_len = 0

    local function push_byte(byte_value)
        out_len = out_len + 1
        out[out_len] = string.char(byte_value)
    end

    local function get_out_byte(idx)
        local ch = out[idx]
        if not ch then
            return 0
        end
        return ch:byte(1)
    end

    while in_pos <= in_len do
        local token = input:byte(in_pos) or 0
        in_pos = in_pos + 1

        local literal_length = rshift(token, 4)
        if literal_length == 15 then
            while in_pos <= in_len do
                local extension = input:byte(in_pos) or 0
                in_pos = in_pos + 1
                literal_length = literal_length + extension
                if extension ~= 255 then
                    break
                end
            end
        end

        for _ = 1, literal_length do
            if in_pos > in_len then
                break
            end
            push_byte(input:byte(in_pos) or 0)
            in_pos = in_pos + 1
        end

        if in_pos > in_len then
            break
        end

        local offset_lo = input:byte(in_pos) or 0
        local offset_hi = input:byte(in_pos + 1) or 0
        in_pos = in_pos + 2
        local offset = offset_lo + offset_hi * 256
        if offset <= 0 then
            break
        end

        local match_length = band(token, 0x0F) + 4
        if band(token, 0x0F) == 15 then
            while in_pos <= in_len do
                local extension = input:byte(in_pos) or 0
                in_pos = in_pos + 1
                match_length = match_length + extension
                if extension ~= 255 then
                    break
                end
            end
        end

        for _ = 1, match_length do
            local source_index = out_len - offset + 1
            push_byte(get_out_byte(source_index))
        end
    end

    local decoded = table.concat(out)
    if expected_size and expected_size > 0 and #decoded > expected_size then
        return decoded:sub(1, expected_size)
    end
    return decoded
end

function read_vector3(properties_block, property_name)
    local vector_block = find_named_block(properties_block, "Vector3", property_name)
    if not vector_block then
        return nil
    end
    return read_tag_number(vector_block, "X", 0),
        read_tag_number(vector_block, "Y", 0),
        read_tag_number(vector_block, "Z", 0)
end

function read_vector2(properties_block, property_name, default_x, default_y)
    local vector_block = find_named_block(properties_block, "Vector2", property_name)
    if not vector_block then
        return nil
    end
    return read_tag_number(vector_block, "X", default_x or 0),
        read_tag_number(vector_block, "Y", default_y or 0)
end

function read_cframe(properties_block, property_name)
    local cframe_block = find_named_block(properties_block, "CoordinateFrame", property_name)
    if not cframe_block then
        return nil
    end

    return {
        x = read_tag_number(cframe_block, "X", 0),
        y = read_tag_number(cframe_block, "Y", 0),
        z = read_tag_number(cframe_block, "Z", 0),
        r00 = read_tag_number(cframe_block, "R00", 1),
        r01 = read_tag_number(cframe_block, "R01", 0),
        r02 = read_tag_number(cframe_block, "R02", 0),
        r10 = read_tag_number(cframe_block, "R10", 0),
        r11 = read_tag_number(cframe_block, "R11", 1),
        r12 = read_tag_number(cframe_block, "R12", 0),
        r20 = read_tag_number(cframe_block, "R20", 0),
        r21 = read_tag_number(cframe_block, "R21", 0),
        r22 = read_tag_number(cframe_block, "R22", 1),
    }
end

local LEGACY_BODY_MOVER_CLASSES = {
    BodyAngularVelocity = true,
    BodyForce = true,
    BodyGyro = true,
    BodyPosition = true,
    BodyThrust = true,
    BodyVelocity = true,
}

local LEGACY_JOINT_INSTANCE_CLASSES = {
    ManualWeld = true,
    Motor = true,
    Motor6D = true,
    RotateV = true,
    Snap = true,
    Weld = true,
    WeldConstraint = true,
}

local function copy_runtime_vector3_entry(value)
    if type(value) ~= "table" then
        return nil
    end
    return {
        x = to_number(value.x or value.X or value[1], 0),
        y = to_number(value.y or value.Y or value[2], 0),
        z = to_number(value.z or value.Z or value[3], 0),
    }
end

local function read_tree_part_linear_velocity(instance)
    local value = copy_runtime_vector3_entry(instance.AssemblyLinearVelocity or instance.assemblylinearvelocity)
    if value then
        return value, "AssemblyLinearVelocity"
    end
    value = copy_runtime_vector3_entry(instance.Velocity or instance.velocity)
    if value then
        return value, "Velocity"
    end
    return nil, nil
end

local function read_tree_part_angular_velocity(instance)
    local value = copy_runtime_vector3_entry(instance.AssemblyAngularVelocity or instance.assemblyangularvelocity)
    if value then
        return value, "AssemblyAngularVelocity"
    end
    value = copy_runtime_vector3_entry(instance.RotVelocity or instance.rotvelocity)
    if value then
        return value, "RotVelocity"
    end
    return nil, nil
end

local function read_xml_part_linear_velocity(properties_block)
    local x, y, z = read_vector3(properties_block, "AssemblyLinearVelocity")
    if x ~= nil then
        return { x = x, y = y, z = z }, "AssemblyLinearVelocity"
    end
    x, y, z = read_vector3(properties_block, "Velocity")
    if x ~= nil then
        return { x = x, y = y, z = z }, "Velocity"
    end
    return nil, nil
end

local function read_xml_part_angular_velocity(properties_block)
    local x, y, z = read_vector3(properties_block, "AssemblyAngularVelocity")
    if x ~= nil then
        return { x = x, y = y, z = z }, "AssemblyAngularVelocity"
    end
    x, y, z = read_vector3(properties_block, "RotVelocity")
    if x ~= nil then
        return { x = x, y = y, z = z }, "RotVelocity"
    end
    return nil, nil
end

local function source_group_property(primary, secondary)
    if primary ~= nil then return primary end
    return secondary
end

local function normalize_collision_group_name(raw_value, explicit_name)
    if explicit_name ~= nil then
        assert(type(explicit_name) == "string", "Authored CollisionGroup must be a string")
        return explicit_name == "" and "Default" or explicit_name
    end
    local numeric = read_numeric_token(raw_value, nil)
    if numeric == nil or numeric == 0 then
        return "Default"
    end
    return "Group" .. tostring(math.floor(numeric))
end

-- .rbxlx dom emits camelCase frictionWeight/elasticityWeight, so accept all 3 spellings
local function clone_custom_physical_properties(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local friction_weight = entry.friction_weight or entry.FrictionWeight or entry[4]
        or entry.frictionWeight
    local elasticity_weight = entry.elasticity_weight or entry.ElasticityWeight or entry[5]
        or entry.elasticityWeight
    local acoustic_absorption = entry.acoustic_absorption or entry.AcousticAbsorption or entry[6]
        or entry.acousticAbsorption
    return {
        density = read_numeric_token(entry.density or entry.Density or entry[1], nil),
        friction = read_numeric_token(entry.friction or entry.Friction or entry[2], nil),
        elasticity = read_numeric_token(entry.elasticity or entry.Elasticity or entry[3], nil),
        friction_weight = read_numeric_token(friction_weight, nil),
        elasticity_weight = read_numeric_token(elasticity_weight, nil),
        acoustic_absorption = read_numeric_token(acoustic_absorption, nil),
        friction_combine = entry.friction_combine or entry.FrictionCombine or nil,
        elasticity_combine = entry.elasticity_combine or entry.ElasticityCombine or nil,
    }
end

local function parse_tree_custom_physical_properties(raw_value)
    if type(raw_value) ~= "table" then
        return nil
    end
    local custom = raw_value.CustomPhysics
    if custom == nil then
        custom = raw_value.customphysics
    end
    if custom == false or custom == "false" then
        return nil
    end
    local entry = clone_custom_physical_properties(raw_value)
    if not entry then
        return nil
    end
    if entry.density == nil and entry.friction == nil and entry.elasticity == nil
        and entry.friction_weight == nil and entry.elasticity_weight == nil
        and entry.acoustic_absorption == nil then
        return nil
    end
    return entry
end

local function parse_xml_custom_physical_properties(properties_block)
    local block = find_named_block(properties_block, "PhysicalProperties", "CustomPhysicalProperties")
    if type(block) ~= "string" then
        return nil
    end
    local custom_raw = block:match("<CustomPhysics>([^<]+)</CustomPhysics>")
    if type(custom_raw) ~= "string" or trim(custom_raw):lower() ~= "true" then
        return nil
    end
    local entry = {
        density = read_tag_number(block, "Density", nil),
        friction = read_tag_number(block, "Friction", nil),
        elasticity = read_tag_number(block, "Elasticity", nil),
        friction_weight = read_tag_number(block, "FrictionWeight", nil),
        elasticity_weight = read_tag_number(block, "ElasticityWeight", nil),
        acoustic_absorption = read_tag_number(block, "AcousticAbsorption", nil),
    }
    if entry.density == nil and entry.friction == nil and entry.elasticity == nil
        and entry.friction_weight == nil and entry.elasticity_weight == nil
        and entry.acoustic_absorption == nil then
        return nil
    end
    return entry
end

BRICK_COLORS = {
    [1] = { 242, 243, 243 },
    [2] = { 161, 165, 162 },
    [3] = { 249, 233, 153 },
    [5] = { 215, 197, 154 },
    [6] = { 194, 218, 184 },
    [9] = { 232, 186, 200 },
    [11] = { 128, 187, 219 },
    [12] = { 203, 132, 66 },
    [18] = { 204, 142, 105 },
    [21] = { 196, 40, 28 },
    [22] = { 196, 112, 160 },
    [23] = { 13, 105, 172 },
    [24] = { 245, 205, 48 },
    [25] = { 98, 71, 50 },
    [26] = { 27, 42, 53 },
    [27] = { 109, 110, 108 },
    [28] = { 40, 127, 71 },
    [29] = { 161, 196, 140 },
    [37] = { 75, 151, 75 },
    [38] = { 160, 95, 53 },
    [39] = { 193, 202, 222 },
    [40] = { 236, 236, 236 },
    [41] = { 205, 84, 75 },
    [42] = { 193, 223, 240 },
    [43] = { 123, 182, 232 },
    [44] = { 247, 241, 141 },
    [45] = { 180, 210, 228 },
    [47] = { 217, 133, 108 },
    [48] = { 132, 182, 141 },
    [49] = { 248, 241, 132 },
    [50] = { 236, 232, 222 },
    [102] = { 110, 153, 202 },
    [104] = { 107, 50, 124 },
    [105] = { 226, 155, 64 },
    [106] = { 218, 133, 65 },
    [107] = { 0, 143, 156 },
    [110] = { 67, 84, 147 },
    [112] = { 104, 116, 172 },
    [119] = { 164, 189, 71 },
    [120] = { 217, 228, 167 },
    [128] = { 174, 122, 89 },
    [131] = { 156, 163, 168 },
    [135] = { 116, 134, 157 },
    [136] = { 135, 124, 144 },
    [140] = { 32, 58, 86 },
    [141] = { 39, 70, 45 },
    [145] = { 121, 136, 161 },
    [151] = { 120, 144, 130 },
    [154] = { 123, 46, 47 },
    [176] = { 151, 105, 91 },
    [179] = { 137, 135, 136 },
    [192] = { 105, 64, 40 },
    [194] = { 163, 162, 165 },
    [195] = { 70, 103, 164 },
    [196] = { 35, 71, 139 },
    [199] = { 99, 95, 98 },
    [208] = { 229, 228, 223 },
    [213] = { 108, 129, 183 },
    [221] = { 205, 98, 152 },
    [226] = { 253, 234, 141 },
    [301] = { 80, 109, 84 },
    [302] = { 91, 93, 105 },
    [303] = { 0, 16, 176 },
    [304] = { 44, 101, 29 },
    [311] = { 159, 161, 172 },
    [315] = { 9, 137, 207 },
    [320] = { 202, 203, 209 },
    [333] = { 239, 184, 56 },
    [334] = { 248, 217, 109 },
    [335] = { 231, 231, 236 },
    [337] = { 255, 148, 148 },
    [338] = { 190, 104, 98 },
    [341] = { 254, 243, 187 },
    [348] = { 237, 234, 234 },
    [349] = { 233, 218, 218 },
    [350] = { 136, 62, 62 },
    [365] = { 106, 57, 9 },
}

function color3uint8_to_rgb(decimal_string)
    local numeric = tonumber(decimal_string)
    if not numeric then
        return 255, 255, 255
    end
    if numeric < 0 then
        numeric = numeric + 4294967296
    end

    local hex = string.format("%08X", numeric)
    local r = tonumber(hex:sub(3, 4), 16) or 255
    local g = tonumber(hex:sub(5, 6), 16) or 255
    local b = tonumber(hex:sub(7, 8), 16) or 255
    return r, g, b
end

function read_part_color(properties_block)
    local color_value = find_named_value(properties_block, "Color3uint8", "Color3uint8")
    if color_value then
        return color3uint8_to_rgb(color_value)
    end

    local color3 = read_named_color3(properties_block, "Color")
    if color3 then
        return clamp(math.floor(color3[1] * 255 + 0.5), 0, 255),
            clamp(math.floor(color3[2] * 255 + 0.5), 0, 255),
            clamp(math.floor(color3[3] * 255 + 0.5), 0, 255)
    end

    local brick_color_id = tonumber(find_named_value(properties_block, "int", "BrickColor"))
    local color = brick_color_id and BRICK_COLORS[brick_color_id]
    if color then
        return color[1], color[2], color[3]
    end

    return 200, 200, 200
end

SUPPORTED_PART_CLASSES = {
    Part = true,
    SpawnLocation = true,
    WedgePart = true,
    CornerWedgePart = true,
    TrussPart = true,
    Seat = true,
    VehicleSeat = true,
    MeshPart = true,
    UnionOperation = true,
    PartOperation = true,
    -- NegateOperation deliberately absent: free-floating negate volumes are CSG
    -- operands, invisible and non-colliding in-game (Studio shows them red only in
    -- the editor). Rendering them drew giant solid blocks over the map
}

function is_csg_part_class(class_name)
    return class_name == "UnionOperation" or class_name == "PartOperation" or class_name == "NegateOperation"
end

local function part_supports_surface_appearance(class_name, mesh_owner)
    if class_name == "MeshPart" or is_csg_part_class(class_name) then
        return true
    end
    if type(mesh_owner) == "table" then
        mesh_owner = mesh_owner.ClassName or mesh_owner.className or mesh_owner.class_name
    end
    return mesh_owner == "SpecialMesh"
end

function find_matching_item_close(xml, start_position)
    local depth = 1
    local cursor = start_position

    while depth > 0 do
        local next_open = xml:find("<Item", cursor, true)
        local next_close_start, next_close_end = xml:find("</Item>", cursor, true)
        if not next_close_start then
            return nil, nil
        end

        if next_open and next_open < next_close_start then
            depth = depth + 1
            cursor = next_open + 5
        else
            depth = depth - 1
            cursor = next_close_end + 1
            if depth == 0 then
                return next_close_start, next_close_end
            end
        end
    end

    return nil, nil
end

function find_item_body_by_class(xml, target_class)
    local cursor = 1
    while true do
        local item_start, item_tag_end, class_name = xml:find("<Item%s+class=\"([^\"]+)\"[^>]*>", cursor)
        if not item_start then
            return nil
        end

        if class_name == target_class then
            local close_start, close_end = find_matching_item_close(xml, item_tag_end + 1)
            if close_start and close_end then
                return xml:sub(item_tag_end + 1, close_start - 1)
            end
            return nil
        end

        cursor = item_tag_end + 1
    end
end

function compute_sun_direction(clock_hours, geographic_latitude)
    local hours = (clock_hours or 14) % 24
    local latitude = math.abs(geographic_latitude or 35)
    local latitude_factor = clamp(math.cos(math.rad(latitude)), 0.25, 1.0)

    -- 6:00/18:00 near horizon, 12:00 near apex
    local day_arc = ((hours - 6) / 12) * math.pi
    local y = math.sin(day_arc) * latitude_factor
    local horizontal = math.sqrt(math.max(0.0001, 1 - y * y))

    local azimuth = (hours / 24) * (math.pi * 2)
    local x = math.cos(azimuth) * horizontal
    local z = math.sin(azimuth) * horizontal

    return normalize_or_fallback(x, y, z, 0.4, 1.0, 0.25)
end

function clock_hours_to_time_of_day(clock_hours)
    local hours = clamp(tonumber(clock_hours) or 14, 0, 24)
    local total_seconds = math.floor((hours % 24) * 3600 + 0.5) % 86400
    local h = math.floor(total_seconds / 3600)
    local m = math.floor((total_seconds % 3600) / 60)
    local s = total_seconds % 60
    return ("%02d:%02d:%02d"):format(h, m, s)
end

function lighting_get_minutes_after_midnight(clock_hours)
    return math.floor(((tonumber(clock_hours) or 14) % 24) * 60 + 0.5)
end

function normalize_lighting_enum_value(value)
    if value == nil then
        return nil
    end
    if type(value) == "table" then
        return normalize_lighting_enum_value(value.Name or value.name or value.Value or value.value or value[1])
    end
    local text = trim(tostring(value))
    if text == "" then
        return nil
    end
    return text
end

function read_named_token_string(properties_block, property_name)
    return normalize_lighting_enum_value(find_named_value(properties_block, "token", property_name))
        or normalize_lighting_enum_value(find_named_value(properties_block, "string", property_name))
        or normalize_lighting_enum_value(find_named_value(properties_block, "int", property_name))
end

function max3_per_channel(a, b)
    return {
        math.max(a[1] or 0, b[1] or 0),
        math.max(a[2] or 0, b[2] or 0),
        math.max(a[3] or 0, b[3] or 0),
    }
end

function read_sky_settings_from_properties(properties_block, source_name)
    if not properties_block then
        return nil
    end

    local sky = {
        SkyboxBk = find_named_content_value(properties_block, "SkyboxBk") or
            find_named_value(properties_block, "string", "SkyboxBk"),
        SkyboxDn = find_named_content_value(properties_block, "SkyboxDn") or
            find_named_value(properties_block, "string", "SkyboxDn"),
        SkyboxFt = find_named_content_value(properties_block, "SkyboxFt") or
            find_named_value(properties_block, "string", "SkyboxFt"),
        SkyboxLf = find_named_content_value(properties_block, "SkyboxLf") or
            find_named_value(properties_block, "string", "SkyboxLf"),
        SkyboxRt = find_named_content_value(properties_block, "SkyboxRt") or
            find_named_value(properties_block, "string", "SkyboxRt"),
        SkyboxUp = find_named_content_value(properties_block, "SkyboxUp") or
            find_named_value(properties_block, "string", "SkyboxUp"),
        SunTextureId = find_named_content_value(properties_block, "SunTextureId") or
            find_named_value(properties_block, "string", "SunTextureId"),
        MoonTextureId = find_named_content_value(properties_block, "MoonTextureId") or
            find_named_value(properties_block, "string", "MoonTextureId"),
        SunAngularSize = read_named_number(properties_block, "SunAngularSize", nil),
        MoonAngularSize = read_named_number(properties_block, "MoonAngularSize", nil),
        StarCount = read_named_number(properties_block, "StarCount", nil),
        CelestialBodiesShown = read_named_bool(properties_block, "CelestialBodiesShown", nil),
        SkyboxOrientation = find_named_block(properties_block, "Vector3", "SkyboxOrientation")
            or find_named_block(properties_block, "Vector3int16", "SkyboxOrientation"),
        source = source_name or "rbxlx_sky",
    }

    -- sky instance present: return a valid record even if all faces blank, renderer honors it
    return sky
end

function RBX._build_lighting_state(raw)
    raw = type(raw) == "table" and raw or {}

    local ambient = normalize_color3(raw.ambient or raw.Ambient, 0, 0, 0)
    local outdoor = normalize_color3(raw.outdoor_ambient or raw.OutdoorAmbient, 0.5, 0.5, 0.5)
    local color_shift_top = normalize_color3(raw.color_shift_top or raw.ColorShift_Top, 0, 0, 0)
    local color_shift_bottom = normalize_color3(raw.color_shift_bottom or raw.ColorShift_Bottom, 0, 0, 0)
    local fog_color = normalize_color3(raw.fog_color or raw.FogColor, 0.75, 0.75, 0.75)

    local brightness = math.max(0, to_number(raw.brightness or raw.Brightness, 1.0))
    local exposure = clamp(to_number(raw.exposure_compensation or raw.ExposureCompensation, 0.0), -5, 5)
    local environment_diffuse = clamp(to_number(raw.environment_diffuse_scale or raw.EnvironmentDiffuseScale, 0.0), 0, 1)
    local environment_specular = clamp(to_number(raw.environment_specular_scale or raw.EnvironmentSpecularScale, 0.0), 0, 1)
    local geographic_latitude = clamp(to_number(raw.geographic_latitude or raw.GeographicLatitude, 35.0), -90, 90)

    local global_shadows = raw.global_shadows
    if global_shadows == nil then
        global_shadows = raw.GlobalShadows
    end
    if global_shadows == nil then
        global_shadows = true
    end
    if type(global_shadows) == "string" then
        global_shadows = safe_lower(global_shadows) == "true"
    end
    global_shadows = global_shadows == true

    local raw_clock_time = to_number(raw.clock_time or raw.ClockTime, nil)
    local time_of_day = type(raw.time_of_day or raw.TimeOfDay) == "string" and (raw.time_of_day or raw.TimeOfDay) or nil
    local clock_time = clamp(parse_time_of_day_hours(time_of_day, raw_clock_time), 0, 24)
    local normalized_time_of_day = clock_hours_to_time_of_day(clock_time)
    local minutes_after_midnight = lighting_get_minutes_after_midnight(clock_time)

    local sun_dir_x, sun_dir_y, sun_dir_z = compute_sun_direction(clock_time, geographic_latitude)
    local moon_dir_x, moon_dir_y, moon_dir_z = normalize_or_fallback(-sun_dir_x, -sun_dir_y, -sun_dir_z, -0.4, -1.0, -0.25)
    local sun_elevation = clamp(sun_dir_y, -1, 1)
    local moon_elevation = clamp(moon_dir_y, -1, 1)

    -- clocktime = celestial clock (sun down, moon takes over). continuous blend so sunrise/sunset dont snap
    local daylight = clamp((sun_elevation + 0.08) / 0.62, 0, 1)
    local moonlight = clamp((-sun_elevation + 0.04) / 0.70, 0, 1)
    local twilight = 1 - daylight
    local night_factor = clamp(twilight, 0, 1)
    local use_moon = daylight <= 0.05 and moonlight > 0
    local active_dir = use_moon and { moon_dir_x, moon_dir_y, moon_dir_z } or { sun_dir_x, sun_dir_y, sun_dir_z }
    -- Brightness scales the direct source. HDR/display mapping owns saturation;
    -- an arbitrary pre-light clamp made authored values above 2.5 ineffective
    local directional_intensity = math.max(0,
        brightness * (use_moon and (0.36 * moonlight) or daylight))

    local night_sky_tint = { 0.055, 0.100, 0.145 }
    local day_sky_floor = { 0.55, 0.62, 0.72 }

    local effective_ambient = clone3(ambient)
    local effective_outdoor_raw = global_shadows and max3_per_channel(outdoor, ambient) or clone3(ambient)
    -- Authored ambient hues are independent of the celestial clock. Sky-derived
    -- illumination may change with time, OutdoorAmbient itself must not
    local effective_outdoor = clone3(effective_outdoor_raw)
    local sky_ambient = {
        math.max(effective_outdoor[1] - effective_ambient[1], 0),
        math.max(effective_outdoor[2] - effective_ambient[2], 0),
        math.max(effective_outdoor[3] - effective_ambient[3], 0),
    }

    -- sky color = what reflections sample for up. ambient+fog by day, cool tint by night
    local day_sky_color = lerp3(effective_outdoor_raw, fog_color, clamp(0.20 + environment_diffuse * 0.25, 0, 0.55))
    day_sky_color = {
        clamp(math.max(day_sky_color[1], day_sky_floor[1]) + color_shift_top[1] * 0.18, 0, 1),
        clamp(math.max(day_sky_color[2], day_sky_floor[2]) + color_shift_top[2] * 0.18, 0, 1),
        clamp(math.max(day_sky_color[3], day_sky_floor[3]) + color_shift_top[3] * 0.18, 0, 1),
    }
    local night_sky_color = {
        clamp(night_sky_tint[1] + effective_ambient[1] * 0.4 + color_shift_top[1] * 0.1, 0, 1),
        clamp(night_sky_tint[2] + effective_ambient[2] * 0.4 + color_shift_top[2] * 0.1, 0, 1),
        clamp(night_sky_tint[3] + effective_ambient[3] * 0.4 + color_shift_top[3] * 0.1, 0, 1),
    }
    local sky_color = lerp3(day_sky_color, night_sky_color, night_factor)

    local ground_color = {
        clamp(effective_ambient[1] + color_shift_bottom[1] * 0.28, 0, 1),
        clamp(effective_ambient[2] + color_shift_bottom[2] * 0.28, 0, 1),
        clamp(effective_ambient[3] + color_shift_bottom[3] * 0.28, 0, 1),
    }
    ground_color = lerp3(ground_color, mul3(ground_color, { 0.30, 0.34, 0.42 }), night_factor)

    local color_correction_post = raw.post_effects and raw.post_effects.color_correction
    if raw.tint_color and not (color_correction_post and color_correction_post.Enabled ~= false) then
        local tint = normalize_color3(raw.tint_color, 1, 1, 1)
        sky_color = mul3(sky_color, tint)
        ground_color = mul3(ground_color, tint)
        effective_ambient = mul3(effective_ambient, tint)
        effective_outdoor = mul3(effective_outdoor, tint)
    end

    -- twilight peaks at sunrise/sunset, zero at noon/midnight. blends in warm horizon color
    local twilight_window = clamp(1 - math.abs(sun_elevation) / 0.50, 0, 1)
    local twilight_factor = clamp(twilight_window * twilight_window * twilight_window, 0, 1)
    local twilight_tint = { 1.00, 0.66, 0.48 }
    local day_tint = { 1.00, 1.00, 1.00 }
    local night_tint = { 0.20, 0.26, 0.50 }
    -- multiplies configured skybox textures. shader's .a = night_factor
    local sky_time_rgb = lerp3(day_tint, night_tint, night_factor)
    sky_time_rgb = lerp3(sky_time_rgb, twilight_tint, twilight_factor * 0.45)

    -- solid color for a blank sky face. night fallback is dark blue/teal, not pure black
    local day_blank_color = {
        clamp(0.62 + color_shift_top[1] * 0.06, 0, 1),
        clamp(0.74 + color_shift_top[2] * 0.06, 0, 1),
        clamp(0.92 + color_shift_top[3] * 0.06, 0, 1),
    }
    -- dark blue/teal baseline, ambient above roblox defaults folds in as a lift
    local function outdoor_lift(channel_index)
        local outdoor_v = outdoor[channel_index] or 0
        local lift = math.max(0, outdoor_v - 0.50) * 0.30
        return lift
    end
    local night_blank_color = {
        clamp(0.004 + effective_ambient[1] * 0.08 + outdoor_lift(1) + color_shift_top[1] * 0.02, 0, 1),
        clamp(0.012 + effective_ambient[2] * 0.08 + outdoor_lift(2) + color_shift_top[2] * 0.02, 0, 1),
        clamp(0.018 + effective_ambient[3] * 0.10 + outdoor_lift(3) + color_shift_top[3] * 0.02, 0, 1),
    }
    local twilight_blank_color = {
        clamp(0.85 + color_shift_top[1] * 0.10, 0, 1),
        clamp(0.55 + color_shift_top[2] * 0.10, 0, 1),
        clamp(0.40 + color_shift_top[3] * 0.10, 0, 1),
    }
    local sky_blank_color = lerp3(day_blank_color, night_blank_color, night_factor)
    sky_blank_color = lerp3(sky_blank_color, twilight_blank_color, twilight_factor * 0.55)

    -- scales skybox texel brightness: full at noon, dimmed at midnight, no floor
    local sky_exposure = clamp(0.04 + (1 - night_factor) * 1.06, 0.04, 1.10)

    -- night cooler/dimmer but not off: 15% diffuse at midnight kills the cool fill studio has
    local effective_environment_diffuse = clamp(environment_diffuse * (1 - night_factor * 0.45), 0, 1)
    local effective_environment_specular = clamp(environment_specular * (1 - night_factor * 0.60), 0, 1)

    -- ambient is already a light color, keep scalar near 1 or it acts as a tiny multiplier
    local ambient_strength = clamp(0.78 + effective_environment_diffuse * 0.22, 0.55, 1.08)
    local diffuse_strength = clamp(0.72 + effective_environment_diffuse * 0.18, 0.30, 1.20)
    local specular_strength = clamp(
        effective_environment_specular * 0.36 + directional_intensity * 0.015,
        0, 0.65
    )
    local rim_strength = clamp(
        effective_environment_specular * 0.055,
        0, 0.18
    )

    local fog_start = math.max(0, to_number(raw.fog_start or raw.FogStart, 0))
    local fog_end = to_number(raw.fog_end or raw.FogEnd, 100000)
    if fog_end == nil or fog_end ~= fog_end then
        fog_end = 100000
    end
    fog_end = math.max(fog_start + 0.001, fog_end)
    local fog_enabled = fog_end < 99999 and fog_end > fog_start

    local prioritize = raw.prioritize_lighting_quality
    if prioritize == nil then prioritize = raw.PrioritizeLightingQuality end

    local outlines = raw.outlines
    if outlines == nil then
        outlines = raw.Outlines
    end

    local computed_environment_diffuse = {
        clamp(effective_outdoor[1] * effective_environment_diffuse, 0, 1),
        clamp(effective_outdoor[2] * effective_environment_diffuse, 0, 1),
        clamp(effective_outdoor[3] * effective_environment_diffuse, 0, 1),
    }
    local computed_environment_specular = {
        clamp(sky_color[1] * effective_environment_specular, 0, 1),
        clamp(sky_color[2] * effective_environment_specular, 0, 1),
        clamp(sky_color[3] * effective_environment_specular, 0, 1),
    }

    local atmosphere = raw.atmosphere
    local atmosphere_density = clamp(to_number(
        atmosphere and (atmosphere.Density or atmosphere.density),
        RBX._ATMOSPHERE_DEFAULTS.Density), 0, 1)
    local atmosphere_offset = clamp(to_number(
        atmosphere and (atmosphere.Offset or atmosphere.offset),
        RBX._ATMOSPHERE_DEFAULTS.Offset), -1, 1)
    local atmosphere_color = normalize_color3(atmosphere and (atmosphere.Color or atmosphere.color),
        RBX._ATMOSPHERE_DEFAULTS.Color[1],
        RBX._ATMOSPHERE_DEFAULTS.Color[2],
        RBX._ATMOSPHERE_DEFAULTS.Color[3])
    local atmosphere_decay = normalize_color3(atmosphere and (atmosphere.Decay or atmosphere.decay),
        RBX._ATMOSPHERE_DEFAULTS.Decay[1],
        RBX._ATMOSPHERE_DEFAULTS.Decay[2],
        RBX._ATMOSPHERE_DEFAULTS.Decay[3])
    local atmosphere_haze = clamp(to_number(
        atmosphere and (atmosphere.Haze or atmosphere.haze),
        RBX._ATMOSPHERE_DEFAULTS.Haze), 0, 10)
    local atmosphere_glare = clamp(to_number(
        atmosphere and (atmosphere.Glare or atmosphere.glare),
        RBX._ATMOSPHERE_DEFAULTS.Glare), 0, 10)
    local atmosphere_present = raw.atmosphere_present == true or atmosphere ~= nil

    local state = {
        kind = "LightingState",
        source = raw.source or "lighting",
        clock_time = clock_time,
        time_hours = clock_time,
        time_of_day = normalized_time_of_day,
        minutes_after_midnight = minutes_after_midnight,
        geographic_latitude = geographic_latitude,
        ambient_color = ambient,
        outdoor_ambient = outdoor,
        effective_ambient = effective_ambient,
        effective_outdoor_ambient = effective_outdoor,
        effective_outdoor_ambient_raw = effective_outdoor_raw,
        sky_ambient = sky_ambient,
        brightness = brightness,
        directional_intensity = directional_intensity,
        global_shadows = global_shadows,
        color_shift_top = color_shift_top,
        color_shift_bottom = color_shift_bottom,
        exposure_compensation = exposure,
        exposure_multiplier = math.pow(2, exposure),
        environment_diffuse_scale = environment_diffuse,
        environment_specular_scale = environment_specular,
        effective_environment_diffuse_scale = effective_environment_diffuse,
        effective_environment_specular_scale = effective_environment_specular,
        computed_environment_diffuse = computed_environment_diffuse,
        computed_environment_specular = computed_environment_specular,
        fog_color = fog_color,
        fog_start = fog_start,
        fog_end = fog_end,
        -- Roblox hides Lighting.Fog* whenever an Atmosphere child exists
        -- retain the authored range for runtime round-trips/diagnostics, but
        -- never apply both extinction models to the same fragment
        fog_enabled = fog_enabled and atmosphere == nil,
        legacy_fog_suppressed_by_atmosphere =
            fog_enabled and atmosphere ~= nil,
        shadow_softness = clamp(to_number(raw.shadow_softness or raw.ShadowSoftness, 0.2), 0, 1),
        lighting_style = normalize_lighting_enum_value(raw.lighting_style or raw.LightingStyle),
        technology = normalize_lighting_enum_value(raw.technology or raw.Technology),
        outlines = outlines,
        prioritize_lighting_quality = prioritize,
        atmosphere_present = atmosphere_present,
        atmosphere_supported = atmosphere ~= nil,
        atmosphere = atmosphere and {
            density = atmosphere_density,
            offset = atmosphere_offset,
            color = atmosphere_color,
            decay = atmosphere_decay,
            haze = atmosphere_haze,
            glare = atmosphere_glare,
        } or nil,
        sky = raw.sky,
        sky_time_tint = sky_time_rgb,
        sky_blank_color = sky_blank_color,
        sky_exposure = sky_exposure,
        twilight_factor = twilight_factor,
        post_effects = raw.post_effects,
        sun_direction = { sun_dir_x, sun_dir_y, sun_dir_z },
        moon_direction = { moon_dir_x, moon_dir_y, moon_dir_z },
        sun_elevation = sun_elevation,
        moon_elevation = moon_elevation,
        light_direction = active_dir,
        daylight_factor = daylight,
        moonlight_factor = moonlight,
        night_factor = night_factor,
        use_moon = use_moon,
        sky_color = sky_color,
        ground_color = ground_color,
        ambient = ambient_strength,
        diffuse_strength = diffuse_strength,
        specular_strength = specular_strength,
        rim_strength = rim_strength,
    }

    state.deprecated = {
        technology = state.technology,
        outlines = state.outlines,
    }

    return state
end

function parse_lighting_settings(xml)
    local lighting_body = find_item_body_by_class(xml, "Lighting")
    if not lighting_body then
        return nil
    end

    local properties_block = lighting_body:match("<Properties>(.-)</Properties>")
    if not properties_block then
        return nil
    end

    local tint_color
    local color_correction_settings
    do
        local cc_body = find_item_body_by_class(lighting_body, "ColorCorrectionEffect")
        if cc_body then
            local cc_properties = cc_body:match("<Properties>(.-)</Properties>")
            if cc_properties then
                local enabled = read_named_bool(cc_properties, "Enabled", true)
                color_correction_settings = {
                    Enabled = enabled,
                    Brightness = read_named_number(cc_properties, "Brightness", 0),
                    Contrast = read_named_number(cc_properties, "Contrast", 0),
                    Saturation = read_named_number(cc_properties, "Saturation", 0),
                    TintColor = read_named_color3(cc_properties, "TintColor"),
                }
                if enabled then
                    tint_color = color_correction_settings.TintColor
                end
            end
        end
    end

    local bloom_body = find_item_body_by_class(lighting_body, "BloomEffect")
    local bloom_settings = nil
    if bloom_body then
        local bloom_properties = bloom_body:match("<Properties>(.-)</Properties>")
        if bloom_properties then
            bloom_settings = {
                Enabled = read_named_bool(bloom_properties, "Enabled", true),
                Intensity = read_named_number(bloom_properties, "Intensity", 0.4),
                Size = read_named_number(bloom_properties, "Size", 24),
                Threshold = read_named_number(bloom_properties, "Threshold", 0.95),
            }
        end
    end

    local blur_body = find_item_body_by_class(lighting_body, "BlurEffect")
    local blur_settings = nil
    if blur_body then
        local blur_properties = blur_body:match("<Properties>(.-)</Properties>")
        if blur_properties then
            blur_settings = {
                Enabled = read_named_bool(blur_properties, "Enabled", true),
                Size = read_named_number(blur_properties, "Size", 0),
            }
        end
    end

    local sun_rays_body = find_item_body_by_class(lighting_body, "SunRaysEffect")
    local sun_rays_settings = nil
    if sun_rays_body then
        local sun_rays_properties = sun_rays_body:match("<Properties>(.-)</Properties>")
        if sun_rays_properties then
            sun_rays_settings = {
                Enabled = read_named_bool(sun_rays_properties, "Enabled", true),
                Intensity = read_named_number(sun_rays_properties, "Intensity", 0.25),
                Spread = read_named_number(sun_rays_properties, "Spread", 1.0),
            }
        end
    end

    local depth_of_field_body = find_item_body_by_class(lighting_body, "DepthOfFieldEffect")
    local depth_of_field_settings = nil
    if depth_of_field_body then
        local dof_properties = depth_of_field_body:match("<Properties>(.-)</Properties>")
        if dof_properties then
            depth_of_field_settings = {
                Enabled = read_named_bool(dof_properties, "Enabled", true),
                FarIntensity = read_named_number(dof_properties, "FarIntensity", 0),
                FocusDistance = read_named_number(dof_properties, "FocusDistance", 0),
                InFocusRadius = read_named_number(dof_properties, "InFocusRadius", 50),
                NearIntensity = read_named_number(dof_properties, "NearIntensity", 0),
            }
        end
    end

    local sky_body = find_item_body_by_class(lighting_body, "Sky")
    local sky_settings = nil
    if sky_body then
        sky_settings = read_sky_settings_from_properties(sky_body:match("<Properties>(.-)</Properties>"), "rbxlx_sky")
    end

    local atmosphere_body = find_item_body_by_class(lighting_body, "Atmosphere")
    local atmosphere_settings = nil
    if atmosphere_body then
        local atmosphere_properties = atmosphere_body:match("<Properties>(.-)</Properties>")
        if atmosphere_properties then
            atmosphere_settings = {
                Density = read_named_number(atmosphere_properties, "Density", 0),
                Offset = read_named_number(atmosphere_properties, "Offset", 0),
                Color = read_named_color3(atmosphere_properties, "Color"),
                Decay = read_named_color3(atmosphere_properties, "Decay"),
                Haze = read_named_number(atmosphere_properties, "Haze", 0),
                Glare = read_named_number(atmosphere_properties, "Glare", 0),
            }
        else
            atmosphere_settings = {}
        end
    end

    return RBX._build_lighting_state({
        source = "rbxlx_lighting",
        ambient = read_named_color3(properties_block, "Ambient"),
        outdoor_ambient = read_named_color3(properties_block, "OutdoorAmbient"),
        color_shift_top = read_named_color3(properties_block, "ColorShift_Top"),
        color_shift_bottom = read_named_color3(properties_block, "ColorShift_Bottom"),
        fog_color = read_named_color3(properties_block, "FogColor"),
        fog_start = read_named_number(properties_block, "FogStart", 0),
        fog_end = read_named_number(properties_block, "FogEnd", 100000),
        brightness = read_named_number(properties_block, "Brightness", 1.0),
        exposure_compensation = read_named_number(properties_block, "ExposureCompensation", 0.0),
        environment_diffuse_scale = read_named_number(properties_block, "EnvironmentDiffuseScale", 0.0),
        environment_specular_scale = read_named_number(properties_block, "EnvironmentSpecularScale", 0.0),
        geographic_latitude = read_named_number(properties_block, "GeographicLatitude", 35.0),
        global_shadows = read_named_bool(properties_block, "GlobalShadows", true),
        clock_time = read_named_number(properties_block, "ClockTime", nil),
        time_of_day = find_named_value(properties_block, "string", "TimeOfDay"),
        shadow_softness = read_named_number(properties_block, "ShadowSoftness", 0.2),
        lighting_style = read_named_token_string(properties_block, "LightingStyle"),
        prioritize_lighting_quality = read_named_bool(properties_block, "PrioritizeLightingQuality", nil),
        technology = read_named_token_string(properties_block, "Technology"),
        outlines = read_named_bool(properties_block, "Outlines", nil),
        tint_color = tint_color,
        atmosphere_present = atmosphere_settings ~= nil,
        atmosphere = atmosphere_settings,
        sky = sky_settings,
        post_effects = {
            color_correction = color_correction_settings,
            bloom = bloom_settings,
            blur = blur_settings,
            sun_rays = sun_rays_settings,
            depth_of_field = depth_of_field_settings,
        },
    })
end

function parse_sky_settings_xml(xml)
    local lighting_body = find_item_body_by_class(xml, "Lighting")
    if not lighting_body then
        return nil
    end

    local sky_body = find_item_body_by_class(lighting_body, "Sky")
    if not sky_body then
        return nil
    end

    local properties_block = sky_body:match("<Properties>(.-)</Properties>")
    if not properties_block then
        return nil
    end

    return read_sky_settings_from_properties(properties_block, "rbxlx_sky")
end

function parse_workspace_settings(xml)
    local workspace_body = find_item_body_by_class(xml, "Workspace")
    if not workspace_body then
        return nil
    end

    local properties_block = workspace_body:match("<Properties>(.-)</Properties>")
    if not properties_block then
        return nil
    end

    local util = require("engine/graphics/rbx/util")
    local group_data
    local seen_group_data = false
    for attrs, text in properties_block:gmatch("<BinaryString([^>]*)>(.-)</BinaryString>") do
        if attrs:match('name%s*=%s*"CollisionGroupData"') then
            assert(not seen_group_data, "Duplicate present CollisionGroupData")
            seen_group_data = true
            local cdata = text:match("^%s*<!%[CDATA%[(.-)%]%]>%s*$")
            if cdata ~= nil then text = cdata
            else
                assert(not text:find("<", 1, true), "Invalid present CollisionGroupData XML")
                text = util.xml_unescape(text)
            end
            if attrs:match('encoding%s*=%s*"none"') then
                group_data = text
            else
                group_data = util.decode_base64(text)
                assert(type(group_data) == "string", "Invalid present CollisionGroupData base64")
            end
        end
    end
    if group_data == nil then
        local text = find_named_value(properties_block, "string", "CollisionGroupData")
        if text ~= nil then group_data = util.xml_unescape(text) end
        assert(group_data ~= nil or not properties_block:find("CollisionGroupData", 1, true),
            "Present CollisionGroupData could not be decoded")
    end
    return {
        Gravity = read_named_number(properties_block, "Gravity", 196.2),
        FallenPartsDestroyHeight = read_named_number(properties_block, "FallenPartsDestroyHeight", -500),
        CollisionGroupData = group_data,
        TouchesUseCollisionGroups = read_named_bool(properties_block, "TouchesUseCollisionGroups", false),
    }
end

-- memoized: pure function of value, and the trim/match/lower string path ran per face per part
-- during map-load classify (string.match is also an NYI that aborts any LuaJIT trace through it)
local enum_face_name_cache = {}

enum_face_name = function(value)
    local value_type = type(value)
    if value_type == "number" or value_type == "string" then
        local cached = enum_face_name_cache[value]
        if cached ~= nil then
            return cached
        end
    end
    local resolved
    if value_type == "number" then
        resolved = RBX.FACE_ENUM[math.floor(value + 0.5)] or "Front"
    elseif value_type == "string" and value ~= "" then
        local normalized = trim(value)
        local numeric = tonumber(normalized)
        if numeric ~= nil then
            resolved = RBX.FACE_ENUM[math.floor(numeric + 0.5)] or "Front"
        else
            local enum_name = normalized:match("Enum%.NormalId%.([A-Za-z_]+)$")
                or normalized:match("NormalId%.([A-Za-z_]+)$")
                or normalized
            resolved = RBX.FACE_ENUM.aliases[safe_lower(enum_name)] or "Front"
        end
    else
        return "Front"
    end
    if value == value then -- NaN would error as a table key
        enum_face_name_cache[value] = resolved
    end
    return resolved
end

RBX._enum_face_name = enum_face_name

local normalize_referent_value

LOCAL_LIGHT_CLASSES = {
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
}

local function local_light_default_range(class_name)
    return class_name == "PointLight" and 8 or 16
end

local function local_light_default_angle(class_name)
    return class_name == "PointLight" and 0 or 90
end

local function normalize_local_light_bool(value, default_value)
    if value == nil then
        return default_value == true
    end
    return value == true
end

local function normalize_local_light_color(value)
    local color = normalize_color3(value, 1, 1, 1)
    return {
        clamp(color[1] or 1, 0, 1),
        clamp(color[2] or 1, 0, 1),
        clamp(color[3] or 1, 0, 1),
    }
end

local function first_non_nil(a, b, c)
    if a ~= nil then
        return a
    end
    if b ~= nil then
        return b
    end
    return c
end

function RBX._make_local_light_entry(class_name, raw)
    if not LOCAL_LIGHT_CLASSES[class_name] then
        return nil
    end
    raw = raw or {}
    local raw_brightness = first_non_nil(raw.Brightness, raw.brightness, 1)
    local raw_range = first_non_nil(raw.Range, raw.range, local_light_default_range(class_name))
    local raw_angle = first_non_nil(raw.Angle, raw.angle, local_light_default_angle(class_name))
    local raw_color = first_non_nil(raw.Color, raw.Color3, first_non_nil(raw.color, raw.color3, nil))
    -- studio slider ranges: Brightness 0..40, Range 0..60. unclamped blows out exposure
    local brightness = clamp(to_number(raw_brightness, 1), 0, 40)
    local range = clamp(to_number(raw_range, local_light_default_range(class_name)), 0, 60)
    local angle = clamp(to_number(raw_angle, local_light_default_angle(class_name)), 0, 180)
    local color = normalize_local_light_color(raw_color)
    return {
        class_name = class_name,
        name = raw.Name or raw.name or class_name,
        referent = normalize_referent_value(raw.Referent or raw.referent),
        enabled = normalize_local_light_bool(first_non_nil(raw.Enabled, raw.enabled, nil), true),
        brightness = brightness,
        color = color,
        color_r = color[1],
        color_g = color[2],
        color_b = color[3],
        shadows = normalize_local_light_bool(first_non_nil(raw.Shadows, raw.shadows, nil), false),
        range = range,
        raw_range = to_number(raw_range, local_light_default_range(class_name)),
        angle = angle,
        face = enum_face_name(first_non_nil(raw.Face, raw.face, "Front")),
    }
end

function RBX._parse_local_light_xml(class_name, properties_block, referent)
    if not LOCAL_LIGHT_CLASSES[class_name] or type(properties_block) ~= "string" then
        return nil
    end
    local raw = {
        Name = find_named_value(properties_block, "string", "Name") or class_name,
        Referent = referent,
        Enabled = read_named_bool(properties_block, "Enabled", true),
        Brightness = read_named_number(properties_block, "Brightness", 1),
        Color = read_named_color3(properties_block, "Color")
            or read_named_color3(properties_block, "Color3")
            or { 1, 1, 1 },
        Shadows = read_named_bool(properties_block, "Shadows", false),
        Range = read_named_number(properties_block, "Range", local_light_default_range(class_name)),
        Angle = read_named_number(properties_block, "Angle", local_light_default_angle(class_name)),
        Face = find_named_value(properties_block, "token", "Face")
            or find_named_value(properties_block, "string", "Face")
            or "Front",
    }
    return RBX._make_local_light_entry(class_name, raw)
end

local function copy_attachment_transform_fields(out, cframe)
    cframe = type(cframe) == "table" and cframe or nil
    out.r00 = to_number(cframe and (cframe.R00 or cframe.r00), 1)
    out.r01 = to_number(cframe and (cframe.R01 or cframe.r01), 0)
    out.r02 = to_number(cframe and (cframe.R02 or cframe.r02), 0)
    out.r10 = to_number(cframe and (cframe.R10 or cframe.r10), 0)
    out.r11 = to_number(cframe and (cframe.R11 or cframe.r11), 1)
    out.r12 = to_number(cframe and (cframe.R12 or cframe.r12), 0)
    out.r20 = to_number(cframe and (cframe.R20 or cframe.r20), 0)
    out.r21 = to_number(cframe and (cframe.R21 or cframe.r21), 0)
    out.r22 = to_number(cframe and (cframe.R22 or cframe.r22), 1)
end

function normalize_surface_type(surface_value)
    if type(surface_value) == "table" then
        surface_value = surface_value.Value
            or surface_value.value
            or surface_value.Name
            or surface_value.name
            or surface_value.EnumItem
            or surface_value.enumItem
            or surface_value.Id
            or surface_value.id
    end

    local numeric = tonumber(surface_value)
    if numeric ~= nil then
        return RBX.SURFACE_TYPE_ENUM[math.floor(numeric + 0.5)]
    end

    if type(surface_value) == "string" then
        local normalized = trim(surface_value)
        normalized = normalized:gsub("^Enum%.SurfaceType%.", "")
        normalized = normalized:gsub("[%s_]+", ""):lower()
        return RBX.SURFACE_TYPE_ENUM.aliases[normalized]
    end

    return nil
end

RBX._normalize_surface_type = normalize_surface_type

-- render/physics consumers repeatedly read already normalized type tokens
-- preserve the serialized/alias path below for every other input
local canonical_part_shapes,canonical_mesh_types={},{}
for _,name in pairs(RBX.PART_SHAPE_ENUM.aliases)do canonical_part_shapes[name]=name end
for _,name in pairs(RBX.SPECIAL_MESH_TYPE_ENUM.aliases)do canonical_mesh_types[name]=name end

function normalize_part_shape(shape_value, class_name)
    if class_name == "WedgePart" then
        return "Wedge"
    end
    if class_name == "CornerWedgePart" then
        return "CornerWedge"
    end
    if class_name == "TrussPart" then
        return "Truss"
    end
    if type(shape_value)=='string'and canonical_part_shapes[shape_value]then return shape_value end

    -- EnumItem TABLES (rbx.Enum.PartType.Ball) must unwrap like
    -- normalize_special_mesh_type does, or they fall through every branch to
    -- "Block" -- the gamejam's "Ball" char was silently a tumbling CUBE (edge
    -- pivots lost ground contact, corners caught walls = "collision feels wrong")
    if type(shape_value) == "table" then
        shape_value = shape_value.Value
            or shape_value.value
            or shape_value.Name
            or shape_value.name
            or shape_value.EnumItem
            or shape_value.enumItem
            or shape_value.Id
            or shape_value.id
    end

    local numeric = tonumber(shape_value)
    if numeric ~= nil then
        return RBX.PART_SHAPE_ENUM[math.floor(numeric + 0.5)] or "Block"
    end

    if type(shape_value) == "string" then
        local lowered = safe_lower(trim(shape_value))
        local mapped = RBX.PART_SHAPE_ENUM.aliases[lowered]
        if mapped then
            return mapped
        end
    end

    return "Block"
end

function normalize_special_mesh_type(mesh_type_value, mesh_id)
    if type(mesh_type_value)=='string'and canonical_mesh_types[mesh_type_value]then return mesh_type_value end
    mesh_id = normalize_asset_reference(mesh_id)

    if type(mesh_type_value) == "table" then
        mesh_type_value = mesh_type_value.Value
            or mesh_type_value.value
            or mesh_type_value.Name
            or mesh_type_value.name
            or mesh_type_value.EnumItem
            or mesh_type_value.enumItem
            or mesh_type_value.Id
            or mesh_type_value.id
    end

    local numeric = tonumber(mesh_type_value)
    if numeric ~= nil then
        -- Enum tokens are integral. Rounding a malformed serialized value such
        -- as 3.6 silently changed it into Cylinder (4) and made parser output
        -- disagree with strict DataModel promotion. let the serialized caller
        -- apply SpecialMesh's native Head default instead
        if numeric ~= math.floor(numeric) then
            return nil
        end
        return RBX.SPECIAL_MESH_TYPE_ENUM[numeric]
            or (mesh_id and "FileMesh" or nil)
    end

    if type(mesh_type_value) == "string" then
        local lowered = safe_lower(trim(mesh_type_value))
        local mapped = RBX.SPECIAL_MESH_TYPE_ENUM.aliases[lowered]
        if mapped then
            return mapped
        end
    end

    if mesh_id then
        return "FileMesh"
    end

    return nil
end

function normalize_vector3_value(value, default_x, default_y, default_z)
    default_x = default_x or 0
    default_y = default_y or 0
    default_z = default_z or 0

    if type(value) ~= "table" then
        return {
            x = default_x,
            y = default_y,
            z = default_z,
        }
    end

    return {
        x = tonumber(value.X or value.x or value[1] or default_x) or default_x,
        y = tonumber(value.Y or value.y or value[2] or default_y) or default_y,
        z = tonumber(value.Z or value.z or value[3] or default_z) or default_z,
    }
end

function normalize_optional_vector2_components(value, default_x, default_y)
    if type(value) ~= "table" then
        return nil, nil
    end

    local raw_x = value.X
    if raw_x == nil then raw_x = value.x end
    if raw_x == nil then raw_x = value[1] end
    local raw_y = value.Y
    if raw_y == nil then raw_y = value.y end
    if raw_y == nil then raw_y = value[2] end
    if raw_x == nil and raw_y == nil then
        return nil, nil
    end

    return to_number(raw_x, default_x or 0),
        to_number(raw_y, default_y or 0)
end

---returns the first usable Decal/Texture color reference in caller-supplied
---property precedence. empty Content values do not mask a populated legacy alias
function normalize_face_texture_asset_reference(...)
    for index = 1, select("#", ...) do
        local normalized = normalize_asset_reference(select(index, ...))
        if type(normalized) == "string"
            and normalized ~= ""
            and not RBX._is_empty_asset_reference(normalized) then
            return normalized
        end
    end
    return nil
end

local function surface_appearance_property_value(source, property_name)
    if type(source) ~= "table" then
        return nil
    end
    local value = source[property_name]
    if value == nil then
        value = source[property_name:lower()]
    end
    return value
end

local function normalize_surface_appearance_enum_scalar(value)
    local seen = nil
    if type(value) == "table" then
        seen = {}
        while type(value) == "table" do
            if seen[value] then
                return nil
            end
            seen[value] = true
            value = value.Value
                or value.value
                or value.Name
                or value.name
                or value.EnumItem
                or value.enum_item
        end
    end
    if type(value) == "string" then
        value = trim(value)
        if value == "" then
            return nil
        end
        return tonumber(value) or value
    end
    return tonumber(value)
end

local function surface_appearance_map_fields(source, legacy_name, content_name)
    local legacy = normalize_asset_reference(
        surface_appearance_property_value(source, legacy_name))
    local content = normalize_asset_reference(
        surface_appearance_property_value(source, content_name))
    return normalize_face_texture_asset_reference(content, legacy), content, legacy
end

---builds the parser/runtime transport descriptor for one direct
---SurfaceAppearance child. Resolved map fields prefer modern Content values,
---but the `properties` table retains both modern and legacy source values for
---future asset/shader stages. this function deliberately assigns no PBR or
---alpha semantics
function RBX._build_surface_appearance_descriptor(source, source_index)
    if type(source) ~= "table" then
        return nil
    end

    local color_map, color_map_content, legacy_color_map =
        surface_appearance_map_fields(source, "ColorMap", "ColorMapContent")
    local normal_map, normal_map_content, legacy_normal_map =
        surface_appearance_map_fields(source, "NormalMap", "NormalMapContent")
    local roughness_map, roughness_map_content, legacy_roughness_map =
        surface_appearance_map_fields(source, "RoughnessMap", "RoughnessMapContent")
    local metalness_map, metalness_map_content, legacy_metalness_map =
        surface_appearance_map_fields(source, "MetalnessMap", "MetalnessMapContent")
    local authored_alpha_mode = normalize_surface_appearance_enum_scalar(
        surface_appearance_property_value(source, "AlphaMode"))
    local alpha_mode = RBX._normalize_surface_appearance_alpha_mode(
        authored_alpha_mode)
    local source_color = surface_appearance_property_value(source, "Color")
        or surface_appearance_property_value(source, "Color3")
    local color = source_color ~= nil and normalize_color3(source_color, 1, 1, 1) or nil
    local emissive_mask_content = normalize_asset_reference(
        surface_appearance_property_value(source, "EmissiveMaskContent"))
    local emissive_mask = normalize_face_texture_asset_reference(
        emissive_mask_content)
    local emissive_strength = tonumber(
        surface_appearance_property_value(source, "EmissiveStrength"))
    local source_emissive_tint =
        surface_appearance_property_value(source, "EmissiveTint")
    local emissive_tint = source_emissive_tint ~= nil
        and normalize_color3(source_emissive_tint, 1, 1, 1) or nil
    local resample_mode = normalize_surface_appearance_enum_scalar(
        surface_appearance_property_value(source, "ResampleMode"))
    local texture_pack, texture_pack_content, legacy_texture_pack =
        surface_appearance_map_fields(source, "TexturePack", "TexturePackContent")
    local texture_pack_metadata =
        surface_appearance_property_value(source, "TexturePackMetadata")
    if texture_pack_metadata ~= nil then
        texture_pack_metadata = tostring(texture_pack_metadata)
    end

    local properties = {
        ColorMapContent = color_map_content,
        ColorMap = legacy_color_map,
        NormalMapContent = normal_map_content,
        NormalMap = legacy_normal_map,
        RoughnessMapContent = roughness_map_content,
        RoughnessMap = legacy_roughness_map,
        MetalnessMapContent = metalness_map_content,
        MetalnessMap = legacy_metalness_map,
        AlphaMode = authored_alpha_mode,
        Color = color and { color[1], color[2], color[3] } or nil,
        EmissiveMaskContent = emissive_mask_content,
        EmissiveStrength = emissive_strength,
        EmissiveTint = emissive_tint
            and { emissive_tint[1], emissive_tint[2], emissive_tint[3] }
            or nil,
        ResampleMode = resample_mode,
        TexturePackContent = texture_pack_content,
        TexturePack = legacy_texture_pack,
        TexturePackMetadata = texture_pack_metadata,
    }

    return {
        class_name = "SurfaceAppearance",
        name = tostring(surface_appearance_property_value(source, "Name")
            or "SurfaceAppearance"),
        referent = normalize_referent_value(
            surface_appearance_property_value(source, "Referent")),
        source_index = math.max(1, math.floor(tonumber(source_index) or 1)),
        color_map = color_map,
        color_map_content = color_map_content,
        legacy_color_map = legacy_color_map,
        normal_map = normal_map,
        normal_map_content = normal_map_content,
        legacy_normal_map = legacy_normal_map,
        roughness_map = roughness_map,
        roughness_map_content = roughness_map_content,
        legacy_roughness_map = legacy_roughness_map,
        metalness_map = metalness_map,
        metalness_map_content = metalness_map_content,
        legacy_metalness_map = legacy_metalness_map,
        alpha_mode = alpha_mode,
        raw_alpha_mode = authored_alpha_mode,
        color = color,
        emissive_mask = emissive_mask,
        emissive_mask_content = emissive_mask_content,
        emissive_strength = emissive_strength,
        emissive_tint = emissive_tint,
        resample_mode = resample_mode,
        texture_pack = texture_pack,
        texture_pack_content = texture_pack_content,
        legacy_texture_pack = legacy_texture_pack,
        texture_pack_metadata = texture_pack_metadata,
        properties = properties,
    }
end

function normalize_special_mesh_vertex_color(value)
    local color = normalize_vector3_value(value, 1, 1, 1)
    -- DataModelMesh.VertexColor is a Vector3 multiplier expressed in the same
    -- component space as Color3.R/G/B, not a byte RGB triplet. Legacy places
    -- legitimately carry overbright values (5,5,5 occurs in real places)
    -- the fixed-function result saturates for this renderer, dividing by 255
    -- instead turns the authored texture almost black
    local x = color.x
    local y = color.y
    local z = color.z
    return {
        r = clamp(x, 0, 1),
        g = clamp(y, 0, 1),
        b = clamp(z, 0, 1),
    }
end

function normalize_mesh_size_value(value)
    local size = normalize_vector3_value(value, 0, 0, 0)
    local x = math.abs(size.x or 0)
    local y = math.abs(size.y or 0)
    local z = math.abs(size.z or 0)
    if x <= 1e-6 or y <= 1e-6 or z <= 1e-6 then
        return nil
    end
    return {
        x = x,
        y = y,
        z = z,
    }
end

function normalize_color3(value, default_r, default_g, default_b)
    default_r = default_r or 1
    default_g = default_g or 1
    default_b = default_b or 1

    if type(value) ~= "table" then
        return { default_r, default_g, default_b }
    end

    local r = tonumber(value.R or value.r or value[1] or default_r) or default_r
    local g = tonumber(value.G or value.g or value[2] or default_g) or default_g
    local b = tonumber(value.B or value.b or value[3] or default_b) or default_b
    if r > 1 or g > 1 or b > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end
    return { clamp(r, 0, 1), clamp(g, 0, 1), clamp(b, 0, 1) }
end

function color3_to_rgb255(value, default_r, default_g, default_b)
    local c = normalize_color3(value, default_r or 1, default_g or 1, default_b or 1)
    return clamp(math.floor(c[1] * 255 + 0.5), 0, 255),
        clamp(math.floor(c[2] * 255 + 0.5), 0, 255),
        clamp(math.floor(c[3] * 255 + 0.5), 0, 255)
end

function to_number(value, default_value)
    local n = read_numeric_token(value, nil)
    if n == nil then
        return default_value
    end
    return n
end

function find_first_child_by_class(children, class_name)
    if type(children) ~= "table" then
        return nil
    end
    for i = 1, #children do
        local child = children[i]
        if type(child) == "table" and child.ClassName == class_name then
            return child
        end
    end
    return nil
end

function find_first_descendant_by_class(instance, class_name)
    if type(instance) ~= "table" then
        return nil
    end
    if instance.ClassName == class_name then
        return instance
    end
    local children = instance.Children
    if type(children) ~= "table" then
        return nil
    end
    for i = 1, #children do
        local child = children[i]
        local found = find_first_descendant_by_class(child, class_name)
        if found then
            return found
        end
    end
    return nil
end

function find_first_in_roots(roots, class_name)
    if type(roots) ~= "table" then
        return nil
    end
    for i = 1, #roots do
        local found = find_first_descendant_by_class(roots[i], class_name)
        if found then
            return found
        end
    end
    return nil
end


function RBX._collect_descendants_by_class(instance, class_name, out)
    if type(instance) ~= "table" then
        return
    end
    if instance.ClassName == class_name then
        out[#out + 1] = instance
    end
    local children = instance.Children
    if type(children) ~= "table" then
        return
    end
    for i = 1, #children do
        RBX._collect_descendants_by_class(children[i], class_name, out)
    end
end

function RBX._workspace_subtree_skip_policy_matches(name, class_name, policy)
    if policy == nil or policy == false then
        return false
    end
    if class_name ~= nil and class_name ~= "Folder" then
        return false
    end
    local normalized_name = safe_lower(trim(tostring(name or "")))
    if policy == true or policy == "legacy_names" then
        return RBX.SKIPPED_WORKSPACE_SUBTREE_NAMES[normalized_name] == true
    end
    if type(policy) == "table" then
        local names = policy.names or policy
        return names[normalized_name] == true
            or names[tostring(name or "")] == true
    end
    return false
end

-- Roblox resolves malformed Parts containing multiple legacy DataModelMesh
-- children by authored order: the last SpecialMesh, CylinderMesh, or BlockMesh
-- is the visual owner, regardless of concrete class. Studio 0.735 native captures
-- pin this with all alternating class pairs and two SpecialMeshes. keep the
-- selection in one helper so DOM and runtime paths cannot reintroduce a
-- SpecialMesh>CylinderMesh>BlockMesh priority rule
function find_last_legacy_mesh_child(children)
    if type(children) ~= "table" then return nil end
    local selected = nil
    for index = 1, #children do
        local child = children[index]
        local class_name = type(child) == "table" and child.ClassName or nil
        if class_name == "SpecialMesh" or class_name == "CylinderMesh"
            or class_name == "BlockMesh" then
            selected = child
        end
    end
    return selected
end

function RBX._should_skip_workspace_subtree_name(
    name, class_name, supported_part_count, policy)
    -- Rendering every Workspace descendant is the default. Name-based omission
    -- is a loader policy, never an implicit heuristic: a legitimate Folder named
    -- Temp/TestMap must not disappear when it happens to contain <=128 parts
    if not RBX._workspace_subtree_skip_policy_matches(
        name, class_name, policy) then
        return false
    end
    local max_supported_parts = nil
    if policy == true or policy == "legacy_names" then
        max_supported_parts = 128
    elseif type(policy) == "table" then
        max_supported_parts = tonumber(policy.max_supported_parts)
    end
    if max_supported_parts ~= nil and supported_part_count ~= nil
        and supported_part_count > max_supported_parts then
        return false
    end
    return true
end

function RBX._collect_render_roots(roots)
    if type(roots) ~= "table" then
        return roots
    end

    local workspace_roots = {}
    for i = 1, #roots do
        RBX._collect_descendants_by_class(roots[i], "Workspace", workspace_roots)
    end
    if #workspace_roots > 0 then
        return workspace_roots
    end

    local world_model_roots = {}
    for i = 1, #roots do
        RBX._collect_descendants_by_class(roots[i], "WorldModel", world_model_roots)
    end
    if #world_model_roots > 0 then
        return world_model_roots
    end

    return roots
end

function parse_lighting_settings_tree(roots)
    local lighting = find_first_in_roots(roots, "Lighting")
    if not lighting then
        return nil
    end

    local tint_color = nil
    local color_correction_settings = nil
    local color_correction = find_first_child_by_class(lighting.Children or {}, "ColorCorrectionEffect")
    if color_correction then
        local enabled = color_correction.Enabled ~= false
        color_correction_settings = {
            Enabled = enabled,
            Brightness = color_correction.Brightness,
            Contrast = color_correction.Contrast,
            Saturation = color_correction.Saturation,
            TintColor = color_correction.TintColor,
        }
        if enabled then
            tint_color = normalize_color3(color_correction.TintColor, 1, 1, 1)
        end
    end

    local bloom = find_first_child_by_class(lighting.Children or {}, "BloomEffect")
    local bloom_settings = bloom and {
        Enabled = bloom.Enabled ~= false,
        Intensity = bloom.Intensity,
        Size = bloom.Size,
        Threshold = bloom.Threshold,
    } or nil
    local blur = find_first_child_by_class(lighting.Children or {}, "BlurEffect")
    local blur_settings = blur and {
        Enabled = blur.Enabled ~= false,
        Size = blur.Size,
    } or nil
    local sun_rays = find_first_child_by_class(lighting.Children or {}, "SunRaysEffect")
    local sun_rays_settings = sun_rays and {
        Enabled = sun_rays.Enabled ~= false,
        Intensity = sun_rays.Intensity,
        Spread = sun_rays.Spread,
    } or nil
    local depth_of_field = find_first_child_by_class(lighting.Children or {}, "DepthOfFieldEffect")
    local depth_of_field_settings = depth_of_field and {
        Enabled = depth_of_field.Enabled ~= false,
        FarIntensity = depth_of_field.FarIntensity,
        FocusDistance = depth_of_field.FocusDistance,
        InFocusRadius = depth_of_field.InFocusRadius,
        NearIntensity = depth_of_field.NearIntensity,
    } or nil

    local sky = find_first_child_by_class(lighting.Children or {}, "Sky")
    local atmosphere = find_first_child_by_class(lighting.Children or {}, "Atmosphere")
    local sky_settings = nil
    if sky then
        sky_settings = {
            SkyboxBk = sky.SkyboxBk,
            SkyboxDn = sky.SkyboxDn,
            SkyboxFt = sky.SkyboxFt,
            SkyboxLf = sky.SkyboxLf,
            SkyboxRt = sky.SkyboxRt,
            SkyboxUp = sky.SkyboxUp,
            SunTextureId = sky.SunTextureId,
            MoonTextureId = sky.MoonTextureId,
            SunAngularSize = sky.SunAngularSize,
            MoonAngularSize = sky.MoonAngularSize,
            StarCount = sky.StarCount,
            CelestialBodiesShown = sky.CelestialBodiesShown,
            SkyboxOrientation = sky.SkyboxOrientation,
            source = "rbxl_sky",
        }
    end
    local atmosphere_settings = nil
    if atmosphere then
        atmosphere_settings = {
            Density = atmosphere.Density,
            Offset = atmosphere.Offset,
            Color = atmosphere.Color,
            Decay = atmosphere.Decay,
            Haze = atmosphere.Haze,
            Glare = atmosphere.Glare,
        }
    end

    return RBX._build_lighting_state({
        source = "rbxl_lighting",
        ambient = lighting.Ambient,
        outdoor_ambient = lighting.OutdoorAmbient,
        color_shift_top = lighting.ColorShift_Top,
        color_shift_bottom = lighting.ColorShift_Bottom,
        fog_color = lighting.FogColor,
        fog_start = lighting.FogStart,
        fog_end = lighting.FogEnd,
        brightness = lighting.Brightness,
        exposure_compensation = lighting.ExposureCompensation,
        environment_diffuse_scale = lighting.EnvironmentDiffuseScale,
        environment_specular_scale = lighting.EnvironmentSpecularScale,
        geographic_latitude = lighting.GeographicLatitude,
        global_shadows = lighting.GlobalShadows,
        clock_time = lighting.ClockTime,
        time_of_day = lighting.TimeOfDay,
        shadow_softness = lighting.ShadowSoftness,
        lighting_style = lighting.LightingStyle,
        prioritize_lighting_quality = lighting.PrioritizeLightingQuality,
        technology = lighting.Technology,
        outlines = lighting.Outlines,
        tint_color = tint_color,
        atmosphere_present = atmosphere ~= nil,
        atmosphere = atmosphere_settings,
        sky = sky_settings,
        post_effects = {
            color_correction = color_correction_settings,
            bloom = bloom_settings,
            blur = blur_settings,
            sun_rays = sun_rays_settings,
            depth_of_field = depth_of_field_settings,
        },
    })
end

function parse_sky_settings_tree(roots)
    local lighting = find_first_in_roots(roots, "Lighting")
    if not lighting then
        return nil
    end
    local sky = find_first_child_by_class(lighting.Children or {}, "Sky")
    if not sky then
        return nil
    end

    -- keep blank faces blank/nil so the renderer doesnt backfill the default skybox
    local out = {
        SkyboxBk = sky.SkyboxBk,
        SkyboxDn = sky.SkyboxDn,
        SkyboxFt = sky.SkyboxFt,
        SkyboxLf = sky.SkyboxLf,
        SkyboxRt = sky.SkyboxRt,
        SkyboxUp = sky.SkyboxUp,
        SunTextureId = sky.SunTextureId,
        MoonTextureId = sky.MoonTextureId,
        SunAngularSize = sky.SunAngularSize,
        MoonAngularSize = sky.MoonAngularSize,
        StarCount = sky.StarCount,
        CelestialBodiesShown = sky.CelestialBodiesShown,
        SkyboxOrientation = sky.SkyboxOrientation,
        source = "rbxl_sky",
    }
    return out
end

function parse_workspace_settings_tree(roots)
    local workspace = find_first_in_roots(roots, "Workspace")
    if not workspace then
        return nil
    end

    return {
        Gravity = to_number(workspace.Gravity, 196.2),
        FallenPartsDestroyHeight = to_number(workspace.FallenPartsDestroyHeight, -500),
        CollisionGroupData = workspace.CollisionGroupData,
        TouchesUseCollisionGroups = workspace.TouchesUseCollisionGroups == true,
    }
end

function parse_binary_property_values(payload, value_type, count, class_name, property_name, shared_strings)
    local values = {}
    local function decode_binary_referent_array(reader, total)
        local deltas = interleaved_int32(reader, total)
        local out = {}
        local running = 0
        for i = 1, total do
            running = running + (deltas[i] or 0)
            out[i] = running
        end
        return out
    end

    if value_type == 1 then
        for i = 1, count do
            values[i] = read_binary_string(payload)
        end
        return values
    end

    if value_type == 2 then
        local bools = interleaved_uint8(payload, count)
        for i = 1, count do
            values[i] = bools[i] == 1
        end
        return values
    end

    if value_type == 3 then
        return interleaved_int32(payload, count)
    end

    if value_type == 4 then
        return interleaved_float(payload, count)
    end

    if value_type == 5 then
        for i = 1, count do
            values[i] = payload:float64_le()
        end
        return values
    end

    if value_type == 11 then
        local colors = interleaved_uint32(payload, count)
        for i = 1, count do
            local number = colors[i]
            local color = BRICK_COLORS[number]
            values[i] = {
                Number = number,
                Color = {
                    R = (color and color[1]) or 0,
                    G = (color and color[2]) or 0,
                    B = (color and color[3]) or 0,
                }
            }
        end
        return values
    end

    if value_type == 12 then
        local r = interleaved_float(payload, count)
        local g = interleaved_float(payload, count)
        local b = interleaved_float(payload, count)
        for i = 1, count do
            values[i] = { R = r[i], G = g[i], B = b[i] }
        end
        return values
    end

    if value_type == 14 then
        local x = interleaved_float(payload, count)
        local y = interleaved_float(payload, count)
        local z = interleaved_float(payload, count)
        for i = 1, count do
            values[i] = { X = x[i], Y = y[i], Z = z[i] }
        end
        return values
    end

    if value_type == 16 then
        local components = {}
        for i = 1, count do
            local id = payload:uint8()
            local matrix = RBX.CFRAME_SPECIAL_ORIENTATIONS[id]
            if matrix then
                components[i] = { matrix[1], matrix[2], matrix[3], matrix[4], matrix[5], matrix[6], matrix[7], matrix[8],
                    matrix[9] }
            else
                components[i] = {
                    payload:float32_le(),
                    payload:float32_le(),
                    payload:float32_le(),
                    payload:float32_le(),
                    payload:float32_le(),
                    payload:float32_le(),
                    payload:float32_le(),
                    payload:float32_le(),
                    payload:float32_le(),
                }
            end
        end

        local x = interleaved_float(payload, count)
        local y = interleaved_float(payload, count)
        local z = interleaved_float(payload, count)
        for i = 1, count do
            local m = components[i]
            values[i] = {
                Position = { X = x[i], Y = y[i], Z = z[i] },
                X = x[i],
                Y = y[i],
                Z = z[i],
                R00 = m[1],
                R01 = m[2],
                R02 = m[3],
                R10 = m[4],
                R11 = m[5],
                R12 = m[6],
                R20 = m[7],
                R21 = m[8],
                R22 = m[9],
                Components = {
                    x[i], y[i], z[i],
                    m[1], m[2], m[3],
                    m[4], m[5], m[6],
                    m[7], m[8], m[9],
                }
            }
        end
        return values
    end

    if value_type == 18 then
        local tokens = interleaved_uint32(payload, count)
        for i = 1, count do
            local token = tokens[i]
            if property_name == "Face" then
                values[i] = enum_face_name(token)
            else
                values[i] = token
            end
        end
        return values
    end

    if value_type == 19 then
        return decode_binary_referent_array(payload, count)
    end

    -- PhysicalProperties (0x19): NOT interleaved. the flag is a TWO-BIT field --
    -- bit0 = has custom properties, bit1 = EXTENDED record with a SIXTH f32
    -- (AcousticAbsorption) -- so the payload is 24 bytes when bit1 is set, else 20
    --
    -- this decoder is the independent fallback that choose_best_binary_parse is
    -- supposed to be able to cross-check binary.lua against. it previously carried a
    -- verbatim copy of binary.lua's wrong 5-float assumption, so both candidates
    -- agreed and neither could rescue the other. keep the two in step: see
    -- binary.lua's PhysicalProperties branch
    if value_type == 25 then
        local data_end = payload.len or 0
        for i = 1, count do
            if payload.pos > data_end then break end
            local flag = payload:uint8()
            if (flag % 2) == 1 then
                local wide = (math.floor(flag / 2) % 2) == 1
                local needed = wide and 24 or 20
                if (data_end - payload.pos + 1) >= needed then
                    local entry = {
                        density = payload:float32_le(),
                        friction = payload:float32_le(),
                        elasticity = payload:float32_le(),
                        friction_weight = payload:float32_le(),
                        elasticity_weight = payload:float32_le(),
                    }
                    if wide then
                        entry.acoustic_absorption = payload:float32_le()
                    end
                    values[i] = entry
                else
                    -- Truncated record: stop rather than decode from short data
                    break
                end
            end
        end
        if payload.pos <= data_end then
            payload.pos = data_end + 1
        end
        return values
    end

    if value_type == 26 then
        local r = interleaved_uint8(payload, count)
        local g = interleaved_uint8(payload, count)
        local b = interleaved_uint8(payload, count)
        for i = 1, count do
            values[i] = { R = r[i] / 255, G = g[i] / 255, B = b[i] / 255 }
        end
        return values
    end

    if value_type == 27 then
        for i = 1, count do
            local lo = payload:uint32_le()
            local hi = payload:uint32_le()
            values[i] = hi * 4294967296 + lo
        end
        return values
    end

    if value_type == 28 then
        local ids = interleaved_uint32(payload, count)
        for i = 1, count do
            local shared_id = ids[i]
            if shared_strings and shared_id ~= nil then
                values[i] = shared_strings[(shared_id or 0) + 1]
            else
                values[i] = nil
            end
        end
        return values
    end

    if value_type == 29 then
        for i = 1, count do
            local raw_bytes = read_binary_string(payload)
            values[i] = {
                value = raw_bytes,
                raw_bytes = raw_bytes,
                compressed_bytes = raw_bytes,
                byte_length = #raw_bytes,
                compression = "preserved",
            }
        end
        return values
    end

    if value_type == 34 then
        local source_types = interleaved_int32(payload, count)
        local uri_count = payload:uint32_le()
        local uris = {}
        for i = 1, uri_count do
            uris[i] = read_binary_string(payload)
        end

        local object_count = payload:int32_le()
        local object_refs = decode_binary_referent_array(payload, object_count)
        local external_count = payload:int32_le()
        local external_refs = decode_binary_referent_array(payload, external_count)

        local uri_index = 1
        local object_index = 1
        local external_index = 1
        for i = 1, count do
            local source_type = source_types[i] or 0
            if source_type == 1 then
                values[i] = normalize_asset_reference(uris[uri_index] or "")
                uri_index = uri_index + 1
            elseif source_type == 2 then
                values[i] = object_refs[object_index]
                object_index = object_index + 1
            elseif source_type == 3 then
                values[i] = external_refs[external_index]
                external_index = external_index + 1
            else
                values[i] = nil
            end
        end
        return values
    end

    return nil
end

RBX._parse_binary_property_values = parse_binary_property_values
RBX.BinaryReader = BinaryReader

-- derived key strings precomputed once: the old per-part gsub/lower/concat chain
-- built ~55 temp strings per part (and gsub is NYI, killing the trace)
local SURFACE_FIELD_KEYS = {}
for index = 1, #SURFACE_PROPERTY_FIELDS do
    local field = SURFACE_PROPERTY_FIELDS[index]
    local prefix = field.property:gsub("Surface$", "")
    local lower = prefix:lower()
    SURFACE_FIELD_KEYS[index] = {
        property = field.property,
        property_lower = field.property:lower(),
        parsed_key = field.parsed_key,
        input_name = prefix .. "SurfaceInput",
        input_name_lower = (prefix .. "SurfaceInput"):lower(),
        param_a_name = prefix .. "ParamA",
        param_a_name_lower = (prefix .. "ParamA"):lower(),
        param_b_name = prefix .. "ParamB",
        param_b_name_lower = (prefix .. "ParamB"):lower(),
        out_input = lower .. "_surface_input",
        out_param_a = lower .. "_param_a",
        out_param_b = lower .. "_param_b",
    }
end

local function read_instance_surface_properties(instance)
    local out = {}
    for index = 1, #SURFACE_FIELD_KEYS do
        local k = SURFACE_FIELD_KEYS[index]
        out[k.parsed_key] = normalize_surface_type(
            instance[k.property]
            or instance[k.property_lower]
        )
        out[k.out_input] = to_number(
            instance[k.input_name]
            or instance[k.input_name_lower],
            0
        )
        out[k.out_param_a] = to_number(
            instance[k.param_a_name]
            or instance[k.param_a_name_lower],
            nil
        )
        out[k.out_param_b] = to_number(
            instance[k.param_b_name]
            or instance[k.param_b_name_lower],
            nil
        )
    end
    return out
end

local function read_xml_surface_type(properties_block, property_name)
    return normalize_surface_type(
        read_named_number(properties_block, property_name, nil)
        or find_named_value(properties_block, "string", property_name)
    )
end

local function read_xml_surface_number(properties_block, property_name, default_value)
    return to_number(read_named_number(properties_block, property_name, default_value), default_value)
end

function decode_rbxl_binary(data)
    if not starts_with(data, RBX.BINARY_SIGNATURE) then
        return nil, "Invalid .rbxl signature"
    end

    local reader = BinaryReader.new(data)
    reader:skip(#RBX.BINARY_SIGNATURE)
    reader:uint16_le() -- version
    reader:uint32_le() -- classcount
    reader:uint32_le() -- instancecount
    reader:skip(8)     -- reserved

    local classes = {}
    local instances = {}
    local roots = {}
    local shared_strings = {}

    while reader:remaining() > 0 do
        local signature = reader:read_string(4)
        if #signature < 4 then
            break
        end

        local compressed_length = reader:uint32_le()
        local uncompressed_length = reader:uint32_le()
        reader:skip(4)

        local read_size = compressed_length == 0 and uncompressed_length or compressed_length
        local raw_payload = reader:read_string(read_size)
        if compressed_length ~= 0 then
            raw_payload = decode_lz4_block(raw_payload, uncompressed_length)
        end

        local payload = BinaryReader.new(raw_payload)

        if signature == "SSTR" then
            local version = payload:uint32_le()
            if version == 0 then
                local count = payload:uint32_le()
                for i = 1, count do
                    payload:skip(16)
                    shared_strings[i] = read_binary_string(payload)
                end
            end
        elseif signature == "INST" then
            local class_id = payload:int32_le()
            local class_name = read_binary_string(payload)
            payload:uint8() -- isservice
            local count = payload:uint32_le()
            local ids = interleaved_int32(payload, count)
            interleaved_uint8(payload, count) -- service flags

            classes[class_id] = {
                class_name = class_name,
                instances = {}
            }

            local running = 0
            for i = 1, count do
                running = running + (ids[i] or 0)
                local instance = {
                    ClassName = class_name,
                    Name = class_name,
                    Referent = running,
                    referent = running,
                    Children = {},
                }
                instances[running] = instance
                classes[class_id].instances[i] = running
            end
        elseif signature == "PROP" then
            local class_id = payload:int32_le()
            local prop_name = read_binary_string(payload)
            local class_info = classes[class_id]
            if class_info then
                local count = #class_info.instances
                local value_type = payload:uint8()
                local values = parse_binary_property_values(payload, value_type, count, class_info.class_name, prop_name,
                    shared_strings)
                if values then
                    local key = prop_name:gsub("^%l", string.upper)
                    if key == "Color3uint8" then
                        key = "Color3"
                    end
                    for i = 1, count do
                        local id = class_info.instances[i]
                        local instance = instances[id]
                        if instance then
                            instance[key] = values[i]
                        end
                    end
                end
            end
        elseif signature == "PRNT" then
            payload:uint8() -- version
            local count = payload:uint32_le()
            local child_deltas = interleaved_int32(payload, count)
            local parent_deltas = interleaved_int32(payload, count)
            local child_running = 0
            local parent_running = 0

            for i = 1, count do
                child_running = child_running + (child_deltas[i] or 0)
                parent_running = parent_running + (parent_deltas[i] or 0)
                local child = instances[child_running]
                if child then
                    if parent_running < 0 then
                        roots[#roots + 1] = child
                    else
                        local parent = instances[parent_running]
                        if parent then
                            parent.Children[#parent.Children + 1] = child
                            child.Parent = parent
                        else
                            roots[#roots + 1] = child
                        end
                    end
                end
            end
        elseif signature == "END\0" then
            break
        end
    end

    return roots
end

local function copy_vector3_entry(value)
    if type(value) ~= "table" then
        return nil
    end
    local x = to_number(value.X or value.x or value[1], nil)
    local y = to_number(value.Y or value.y or value[2], nil)
    local z = to_number(value.Z or value.z or value[3], nil)
    if x == nil and y == nil and z == nil then
        return nil
    end
    return {
        x = x or 0,
        y = y or 0,
        z = z or 0,
    }
end

local function copy_cframe_entry(value)
    if type(value) ~= "table" then
        return nil
    end
    local position = value.Position or value.position
    return {
        x = to_number(value.X or value.x or (position and position.X) or (position and position.x), 0),
        y = to_number(value.Y or value.y or (position and position.Y) or (position and position.y), 0),
        z = to_number(value.Z or value.z or (position and position.Z) or (position and position.z), 0),
        r00 = to_number(value.R00 or value.r00, 1),
        r01 = to_number(value.R01 or value.r01, 0),
        r02 = to_number(value.R02 or value.r02, 0),
        r10 = to_number(value.R10 or value.r10, 0),
        r11 = to_number(value.R11 or value.r11, 1),
        r12 = to_number(value.R12 or value.r12, 0),
        r20 = to_number(value.R20 or value.r20, 0),
        r21 = to_number(value.R21 or value.r21, 0),
        r22 = to_number(value.R22 or value.r22, 1),
    }
end

normalize_referent_value = function(value)
    if value == nil then
        return nil
    end
    if type(value) == "number" then
        if value < 0 then
            return nil
        end
        return value
    end
    if type(value) == "string" then
        local trimmed = trim(value)
        if trimmed == "" or trimmed == "null" then
            return nil
        end
        return trimmed
    end
    if type(value) == "table" then
        local instance = value.instance or value.Instance
        if type(instance) == "table" then
            local referent = instance.referent or instance.Referent
            if type(referent) == "number" then
                return referent >= 0 and referent or nil
            end
            if type(referent) == "string" and trim(referent) ~= "" then
                return trim(referent)
            end
        end
        local referent_value = value.value or value.Value
        if type(referent_value) == "number" then
            return referent_value >= 0 and referent_value or nil
        end
        local referent = value.Referent or value.referent
        if type(referent) == "string" and trim(referent) ~= "" then
            return trim(referent)
        end
        if type(referent) == "number" then
            return referent >= 0 and referent or nil
        end
    end
    return nil
end

local function build_tree_body_mover_entry(instance, parent_referent)
    local class_name = instance and instance.ClassName or nil
    if not LEGACY_BODY_MOVER_CLASSES[class_name] or not parent_referent then
        return nil
    end
    local entry = {
        kind = "mover",
        class_name = class_name,
        name = instance.Name or class_name,
        parent_referent = parent_referent,
    }
    if class_name == "BodyPosition" then
        entry.position = copy_vector3_entry(instance.Position or instance.position)
        entry.max_force = copy_vector3_entry(instance.MaxForce or instance.maxforce)
        entry.p = to_number(instance.P or instance.p, nil)
        entry.d = to_number(instance.D or instance.d, nil)
    elseif class_name == "BodyVelocity" then
        entry.velocity = copy_vector3_entry(instance.Velocity or instance.velocity)
        entry.max_force = copy_vector3_entry(instance.MaxForce or instance.maxforce)
        entry.p = to_number(instance.P or instance.p, nil)
    elseif class_name == "BodyForce" then
        entry.force = copy_vector3_entry(instance.Force or instance.force)
    elseif class_name == "BodyGyro" then
        entry.cframe = copy_cframe_entry(instance.CFrame or instance.cframe or instance.CoordinateFrame or
            instance.coordinateframe)
        entry.max_torque = copy_vector3_entry(instance.MaxTorque or instance.maxtorque)
        entry.p = to_number(instance.P or instance.p, nil)
        entry.d = to_number(instance.D or instance.d, nil)
    elseif class_name == "BodyAngularVelocity" then
        entry.angular_velocity = copy_vector3_entry(instance.AngularVelocity or instance.angularvelocity)
            or copy_vector3_entry(instance.Velocity or instance.velocity)
        entry.max_torque = copy_vector3_entry(instance.MaxTorque or instance.maxtorque)
        entry.p = to_number(instance.P or instance.p, nil)
    elseif class_name == "BodyThrust" then
        entry.force = copy_vector3_entry(instance.Force or instance.force)
        entry.location = copy_vector3_entry(instance.Location or instance.location)
    end
    return entry
end

local function build_tree_joint_entry(instance)
    local class_name = instance and instance.ClassName or nil
    -- NoCollisionConstraint: part0/part1 pair, emitted as kind="no_collision" w/ no c0/c1
    if class_name == "NoCollisionConstraint" then
        local p0 = normalize_referent_value(instance.Part0 or instance.part0)
        local p1 = normalize_referent_value(instance.Part1 or instance.part1)
        if not p0 or not p1 then
            return nil
        end
        return {
            kind = "no_collision",
            class_name = class_name,
            name = instance.Name or class_name,
            enabled = instance.Enabled ~= false and instance.enabled ~= false,
            referent = normalize_referent_value(instance.Referent or instance.referent),
            part0_referent = p0,
            part1_referent = p1,
        }
    end
    if not LEGACY_JOINT_INSTANCE_CLASSES[class_name] then
        return nil
    end
    local part0_referent = normalize_referent_value(instance.Part0 or instance.part0)
    local part1_referent = normalize_referent_value(instance.Part1 or instance.part1)
    if not part0_referent or not part1_referent then
        return nil
    end
    return {
        kind = "joint",
        class_name = class_name,
        name = instance.Name or class_name,
        enabled = instance.Enabled ~= false and instance.enabled ~= false,
        -- lets a materialized instance match back to this record on destroy/disable
        referent = normalize_referent_value(instance.Referent or instance.referent),
        part0_referent = part0_referent,
        part1_referent = part1_referent,
        c0 = copy_cframe_entry(instance.C0 or instance.c0),
        c1 = copy_cframe_entry(instance.C1 or instance.c1),
        base_angle = to_number(instance.BaseAngle or instance.baseangle, nil),
        -- RotateV actuator params: usually on the axle part surface, but can serialize on the joint
        param_a = to_number(instance.ParamA or instance.parama, nil),
        param_b = to_number(instance.ParamB or instance.paramb, nil),
        surface_input = to_number(instance.SurfaceInput or instance.surfaceinput, nil),
    }
end

function collect_supported_parts_from_tree(roots, options)
    options = options or {}
    local workspace_subtree_skip_policy =
        options.skip_workspace_subtrees
    local parts = {}
    local constraints = {}
    local physics_instances = {}
    local local_lights = {}
    local attachments_by_ref = {}
    local part_index_by_instance = {}
    local part_index_by_ref = {}
    local part_transform_by_instance = {}
    local scanned_items = 0
    local skipped_items = 0
    local local_light_invalid_count = 0
    local render_roots = RBX._collect_render_roots(roots)

    local function parse_constraint_color(raw_color)
        if type(raw_color) == "number" then
            local color = BRICK_COLORS[tonumber(raw_color) or -1]
            if color then
                return to_number(color[1], 235), to_number(color[2], 235), to_number(color[3], 235)
            end
        elseif type(raw_color) == "table" then
            if raw_color.Color then
                return to_number(raw_color.Color.R, 235), to_number(raw_color.Color.G, 235),
                    to_number(raw_color.Color.B, 235)
            end
            local keypoints = raw_color.keypoints or raw_color.Keypoints or raw_color
            if type(keypoints) == "table" and type(keypoints[1]) == "table" then
                local value = keypoints[1].value or keypoints[1].Value or keypoints[1].color or keypoints[1].Color
                if type(value) == "table" then
                    return color3_to_rgb255(value, 1, 1, 1)
                end
            end
            if raw_color[1] ~= nil and raw_color[2] ~= nil and raw_color[3] ~= nil then
                return color3_to_rgb255(raw_color, 1, 1, 1)
            end
        end

        return 235, 235, 235
    end

    local function parse_constraint_transparency(raw_value)
        if type(raw_value) == "number" then
            return clamp(raw_value, 0, 1)
        end
        if type(raw_value) == "table" then
            local keypoints = raw_value.keypoints or raw_value.Keypoints or raw_value
            if type(keypoints) == "table" and type(keypoints[1]) == "table" then
                return clamp(tonumber(
                    keypoints[1].value or keypoints[1].Value or keypoints[1].transparency or keypoints[1].Transparency or
                    keypoints[1][2]
                ) or 0, 0, 1)
            end
            return clamp(tonumber(raw_value[2]) or 0, 0, 1)
        end
        return 0
    end

    local function append_attachment(parent_part_index, parent_referent, parent_transform, child, parent_cframe)
        local referent = child and (child.Referent or child.referent) or nil
        if referent == nil then
            return
        end

        local cframe = child.CFrame or child.CoordinateFrame or child.cframe or child.coordinateframe
        local position = child.Position or child.position
        local local_x = to_number((cframe and (cframe.X or (cframe.Position and cframe.Position.X))) or
            (position and position.X), 0)
        local local_y = to_number((cframe and (cframe.Y or (cframe.Position and cframe.Position.Y))) or
            (position and position.Y), 0)
        local local_z = to_number((cframe and (cframe.Z or (cframe.Position and cframe.Position.Z))) or
            (position and position.Z), 0)
        local world_x, world_y, world_z = RBX._transform_attachment_world_point(parent_cframe, local_x, local_y, local_z)
        local entry = {
            referent = referent,
            parent_part_index = parent_part_index,
            parent_referent = parent_referent,
            parent_transform = parent_transform,
            local_x = local_x,
            local_y = local_y,
            local_z = local_z,
            world_x = world_x,
            world_y = world_y,
            world_z = world_z,
        }
        copy_attachment_transform_fields(entry, cframe)
        attachments_by_ref[referent] = entry
    end

    local function append_part(instance)
        if parse_progress_hook then parse_progress_hook("dom_collect") end
        scanned_items = scanned_items + 1

        local cframe = instance.CFrame or instance.CoordinateFrame or instance.cframe or instance.coordinateframe
        local size = instance.Size or instance.size
        if size ~= nil then RBX._size_validation.components(size, instance) end
        local shape = normalize_part_shape(instance.Shape or instance.shape, instance.ClassName)
        if not cframe or not size then
            skipped_items = skipped_items + 1
            return
        end

        local transparency = to_number(instance.Transparency, 0)
        -- keep transparent parts in the instance tree and physics world
        -- visibility only affects drawing; child decals and GUIs can still be visible
        local keep_invisible = RBX._parse_invisible_parts == true
        local renderable = transparency < 1 or keep_invisible
        local reflectance = clamp(to_number(instance.Reflectance, 0), 0, 1)
        local referent = normalize_referent_value(instance.Referent or instance.referent)
        local velocity, velocity_source = read_tree_part_linear_velocity(instance)
        local rot_velocity, rot_velocity_source = read_tree_part_angular_velocity(instance)
        part_transform_by_instance[instance] = {
            referent = referent,
            x = to_number(cframe.X or (cframe.Position and cframe.Position.X), 0),
            y = to_number(cframe.Y or (cframe.Position and cframe.Position.Y), 0),
            z = to_number(cframe.Z or (cframe.Position and cframe.Position.Z), 0),
            r00 = to_number(cframe.R00 or cframe.r00, 1),
            r01 = to_number(cframe.R01 or cframe.r01, 0),
            r02 = to_number(cframe.R02 or cframe.r02, 0),
            r10 = to_number(cframe.R10 or cframe.r10, 0),
            r11 = to_number(cframe.R11 or cframe.r11, 1),
            r12 = to_number(cframe.R12 or cframe.r12, 0),
            r20 = to_number(cframe.R20 or cframe.r20, 0),
            r21 = to_number(cframe.R21 or cframe.r21, 0),
            r22 = to_number(cframe.R22 or cframe.r22, 1),
            sx = to_number(size.X, 4),
            sy = to_number(size.Y, 1),
            sz = to_number(size.Z, 2),
        }

        local r, g, b
        local color3 = instance.Color3 or instance.Color or instance.Color3uint8 or
            instance.color3 or instance.color or instance.color3uint8
        local brick_color = instance.BrickColor or instance.brickcolor
        if color3 then
            r, g, b = color3_to_rgb255(color3, 1, 1, 1)
        elseif brick_color and brick_color.Color then
            r = to_number(brick_color.Color.R, 200)
            g = to_number(brick_color.Color.G, 200)
            b = to_number(brick_color.Color.B, 200)
        else
            r, g, b = 200, 200, 200
        end

        local mesh_id = nil
        local texture_id = nil
        local mesh_owner = nil
        local special_mesh_type = nil
        local special_mesh_scale = nil
        local special_mesh_offset = nil
        local special_mesh_vertex_color = nil
        local mesh_vertex_color = nil
        local blockmesh_scale = nil
        local blockmesh_offset = nil
        local mesh_size = nil
        local embedded_mesh_data = nil
        local embedded_mesh_candidates = nil
        local use_part_color = nil
        local double_sided = nil
        local smoothing_angle = nil
        local render_fidelity = nil
        local collision_fidelity = nil
        local physics_data = nil
        local physical_config_data = nil
        local triangle_count = nil
        local material_variant = nil
        if instance.ClassName == "MeshPart" then
            mesh_id = instance.MeshId or instance.MeshID or instance.meshid
            texture_id = instance.TextureContent or instance.TextureId or instance.TextureID
                or instance.texturecontent or instance.textureid
            mesh_owner = instance
            mesh_size = normalize_mesh_size_value(instance.MeshSize or instance.ModelMeshSize or instance.InitialSize or
                instance.meshsize or instance.modelmeshsize or instance.initialsize)
            double_sided = instance.DoubleSided == true or instance.doublesided == true
            render_fidelity = instance.RenderFidelity or instance.renderfidelity
            collision_fidelity = instance.CollisionFidelity or instance.collisionfidelity
            physics_data = instance.PhysicsData or instance.physicsdata
            physical_config_data = instance.PhysicalConfigData or instance.physicalconfigdata
            triangle_count = to_number(instance.TriangleCount or instance.trianglecount, nil)
            material_variant = instance.MaterialVariant or instance.materialvariant
            if instance.VertexColor or instance.vertexcolor then
                mesh_vertex_color = normalize_special_mesh_vertex_color(instance.VertexColor or instance.vertexcolor)
            end
        elseif is_csg_part_class(instance.ClassName) then
            mesh_id = instance.AssetId or instance.MeshId or instance.MeshID or instance.assetid or instance.meshid
            texture_id = instance.TextureContent or instance.TextureId or instance.TextureID
                or instance.texturecontent or instance.textureid
            mesh_owner = instance
            mesh_size = normalize_mesh_size_value(instance.MeshSize or instance.ModelMeshSize or instance.InitialSize or
                instance.meshsize or instance.modelmeshsize or instance.initialsize)
            double_sided = instance.DoubleSided == true or instance.doublesided == true
            smoothing_angle = to_number(instance.SmoothingAngle or instance.smoothingangle, nil)
            render_fidelity = instance.RenderFidelity or instance.renderfidelity
            collision_fidelity = instance.CollisionFidelity or instance.collisionfidelity
            physics_data = instance.PhysicsData or instance.physicsdata
            physical_config_data = instance.PhysicalConfigData or instance.physicalconfigdata
            triangle_count = to_number(instance.TriangleCount or instance.trianglecount, nil)
            material_variant = instance.MaterialVariant or instance.materialvariant
            embedded_mesh_candidates = collect_csg_embedded_mesh_candidates_from_instance(instance)
            embedded_mesh_data = embedded_mesh_candidates and embedded_mesh_candidates[1] or nil
            if instance.VertexColor or instance.vertexcolor then
                mesh_vertex_color = normalize_special_mesh_vertex_color(instance.VertexColor or instance.vertexcolor)
            end
            use_part_color = instance.UsePartColor ~= false and instance.usepartcolor ~= false
        else
            local legacy_mesh = find_last_legacy_mesh_child(instance.Children)
            local legacy_class = legacy_mesh and legacy_mesh.ClassName or nil
            if legacy_class == "SpecialMesh" then
                mesh_id = legacy_mesh.MeshContent or legacy_mesh.MeshId
                    or legacy_mesh.MeshID or legacy_mesh.meshcontent
                    or legacy_mesh.meshid
                texture_id = legacy_mesh.TextureContent
                    or legacy_mesh.TextureId or legacy_mesh.TextureID
                    or legacy_mesh.texturecontent or legacy_mesh.textureid
                mesh_owner = legacy_mesh
                local raw_mesh_type = legacy_mesh.MeshType
                if raw_mesh_type == nil then raw_mesh_type = legacy_mesh.meshtype end
                -- MeshType's native default is Head, but only an actual selected
                -- SpecialMesh child earns that default. an ordinary Part never does
                -- Studio 0.735 deserializes a missing, malformed, negative, or
                -- out-of-range MeshType on an actual SpecialMesh child as its
                -- native property default (Head = 0).  do not use MeshId as an
                -- implicit FileMesh selector here: native ignores it unless the
                -- authored enum itself is FileMesh
                special_mesh_type = normalize_special_mesh_type(
                    raw_mesh_type, nil) or "Head"
                special_mesh_scale = normalize_vector3_value(
                    legacy_mesh.Scale or legacy_mesh.scale, 1, 1, 1)
                special_mesh_offset = normalize_vector3_value(
                    legacy_mesh.Offset or legacy_mesh.offset, 0, 0, 0)
                special_mesh_vertex_color = normalize_special_mesh_vertex_color(
                    legacy_mesh.VertexColor or legacy_mesh.vertexcolor)
            elseif legacy_class == "CylinderMesh" then
                mesh_owner = "CylinderMesh"
                special_mesh_type = "Cylinder"
                special_mesh_scale = normalize_vector3_value(
                    legacy_mesh.Scale or legacy_mesh.scale, 1, 1, 1)
                special_mesh_offset = normalize_vector3_value(
                    legacy_mesh.Offset or legacy_mesh.offset, 0, 0, 0)
                special_mesh_vertex_color = normalize_special_mesh_vertex_color(
                    legacy_mesh.VertexColor or legacy_mesh.vertexcolor)
            elseif legacy_class == "BlockMesh" then
                mesh_owner = "BlockMesh"
                blockmesh_scale = normalize_vector3_value(
                    legacy_mesh.Scale or legacy_mesh.scale, 1, 1, 1)
                blockmesh_offset = normalize_vector3_value(
                    legacy_mesh.Offset or legacy_mesh.offset, 0, 0, 0)
                mesh_vertex_color = normalize_special_mesh_vertex_color(
                    legacy_mesh.VertexColor or legacy_mesh.vertexcolor)
                if mesh_vertex_color.r == 1 and mesh_vertex_color.g == 1
                    and mesh_vertex_color.b == 1 then
                    mesh_vertex_color = nil
                end
            end
        end

        local face_textures = {}
        local surface_guis = {}
        local billboard_guis = {}
        local surface_appearance = nil
        local surface_properties = read_instance_surface_properties(instance)
        local part_index = #parts + 1
        local children = instance.Children or {}
        for i = 1, #children do
            local child = children[i]
            local child_class = child and (child.ClassName or child.className or child.class_name) or nil
            if child_class == "SurfaceAppearance" and surface_appearance == nil then
                -- Roblox authors at most one effective SurfaceAppearance per mesh
                -- Malformed/hand-authored files can contain several, so pin the
                -- first direct child in authored order on both parser paths
                surface_appearance = RBX._build_surface_appearance_descriptor(child, i)
            elseif (child_class == "Decal" or child_class == "Texture") and renderable then
                -- empty content is a dormant authored FaceInstance, not an
                -- absent one: retain it so a later facade write can activate
                -- the layer without reconstructing source hierarchy metadata
                face_textures[#face_textures + 1] =
                    RBX._normalize_face_texture_descriptor(child, child_class, {
                        referent = child.Referent,
                        name = child.Name,
                        authored_index = i,
                    })
            elseif RBX._is_surface_gui_class(child_class) then
                local parsed_gui = RBX._parse_surface_gui_instance(child, part_index, #surface_guis)
                if parsed_gui then
                    surface_guis[#surface_guis + 1] = parsed_gui
                end
            elseif RBX._is_billboard_gui_class(child_class) then
                local parsed_gui = RBX._parse_billboard_gui_instance(child, part_index, #billboard_guis)
                if parsed_gui then
                    billboard_guis[#billboard_guis + 1] = parsed_gui
                end
            elseif child_class == "Attachment" then
                append_attachment(renderable and part_index or nil, referent, part_transform_by_instance[instance], child, cframe)
                elseif LEGACY_BODY_MOVER_CLASSES[child_class] and referent then
                    local parsed_mover = build_tree_body_mover_entry(child, referent)
                    if parsed_mover then
                        physics_instances[#physics_instances + 1] = parsed_mover
                    end
            end
        end

        if not renderable then
            return
        end

        parts[part_index] = {
            class_name = instance.ClassName or "Part",
            name = instance.Name or (instance.ClassName or "Part"),
            shape = shape,
            x = to_number(cframe.X or (cframe.Position and cframe.Position.X), 0),
            y = to_number(cframe.Y or (cframe.Position and cframe.Position.Y), 0),
            z = to_number(cframe.Z or (cframe.Position and cframe.Position.Z), 0),
            r00 = to_number(cframe.R00, 1),
            r01 = to_number(cframe.R01, 0),
            r02 = to_number(cframe.R02, 0),
            r10 = to_number(cframe.R10, 0),
            r11 = to_number(cframe.R11, 1),
            r12 = to_number(cframe.R12, 0),
            r20 = to_number(cframe.R20, 0),
            r21 = to_number(cframe.R21, 0),
            r22 = to_number(cframe.R22, 1),
            sx = to_number(size.X, 4),
            sy = to_number(size.Y, 1),
            sz = to_number(size.Z, 2),
            referent = referent,
            anchored = instance.Anchored == true,
            can_collide = instance.CanCollide ~= false,
            can_touch = instance.CanTouch ~= false,
            can_query = instance.CanQuery ~= false,
            -- CastShadow defaults true in roblox
            cast_shadow = (instance.CastShadow ~= false) and (instance.castshadow ~= false),
            collision_group = normalize_collision_group_name(
                source_group_property(instance.CollisionGroupId, instance.collisiongroupid),
                source_group_property(instance.CollisionGroup, instance.collisiongroup)),
            collision_group_source_name = source_group_property(instance.CollisionGroup, instance.collisiongroup),
            collision_group_legacy_id = source_group_property(instance.CollisionGroupId, instance.collisiongroupid),
            massless = instance.Massless == true,
            root_priority = to_number(instance.RootPriority or instance.rootpriority, 0),
            custom_physical_properties = parse_tree_custom_physical_properties(
                instance.CustomPhysicalProperties or instance.customphysicalproperties
            ),
            linear_velocity = velocity,
            linear_velocity_source = velocity_source,
            angular_velocity = rot_velocity,
            angular_velocity_source = rot_velocity_source,
            material = to_number(instance.Material, 0),
            reflectance = reflectance,
            color_r = r,
            color_g = g,
            color_b = b,
            color_a = math.floor(clamp((1 - transparency) * 255, 0, 255) + 0.5),
            transparency = clamp(transparency, 0, 1),
            mesh_id = normalize_asset_reference(mesh_id),
            texture_id = normalize_asset_reference(texture_id),
            mesh_owner = type(mesh_owner) == "string" and mesh_owner or (mesh_owner and mesh_owner.ClassName) or nil,
            special_mesh_type = special_mesh_type,
            special_mesh_scale = special_mesh_scale,
            special_mesh_offset = special_mesh_offset,
            special_mesh_vertex_color = special_mesh_vertex_color,
            mesh_vertex_color = mesh_vertex_color,
            use_part_color = use_part_color,
            double_sided = double_sided == true,
            smoothing_angle = smoothing_angle,
            render_fidelity = render_fidelity,
            collision_fidelity = collision_fidelity,
            physics_data = physics_data,
            physical_config_data = type(physical_config_data) == "string" and physical_config_data ~= ""
                and physical_config_data or nil,
            triangle_count = triangle_count,
            material_variant = material_variant,
            surface_appearance = part_supports_surface_appearance(
                instance.ClassName, mesh_owner) and surface_appearance or nil,
            top_surface = surface_properties.top_surface,
            bottom_surface = surface_properties.bottom_surface,
            left_surface = surface_properties.left_surface,
            right_surface = surface_properties.right_surface,
            front_surface = surface_properties.front_surface,
            back_surface = surface_properties.back_surface,
            top_surface_input = surface_properties.top_surface_input,
            bottom_surface_input = surface_properties.bottom_surface_input,
            left_surface_input = surface_properties.left_surface_input,
            right_surface_input = surface_properties.right_surface_input,
            front_surface_input = surface_properties.front_surface_input,
            back_surface_input = surface_properties.back_surface_input,
            top_param_a = surface_properties.top_param_a,
            top_param_b = surface_properties.top_param_b,
            bottom_param_a = surface_properties.bottom_param_a,
            bottom_param_b = surface_properties.bottom_param_b,
            left_param_a = surface_properties.left_param_a,
            left_param_b = surface_properties.left_param_b,
            right_param_a = surface_properties.right_param_a,
            right_param_b = surface_properties.right_param_b,
            front_param_a = surface_properties.front_param_a,
            front_param_b = surface_properties.front_param_b,
            back_param_a = surface_properties.back_param_a,
            back_param_b = surface_properties.back_param_b,
            face_textures = face_textures,
            surface_guis = surface_guis,
            billboard_guis = billboard_guis,
            blockmesh_scale = blockmesh_scale,
            blockmesh_offset = blockmesh_offset,
            mesh_size = mesh_size,
            embedded_mesh_data = embedded_mesh_data,
            embedded_mesh_candidates = embedded_mesh_candidates,
        }
        part_index_by_instance[instance] = part_index
        if referent ~= nil then
            part_index_by_ref[referent] = part_index
        end
    end

    local function append_constraint(instance)
        local class_name = instance and instance.ClassName or nil
        if class_name ~= "RopeConstraint" and class_name ~= "RodConstraint" and class_name ~= "Beam" then
            return
        end

        local attachment0 = instance.Attachment0 or instance.attachment0
        local attachment1 = instance.Attachment1 or instance.attachment1
        local entry0 = attachments_by_ref[attachment0]
        local entry1 = attachments_by_ref[attachment1]
        if not entry0 or not entry1 then
            return
        end

        if instance.Visible == false or instance.visible == false or instance.Enabled == false or instance.enabled == false then
            return
        end

        local width0 = to_number(instance.Width0 or instance.width0, nil)
        local width1 = to_number(instance.Width1 or instance.width1, nil)
        local thickness = to_number(instance.Thickness or instance.thickness,
            math.max(width0 or 0, width1 or 0, class_name == "Beam" and 0.15 or 0.2))
        if thickness <= 0 then
            thickness = math.max(width0 or 0, width1 or 0, 0.15)
        end

        local color_r, color_g, color_b = parse_constraint_color(instance.Color or instance.color)
        constraints[#constraints + 1] = {
            class_name = class_name,
            name = instance.Name or class_name,
            attachment0 = attachment0,
            attachment1 = attachment1,
            attachment0_entry = entry0,
            attachment1_entry = entry1,
            thickness = thickness,
            width0 = width0,
            width1 = width1,
            transparency = parse_constraint_transparency(instance.Transparency or instance.transparency),
            color_r = color_r,
            color_g = color_g,
            color_b = color_b,
        }
    end

    local function count_supported_descendants(instance)
        if type(instance) ~= "table" then
            return 0
        end

        local count = SUPPORTED_PART_CLASSES[instance.ClassName] and 1 or 0
        local children = instance.Children
        if type(children) == "table" then
            for i = 1, #children do
                count = count + count_supported_descendants(children[i])
            end
        end
        return count
    end

    local function should_skip_workspace_child(child, is_render_root)
        if not is_render_root or type(child) ~= "table"
            or not RBX._workspace_subtree_skip_policy_matches(
                child.Name, child.ClassName,
                workspace_subtree_skip_policy) then
            return false
        end
        -- the recursive count is deliberately lazy. With the default render-all
        -- policy this removes several redundant full Workspace traversals
        return RBX._should_skip_workspace_subtree_name(
            child.Name, child.ClassName,
            count_supported_descendants(child),
            workspace_subtree_skip_policy)
    end

    local function walk_parts(instance, is_render_root)
        if type(instance) ~= "table" then
            return
        end

        if SUPPORTED_PART_CLASSES[instance.ClassName] then
            append_part(instance)
        end
        local children = instance.Children
        if type(children) == "table" then
            for i = 1, #children do
                local child = children[i]
                if not should_skip_workspace_child(
                    child, is_render_root) then
                    walk_parts(child, false)
                end
            end
        end
    end

    local function walk_constraints(instance, is_render_root)
        if type(instance) ~= "table" then
            return
        end

        append_constraint(instance)
        local children = instance.Children
        if type(children) == "table" then
            for i = 1, #children do
                local child = children[i]
                if not should_skip_workspace_child(
                    child, is_render_root) then
                    walk_constraints(child, false)
                end
            end
        end
    end

    local function walk_physics_instances(instance, is_render_root)
        if type(instance) ~= "table" then
            return
        end

        local parsed_joint = build_tree_joint_entry(instance)
        if parsed_joint then
            physics_instances[#physics_instances + 1] = parsed_joint
        end

        local children = instance.Children
        if type(children) == "table" then
            for i = 1, #children do
                local child = children[i]
                if not should_skip_workspace_child(
                    child, is_render_root) then
                    walk_physics_instances(child, false)
                end
            end
        end
    end

    for i = 1, #(render_roots or {}) do
        walk_parts(render_roots[i], render_roots[i] and render_roots[i].ClassName == "Workspace")
    end
    for i = 1, #(render_roots or {}) do
        walk_constraints(render_roots[i], render_roots[i] and render_roots[i].ClassName == "Workspace")
    end
    for i = 1, #(roots or {}) do
        walk_physics_instances(roots[i], roots[i] and roots[i].ClassName == "Workspace")
    end

    -- screen guis have no anchor part: collected flat, drawn 2d post-scene
    local screen_guis = {}

    local function walk_surface_guis(instance, is_render_root)
        if type(instance) ~= "table" then
            return
        end

        local class_name = instance.ClassName or instance.className or instance.class_name
        local is_surface_gui = RBX._is_surface_gui_class(class_name)
        local is_billboard_gui = RBX._is_billboard_gui_class(class_name)
        if is_surface_gui or is_billboard_gui then
            -- part-parented guis came from the per-part scan, this is the Adornee-anchored remainder
            local parent_part_index = part_index_by_instance[instance.Parent]
            local target_part_index = nil
            if not parent_part_index then
                target_part_index = part_index_by_ref[instance.Adornee or instance.adornee]
            end

            local target_part = target_part_index and parts[target_part_index] or nil
            if target_part then
                if is_surface_gui then
                    local parsed_gui = RBX._parse_surface_gui_instance(
                        instance,
                        target_part_index,
                        #target_part.surface_guis
                    )
                    if parsed_gui then
                        target_part.surface_guis[#target_part.surface_guis + 1] = parsed_gui
                    end
                else
                    target_part.billboard_guis = target_part.billboard_guis or {}
                    local parsed_gui = RBX._parse_billboard_gui_instance(
                        instance,
                        target_part_index,
                        #target_part.billboard_guis
                    )
                    if parsed_gui then
                        target_part.billboard_guis[#target_part.billboard_guis + 1] = parsed_gui
                    end
                end
            end
        elseif RBX._is_screen_gui_class and RBX._is_screen_gui_class(class_name) then
            local parsed_gui = RBX._parse_screen_gui_instance(instance, #screen_guis)
            if parsed_gui then
                screen_guis[#screen_guis + 1] = parsed_gui
            end
        end

        local children = instance.Children
        if type(children) == "table" then
            for i = 1, #children do
                local child = children[i]
                if not should_skip_workspace_child(
                    child, is_render_root) then
                    walk_surface_guis(child, false)
                end
            end
        end
    end

    for i = 1, #(render_roots or {}) do
        walk_surface_guis(render_roots[i], render_roots[i] and render_roots[i].ClassName == "Workspace")
    end
    -- StarterGui hosts guis but isnt under render roots. skip if render_roots==roots, already walked
    if render_roots ~= roots then
        local starter_gui_roots = {}
        for i = 1, #(roots or {}) do
            RBX._collect_descendants_by_class(roots[i], "StarterGui", starter_gui_roots)
        end
        for i = 1, #starter_gui_roots do
            walk_surface_guis(starter_gui_roots[i], false)
        end
    end

    local function copy_flat_entry(entry)
        if type(entry) ~= "table" then
            return nil
        end
        local out = {}
        for key, value in pairs(entry) do
            if type(value) ~= "table" then
                out[key] = value
            end
        end
        return out
    end

    local function instance_path(instance)
        local segments = {}
        local current = instance
        while type(current) == "table" do
            local name = current.Name or current.name or current.ClassName or current.className or "Instance"
            segments[#segments + 1] = tostring(name)
            current = current.Parent
        end
        local out = {}
        for i = #segments, 1, -1 do
            out[#out + 1] = segments[i]
        end
        return table.concat(out, ".")
    end

    local function append_local_light(instance)
        if type(instance) ~= "table" then
            return
        end
        local class_name = instance.ClassName or instance.className or instance.class_name
        if not LOCAL_LIGHT_CLASSES[class_name] then
            return
        end

        local entry = RBX._make_local_light_entry(class_name, instance)
        if not entry then
            return
        end

        local parent = instance.Parent
        local parent_class = parent and (parent.ClassName or parent.className or parent.class_name) or nil
        if SUPPORTED_PART_CLASSES[parent_class] then
            local part_index = part_index_by_instance[parent]
            local part_transform = part_transform_by_instance[parent]
            if not part_index and not part_transform then
                entry.invalid_reason = "missing_parent_transform"
                local_light_invalid_count = local_light_invalid_count + 1
                return
            end
            -- Transparency=1 hides the surface but must NOT disable child lights
            local parent_transparency = to_number(parent.Transparency, 0)
            entry.parent_kind = "Part"
            entry.parent_class = parent_class
            entry.parent_name = parent.Name or parent_class
            entry.parent_path = instance_path(parent)
            entry.parent_part_index = part_index
            entry.parent_referent = part_transform and part_transform.referent
                or (part_index and parts[part_index] and parts[part_index].referent)
            entry.parent_transform = copy_flat_entry(part_transform)
            entry.parent_transparency = parent_transparency
            entry.parent_transparent_at_load = parent_transparency >= 1
            local_lights[#local_lights + 1] = entry
            return
        end

        if parent_class == "Attachment" then
            local attachment_ref = normalize_referent_value(parent.Referent or parent.referent)
            local attachment = attachment_ref and attachments_by_ref[attachment_ref] or nil
            if not attachment then
                entry.invalid_reason = "missing_attachment"
                local_light_invalid_count = local_light_invalid_count + 1
                return
            end
            local attachment_parent = parent and parent.Parent or nil
            local attachment_parent_transparency = attachment_parent
                and to_number(attachment_parent.Transparency, 0) or 0
            entry.parent_kind = "Attachment"
            entry.parent_class = attachment_parent and (attachment_parent.ClassName or attachment_parent.className) or "BasePart"
            entry.parent_name = attachment_parent and (attachment_parent.Name or attachment_parent.ClassName) or nil
            entry.parent_path = attachment_parent and instance_path(attachment_parent) or nil
            entry.parent_part_index = attachment.parent_part_index
            entry.parent_referent = attachment.parent_referent
            entry.attachment_referent = attachment.referent
            entry.attachment = copy_flat_entry(attachment)
            entry.parent_transform = copy_flat_entry(attachment.parent_transform)
            entry.parent_transparency = attachment_parent_transparency
            entry.parent_transparent_at_load = attachment_parent_transparency >= 1
            local_lights[#local_lights + 1] = entry
            return
        end

        entry.invalid_reason = "parent_not_workspace_descendant"
        local_light_invalid_count = local_light_invalid_count + 1
    end

    local function walk_local_lights(instance, is_render_root)
        if type(instance) ~= "table" then
            return
        end

        append_local_light(instance)
        local children = instance.Children
        if type(children) == "table" then
            for i = 1, #children do
                local child = children[i]
                if not should_skip_workspace_child(
                    child, is_render_root) then
                    walk_local_lights(child, false)
                end
            end
        end
    end

    for i = 1, #(render_roots or {}) do
        walk_local_lights(render_roots[i], render_roots[i] and render_roots[i].ClassName == "Workspace")
    end

    -- named field on the numeric parts array, numeric iteration ignores it
    parts._screen_guis = screen_guis
    return parts, constraints, physics_instances, scanned_items, skipped_items, local_lights, local_light_invalid_count
end

local function count_rigid_joint_entries(physics_instances)
    local count = 0
    for index = 1, #(physics_instances or {}) do
        local entry = physics_instances[index]
        if entry and entry.kind == "joint" and LEGACY_JOINT_INSTANCE_CLASSES[entry.class_name] then
            count = count + 1
        end
    end
    return count
end

local function collect_parse_resolution_stats(parts, physics_instances)
    local part_refs = {}
    local stats = {
        resolved_joint_count = 0,
        unresolved_joint_count = 0,
        resolved_rigid_joint_count = 0,
        unresolved_rigid_joint_count = 0,
        resolved_mover_count = 0,
        unresolved_mover_count = 0,
        resolved_physics_instance_count = 0,
    }

    for index = 1, #(parts or {}) do
        local part = parts[index]
        if part and part.referent ~= nil then
            part_refs[part.referent] = true
        end
    end

    for index = 1, #(physics_instances or {}) do
        local entry = physics_instances[index]
        if entry and entry.kind == "joint" then
            local resolved = part_refs[entry.part0_referent] == true and part_refs[entry.part1_referent] == true
            if resolved then
                stats.resolved_joint_count = stats.resolved_joint_count + 1
                stats.resolved_physics_instance_count = stats.resolved_physics_instance_count + 1
                if LEGACY_JOINT_INSTANCE_CLASSES[entry.class_name] then
                    stats.resolved_rigid_joint_count = stats.resolved_rigid_joint_count + 1
                end
            else
                stats.unresolved_joint_count = stats.unresolved_joint_count + 1
                if LEGACY_JOINT_INSTANCE_CLASSES[entry.class_name] then
                    stats.unresolved_rigid_joint_count = stats.unresolved_rigid_joint_count + 1
                end
            end
        elseif entry and entry.kind == "mover" then
            local resolved = part_refs[entry.parent_referent] == true
            if resolved then
                stats.resolved_mover_count = stats.resolved_mover_count + 1
                stats.resolved_physics_instance_count = stats.resolved_physics_instance_count + 1
            else
                stats.unresolved_mover_count = stats.unresolved_mover_count + 1
            end
        end
    end

    return stats
end

local function count_surface_controller_fields(parts)
    local count = 0
    for part_index = 1, #(parts or {}) do
        local part = parts[part_index]
        if part then
            for _, prefix in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
                if (tonumber(part[prefix .. "_surface_input"]) or 0) ~= 0 then
                    count = count + 1
                end
                if part[prefix .. "_param_a"] ~= nil then
                    count = count + 1
                end
                if part[prefix .. "_param_b"] ~= nil then
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function count_configured_mover_fields(physics_instances)
    local count = 0
    for index = 1, #(physics_instances or {}) do
        local entry = physics_instances[index]
        if entry and entry.kind == "mover" then
            if entry.position then
                count = count + 1
            end
            if entry.velocity then
                count = count + 1
            end
            if entry.angular_velocity then
                count = count + 1
            end
            if entry.force then
                count = count + 1
            end
            if entry.location then
                count = count + 1
            end
            if entry.max_force then
                count = count + 1
            end
            if entry.max_torque then
                count = count + 1
            end
            if entry.cframe then
                count = count + 1
            end
            if entry.p ~= nil then
                count = count + 1
            end
            if entry.d ~= nil then
                count = count + 1
            end
        end
    end
    return count
end

local function make_binary_parse_candidate(parse_strategy, roots, parts, constraints, physics_instances, scanned_items,
                                           skipped_items, local_lights, local_light_invalid_count)
    local resolution_stats = collect_parse_resolution_stats(parts, physics_instances)
    return {
        parse_strategy = parse_strategy,
        roots = roots,
        parts = parts,
        constraints = constraints,
        physics_instances = physics_instances,
        local_lights = local_lights or {},
        local_light_invalid_count = local_light_invalid_count or 0,
        scanned_items = scanned_items,
        skipped_items = skipped_items,
        rigid_joint_count = count_rigid_joint_entries(physics_instances),
        surface_controller_field_count = count_surface_controller_fields(parts),
        configured_mover_field_count = count_configured_mover_fields(physics_instances),
        resolved_joint_count = resolution_stats.resolved_joint_count,
        unresolved_joint_count = resolution_stats.unresolved_joint_count,
        resolved_rigid_joint_count = resolution_stats.resolved_rigid_joint_count,
        unresolved_rigid_joint_count = resolution_stats.unresolved_rigid_joint_count,
        resolved_mover_count = resolution_stats.resolved_mover_count,
        unresolved_mover_count = resolution_stats.unresolved_mover_count,
        resolved_physics_instance_count = resolution_stats.resolved_physics_instance_count,
    }
end

local function make_binary_parse_diagnostic(candidate)
    if not candidate then
        return nil
    end
    return {
        parse_strategy = candidate.parse_strategy,
        part_count = #(candidate.parts or {}),
        physics_instance_count = #(candidate.physics_instances or {}),
        local_light_count = #(candidate.local_lights or {}),
        local_light_invalid_count = candidate.local_light_invalid_count or 0,
        rigid_joint_count = candidate.rigid_joint_count or 0,
        surface_controller_field_count = candidate.surface_controller_field_count or 0,
        configured_mover_field_count = candidate.configured_mover_field_count or 0,
        resolved_joint_count = candidate.resolved_joint_count or 0,
        unresolved_joint_count = candidate.unresolved_joint_count or 0,
        resolved_rigid_joint_count = candidate.resolved_rigid_joint_count or 0,
        unresolved_rigid_joint_count = candidate.unresolved_rigid_joint_count or 0,
        resolved_mover_count = candidate.resolved_mover_count or 0,
        unresolved_mover_count = candidate.unresolved_mover_count or 0,
        resolved_physics_instance_count = candidate.resolved_physics_instance_count or 0,
        scanned_items = candidate.scanned_items or 0,
        skipped_items = candidate.skipped_items or 0,
    }
end

local function choose_best_binary_parse(current_best, candidate)
    if not candidate then
        return current_best
    end
    if not current_best then
        return candidate
    end
    if candidate.resolved_rigid_joint_count ~= current_best.resolved_rigid_joint_count then
        return candidate.resolved_rigid_joint_count > current_best.resolved_rigid_joint_count and candidate
            or current_best
    end
    if candidate.resolved_joint_count ~= current_best.resolved_joint_count then
        return candidate.resolved_joint_count > current_best.resolved_joint_count and candidate or current_best
    end
    if candidate.resolved_mover_count ~= current_best.resolved_mover_count then
        return candidate.resolved_mover_count > current_best.resolved_mover_count and candidate or current_best
    end
    if candidate.resolved_physics_instance_count ~= current_best.resolved_physics_instance_count then
        return candidate.resolved_physics_instance_count > current_best.resolved_physics_instance_count and candidate
            or current_best
    end
    if candidate.unresolved_rigid_joint_count ~= current_best.unresolved_rigid_joint_count then
        return candidate.unresolved_rigid_joint_count < current_best.unresolved_rigid_joint_count and candidate
            or current_best
    end
    if candidate.unresolved_joint_count ~= current_best.unresolved_joint_count then
        return candidate.unresolved_joint_count < current_best.unresolved_joint_count and candidate or current_best
    end
    if candidate.unresolved_mover_count ~= current_best.unresolved_mover_count then
        return candidate.unresolved_mover_count < current_best.unresolved_mover_count and candidate or current_best
    end
    if candidate.rigid_joint_count ~= current_best.rigid_joint_count then
        return candidate.rigid_joint_count > current_best.rigid_joint_count and candidate or current_best
    end
    if candidate.surface_controller_field_count ~= current_best.surface_controller_field_count then
        return candidate.surface_controller_field_count > current_best.surface_controller_field_count and candidate
            or current_best
    end
    if candidate.configured_mover_field_count ~= current_best.configured_mover_field_count then
        return candidate.configured_mover_field_count > current_best.configured_mover_field_count and candidate
            or current_best
    end
    if #(candidate.physics_instances or {}) ~= #(current_best.physics_instances or {}) then
        return #(candidate.physics_instances or {}) > #(current_best.physics_instances or {}) and candidate or current_best
    end
    if #(candidate.parts or {}) ~= #(current_best.parts or {}) then
        return #(candidate.parts or {}) > #(current_best.parts or {}) and candidate or current_best
    end
    if candidate.parse_strategy == "rbxl_dom" and current_best.parse_strategy ~= "rbxl_dom" then
        return candidate
    end
    return current_best
end

-- per-phase timing + alloc deltas, measurement only
local function parse_phase_clock()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

function parse_binary_place(data, options)
    options = options or {}
    local best_parse = nil
    local primary_err = nil
    local dom_roots = nil
    local diagnostics = {
        candidates = {},
    }
    local phase_times = {}
    diagnostics.phase_times = phase_times
    local phase_started = parse_phase_clock()
    local phase_alloc = collectgarbage("count")
    local function note_phase(name)
        local now = parse_phase_clock()
        local alloc = collectgarbage("count")
        phase_times[name] = (phase_times[name] or 0) + (now - phase_started)
        phase_times[name .. "_alloc_kb"] = (phase_times[name .. "_alloc_kb"] or 0)
            + math.max(0, alloc - phase_alloc)
        phase_started = now
        phase_alloc = alloc
    end
    local ok, parsed = pcall(require("engine/graphics/rbx/binary").read, data, {
        formatKind = ".rbxl",
        source_name = "<binary-map>",
        progress_hook = parse_progress_hook,
    })
    note_phase("dom_read")
    -- DOM reader swallows per-property failures silently, so count them or fastpath skips fallback
    local dom_data_loss_count = 0
    if ok and parsed and type(parsed.warnings) == "table" then
        for i = 1, #parsed.warnings do
            local code = parsed.warnings[i] and parsed.warnings[i].code
            if code == "PropertyParseFailed" or code == "UnknownPropertyType"
                or code == "UnknownClassPropChunk" or code == "DanglingParentLink"
                or code == "InvalidReferent" then
                dom_data_loss_count = dom_data_loss_count + 1
            end
        end
    end
    if ok and parsed and parsed.preserved and type(parsed.preserved.unknownPropChunks) == "table" then
        dom_data_loss_count = dom_data_loss_count + #parsed.preserved.unknownPropChunks
    end
    diagnostics.dom_data_loss_count = dom_data_loss_count
    if ok and parsed then
        local roots = convert_dom_roots_to_runtime_nodes(parsed.roots)
        dom_roots = roots
        note_phase("dom_convert")
        local parts, constraints, physics_instances, scanned_items, skipped_items, local_lights,
        local_light_invalid_count = collect_supported_parts_from_tree(
            roots, options)
        note_phase("dom_collect")
        local candidate = make_binary_parse_candidate("rbxl_dom", roots, parts, constraints, physics_instances,
            scanned_items, skipped_items, local_lights, local_light_invalid_count)
        diagnostics.candidates.rbxl_dom = make_binary_parse_diagnostic(candidate)
        best_parse = choose_best_binary_parse(best_parse, candidate)
    else
        primary_err = parsed
    end

    -- legacy fallback re-decodes the whole file (0.85s+127MB on a large place) for the same scores
    local dom_candidate_complete = best_parse ~= nil
        and type(best_parse.parts) == "table" and #best_parse.parts > 0
        and (best_parse.skipped_items or 0) == 0
        and (best_parse.local_light_invalid_count or 0) == 0
        and dom_data_loss_count == 0
        and not ((best_parse.rigid_joint_count or 0) > 0
            and (best_parse.resolved_rigid_joint_count or 0) == 0)
        and not ((best_parse.unresolved_joint_count or 0) > 0
            and (best_parse.resolved_joint_count or 0) == 0)
        and not (((best_parse.unresolved_mover_count or 0) > 0
                or (best_parse.configured_mover_field_count or 0) > 0)
            and (best_parse.resolved_mover_count or 0) == 0)
    local skip_fallback = dom_candidate_complete
    if skip_fallback then
        diagnostics.fallback_skipped = true
        phase_times.fallback_skipped = 1
    else
        local fallback_roots, fallback_err = decode_rbxl_binary(data)
        note_phase("fallback_decode")
        if fallback_roots then
            local parts, constraints, physics_instances, scanned_items, skipped_items, local_lights,
            local_light_invalid_count = collect_supported_parts_from_tree(
                fallback_roots, options)
            note_phase("fallback_collect")
            local candidate = make_binary_parse_candidate("rbxl_fallback", fallback_roots, parts, constraints,
                physics_instances, scanned_items, skipped_items, local_lights, local_light_invalid_count)
            diagnostics.candidates.rbxl_fallback = make_binary_parse_diagnostic(candidate)
            best_parse = choose_best_binary_parse(best_parse, candidate)
        elseif not best_parse then
            primary_err = primary_err or fallback_err
        end
    end
    -- a candidate with zero parts must not outrank a real decode error: a
    -- zstd-compressed .rbxl (modern Studio export) used to "succeed" here as an
    -- empty world because the legacy fallback returns a hollow tree. Surface the
    -- decoder's error instead (tools/rbxl-dezstd.py converts such files)
    if not best_parse or not best_parse.roots
        or (#(best_parse.parts or {}) == 0 and primary_err ~= nil) then
        diagnostics.selected_parse_strategy = nil
        return nil, nil, nil, nil, nil, nil, nil, nil, nil, diagnostics,
            primary_err or fallback_err or "Failed to parse .rbxl"
    end

    local lighting_settings = parse_lighting_settings_tree(best_parse.roots)
    local sky_settings = parse_sky_settings_tree(best_parse.roots)
    local workspace_settings = parse_workspace_settings_tree(best_parse.roots)
    note_phase("settings_walk")
    phase_times.selected_strategy = best_parse.parse_strategy
    local instance_roots = dom_roots or best_parse.roots
    local material_variant_catalog, material_variant_error =
        RBX._material_variants.extract_from_roots(
            instance_roots, options.material_variant_options)
    best_parse.parts._material_variant_catalog = material_variant_catalog
    best_parse.parts._material_variant_error = material_variant_error
    RBX._collision_group_policy.decorate(best_parse.parts, workspace_settings)
    diagnostics.selected_parse_strategy = best_parse.parse_strategy
    diagnostics.selected = make_binary_parse_diagnostic(best_parse)
    return best_parse.parts, best_parse.constraints, best_parse.physics_instances,
        best_parse.scanned_items, best_parse.skipped_items, lighting_settings, sky_settings, workspace_settings,
        best_parse.parse_strategy, diagnostics, nil, instance_roots, best_parse.local_lights,
        best_parse.local_light_invalid_count
end

function read_named_content_or_string(properties_block, property_name)
    local content = find_named_content_value(properties_block, property_name)
    if content and content ~= "" then
        return content
    end
    local text = find_named_value(properties_block, "string", property_name)
    if text and text ~= "" then
        return text
    end
    return nil
end

function RBX._make_empty_child_assets()
    return {
        mesh_id = nil,
        texture_id = nil,
        mesh_owner = nil,
        special_mesh_type = nil,
        special_mesh_scale = nil,
        special_mesh_offset = nil,
        special_mesh_vertex_color = nil,
        surface_appearance = nil,
        face_textures = {},
        blockmesh_scale = nil,
        blockmesh_offset = nil,
        blockmesh_vertex_color = nil,
        attachments = {},
        local_lights = {},
        -- Legacy mesh fields above are overwritten atomically by every authored
        -- DataModelMesh child, native rendering uses the last such child
    }
end

function parse_child_assets_xml(part_item_body, attachments_only)
    local child_assets = RBX._make_empty_child_assets()

    local cursor = 1
    local child_index = 0
    while true do
        local child_start, child_tag_end, child_class, child_attrs = part_item_body:find(
            "<Item%s+class=\"([^\"]+)\"([^>]*)>",
            cursor
        )
        if not child_start then
            break
        end
        child_index = child_index + 1

        local close_start, close_end = find_matching_item_close(part_item_body, child_tag_end + 1)
        if not close_start then
            break
        end

        if child_class == "Attachment"
            or LOCAL_LIGHT_CLASSES[child_class]
            or (not attachments_only and (
                child_class == "SpecialMesh"
                or child_class == "BlockMesh"
                or child_class == "CylinderMesh"
                or child_class == "SurfaceAppearance"
                or child_class == "Decal"
                or child_class == "Texture"
            )) then
            local child_body = part_item_body:sub(child_tag_end + 1, close_start - 1)
            local properties_block = child_body:match("<Properties>(.-)</Properties>")
            if properties_block then
                if child_class == "SurfaceAppearance" then
                    if child_assets.surface_appearance == nil then
                        local alpha_mode = find_named_value(properties_block, "token", "AlphaMode")
                            or find_named_value(properties_block, "string", "AlphaMode")
                        local source = {
                            Name = find_named_value(properties_block, "string", "Name"),
                            Referent = type(child_attrs) == "string"
                                and child_attrs:match("referent=\"([^\"]+)\"") or nil,
                            ColorMapContent = read_named_content_or_string(properties_block, "ColorMapContent"),
                            ColorMap = read_named_content_or_string(properties_block, "ColorMap"),
                            NormalMapContent = read_named_content_or_string(properties_block, "NormalMapContent"),
                            NormalMap = read_named_content_or_string(properties_block, "NormalMap"),
                            RoughnessMapContent = read_named_content_or_string(properties_block, "RoughnessMapContent"),
                            RoughnessMap = read_named_content_or_string(properties_block, "RoughnessMap"),
                            MetalnessMapContent = read_named_content_or_string(properties_block, "MetalnessMapContent"),
                            MetalnessMap = read_named_content_or_string(properties_block, "MetalnessMap"),
                            AlphaMode = alpha_mode,
                            Color = read_named_color3(properties_block, "Color")
                                or read_named_color3(properties_block, "Color3"),
                            EmissiveMaskContent =
                                read_named_content_or_string(properties_block, "EmissiveMaskContent"),
                            EmissiveStrength = tonumber(
                                find_named_value(properties_block, "float", "EmissiveStrength")
                                or find_named_value(properties_block, "double", "EmissiveStrength")),
                            EmissiveTint = read_named_color3(properties_block, "EmissiveTint"),
                            ResampleMode = find_named_value(properties_block, "token", "ResampleMode")
                                or find_named_value(properties_block, "string", "ResampleMode"),
                            TexturePackContent =
                                read_named_content_or_string(properties_block, "TexturePackContent"),
                            TexturePack = read_named_content_or_string(properties_block, "TexturePack"),
                            TexturePackMetadata =
                                find_named_value(properties_block, "string", "TexturePackMetadata"),
                        }
                        child_assets.surface_appearance =
                            RBX._build_surface_appearance_descriptor(source, child_index)
                    end
                elseif child_class == "SpecialMesh" then
                    local child_mesh_id = read_named_content_or_string(
                        properties_block, "MeshContent")
                        or read_named_content_or_string(properties_block, "MeshId")
                    local child_texture_id = read_named_content_or_string(
                        properties_block, "TextureContent")
                        or read_named_content_or_string(properties_block, "TextureId")
                    -- every later DataModelMesh child replaces the complete visual
                    -- owner selected so far, never retain IDs/scale from an earlier
                    -- child of another class
                    child_assets.mesh_id = child_mesh_id ~= "" and child_mesh_id or nil
                    child_assets.texture_id = child_texture_id ~= "" and child_texture_id or nil
                    child_assets.mesh_owner = "SpecialMesh"
                    child_assets.blockmesh_scale = nil
                    child_assets.blockmesh_offset = nil
                    child_assets.blockmesh_vertex_color = nil
                    local raw_mesh_type = find_named_value(properties_block, "token", "MeshType")
                        or find_named_value(properties_block, "string", "MeshType")
                    child_assets.special_mesh_type = normalize_special_mesh_type(
                        raw_mesh_type, nil) or "Head"
                    local sx, sy, sz = read_vector3(properties_block, "Scale")
                    child_assets.special_mesh_scale = sx ~= nil
                        and { x = sx, y = sy, z = sz } or nil
                    local ox, oy, oz = read_vector3(properties_block, "Offset")
                    child_assets.special_mesh_offset = ox ~= nil
                        and { x = ox, y = oy, z = oz } or nil
                    local vx, vy, vz = read_vector3(properties_block, "VertexColor")
                    child_assets.special_mesh_vertex_color = vx ~= nil
                        and normalize_special_mesh_vertex_color({
                            X = vx,
                            Y = vy,
                            Z = vz,
                        }) or nil
                elseif child_class == "BlockMesh" then
                    child_assets.mesh_owner = "BlockMesh"
                    child_assets.mesh_id = nil
                    child_assets.texture_id = nil
                    child_assets.special_mesh_type = nil
                    child_assets.special_mesh_scale = nil
                    child_assets.special_mesh_offset = nil
                    child_assets.special_mesh_vertex_color = nil
                    local sx, sy, sz = read_vector3(properties_block, "Scale")
                    child_assets.blockmesh_scale = sx ~= nil
                        and { x = sx, y = sy, z = sz } or nil
                    local ox, oy, oz = read_vector3(properties_block, "Offset")
                    child_assets.blockmesh_offset = ox ~= nil
                        and { x = ox, y = oy, z = oz } or nil
                    local vx, vy, vz = read_vector3(
                        properties_block, "VertexColor")
                    child_assets.blockmesh_vertex_color = vx ~= nil
                        and normalize_special_mesh_vertex_color({
                                X = vx, Y = vy, Z = vz,
                            }) or nil
                elseif child_class == "CylinderMesh" then
                    child_assets.mesh_owner = "CylinderMesh"
                    child_assets.mesh_id = nil
                    child_assets.texture_id = nil
                    child_assets.special_mesh_type = "Cylinder"
                    child_assets.blockmesh_scale = nil
                    child_assets.blockmesh_offset = nil
                    child_assets.blockmesh_vertex_color = nil
                    local sx, sy, sz = read_vector3(properties_block, "Scale")
                    child_assets.special_mesh_scale = sx ~= nil
                        and { x = sx, y = sy, z = sz } or nil
                    local ox, oy, oz = read_vector3(properties_block, "Offset")
                    child_assets.special_mesh_offset = ox ~= nil
                        and { x = ox, y = oy, z = oz } or nil
                    local vx, vy, vz = read_vector3(properties_block, "VertexColor")
                    child_assets.special_mesh_vertex_color = vx ~= nil
                        and normalize_special_mesh_vertex_color({
                            X = vx,
                            Y = vy,
                            Z = vz,
                        }) or nil
                elseif child_class == "Decal" or child_class == "Texture" then
                    local face = find_named_value(properties_block, "token", "Face")
                        or find_named_value(properties_block, "string", "Face")
                    local uv_offset_u, uv_offset_v = read_vector2(properties_block, "UVOffset", 0, 0)
                    if uv_offset_u == nil then
                        uv_offset_u, uv_offset_v = read_vector2(properties_block, "uvoffset", 0, 0)
                    end
                    local uv_scale_u, uv_scale_v = read_vector2(properties_block, "UVScale", 1, 1)
                    if uv_scale_u == nil then
                        uv_scale_u, uv_scale_v = read_vector2(properties_block, "uvscale", 1, 1)
                    end
                    child_assets.face_textures[#child_assets.face_textures + 1] =
                        RBX._normalize_face_texture_descriptor({
                            Name = find_named_value(properties_block, "string", "Name"),
                            Referent = type(child_attrs) == "string"
                                and child_attrs:match("referent=\"([^\"]+)\"") or nil,
                            Face = tonumber(face) or face,
                            ColorMapContent = read_named_content_or_string(
                                properties_block, "ColorMapContent"),
                            ColorMap = read_named_content_or_string(
                                properties_block, "ColorMap"),
                            TextureContent = read_named_content_or_string(
                                properties_block, "TextureContent"),
                            Texture = read_named_content_or_string(
                                properties_block, "Texture"),
                            Transparency = read_named_number(properties_block, "Transparency", 0),
                            Color3 = read_named_color3(properties_block, "Color3")
                                or read_named_color3(properties_block, "Color"),
                            ZIndex = read_named_number(properties_block, "ZIndex", 1),
                            Rotation = read_named_number(properties_block, "Rotation",
                                read_named_number(properties_block, "rotation", nil)),
                            uv_offset_u = uv_offset_u,
                            uv_offset_v = uv_offset_v,
                            uv_scale_u = uv_scale_u,
                            uv_scale_v = uv_scale_v,
                            StudsPerTileU = read_named_number(properties_block, "StudsPerTileU",
                                read_named_number(properties_block, "StudsPerTile", nil)),
                            StudsPerTileV = read_named_number(properties_block, "StudsPerTileV",
                                read_named_number(properties_block, "StudsPerTile", nil)),
                            OffsetStudsU = read_named_number(properties_block, "OffsetStudsU", 0),
                            OffsetStudsV = read_named_number(properties_block, "OffsetStudsV", 0),
                        }, child_class, { authored_index = child_index })
                elseif child_class == "Attachment" then
                    local attachment_cframe = read_cframe(properties_block, "CFrame")
                    local ax, ay, az = read_vector3(properties_block, "Position")
                    local referent = type(child_attrs) == "string" and child_attrs:match("referent=\"([^\"]+)\"") or nil
                    local attachment_entry = {
                        referent = referent,
                        local_x = to_number((attachment_cframe and attachment_cframe.x) or ax, 0),
                        local_y = to_number((attachment_cframe and attachment_cframe.y) or ay, 0),
                        local_z = to_number((attachment_cframe and attachment_cframe.z) or az, 0),
                    }
                    copy_attachment_transform_fields(attachment_entry, attachment_cframe)
                    child_assets.attachments[#child_assets.attachments + 1] = attachment_entry

                    local light_cursor = 1
                    while true do
                        local light_start, light_tag_end, light_class, light_attrs = child_body:find(
                            "<Item%s+class=\"([^\"]+)\"([^>]*)>",
                            light_cursor
                        )
                        if not light_start then
                            break
                        end
                        local light_close_start, light_close_end = find_matching_item_close(child_body, light_tag_end + 1)
                        if not light_close_start then
                            break
                        end
                        if LOCAL_LIGHT_CLASSES[light_class] then
                            local light_body = child_body:sub(light_tag_end + 1, light_close_start - 1)
                            local light_properties = light_body:match("<Properties>(.-)</Properties>")
                            local light_referent = type(light_attrs) == "string"
                                and light_attrs:match("referent=\"([^\"]+)\"") or nil
                            local light = RBX._parse_local_light_xml(light_class, light_properties, light_referent)
                            if light then
                                light.parent_kind = "Attachment"
                                light.attachment_referent = referent
                                child_assets.local_lights[#child_assets.local_lights + 1] = light
                            end
                        end
                        light_cursor = light_close_end + 1
                    end
                elseif LOCAL_LIGHT_CLASSES[child_class] then
                    local referent = type(child_attrs) == "string" and child_attrs:match("referent=\"([^\"]+)\"") or nil
                    local light = RBX._parse_local_light_xml(child_class, properties_block, referent)
                    if light then
                        light.parent_kind = "Part"
                        child_assets.local_lights[#child_assets.local_lights + 1] = light
                    end
                end
            end
        end

        cursor = close_end + 1
    end

    return child_assets
end

local function copy_xml_cframe_entry(cframe)
    if type(cframe) ~= "table" then
        return nil
    end
    return {
        x = cframe.x or 0,
        y = cframe.y or 0,
        z = cframe.z or 0,
        r00 = cframe.r00 or 1,
        r01 = cframe.r01 or 0,
        r02 = cframe.r02 or 0,
        r10 = cframe.r10 or 0,
        r11 = cframe.r11 or 1,
        r12 = cframe.r12 or 0,
        r20 = cframe.r20 or 0,
        r21 = cframe.r21 or 0,
        r22 = cframe.r22 or 1,
    }
end

local function copy_xml_vector3_entry(x, y, z)
    if x == nil and y == nil and z == nil then
        return nil
    end
    return {
        x = x or 0,
        y = y or 0,
        z = z or 0,
    }
end

local function build_xml_body_mover_entry(class_name, properties_block, parent_referent)
    if not LEGACY_BODY_MOVER_CLASSES[class_name] or type(properties_block) ~= "string" or not parent_referent then
        return nil
    end
    local entry = {
        kind = "mover",
        class_name = class_name,
        name = find_named_value(properties_block, "string", "Name") or class_name,
        parent_referent = parent_referent,
    }
    if class_name == "BodyPosition" then
        entry.position = copy_xml_vector3_entry(read_vector3(properties_block, "Position"))
        entry.max_force = copy_xml_vector3_entry(read_vector3(properties_block, "MaxForce"))
        entry.p = read_named_number(properties_block, "P", nil)
        entry.d = read_named_number(properties_block, "D", nil)
    elseif class_name == "BodyVelocity" then
        entry.velocity = copy_xml_vector3_entry(read_vector3(properties_block, "Velocity"))
        entry.max_force = copy_xml_vector3_entry(read_vector3(properties_block, "MaxForce"))
        entry.p = read_named_number(properties_block, "P", nil)
    elseif class_name == "BodyForce" then
        entry.force = copy_xml_vector3_entry(read_vector3(properties_block, "Force"))
    elseif class_name == "BodyGyro" then
        entry.cframe = copy_xml_cframe_entry(read_cframe(properties_block, "CFrame"))
        entry.max_torque = copy_xml_vector3_entry(read_vector3(properties_block, "MaxTorque"))
        entry.p = read_named_number(properties_block, "P", nil)
        entry.d = read_named_number(properties_block, "D", nil)
    elseif class_name == "BodyAngularVelocity" then
        entry.angular_velocity = copy_xml_vector3_entry(read_vector3(properties_block, "AngularVelocity"))
            or copy_xml_vector3_entry(read_vector3(properties_block, "Velocity"))
        entry.max_torque = copy_xml_vector3_entry(read_vector3(properties_block, "MaxTorque"))
        entry.p = read_named_number(properties_block, "P", nil)
    elseif class_name == "BodyThrust" then
        entry.force = copy_xml_vector3_entry(read_vector3(properties_block, "Force"))
        entry.location = copy_xml_vector3_entry(read_vector3(properties_block, "Location"))
    end
    return entry
end

local function build_xml_joint_entry(class_name, properties_block)
    if type(properties_block) ~= "string" then
        return nil
    end
    if class_name == "NoCollisionConstraint" then
        local p0 = normalize_referent_value(RBX._read_named_ref(properties_block, "Part0"))
        local p1 = normalize_referent_value(RBX._read_named_ref(properties_block, "Part1"))
        if not p0 or not p1 then
            return nil
        end
        return {
            kind = "no_collision",
            class_name = class_name,
            name = find_named_value(properties_block, "string", "Name") or class_name,
            enabled = read_named_bool(properties_block, "Enabled", true),
            referent = normalize_referent_value(RBX._read_named_ref(properties_block, "referent")),
            part0_referent = p0,
            part1_referent = p1,
        }
    end
    if not LEGACY_JOINT_INSTANCE_CLASSES[class_name] then
        return nil
    end
    local part0_referent = normalize_referent_value(RBX._read_named_ref(properties_block, "Part0"))
    local part1_referent = normalize_referent_value(RBX._read_named_ref(properties_block, "Part1"))
    if not part0_referent or not part1_referent then
        return nil
    end
    return {
        kind = "joint",
        class_name = class_name,
        name = find_named_value(properties_block, "string", "Name") or class_name,
        enabled = read_named_bool(properties_block, "Enabled", true),
        part0_referent = part0_referent,
        part1_referent = part1_referent,
        c0 = copy_xml_cframe_entry(read_cframe(properties_block, "C0")),
        c1 = copy_xml_cframe_entry(read_cframe(properties_block, "C1")),
        base_angle = read_named_number(properties_block, "BaseAngle", nil),
        -- RotateV actuator params, nil when absent
        param_a = read_named_number(properties_block, "ParamA", nil),
        param_b = read_named_number(properties_block, "ParamB", nil),
        surface_input = read_named_number(properties_block, "SurfaceInput", nil),
    }
end

local function parse_child_legacy_physics_xml(part_item_body, parent_referent, out)
    if type(part_item_body) ~= "string" or not parent_referent then
        return
    end
    local cursor = 1
    while true do
        local child_start, child_tag_end, child_class = part_item_body:find(
            "<Item%s+class=\"([^\"]+)\"([^>]*)>",
            cursor
        )
        if not child_start then
            break
        end
        local close_start, close_end = find_matching_item_close(part_item_body, child_tag_end + 1)
        if not close_start then
            break
        end
        if LEGACY_BODY_MOVER_CLASSES[child_class] then
            local child_body = part_item_body:sub(child_tag_end + 1, close_start - 1)
            local properties_block = child_body:match("<Properties>(.-)</Properties>")
            local entry = build_xml_body_mover_entry(child_class, properties_block, parent_referent)
            if entry then
                out[#out + 1] = entry
            end
        end
        cursor = close_end + 1
    end
end

function read_xml_part_shape(properties_block)
    local shape = find_named_value(properties_block, "token", "Shape")
        or find_named_value(properties_block, "token", "shape")
        or find_named_value(properties_block, "string", "Shape")
        or find_named_value(properties_block, "string", "shape")
    if shape == nil then
        return nil
    end
    local numeric = tonumber(shape)
    if numeric ~= nil then
        return numeric
    end
    return shape
end

function read_xml_shared_string_ref(properties_block, property_name)
    if type(properties_block) ~= "string" or type(property_name) ~= "string" then
        return nil
    end

    local escaped_name = escape_pattern(property_name)
    local pattern = "<SharedString%s+name=\"" .. escaped_name .. "\"%s*>(.-)</SharedString>"
    local value = properties_block:match(pattern)
    if not value then
        return nil
    end
    value = trim(value)
    if value == "" then
        return nil
    end
    return value
end

function parse_xml_shared_strings(xml)
    local shared_strings = {}
    local block = xml:match("<SharedStrings>(.-)</SharedStrings>")
    if not block then
        return shared_strings
    end

    for md5_hash, encoded in block:gmatch("<SharedString%s+md5=\"([^\"]+)\"%s*>(.-)</SharedString>") do
        local decoded = require("engine/services/oss/base64").decode(trim(encoded or ""))
        if type(decoded) == "string" then
            shared_strings[trim(md5_hash)] = decoded
        end
    end

    return shared_strings
end

function collect_csg_embedded_mesh_candidates_from_xml(properties_block, shared_strings)
    if type(properties_block) ~= "string" then
        return nil
    end

    local candidates = {}
    local seen = {}
    for i = 1, #CSG_EMBEDDED_MESH_FIELDS do
        local property_name = CSG_EMBEDDED_MESH_FIELDS[i]
        local shared_ref = read_xml_shared_string_ref(properties_block, property_name)
        if shared_ref and type(shared_strings) == "table" then
            append_unique_string_candidate(candidates, seen, shared_strings[shared_ref])
        end
        append_unique_string_candidate(candidates, seen, read_named_content_or_string(properties_block, property_name))
    end

    return #candidates > 0 and candidates or nil
end

function parse_supported_parts(xml, options)
    options = options or {}
    local parts = {}
    local constraints = {}
    local physics_instances = {}
    local local_lights = {}
    local attachments_by_ref = {}
    local pending_constraints = {}
    local scanned_items = 0
    local skipped_items = 0
    local local_light_invalid_count = 0
    local cursor = 1
    local xml_shared_strings = parse_xml_shared_strings(xml)

    while true do
        local item_start, item_tag_end, class_name, item_attrs = xml:find("<Item%s+class=\"([^\"]+)\"([^>]*)>", cursor)
        if not item_start then
            break
        end

        local close_start, close_end = find_matching_item_close(xml, item_tag_end + 1)
        if close_start and close_end then
            local item_body = xml:sub(item_tag_end + 1, close_start - 1)
            local properties_block = item_body:match("<Properties>(.-)</Properties>")

            if SUPPORTED_PART_CLASSES[class_name] then
                scanned_items = scanned_items + 1
                if properties_block then
                    local size_block = find_named_block(properties_block, "Vector3", "size")
                        or find_named_block(properties_block, "Vector3", "Size")
                    if size_block then
                        local owner = {referent = item_attrs:match('referent="([^"]+)"')}
                        for _, axis in ipairs({"X", "Y", "Z"}) do
                            RBX._size_validation.number(read_tag_number(size_block, axis, nil), owner, axis)
                        end
                    end
                    local cframe = read_cframe(properties_block, "CFrame")
                    local sx, sy, sz = read_vector3(properties_block, "size")
                    if not sx then
                        sx, sy, sz = read_vector3(properties_block, "Size")
                    end
                    local part_name = find_named_value(properties_block, "string", "Name") or class_name
                    local transparency = read_numeric_token(find_named_value(properties_block, "float", "Transparency"), 0)
                    local reflectance = read_named_number(properties_block, "Reflectance", 0)
                    local anchored = read_named_bool(properties_block, "Anchored", true)
                    local referent = type(item_attrs) == "string" and item_attrs:match("referent=\"([^\"]+)\"") or nil
                    local velocity, velocity_source = read_xml_part_linear_velocity(properties_block)
                    local rot_velocity, rot_velocity_source = read_xml_part_angular_velocity(properties_block)
                    local material = read_named_number(properties_block, "Material", 0)
                    local shape = normalize_part_shape(read_xml_part_shape(properties_block), class_name)
                    local child_assets = nil

                    if cframe and sx and sy and sz then
                        local parent_transform = {
                            referent = referent,
                            x = cframe.x,
                            y = cframe.y,
                            z = cframe.z,
                            r00 = cframe.r00,
                            r01 = cframe.r01,
                            r02 = cframe.r02,
                            r10 = cframe.r10,
                            r11 = cframe.r11,
                            r12 = cframe.r12,
                            r20 = cframe.r20,
                            r21 = cframe.r21,
                            r22 = cframe.r22,
                            sx = sx,
                            sy = sy,
                            sz = sz,
                        }
                        if transparency < 1 or RBX._parse_invisible_parts == true then
                            -- match the DOM/tree parser: when invisible parts
                            -- are retained, their Decal/Texture children are
                            -- retained too.  Parsing only attachments/lights in
                            -- this branch produced a regex-fallback-only loss of
                            -- floating signage and made a later facade write
                            -- unable to activate an initially empty layer
                            child_assets = (type(item_body) == "string" and item_body:find("<Item", 1, true) ~= nil)
                                and parse_child_assets_xml(item_body, false)
                                or RBX._make_empty_child_assets()
                        elseif type(item_body) == "string" and (
                                item_body:find('class="Attachment"', 1, true) ~= nil
                                or item_body:find('class="PointLight"', 1, true) ~= nil
                                or item_body:find('class="SpotLight"', 1, true) ~= nil
                                or item_body:find('class="SurfaceLight"', 1, true) ~= nil
                            ) then
                            child_assets = parse_child_assets_xml(item_body, true)
                        end
                        local attachment_parent_index = #parts + 1
                        for attachment_index = 1, #((child_assets and child_assets.attachments) or {}) do
                            local attachment = child_assets.attachments[attachment_index]
                            if attachment and attachment.referent then
                                attachment.parent_part_index = transparency < 1 and attachment_parent_index or nil
                                attachment.parent_referent = referent
                                attachment.parent_transform = parent_transform
                                attachment.world_x, attachment.world_y, attachment.world_z =
                                    RBX._transform_attachment_world_point(
                                        cframe,
                                        attachment.local_x,
                                        attachment.local_y,
                                        attachment.local_z
                                    )
                                attachments_by_ref[attachment.referent] = attachment
                            end
                        end
                        for light_index = 1, #((child_assets and child_assets.local_lights) or {}) do
                            local light = child_assets.local_lights[light_index]
                            if light then
                                if light.parent_kind == "Attachment" then
                                    local attachment = light.attachment_referent
                                        and attachments_by_ref[light.attachment_referent] or nil
                                    if attachment then
                                        light.parent_part_index = attachment.parent_part_index
                                        light.parent_referent = attachment.parent_referent
                                        light.attachment = attachment
                                        light.parent_transform = parent_transform
                                        light.parent_class = class_name
                                        light.parent_name = part_name
                                        light.parent_path = part_name
                                        light.parent_transparency = transparency
                                        light.parent_transparent_at_load = transparency >= 1
                                        local_lights[#local_lights + 1] = light
                                    else
                                        light.invalid_reason = "missing_attachment"
                                        local_light_invalid_count = local_light_invalid_count + 1
                                    end
                                else
                                    light.parent_kind = "Part"
                                    light.parent_part_index = transparency < 1 and attachment_parent_index or nil
                                    light.parent_referent = referent
                                    light.parent_transform = parent_transform
                                    light.parent_class = class_name
                                    light.parent_name = part_name
                                    light.parent_path = part_name
                                    light.parent_transparency = transparency
                                    light.parent_transparent_at_load = transparency >= 1
                                    local_lights[#local_lights + 1] = light
                                end
                            end
                        end
                        parse_child_legacy_physics_xml(
                            item_body,
                            referent,
                            physics_instances
                        )
                    end

                    -- same invisible-part rule as the tree parser above: a fully
                    -- transparent part must still exist so it keeps its collider
                    if cframe and sx and sy and sz
                        and (transparency < 1 or RBX._parse_invisible_parts == true) then
                        local r, g, b = read_part_color(properties_block)
                        local alpha = math.floor(clamp((1 - transparency) * 255, 0, 255) + 0.5)
                        child_assets = child_assets or RBX._make_empty_child_assets()
                        local part_mesh_id = child_assets.mesh_id
                        local part_texture_id = child_assets.texture_id
                        local mesh_owner = child_assets.mesh_owner
                        local mesh_size = nil
                        local mesh_vertex_color = nil
                        local embedded_mesh_data = nil
                        local embedded_mesh_candidates = nil
                        local use_part_color = nil
                        local double_sided = nil
                        local smoothing_angle = nil
                        local render_fidelity = nil
                        local collision_fidelity = nil
                        local physics_data = nil
                        local physical_config_data = nil
                        local triangle_count = nil
                        local material_variant = find_named_value(properties_block, "string", "MaterialVariant")
                        if class_name == "MeshPart" or is_csg_part_class(class_name) then
                            part_mesh_id = part_mesh_id
                                or read_named_content_or_string(properties_block, "MeshId")
                                or read_named_content_or_string(properties_block, "MeshID")
                                or read_named_content_or_string(properties_block, "AssetId")
                            part_texture_id = part_texture_id
                                or read_named_content_or_string(properties_block, "TextureContent")
                                or read_named_content_or_string(properties_block, "TextureID")
                                or read_named_content_or_string(properties_block, "TextureId")
                            mesh_owner = mesh_owner or class_name
                            double_sided = read_named_bool(properties_block, "DoubleSided", false)
                            render_fidelity = find_named_value(properties_block, "token", "RenderFidelity")
                                or find_named_value(properties_block, "string", "RenderFidelity")
                            collision_fidelity = find_named_value(properties_block, "token", "CollisionFidelity")
                                or find_named_value(properties_block, "string", "CollisionFidelity")
                            local physics_ref = read_xml_shared_string_ref(properties_block, "PhysicsData")
                            physics_data = physics_ref and xml_shared_strings[physics_ref] or nil
                            local physics_encoded = find_named_value(properties_block, "BinaryString", "PhysicsData")
                            if physics_encoded then
                                physics_data = require("engine/services/oss/base64").decode(trim(physics_encoded))
                            end
                            physics_data = physics_data or read_named_content_or_string(properties_block, "PhysicsData")
                            local config_ref = read_xml_shared_string_ref(properties_block, "PhysicalConfigData")
                            physical_config_data = config_ref and xml_shared_strings[config_ref] or nil
                            triangle_count = read_named_number(properties_block, "TriangleCount", nil)
                            local mesh_size_x, mesh_size_y, mesh_size_z = read_vector3(properties_block, "MeshSize")
                            if mesh_size_x == nil then
                                mesh_size_x, mesh_size_y, mesh_size_z = read_vector3(properties_block, "ModelMeshSize")
                            end
                            if mesh_size_x == nil then
                                mesh_size_x, mesh_size_y, mesh_size_z = read_vector3(properties_block, "InitialSize")
                            end
                            if mesh_size_x ~= nil then
                                mesh_size = normalize_mesh_size_value({
                                    X = mesh_size_x,
                                    Y = mesh_size_y,
                                    Z = mesh_size_z,
                                })
                            end
                            local vertex_color_x, vertex_color_y, vertex_color_z = read_vector3(properties_block,
                                "VertexColor")
                            if vertex_color_x ~= nil then
                                mesh_vertex_color = normalize_special_mesh_vertex_color({
                                    X = vertex_color_x,
                                    Y = vertex_color_y,
                                    Z = vertex_color_z,
                                })
                            end
                            if is_csg_part_class(class_name) then
                                use_part_color = read_named_bool(properties_block, "UsePartColor", true)
                                smoothing_angle = read_named_number(properties_block, "SmoothingAngle", nil)
                                embedded_mesh_candidates = collect_csg_embedded_mesh_candidates_from_xml(
                                    properties_block,
                                    xml_shared_strings
                                )
                                embedded_mesh_data = embedded_mesh_candidates and embedded_mesh_candidates[1] or nil
                            end
                        end
                        if mesh_owner == "BlockMesh" then
                            mesh_vertex_color = child_assets.blockmesh_vertex_color
                            if mesh_vertex_color and mesh_vertex_color.r == 1
                                and mesh_vertex_color.g == 1
                                and mesh_vertex_color.b == 1 then
                                mesh_vertex_color = nil
                            end
                        end

                        local part_index = #parts + 1
                        parts[part_index] = {
                            class_name = class_name,
                            name = part_name,
                            shape = shape,
                            x = cframe.x,
                            y = cframe.y,
                            z = cframe.z,
                            r00 = cframe.r00,
                            r01 = cframe.r01,
                            r02 = cframe.r02,
                            r10 = cframe.r10,
                            r11 = cframe.r11,
                            r12 = cframe.r12,
                            r20 = cframe.r20,
                            r21 = cframe.r21,
                            r22 = cframe.r22,
                            sx = sx,
                            sy = sy,
                            sz = sz,
                            referent = referent,
                            anchored = anchored,
                            can_collide = read_named_bool(properties_block, "CanCollide", true),
                            can_touch = read_named_bool(properties_block, "CanTouch", true),
                            can_query = read_named_bool(properties_block, "CanQuery", true),
                            cast_shadow = read_named_bool(properties_block, "CastShadow", true),
                            collision_group = normalize_collision_group_name(read_named_number(properties_block,
                                "CollisionGroupId", 0)),
                            collision_group_source_name = (function()
                                local value = find_named_value(properties_block, "string", "CollisionGroup")
                                return value ~= nil and require("engine/graphics/rbx/util").xml_unescape(value) or nil
                            end)(),
                            collision_group_legacy_id = read_named_number(properties_block, "CollisionGroupId", 0),
                            massless = read_named_bool(properties_block, "Massless", false),
                            root_priority = read_named_number(properties_block, "RootPriority", 0),
                            custom_physical_properties = parse_xml_custom_physical_properties(properties_block),
                            linear_velocity = velocity,
                            linear_velocity_source = velocity_source,
                            angular_velocity = rot_velocity,
                            angular_velocity_source = rot_velocity_source,
                            material = material,
                            reflectance = clamp(reflectance, 0, 1),
                            color_r = r,
                            color_g = g,
                            color_b = b,
                            color_a = alpha,
                            transparency = clamp(transparency, 0, 1),
                            mesh_id = normalize_asset_reference(part_mesh_id),
                            texture_id = normalize_asset_reference(part_texture_id),
                            mesh_owner = mesh_owner,
                            special_mesh_type = child_assets.special_mesh_type,
                            special_mesh_scale = child_assets.special_mesh_scale,
                            special_mesh_offset = child_assets.special_mesh_offset,
                            special_mesh_vertex_color = child_assets.special_mesh_vertex_color,
                            mesh_vertex_color = mesh_vertex_color,
                            use_part_color = use_part_color,
                            double_sided = double_sided == true,
                            smoothing_angle = smoothing_angle,
                            render_fidelity = render_fidelity,
                            collision_fidelity = collision_fidelity,
                            physics_data = physics_data,
                            physical_config_data = type(physical_config_data) == "string"
                                and physical_config_data ~= "" and physical_config_data or nil,
                            triangle_count = triangle_count,
                            material_variant = material_variant,
                            surface_appearance = part_supports_surface_appearance(
                                class_name, mesh_owner) and child_assets.surface_appearance or nil,
                            top_surface = read_xml_surface_type(properties_block, "TopSurface"),
                            bottom_surface = read_xml_surface_type(properties_block, "BottomSurface"),
                            left_surface = read_xml_surface_type(properties_block, "LeftSurface"),
                            right_surface = read_xml_surface_type(properties_block, "RightSurface"),
                            front_surface = read_xml_surface_type(properties_block, "FrontSurface"),
                            back_surface = read_xml_surface_type(properties_block, "BackSurface"),
                            top_surface_input = read_xml_surface_number(properties_block, "TopSurfaceInput", 0),
                            bottom_surface_input = read_xml_surface_number(properties_block, "BottomSurfaceInput", 0),
                            left_surface_input = read_xml_surface_number(properties_block, "LeftSurfaceInput", 0),
                            right_surface_input = read_xml_surface_number(properties_block, "RightSurfaceInput", 0),
                            front_surface_input = read_xml_surface_number(properties_block, "FrontSurfaceInput", 0),
                            back_surface_input = read_xml_surface_number(properties_block, "BackSurfaceInput", 0),
                            top_param_a = read_xml_surface_number(properties_block, "TopParamA", nil),
                            top_param_b = read_xml_surface_number(properties_block, "TopParamB", nil),
                            bottom_param_a = read_xml_surface_number(properties_block, "BottomParamA", nil),
                            bottom_param_b = read_xml_surface_number(properties_block, "BottomParamB", nil),
                            left_param_a = read_xml_surface_number(properties_block, "LeftParamA", nil),
                            left_param_b = read_xml_surface_number(properties_block, "LeftParamB", nil),
                            right_param_a = read_xml_surface_number(properties_block, "RightParamA", nil),
                            right_param_b = read_xml_surface_number(properties_block, "RightParamB", nil),
                            front_param_a = read_xml_surface_number(properties_block, "FrontParamA", nil),
                            front_param_b = read_xml_surface_number(properties_block, "FrontParamB", nil),
                            back_param_a = read_xml_surface_number(properties_block, "BackParamA", nil),
                            back_param_b = read_xml_surface_number(properties_block, "BackParamB", nil),
                            face_textures = child_assets.face_textures,
                            blockmesh_scale = child_assets.blockmesh_scale,
                            blockmesh_offset = child_assets.blockmesh_offset,
                            mesh_size = mesh_size,
                            embedded_mesh_data = embedded_mesh_data,
                            embedded_mesh_candidates = embedded_mesh_candidates,
                        }
                    else
                        skipped_items = skipped_items + 1
                    end
                else
                    skipped_items = skipped_items + 1
                end
            elseif class_name == "RopeConstraint" or class_name == "RodConstraint" or class_name == "Beam" then
                if properties_block then
                    local constraint_r, constraint_g, constraint_b =
                        RBX._parse_constraint_color_properties_block(properties_block)
                    pending_constraints[#pending_constraints + 1] = {
                        class_name = class_name,
                        name = find_named_value(properties_block, "string", "Name") or class_name,
                        attachment0 = RBX._read_named_ref(properties_block, "Attachment0"),
                        attachment1 = RBX._read_named_ref(properties_block, "Attachment1"),
                        visible = read_named_bool(properties_block, "Visible", true),
                        enabled = read_named_bool(properties_block, "Enabled", true),
                        thickness = read_named_number(properties_block, "Thickness", nil),
                        width0 = read_named_number(properties_block, "Width0", nil),
                        width1 = read_named_number(properties_block, "Width1", nil),
                        transparency = RBX._parse_constraint_transparency_properties_block(properties_block),
                        color_r = constraint_r,
                        color_g = constraint_g,
                        color_b = constraint_b,
                    }
                end
            elseif LEGACY_JOINT_INSTANCE_CLASSES[class_name] and properties_block then
                local entry = build_xml_joint_entry(class_name, properties_block)
                if entry then
                    physics_instances[#physics_instances + 1] = entry
                end
            end
        end

        cursor = item_tag_end + 1
    end

    for index = 1, #pending_constraints do
        local constraint = pending_constraints[index]
        local attachment0 = attachments_by_ref[constraint.attachment0]
        local attachment1 = attachments_by_ref[constraint.attachment1]
        if constraint.visible and constraint.enabled and attachment0 and attachment1 then
            local thickness = tonumber(constraint.thickness)
            if thickness == nil or thickness <= 0 then
                thickness = math.max(constraint.width0 or 0, constraint.width1 or 0,
                    constraint.class_name == "Beam" and 0.15 or 0.2)
            end
            constraints[#constraints + 1] = {
                class_name = constraint.class_name,
                name = constraint.name,
                attachment0 = constraint.attachment0,
                attachment1 = constraint.attachment1,
                attachment0_entry = attachment0,
                attachment1_entry = attachment1,
                thickness = thickness,
                width0 = constraint.width0,
                width1 = constraint.width1,
                transparency = constraint.transparency,
                color_r = constraint.color_r,
                color_g = constraint.color_g,
                color_b = constraint.color_b,
            }
        end
    end

    return parts, constraints, physics_instances, scanned_items, skipped_items, local_lights, local_light_invalid_count
end

function RBX._extract_render_scope_xml(xml, workspace_subtree_skip_policy)
    if type(xml) ~= "string" or xml == "" then
        return xml
    end

    local workspace_segments = {}
    local world_model_segments = {}
    local cursor = 1

    while true do
        local item_start, item_tag_end, class_name = xml:find("<Item%s+class=\"([^\"]+)\"([^>]*)>", cursor)
        if not item_start then
            break
        end

        local close_start, close_end = find_matching_item_close(xml, item_tag_end + 1)
        if not close_start or not close_end then
            break
        end

        if class_name == "Workspace" then
            workspace_segments[#workspace_segments + 1] =
                RBX._prune_workspace_render_scope_segment_xml(
                    xml:sub(item_start, close_end),
                    workspace_subtree_skip_policy)
        elseif class_name == "WorldModel" then
            world_model_segments[#world_model_segments + 1] = xml:sub(item_start, close_end)
        end

        cursor = item_tag_end + 1
    end

    if #workspace_segments > 0 then
        return table.concat(workspace_segments, "\n")
    end
    if #world_model_segments > 0 then
        return table.concat(world_model_segments, "\n")
    end
    return xml
end

function RBX._prune_workspace_render_scope_segment_xml(
    segment, workspace_subtree_skip_policy)
    if type(segment) ~= "string" or segment == "" then
        return segment
    end

    local item_start, item_tag_end = segment:find("<Item%s+class=\"Workspace\"([^>]*)>")
    if item_start ~= 1 or not item_tag_end then
        return segment
    end

    local close_start, close_end = find_matching_item_close(segment, item_tag_end + 1)
    if not close_start or not close_end then
        return segment
    end

    local body = segment:sub(item_tag_end + 1, close_start - 1)
    local rebuilt = {}
    local cursor = 1

    while true do
        local child_start, child_tag_end, child_class =
            body:find("<Item%s+class=\"([^\"]+)\"([^>]*)>", cursor)
        if not child_start then
            rebuilt[#rebuilt + 1] = body:sub(cursor)
            break
        end

        local child_close_start, child_close_end = find_matching_item_close(body, child_tag_end + 1)
        if not child_close_start or not child_close_end then
            rebuilt[#rebuilt + 1] = body:sub(cursor)
            break
        end

        rebuilt[#rebuilt + 1] = body:sub(cursor, child_start - 1)

        local child_segment = body:sub(child_start, child_close_end)
        local properties_block = child_segment:match("<Properties>(.-)</Properties>")
        local child_name = properties_block and (find_named_value(properties_block, "string", "Name") or "") or ""
        local child_supported_descendants = nil
        if RBX._workspace_subtree_skip_policy_matches(
            child_name, child_class,
            workspace_subtree_skip_policy) then
            child_supported_descendants = 0
            for supported_class in pairs(SUPPORTED_PART_CLASSES) do
                local _, match_count = child_segment:gsub("<Item%s+class=\"" .. supported_class .. "\"", "")
                child_supported_descendants = child_supported_descendants + match_count
            end
        end
        local skip_child = RBX._should_skip_workspace_subtree_name(
            child_name, child_class, child_supported_descendants,
            workspace_subtree_skip_policy)
        if not skip_child then
            rebuilt[#rebuilt + 1] = child_segment
        end

        cursor = child_close_end + 1
    end

    return segment:sub(1, item_tag_end) .. table.concat(rebuilt) .. segment:sub(close_start, close_end)
end

function RBX._parse_xml_place(data, source_name, options)
    options = options or {}
    -- so gui local-image paths can try the map's own folder mid-load, before renderer.map_path is set
    if type(source_name) == "string" and source_name:find("[/\\]") then
        RBX._last_parsed_map_path = source_name
    end
    local render_scope_xml = RBX._extract_render_scope_xml(
        data, options.skip_workspace_subtrees)
    local roots = nil
    local parsed_file = nil
    local ok, loaded_or_err = pcall(require("engine/graphics/rbx/xml").read, data, {
        source_name = source_name or "<xml-map>",
    })
    if not ok and type(loaded_or_err) == "table"
        and loaded_or_err.kind == "DuplicateXmlCollisionGroupData" then
        -- this structural failure is terminal. Legacy raw fallback must not
        -- turn a duplicate property into a single keyed DOM value
        error(require("engine/graphics/rbx/errors").format(loaded_or_err), 0)
    end
    if ok and loaded_or_err then
        parsed_file = loaded_or_err
        roots = convert_dom_roots_to_runtime_nodes(parsed_file.roots)
    end

    local has_surface_gui = type(render_scope_xml) == "string"
        and (render_scope_xml:find("<Item%s+class=\"SurfaceGui\"", 1) ~= nil
            or render_scope_xml:find("<Item%s+class=\"SurfaceBoard\"", 1) ~= nil)
    local parts, constraints, physics_instances, scanned_items, skipped_items, local_lights, local_light_invalid_count
    if roots then
        parts, constraints, physics_instances, scanned_items, skipped_items, local_lights,
        local_light_invalid_count = collect_supported_parts_from_tree(
            roots, options)
    elseif has_surface_gui then
        local render_ok, render_file = pcall(require("engine/graphics/rbx/xml").read, render_scope_xml, {
            source_name = source_name or "<xml-map>",
        })
        if render_ok and render_file then
            local render_roots = convert_dom_roots_to_runtime_nodes(render_file.roots)
            parts, constraints, physics_instances, scanned_items, skipped_items, local_lights,
            local_light_invalid_count =
                collect_supported_parts_from_tree(render_roots, options)
        end
    end
    if not parts then
        parts, constraints, physics_instances, scanned_items, skipped_items, local_lights, local_light_invalid_count =
            parse_supported_parts(render_scope_xml, options)
    end
    local lighting_settings = parse_lighting_settings(data)
    local sky_settings = parse_sky_settings_xml(data)
    local workspace_settings = roots and parse_workspace_settings_tree(roots) or parse_workspace_settings(data)
    if parts then
        local material_variant_catalog, material_variant_error =
            RBX._material_variants.extract_from_roots(
                roots or {}, options.material_variant_options)
        parts._material_variant_catalog = material_variant_catalog
        parts._material_variant_error = material_variant_error
        RBX._collision_group_policy.decorate(parts, workspace_settings)
    end
    if options.include_instance_roots == false then
        roots = nil
    end
    return parts, constraints, physics_instances, scanned_items, skipped_items, lighting_settings, sky_settings,
        workspace_settings, roots, local_lights, local_light_invalid_count
end
