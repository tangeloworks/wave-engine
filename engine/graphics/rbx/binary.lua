-- read and write Roblox binary places and models (.rbxl and .rbxm)
-- the layout follows the Rojo rbx-dom binary format specification
-- VALUE_READERS handles known property types; SecurityCapabilities follows its observed layout
-- preserve unknown property chunks in file.preserved.unknownPropChunks for the writer

local constants = require("engine/graphics/rbx/constants")
local dom = require("engine/graphics/rbx/dom")
local errors = require("engine/graphics/rbx/errors")
local util = require("engine/graphics/rbx/util")

local bitops = util.make_bitops()
local band = bitops.band
local bor = bitops.bor
local bxor = bitops.bxor
local lshift = bitops.lshift
local rshift = bitops.rshift

local byte = string.byte
local char = string.char
local concat = table.concat

-- luajit ffi speeds up lz4 decode + float bit-casting, falls back to pure lua without it
local has_ffi, ffi = pcall(require, "ffi")
if has_ffi and type(ffi) ~= "table" then
    has_ffi = false
    ffi = nil
end

local binary = {}
local decompressors = {}

local DATA_TYPES = constants.DATA_TYPES
local TYPE_NAMES_BY_ID = constants.TYPE_NAMES_BY_ID

-- "`END` Chunk": nine bytes, never compressed
local END_MAGIC = "</roblox>"

-- Resource limits for malformed or hostile input. Defaults are far above any real
-- Roblox place: a large test place has 55,087 instances and
-- 74k total, a 30 MB single chunk is roughly 20x the largest chunk observed across
-- the whole shipped corpus. pass opts.limits to override per load
--
-- these exist because a length field is only four bytes to write: an uncompressed
-- length of 0xFFFFFFFF asks for a 4 GB allocation, and nothing previously checked
binary.LIMITS = {
    max_classes = 100000,
    max_instances = 5000000,
    max_chunk_bytes = 32 * 1024 * 1024,       -- compressed payload as read from disk
    max_decompressed_bytes = 256 * 1024 * 1024, -- per chunk, after inflation
}

local Reader = {}
Reader.__index = Reader

local Writer = {}
Writer.__index = Writer

--------------------------------------------------------------------- scalars

local function u32_to_le_bytes(value)
    value = value % 4294967296
    return char(
        band(value, 0xFF),
        band(rshift(value, 8), 0xFF),
        band(rshift(value, 16), 0xFF),
        band(rshift(value, 24), 0xFF)
    )
end

local function u32_to_be_bytes(value)
    value = value % 4294967296
    return char(
        band(rshift(value, 24), 0xFF),
        band(rshift(value, 16), 0xFF),
        band(rshift(value, 8), 0xFF),
        band(value, 0xFF)
    )
end

local function be_bytes_to_u32(bytes)
    local a, b, c, d = byte(bytes, 1, 4)
    return ((a or 0) * 16777216) + ((b or 0) * 65536) + ((c or 0) * 256) + (d or 0)
end

local function le_bytes_to_u32(bytes)
    local a, b, c, d = byte(bytes, 1, 4)
    return (a or 0) + ((b or 0) * 256) + ((c or 0) * 65536) + ((d or 0) * 16777216)
end

-- bit.band / bit.bxor return SIGNED 32-bit results in LuaJIT, so a u64 assembled
-- through them comes out as {hi = -1, lo = -1} where be_bytes_to_u32 would have
-- produced {hi = 4294967295, lo = 4294967295} for the same eight bytes. every
-- hi/lo pair leaving this module is normalised to the unsigned range so the two
-- construction paths agree
local function to_u32(value)
    value = value % 4294967296
    if value < 0 then
        value = value + 4294967296
    end
    return value
end

local function ieee_u32_from_float(value)
    return le_bytes_to_u32(love.data.pack("string", "<f", tonumber(value) or 0))
end

local f32_bitcast = has_ffi and ffi.new("union { uint32_t u; float f; }") or nil
local function float_from_ieee_u32(value)
    if f32_bitcast then
        f32_bitcast.u = value
        return f32_bitcast.f
    end
    return love.data.unpack("<f", u32_to_le_bytes(value))
end

-- "Roblox Float Format": the sign bit is stored AFTER the mantissa,
--   standard  s eeeeeeee mmmmmmmmmmmmmmmmmmmmmmm
--   roblox      eeeeeeee mmmmmmmmmmmmmmmmmmmmmmm s
-- so decoding is a 1-bit right rotate and encoding a 1-bit left rotate
local function rotate_float_decode(value)
    return float_from_ieee_u32(bor(rshift(value, 1), band(lshift(value, 31), 0xFFFFFFFF)))
end

local function rotate_float_encode(value)
    local ieee = ieee_u32_from_float(value)
    return bor(band(lshift(ieee, 1), 0xFFFFFFFF), rshift(ieee, 31))
end

-- "Integer Transformations": transform is (x << 1) ^ (x >> 31),
-- untransform is (x >> 1) ^ -(x & 1)
local function zigzag_decode_u32(value)
    if band(value, 1) == 1 then
        return -math.floor((value + 1) / 2)
    end
    return math.floor(value / 2)
end

local function zigzag_encode_i32(value)
    value = math.floor(tonumber(value) or 0)
    if value < 0 then
        return ((-value) * 2) - 1
    end
    return value * 2
end

local function uint64_shr1(hi, lo)
    return rshift(hi, 1), bor(rshift(lo, 1), lshift(band(hi, 1), 31))
end

local function uint64_shl1(hi, lo)
    return band(bor(lshift(hi, 1), rshift(lo, 31)), 0xFFFFFFFF), band(lshift(lo, 1), 0xFFFFFFFF)
end

local function uint64_not(hi, lo)
    return bxor(hi, 0xFFFFFFFF), bxor(lo, 0xFFFFFFFF)
end

local function i64_negative(value)
    return type(value) == "table" and value.signed ~= false and band(value.hi or 0, 0x80000000) ~= 0
end

local function make_i64(hi, lo, signed)
    return dom.make_i64(to_u32(hi), to_u32(lo), signed)
end

-- 64-bit form of the same transform, with 63 in place of 31
local function zigzag_decode_i64(hi, lo)
    local out_hi, out_lo = uint64_shr1(hi, lo)
    if band(lo, 1) == 1 then
        out_hi, out_lo = uint64_not(out_hi, out_lo)
    end
    return make_i64(out_hi, out_lo, true)
end

local function zigzag_encode_i64(value)
    local hi = value and value.hi or 0
    local lo = value and value.lo or 0
    local out_hi, out_lo = uint64_shl1(hi, lo)
    if i64_negative(value) then
        out_hi, out_lo = uint64_not(out_hi, out_lo)
    end
    return out_hi, out_lo
end

local function i64_to_be_bytes(value, transformed)
    local hi = value and value.hi or 0
    local lo = value and value.lo or 0
    if transformed then
        hi, lo = zigzag_encode_i64(value)
    end
    return u32_to_be_bytes(hi) .. u32_to_be_bytes(lo)
end

local function be_bytes_to_i64(bytes, transformed, signed)
    local hi = be_bytes_to_u32(bytes:sub(1, 4))
    local lo = be_bytes_to_u32(bytes:sub(5, 8))
    if transformed then
        return zigzag_decode_i64(hi, lo)
    end
    return make_i64(hi, lo, signed ~= false)
end

---------------------------------------------------------------------- Reader

function Reader.new(data, path)
    return setmetatable({
        data = data or "",
        pos = 1,
        len = #(data or ""),
        path = path,
    }, Reader)
end

function Reader:remaining()
    return self.len - self.pos + 1
end

function Reader:tell()
    return self.pos - 1
end

function Reader:require_bytes(count)
    if self:remaining() < count then
        errors.raise("BinaryTruncated", "unexpected end of buffer", {
            path = self.path,
            offset = self:tell(),
            need = count,
            have = self:remaining(),
        }, 2)
    end
end

function Reader:read_bytes(count)
    self:require_bytes(count)
    local first = self.pos
    self.pos = self.pos + count
    return self.data:sub(first, self.pos - 1)
end

function Reader:skip(count)
    self:require_bytes(count)
    self.pos = self.pos + count
end

function Reader:read_u8()
    self:require_bytes(1)
    local value = byte(self.data, self.pos) or 0
    self.pos = self.pos + 1
    return value
end

function Reader:read_bool()
    return self:read_u8() ~= 0
end

function Reader:read_u16le()
    local a = self:read_u8()
    local b = self:read_u8()
    return a + (b * 256)
end

function Reader:read_i16le()
    local value = self:read_u16le()
    return value >= 0x8000 and (value - 0x10000) or value
end

function Reader:read_u32le()
    return le_bytes_to_u32(self:read_bytes(4))
end

function Reader:read_i32le()
    local value = self:read_u32le()
    return value >= 2147483648 and (value - 4294967296) or value
end

function Reader:read_f32le()
    self:require_bytes(4)
    local value
    value, self.pos = love.data.unpack("<f", self.data, self.pos)
    return value
end

function Reader:read_f64le()
    self:require_bytes(8)
    local value
    value, self.pos = love.data.unpack("<d", self.data, self.pos)
    return value
end

