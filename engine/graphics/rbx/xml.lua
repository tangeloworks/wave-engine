-- read and write Roblox XML places and models (.rbxlx and .rbxmx)
-- the layout follows version 4 of the Rojo rbx-dom XML specification
-- both readers produce the same DOM types so downstream code can use value.type
-- keep the original XML tag and spelling when the writer needs them for a round trip
-- legacy empty Content values are strings; modern Content keeps its structured value

local dom = require("engine/graphics/rbx/dom")
local errors = require("engine/graphics/rbx/errors")
local util = require("engine/graphics/rbx/util")

local bitops = util.make_bitops()
local band = bitops.band
local bor = bitops.bor
local lshift = bitops.lshift
local rshift = bitops.rshift

local xml = {}

-- Properties written as <int> that are really a BrickColor. Roblox serialises
-- BrickColor with the element name `int` (xml.md:227), so without this the binary
-- parser yields BrickColor and this one yields Int32 for the same property --
-- measured on Classic-Crossroads as 7 divergent `TeamColor` values, which reach
-- the runtime as a raw palette index instead of a colour
local BRICKCOLOR_PROPERTIES = {
    BrickColor = true,
    brickColor = true,
    TeamColor = true,
    teamColor = true,
    -- BodyColors, these six names exist on no other class
    HeadColor = true,
    LeftArmColor = true,
    LeftLegColor = true,
    RightArmColor = true,
    RightLegColor = true,
    TorsoColor = true,
}

-- Enum.FontStyle. the binary format stores Style as a u8 (binary.md:731) while XML
-- stores the item NAME (xml.md:393) -- explicitly called out in binary.md:734
local FONT_STYLES = {
    Normal = 0,
    Italic = 1,
}

local function is_name_char(byte)
    return (byte >= 48 and byte <= 57)
        or (byte >= 65 and byte <= 90)
        or (byte >= 97 and byte <= 122)
        or byte == 95 or byte == 45 or byte == 46 or byte == 58
end

local function parse_number(text)
    text = util.trim(text)
    if text == "" then
        return 0
    end
    local lower = text:lower()
    if lower == "inf" or lower == "+inf" then
        return math.huge
    end
    if lower == "-inf" then
        return -math.huge
    end
    if lower == "nan" or lower == "-nan" or lower == "+nan" then
        return 0 / 0
    end
    return tonumber(text) or 0
end

