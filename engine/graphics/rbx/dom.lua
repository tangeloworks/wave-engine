local util = require("engine/graphics/rbx/util")
local logging = require("engine/graphics/rbx/logging")

local dom = {}

local File = {}
File.__index = File

local Instance = {}
Instance.__index = Instance

local function normalize_warning(code, message, context)
    return {
        code = code,
        message = message,
        context = context,
    }
end

function dom.value(type_name, value, extra)
    local out = {
        type = type_name,
        value = value,
    }
    if type(extra) == "table" then
        for key, item in pairs(extra) do
            out[key] = item
        end
    end
    return out
end

local TWO32 = 4294967296

---normalises a 32-bit half to the unsigned range 0..2^32-1
---
---the binary parser reaches make_i64 by two routes that disagreed on the
---representation of the halves. `be_bytes_to_u32` builds them with plain
---arithmetic, so an untransformed value (SecurityCapabilities) arrived with
---hi in 0..2^32-1, the zigzag path (Int64) runs the halves through LuaJIT bit
---ops, which return SIGNED 32-bit results, so the same bit pattern arrived as
---a negative number. Measured on Classic-Crossroads.rbxl: Capabilities came
---back {hi=0, lo=0} while SourceAssetId = -1 came back {hi=-1, lo=-1} instead
---of {hi=4294967295, lo=4294967295}. two encodings of one 64-bit value meant
---no consumer -- and no parity test -- could compare them, and the XML parser
---had no way to know which one to reproduce. Normalising here makes the
---representation canonical for every producer
local function u32(value)
    value = tonumber(value) or 0
    value = value % TWO32
    if value < 0 then
        value = value + TWO32
    end
    return value
end

function dom.make_i64(hi, lo, signed)
    local is_signed = signed ~= false
    return {
        kind = is_signed and "int64" or "uint64",
        hi = u32(hi),
        lo = u32(lo),
        signed = is_signed,
    }
end

---builds a 64-bit value from its decimal text, the form the XML format uses
---@return table|nil  nil when the text is not a well-formed integer
function dom.i64_from_decimal(text, signed)
    if type(text) ~= "string" then
        if type(text) == "number" then
            text = string.format("%.0f", text)
        else
            return nil
        end
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local negative = false
    local first = text:sub(1, 1)
    if first == "-" then
        negative = true
        text = text:sub(2)
    elseif first == "+" then
        text = text:sub(2)
    end
    if text == "" or text:find("%D") then
        return nil
    end

    -- Base-2^32 long multiplication. each step stays under 2^36, well inside the
    -- 2^53 exact-integer range of a double, so no precision is lost
    local hi, lo = 0, 0
    for index = 1, #text do
        local digit = text:byte(index) - 48
        local low = lo * 10 + digit
        local carry = math.floor(low / TWO32)
        lo = low % TWO32
        hi = (hi * 10 + carry) % TWO32
    end

    if negative then
        hi = 4294967295 - hi
        lo = 4294967295 - lo + 1
        if lo >= TWO32 then
            lo = lo - TWO32
            hi = hi + 1
        end
        hi = hi % TWO32
    end
    return dom.make_i64(hi, lo, signed)
end

