-- Deterministic weighted LRU for renderer-local decoded meshes
--
-- the public values table intentionally keeps the historical shape
--     renderer._mesh_cache[key] = decoded_mesh | false
-- because map warm-cache checks and diagnostics inspect it directly.  this
-- object owns only parallel accounting/LRU metadata.  its reference to the
-- values table is weak, so renderer teardown can release decoded geometry even
-- if the small accounting object itself remains reachable

local LocalMeshCache = {}
LocalMeshCache.__index = LocalMeshCache

LocalMeshCache.DEFAULT_MAX_BYTES = 384 * 1024 * 1024
LocalMeshCache.DEFAULT_MAX_ENTRIES = 2048
LocalMeshCache.DEFAULT_NEGATIVE_TTL_SECONDS = 60

-- LuaJIT stores dense numeric arrays compactly.  Charging 16 bytes per slot is
-- deliberately conservative across LÖVE Lua runtimes and, more importantly,
-- is deterministic.  Large known streams are accounted from their length in
-- O(1), only bounded metadata is traversed
local RESULT_BASE_BYTES = 256
local ARRAY_BASE_BYTES = 64
local NUMERIC_SLOT_BYTES = 16
local METADATA_ENTRY_BYTES = 24
local STRING_BASE_BYTES = 24
local CACHE_NODE_BASE_BYTES = 112
local MAX_METADATA_ENTRIES = 4096
local MAX_EXACT_BYTES = 9007199254740991

local STREAM_FIELDS = {
    "positions", "normals", "uvs", "colors", "_gpu_colors",
    "normal_ids", "tangents", "indices", "faces", "face_ids", "vertices",
    "weights", "bone_indices",
}
local STREAM_FIELD_SET = {}
for index = 1, #STREAM_FIELDS do
    STREAM_FIELD_SET[STREAM_FIELDS[index]] = true
end

local function default_now()
    if love and love.timer and type(love.timer.getTime) == "function" then
        return love.timer.getTime()
    end
    return os.clock()
end

local function clamp_integer(value, fallback, minimum, maximum)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        value = fallback
    end
    value = math.floor(value)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function finite_nonnegative(value, fallback, maximum)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        value = fallback
    end
    if value < 0 then value = 0 end
    if value > maximum then value = maximum end
    return value
end

local function resolve_now(value, clock)
    if value == nil then value = clock() end
    return finite_nonnegative(value, 0, MAX_EXACT_BYTES)
end

local function array_length(value)
    if type(rawlen) == "function" then return rawlen(value) end
    return #value
end

local function add_bytes(total, amount)
    amount = tonumber(amount)
    if amount == nil or amount ~= amount or amount < 0 or amount == math.huge
        or total > MAX_EXACT_BYTES - amount then
        return MAX_EXACT_BYTES, false
    end
    return total + amount, true
end