local function append_text(out, text)
    if text ~= "" then
        out[#out + 1] = text
    end
end

local function scan_attributes(source, path, line, column)
    local attrs = {}
    local index = 1
    local length = #source

    local function skip_ws()
        while index <= length do
            local byte = source:byte(index)
            if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
                return
            end
            index = index + 1
        end
    end

    while true do
        skip_ws()
        if index > length then
            break
        end

        local start = index
        while index <= length and is_name_char(source:byte(index) or 0) do
            index = index + 1
        end
        local name = source:sub(start, index - 1)
        if name == "" then
            errors.raise("XmlSyntax", "malformed attribute name", {
                path = path,
                line = line,
                column = column,
            }, 2)
        end

        skip_ws()
        if source:sub(index, index) ~= "=" then
            errors.raise("XmlSyntax", "attribute missing '='", {
                path = path,
                line = line,
                column = column,
                attribute = name,
            }, 2)
        end
        index = index + 1
        skip_ws()

        local quote = source:sub(index, index)
        if quote ~= '"' and quote ~= "'" then
            errors.raise("XmlSyntax", "attribute missing quote", {
                path = path,
                line = line,
                column = column,
                attribute = name,
            }, 2)
        end
        index = index + 1
        local value_start = index
        local value_end = source:find(quote, value_start, true)
        if not value_end then
            errors.raise("XmlSyntax", "unterminated attribute value", {
                path = path,
                line = line,
                column = column,
                attribute = name,
            }, 2)
        end
        attrs[name] = util.xml_unescape(source:sub(value_start, value_end - 1))
        index = value_end + 1
    end

    return attrs
end

function xml.tokenize(data, opts)
    opts = opts or {}
    local tokens = {}
    local index = 1
    local length = #data
    local line = 1
    local column = 1

    local function advance(text)
        for i = 1, #text do
            if text:byte(i) == 10 then
                line = line + 1
                column = 1
            else
                column = column + 1
            end
        end
    end

    local function push(token)
        tokens[#tokens + 1] = token
    end

    local function find_tag_end(start_index)
        local quote = nil
        local cursor = start_index
        while cursor <= length do
            local char = data:sub(cursor, cursor)
            if quote then
                if char == quote then
                    quote = nil
                end
            elseif char == '"' or char == "'" then
                quote = char
            elseif char == ">" then
                return cursor
            end
            cursor = cursor + 1
        end
        return nil
    end

    while index <= length do
        local lt = data:find("<", index, true)
        if not lt then
            local text = data:sub(index)
            if text ~= "" then
                push({ type = "text", value = text, line = line, column = column })
                advance(text)
            end
            break
        end

        if lt > index then
            local text = data:sub(index, lt - 1)
            push({ type = "text", value = text, line = line, column = column })
            advance(text)
            index = lt
        end

        local token_line = line
        local token_column = column

        if data:sub(index, index + 3) == "<!--" then
            local close = data:find("-->", index + 4, true)
            if not close then
                errors.raise("XmlSyntax", "unterminated XML comment", {
                    path = opts.source_name,
                    line = token_line,
                    column = token_column,
                }, 2)
            end
            local raw = data:sub(index, close + 2)
            push({
                type = "comment",
                value = data:sub(index + 4, close - 1),
                raw = raw,
                line = token_line,
                column = token_column,
            })
            advance(raw)
            index = close + 3
        elseif data:sub(index, index + 8) == "<![CDATA[" then
            local close = data:find("]]>", index + 9, true)
            if not close then
                errors.raise("XmlSyntax", "unterminated CDATA section", {
                    path = opts.source_name,
                    line = token_line,
                    column = token_column,
                }, 2)
            end
            local raw = data:sub(index, close + 2)
            push({
                type = "cdata",
                value = data:sub(index + 9, close - 1),
                raw = raw,
                line = token_line,
                column = token_column,
            })
            advance(raw)
            index = close + 3
        elseif data:sub(index, index + 1) == "<?" then
            local close = data:find("?>", index + 2, true)
            if not close then
                errors.raise("XmlSyntax", "unterminated XML declaration", {
                    path = opts.source_name,
                    line = token_line,
                    column = token_column,
                }, 2)
            end
            local raw = data:sub(index, close + 1)
            local inner = util.trim(data:sub(index + 2, close - 1))
            local name = inner:match("^([%w:_%-%.]+)") or ""
            local attr_source = inner:sub(#name + 1)
            push({
                type = "declaration",
                name = name,
                attrs = scan_attributes(attr_source, opts.source_name, token_line, token_column),
                raw = raw,
                line = token_line,
                column = token_column,
            })
            advance(raw)
            index = close + 2
        elseif data:sub(index, index + 1) == "</" then
            local close = data:find(">", index + 2, true)
            if not close then
                errors.raise("XmlSyntax", "unterminated end tag", {
                    path = opts.source_name,
                    line = token_line,
                    column = token_column,
                }, 2)
            end
            local raw = data:sub(index, close)
            local name = util.trim(data:sub(index + 2, close - 1))
            push({
                type = "end",
                name = name,
                raw = raw,
                line = token_line,
                column = token_column,
            })
            advance(raw)
            index = close + 1
        elseif data:sub(index, index + 1) == "<!" then
            local close = data:find(">", index + 2, true)
            if not close then
                errors.raise("XmlSyntax", "unterminated declaration", {
                    path = opts.source_name,
                    line = token_line,
                    column = token_column,
                }, 2)
            end
            local raw = data:sub(index, close)
            push({
                type = "directive",
                value = data:sub(index + 2, close - 1),
                raw = raw,
                line = token_line,
                column = token_column,
            })
            advance(raw)
            index = close + 1
        else
            local close = find_tag_end(index + 1)
            if not close then
                errors.raise("XmlSyntax", "unterminated start tag", {
                    path = opts.source_name,
                    line = token_line,
                    column = token_column,
                }, 2)
            end
            local raw = data:sub(index, close)
            local inner = util.trim(data:sub(index + 1, close - 1))
            local self_closing = inner:sub(-1) == "/"
            if self_closing then
                inner = util.trim(inner:sub(1, -2))
            end
            local name = inner:match("^([%w:_%-%.]+)") or ""
            local attr_source = inner:sub(#name + 1)
            push({
                type = "start",
                name = name,
                attrs = scan_attributes(attr_source, opts.source_name, token_line, token_column),
                selfClosing = self_closing,
                raw = raw,
                line = token_line,
                column = token_column,
            })
            advance(raw)
            index = close + 1
        end
    end

    return tokens
end

function xml.parse_tree(tokens, opts)
    opts = opts or {}
    local document = { type = "document", children = {} }
    local stack = { document }

    local function append_node(node)
        local parent = stack[#stack]
        parent.children[#parent.children + 1] = node
    end

    for index = 1, #tokens do
        local token = tokens[index]
        if token.type == "start" then
            local node = {
                type = "element",
                name = token.name,
                attrs = token.attrs or {},
                children = {},
                line = token.line,
                column = token.column,
            }
            append_node(node)
            if not token.selfClosing then
                stack[#stack + 1] = node
            end
        elseif token.type == "end" then
            local current = stack[#stack]
            if not current or current.type ~= "element" or current.name ~= token.name then
                errors.raise("XmlSyntax", "mismatched closing tag", {
                    path = opts.source_name,
                    line = token.line,
                    column = token.column,
                    tag = token.name,
                    expected = current and current.name or nil,
                }, 2)
            end
            stack[#stack] = nil
        else
            append_node(util.deep_copy(token))
        end
    end

    if #stack ~= 1 then
        local current = stack[#stack]
        errors.raise("XmlSyntax", "unterminated XML element", {
            path = opts.source_name,
            tag = current and current.name or nil,
            line = current and current.line or nil,
            column = current and current.column or nil,
        }, 2)
    end

    return document
end

local function first_element(nodes, name)
    for index = 1, #nodes do
        local node = nodes[index]
        if node.type == "element" and (not name or node.name == name) then
            return node
        end
    end
    return nil
end

local function collect_text(node, preserve_whitespace)
    local parts = {}
    for index = 1, #(node.children or {}) do
        local child = node.children[index]
        if child.type == "text" then
            append_text(parts, util.xml_unescape(child.value))
        elseif child.type == "cdata" then
            append_text(parts, child.value)
        end
    end
    local text = table.concat(parts)
    if preserve_whitespace then
        return text
    end
    return util.trim(text)
end

local function child_value_map(node)
    local out = {}
    for index = 1, #(node.children or {}) do
        local child = node.children[index]
        if child.type == "element" then
            out[child.name] = collect_text(child, false)
        end
    end
    return out
end

---reads a `float`/`double` written either as this node's text or as the text of a
---named child, whichever is present
local function child_number(node, name, fallback)
    local child = first_element(node.children, name)
    if not child then
        return fallback
    end
    return parse_number(collect_text(child, false))
end

---Splits a whitespace-separated run of numbers. used by the sequence types and
---NumberRange, which are text payloads rather than child elements
---(xml.md:441-463) -- the previous implementation looked for <Min>/<Max> child
---elements that Roblox never writes, so every NumberRange in every .rbxlx decoded
---to (0, 0). Classic-Crossroads has 33 of them
local function split_numbers(text)
    local out = {}
    for token in tostring(text or ""):gmatch("%S+") do
        out[#out + 1] = parse_number(token)
    end
    return out
end

---Content-typed sub-element (Font.Family, Font.CachedFaceId): the payload lives in
---a <url> child, not in the element's own text. Reading the element text returned
---"" for every Font in every file
local function content_child_text(node, name)
    local child = first_element(node.children, name)
    if not child then
        return ""
    end
    local inner = first_element(child.children)
    if inner then
        if inner.name == "null" then
            return ""
        end
        return collect_text(inner, false)
    end
    return collect_text(child, false)
end

local TWO32 = 4294967296

local function be_u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset, offset + 3)
    return ((a or 0) * 16777216) + ((b or 0) * 65536) + ((c or 0) * 256) + (d or 0)
end

local function u32_to_be_bytes(value)
    value = value % TWO32
    return string.char(
        band(rshift(value, 24), 0xFF),
        band(rshift(value, 16), 0xFF),
        band(rshift(value, 8), 0xFF),
        band(value, 0xFF))
end

--- the XML and binary formats store the Random bits of UniqueId one rotation apart
--- rotate left when reading XML and right when writing it
--- keep the bit operations local so loading XML does not pull in the binary reader
local function rotl64(hi, lo)
    local out_hi = band(bor(lshift(hi, 1), rshift(lo, 31)), 0xFFFFFFFF) % TWO32
    local out_lo = band(lshift(lo, 1), 0xFFFFFFFF) % TWO32
    if band(hi, 0x80000000) ~= 0 then
        out_lo = bor(out_lo, 1) % TWO32
    end
    return out_hi, out_lo
end

local function rotr64(hi, lo)
    local out_hi = rshift(hi, 1) % TWO32
    local out_lo = bor(rshift(lo, 1), lshift(band(hi, 1), 31)) % TWO32
    if band(lo, 1) == 1 then
        out_hi = bor(out_hi, 0x80000000) % TWO32
    end
    return out_hi, out_lo
end

---decodes the 32 hex characters of an XML UniqueId
---
---LAYOUT (xml.md:662-672): Random (u64, bytes 0-7), Time (u32, bytes 8-11),
---index (u32, bytes 12-15) -- the REVERSE of the binary struct order
---(binary.md:708-716), and the Random component is rotated one bit relative to
---the binary encoding. both facts are confirmed against the shipped pair: for
---Workspace/Overhead Ramp/Climb Ramp the binary carries
---000008e5 09dc3b56 5f2db3c95775d646 and the XML carries
---2f96d9e4abbaeb23 09dc3b56 000008e5
---
---`rawBytes` is rebuilt in the BINARY layout so the two parsers can be compared
---byte for byte, `hex` keeps the XML spelling for the writer
local function parse_unique_id(hex)
    hex = util.trim(hex)
    if #hex ~= 32 or hex:find("%X") then
        return nil
    end
    local bytes = {}
    for index = 1, 32, 2 do
        bytes[#bytes + 1] = string.char(tonumber(hex:sub(index, index + 1), 16))
    end
    local raw = table.concat(bytes)

    local xml_hi = be_u32(raw, 1)
    local xml_lo = be_u32(raw, 5)
    local time = be_u32(raw, 9)
    local index_value = be_u32(raw, 13)

    local random_hi, random_lo = rotl64(xml_hi, xml_lo)
    local binary_bytes = u32_to_be_bytes(index_value)
        .. u32_to_be_bytes(time)
        .. u32_to_be_bytes(random_hi)
        .. u32_to_be_bytes(random_lo)

    return {
        index = index_value,
        time = time,
        random = dom.make_i64(random_hi, random_lo, true),
    }, binary_bytes
end

---inverse of parse_unique_id, for the writer: Random, Time, Index (xml.md:662-672)
local function unique_id_to_xml_hex(value)
    if type(value) ~= "table" then
        return ""
    end
    local random = value.random or {}
    local xml_hi, xml_lo = rotr64(random.hi or 0, random.lo or 0)
    local raw = u32_to_be_bytes(xml_hi)
        .. u32_to_be_bytes(xml_lo)
        .. u32_to_be_bytes(value.time or 0)
        .. u32_to_be_bytes(value.index or 0)
    return (raw:gsub(".", function(char) return string.format("%02x", char:byte()) end))
end

-- inverse of FONT_STYLES, for the writer
local FONT_STYLE_NAMES = {}
for name, id in pairs(FONT_STYLES) do
    FONT_STYLE_NAMES[id] = name
end

local function parse_vector_node(node, integer_mode)
    local values = child_value_map(node)
    local x = integer_mode and math.floor(parse_number(values.X or values.x)) or parse_number(values.X or values.x)
    local y = integer_mode and math.floor(parse_number(values.Y or values.y)) or parse_number(values.Y or values.y)
    local z = integer_mode and math.floor(parse_number(values.Z or values.z)) or parse_number(values.Z or values.z)
    return { x = x, y = y, z = z }
end

local function parse_coordinate_frame(node)
    local target = node
    if node.name == "OptionalCoordinateFrame" then
        target = first_element(node.children, "CFrame")
        if not target then
            return nil
        end
    end
    local values = child_value_map(target)
    return {
        position = {
            x = parse_number(values.X),
            y = parse_number(values.Y),
            z = parse_number(values.Z),
        },
        orientation = {
            parse_number(values.R00 or "1"),
            parse_number(values.R01 or "0"),
            parse_number(values.R02 or "0"),
            parse_number(values.R10 or "0"),
            parse_number(values.R11 or "1"),
            parse_number(values.R12 or "0"),
            parse_number(values.R20 or "0"),
            parse_number(values.R21 or "0"),
            parse_number(values.R22 or "1"),
        },
    }
end

---Legacy ContentId (xml.md:293-313) and the modern Content type (xml.md:277-291)
---share the element name `Content`, so the CHILD decides which one this is:
---  <url> / <binary> / <hash>  -> legacy ContentId, which the binary format stores
---                                as a plain String, so that is what we return
---  <uri> / <Ref>              -> modern Content (binary type 0x22)
---  <null>                     -> ambiguous, read as legacy. See the header note
local function parse_content(node, tag)
    local element = first_element(node.children)

    if not element then
        -- no child element at all. Not a shape Roblox writes, but hand-authored
        -- files do it, treat the text as the URI
        local text = collect_text(node, false)
        return dom.value("String", text, { xml = { tag = tag, kind = "ContentId" } })
    end

    local name = element.name
    if name == "uri" then
        return dom.value("Content", { sourceType = "Uri", uri = collect_text(element, false) })
    end
    if name == "Ref" then
        local referent = collect_text(element, false)
        if referent == "" or referent == "null" then
            return dom.value("Content", { sourceType = "None" })
        end
        return dom.value("Content", { sourceType = "Object", referent = referent })
    end
    if name == "null" or name == "binary" or name == "hash" then
        -- xml.md:301 -- <binary>/<hash> contents are to be disregarded
        return dom.value("String", "", { xml = { tag = tag, kind = "ContentId" } })
    end

    -- <url>, and anything else, is the legacy URI form
    return dom.value("String", collect_text(element, false), {
        xml = { tag = tag, kind = "ContentId" },
    })
end

local function parse_font(node)
    local style_text = util.trim(collect_text(first_element(node.children, "Style") or { children = {} }, false))
    local style = FONT_STYLES[style_text]
    if style == nil then
        style = tonumber(style_text) or 0
    end
    return dom.value("Font", {
        family = content_child_text(node, "Family"),
        weight = math.floor(child_number(node, "Weight", 400) or 400),
        style = style,
        -- xml.md:395 -- CachedFaceId is OPTIONAL and omitted when empty. the binary
        -- format always writes it (binary.md:736), as "" when unset, so default to ""
        cachedFaceId = content_child_text(node, "CachedFaceId"),
    })
end

---a bitfield type written as <Faces><faces>N</faces></Faces> (xml.md:354-364) or
---<Axes><axes>N</axes></Axes> (xml.md:189-199)
---
---this used to return collect_text(node), which ignores element children -- so it
---produced the EMPTY STRING, not even the digits, where the binary parser produces
---a number (binary.lua:719-725). any downstream numeric test on a Faces/Axes
---property silently did nothing on an XML place
local function parse_bitfield(node, type_name, child_name)
    local child = first_element(node.children, child_name)
    local text = child and collect_text(child, false) or collect_text(node, false)
    local bits = math.floor(parse_number(text))
    -- same numeric `.value` and same decoded flags as binary.lua's Faces/Axes
    -- readers, the bit order is shared through dom.lua
    local flags = type_name == "Faces" and dom.face_flags(bits) or dom.axis_flags(bits)
    return dom.value(type_name, bits, flags)
end

-- Tag -> decoder. a dispatch table rather than a 40-arm elseif chain: this runs
-- once per property element, which is ~160k times for Classic-Crossroads.rbxlx
local DECODERS = {}

DECODERS["string"] = function(node)
    return dom.value("String", collect_text(node, true))
end

DECODERS["bool"] = function(node)
    -- xml.md:215 -- Roblox accepts "TRUE"/"fAlSe" even though it writes lowercase
    return dom.value("Bool", collect_text(node, false):lower() == "true")
end

DECODERS["int"] = function(node, property_name)
    if BRICKCOLOR_PROPERTIES[property_name] then
        return dom.value("BrickColor", math.floor(parse_number(collect_text(node, false))), {
            propertyName = property_name,
        })
    end
    return dom.value("Int32", math.floor(parse_number(collect_text(node, false))))
end

DECODERS["BrickColor"] = function(node, property_name)
    return dom.value("BrickColor", math.floor(parse_number(collect_text(node, false))), {
        propertyName = property_name,
    })
end

-- Int64 used to be stored as { decimal = <text>, number = tonumber(text) }, which
-- silently truncated anything past 2^53 and shared no shape at all with the binary
-- parser's { kind, hi, lo, signed }. dom.i64_from_decimal is exact for the full
-- 64-bit range and produces the binary parser's representation
DECODERS["int64"] = function(node, property_name, file)
    local text = collect_text(node, false)
    local value = dom.i64_from_decimal(text, true)
    if not value then
        file:add_warning("MalformedInt64", "int64 property was not a decimal integer", {
            property = property_name,
            text = text,
        })
        value = dom.make_i64(0, 0, true)
    end
    return dom.value("Int64", value)
end

DECODERS["SecurityCapabilities"] = function(node, property_name, file)
    local text = collect_text(node, false)
    local value = dom.i64_from_decimal(text, false)
    if not value then
        file:add_warning("MalformedSecurityCapabilities",
            "SecurityCapabilities property was not a decimal integer", {
                property = property_name,
                text = text,
            })
        value = dom.make_i64(0, 0, false)
    end
    return dom.value("SecurityCapabilities", value)
end

DECODERS["float"] = function(node)
    return dom.value("Float32", parse_number(collect_text(node, false)))
end

DECODERS["double"] = function(node)
    return dom.value("Float64", parse_number(collect_text(node, false)))
end

DECODERS["token"] = function(node, property_name)
    local text = collect_text(node, false)
    local number = tonumber(text)
    if number then
        -- same extras as binary.lua:727-733, so the two DOMs match key for key
        return dom.value("Enum", number, { propertyName = property_name })
    end
    -- Not a number. xml.md:622-632 says token is numeric, but hand-authored files
    -- use the item name, keep it so common.lua can resolve it by name
    return dom.value("Enum", 0, { tokenText = text, propertyName = property_name })
end

DECODERS["Color3"] = function(node)
    local values = child_value_map(node)
    return dom.value("Color3", {
        r = parse_number(values.R),
        g = parse_number(values.G),
        b = parse_number(values.B),
    })
end

DECODERS["Color3uint8"] = function(node)
    local packed = tonumber(collect_text(node, false)) or 0
    if packed < 0 then
        packed = packed + 4294967296
    end
    -- matches binary.lua:901-909, which divides the three bytes by 255. no `packed`
    -- extra: the binary parser has none, and the writer recomputes it
    return dom.value("Color3uint8", {
        r = math.floor(packed / 65536) % 256 / 255,
        g = math.floor(packed / 256) % 256 / 255,
        b = packed % 256 / 255,
    })
end

DECODERS["Vector2"] = function(node)
    local values = child_value_map(node)
    return dom.value("Vector2", {
        x = parse_number(values.X),
        y = parse_number(values.Y),
    })
end

DECODERS["Vector3"] = function(node)
    return dom.value("Vector3", parse_vector_node(node, false))
end

DECODERS["Vector3int16"] = function(node)
    return dom.value("Vector3int16", parse_vector_node(node, true))
end

DECODERS["UDim"] = function(node)
    local values = child_value_map(node)
    return dom.value("UDim", {
        scale = parse_number(values.S or values.Scale),
        offset = math.floor(parse_number(values.O or values.Offset)),
    })
end

DECODERS["UDim2"] = function(node)
    local values = child_value_map(node)
    return dom.value("UDim2", {
        x = {
            scale = parse_number(values.XS or values.XScale),
            offset = math.floor(parse_number(values.XO or values.XOffset)),
        },
        y = {
            scale = parse_number(values.YS or values.YScale),
            offset = math.floor(parse_number(values.YO or values.YOffset)),
        },
    })
end

DECODERS["CoordinateFrame"] = function(node)
    return dom.value("CFrame", parse_coordinate_frame(node))
end
DECODERS["CFrame"] = DECODERS["CoordinateFrame"]

DECODERS["OptionalCoordinateFrame"] = function(node)
    local parsed = parse_coordinate_frame(node)
    if not parsed then
        return dom.value("OptionalCFrame", nil, { none = true })
    end
    return dom.value("OptionalCFrame", parsed)
end

DECODERS["Ref"] = function(node)
    local text = collect_text(node, false)
    if text == "" or text == "null" then
        return dom.value("Referent", nil, { xmlRef = "null" })
    end
    return dom.value("Referent", text, { xmlRef = text })
end

-- BinaryString decodes to a DOM `String` holding the raw bytes
--
-- two separate defects lived here. the first was that the base64 decode was gated
-- on an encoding="base64" attribute that Roblox never writes (grep -c on
-- Classic-Crossroads.rbxlx returns 0), so it never fired and base64 ASCII went
-- downstream where bytes were expected -- a .rbxlx union's MeshData arrived as
-- text and the CSG part rendered with no geometry. That was fixed earlier and the
-- unconditional decode is kept here
--
-- the second is the TYPE NAME. the binary format has no BinaryString type: it
-- writes 0x01 String (binary.md:299-315). So the same property was String from one
-- parser and BinaryString from the other -- 178 properties on Classic-Crossroads,
-- dominated by Tags and AttributesSerialize, which appear on every instance
DECODERS["BinaryString"] = function(node, property_name, file)
    local text = collect_text(node, true)
    local encoding = node.attrs and node.attrs.encoding or nil
    local decoded
    if encoding == "none" then
        decoded = text
    else
        local ok, result = pcall(util.decode_base64, text)
        if ok and type(result) == "string" then
            decoded = result
        else
            -- Not valid base64. keep the raw text so nothing is lost, but say so
            -- rather than silently substituting a value of the wrong kind
            decoded = text
            file:add_warning("BinaryStringDecodeFailed",
                "BinaryString content was not valid base64; kept as raw text", {
                    property = property_name,
                    length = #text,
                })
        end
    end
    return dom.value("String", decoded, {
        xml = { tag = "BinaryString", text = text, encoding = encoding },
    })
end

-- also a 0x01 String in the binary format. Whitespace MUST be preserved
-- (xml.md:531)
DECODERS["ProtectedString"] = function(node)
    return dom.value("String", collect_text(node, true), {
        xml = { tag = "ProtectedString" },
    })
end

DECODERS["SharedString"] = function(node, property_name, file)
    local md5 = collect_text(node, false)
    local shared = file.sharedStringsByMd5 and file.sharedStringsByMd5[md5] or nil
    -- `index` mirrors binary.lua:922-933, which carries the SSTR table position
    return dom.value("SharedString", {
        index = shared and shared.index or 0,
        md5 = md5,
        value = shared and shared.value or "",
    })
end

-- xml.md:431-439 -- NetAssetRef is written exactly like a SharedString
DECODERS["NetAssetRef"] = DECODERS["SharedString"]

DECODERS["Content"] = function(node)
    return parse_content(node, "Content")
end

DECODERS["ContentId"] = function(node)
    return parse_content(node, "ContentId")
end

DECODERS["UniqueId"] = function(node, property_name, file)
    local hex = collect_text(node, false)
    local parsed, binary_bytes = parse_unique_id(hex)
    if not parsed then
        file:add_warning("MalformedUniqueId", "UniqueId was not 32 hexadecimal characters", {
            property = property_name,
            text = hex,
        })
        return dom.value("UniqueId", {
            index = 0,
            time = 0,
            random = dom.make_i64(0, 0, true),
        }, { hex = hex })
    end
    return dom.value("UniqueId", parsed, { rawBytes = binary_bytes, hex = hex })
end

DECODERS["Font"] = function(node)
    return parse_font(node)
end

DECODERS["PhysicalProperties"] = function(node)
    local values = child_value_map(node)
    -- xml.md:501-507 -- CustomPhysics is the discriminator and is the ONLY child
    -- when false
    if (values.CustomPhysics or ""):lower() ~= "true" then
        return dom.value("PhysicalProperties", nil, { none = true })
    end
    -- snake_case keys, matching binary.lua:886-893. they used to be camelCase here,
    -- so the same part had a differently-shaped PhysicalProperties depending on the
    -- container format, runtime/parser.lua:392-400 still carries a workaround for it
    return dom.value("PhysicalProperties", {
        density = parse_number(values.Density),
        friction = parse_number(values.Friction),
        elasticity = parse_number(values.Elasticity),
        friction_weight = parse_number(values.FrictionWeight),
        elasticity_weight = parse_number(values.ElasticityWeight),
        -- xml.md:505 -- AcousticAbsorption MAY be absent in older files
        acoustic_absorption = values.AcousticAbsorption and parse_number(values.AcousticAbsorption) or nil,
    })
end

-- xml.md:441-451 -- two floats separated by a space, NOT <Min>/<Max> children
DECODERS["NumberRange"] = function(node)
    local numbers = split_numbers(collect_text(node, false))
    return dom.value("NumberRange", {
        min = numbers[1] or 0,
        max = numbers[2] or 0,
    })
end

-- xml.md:453-463 -- flat float run, 3 per keypoint (Time, Value, Envelope)
DECODERS["NumberSequence"] = function(node)
    local numbers = split_numbers(collect_text(node, false))
    local keypoints = {}
    for index = 1, #numbers - 2, 3 do
        keypoints[#keypoints + 1] = {
            time = numbers[index],
            value = numbers[index + 1],
            envelope = numbers[index + 2],
        }
    end
    return dom.value("NumberSequence", keypoints)
end

-- xml.md:263-275 -- flat float run, 5 per keypoint (Time, R, G, B, Envelope)
DECODERS["ColorSequence"] = function(node)
    local numbers = split_numbers(collect_text(node, false))
    local keypoints = {}
    for index = 1, #numbers - 4, 5 do
        keypoints[#keypoints + 1] = {
            time = numbers[index],
            color = {
                r = numbers[index + 1],
                g = numbers[index + 2],
                b = numbers[index + 3],
            },
            envelope = numbers[index + 4],
        }
    end
    return dom.value("ColorSequence", keypoints)
end

-- xml.md:562-581 -- <min> and <max> children, each a Vector2
--
-- the previous implementation read flat keys (min_x / X0 / MinX ...) that no
-- Roblox encoder emits, so every Rect in every .rbxlx decoded to (0,0)-(0,0)
DECODERS["Rect2D"] = function(node)
    local min_node = first_element(node.children, "min") or first_element(node.children, "Min")
    local max_node = first_element(node.children, "max") or first_element(node.children, "Max")
    local min_values = min_node and child_value_map(min_node) or {}
    local max_values = max_node and child_value_map(max_node) or {}
    return dom.value("Rect", {
        min = { x = parse_number(min_values.X), y = parse_number(min_values.Y) },
        max = { x = parse_number(max_values.X), y = parse_number(max_values.Y) },
    })
end
DECODERS["Rect"] = DECODERS["Rect2D"]

DECODERS["Ray"] = function(node)
    local origin = first_element(node.children, "origin") or first_element(node.children, "Origin")
    local direction = first_element(node.children, "direction") or first_element(node.children, "Direction")
    return dom.value("Ray", {
        origin = origin and parse_vector_node(origin, false) or { x = 0, y = 0, z = 0 },
        direction = direction and parse_vector_node(direction, false) or { x = 0, y = 0, z = 0 },
    })
end

DECODERS["Faces"] = function(node)
    return parse_bitfield(node, "Faces", "faces")
end

DECODERS["Axes"] = function(node)
    return parse_bitfield(node, "Axes", "axes")
end

xml.DECODERS = DECODERS

local function parse_property_node(node, file)
    local decoder = DECODERS[node.name]
    if not decoder then
        return nil
    end
    return decoder(node, node.attrs and node.attrs.name or node.name, file)
end

local function parse_properties(instance, node, file)
    instance.sourceMetadata.unknownXmlChildren = instance.sourceMetadata.unknownXmlChildren or {}
    for index = 1, #node.children do
        local child = node.children[index]
        if child.type == "element" then
            local property_name = child.attrs and child.attrs.name or child.name
            if instance.className == "Workspace" and property_name == "CollisionGroupData" then
                local count = (instance.sourceMetadata.collisionGroupDataPropertyCount or 0) + 1
                instance.sourceMetadata.collisionGroupDataPropertyCount = count
                if count > 1 then
                    -- reject before set_property can overwrite the first value,
                    -- including duplicate fields in separate Properties blocks
                    error(errors.new("DuplicateXmlCollisionGroupData",
                        "Duplicate present CollisionGroupData",
                        { property=property_name, instance=instance.className }), 0)
                end
            end
            local value = parse_property_node(child, file)
            if value then
                instance:set_property(property_name, value)
            else
                -- a type element we do not decode. this used to be dropped into
                -- unknownProperties with NO diagnostic at all, so a whole type going
                -- missing looked exactly like the file not carrying it: every
                -- <SecurityCapabilities> element in Classic-Crossroads.rbxlx -- one
                -- per instance, 4406 of them -- landed here silently while the binary
                -- parser decoded all 4412. Warn once per (tag, property) pair so the
                -- volume stays readable but nothing is invisible
                local key = child.name .. "\0" .. property_name
                local seen = file.sourceMetadata.unknownXmlPropertyTypes
                if not seen then
                    seen = {}
                    file.sourceMetadata.unknownXmlPropertyTypes = seen
                end
                if not seen[key] then
                    seen[key] = true
                    file:add_warning("UnknownXmlPropertyType",
                        "no decoder for this XML type element; property preserved but not parsed", {
                            tag = child.name,
                            property = property_name,
                            instance = instance.className,
                        })
                end
                instance.unknownProperties[property_name] = util.deep_copy(child)
            end
        end
    end
end

local function parse_item(node, file)
    local instance = dom.new_instance(node.attrs.class or "Instance", node.attrs.referent)
    instance.sourceMetadata.xmlAttributes = util.deep_copy(node.attrs or {})
    file:add_instance(instance)

    for index = 1, #node.children do
        local child = node.children[index]
        if child.type == "element" and child.name == "Properties" then
            parse_properties(instance, child, file)
        elseif child.type == "element" and child.name == "Item" then
            instance:add_child(parse_item(child, file))
        elseif child.type == "element" then
            instance.sourceMetadata.unknownXmlChildren = instance.sourceMetadata.unknownXmlChildren or {}
            instance.sourceMetadata.unknownXmlChildren[#instance.sourceMetadata.unknownXmlChildren + 1] = util.deep_copy(child)
        end
    end

    return instance
end

local function resolve_xml_refs(file)
    for index = 1, #file.instances do
        local instance = file.instances[index]
        for property_name, value in pairs(instance.properties) do
            if dom.is_value(value) and value.type == "Referent" then
                value.instance = value.value and file:get_instance(value.value) or nil
                if value.value and not value.instance then
                    file:add_warning("InvalidXmlRef", "XML Ref could not be resolved", {
                        instance = dom.instance_path(instance),
                        propertyName = property_name,
                        referent = value.value,
                    })
                end
            end
        end
    end
end

function xml.read(data, opts)
    opts = opts or {}
    local tokens = xml.tokenize(data, opts)
    local tree = xml.parse_tree(tokens, opts)
    local root = first_element(tree.children, "roblox")
    if not root then
        errors.raise("XmlSyntax", "missing <roblox> root element", {
            path = opts.source_name,
        }, 2)
    end

    local file = dom.new_file(opts.formatKind or ".rbxlx", opts.source_name)
    file.sourceBytes = data
    file.sourceMetadata.xmlRootAttributes = util.deep_copy(root.attrs or {})
    file.sharedStringsByMd5 = {}
    file.sourceMetadata.xmlTokens = opts.keep_tokens and tokens or nil
    file.sourceMetadata.xmlTree = opts.keep_tree and tree or nil
    file.sourceMetadata.xmlDeclaration = nil

    for index = 1, #tree.children do
        local child = tree.children[index]
        if child.type == "declaration" then
            file.sourceMetadata.xmlDeclaration = util.deep_copy(child)
            break
        end
    end

    for index = 1, #root.children do
        local child = root.children[index]
        if child.type == "element" and child.name == "Meta" then
            file.metadata[child.attrs.name or ("Meta" .. index)] = collect_text(child, true)
        elseif child.type == "element" and child.name == "SharedStrings" then
            for shared_index = 1, #child.children do
                local shared_node = child.children[shared_index]
                if shared_node.type == "element" and shared_node.name == "SharedString" then
                    local entry = {
                        md5 = shared_node.attrs.md5 or "",
                        encoded = collect_text(shared_node, true),
                        -- 0-based, matching the SSTR table index the binary format
                        -- stores in a SharedString property (binary.lua:922-933)
                        index = #file.sharedStrings,
                    }
                    entry.value = util.decode_base64(entry.encoded)
                    file.sharedStrings[#file.sharedStrings + 1] = entry
                    if entry.md5 ~= "" then
                        file.sharedStringsByMd5[entry.md5] = entry
                    end
                end
            end
        end
    end

    for index = 1, #root.children do
        local child = root.children[index]
        if child.type == "element" and child.name == "Item" then
            file:add_root(parse_item(child, file))
        elseif child.type == "element" and child.name ~= "Meta" and child.name ~= "External" and child.name ~= "SharedStrings" then
            file:add_unknown_xml_node(util.deep_copy(child))
        end
    end

    resolve_xml_refs(file)
    return file
end

function xml.read_file(path, opts)
    local data, err = util.read_file(path)
    if type(data) ~= "string" then
        errors.raise("XmlRead", "failed to read Roblox XML file", {
            path = path,
            reason = err,
        }, 2)
    end
    opts = util.shallow_copy(opts or {})
    opts.source_name = path
    opts.formatKind = util.detect_format(path, data)
    return xml.read(data, opts)
end

local function serialize_node(node, parts, indent)
    indent = indent or ""
    if node.type == "text" then
        parts[#parts + 1] = indent .. util.xml_escape(node.value)
        return
    end
    if node.type == "cdata" then
        parts[#parts + 1] = indent .. "<![CDATA[" .. node.value .. "]]>"
        return
    end
    if node.type ~= "element" then
        return
    end

    local attrs = {}
    for key, value in pairs(node.attrs or {}) do
        attrs[#attrs + 1] = key .. '="' .. util.xml_escape(value) .. '"'
    end
    table.sort(attrs)
    local prefix = indent .. "<" .. node.name
    if #attrs > 0 then
        prefix = prefix .. " " .. table.concat(attrs, " ")
    end

    if not node.children or #node.children == 0 then
        parts[#parts + 1] = prefix .. "/>"
        return
    end

    parts[#parts + 1] = prefix .. ">"
    for index = 1, #node.children do
        serialize_node(node.children[index], parts, indent .. "\t")
    end
    parts[#parts + 1] = indent .. "</" .. node.name .. ">"
end

local function encode_coordinate_frame(value, name, parts, indent, optional)
    parts[#parts + 1] = indent .. "<" .. (optional and "OptionalCoordinateFrame" or "CoordinateFrame") .. ' name="' .. util.xml_escape(name) .. '">'
    if value then
        if optional then
            parts[#parts + 1] = indent .. "\t<CFrame>"
            indent = indent .. "\t"
        end
        local p = value.position or {}
        local o = value.orientation or {}
        local labels = {
            { "X", p.x or 0 }, { "Y", p.y or 0 }, { "Z", p.z or 0 },
            { "R00", o[1] or 1 }, { "R01", o[2] or 0 }, { "R02", o[3] or 0 },
            { "R10", o[4] or 0 }, { "R11", o[5] or 1 }, { "R12", o[6] or 0 },
            { "R20", o[7] or 0 }, { "R21", o[8] or 0 }, { "R22", o[9] or 1 },
        }
        for index = 1, #labels do
            parts[#parts + 1] = indent .. "\t<" .. labels[index][1] .. ">" .. tostring(labels[index][2]) .. "</" .. labels[index][1] .. ">"
        end
        if optional then
            parts[#parts + 1] = indent .. "</CFrame>"
            indent = indent:sub(1, -2)
        end
    end
    parts[#parts + 1] = indent .. "</" .. (optional and "OptionalCoordinateFrame" or "CoordinateFrame") .. ">"
end

---Formats a number the way the XML spec requires (xml.md:340-352, 366-378):
---INF / -INF / NAN in upper case, and no exponent-free rounding of integers
local function encode_number(value)
    value = tonumber(value) or 0
    if value ~= value then
        return "NAN"
    end
    if value == math.huge then
        return "INF"
    end
    if value == -math.huge then
        return "-INF"
    end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return string.format("%.9g", value)
end

local function open_tag(tag, name)
    return "<" .. tag .. ' name="' .. util.xml_escape(name) .. '">'
end

---Emits a Content-typed sub-element, the shape Font.Family/Font.CachedFaceId use
local function encode_content_child(parts, indent, tag, uri)
    if uri and uri ~= "" then
        parts[#parts + 1] = indent .. "<" .. tag .. "><url>" .. util.xml_escape(uri) .. "</url></" .. tag .. ">"
    else
        parts[#parts + 1] = indent .. "<" .. tag .. "><null></null></" .. tag .. ">"
    end
end

---Re-emits a DOM `String` in whichever XML spelling it was read from
---
---BinaryString, ProtectedString and legacy ContentId all decode to `String` so the
---DOM matches the binary parser (see the header note). value.xml.tag records the
---original element so a read/write round trip does not silently rewrite a script's
---source as an escaped <string> or a texture id as a bare string
local function encode_string_property(name, value, raw, parts, indent)
    local meta = value.xml
    local tag = type(meta) == "table" and meta.tag or nil
    raw = type(raw) == "string" and raw or ""

    if tag == "BinaryString" then
        local text
        if type(meta) == "table" and meta.encoding == "none" then
            text = raw
        else
            text = util.encode_base64(raw)
        end
        parts[#parts + 1] = indent .. open_tag("BinaryString", name) .. text .. "</BinaryString>"
        return
    end
    if tag == "ProtectedString" then
        parts[#parts + 1] = indent .. open_tag("ProtectedString", name) .. "<![CDATA[" .. raw .. "]]></ProtectedString>"
        return
    end
    if tag == "Content" or tag == "ContentId" then
        parts[#parts + 1] = indent .. open_tag(tag, name)
        if raw ~= "" then
            parts[#parts + 1] = indent .. "\t<url>" .. util.xml_escape(raw) .. "</url>"
        else
            parts[#parts + 1] = indent .. "\t<null></null>"
        end
        parts[#parts + 1] = indent .. "</" .. tag .. ">"
        return
    end

    parts[#parts + 1] = indent .. open_tag("string", name) .. util.xml_escape(raw) .. "</string>"
end

local function encode_property(name, value, parts, indent)
    if not dom.is_value(value) then
        value = dom.value("String", tostring(value))
    end

    local t = value.type
    local raw = value.value
    if t == "String" or t == "ProtectedString" or t == "Bytecode" then
        encode_string_property(name, value, raw, parts, indent)
    elseif t == "BinaryString" then
        -- Legacy shape { text = <base64>, value = <bytes> }, still accepted so a DOM
        -- built by hand or restored from an old cache round-trips
        local text = type(raw) == "table" and (raw.text or util.encode_base64(raw.value or "")) or util.encode_base64(raw or "")
        parts[#parts + 1] = indent .. open_tag("BinaryString", name) .. text .. "</BinaryString>"
    elseif t == "Bool" then
        parts[#parts + 1] = indent .. open_tag("bool", name) .. tostring(raw and true or false) .. "</bool>"
    elseif t == "Int32" then
        parts[#parts + 1] = indent .. open_tag("int", name) .. string.format("%d", math.floor(tonumber(raw) or 0)) .. "</int>"
    elseif t == "Int64" then
        parts[#parts + 1] = indent .. open_tag("int64", name) .. dom.i64_to_decimal(raw) .. "</int64>"
    elseif t == "SecurityCapabilities" then
        parts[#parts + 1] = indent .. open_tag("SecurityCapabilities", name)
            .. dom.i64_to_decimal(raw) .. "</SecurityCapabilities>"
    elseif t == "Float32" then
        parts[#parts + 1] = indent .. open_tag("float", name) .. encode_number(raw) .. "</float>"
    elseif t == "Float64" then
        parts[#parts + 1] = indent .. open_tag("double", name) .. encode_number(raw) .. "</double>"
    elseif t == "Enum" then
        parts[#parts + 1] = indent .. open_tag("token", name) .. string.format("%d", math.floor(tonumber(raw) or 0)) .. "</token>"
    elseif t == "BrickColor" then
        -- xml.md:227 -- Roblox writes BrickColor with the element name `int`
        parts[#parts + 1] = indent .. open_tag("int", name) .. string.format("%d", math.floor(tonumber(raw) or 0)) .. "</int>"
    elseif t == "Color3" then
        parts[#parts + 1] = indent .. open_tag("Color3", name)
        parts[#parts + 1] = indent .. "\t<R>" .. encode_number(raw and raw.r) .. "</R>"
        parts[#parts + 1] = indent .. "\t<G>" .. encode_number(raw and raw.g) .. "</G>"
        parts[#parts + 1] = indent .. "\t<B>" .. encode_number(raw and raw.b) .. "</B>"
        parts[#parts + 1] = indent .. "</Color3>"
    elseif t == "Color3uint8" then
        local packed = value.packed
        if not packed and type(raw) == "table" then
            packed = (util.round((raw.r or 0) * 255) * 65536)
                + (util.round((raw.g or 0) * 255) * 256)
                + util.round((raw.b or 0) * 255)
        end
        -- xml.md:253 -- the top byte SHOULD be 0xFF for Roblox compatibility
        packed = (packed or 0) % 16777216 + 4278190080
        parts[#parts + 1] = indent .. open_tag("Color3uint8", name) .. string.format("%d", packed) .. "</Color3uint8>"
    elseif t == "Vector2" then
        parts[#parts + 1] = indent .. open_tag("Vector2", name)
        parts[#parts + 1] = indent .. "\t<X>" .. encode_number(raw and raw.x) .. "</X>"
        parts[#parts + 1] = indent .. "\t<Y>" .. encode_number(raw and raw.y) .. "</Y>"
        parts[#parts + 1] = indent .. "</Vector2>"
    elseif t == "Vector3" or t == "Vector3int16" then
        parts[#parts + 1] = indent .. open_tag(t, name)
        parts[#parts + 1] = indent .. "\t<X>" .. encode_number(raw and raw.x) .. "</X>"
        parts[#parts + 1] = indent .. "\t<Y>" .. encode_number(raw and raw.y) .. "</Y>"
        parts[#parts + 1] = indent .. "\t<Z>" .. encode_number(raw and raw.z) .. "</Z>"
        parts[#parts + 1] = indent .. "</" .. t .. ">"
    elseif t == "UDim" then
        parts[#parts + 1] = indent .. open_tag("UDim", name)
        parts[#parts + 1] = indent .. "\t<S>" .. encode_number(raw and raw.scale) .. "</S>"
        parts[#parts + 1] = indent .. "\t<O>" .. string.format("%d", math.floor((raw and raw.offset) or 0)) .. "</O>"
        parts[#parts + 1] = indent .. "</UDim>"
    elseif t == "UDim2" then
        local x = (type(raw) == "table" and raw.x) or {}
        local y = (type(raw) == "table" and raw.y) or {}
        parts[#parts + 1] = indent .. open_tag("UDim2", name)
        parts[#parts + 1] = indent .. "\t<XS>" .. encode_number(x.scale) .. "</XS>"
        parts[#parts + 1] = indent .. "\t<XO>" .. string.format("%d", math.floor(x.offset or 0)) .. "</XO>"
        parts[#parts + 1] = indent .. "\t<YS>" .. encode_number(y.scale) .. "</YS>"
        parts[#parts + 1] = indent .. "\t<YO>" .. string.format("%d", math.floor(y.offset or 0)) .. "</YO>"
        parts[#parts + 1] = indent .. "</UDim2>"
    elseif t == "CFrame" then
        encode_coordinate_frame(raw, name, parts, indent, false)
    elseif t == "OptionalCFrame" then
        encode_coordinate_frame(raw, name, parts, indent, true)
    elseif t == "Referent" then
        parts[#parts + 1] = indent .. open_tag("Ref", name) .. util.xml_escape(raw or "null") .. "</Ref>"
    elseif t == "SharedString" then
        local md5 = type(raw) == "table" and raw.md5 or ""
        parts[#parts + 1] = indent .. open_tag("SharedString", name) .. util.xml_escape(md5 or "") .. "</SharedString>"
    elseif t == "Content" then
        parts[#parts + 1] = indent .. open_tag("Content", name)
        local source_type = type(raw) == "table" and raw.sourceType or nil
        if source_type == "Object" or source_type == "ExternalObject" then
            parts[#parts + 1] = indent .. "\t<Ref>" .. util.xml_escape(tostring(raw.referent or "null")) .. "</Ref>"
        elseif source_type == "Uri" and type(raw.uri) == "string" and raw.uri ~= "" then
            parts[#parts + 1] = indent .. "\t<uri>" .. util.xml_escape(raw.uri) .. "</uri>"
        else
            parts[#parts + 1] = indent .. "\t<null></null>"
        end
        parts[#parts + 1] = indent .. "</Content>"
    elseif t == "UniqueId" then
        local hex = value.hex
        if not hex and type(raw) == "table" then
            hex = unique_id_to_xml_hex(raw)
        end
        parts[#parts + 1] = indent .. open_tag("UniqueId", name) .. util.xml_escape(hex or "") .. "</UniqueId>"
    elseif t == "Font" then
        parts[#parts + 1] = indent .. open_tag("Font", name)
        encode_content_child(parts, indent .. "\t", "Family", raw and raw.family)
        parts[#parts + 1] = indent .. "\t<Weight>" .. string.format("%d", math.floor((raw and raw.weight) or 400)) .. "</Weight>"
        parts[#parts + 1] = indent .. "\t<Style>" .. (FONT_STYLE_NAMES[raw and raw.style] or "Normal") .. "</Style>"
        if raw and raw.cachedFaceId and raw.cachedFaceId ~= "" then
            encode_content_child(parts, indent .. "\t", "CachedFaceId", raw.cachedFaceId)
        end
        parts[#parts + 1] = indent .. "</Font>"
    elseif t == "PhysicalProperties" then
        parts[#parts + 1] = indent .. open_tag("PhysicalProperties", name)
        if value.none or raw == nil then
            parts[#parts + 1] = indent .. "\t<CustomPhysics>false</CustomPhysics>"
        else
            parts[#parts + 1] = indent .. "\t<CustomPhysics>true</CustomPhysics>"
            parts[#parts + 1] = indent .. "\t<Density>" .. encode_number(raw.density) .. "</Density>"
            parts[#parts + 1] = indent .. "\t<Friction>" .. encode_number(raw.friction) .. "</Friction>"
            parts[#parts + 1] = indent .. "\t<Elasticity>" .. encode_number(raw.elasticity) .. "</Elasticity>"
            parts[#parts + 1] = indent .. "\t<FrictionWeight>"
                .. encode_number(raw.friction_weight or raw.frictionWeight) .. "</FrictionWeight>"
            parts[#parts + 1] = indent .. "\t<ElasticityWeight>"
                .. encode_number(raw.elasticity_weight or raw.elasticityWeight) .. "</ElasticityWeight>"
            local acoustic = raw.acoustic_absorption
            if acoustic == nil then acoustic = raw.acousticAbsorption end
            if acoustic ~= nil then
                parts[#parts + 1] = indent .. "\t<AcousticAbsorption>" .. encode_number(acoustic) .. "</AcousticAbsorption>"
            end
        end
        parts[#parts + 1] = indent .. "</PhysicalProperties>"
    elseif t == "NumberRange" then
        parts[#parts + 1] = indent .. open_tag("NumberRange", name)
            .. encode_number(raw and raw.min) .. " " .. encode_number(raw and raw.max) .. " </NumberRange>"
    elseif t == "NumberSequence" or t == "ColorSequence" then
        local pieces = {}
        for index = 1, #(raw or {}) do
            local keypoint = raw[index]
            pieces[#pieces + 1] = encode_number(keypoint.time)
            if t == "NumberSequence" then
                pieces[#pieces + 1] = encode_number(keypoint.value)
            else
                local color = keypoint.color or {}
                pieces[#pieces + 1] = encode_number(color.r)
                pieces[#pieces + 1] = encode_number(color.g)
                pieces[#pieces + 1] = encode_number(color.b)
            end
            pieces[#pieces + 1] = encode_number(keypoint.envelope)
        end
        parts[#parts + 1] = indent .. open_tag(t, name) .. table.concat(pieces, " ") .. " </" .. t .. ">"
    elseif t == "Rect" then
        local min_value = (type(raw) == "table" and raw.min) or {}
        local max_value = (type(raw) == "table" and raw.max) or {}
        parts[#parts + 1] = indent .. open_tag("Rect2D", name)
        parts[#parts + 1] = indent .. "\t<min>"
        parts[#parts + 1] = indent .. "\t\t<X>" .. encode_number(min_value.x) .. "</X>"
        parts[#parts + 1] = indent .. "\t\t<Y>" .. encode_number(min_value.y) .. "</Y>"
        parts[#parts + 1] = indent .. "\t</min>"
        parts[#parts + 1] = indent .. "\t<max>"
        parts[#parts + 1] = indent .. "\t\t<X>" .. encode_number(max_value.x) .. "</X>"
        parts[#parts + 1] = indent .. "\t\t<Y>" .. encode_number(max_value.y) .. "</Y>"
        parts[#parts + 1] = indent .. "\t</max>"
        parts[#parts + 1] = indent .. "</Rect2D>"
    elseif t == "Ray" then
        local origin = (type(raw) == "table" and raw.origin) or {}
        local direction = (type(raw) == "table" and raw.direction) or {}
        parts[#parts + 1] = indent .. open_tag("Ray", name)
        parts[#parts + 1] = indent .. "\t<origin>"
        parts[#parts + 1] = indent .. "\t\t<X>" .. encode_number(origin.x) .. "</X>"
        parts[#parts + 1] = indent .. "\t\t<Y>" .. encode_number(origin.y) .. "</Y>"
        parts[#parts + 1] = indent .. "\t\t<Z>" .. encode_number(origin.z) .. "</Z>"
        parts[#parts + 1] = indent .. "\t</origin>"
        parts[#parts + 1] = indent .. "\t<direction>"
        parts[#parts + 1] = indent .. "\t\t<X>" .. encode_number(direction.x) .. "</X>"
        parts[#parts + 1] = indent .. "\t\t<Y>" .. encode_number(direction.y) .. "</Y>"
        parts[#parts + 1] = indent .. "\t\t<Z>" .. encode_number(direction.z) .. "</Z>"
        parts[#parts + 1] = indent .. "\t</direction>"
        parts[#parts + 1] = indent .. "</Ray>"
    elseif t == "Faces" or t == "Axes" then
        local child = t == "Faces" and "faces" or "axes"
        parts[#parts + 1] = indent .. open_tag(t, name)
            .. "<" .. child .. ">" .. string.format("%d", math.floor(tonumber(raw) or 0)) .. "</" .. child .. ">"
            .. "</" .. t .. ">"
    else
        parts[#parts + 1] = indent .. open_tag("string", name) .. util.xml_escape(tostring(raw or "")) .. "</string>"
    end
end

local function encode_item(instance, parts, indent)
    parts[#parts + 1] = indent .. '<Item class="' .. util.xml_escape(instance.className or "Instance") .. '" referent="' .. util.xml_escape(instance.referent or "") .. '">'
    parts[#parts + 1] = indent .. "\t<Properties>"
    for index = 1, #instance.propertyOrder do
        local property_name = instance.propertyOrder[index]
        encode_property(property_name, instance.properties[property_name], parts, indent .. "\t\t")
    end
    for property_name, node in pairs(instance.unknownProperties or {}) do
        if not instance.properties[property_name] then
            serialize_node(node, parts, indent .. "\t\t")
        end
    end
    parts[#parts + 1] = indent .. "\t</Properties>"

    local preserved = instance.sourceMetadata and instance.sourceMetadata.unknownXmlChildren or nil
    if type(preserved) == "table" then
        for index = 1, #preserved do
            serialize_node(preserved[index], parts, indent .. "\t")
        end
    end

    for index = 1, #instance.children do
        encode_item(instance.children[index], parts, indent .. "\t")
    end
    parts[#parts + 1] = indent .. "</Item>"
end

function xml.write(file, opts)
    opts = opts or {}
    local parts = {}
    parts[#parts + 1] = '<?xml version="1.0" encoding="utf-8"?>'
    parts[#parts + 1] = '<roblox version="4">'

    local keys = {}
    for key in pairs(file.metadata or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for index = 1, #keys do
        parts[#parts + 1] = '\t<Meta name="' .. util.xml_escape(keys[index]) .. '">' .. util.xml_escape(file.metadata[keys[index]]) .. "</Meta>"
    end

    if file.sharedStrings and #file.sharedStrings > 0 then
        parts[#parts + 1] = "\t<SharedStrings>"
        for index = 1, #file.sharedStrings do
            local entry = file.sharedStrings[index]
            local encoded = entry.encoded or util.encode_base64(entry.value or "")
            parts[#parts + 1] = '\t\t<SharedString md5="' .. util.xml_escape(entry.md5 or "") .. '">' .. encoded .. "</SharedString>"
        end
        parts[#parts + 1] = "\t</SharedStrings>"
    end

    for index = 1, #file.roots do
        encode_item(file.roots[index], parts, "\t")
    end

    for index = 1, #file.unknownXmlNodes do
        serialize_node(file.unknownXmlNodes[index], parts, "\t")
    end

    parts[#parts + 1] = "</roblox>"
    return table.concat(parts, "\n")
end

function xml.write_file(file, path, opts)
    local data = xml.write(file, opts)
    local ok, err = util.write_file(path, data)
    if not ok then
        errors.raise("XmlWrite", "failed to write Roblox XML file", {
            path = path,
            reason = err,
        }, 2)
    end
    return true
end

return xml
