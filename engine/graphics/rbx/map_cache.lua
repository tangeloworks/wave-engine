-- cache parsed places in the LÖVE save directory so the next load can skip parsing
-- tables are stored by ID to preserve shared references and parent cycles
-- numbers are stored as doubles

local ffi = require("ffi")

-- LuaJIT table.new preallocates a table's array+hash parts so the decode doesn't
-- regrow/rehash every one of the millions of tiny subtables in a 74k-instance map
-- falls back to {} where unavailable (hints are advisory: wrong sizes only cost speed)
local ok_tn, table_new = pcall(require, "table.new")
if not ok_tn or type(table_new) ~= "function" then
    table_new = function() return {} end
end

local map_cache = {}

-- bump the cache version when the parsed graph or binary layout changes
-- the map hash covers the source file, so a parser change needs its own version bump
map_cache.FORMAT_VERSION = 26

local MAGIC = "LGMC"
local CACHE_DIR = "map_cache"
local PROGRESS_EVERY = 200
local LOAD_DIAGNOSTIC_FIELDS = {
    "complete", "read_wall", "header_wall", "decode_wall",
    "callback_wall", "callback_calls", "encoded_bytes",
    "decoded_tables", "decoded_strings", "heap_before_kb",
    "heap_after_read_kb", "heap_after_decode_kb",
}

local function valid_diagnostic_number(value)
    return type(value) == "number" and value == value
        and value >= 0 and value < math.huge
end

-- Observation must not turn a valid cache hit into a miss. protect only the
-- observers, the real progress callback retains the load's existing pcall/yield
-- semantics. Heap readings are net residency observations, not allocation totals
local function read_diagnostic_number(observer, ...)
    local ok, value = pcall(observer, ...)
    if ok and valid_diagnostic_number(value) then
        return value
    end
end

local T_NIL = 0
local T_FALSE = 1
local T_TRUE = 2
local T_NUMBER = 3
local T_STRING = 4
local T_STRING_REF = 5
local T_TABLE = 6
local T_TABLE_REF = 7
local T_END = 8

local scratch_double = ffi.new("double[1]")

local function cache_path(cache_name)
    return CACHE_DIR .. "/" .. tostring(cache_name) .. ".v" .. map_cache.FORMAT_VERSION .. ".mapcache"
end

-- single growing byte buffer: per-value Lua string chunks would allocate millions
-- of tiny strings for a 63k-part map, this stays raw until one ffi.string at the end
local function writer_new()
    local cap = 1024 * 1024
    return { buf = ffi.new("uint8_t[?]", cap), cap = cap, len = 0 }
end

local function writer_reserve(w, extra)
    local need = w.len + extra
    if need > w.cap then
        local cap = w.cap
        repeat cap = cap * 2 until cap >= need
        local buf = ffi.new("uint8_t[?]", cap)
        ffi.copy(buf, w.buf, w.len)
        w.buf, w.cap = buf, cap
    end
end

local function write_u8(w, v)
    writer_reserve(w, 1)
    w.buf[w.len] = v
    w.len = w.len + 1
end

local function write_u32(w, v)
    writer_reserve(w, 4)
    ffi.cast("uint32_t*", w.buf + w.len)[0] = v
    w.len = w.len + 4
end

local function write_double(w, v)
    writer_reserve(w, 8)
    scratch_double[0] = v
    ffi.copy(w.buf + w.len, scratch_double, 8)
    w.len = w.len + 8
end

local function write_bytes(w, s)
    local n = #s
    writer_reserve(w, n)
    ffi.copy(w.buf + w.len, s, n)
    w.len = w.len + n
end