---format both halves of an Int64 as decimal text for the XML writer
function dom.i64_to_decimal(value)
    if type(value) ~= "table" then
        return tostring(value)
    end
    local hi, lo = u32(value.hi), u32(value.lo)
    local negative = false
    if value.signed ~= false and hi >= 2147483648 then
        negative = true
        hi = 4294967295 - hi
        lo = 4294967295 - lo + 1
        if lo >= TWO32 then
            lo = lo - TWO32
            hi = hi + 1
        end
    end

    local digits = {}
    repeat
        local hi_rem = hi % 10
        hi = (hi - hi_rem) / 10
        local current = hi_rem * TWO32 + lo
        local rem = current % 10
        lo = (current - rem) / 10
        digits[#digits + 1] = string.char(48 + rem)
    until hi == 0 and lo == 0

    local out = string.reverse(table.concat(digits))
    if negative then
        return "-" .. out
    end
    return out
end

function dom.is_value(value)
    return type(value) == "table" and type(value.type) == "string"
end

------------------------------------------------------------------ bitfields

-- Faces / Axes decode identically in both container formats (a byte in binary,
-- the text of a <faces>/<axes> child in XML), so the bit ORDER lives here rather
-- than being spelled out twice and drifting
--
-- the order is Enum.NormalId's own numbering: Right=0, Top=1, Back=2, Left=3,
-- Bottom=4, Front=5. xml.md:354-364 lists the names in the opposite direction
-- ("Right, Top, Back, Left, Bottom, and Front ... in that order") but pins the
-- numbering with a worked example in the same section: Front|Left|Top is 42,
-- and 42 = 0b101010 = bits 1, 3 and 5. Reading the list as most-significant-first
-- would make 42 mean Bottom|Back|Right instead
dom.FACE_BIT_NAMES = { "right", "top", "back", "left", "bottom", "front" }
dom.AXIS_BIT_NAMES = { "x", "y", "z" }

local function bit_flags(bits, names)
    bits = math.floor(tonumber(bits) or 0)
    local out = {}
    for index = 1, #names do
        out[names[index]] = (bits % (2 ^ index)) >= (2 ^ (index - 1))
    end
    return out
end

---@param bits number  0..63
---@return table  { right, top, back, left, bottom, front } booleans
function dom.face_flags(bits)
    return bit_flags(bits, dom.FACE_BIT_NAMES)
end

---@param bits number  0..7
---@return table  { x, y, z } booleans
function dom.axis_flags(bits)
    return bit_flags(bits, dom.AXIS_BIT_NAMES)
end

function dom.unwrap(value)
    if dom.is_value(value) then
        return value.value
    end
    return value
end

function dom.new_file(format_kind, source_name)
    return setmetatable({
        formatKind = format_kind,
        sourceName = source_name,
        sourceMetadata = {},
        metadata = {},
        sharedStrings = {},
        instances = {},
        referentMap = {},
        roots = {},
        unknownChunks = {},
        unknownXmlNodes = {},
        warnings = {},
        importArtifacts = {},
        serializerState = {
            propertyOrder = {},
            classOrder = {},
        },
        preserved = {
            unknownPropChunks = {},
        },
    }, File)
end

function dom.new_instance(class_name, referent)
    local instance = setmetatable({
        className = class_name or "Instance",
        name = class_name or "Instance",
        referent = referent,
        parent = nil,
        children = {},
        properties = {},
        attributes = {},
        isService = false,
        sourceMetadata = {},
        importMetadata = {},
        unknownProperties = {},
        propertyOrder = {},
    }, Instance)
    return instance
end

function File:add_warning(code, message, context)
    self.warnings[#self.warnings + 1] = normalize_warning(code, message, context)
end

function File:add_unknown_chunk(chunk)
    self.unknownChunks[#self.unknownChunks + 1] = chunk
end

function File:add_unknown_xml_node(node)
    self.unknownXmlNodes[#self.unknownXmlNodes + 1] = node
end

function File:add_instance(instance)
    self.instances[#self.instances + 1] = instance
    if instance.referent ~= nil then
        self.referentMap[instance.referent] = instance
    end
    return instance
end

function File:get_instance(referent)
    return self.referentMap[referent]
end

function File:add_root(instance)
    self.roots[#self.roots + 1] = instance
    return instance
end

function File:get_path(instance)
    return dom.instance_path(instance)
end

-- Maximum ancestry depth. Roblox itself refuses to serialise trees deeper than a
-- few hundred levels, anything beyond this in a file is malformed or hostile, and
-- an unbounded walk in instance_path/walk would hang or blow the C stack
dom.MAX_ANCESTRY_DEPTH = 512

---Rejects a parent link that would create a cycle
---the PRNT chunk is (child, parent) pairs taken straight from the file with no
---validation, so a single self-parenting pair -- children[i] == parents[i] -- was
---enough to make dom.instance_path loop forever appending to a table until memory
---ran out, and dom.walk recurse until the C stack blew. Neither had a depth cap
---all eight shipped maps are clean, so this is malformed/hostile input only
---@return boolean ok, string|nil reason
function Instance:can_adopt(child)
    if child == nil then
        return false, "nil child"
    end
    if child == self then
        return false, "an instance cannot be its own parent"
    end
    -- walk our own ancestry: if `child` is already an ancestor of `self`, adopting
    -- it would close a loop
    local cursor = self
    local depth = 0
    while cursor ~= nil do
        if cursor == child then
            return false, "parenting would create an ancestry cycle"
        end
        depth = depth + 1
        if depth > dom.MAX_ANCESTRY_DEPTH then
            return false, "ancestry deeper than " .. dom.MAX_ANCESTRY_DEPTH
        end
        cursor = cursor.parent
    end
    return true
end

function Instance:add_child(child)
    local ok, reason = self:can_adopt(child)
    if not ok then
        error("dom: refusing to add child -- " .. tostring(reason), 2)
    end
    child.parent = self
    self.children[#self.children + 1] = child
    return child
end

function Instance:set_property(name, value)
    self.properties[name] = value
    local order = self.propertyOrder
    -- presence map: avoids an O(props^2) dup scan
    local seen = self.propertySeen
    if not seen then
        seen = {}
        self.propertySeen = seen
    end
    if not seen[name] then
        seen[name] = true
        order[#order + 1] = name
    end
    if name == "Name" then
        local plain = dom.property_to_string(value)
        if plain and plain ~= "" then
            self.name = plain
        end
    end
    return value
end

function Instance:get_property(name)
    return self.properties[name]
end

function Instance:add_warning(code, message, context)
    logging.warn(self, code, message, context)
end

function dom.property_to_string(value)
    if dom.is_value(value) then
        local raw = value.value
        if type(raw) == "string" then
            return raw
        end
        if value.type == "SharedString" and type(raw) == "table" then
            return raw.value
        end
        return nil
    end
    if type(value) == "string" then
        return value
    end
    return nil
end

function dom.instance_path(instance)
    if type(instance) ~= "table" then
        return ""
    end
    local parts = {}
    local cursor = instance
    while cursor do
        parts[#parts + 1] = cursor.name or cursor.className or "Instance"
        cursor = cursor.parent
    end
    local out = {}
    for index = #parts, 1, -1 do
        out[#out + 1] = parts[index]
    end
    return table.concat(out, "/")
end

function dom.walk(roots, visit)
    local function walk_one(instance)
        visit(instance)
        for index = 1, #instance.children do
            walk_one(instance.children[index])
        end
    end

    roots = util.arrayify(roots)
    for index = 1, #roots do
        walk_one(roots[index])
    end
end

function dom.add_attribute(instance, name, value)
    instance.attributes[name] = value
end

function dom.copy_file(file)
    local clone = dom.new_file(file.formatKind, file.sourceName)
    clone.metadata = util.deep_copy(file.metadata)
    clone.sharedStrings = util.deep_copy(file.sharedStrings)
    clone.unknownChunks = util.deep_copy(file.unknownChunks)
    clone.unknownXmlNodes = util.deep_copy(file.unknownXmlNodes)
    clone.warnings = util.deep_copy(file.warnings)
    clone.importArtifacts = util.deep_copy(file.importArtifacts)
    clone.serializerState = util.deep_copy(file.serializerState)
    return clone
end

return dom