---Estimate retained decoded-mesh bytes without walking numeric vertices
---@return number|nil bytes, string|nil reason
function LocalMeshCache.estimate_decoded_bytes(decoded)
    if type(decoded) ~= "table" then
        return nil, "decoded_mesh_not_table"
    end

    local total = RESULT_BASE_BYTES
    local stream_tables = {}
    local color_streams_reserved = {}

    for index = 1, #STREAM_FIELDS do
        local field = STREAM_FIELDS[index]
        local stream = rawget(decoded, field)
        if stream ~= nil then
            local stream_type = type(stream)
            if stream_type == "table" then
                if not stream_tables[stream] then
                    stream_tables[stream] = true
                    local ok
                    total, ok = add_bytes(total,
                        ARRAY_BASE_BYTES + array_length(stream) * NUMERIC_SLOT_BYTES)
                    if not ok then return nil, "decoded_mesh_byte_overflow" end
                end
                if field == "colors" then
                    color_streams_reserved[stream] = true
                end
            elseif stream_type == "string" then
                local ok
                total, ok = add_bytes(total, STRING_BASE_BYTES + #stream)
                if not ok then return nil, "decoded_mesh_byte_overflow" end
            else
                return nil, "decoded_mesh_bad_stream"
            end
        end
    end

    -- assets.lua derives and retains one linear-space stream per authored color
    -- stream. Reserve it before the first render so admission cannot silently
    -- grow past the configured ceiling later
    if type(rawget(decoded, "colors")) == "table"
        and type(rawget(decoded, "_gpu_colors")) ~= "table" then
        local colors = rawget(decoded, "colors")
        local ok
        total, ok = add_bytes(total,
            ARRAY_BASE_BYTES + array_length(colors) * NUMERIC_SLOT_BYTES)
        if not ok then return nil, "decoded_mesh_byte_overflow" end
    end

    local seen = { [decoded] = true }
    local stack = { decoded }
    local metadata_entries = 0
    while #stack > 0 do
        local current = stack[#stack]
        stack[#stack] = nil
        for key, value in pairs(current) do
            metadata_entries = metadata_entries + 1
            if metadata_entries > MAX_METADATA_ENTRIES then
                return nil, "decoded_mesh_metadata_limit"
            end

            local ok
            total, ok = add_bytes(total, METADATA_ENTRY_BYTES)
            if not ok then return nil, "decoded_mesh_byte_overflow" end

            local key_type = type(key)
            if key_type == "string" then
                total, ok = add_bytes(total, STRING_BASE_BYTES + #key)
                if not ok then return nil, "decoded_mesh_byte_overflow" end
            elseif key_type ~= "number" and key_type ~= "boolean" then
                return nil, "decoded_mesh_bad_metadata_key"
            end

            local value_type = type(value)
            local known_stream = key_type == "string" and STREAM_FIELD_SET[key] == true
            if value_type == "table" then
                if known_stream then
                    if not stream_tables[value] then
                        stream_tables[value] = true
                        total, ok = add_bytes(total,
                            ARRAY_BASE_BYTES + array_length(value) * NUMERIC_SLOT_BYTES)
                        if not ok then return nil, "decoded_mesh_byte_overflow" end
                    end
                    if key == "colors" and not color_streams_reserved[value] then
                        color_streams_reserved[value] = true
                        total, ok = add_bytes(total,
                            ARRAY_BASE_BYTES + array_length(value) * NUMERIC_SLOT_BYTES)
                        if not ok then return nil, "decoded_mesh_byte_overflow" end
                    end
                elseif not stream_tables[value] and not seen[value] then
                    seen[value] = true
                    total, ok = add_bytes(total, ARRAY_BASE_BYTES)
                    if not ok then return nil, "decoded_mesh_byte_overflow" end
                    stack[#stack + 1] = value
                end
            elseif value_type == "string" then
                total, ok = add_bytes(total, STRING_BASE_BYTES + #value)
                if not ok then return nil, "decoded_mesh_byte_overflow" end
            elseif value_type == "number" then
                total, ok = add_bytes(total, NUMERIC_SLOT_BYTES)
                if not ok then return nil, "decoded_mesh_byte_overflow" end
            elseif value_type == "boolean" or value_type == "nil" then
                -- the entry charge above owns immediate scalar storage
            elseif value_type == "userdata" then
                local method_ok, get_size = pcall(function() return value.getSize end)
                if not method_ok or type(get_size) ~= "function" then
                    return nil, "decoded_mesh_unaccountable_userdata"
                end
                local size_ok, size = pcall(get_size, value)
                if not size_ok or type(size) ~= "number" or size < 0 then
                    return nil, "decoded_mesh_unaccountable_userdata"
                end
                total, ok = add_bytes(total, size)
                if not ok then return nil, "decoded_mesh_byte_overflow" end
            else
                return nil, "decoded_mesh_unaccountable_type"
            end
        end
    end

    return math.floor(total), nil
end

local function new_stats()
    return {
        hits = 0,
        misses = 0,
        negative_hits = 0,
        negative_expirations = 0,
        admissions = 0,
        positive_admissions = 0,
        negative_admissions = 0,
        updates = 0,
        evictions = 0,
        positive_evictions = 0,
        negative_evictions = 0,
        evicted_bytes = 0,
        oversize_rejections = 0,
        estimate_failures = 0,
        publish_conflicts = 0,
        pressure_stalls = 0,
        resident_bytes = 0,
        resident_peak_bytes = 0,
        resident_entries = 0,
        resident_peak_entries = 0,
        resident_negative_entries = 0,
        publishing_entries = 0,
        publishing_peak_entries = 0,
    }
end

local function weak_values_reference(values)
    return setmetatable({ values }, { __mode = "v" })
end

function LocalMeshCache.new(values, options)
    assert(type(values) == "table", "LocalMeshCache.new needs a values table")
    options = options or {}
    local self = setmetatable({}, LocalMeshCache)
    self.max_bytes = clamp_integer(options.max_bytes,
        LocalMeshCache.DEFAULT_MAX_BYTES, 0, MAX_EXACT_BYTES)
    self.max_entries = clamp_integer(options.max_entries,
        LocalMeshCache.DEFAULT_MAX_ENTRIES, 0, 1000000)
    self.negative_ttl_seconds = finite_nonnegative(
        options.negative_ttl_seconds,
        LocalMeshCache.DEFAULT_NEGATIVE_TTL_SECONDS,
        86400)
    self.now = type(options.now) == "function" and options.now or default_now
    self._values_reference = weak_values_reference(values)
    self.nodes = {}
    self.publishing = {}
    self.head = nil
    self.tail = nil
    self.stats = new_stats()

    -- a controller can be reconstructed around a warm cache (for example after
    -- live reconfiguration). Adopt those direct values in a stable key order so
    -- none remain resident but uncharged. production construction starts empty,
    -- so this migration path has no map-build hot-path cost
    local existing_keys = {}
    for key in pairs(values) do existing_keys[#existing_keys + 1] = key end
    table.sort(existing_keys, function(a, b)
        local a_text, b_text = tostring(a), tostring(b)
        if a_text ~= b_text then return a_text < b_text end
        return type(a) < type(b)
    end)
    for index = 1, #existing_keys do
        local key = existing_keys[index]
        local value = values[key]
        values[key] = nil
        self:begin_publish(key)
        self:publish(key, value)
        self:finish_publish(key)
    end
    return self
end

function LocalMeshCache:is_bound_to(values)
    return type(values) == "table" and self._values_reference[1] == values
end

function LocalMeshCache:_values()
    return self._values_reference[1]
end

function LocalMeshCache:_detach(node)
    local previous = node.previous
    local following = node.following
    if previous then previous.following = following else self.head = following end
    if following then following.previous = previous else self.tail = previous end
    node.previous = nil
    node.following = nil
end

function LocalMeshCache:_append_mru(node)
    node.previous = self.tail
    node.following = nil
    if self.tail then self.tail.following = node else self.head = node end
    self.tail = node
end

function LocalMeshCache:_touch(node)
    if self.tail == node then return end
    self:_detach(node)
    self:_append_mru(node)
end

function LocalMeshCache:_set_resident(bytes, entries, negatives)
    local stats = self.stats
    stats.resident_bytes = math.max(0, math.floor(tonumber(bytes) or 0))
    stats.resident_entries = math.max(0, math.floor(tonumber(entries) or 0))
    stats.resident_negative_entries = math.max(0,
        math.min(stats.resident_entries, math.floor(tonumber(negatives) or 0)))
    stats.resident_peak_bytes = math.max(stats.resident_peak_bytes,
        stats.resident_bytes)
    stats.resident_peak_entries = math.max(stats.resident_peak_entries,
        stats.resident_entries)
end

function LocalMeshCache:_remove_node(node, evicted)
    if not node or self.nodes[node.key] ~= node then return false end
    self:_detach(node)
    self.nodes[node.key] = nil
    local values = self:_values()
    if values then values[node.key] = nil end

    local stats = self.stats
    local removed_bytes = math.max(0, math.floor(tonumber(node.bytes) or 0))
    self:_set_resident(
        math.max(0, stats.resident_bytes - removed_bytes),
        math.max(0, stats.resident_entries - 1),
        math.max(0, stats.resident_negative_entries - (node.negative and 1 or 0)))
    if evicted then
        stats.evictions = stats.evictions + 1
        stats.evicted_bytes = stats.evicted_bytes + removed_bytes
        if node.negative then
            stats.negative_evictions = stats.negative_evictions + 1
        else
            stats.positive_evictions = stats.positive_evictions + 1
        end
    end
    return true
end

function LocalMeshCache:_oldest_evictable()
    local candidate = self.head
    while candidate and self.publishing[candidate.key] ~= nil do
        candidate = candidate.following
    end
    return candidate
end

function LocalMeshCache:_enforce_budget()
    local stats = self.stats
    while stats.resident_bytes > self.max_bytes
        or stats.resident_entries > self.max_entries do
        local candidate = self:_oldest_evictable()
        if not candidate then
            stats.pressure_stalls = stats.pressure_stalls + 1
            return false
        end
        self:_remove_node(candidate, true)
    end
    return true
end

---return value, hit, state.  a cached negative returns false,true,"negative"
function LocalMeshCache:get(key, now)
    local values = self:_values()
    if not values then
        self.stats.misses = self.stats.misses + 1
        return nil, false, "unbound"
    end
    local node = self.nodes[key]
    local value = node and values[key]
    if not node or value == nil then
        if node then self:_remove_node(node, false) end
        self.stats.misses = self.stats.misses + 1
        return nil, false, "missing"
    end

    if node.negative then
        now = resolve_now(now, self.now)
        if now >= node.negative_until then
            self:_remove_node(node, false)
            self.stats.negative_expirations = self.stats.negative_expirations + 1
            self.stats.misses = self.stats.misses + 1
            return nil, false, "negative_expired"
        end
        self.stats.negative_hits = self.stats.negative_hits + 1
    end
    self.stats.hits = self.stats.hits + 1
    self:_touch(node)
    return value, true, node.negative and "negative" or "positive"
end

---Pin a cache key across read/decode/publication.  Eviction may continue around
---other keys, but this key cannot be selected until finish_publish
function LocalMeshCache:begin_publish(key)
    if key == nil then return false end
    if self.publishing[key] ~= nil then
        self.stats.publish_conflicts = self.stats.publish_conflicts + 1
        return false
    end
    -- Lua tables cannot store nil keys, and cache keys are allowed to be false;
    -- use one shared sentinel value rather than arithmetic pin counts
    self.publishing[key] = true
    self.stats.publishing_entries = self.stats.publishing_entries + 1
    self.stats.publishing_peak_entries = math.max(
        self.stats.publishing_peak_entries, self.stats.publishing_entries)
    return true
end

function LocalMeshCache:publish(key, value, now)
    if key == nil then return false, "invalid_key" end
    local values = self:_values()
    if not values then return false, "unbound" end

    local negative = value == nil or value == false
    local payload_bytes, estimate_reason
    if negative then
        payload_bytes = 0
    else
        payload_bytes, estimate_reason = LocalMeshCache.estimate_decoded_bytes(value)
        if payload_bytes == nil then
            self.stats.estimate_failures = self.stats.estimate_failures + 1
            return false, estimate_reason or "estimate_failed"
        end
    end

    local key_bytes = type(key) == "string" and #key or #tostring(key)
    local entry_bytes, entry_size_ok = add_bytes(
        CACHE_NODE_BASE_BYTES + STRING_BASE_BYTES + key_bytes,
        payload_bytes)
    if not entry_size_ok then
        self.stats.oversize_rejections = self.stats.oversize_rejections + 1
        return false, "entry_exceeds_budget"
    end
    if self.max_entries < 1 or entry_bytes > self.max_bytes then
        self.stats.oversize_rejections = self.stats.oversize_rejections + 1
        return false, "entry_exceeds_budget"
    end

    local existing = self.nodes[key]
    if existing then
        self:_remove_node(existing, false)
        self.stats.updates = self.stats.updates + 1
    end

    now = resolve_now(now, self.now)
    local node = {
        key = key,
        bytes = entry_bytes,
        negative = negative,
        negative_until = negative and (now + self.negative_ttl_seconds) or nil,
    }
    self.nodes[key] = node
    values[key] = negative and false or value
    self:_append_mru(node)
    self.stats.admissions = self.stats.admissions + 1
    if negative then
        self.stats.negative_admissions = self.stats.negative_admissions + 1
    else
        self.stats.positive_admissions = self.stats.positive_admissions + 1
    end
    self:_set_resident(
        self.stats.resident_bytes + entry_bytes,
        self.stats.resident_entries + 1,
        self.stats.resident_negative_entries + (negative and 1 or 0))
    self:_enforce_budget()
    return self.nodes[key] == node, self.nodes[key] == node and nil or "evicted"
end

function LocalMeshCache:finish_publish(key)
    if self.publishing[key] == nil then return false end
    self.publishing[key] = nil
    self.stats.publishing_entries = math.max(0,
        self.stats.publishing_entries - 1)
    self:_enforce_budget()
    return true
end

function LocalMeshCache:remove(key)
    if self.publishing[key] ~= nil then return false end
    return self:_remove_node(self.nodes[key], false)
end

function LocalMeshCache:reconfigure(options)
    options = options or {}
    if options.max_bytes ~= nil then
        self.max_bytes = clamp_integer(options.max_bytes,
            self.max_bytes, 0, MAX_EXACT_BYTES)
    end
    if options.max_entries ~= nil then
        self.max_entries = clamp_integer(options.max_entries,
            self.max_entries, 0, 1000000)
    end
    if options.negative_ttl_seconds ~= nil then
        self.negative_ttl_seconds = finite_nonnegative(
            options.negative_ttl_seconds,
            self.negative_ttl_seconds,
            86400)
    end
    if type(options.now) == "function" then self.now = options.now end
    self:_enforce_budget()
end

function LocalMeshCache:snapshot()
    local out = {}
    for key, value in pairs(self.stats) do out[key] = value end
    out.max_bytes = self.max_bytes
    out.max_entries = self.max_entries
    out.negative_ttl_seconds = self.negative_ttl_seconds
    out.oldest_key = self.head and self.head.key or nil
    out.newest_key = self.tail and self.tail.key or nil
    return out
end

return LocalMeshCache