local function encode_value(ctx, v)
    local w = ctx.w
    local tv = type(v)
    if tv == "number" then
        write_u8(w, T_NUMBER)
        write_double(w, v)
    elseif tv == "string" then
        local id = ctx.string_ids[v]
        if id then
            write_u8(w, T_STRING_REF)
            write_u32(w, id)
        else
            ctx.string_count = ctx.string_count + 1
            ctx.string_ids[v] = ctx.string_count
            write_u8(w, T_STRING)
            write_u32(w, #v)
            write_bytes(w, v)
        end
    elseif tv == "boolean" then
        write_u8(w, v and T_TRUE or T_FALSE)
    elseif tv == "table" then
        local id = ctx.table_ids[v]
        if id then
            write_u8(w, T_TABLE_REF)
            write_u32(w, id)
            return
        end
        ctx.table_count = ctx.table_count + 1
        ctx.table_ids[v] = ctx.table_count
        if ctx.progress and ctx.table_count % PROGRESS_EVERY == 0 then
            ctx.progress()
        end
        write_u8(w, T_TABLE)
        local narr = 0
        while rawget(v, narr + 1) ~= nil do
            narr = narr + 1
        end
        write_u32(w, narr)
        -- nhash: count of hash entries that will actually be written (same skip predicate
        -- as the write loop below). Lets decode preallocate table.new(narr, nhash) exactly,
        -- avoiding rehash churn on millions of subtables. Cold-save-only extra pairs() walk
        local nhash = 0
        for k, item in pairs(v) do
            local tk = type(k)
            if not (k == "_dom_instance"
                    or (tk == "number" and k >= 1 and k <= narr and k % 1 == 0)
                    or (tk ~= "string" and tk ~= "number" and tk ~= "boolean")) then
                local ti = type(item)
                if ti == "boolean" or ti == "number" or ti == "string" or ti == "table" then
                    nhash = nhash + 1
                end
            end
        end
        write_u32(w, nhash)
        for i = 1, narr do
            encode_value(ctx, v[i])
        end
        for k, item in pairs(v) do
            local tk = type(k)
            -- _dom_instance is write-only after parse (scene/datamodel copy loops skip
            -- it), dropping the DOM subtree roughly halves the cache
            local skip = k == "_dom_instance"
                or (tk == "number" and k >= 1 and k <= narr and k % 1 == 0)
                or (tk ~= "string" and tk ~= "number" and tk ~= "boolean")
            if not skip then
                local ti = type(item)
                if ti == "boolean" or ti == "number" or ti == "string" or ti == "table" then
                    encode_value(ctx, k)
                    encode_value(ctx, item)
                end
                -- other value types (function/userdata/...) are silently skipped
            end
        end
        write_u8(w, T_END)
    elseif tv == "cdata" and tonumber(v) then
        write_u8(w, T_NUMBER)
        write_double(w, tonumber(v))
    else
        -- unsupported value in an array slot: hole keeps later positions stable
        write_u8(w, T_NIL)
    end
end

local function read_u8(ctx)
    local pos = ctx.pos
    if pos + 1 > ctx.n then
        error("truncated cache", 0)
    end
    ctx.pos = pos + 1
    return ctx.ptr[pos]
end

local function read_u32(ctx)
    local pos = ctx.pos
    if pos + 4 > ctx.n then
        error("truncated cache", 0)
    end
    ctx.pos = pos + 4
    return ffi.cast("const uint32_t*", ctx.ptr + pos)[0]
end

local function read_double(ctx)
    local pos = ctx.pos
    if pos + 8 > ctx.n then
        error("truncated cache", 0)
    end
    ctx.pos = pos + 8
    ffi.copy(scratch_double, ctx.ptr + pos, 8)
    return scratch_double[0]
end

local function read_bytes(ctx, len)
    local pos = ctx.pos
    if pos + len > ctx.n then
        error("truncated cache", 0)
    end
    ctx.pos = pos + len
    return ffi.string(ctx.ptr + pos, len)
end

local function decode_value(ctx)
    local tag = read_u8(ctx)
    if tag == T_NUMBER then
        return read_double(ctx)
    elseif tag == T_STRING_REF then
        local s = ctx.strings[read_u32(ctx)]
        if s == nil then
            error("bad string ref", 0)
        end
        return s
    elseif tag == T_STRING then
        local s = read_bytes(ctx, read_u32(ctx))
        ctx.string_count = ctx.string_count + 1
        ctx.strings[ctx.string_count] = s
        return s
    elseif tag == T_TABLE then
        local narr = read_u32(ctx)
        local nhash = read_u32(ctx)
        local t = table_new(narr, nhash)
        -- register before filling so cyclic refs (Parent backrefs) resolve
        ctx.table_count = ctx.table_count + 1
        ctx.tables[ctx.table_count] = t
        if ctx.progress and ctx.table_count % PROGRESS_EVERY == 0 then
            ctx.progress()
        end
        for i = 1, narr do
            t[i] = decode_value(ctx)
        end
        while true do
            if ctx.pos + 1 > ctx.n then
                error("truncated cache", 0)
            end
            if ctx.ptr[ctx.pos] == T_END then
                ctx.pos = ctx.pos + 1
                break
            end
            local k = decode_value(ctx)
            if k == nil then
                error("nil key", 0)
            end
            t[k] = decode_value(ctx)
        end
        return t
    elseif tag == T_TABLE_REF then
        local t = ctx.tables[read_u32(ctx)]
        if t == nil then
            error("bad table ref", 0)
        end
        return t
    elseif tag == T_TRUE then
        return true
    elseif tag == T_FALSE then
        return false
    elseif tag == T_NIL then
        return nil
    end
    error("bad tag", 0)
end

-- returns the decoded payload table, or nil on any miss (absent file, version or
-- hash mismatch, decode error). never raises. `progress` (optional) is called
-- periodically during decode so a loading screen can stay live
-- optional diagnostics receives only a complete successful observation, never
-- the payload/context. without a sink there are no added clock/heap reads
function map_cache.load(cache_name, file_hash, progress, diagnostics)
    local diagnostic_clock
    if type(diagnostics) == "table" then
        for index = 1, #LOAD_DIAGNOSTIC_FIELDS do
            rawset(diagnostics, LOAD_DIAGNOSTIC_FIELDS[index], nil)
        end
        if love and love.timer and type(love.timer.getTime) == "function" then
            diagnostic_clock = love.timer.getTime
        end
    end
    if not (love and love.filesystem) then
        return nil
    end
    local read_start, read_end, header_start, header_end, decode_end
    local heap_before, heap_after_read, heap_after_decode
    local encoded_bytes, decoded_tables, decoded_strings
    local callback_wall, callback_calls = 0, 0
    local ok, payload = pcall(function()
        if diagnostic_clock then
            heap_before = read_diagnostic_number(collectgarbage, "count")
            read_start = read_diagnostic_number(diagnostic_clock)
        end
        local data = love.filesystem.read(cache_path(cache_name))
        if diagnostic_clock then
            read_end = read_diagnostic_number(diagnostic_clock)
            heap_after_read = read_diagnostic_number(collectgarbage, "count")
        end
        if type(data) ~= "string" or #data < #MAGIC + 8 then
            return nil
        end
        if diagnostic_clock then
            encoded_bytes = #data
            header_start = read_diagnostic_number(diagnostic_clock)
        end
        local ctx = {
            -- keep `data` referenced in ctx: ptr borrows the string's memory, and
            -- without the anchor LuaJIT may collect the string mid-decode
            data = data,
            ptr = ffi.cast("const uint8_t*", data),
            n = #data,
            pos = 0,
            strings = {},
            string_count = 0,
            tables = {},
            table_count = 0,
            progress = progress,
        }
        if diagnostic_clock and progress then
            -- this wrapper belongs only to load: save uses the original callback
            ctx.progress = function()
                local started = read_diagnostic_number(diagnostic_clock)
                progress()
                callback_calls = callback_calls + 1
                local finished = read_diagnostic_number(diagnostic_clock)
                local elapsed = started and finished and finished - started
                if callback_wall ~= nil and valid_diagnostic_number(elapsed) then
                    callback_wall = callback_wall + elapsed
                else
                    callback_wall = nil
                end
            end
        end
        if read_bytes(ctx, #MAGIC) ~= MAGIC then
            return nil
        end
        if read_u32(ctx) ~= map_cache.FORMAT_VERSION then
            return nil
        end
        if read_bytes(ctx, read_u32(ctx)) ~= tostring(file_hash or "") then
            return nil
        end
        if diagnostic_clock then
            header_end = read_diagnostic_number(diagnostic_clock)
        end
        local decoded = decode_value(ctx)
        if diagnostic_clock then
            decode_end = read_diagnostic_number(diagnostic_clock)
            heap_after_decode = read_diagnostic_number(collectgarbage, "count")
            decoded_tables = ctx.table_count
            decoded_strings = ctx.string_count
        end
        if type(decoded) ~= "table" then
            return nil
        end
        return decoded
    end)
    if not ok then
        return nil
    end
    if diagnostic_clock and type(payload) == "table" then
        local read_wall = read_start and read_end and read_end - read_start
        local header_wall = header_start and header_end and header_end - header_start
        local decode_wall = header_end and decode_end and decode_end - header_end
        if valid_diagnostic_number(read_wall)
            and valid_diagnostic_number(header_wall)
            and valid_diagnostic_number(decode_wall)
            and header_start >= read_end
            and valid_diagnostic_number(callback_wall)
            and callback_wall <= decode_wall
            and valid_diagnostic_number(callback_calls) and callback_calls % 1 == 0
            and valid_diagnostic_number(encoded_bytes) and encoded_bytes % 1 == 0
            and valid_diagnostic_number(decoded_tables) and decoded_tables % 1 == 0
            and valid_diagnostic_number(decoded_strings) and decoded_strings % 1 == 0
            and valid_diagnostic_number(heap_before)
            and valid_diagnostic_number(heap_after_read)
            and valid_diagnostic_number(heap_after_decode) then
            -- no callbacks/metamethods or yields during publication. Complete is
            -- written last, after all scalar observations have been validated
            rawset(diagnostics, "read_wall", read_wall)
            rawset(diagnostics, "header_wall", header_wall)
            rawset(diagnostics, "decode_wall", decode_wall)
            rawset(diagnostics, "callback_wall", callback_wall)
            rawset(diagnostics, "callback_calls", callback_calls)
            rawset(diagnostics, "encoded_bytes", encoded_bytes)
            rawset(diagnostics, "decoded_tables", decoded_tables)
            rawset(diagnostics, "decoded_strings", decoded_strings)
            rawset(diagnostics, "heap_before_kb", heap_before)
            rawset(diagnostics, "heap_after_read_kb", heap_after_read)
            rawset(diagnostics, "heap_after_decode_kb", heap_after_decode)
            rawset(diagnostics, "complete", true)
        end
    end
    return payload
end

-- returns true, byte_count on success, false, err otherwise. never mutates payload
function map_cache.save(cache_name, file_hash, payload, progress)
    if not (love and love.filesystem) then
        return false, "love.filesystem unavailable"
    end
    if type(payload) ~= "table" then
        return false, "payload must be a table"
    end
    local ok, result = pcall(function()
        local w = writer_new()
        write_bytes(w, MAGIC)
        write_u32(w, map_cache.FORMAT_VERSION)
        local hash = tostring(file_hash or "")
        write_u32(w, #hash)
        write_bytes(w, hash)
        local ctx = {
            w = w,
            string_ids = {},
            string_count = 0,
            table_ids = {},
            table_count = 0,
            progress = progress,
        }
        encode_value(ctx, payload)
        love.filesystem.createDirectory(CACHE_DIR)
        local wrote, write_err = love.filesystem.write(cache_path(cache_name), ffi.string(w.buf, w.len))
        if not wrote then
            error(tostring(write_err or "write failed"), 0)
        end
        return w.len
    end)
    if not ok then
        return false, tostring(result)
    end
    return true, result
end

return map_cache