-- "String": u32 length prefix (untransformed, little endian) then raw bytes
function Reader:read_string()
    local length = self:read_u32le()
    return length > 0 and self:read_bytes(length) or ""
end

---------------------------------------------------------------------- Writer

function Writer.new()
    return setmetatable({ parts = {} }, Writer)
end

function Writer:put_bytes(bytes)
    self.parts[#self.parts + 1] = bytes
end

function Writer:put_u8(value)
    self:put_bytes(char(band(value or 0, 0xFF)))
end

function Writer:put_bool(value)
    self:put_u8(value and 1 or 0)
end

function Writer:put_u16le(value)
    value = value or 0
    self:put_bytes(char(band(value, 0xFF), band(rshift(value, 8), 0xFF)))
end

function Writer:put_i16le(value)
    if value < 0 then
        value = 0x10000 + value
    end
    self:put_u16le(value)
end

function Writer:put_u32le(value)
    self:put_bytes(u32_to_le_bytes(value or 0))
end

function Writer:put_i32le(value)
    if value < 0 then
        value = 4294967296 + value
    end
    self:put_u32le(value)
end

function Writer:put_f32le(value)
    self:put_bytes(love.data.pack("string", "<f", tonumber(value) or 0))
end

function Writer:put_f64le(value)
    self:put_bytes(love.data.pack("string", "<d", tonumber(value) or 0))
end

function Writer:put_string(value)
    value = value or ""
    self:put_u32le(#value)
    self:put_bytes(value)
end

function Writer:to_string()
    return concat(self.parts)
end

------------------------------------------------------------- byte interleaving
--
-- "Byte Interleaving": an array of N items of W bytes is stored as W columns of
-- N bytes -- all the first bytes, then all the second bytes, and so on
--
-- every reader below is a small loop over string.byte offsets. the generic
-- column-slicing form allocates N*W one-character substrings plus a table.concat
-- per item, which on a 55k-instance place (~1.2M property values) dominated
-- parse time and GC. Loop bodies are kept short on purpose: an oversized body
-- gets JIT-blacklisted and silently runs interpreted

local function read_interleaved_u32_array(reader, count)
    local blob = reader:read_bytes(count * 4)
    local c1, c2, c3 = count, count * 2, count * 3
    local out = {}
    for row = 1, count do
        out[row] = byte(blob, row) * 16777216
            + byte(blob, c1 + row) * 65536
            + byte(blob, c2 + row) * 256
            + byte(blob, c3 + row)
    end
    return out
end

local function read_interleaved_i32_array(reader, count)
    local raw = read_interleaved_u32_array(reader, count)
    for index = 1, count do
        raw[index] = zigzag_decode_u32(raw[index])
    end
    return raw
end

local function read_interleaved_float_array(reader, count)
    local raw = read_interleaved_u32_array(reader, count)
    for index = 1, count do
        raw[index] = rotate_float_decode(raw[index])
    end
    return raw
end

local function read_interleaved_byte_array(reader, count)
    local raw = reader:read_bytes(count)
    local out = {}
    for index = 1, count do
        out[index] = byte(raw, index) or 0
    end
    return out
end

---reads `count` interleaved 8-byte items as big-endian (hi, lo) u32 pairs
local function read_interleaved_u64_arrays(reader, count)
    local blob = reader:read_bytes(count * 8)
    local c1, c2, c3 = count, count * 2, count * 3
    local c4, c5, c6, c7 = count * 4, count * 5, count * 6, count * 7
    local his, los = {}, {}
    for row = 1, count do
        his[row] = byte(blob, row) * 16777216 + byte(blob, c1 + row) * 65536
            + byte(blob, c2 + row) * 256 + byte(blob, c3 + row)
        los[row] = byte(blob, c4 + row) * 16777216 + byte(blob, c5 + row) * 65536
            + byte(blob, c6 + row) * 256 + byte(blob, c7 + row)
    end
    return his, los
end

---reads `count` interleaved 16-byte items, returning them de-interleaved
local function read_interleaved_bytes16(reader, count)
    local blob = reader:read_bytes(count * 16)
    local c01, c02, c03, c04 = count, count * 2, count * 3, count * 4
    local c05, c06, c07, c08 = count * 5, count * 6, count * 7, count * 8
    local c09, c10, c11, c12 = count * 9, count * 10, count * 11, count * 12
    local c13, c14, c15 = count * 13, count * 14, count * 15
    local out = {}
    for row = 1, count do
        out[row] = char(
            byte(blob, row), byte(blob, c01 + row), byte(blob, c02 + row), byte(blob, c03 + row),
            byte(blob, c04 + row), byte(blob, c05 + row), byte(blob, c06 + row), byte(blob, c07 + row),
            byte(blob, c08 + row), byte(blob, c09 + row), byte(blob, c10 + row), byte(blob, c11 + row),
            byte(blob, c12 + row), byte(blob, c13 + row), byte(blob, c14 + row), byte(blob, c15 + row))
    end
    return out
end

--- de-interleave values whose byte width is known only at runtime
local function read_interleaved_items(reader, count, item_size)
    if item_size == 8 then
        local his, los = read_interleaved_u64_arrays(reader, count)
        local out = {}
        for index = 1, count do
            out[index] = u32_to_be_bytes(his[index]) .. u32_to_be_bytes(los[index])
        end
        return out
    end
    if item_size == 16 then
        return read_interleaved_bytes16(reader, count)
    end
    local blob = reader:read_bytes(count * item_size)
    local out = {}
    for row = 0, count - 1 do
        local parts = {}
        for column = 0, item_size - 1 do
            local index = (column * count) + row + 1
            parts[#parts + 1] = blob:sub(index, index)
        end
        out[row + 1] = concat(parts)
    end
    return out
end

local function write_interleaved_items(items, item_size)
    local columns = {}
    for column = 1, item_size do
        local parts = {}
        for index = 1, #items do
            parts[#parts + 1] = items[index]:sub(column, column)
        end
        columns[#columns + 1] = concat(parts)
    end
    return concat(columns)
end

local function write_interleaved_u32_array(writer, values)
    local items = {}
    for index = 1, #values do
        items[index] = u32_to_be_bytes(values[index] or 0)
    end
    writer:put_bytes(write_interleaved_items(items, 4))
end

local function write_interleaved_i32_array(writer, values)
    local raw = {}
    for index = 1, #values do
        raw[index] = zigzag_encode_i32(values[index] or 0)
    end
    write_interleaved_u32_array(writer, raw)
end

local function write_interleaved_float_array(writer, values)
    local raw = {}
    for index = 1, #values do
        raw[index] = rotate_float_encode(values[index] or 0)
    end
    write_interleaved_u32_array(writer, raw)
end

local function write_interleaved_byte_array(writer, values)
    local parts = {}
    for index = 1, #values do
        parts[index] = char(band(values[index] or 0, 0xFF))
    end
    writer:put_bytes(concat(parts))
end

-- "Referent": an Int32 array, additionally stored as deltas -- the actual value
-- of each referent is the read value plus every value before it
local function read_referent_array(reader, count)
    local deltas = read_interleaved_i32_array(reader, count)
    local out = {}
    local current = 0
    for index = 1, count do
        current = current + deltas[index]
        out[index] = current
    end
    return out
end

local function write_referent_array(writer, referents)
    local deltas = {}
    local previous = 0
    for index = 1, #referents do
        deltas[index] = (referents[index] or -1) - previous
        previous = referents[index] or -1
    end
    write_interleaved_i32_array(writer, deltas)
end

------------------------------------------------------------------ compression

-- ffi fast path: fixed buffer + memcpy, the 1-char-per-byte lua path dominated .rbxl parse time
-- overlapping back-refs must copy byte-forward (lz4 semantics), non-overlapping use ffi.copy
local function decode_lz4_raw_ffi(block, expected_size)
    local src = ffi.cast("const uint8_t*", block)
    local src_len = #block
    local dst = ffi.new("uint8_t[?]", expected_size)
    local in_pos = 0
    local out_pos = 0

    while in_pos < src_len do
        local token = src[in_pos]
        in_pos = in_pos + 1
        local literal_len = rshift(token, 4)
        if literal_len == 15 then
            while in_pos < src_len do
                local ext = src[in_pos]
                in_pos = in_pos + 1
                literal_len = literal_len + ext
                if ext ~= 255 then
                    break
                end
            end
        end

        if literal_len > 0 then
            if in_pos + literal_len > src_len then
                literal_len = src_len - in_pos
            end
            if out_pos + literal_len > expected_size then
                literal_len = expected_size - out_pos
            end
            if literal_len > 0 then
                ffi.copy(dst + out_pos, src + in_pos, literal_len)
                in_pos = in_pos + literal_len
                out_pos = out_pos + literal_len
            end
        end

        if in_pos >= src_len then
            break
        end

        local offset = src[in_pos] + src[in_pos + 1] * 256
        in_pos = in_pos + 2
        if offset <= 0 or offset > out_pos then
            break
        end

        local match_len = band(token, 0x0F) + 4
        if band(token, 0x0F) == 15 then
            while in_pos < src_len do
                local ext = src[in_pos]
                in_pos = in_pos + 1
                match_len = match_len + ext
                if ext ~= 255 then
                    break
                end
            end
        end

        if out_pos + match_len > expected_size then
            match_len = expected_size - out_pos
        end
        local match_pos = out_pos - offset
        if offset >= match_len then
            ffi.copy(dst + out_pos, dst + match_pos, match_len)
            out_pos = out_pos + match_len
        else
            for k = 0, match_len - 1 do
                dst[out_pos + k] = dst[match_pos + k]
            end
            out_pos = out_pos + match_len
        end
    end

    return ffi.string(dst, out_pos)
end

local function decode_lz4_raw(block, expected_size)
    if has_ffi and expected_size and expected_size > 0 then
        local ok, decoded = pcall(decode_lz4_raw_ffi, block, expected_size)
        if ok and decoded then
            if #decoded ~= expected_size then
                errors.raise("BinaryCompression", "LZ4 size mismatch", {
                    expected = expected_size,
                    actual = #decoded,
                }, 2)
            end
            return decoded
        end
    end

    local in_pos = 1
    local out = {}
    local out_len = 0

    local function push_byte(value)
        out_len = out_len + 1
        out[out_len] = char(value)
    end

    local function output_byte(index)
        local chunk = out[index]
        return chunk and byte(chunk, 1) or 0
    end

    while in_pos <= #block do
        local token = byte(block, in_pos) or 0
        in_pos = in_pos + 1
        local literal_len = rshift(token, 4)
        if literal_len == 15 then
            while in_pos <= #block do
                local ext = byte(block, in_pos) or 0
                in_pos = in_pos + 1
                literal_len = literal_len + ext
                if ext ~= 255 then
                    break
                end
            end
        end

        for _ = 1, literal_len do
            if in_pos > #block then
                break
            end
            push_byte(byte(block, in_pos) or 0)
            in_pos = in_pos + 1
        end

        if in_pos > #block then
            break
        end

        local offset = (byte(block, in_pos) or 0) + ((byte(block, in_pos + 1) or 0) * 256)
        in_pos = in_pos + 2
        if offset <= 0 then
            break
        end

        local match_len = band(token, 0x0F) + 4
        if band(token, 0x0F) == 15 then
            while in_pos <= #block do
                local ext = byte(block, in_pos) or 0
                in_pos = in_pos + 1
                match_len = match_len + ext
                if ext ~= 255 then
                    break
                end
            end
        end

        for _ = 1, match_len do
            push_byte(output_byte(out_len - offset + 1))
        end
    end

    local decoded = concat(out)
    if expected_size and #decoded ~= expected_size then
        errors.raise("BinaryCompression", "LZ4 size mismatch", {
            expected = expected_size,
            actual = #decoded,
        }, 2)
    end
    return decoded
end

function binary.register_decompressor(kind, fn)
    decompressors[kind] = fn
end

-- "Chunks": a compressed body starting with 28 b5 2f fd is ZSTD, anything else LZ4
local function detect_compression(raw_payload)
    if #raw_payload >= 4 then
        local a, b, c, d = byte(raw_payload, 1, 4)
        if a == 0x28 and b == 0xB5 and c == 0x2F and d == 0xFD then
            return "zstd"
        end
    end
    return "lz4_raw"
end

local function decode_chunk_payload(raw_payload, compressed_length, uncompressed_length)
    if compressed_length == 0 then
        return raw_payload, "none"
    end

    local compression = detect_compression(raw_payload)
    local decoder = decompressors[compression]
    if decoder then
        return decoder(raw_payload, uncompressed_length), compression
    end

    if compression == "lz4_raw" then
        return decode_lz4_raw(raw_payload, uncompressed_length), compression
    end

    errors.raise("BinaryCompression", "missing chunk decompressor backend", {
        compression = compression,
        compressedLength = compressed_length,
        uncompressedLength = uncompressed_length,
    }, 2)
end

----------------------------------------------------------------- value readers
--
-- each reader takes (reader, count, ctx) and returns an array of `count` dom
-- values, or nil when the payload cannot be represented (which the caller turns
-- into a warning plus a verbatim copy of the chunk)
--
-- ctx carries { file, chunk, classId, className, propertyName, typeId } plus a
-- warn() helper, so a decoder that has to make a recovery decision says so rather
-- than quietly producing wrong values

local function make_value(type_name, value)
    return { type = type_name, value = value }
end

local function make_value_extra(type_name, value, extra)
    return dom.value(type_name, value, extra)
end

local VALUE_READERS = {}

-- "String" (0x01): length-prefixed bytes, stored in sequence
VALUE_READERS[DATA_TYPES.String] = function(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("String", reader:read_string())
    end
    return values
end

-- "Bytecode" (0x1d): stored identically to String, but holds precompiled Luau
-- never interpreted -- the spec is explicit that implementations should read and
-- write this data as-is
VALUE_READERS[DATA_TYPES.Bytecode] = function(reader, count)
    local values = {}
    for index = 1, count do
        local raw_bytes = reader:read_string()
        values[index] = make_value_extra("Bytecode", raw_bytes, {
            rawBytes = raw_bytes,
            compressedBytes = raw_bytes,
            byteLength = #raw_bytes,
            compression = "preserved",
        })
    end
    return values
end

-- "Bool" (0x02): one byte per value, in sequence
VALUE_READERS[DATA_TYPES.Bool] = function(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Bool", reader:read_u8() ~= 0)
    end
    return values
end

-- "Int32" (0x03): big-endian, transformed, interleaved
VALUE_READERS[DATA_TYPES.Int32] = function(reader, count)
    local ints = read_interleaved_i32_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Int32", ints[index])
    end
    return values
end

-- "Float32" (0x04): Roblox float format, big-endian, interleaved
VALUE_READERS[DATA_TYPES.Float32] = function(reader, count)
    local numbers = read_interleaved_float_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Float32", numbers[index])
    end
    return values
end

-- "Float64" (0x05): IEEE-754 little-endian, in sequence, untransformed
VALUE_READERS[DATA_TYPES.Float64] = function(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Float64", reader:read_f64le())
    end
    return values
end

-- "UDim" (0x06): a Float32 array (Scale) then an Int32 array (Offset)
VALUE_READERS[DATA_TYPES.UDim] = function(reader, count)
    local scales = read_interleaved_float_array(reader, count)
    local offsets = read_interleaved_i32_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("UDim", { scale = scales[index], offset = offsets[index] })
    end
    return values
end

-- "UDim2" (0x07): four arrays, in the order X.Scale, Y.Scale, X.Offset, Y.Offset
VALUE_READERS[DATA_TYPES.UDim2] = function(reader, count)
    local xs = read_interleaved_float_array(reader, count)
    local ys = read_interleaved_float_array(reader, count)
    local xo = read_interleaved_i32_array(reader, count)
    local yo = read_interleaved_i32_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("UDim2", {
            x = { scale = xs[index], offset = xo[index] },
            y = { scale = ys[index], offset = yo[index] },
        })
    end
    return values
end

-- "Ray" (0x08): six little-endian f32 (origin xyz then direction xyz), in order,
-- with no transformation or interleaving
VALUE_READERS[DATA_TYPES.Ray] = function(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Ray", {
            origin = { x = reader:read_f32le(), y = reader:read_f32le(), z = reader:read_f32le() },
            direction = { x = reader:read_f32le(), y = reader:read_f32le(), z = reader:read_f32le() },
        })
    end
    return values
end

-- "Faces" (0x09): one byte per value, low 6 bits, no transformation or
-- interleaving
--
-- the numeric bitfield stays as `.value` because callers read it directly
-- (runtime/common.lua passes Faces/Axes through unchanged), the decoded flags
-- ride alongside so nothing downstream has to re-derive the bit order
--
-- BIT ORDER lives in dom.lua, shared with the XML reader so the two cannot
-- disagree, and follows Enum.NormalId (Right=0 ... Front=5). it was inverted here
-- (front at bit 0): xml.md:358-363 gives Front|Left|Top = 42, and 42 = bits 1,3,5,
-- which is Top|Left|Front only under the NormalId numbering
local FACE_BIT_NAMES = dom.FACE_BIT_NAMES
local AXIS_BIT_NAMES = dom.AXIS_BIT_NAMES

VALUE_READERS[DATA_TYPES.Faces] = function(reader, count)
    local values = {}
    for index = 1, count do
        local bits = reader:read_u8()
        values[index] = make_value_extra("Faces", bits, dom.face_flags(bits))
    end
    return values
end

-- "Axes" (0x0a): one byte per value, low 3 bits = X, Y, Z (Enum.Axis numbering)
VALUE_READERS[DATA_TYPES.Axes] = function(reader, count)
    local values = {}
    for index = 1, count do
        local bits = reader:read_u8()
        values[index] = make_value_extra("Axes", bits, dom.axis_flags(bits))
    end
    return values
end

-- "BrickColor" (0x0b): untransformed big-endian u32, interleaved
VALUE_READERS[DATA_TYPES.BrickColor] = function(reader, count, ctx)
    local raw = read_interleaved_u32_array(reader, count)
    local values = {}
    local property_name = ctx and ctx.propertyName
    for index = 1, count do
        values[index] = make_value_extra("BrickColor", raw[index], { propertyName = property_name })
    end
    return values
end

-- "Enum" (0x12): untransformed big-endian u32, interleaved. same storage as
-- BrickColor, kept separate so the dom value carries the right type name
VALUE_READERS[DATA_TYPES.Enum] = function(reader, count, ctx)
    local raw = read_interleaved_u32_array(reader, count)
    local values = {}
    local property_name = ctx and ctx.propertyName
    for index = 1, count do
        values[index] = make_value_extra("Enum", raw[index], { propertyName = property_name })
    end
    return values
end

-- "Color3" (0x0c): three Float32 arrays, R then G then B
VALUE_READERS[DATA_TYPES.Color3] = function(reader, count)
    local r = read_interleaved_float_array(reader, count)
    local g = read_interleaved_float_array(reader, count)
    local b = read_interleaved_float_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Color3", { r = r[index], g = g[index], b = b[index] })
    end
    return values
end

-- "Vector2" (0x0d): two Float32 arrays
VALUE_READERS[DATA_TYPES.Vector2] = function(reader, count)
    local x = read_interleaved_float_array(reader, count)
    local y = read_interleaved_float_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Vector2", { x = x[index], y = y[index] })
    end
    return values
end

-- "Vector3" (0x0e): three Float32 arrays
VALUE_READERS[DATA_TYPES.Vector3] = function(reader, count)
    local x = read_interleaved_float_array(reader, count)
    local y = read_interleaved_float_array(reader, count)
    local z = read_interleaved_float_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Vector3", { x = x[index], y = y[index], z = z[index] })
    end
    return values
end

-- "CFrame" (0x10): per value an orientation ID byte, then nine raw IEEE f32 only
-- when that ID is 0x00, afterwards one Vector3 array holding every position
--
-- the ID is NOT a free-form byte: 0x00 means "nine floats follow", and the 24
-- documented IDs mean "no floats follow, use this rotation". any other value is
-- undefined. Treating an undefined ID as if it were 0x00 -- which is what an
-- `if special[id] then ... else read nine floats end` fallthrough does -- consumes
-- 36 bytes that are not there and desynchronises every subsequent value in the
-- chunk, silently and unrecoverably. Unknown IDs are therefore reported and
-- treated as "no floats follow", which keeps the stream aligned, the
-- leftover-byte check in check_fully_consumed is the backstop if that assumption
-- is ever wrong for a future ID
--
-- all 154 CFrame chunks in the shipped corpus use only 0x00 and the 24 documented
-- IDs, so this path is defensive rather than corrective -- but it is the
-- difference between one bad property and a corrupt chunk
local CFRAME_SPECIAL = constants.CFRAME_SPECIAL_ORIENTATIONS

local function read_cframe_orientations(reader, count, ctx)
    local orientations = {}
    local unknown_ids = nil
    for index = 1, count do
        local orient_id = reader:read_u8()
        if orient_id == 0 then
            orientations[index] = {
                reader:read_f32le(), reader:read_f32le(), reader:read_f32le(),
                reader:read_f32le(), reader:read_f32le(), reader:read_f32le(),
                reader:read_f32le(), reader:read_f32le(), reader:read_f32le(),
            }
        else
            local m = CFRAME_SPECIAL[orient_id]
            if m then
                orientations[index] = { m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9] }
            else
                orientations[index] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
                unknown_ids = unknown_ids or {}
                unknown_ids[orient_id] = (unknown_ids[orient_id] or 0) + 1
            end
        end
    end
    if unknown_ids and ctx and ctx.warn then
        local seen = {}
        for id, hits in pairs(unknown_ids) do
            seen[#seen + 1] = string.format("0x%02X x%d", id, hits)
        end
        table.sort(seen)
        ctx.warn("UnknownCFrameOrientationId",
            "CFrame used an orientation id outside the 24 documented cases; "
            .. "decoded as identity with no inline rotation matrix so the stream stays aligned", {
                orientationIds = concat(seen, ", "),
            })
    end
    return orientations
end

local function read_cframe_array(reader, count, ctx)
    local orientations = read_cframe_orientations(reader, count, ctx)
    local x = read_interleaved_float_array(reader, count)
    local y = read_interleaved_float_array(reader, count)
    local z = read_interleaved_float_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("CFrame", {
            position = { x = x[index], y = y[index], z = z[index] },
            orientation = orientations[index],
        })
    end
    return values
end

VALUE_READERS[DATA_TYPES.CFrame] = read_cframe_array

-- "Referent" (0x13): a delta-accumulated Int32 array, -1 is the null referent,
-- which in a PROP chunk means "property with no set value"
VALUE_READERS[DATA_TYPES.Referent] = function(reader, count)
    local referents = read_referent_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Referent", referents[index])
    end
    return values
end

-- "Vector3int16" (0x14): three little-endian i16, in sequence, no interleaving
VALUE_READERS[DATA_TYPES.Vector3int16] = function(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Vector3int16", {
            x = reader:read_i16le(),
            y = reader:read_i16le(),
            z = reader:read_i16le(),
        })
    end
    return values
end

-- "NumberSequence" (0x15): u32 keypoint count, then (time, value, envelope) f32
-- triples. Little-endian, in sequence, no interleaving
VALUE_READERS[DATA_TYPES.NumberSequence] = function(reader, count)
    local values = {}
    for index = 1, count do
        local keypoint_count = reader:read_u32le()
        local keypoints = {}
        for key_index = 1, keypoint_count do
            keypoints[key_index] = {
                time = reader:read_f32le(),
                value = reader:read_f32le(),
                envelope = reader:read_f32le(),
            }
        end
        values[index] = make_value("NumberSequence", keypoints)
    end
    return values
end

-- "ColorSequence" (0x16): u32 keypoint count, then (time, r, g, b, envelope) f32
-- quintuples. the envelope is serialised but unused by Roblox, it is preserved
VALUE_READERS[DATA_TYPES.ColorSequence] = function(reader, count)
    local values = {}
    for index = 1, count do
        local keypoint_count = reader:read_u32le()
        local keypoints = {}
        for key_index = 1, keypoint_count do
            keypoints[key_index] = {
                time = reader:read_f32le(),
                color = { r = reader:read_f32le(), g = reader:read_f32le(), b = reader:read_f32le() },
                envelope = reader:read_f32le(),
            }
        end
        values[index] = make_value("ColorSequence", keypoints)
    end
    return values
end

-- "NumberRange" (0x17): two little-endian f32, in sequence
VALUE_READERS[DATA_TYPES.NumberRange] = function(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("NumberRange", { min = reader:read_f32le(), max = reader:read_f32le() })
    end
    return values
end

-- "Rect" (0x18): four Float32 arrays, Min.X, Min.Y, Max.X, Max.Y
VALUE_READERS[DATA_TYPES.Rect] = function(reader, count)
    local min_x = read_interleaved_float_array(reader, count)
    local min_y = read_interleaved_float_array(reader, count)
    local max_x = read_interleaved_float_array(reader, count)
    local max_y = read_interleaved_float_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Rect", {
            min = { x = min_x[index], y = min_y[index] },
            max = { x = max_x[index], y = max_y[index] },
        })
    end
    return values
end

-- "PhysicalProperties" (0x19)
--
-- the leading byte is a TWO-BIT field, not an enum of {0,1,2,3} sharing one
-- layout:
--   bit0 = a CustomPhysicalProperties struct follows
--   bit1 = that struct carries a SIXTH f32, AcousticAbsorption
-- so a record is 1 byte, or 21 bytes, or 25 bytes
--
-- Reading a fixed five floats desynchronised the stream by 4 bytes after every
-- flag-3 record, and because the trailing AcousticAbsorption bytes were then
-- re-read as the next flag byte the corruption cascaded. on a large test place
-- that was 1081 of 28965 parts: 524 with no custom properties received density
-- 50.0 scavenged from misaligned float bytes (71x their correct mass), and 557
-- lost their real density. Old saves only ever use flags 0/1, which is why this
-- went unnoticed for so long
--
-- derived empirically here first, later confirmed verbatim by the rbx-dom spec
-- Flag 2 (has AcousticAbsorption, no custom struct) carries no floats at all
-- when bit1 is clear the spec says AcousticAbsorption may be assumed to be 1.0;
-- it is left nil so callers can tell "absent" from "authored as 1.0"
VALUE_READERS[DATA_TYPES.PhysicalProperties] = function(reader, count)
    local values = {}
    for index = 1, count do
        local flag = reader:read_u8()
        if band(flag, 1) ~= 0 then
            local density = reader:read_f32le()
            local friction = reader:read_f32le()
            local elasticity = reader:read_f32le()
            local friction_weight = reader:read_f32le()
            local elasticity_weight = reader:read_f32le()
            local acoustic_absorption = nil
            if band(flag, 2) ~= 0 then
                acoustic_absorption = reader:read_f32le()
            end
            values[index] = make_value("PhysicalProperties", {
                density = density,
                friction = friction,
                elasticity = elasticity,
                friction_weight = friction_weight,
                elasticity_weight = elasticity_weight,
                acoustic_absorption = acoustic_absorption,
            })
        else
            values[index] = make_value_extra("PhysicalProperties", nil, { none = true })
        end
    end
    return values
end

-- "Color3uint8" (0x1a): three byte arrays, R then G then B, untransformed
VALUE_READERS[DATA_TYPES.Color3uint8] = function(reader, count)
    local r = read_interleaved_byte_array(reader, count)
    local g = read_interleaved_byte_array(reader, count)
    local b = read_interleaved_byte_array(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Color3uint8", {
            r = r[index] / 255, g = g[index] / 255, b = b[index] / 255,
        })
    end
    return values
end

-- "Int64" (0x1b): big-endian, transformed, interleaved
VALUE_READERS[DATA_TYPES.Int64] = function(reader, count)
    local his, los = read_interleaved_u64_arrays(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Int64", zigzag_decode_i64(his[index], los[index]))
    end
    return values
end

-- SecurityCapabilities (0x21) is NOT described in binary.md, yet 596 chunks in
-- the shipped corpus carry it -- one per class in every place saved by a modern
-- Studio, so it cannot simply be skipped. it is stored like Int64 minus the
-- integer transformation: an interleaved big-endian u64 capability bitmask
--
-- Byte-exact consumption across all eight maps is the only evidence for that
-- layout, and every observed value is 0. the value semantics are unverified, so
-- it is carried through as an opaque u64 rather than interpreted
VALUE_READERS[DATA_TYPES.SecurityCapabilities] = function(reader, count)
    local his, los = read_interleaved_u64_arrays(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("SecurityCapabilities", make_i64(his[index], los[index], false))
    end
    return values
end

-- "SharedString" (0x1c): interleaved big-endian u32 indices into the SSTR table
-- `NetAssetRef` properties use the same type ID and storage
VALUE_READERS[DATA_TYPES.SharedString] = function(reader, count, ctx)
    local ids = read_interleaved_u32_array(reader, count)
    local file = ctx and ctx.file
    local shared_strings = (file and file.sharedStrings) or {}
    local values = {}
    local missing = 0
    for index = 1, count do
        local id = ids[index] or 0
        local shared = shared_strings[id + 1]
        if not shared then
            missing = missing + 1
        end
        values[index] = make_value("SharedString", {
            index = id,
            md5 = shared and shared.md5 or nil,
            value = shared and shared.value or "",
        })
    end
    if missing > 0 and ctx and ctx.warn then
        -- Previously silent: a SharedString pointing past the end of the SSTR
        -- table produced an empty string with no indication that a value had
        -- been lost
        ctx.warn("SharedStringIndexOutOfRange",
            "SharedString property referenced an index with no SSTR entry", {
                missing = missing,
                sharedStringCount = #shared_strings,
            })
    end
    return values
end

-- "OptionalCoordinateFrame" (0x1e): the CFrame type ID (0x10), then a CFrame
-- array, then the Bool type ID (0x02), then one Bool per value saying whether it
-- has a value. a valueless entry is written as the identity CFrame with a false
-- flag, so the bool array is the only thing that distinguishes them
VALUE_READERS[DATA_TYPES.OptionalCFrame] = function(reader, count, ctx)
    local nested_type = reader:read_u8()
    if nested_type ~= DATA_TYPES.CFrame then
        if ctx and ctx.warn then
            ctx.warn("MalformedOptionalCFrame",
                "OptionalCoordinateFrame did not begin with the CFrame type id", {
                    expectedTypeId = DATA_TYPES.CFrame,
                    actualTypeId = nested_type,
                })
        end
        return nil
    end

    local cframes = read_cframe_array(reader, count, ctx)

    local flag_type = reader:read_u8()
    if flag_type ~= DATA_TYPES.Bool then
        if ctx and ctx.warn then
            ctx.warn("MalformedOptionalCFrame",
                "OptionalCoordinateFrame did not end with the Bool type id", {
                    expectedTypeId = DATA_TYPES.Bool,
                    actualTypeId = flag_type,
                })
        end
        return nil
    end

    local values = {}
    for index = 1, count do
        if reader:read_u8() ~= 0 then
            values[index] = make_value("OptionalCFrame", cframes[index].value)
        else
            values[index] = make_value_extra("OptionalCFrame", nil, { none = true })
        end
    end
    return values
end

-- "UniqueId" (0x1f): interleaved 16-byte records laid out
--   index  u32   bytes 0-3
--   Time   u32   bytes 4-7    (seconds since 2021-01-01)
--   Random i64   bytes 8-15
-- big-endian, in that order, with no transformation
--
-- FIELD ORDER is load-bearing and was previously inverted -- the old decoder
-- reported Index where Time belongs and vice versa. Measured, not inferred:
-- Classic-Crossroads stores 000008e5 09dc3b56 5f2db3c95775d646, and the SAME
-- place in .rbxlx stores 2f96d9e4abbaeb23 09dc3b56 000008e5. xml.md documents the
-- XML layout as Random / Time / Index, which pins 09dc3b56 as the Time
-- (165,428,054 s after 2021-01-01 = mid-2026, the save date, identical for every
-- instance in the file) and 000008e5 as the Index (2277, and per-instance)
--
-- the old decoder also zigzag-untransformed Random. the spec says the struct is
-- stored "with no modifications", and the two agreed only because the sampled low
-- bit happened to be 0 -- for an odd value zigzag yields a negated number where a
-- rotate yields a large positive one. the XML form of the SAME id is this value
-- rotated RIGHT one bit (measured on the pair above), which is why xml.md warns
-- that the component differs between formats, uniqueid_random_from_xml() below
-- converts
VALUE_READERS[DATA_TYPES.UniqueId] = function(reader, count)
    local items = read_interleaved_bytes16(reader, count)
    local values = {}
    for index = 1, count do
        local raw = items[index]
        local i1, i2, i3, i4, t1, t2, t3, t4 = byte(raw, 1, 8)
        local r1, r2, r3, r4, r5, r6, r7, r8 = byte(raw, 9, 16)
        values[index] = make_value_extra("UniqueId", {
            index = i1 * 16777216 + i2 * 65536 + i3 * 256 + i4,
            time = t1 * 16777216 + t2 * 65536 + t3 * 256 + t4,
            random = make_i64(
                r1 * 16777216 + r2 * 65536 + r3 * 256 + r4,
                r5 * 16777216 + r6 * 65536 + r7 * 256 + r8, true),
        }, {
            rawBytes = raw,
        })
    end
    return values
end

-- "Font" (0x20): Family string, u16 Weight, u8 Style, CachedFaceId string
-- Weight and Style are little-endian unsigned integers. CachedFaceId is always
-- present but may be empty (XML omits it in that case)
VALUE_READERS[DATA_TYPES.Font] = function(reader, count)
    local values = {}
    for index = 1, count do
        values[index] = make_value("Font", {
            family = reader:read_string(),
            weight = reader:read_u16le(),
            style = reader:read_u8(),
            cachedFaceId = reader:read_string(),
        })
    end
    return values
end

-- Content (0x22) stores a SourceTypes array followed by separate payloads for each kind
-- read the type IDs as unsigned, interleaved big-endian values
-- signed integer decoding would turn Uri (1) into -1 and Object (2) into 1
local CONTENT_SOURCE_NONE = 0
local CONTENT_SOURCE_URI = 1
local CONTENT_SOURCE_OBJECT = 2
-- ExternalObject has no documented SourceTypes value, the spec only says the
-- external referent array exists and "is not applicable to implementors". 3 is
-- accepted for it because it is the only unused slot and the array would
-- otherwise be unreachable. Flagged as unverified rather than asserted
local CONTENT_SOURCE_EXTERNAL_OBJECT = 3

VALUE_READERS[DATA_TYPES.Content] = function(reader, count, ctx)
    local source_types = read_interleaved_u32_array(reader, count)

    local uri_count = reader:read_u32le()
    local uris = {}
    for index = 1, uri_count do
        uris[index] = reader:read_string()
    end

    local object_count = reader:read_u32le()
    local object_refs = read_referent_array(reader, object_count)

    local external_count = reader:read_u32le()
    local external_refs = read_referent_array(reader, external_count)

    local values = {}
    local uri_index, object_index, external_index = 1, 1, 1
    local unknown_source_types = 0
    for index = 1, count do
        local source_type = source_types[index] or CONTENT_SOURCE_NONE
        if source_type == CONTENT_SOURCE_URI then
            values[index] = make_value("Content", { sourceType = "Uri", uri = uris[uri_index] or "" })
            uri_index = uri_index + 1
        elseif source_type == CONTENT_SOURCE_OBJECT then
            values[index] = make_value("Content", {
                sourceType = "Object", referent = object_refs[object_index],
            })
            object_index = object_index + 1
        elseif source_type == CONTENT_SOURCE_EXTERNAL_OBJECT then
            values[index] = make_value("Content", {
                sourceType = "ExternalObject", referent = external_refs[external_index],
            })
            external_index = external_index + 1
        else
            if source_type ~= CONTENT_SOURCE_NONE then
                unknown_source_types = unknown_source_types + 1
            end
            values[index] = make_value("Content", { sourceType = "None" })
        end
    end

    if unknown_source_types > 0 and ctx and ctx.warn then
        ctx.warn("UnknownContentSourceType",
            "Content property used a SourceType outside None/Uri/Object/ExternalObject", {
                count = unknown_source_types,
            })
    end
    return values
end

---decodes one PROP chunk's value array
---@param reader table   positioned at the first value
---@param type_id number
---@param count number   one value per instance of the owning class
---@return table|nil values  nil when the type id has no decoder
local function parse_value_array(reader, type_id, count, file, property_name, ctx)
    local decoder = VALUE_READERS[type_id]
    if not decoder then
        return nil
    end
    if not ctx then
        ctx = { file = file, propertyName = property_name, typeId = type_id }
    end
    return decoder(reader, count, ctx)
end

-------------------------------------------------------------------- chunk read

local function maybe_add_root(file, instance)
    if not instance then
        return
    end
    for index = 1, #file.roots do
        if file.roots[index] == instance then
            return
        end
    end
    file:add_root(instance)
end

---Warns when a chunk decoded successfully but did not consume its whole payload
---
---a decoder that runs OFF THE END raises and is caught by the pcall in
---read_prop_chunk, one that UNDER-consumes returns a full value array and nothing
---is reported. That is exactly how the PhysicalProperties layout defect stayed
---silent across the entire shipped corpus: four chunks left 2324/228/44/20 bytes
---unread, no warning was raised, so runtime/parser.lua computed
---dom_data_loss_count = 0, set dom_candidate_complete = true, and skipped the
---fallback decoder that would have disagreed
---
---each chunk owns its own Reader over its own decoded payload, so the leftover
---byte count is an exact and free check. it now runs on META, SSTR, INST, PROP
---and PRNT -- every chunk kind with a known layout
---@return number leftover
local function check_fully_consumed(file, payload, chunk_info, context)
    local leftover = payload:remaining()
    if leftover ~= 0 then
        context = context or {}
        context.chunk = chunk_info
        context.leftoverBytes = leftover
        file:add_warning("PropertyChunkNotFullyConsumed",
            "chunk decoded successfully but did not consume its whole payload", context)
    end
    return leftover
end

-- "`META` Chunk": u32 entry count, then String key / String value pairs
local function read_meta_chunk(file, payload, chunk_info)
    local count = payload:read_u32le()
    for _ = 1, count do
        file.metadata[payload:read_string()] = payload:read_string()
    end
    check_fully_consumed(file, payload, chunk_info, { chunkName = "META", valueCount = count })
end

-- "`SSTR` Chunk": u32 version (always 0), u32 count, then 16-byte MD5 + String
-- Roblox Studio ignores the hash on load, it is kept for round-tripping
local function read_sstr_chunk(file, payload, chunk_info)
    local version = payload:read_u32le()
    if version ~= 0 then
        file:add_warning("UnexpectedChunkVersion", "SSTR chunk declared an unexpected version", {
            chunk = chunk_info,
            chunkName = "SSTR",
            version = version,
        })
    end
    local count = payload:read_u32le()
    for index = 1, count do
        file.sharedStrings[index] = {
            version = version,
            md5 = payload:read_bytes(16),
            value = payload:read_string(),
        }
    end
    check_fully_consumed(file, payload, chunk_info, { chunkName = "SSTR", valueCount = count })
end

-- "`INST` Chunk": u32 class id, String class name, u8 object format, u32 count,
-- Referent array, and -- only when the object format is 1 (service) -- one u8
-- marker per instance
local function read_inst_chunk(file, state, payload, chunk_info)
    local class_id = payload:read_u32le()
    local class_name = payload:read_string()
    local object_format = payload:read_u8()
    local count = payload:read_u32le()
    local referents = read_referent_array(payload, count)

    if object_format ~= 0 and object_format ~= 1 then
        file:add_warning("UnknownInstanceObjectFormat",
            "INST chunk used an object format outside {0 regular, 1 service}", {
                chunk = chunk_info,
                classId = class_id,
                className = class_name,
                objectFormat = object_format,
            })
    end

    -- Presence of the marker array is decided by the object format, per spec --
    -- not by whether bytes happen to be left over. Inferring it from the
    -- remaining length silently swallows any trailing garbage instead of
    -- reporting it, and makes a truncated referent array look like a service
    --
    -- only format 1 means "service", an unrecognised format is reported above and
    -- then read as regular. Treating anything non-zero as a service made a single
    -- corrupt byte demand `count` marker bytes that are not there, which raised
    -- out of read_inst_chunk and aborted the whole file instead of losing one
    -- chunk. the leftover-byte check below reports whatever is actually there
    local is_service = object_format == 1
    local service_flags = nil
    if is_service then
        service_flags = read_interleaved_byte_array(payload, count)
    end

    if state.classIdToInfo[class_id] then
        -- the spec requires class ids to be unique. a duplicate silently
        -- orphaned every PROP chunk aimed at the first declaration
        file:add_warning("DuplicateClassId", "two INST chunks declared the same class id", {
            chunk = chunk_info,
            classId = class_id,
            className = class_name,
            previousClassName = state.classIdToInfo[class_id].className,
        })
    end

    local class_info = {
        classId = class_id,
        className = class_name,
        isService = is_service,
        instances = {},
        referents = referents,
    }
    state.classIdToInfo[class_id] = class_info
    state.instChunkCount = state.instChunkCount + 1

    for index = 1, count do
        local instance = dom.new_instance(class_name, referents[index])
        instance.isService = is_service and ((service_flags and service_flags[index] or 0) ~= 0)
        instance.sourceMetadata.classId = class_id
        instance.sourceMetadata.classIndex = index
        file:add_instance(instance)
        class_info.instances[index] = instance
    end

    check_fully_consumed(file, payload, chunk_info, {
        chunkName = "INST",
        classId = class_id,
        className = class_name,
        valueCount = count,
    })
end

local function preserve_prop_chunk(file, class_id, property_name, type_id, raw_payload, leftover)
    file.preserved.unknownPropChunks[#file.preserved.unknownPropChunks + 1] = {
        classId = class_id,
        propertyName = property_name,
        typeId = type_id,
        raw = raw_payload,
        leftoverBytes = leftover,
    }
end

-- "`PROP` Chunk": u32 class id, String property name, u8 type id, then one value
-- per instance of that class, in the order its INST chunk listed them
local function read_prop_chunk(file, state, payload, raw_payload, chunk_info)
    local class_id = payload:read_u32le()
    local property_name = payload:read_string()
    local type_id = payload:read_u8()
    local class_info = state.classIdToInfo[class_id]

    if not class_info then
        file:add_warning("UnknownClassPropChunk", "property chunk referenced missing class", {
            chunk = chunk_info,
            classId = class_id,
            propertyName = property_name,
            typeId = type_id,
        })
        preserve_prop_chunk(file, class_id, property_name, type_id, raw_payload)
        return
    end

    local class_name = class_info.className
    local ctx = {
        file = file,
        chunk = chunk_info,
        classId = class_id,
        className = class_name,
        propertyName = property_name,
        typeId = type_id,
    }
    function ctx.warn(code, message, extra)
        local context = {
            chunk = chunk_info,
            classId = class_id,
            className = class_name,
            propertyName = property_name,
            typeId = type_id,
            typeName = TYPE_NAMES_BY_ID[type_id],
        }
        if type(extra) == "table" then
            for key, value in pairs(extra) do
                context[key] = value
            end
        end
        file:add_warning(code, message, context)
    end

    local count = #class_info.instances
    local ok, values = pcall(parse_value_array, payload, type_id, count, file, property_name, ctx)
    if not ok then
        file:add_warning("PropertyParseFailed", "property chunk could not be parsed", {
            chunk = chunk_info,
            classId = class_id,
            className = class_name,
            propertyName = property_name,
            typeId = type_id,
            typeName = TYPE_NAMES_BY_ID[type_id],
            error = tostring(values),
        })
        preserve_prop_chunk(file, class_id, property_name, type_id, raw_payload)
        return
    end
    if not values then
        file:add_warning("UnknownPropertyType", "property chunk used unsupported value type", {
            chunk = chunk_info,
            classId = class_id,
            propertyName = property_name,
            typeId = type_id,
            typeName = TYPE_NAMES_BY_ID[type_id],
        })
        preserve_prop_chunk(file, class_id, property_name, type_id, raw_payload)
        return
    end

    local leftover = check_fully_consumed(file, payload, chunk_info, {
        chunkName = "PROP",
        classId = class_id,
        className = class_name,
        propertyName = property_name,
        typeId = type_id,
        typeName = TYPE_NAMES_BY_ID[type_id],
        valueCount = count,
    })
    if leftover ~= 0 then
        preserve_prop_chunk(file, class_id, property_name, type_id, raw_payload, leftover)
    end

    local instances = class_info.instances
    for index = 1, count do
        instances[index]:set_property(property_name, values[index])
    end
end

-- "`PRNT` Chunk": u8 version (always 0), u32 count, child Referent array, parent
-- Referent array, paired by position. a parent referent of -1 marks a root
local function read_prnt_chunk(file, state, payload, chunk_info)
    local version = payload:read_u8()
    if version ~= 0 then
        file:add_warning("UnexpectedChunkVersion", "PRNT chunk declared an unexpected version", {
            chunk = chunk_info,
            chunkName = "PRNT",
            version = version,
        })
    end
    local count = payload:read_u32le()
    local children = read_referent_array(payload, count)
    local parents = read_referent_array(payload, count)
    state.prntChunkCount = state.prntChunkCount + 1

    for index = 1, count do
        local child = file:get_instance(children[index])
        local parent_ref = parents[index]
        local parent = parent_ref ~= nil and parent_ref >= 0 and file:get_instance(parent_ref) or nil
        if child then
            if parent then
                -- a malformed or hostile PRNT chunk can contain a self-parenting
                -- pair or a longer cycle. Left unchecked, dom.instance_path would
                -- loop forever and dom.walk would recurse until the C stack blew
                -- Warn and promote the child to a root rather than aborting the
                -- whole parse: the rest of the file is still recoverable
                local ok, reason = parent:can_adopt(child)
                if ok then
                    parent:add_child(child)
                else
                    file:add_warning("InvalidParentLink",
                        "PRNT link rejected: " .. tostring(reason), {
                            version = version,
                            childReferent = children[index],
                            parentReferent = parent_ref,
                        })
                    maybe_add_root(file, child)
                end
            else
                if parent_ref ~= nil and parent_ref >= 0 then
                    -- a non-null parent referent that resolves to nothing is a
                    -- dangling link, not a root. Previously indistinguishable
                    file:add_warning("DanglingParentLink", "PRNT referenced missing parent", {
                        version = version,
                        childReferent = children[index],
                        parentReferent = parent_ref,
                    })
                end
                maybe_add_root(file, child)
            end
        else
            file:add_warning("DanglingParentLink", "PRNT referenced missing child", {
                version = version,
                childReferent = children[index],
                parentReferent = parent_ref,
            })
        end
    end

    check_fully_consumed(file, payload, chunk_info, { chunkName = "PRNT", valueCount = count })
end

local function resolve_special_references(file)
    local warned = {}
    for index = 1, #file.instances do
        local instance = file.instances[index]
        for property_name, value in pairs(instance.properties) do
            if dom.is_value(value) and value.type == "Referent" then
                local referent = value.value
                local is_null = referent == nil or referent < 0
                value.instance = (not is_null) and file:get_instance(referent) or nil
                if (not is_null) and (not value.instance) then
                    local warning_key = concat({
                        dom.instance_path(instance),
                        property_name,
                        tostring(referent),
                    }, "|")
                    if not warned[warning_key] then
                        warned[warning_key] = true
                        file:add_warning("InvalidReferent", "referent property could not be resolved", {
                            instance = dom.instance_path(instance),
                            propertyName = property_name,
                            referent = referent,
                        })
                    end
                end
            elseif dom.is_value(value) and value.type == "Content" and type(value.value) == "table" then
                local referent = value.value.referent
                if referent ~= nil and referent >= 0 then
                    value.value.instance = file:get_instance(referent)
                else
                    value.value.instance = nil
                end
            end
        end
    end
end

------------------------------------------------------------------- public read

---reads a Roblox binary place or model
---@param data string
---@param opts table|nil  { source_name, formatKind, limits, progress_hook }
---@return table file
function binary.read(data, opts)
    opts = opts or {}
    local reader = Reader.new(data, opts.source_name)

    -- "File Header": 8-byte magic `<roblox!`, 6-byte signature 89 ff 0d 0a 1a 0a,
    -- u16 version, i32 class count, i32 instance count, 8 reserved bytes
    reader:require_bytes(32)

    local signature = reader:read_bytes(#constants.BINARY_SIGNATURE)
    if signature ~= constants.BINARY_SIGNATURE then
        errors.raise("BinaryHeader", "invalid Roblox binary signature", {
            path = opts.source_name,
            signature = signature,
        }, 2)
    end

    local version = reader:read_u16le()
    local class_count = reader:read_u32le()
    local instance_count = reader:read_u32le()
    local reserved = reader:read_bytes(8)

    local file = dom.new_file(opts.formatKind or ".rbxl", opts.source_name)
    file.sourceBytes = data
    file.sourceMetadata = {
        version = version,
        classCount = class_count,
        instanceCount = instance_count,
        reserved = reserved,
    }

    if version ~= 0 then
        file:add_warning("UnexpectedFileVersion",
            "binary header declared a version other than 0", { version = version })
    end

    -- Resource limits. there were previously NONE anywhere in this reader: no cap
    -- on instance count, class count, chunk size or decompressed section size, and
    -- the header's own declared counts were stored but never compared against
    -- reality. a malformed or hostile file could therefore ask for an unbounded
    -- allocation (a 4 GB uncompressed_length is four bytes to write) and take the
    -- process down
    --
    -- the defaults sit far above any real Roblox place -- the largest map here,
    -- tested, has 55,087 instances -- so they cannot reject legitimate content
    -- Override per-load via opts.limits for tooling that genuinely needs more
    local limits = opts.limits or binary.LIMITS
    if class_count > limits.max_classes then
        errors.raise("BinaryLimitExceeded", "class count exceeds limit", {
            declared = class_count, limit = limits.max_classes,
        })
    end
    if instance_count > limits.max_instances then
        errors.raise("BinaryLimitExceeded", "instance count exceeds limit", {
            declared = instance_count, limit = limits.max_instances,
        })
    end

    local state = {
        classIdToInfo = {},
        instChunkCount = 0,
        prntChunkCount = 0,
    }

    local progress_hook = opts.progress_hook
    local saw_end = false

    while reader:remaining() >= 16 do
        if progress_hook then
            -- lets a coroutine-hosted parse yield between chunks (async map load)
            progress_hook("dom_read")
        end

        -- "Chunks": 4-byte name, u32 compressed length, u32 uncompressed length,
        -- 4 reserved bytes, then the body. a compressed length of 0 means the body
        -- is stored uncompressed and is `uncompressed length` bytes long
        local signature4 = reader:read_bytes(4)
        local compressed_length = reader:read_u32le()
        local uncompressed_length = reader:read_u32le()
        local chunk_reserved = reader:read_u32le()
        local raw_size = compressed_length ~= 0 and compressed_length or uncompressed_length

        -- Bound the allocation BEFORE reading. read_bytes already refuses to run
        -- off the end of the buffer, but a chunk header can legitimately fit inside
        -- the file while still declaring an absurd decompressed size, and the
        -- zstd/LZ4 decoders allocate against that declared size
        if raw_size > limits.max_chunk_bytes then
            errors.raise("BinaryLimitExceeded", "chunk payload exceeds limit", {
                signature = signature4,
                size = raw_size,
                limit = limits.max_chunk_bytes,
                offset = reader:tell() - 16,
            })
        end
        if uncompressed_length > limits.max_decompressed_bytes then
            errors.raise("BinaryLimitExceeded", "chunk decompressed size exceeds limit", {
                signature = signature4,
                declared = uncompressed_length,
                limit = limits.max_decompressed_bytes,
                offset = reader:tell() - 16,
            })
        end

        local raw_payload = raw_size > 0 and reader:read_bytes(raw_size) or ""
        local chunk_info = {
            signature = signature4,
            compressedLength = compressed_length,
            uncompressedLength = uncompressed_length,
            reserved = chunk_reserved,
            offset = reader:tell() - raw_size - 16,
        }

        if signature4 == "END\0" then
            -- "`END` Chunk": nine bytes, `</roblox>`, never compressed. Roblox uses
            -- it as a rough integrity check when uploading places, so a file whose
            -- magic is wrong was truncated or rewritten by something that did not
            -- understand the format. Previously stored without ever being checked
            saw_end = true
            file.endChunk = {
                raw = raw_payload,
                header = chunk_info,
                trailingBytes = reader:remaining(),
            }
            if raw_payload ~= END_MAGIC then
                file:add_warning("InvalidEndChunk", "END chunk magic was not `</roblox>`", {
                    chunk = chunk_info,
                    magic = raw_payload,
                })
            end
            break
        end

        local decoded_payload, compression = decode_chunk_payload(raw_payload, compressed_length, uncompressed_length)
        chunk_info.compression = compression
        local payload = Reader.new(decoded_payload, opts.source_name)

        if signature4 == "META" then
            read_meta_chunk(file, payload, chunk_info)
        elseif signature4 == "SSTR" then
            read_sstr_chunk(file, payload, chunk_info)
        elseif signature4 == "INST" then
            read_inst_chunk(file, state, payload, chunk_info)
        elseif signature4 == "PROP" then
            read_prop_chunk(file, state, payload, decoded_payload, chunk_info)
        elseif signature4 == "PRNT" then
            read_prnt_chunk(file, state, payload, chunk_info)
        else
            file:add_warning("UnknownChunk", "preserved unsupported binary chunk", chunk_info)
            file:add_unknown_chunk({
                signature = signature4,
                header = chunk_info,
                raw = raw_payload,
                decoded = decoded_payload,
            })
        end
    end

    -- the header's declared counts were previously stored and never checked. they
    -- are the file's own statement of what it contains, so a mismatch means the
    -- file is truncated, or that a chunk we skipped carried instances. Verified
    -- silent on all eight shipped maps
    if not saw_end then
        file:add_warning("MissingEndChunk", "file ended without an END chunk", {
            bytesRemaining = reader:remaining(),
        })
    end
    if state.instChunkCount ~= class_count then
        file:add_warning("ClassCountMismatch",
            "header class count does not match the number of INST chunks", {
                declared = class_count,
                actual = state.instChunkCount,
            })
    end
    if #file.instances ~= instance_count then
        file:add_warning("InstanceCountMismatch",
            "header instance count does not match the number of instances read", {
                declared = instance_count,
                actual = #file.instances,
            })
    end
    if state.prntChunkCount ~= 1 then
        file:add_warning("UnexpectedParentChunkCount",
            "file did not contain exactly one PRNT chunk", { count = state.prntChunkCount })
    end

    if #file.roots == 0 then
        for index = 1, #file.instances do
            local instance = file.instances[index]
            if not instance.parent then
                maybe_add_root(file, instance)
            end
        end
    end

    resolve_special_references(file)
    return file
end

function binary.read_file(path, opts)
    local data, err = util.read_file(path)
    if type(data) ~= "string" then
        errors.raise("BinaryRead", "failed to read Roblox binary file", {
            path = path,
            reason = err,
        }, 2)
    end
    opts = util.shallow_copy(opts or {})
    opts.source_name = path
    opts.formatKind = util.detect_format(path, data)
    return binary.read(data, opts)
end

------------------------------------------------------------------ public write

local function collect_supported_binary_classes(file)
    local order = {}
    local map = {}
    for index = 1, #file.instances do
        local instance = file.instances[index]
        local class_name = instance.className or "Instance"
        local entry = map[class_name]
        if not entry then
            entry = {
                className = class_name,
                classId = #order + 1,
                instances = {},
            }
            map[class_name] = entry
            order[#order + 1] = entry
        end
        entry.instances[#entry.instances + 1] = instance
    end
    return order
end

local function normalize_writer_referents(file)
    local next_id = 0
    for index = 1, #file.instances do
        local instance = file.instances[index]
        if instance.referent == nil then
            instance.referent = next_id
            next_id = next_id + 1
        else
            next_id = math.max(next_id, instance.referent + 1)
        end
    end
end

local function emit_chunk(writer, signature, payload, opts)
    payload = payload or ""
    opts = opts or {}
    writer:put_bytes(signature)
    writer:put_u32le(opts.compressedLength or 0)
    writer:put_u32le(#payload)
    writer:put_u32le(0)
    writer:put_bytes(payload)
end

function binary.write(file, opts)
    opts = opts or {}
    if not opts.force_reencode and type(file.sourceBytes) == "string"
        and (file.formatKind == ".rbxl" or file.formatKind == ".rbxm") then
        return file.sourceBytes
    end

    for index = 1, #file.instances do
        if next(file.instances[index].properties or {}) ~= nil then
            errors.raise("BinaryWrite", "synthetic binary re-encode is not implemented for property-bearing DOM files yet", {
                instance = dom.instance_path(file.instances[index]),
            }, 2)
        end
    end

    normalize_writer_referents(file)
    local writer = Writer.new()
    writer:put_bytes(constants.BINARY_SIGNATURE)
    writer:put_u16le(0)

    local classes = collect_supported_binary_classes(file)
    writer:put_u32le(#classes)
    writer:put_u32le(#file.instances)
    writer:put_bytes(string.rep("\0", 8))

    if next(file.metadata) ~= nil then
        local meta = Writer.new()
        local keys = {}
        for key in pairs(file.metadata) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        meta:put_u32le(#keys)
        for index = 1, #keys do
            meta:put_string(keys[index])
            meta:put_string(tostring(file.metadata[keys[index]]))
        end
        emit_chunk(writer, "META", meta:to_string())
    end

    for class_index = 1, #classes do
        local class_info = classes[class_index]
        local payload = Writer.new()
        payload:put_u32le(class_info.classId)
        payload:put_string(class_info.className)
        payload:put_u8(0)
        payload:put_u32le(#class_info.instances)
        local referents = {}
        for index = 1, #class_info.instances do
            referents[index] = class_info.instances[index].referent
        end
        write_referent_array(payload, referents)
        -- Object format 0 above: per spec the service marker array is present
        -- only for services, so it must NOT be written here
        emit_chunk(writer, "INST", payload:to_string())
    end

    local parent_payload = Writer.new()
    local child_refs = {}
    local parent_refs = {}
    for index = 1, #file.instances do
        local instance = file.instances[index]
        child_refs[index] = instance.referent
        parent_refs[index] = instance.parent and instance.parent.referent or -1
    end
    parent_payload:put_u8(0)
    parent_payload:put_u32le(#file.instances)
    write_referent_array(parent_payload, child_refs)
    write_referent_array(parent_payload, parent_refs)
    emit_chunk(writer, "PRNT", parent_payload:to_string())

    for index = 1, #file.unknownChunks do
        local chunk = file.unknownChunks[index]
        if type(chunk) == "table" and type(chunk.signature) == "string" and #chunk.signature == 4 then
            writer:put_bytes(chunk.signature)
            writer:put_u32le(chunk.header and chunk.header.compressedLength or 0)
            writer:put_u32le(chunk.header and chunk.header.uncompressedLength or #(chunk.decoded or chunk.raw or ""))
            writer:put_u32le(chunk.header and chunk.header.reserved or 0)
            writer:put_bytes(chunk.raw or chunk.decoded or "")
        end
    end

    emit_chunk(writer, "END\0", (file.endChunk and file.endChunk.raw) or END_MAGIC)
    return writer:to_string()
end

function binary.write_file(file, path, opts)
    local data = binary.write(file, opts)
    local ok, err = util.write_file(path, data)
    if not ok then
        errors.raise("BinaryWrite", "failed to write Roblox binary file", {
            path = path,
            reason = err,
        }, 2)
    end
    return true
end

--------------------------------------------------------------- format bridges

---converts a UniqueId Random component between the binary and XML encodings
---
---xml.md notes that the component "is serialized differently between the XML and
---binary format", specifically by a one-bit circular rotation. Measured on
---Classic-Crossroads, which ships in both formats: binary 5f2db3c95775d646 pairs
---with XML 2f96d9e4abbaeb23, i.e. XML = binary rotated RIGHT one bit. Recovering
---the binary (canonical) value from XML is therefore a LEFT rotation
---@param value table  dom i64 { hi, lo }
---@return table
local function uniqueid_random_to_xml(value)
    local hi = to_u32(value and value.hi or 0)
    local lo = to_u32(value and value.lo or 0)
    local out_hi, out_lo = uint64_shr1(hi, lo)
    if band(lo, 1) == 1 then
        out_hi = bor(out_hi, 0x80000000)
    end
    return make_i64(out_hi, out_lo, true)
end

local function uniqueid_random_from_xml(value)
    local hi = to_u32(value and value.hi or 0)
    local lo = to_u32(value and value.lo or 0)
    local out_hi, out_lo = uint64_shl1(hi, lo)
    if band(hi, 0x80000000) ~= 0 then
        out_lo = bor(out_lo, 1)
    end
    return make_i64(out_hi, out_lo, true)
end

-- modern Roblox Studio writes chunks with zstd instead of LZ4, wire up the
-- pure-Lua zstd backend so those .rbxl maps decode without pre-conversion
-- loaded via pcall so a stripped build without the module degrades to the old
-- "missing chunk decompressor backend" error rather than failing to load
do
    local ok_zstd, zstd = pcall(require, "engine/graphics/rbx/zstd")
    if ok_zstd and type(zstd) == "table" and type(zstd.decompress) == "function" then
        binary.register_decompressor("zstd", function(payload, uncompressed_length)
            local ok, result = pcall(zstd.decompress, payload, uncompressed_length)
            if not ok then
                errors.raise("BinaryCompression", "zstd chunk decode failed", {
                    reason = tostring(result),
                    uncompressedLength = uncompressed_length,
                }, 2)
            end
            return result
        end)
    end
end

binary.Reader = Reader
binary.Writer = Writer
binary.END_MAGIC = END_MAGIC
binary.FACE_BIT_NAMES = FACE_BIT_NAMES
binary.AXIS_BIT_NAMES = AXIS_BIT_NAMES
binary.decode_lz4_raw = decode_lz4_raw
binary.rotate_float_decode = rotate_float_decode
binary.rotate_float_encode = rotate_float_encode
binary.zigzag_decode_u32 = zigzag_decode_u32
binary.zigzag_encode_i32 = zigzag_encode_i32
binary.zigzag_decode_i64 = zigzag_decode_i64
binary.be_bytes_to_i64 = be_bytes_to_i64
binary.i64_to_be_bytes = i64_to_be_bytes
binary.read_interleaved_items = read_interleaved_items
binary.write_interleaved_items = write_interleaved_items
binary.read_referent_array = read_referent_array
binary.write_referent_array = write_referent_array
binary.write_interleaved_u32_array = write_interleaved_u32_array
binary.write_interleaved_i32_array = write_interleaved_i32_array
binary.write_interleaved_float_array = write_interleaved_float_array
binary.write_interleaved_byte_array = write_interleaved_byte_array
binary.parse_value_array = parse_value_array
binary.uniqueid_random_to_xml = uniqueid_random_to_xml
binary.uniqueid_random_from_xml = uniqueid_random_from_xml
binary.VALUE_READERS = VALUE_READERS

return binary
