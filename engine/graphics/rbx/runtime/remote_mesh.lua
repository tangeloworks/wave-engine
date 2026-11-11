-- download mesh data and hand decoding to the worker pool
-- request() returns a stable handle and the manager owns its decoded mesh
-- pump() runs during update and groups completed downloads into a single scene rebuild
-- stop() cancels pending work and releases the decoded meshes

local RemoteTexture = require("engine/graphics/rbx/runtime/remote_texture")
local StreamAccounting = require("engine/graphics/rbx/mesh_stream_accounting")

local RemoteMesh = {}
RemoteMesh.__index = RemoteMesh

local ThreadDecodePool = {}
ThreadDecodePool.__index = ThreadDecodePool

local DeferredDecodePool = {}
DeferredDecodePool.__index = DeferredDecodePool

local STOP_TOKEN = "__RBX_REMOTE_MESH_DECODE_STOP__"
local DEFAULT_CACHE_DIR = "rbx_remote_mesh_cache"
local DEFAULT_DECODER_METHOD = "decode_remote_mesh"
local DEFAULT_MAX_DECODED_RESIDENT_BYTES = 512 * 1024 * 1024
local decode_pool_sequence = 0

-- Published decoder results are mostly dense Lua-number arrays.  LuaJIT uses
-- compact array storage, but a 16-byte weight per numeric slot is deliberately
-- conservative across the Lua runtimes LÖVE can embed.  Metadata is charged
-- separately with bounded traversal.  this is a deterministic retained-payload
-- budget, not a sample of process RSS, so admission never depends on GC timing
local DECODED_RESULT_BASE_BYTES = 256
local DECODED_ARRAY_BASE_BYTES = 64
local DECODED_NUMERIC_SLOT_BYTES = 16
local DECODED_METADATA_ENTRY_BYTES = 24
local DECODED_STRING_BASE_BYTES = 24
local MAX_DECODED_METADATA_ENTRIES = 4096
local MAX_EXACT_ACCOUNTED_BYTES = 9007199254740991
local DECODED_STREAM_FIELDS = {
    "positions", "normals", "uvs", "colors", "_gpu_colors",
    "normal_ids", "tangents", "indices", "faces", "face_ids", "vertices",
    "weights", "bone_indices",
}
local DECODED_STREAM_FIELD_SET = {}
for index = 1, #DECODED_STREAM_FIELDS do
    DECODED_STREAM_FIELD_SET[DECODED_STREAM_FIELDS[index]] = true
end

local function clamp_integer(value, fallback, minimum, maximum)
    value = math.floor(tonumber(value) or fallback)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function default_now()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function call_method(object, method, ...)
    local fn = object and object[method]
    if type(fn) ~= "function" then return nil, "missing_" .. method end
    local ok, a, b, c = pcall(fn, object, ...)
    if not ok then return nil, tostring(a) end
    return a, b, c
end

local function release_object(object)
    if object and type(object.release) == "function" then
        pcall(object.release, object)
    end
end

local function copy_primitive_descriptor(value)
    local out = {}
    if type(value) ~= "table" then return out end
    for key, item in pairs(value) do
        if type(key) == "string" then
            local item_type = type(item)
            if item_type == "string" or item_type == "number"
                or item_type == "boolean" then
                out[key] = item
            end
        end
    end
    return out
end

local function count_keys(value)
    local count = 0
    if type(value) == "table" then
        for _ in pairs(value) do count = count + 1 end
    end
    return count
end

local function decoded_array_length(value)
    if type(rawlen) == "function" then return rawlen(value) end
    return #value
end

local function add_decoded_bytes(total, amount)
    amount = tonumber(amount)
    if amount == nil or amount ~= amount or amount < 0
        or amount == math.huge or total > MAX_EXACT_ACCOUNTED_BYTES - amount then
        return MAX_EXACT_ACCOUNTED_BYTES, false
    end
    return total + amount, true
end

-- count large known streams from their dense array lengths (constant work per
-- stream), then inspect only bounded metadata.  Unknown large/nested payloads
-- fail closed instead of hiding an uncharged resident allocation.  colors is
-- reserved twice because assets.lua lazily retains a derived _gpu_colors array
-- on the manager-owned result after publication
local function estimate_decoded_resident_bytes(decoded)
    if type(decoded) ~= "table" then
        return nil, "decoded_resident_not_table"
    end
    local total = DECODED_RESULT_BASE_BYTES
    local stream_tables = {}
    local reserved_color_streams = {}
    local colors_count = 0
    local gpu_colors_present = false

    for index = 1, #DECODED_STREAM_FIELDS do
        local field = DECODED_STREAM_FIELDS[index]
        local stream = rawget(decoded, field)
        if stream ~= nil then
            local stream_type = type(stream)
            if stream_type == "table" then
                local count = decoded_array_length(stream)
                if count < 0 then return nil, "decoded_resident_bad_stream" end
                if not stream_tables[stream] then
                    stream_tables[stream] = true
                    local ok
                    total, ok = add_decoded_bytes(total,
                        DECODED_ARRAY_BASE_BYTES
                            + count * DECODED_NUMERIC_SLOT_BYTES)
                    if not ok then return total, "decoded_resident_limit" end
                end
                if field == "colors" then colors_count = count end
                if field == "_gpu_colors" then gpu_colors_present = true end
            elseif stream_type == "string" then
                local ok
                total, ok = add_decoded_bytes(total,
                    DECODED_STRING_BASE_BYTES + #stream)
                if not ok then return total, "decoded_resident_limit" end
            else
                return nil, "decoded_resident_bad_stream"
            end
        end
    end

    if colors_count > 0 and not gpu_colors_present then
        local ok
        total, ok = add_decoded_bytes(total,
            DECODED_ARRAY_BASE_BYTES
                + colors_count * DECODED_NUMERIC_SLOT_BYTES)
        if not ok then return total, "decoded_resident_limit" end
        local colors = rawget(decoded, "colors")
        if type(colors) == "table" then
            reserved_color_streams[colors] = true
        end
    end

    local seen = { [decoded] = true }
    local stack = { decoded }
    local entries = 0
    while #stack > 0 do
        local table_value = stack[#stack]
        stack[#stack] = nil
        for key, value in pairs(table_value) do
            entries = entries + 1
            if entries > MAX_DECODED_METADATA_ENTRIES then
                return nil, "decoded_resident_metadata_limit"
            end
            local ok
            total, ok = add_decoded_bytes(total,
                DECODED_METADATA_ENTRY_BYTES)
            if not ok then return total, "decoded_resident_limit" end

            if type(key) == "string" then
                total, ok = add_decoded_bytes(total,
                    DECODED_STRING_BASE_BYTES + #key)
                if not ok then return total, "decoded_resident_limit" end
            elseif type(key) ~= "number" and type(key) ~= "boolean" then
                return nil, "decoded_resident_bad_metadata_key"
            end

            local value_type = type(value)
            -- Valid v4+ results retain compact render_lods, each with the same
            -- numeric stream contract as the top-level LOD0 result. Recognize
            -- those keys at every metadata depth, iterating their numeric
            -- elements would turn accounting into O(vertices) work and reject
            -- ordinary meshes at the metadata-entry cap
            local known_stream = type(key) == "string"
                and DECODED_STREAM_FIELD_SET[key] == true
            if value_type == "table" then
                if known_stream then
                    if not stream_tables[value] then
                        stream_tables[value] = true
                        local count = decoded_array_length(value)
                        total, ok = add_decoded_bytes(total,
                            DECODED_ARRAY_BASE_BYTES
                                + count * DECODED_NUMERIC_SLOT_BYTES)
                        if not ok then return total, "decoded_resident_limit" end
                    end
                    if key == "colors" and not reserved_color_streams[value] then
                        reserved_color_streams[value] = true
                        total, ok = add_decoded_bytes(total,
                            DECODED_ARRAY_BASE_BYTES
                                + decoded_array_length(value)
                                    * DECODED_NUMERIC_SLOT_BYTES)
                        if not ok then return total, "decoded_resident_limit" end
                    end
                elseif not stream_tables[value] and not seen[value] then
                    seen[value] = true
                    total, ok = add_decoded_bytes(total,
                        DECODED_ARRAY_BASE_BYTES)
                    if not ok then return total, "decoded_resident_limit" end
                    stack[#stack + 1] = value
                end
            elseif value_type == "string" then
                total, ok = add_decoded_bytes(total,
                    DECODED_STRING_BASE_BYTES + #value)
                if not ok then return total, "decoded_resident_limit" end
            elseif value_type == "number" then
                total, ok = add_decoded_bytes(total,
                    DECODED_NUMERIC_SLOT_BYTES)
                if not ok then return total, "decoded_resident_limit" end
            elseif value_type == "boolean" or value_type == "nil" then
                -- Entry storage above owns these immediate scalar values
            elseif value_type == "userdata" then
                local method_ok, get_size = pcall(function()
                    return value.getSize
                end)
                if not method_ok or type(get_size) ~= "function" then
                    return nil, "decoded_resident_unaccountable_userdata"
                end
                local size_ok, size = pcall(get_size, value)
                if not size_ok or type(size) ~= "number" or size < 0 then
                    return nil, "decoded_resident_unaccountable_userdata"
                end
                total, ok = add_decoded_bytes(total, size)
                if not ok then return total, "decoded_resident_limit" end
            else
                return nil, "decoded_resident_unaccountable_type"
            end
        end
    end
    return math.floor(total), nil
end

-- Renderer fanout needs deterministic, allocation-free traversal, while the
-- manager must never keep scene parts alive.  the descriptor map remains the
-- authoritative binding set, these parallel weak indexes provide stable slots
-- and a generation token which changes whenever a slot gets a new occupant
local function next_consumer_bind_revision(variant)
    local revision = (tonumber(variant._consumer_bind_sequence) or 0) + 1
    variant._consumer_bind_sequence = revision
    return revision
end

-- Binding a popular mesh happens in the map-build hot path.  never walk the
-- whole weak slot array here: N live consumers would otherwise require O(N^2)
-- probes.  a small rotating budget still recovers GC-only holes over time,
-- while explicit unbinds continue to feed the O(1) free list above it
local CONSUMER_RECLAIM_PROBES_PER_BIND = 8

local function allocate_consumer_slot(variant)
    local order = variant.consumer_order
    local free_slots = variant._consumer_free_slots
    local free_set = variant._consumer_free_slot_set

    -- explicit unbinds are O(1) and take priority.  entries are validated on
    -- pop so teardown/repair paths cannot hand out a slot that became occupied
    while free_slots and #free_slots > 0 do
        local index = #free_slots
        local slot = free_slots[index]
        free_slots[index] = nil
        if free_set then free_set[slot] = nil end
        if type(slot) == "number" and slot >= 1
            and slot <= (variant.consumer_order_count or 0)
            and order[slot] == nil then
            return slot
        end
    end

    -- Weak values disappear without an unbind callback. Reclaim those holes
    -- lazily with bounded rotating work, the cursor advances even when this
    -- bind has to append, so later binds eventually cover the whole array
    local count = variant.consumer_order_count or 0
    if count > 0 then
        local start = tonumber(variant._consumer_reclaim_cursor) or 1
        if start < 1 or start > count then start = 1 end
        local probes = math.min(count, CONSUMER_RECLAIM_PROBES_PER_BIND)
        for offset = 0, probes - 1 do
            local slot = ((start + offset - 1) % count) + 1
            variant._consumer_reclaim_probe_count =
                (variant._consumer_reclaim_probe_count or 0) + 1
            if order[slot] == nil and not (free_set and free_set[slot]) then
                variant._consumer_reclaim_cursor = (slot % count) + 1
                return slot
            end
        end
        variant._consumer_reclaim_cursor =
            ((start + probes - 1) % count) + 1
    end

    count = count + 1
    variant.consumer_order_count = count
    if variant._consumer_reclaim_cursor == nil then
        variant._consumer_reclaim_cursor = 1
    end
    return count
end

local function clear_variant_consumers(variant)
    variant.consumers = nil
    variant.consumer_order = nil
    variant.consumer_order_count = 0
    variant.consumer_bind_revision = nil
    variant.consumer_result_revision = nil
    variant.consumer_slots = nil
    variant._consumer_bind_sequence = nil
    variant._consumer_free_slots = nil
    variant._consumer_free_slot_set = nil
    variant._consumer_reclaim_cursor = nil
    variant._consumer_reclaim_probe_count = nil
end

local function normalized_variant_component(value, fallback)
    value = tostring(value == nil and fallback or value)
    if value == "" or #value > 96 or value:find("|", 1, true)
        or not value:match("^[%w_%.:%-]+$") then
        return nil
    end
    return value
end

function RemoteMesh.variant_key(asset_id, asset_type, decode_policy, asset_context)
    asset_id = RemoteTexture.extract_asset_id(asset_id)
    asset_type = normalized_variant_component(asset_type, "MeshPart")
    decode_policy = normalized_variant_component(decode_policy, "render")
    if not asset_id or not asset_type or not decode_policy then return nil end
    local key = table.concat({ asset_id, asset_type, decode_policy }, "|")
    if type(asset_context) == "table" then
        local paths = require("engine/graphics/rbx/runtime/asset_paths")
        key = key .. "\0assets:" .. paths.context_key(
            asset_context.map_path, asset_context.asset_root)
    end
    return key
end

-- use the deferred decoder when a project supplies a single-threaded decode function
-- the worker pool handles decoding off the main thread
function DeferredDecodePool.new(config)
    if type(config.decoder) ~= "function" then return nil, "decoder_unavailable" end
    return setmetatable({
        decoder = config.decoder,
        filesystem = config.filesystem,
        max_encoded_bytes = config.max_encoded_bytes,
        jobs = {},
        stopped = false,
    }, DeferredDecodePool)
end

function DeferredDecodePool:enqueue(job)
    if self.stopped then return false, "stopped" end
    self.jobs[#self.jobs + 1] = job
    return true
end

local function decode_failure(job, reason, retryable)
    return {
        variant_key = job and job.variant_key,
        generation = job and job.generation,
        source_revision = job and job.source_revision,
        manager_epoch = job and job.manager_epoch,
        attempt = job and job.attempt,
        ok = false,
        error = tostring(reason or "decode_failed"),
        retryable = retryable == true,
    }
end

function DeferredDecodePool:pop()
    if self.stopped or #self.jobs == 0 then return nil end
    local job = table.remove(self.jobs, 1)
    local data = job.data
    if data == nil and type(job.cache_path) == "string" then
        local fs = self.filesystem
        if not fs or type(fs.getInfo) ~= "function" or type(fs.read) ~= "function" then
            return decode_failure(job, "filesystem_unavailable", true)
        end
        local info_ok, info = pcall(fs.getInfo, job.cache_path, "file")
        local size = info_ok and type(info) == "table" and tonumber(info.size) or nil
        if not size or size <= 0 then
            return decode_failure(job, "source_read_failed", true)
        end
        if size > self.max_encoded_bytes then
            return decode_failure(job, "encoded_too_large", false)
        end
        local read_ok, read_data = pcall(fs.read, job.cache_path)
        if not read_ok or type(read_data) ~= "string" or #read_data ~= size then
            return decode_failure(job, "source_read_failed", true)
        end
        data = read_data
    end
    if type(data) ~= "string" or data == "" then
        return decode_failure(job, "source_payload_missing", true)
    end
    if #data > self.max_encoded_bytes then
        return decode_failure(job, "encoded_too_large", false)
    end
    local ok, decoded, reason, retryable = pcall(self.decoder, data, job)
    if not ok then return decode_failure(job, "decoder_error:" .. tostring(decoded), false) end
    if decoded == nil then return decode_failure(job, reason, retryable) end
    return {
        variant_key = job.variant_key,
        generation = job.generation,
        source_revision = job.source_revision,
        manager_epoch = job.manager_epoch,
        attempt = job.attempt,
        ok = true,
        decoded = decoded,
    }
end

function DeferredDecodePool:health()
    return not self.stopped, self.stopped and "stopped" or nil
end

function DeferredDecodePool:stop()
    if self.stopped then return false end
    self.stopped = true
    self.jobs = {}
    return true
end

function ThreadDecodePool.new(config)
    if type(config.decoder_module) ~= "string" or config.decoder_module == "" then
        return nil, "decoder_module_unavailable"
    end
    if not (love and love.thread and love.thread.getChannel and love.thread.newThread) then
        return nil, "love_thread_unavailable"
    end
    decode_pool_sequence = decode_pool_sequence + 1
    local tag = tostring({}):gsub("[^%w]", "")
    local request_name = string.format("rbx_remote_mesh_decode_req_%d_%s",
        decode_pool_sequence, tag)
    local response_name = string.format("rbx_remote_mesh_decode_res_%d_%s",
        decode_pool_sequence, tag)
    local self = setmetatable({
        request = love.thread.getChannel(request_name),
        response = love.thread.getChannel(response_name),
        threads = {},
        stopped = false,
    }, ThreadDecodePool)
    local worker_count = clamp_integer(config.worker_count, 2, 1, 4)
    for index = 1, worker_count do
        local ok_thread, thread = pcall(love.thread.newThread,
            require("engine/root") .. "/graphics/rbx/remote_mesh_decode_thread.lua")
        if ok_thread and thread then
            local ok_start = pcall(thread.start, thread,
                request_name, response_name, index,
                config.decoder_module,
                config.decoder_method or DEFAULT_DECODER_METHOD,
                config.max_encoded_bytes)
            if ok_start then
                self.threads[#self.threads + 1] = thread
            else
                release_object(thread)
            end
        end
    end
    if #self.threads == 0 then
        if self.request.clear then pcall(self.request.clear, self.request) end
        if self.response.clear then pcall(self.response.clear, self.response) end
        release_object(self.request)
        release_object(self.response)
        return nil, "worker_start_failed"
    end
    return self
end

function ThreadDecodePool:enqueue(job)
    if self.stopped then return false, "stopped" end
    local ok, pushed = pcall(self.request.push, self.request, job)
    if not ok or pushed == false then return false, tostring(pushed) end
    return true
end

function ThreadDecodePool:pop()
    if self.stopped then return nil end
    local ok, result = pcall(self.response.pop, self.response)
    if not ok then return nil end
    return result
end

function ThreadDecodePool:health()
    if self.stopped then return false, "stopped" end
    for index = 1, #self.threads do
        local thread = self.threads[index]
        local error_ok, thread_error = pcall(thread.getError, thread)
        if error_ok and thread_error then
            return false, "worker_" .. index .. ":" .. tostring(thread_error)
        end
        if thread.isRunning then
            local running_ok, running = pcall(thread.isRunning, thread)
            if running_ok and running == false then
                return false, "worker_" .. index .. "_stopped"
            end
        end
    end
    return true
end

function ThreadDecodePool:stop()
    if self.stopped then return false end
    self.stopped = true
    if self.request and self.request.clear then pcall(self.request.clear, self.request) end
    for _ = 1, #self.threads do
        pcall(self.request.push, self.request, STOP_TOKEN)
    end
    for index = 1, #self.threads do
        local thread = self.threads[index]
        if thread and thread.wait then pcall(thread.wait, thread) end
    end
    if self.response then
        while true do
            local ok, result = pcall(self.response.pop, self.response)
            if not ok or result == nil then break end
        end
        if self.response.clear then pcall(self.response.clear, self.response) end
    end
    if self.request and self.request.clear then pcall(self.request.clear, self.request) end
    for index = 1, #self.threads do release_object(self.threads[index]) end
    release_object(self.request)
    release_object(self.response)
    self.threads = {}
    self.request = nil
    self.response = nil
    return true
end

local function default_decoded_validator(decoded, max_vertices, max_triangles)
    if type(decoded) ~= "table" then return false, "decoded_not_table" end
    local vertex_count, triangle_count, _, _, reason =
        StreamAccounting.collect(decoded)
    if vertex_count == nil then
        if reason == "invalid_vertex_count" then
            return false, "decoded_vertex_count_invalid"
        elseif reason == "invalid_triangle_count" then
            return false, "decoded_triangle_count_invalid"
        elseif reason == "retained_stream_limit" then
            return false, "decoded_stream_limit"
        end
        return false, "decoded_geometry_invalid"
    end
    if vertex_count > max_vertices then
        return false, "decoded_vertex_limit"
    end
    if triangle_count > max_triangles then
        return false, "decoded_triangle_limit"
    end
    return true
end

local function make_acquisition_bridge(manager)
    local bridge = { manager = manager }
    function bridge:_on_remote_texture_source_ready(state)
        local current = self.manager
        if current then current:_on_acquisition_ready(state) end
    end
    return bridge
end

local function make_default_acquisition(manager, options)
    local validator = options.encoded_validator
    if type(validator) ~= "function" then
        validator = function(data)
            return type(data) == "string" and data ~= "", "empty"
        end
    end
    local acquisition_options = {
        enabled = manager.enabled,
        now = manager.now,
        filesystem = manager.filesystem,
        validator = validator,
        logger = manager.logger,
        worker_count = manager.network_worker_count,
        max_queue = manager.max_network_queue,
        max_encoded_bytes = manager.max_encoded_bytes,
        connect_timeout_seconds = options.connect_timeout_seconds,
        total_timeout_seconds = options.total_timeout_seconds,
        max_attempts = manager.max_network_attempts,
        retry_backoff_seconds = manager.network_retry_backoff_seconds,
        negative_ttl_seconds = manager.network_negative_ttl_seconds,
        max_completions_per_pump = manager.max_network_completions_per_pump,
        max_dispatch_per_pump = manager.max_network_dispatch_per_pump,
        pump_budget_ms = options.network_pump_budget_ms or 2,
        cache_dir = options.cache_dir or DEFAULT_CACHE_DIR,
    }
    if type(options.transport_pool_factory) == "function" then
        acquisition_options.pool_factory = options.transport_pool_factory
    end
    return RemoteTexture.new(manager._acquisition_bridge, acquisition_options)
end

function RemoteMesh.new(owner, options)
    options = options or {}
    local self = setmetatable({}, RemoteMesh)
    self.owner = owner
    self.enabled = options.enabled == true
    self.stopped = false
    self.epoch = 1
    self.now = type(options.now) == "function" and options.now or default_now
    self.filesystem = options.filesystem or (love and love.filesystem)
    self.logger = type(options.logger) == "function" and options.logger or print
    self.warned = {}

    self.max_sources = clamp_integer(options.max_sources, 2048, 1, 65536)
    self.source_idle_ttl_seconds = math.max(0,
        math.min(3600, tonumber(options.source_idle_ttl_seconds) or 30))
    self.max_variants = clamp_integer(options.max_variants, 4096, 1, 131072)
    self.max_variants_per_source = clamp_integer(
        options.max_variants_per_source, 8, 1, 256)
    self.max_network_queue = clamp_integer(options.max_network_queue, 256, 1, 4096)
    self.max_encoded_bytes = clamp_integer(options.max_encoded_bytes,
        32 * 1024 * 1024, 1024, 64 * 1024 * 1024)
    self.network_worker_count = clamp_integer(options.network_worker_count, 2, 1, 4)
    self.max_network_attempts = clamp_integer(options.max_network_attempts, 3, 1, 8)
    self.network_retry_backoff_seconds = math.max(0.05,
        math.min(30, tonumber(options.network_retry_backoff_seconds) or 0.5))
    self.network_negative_ttl_seconds = math.max(1,
        math.min(3600, tonumber(options.network_negative_ttl_seconds) or 60))
    self.max_network_completions_per_pump = clamp_integer(
        options.max_network_completions_per_pump, 4, 1, 64)
    self.max_network_dispatch_per_pump = clamp_integer(
        options.max_network_dispatch_per_pump, 8, 1, 128)

    self.decode_worker_count = clamp_integer(options.decode_worker_count, 2, 1, 4)
    self.max_decode_queue = clamp_integer(options.max_decode_queue, 128, 1, 4096)
    self.max_decode_outstanding = clamp_integer(
        options.max_decode_outstanding, self.decode_worker_count, 1, 32)
    self.max_decode_attempts = clamp_integer(options.max_decode_attempts, 2, 1, 8)
    self.decode_retry_backoff_seconds = math.max(0.01,
        math.min(30, tonumber(options.decode_retry_backoff_seconds) or 0.25))
    self.decode_negative_ttl_seconds = math.max(1,
        math.min(3600, tonumber(options.decode_negative_ttl_seconds) or 600))
    self.max_decode_completions_per_pump = clamp_integer(
        options.max_decode_completions_per_pump, 4, 1, 256)
    self.max_decode_dispatch_per_pump = clamp_integer(
        options.max_decode_dispatch_per_pump, 8, 1, 256)
    self.max_state_scans_per_pump = clamp_integer(
        options.max_state_scans_per_pump, 64, 1, 4096)
    self.pump_budget_seconds = math.max(0.0001,
        math.min(0.05, (tonumber(options.pump_budget_ms) or 3) / 1000))
    self.wave_quiet_seconds = math.max(0,
        math.min(5, tonumber(options.wave_quiet_seconds) or 0.1))
    self.max_decoded_vertices = clamp_integer(options.max_decoded_vertices,
        2000000, 1, 20000000)
    self.max_decoded_triangles = clamp_integer(options.max_decoded_triangles,
        4000000, 1, 40000000)
    self.max_decoded_resident_bytes = clamp_integer(
        options.max_decoded_resident_bytes,
        DEFAULT_MAX_DECODED_RESIDENT_BYTES, 1024, 4 * 1024 * 1024 * 1024)
    self.decoded_resident_bytes = 0
    self.validate_decoded = type(options.validate_decoded) == "function"
        and options.validate_decoded or function(decoded)
            return default_decoded_validator(decoded,
                self.max_decoded_vertices, self.max_decoded_triangles)
        end
    self.release_decoded = type(options.release_decoded) == "function"
        and options.release_decoded or nil
    self.notify_variant_ready = options.notify_variant_ready == true

    self.sources = {}
    self.source_order = {}
    self.source_scan_cursor = 1
    self.source_count = 0
    self.variants = {}
    self.variant_order = {}
    self.variant_scan_cursor = 1
    self.variant_count = 0
    self.decode_waiting = {}
    self.decode_waiting_head = 1
    self.decode_outstanding = 0
    self.generation_counter = 0
    self.access_counter = 0

    self.wave = {
        id = 0,
        active = false,
        requested = 0,
        pending = 0,
        ready = 0,
        failed = 0,
        started_at = 0,
        last_activity_at = 0,
        tokens = {},
    }
    self.wave_token_counter = 0
    self.last_wave_snapshot = nil

    self.stats = {
        requests = 0,
        deduplicated = 0,
        rejected_references = 0,
        rejected_variants = 0,
        source_limit_rejections = 0,
        source_evictions = 0,
        acquisition_source_evictions = 0,
        variant_limit_rejections = 0,
        variant_evictions = 0,
        consumers_bound = 0,
        consumers_unbound = 0,
        decode_queued = 0,
        decode_scheduled = 0,
        decode_completions = 0,
        decode_ready = 0,
        decode_failures = 0,
        decode_retries = 0,
        decode_negative_transitions = 0,
        decode_queue_backpressure = 0,
        decode_pool_start_failures = 0,
        decode_pool_runtime_failures = 0,
        stale_decode_completions = 0,
        decoded_limit_rejections = 0,
        decoded_resident_bytes = 0,
        decoded_resident_peak_bytes = 0,
        decoded_resident_evictions = 0,
        decoded_resident_evicted_bytes = 0,
        decoded_resident_rejections = 0,
        decoded_resident_rejected_bytes = 0,
        decoded_resident_estimate_failures = 0,
        variant_ready_notifications = 0,
        wave_notifications = 0,
        waves_started = 0,
        waves_settled = 0,
        pump_ms_last = 0,
        pump_ms_max = 0,
        stopped = false,
    }

    self._acquisition_bridge = make_acquisition_bridge(self)
    self.acquisition = nil
    self.owns_acquisition = options.acquisition == nil
    if options.acquisition then
        self.acquisition = options.acquisition
    elseif type(options.acquisition_factory) == "function" then
        local ok, acquisition, reason = pcall(options.acquisition_factory,
            self._acquisition_bridge, options)
        if ok then
            self.acquisition = acquisition
            self.acquisition_error = reason
        else
            self.acquisition_error = tostring(acquisition)
        end
    else
        self.acquisition = make_default_acquisition(self, options)
    end
    self.stop_injected_acquisition = options.stop_injected_acquisition ~= false

    self.decode_pool = options.decode_pool
    self.decode_pool_factory = nil
    if type(options.decode_pool_factory) == "function" then
        self.decode_pool_factory = options.decode_pool_factory
    elseif type(options.decoder_module) == "string" and options.decoder_module ~= "" then
        self.decode_pool_factory = function(config)
            return ThreadDecodePool.new(config)
        end
    elseif type(options.decoder) == "function" then
        self.decode_pool_factory = function(config)
            return DeferredDecodePool.new(config)
        end
    end
    self.decoder_module = options.decoder_module
    self.decoder_method = options.decoder_method or DEFAULT_DECODER_METHOD
    self.decoder = options.decoder
    self.decode_pool_is_injected = options.decode_pool ~= nil
    return self
end

function RemoteMesh:_log_once(key, message)
    if self.warned[key] then return end
    self.warned[key] = true
    pcall(self.logger, message)
end

function RemoteMesh:_next_access()
    self.access_counter = self.access_counter + 1
    return self.access_counter
end

function RemoteMesh:_next_generation()
    self.generation_counter = self.generation_counter + 1
    return self.generation_counter
end

function RemoteMesh:_release_result(result)
    if result == nil then return end
    if self.release_decoded then
        pcall(self.release_decoded, result)
    elseif type(result) == "table" and type(result.release) == "function" then
        pcall(result.release, result)
    end
end

function RemoteMesh:_set_decoded_resident_bytes(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    self.decoded_resident_bytes = value
    self.stats.decoded_resident_bytes = value
    self.stats.decoded_resident_peak_bytes = math.max(
        self.stats.decoded_resident_peak_bytes, value)
end

function RemoteMesh:_release_variant_result(variant)
    if type(variant) ~= "table" then return 0 end
    local result = variant.result
    local bytes = math.max(0,
        math.floor(tonumber(variant.decoded_resident_bytes) or 0))
    if bytes > 0 then
        self:_set_decoded_resident_bytes(
            math.max(0, self.decoded_resident_bytes - bytes))
    end
    variant.decoded_resident_bytes = 0
    variant.result = nil
    variant.mesh = nil
    self:_release_result(result)
    return bytes
end

function RemoteMesh:_wave_snapshot(settled)
    local wave = self.wave
    return {
        id = wave.id,
        active = wave.active,
        settled = settled == true,
        requested = wave.requested,
        pending = wave.pending,
        ready = wave.ready,
        failed = wave.failed,
        started_at = wave.started_at,
        last_activity_at = wave.last_activity_at,
    }
end

function RemoteMesh:_wave_add(variant)
    local now = self.now()
    local wave = self.wave
    if not wave.active then
        wave.id = wave.id + 1
        wave.active = true
        wave.requested = 0
        wave.pending = 0
        wave.ready = 0
        wave.failed = 0
        wave.started_at = now
        wave.last_activity_at = now
        wave.tokens = {}
        self.stats.waves_started = self.stats.waves_started + 1
    end
    if variant.wave_token and wave.tokens[variant.variant_key] == variant.wave_token then
        wave.last_activity_at = now
        return
    end
    self.wave_token_counter = self.wave_token_counter + 1
    variant.wave_token = self.wave_token_counter
    wave.tokens[variant.variant_key] = variant.wave_token
    wave.requested = wave.requested + 1
    wave.pending = wave.pending + 1
    wave.last_activity_at = now
end

function RemoteMesh:_wave_finish(variant, success)
    local wave = self.wave
    local token = variant and variant.wave_token
    if not token or wave.tokens[variant.variant_key] ~= token then return false end
    wave.tokens[variant.variant_key] = nil
    variant.wave_token = nil
    wave.pending = math.max(0, wave.pending - 1)
    if success then wave.ready = wave.ready + 1 else wave.failed = wave.failed + 1 end
    wave.last_activity_at = self.now()
    return true
end

function RemoteMesh:_maybe_settle_wave(now)
    local wave = self.wave
    now = now or self.now()
    if not wave.active or wave.pending > 0
        or now - wave.last_activity_at < self.wave_quiet_seconds then
        return false
    end
    wave.active = false
    local snapshot = self:_wave_snapshot(true)
    self.last_wave_snapshot = snapshot
    self.stats.waves_settled = self.stats.waves_settled + 1
    local owner = self.owner
    if owner and type(owner._on_remote_mesh_wave_settled) == "function" then
        self.stats.wave_notifications = self.stats.wave_notifications + 1
        pcall(owner._on_remote_mesh_wave_settled, owner, snapshot)
    end
    return true
end

function RemoteMesh:is_wave_settled(now)
    self:_maybe_settle_wave(now)
    if not self.wave.active then
        return true, self.last_wave_snapshot or self:_wave_snapshot(true)
    end
    return false, self:_wave_snapshot(false)
end

function RemoteMesh:_new_source(asset_id)
    local source = {
        asset_id = asset_id,
        status = "new",
        last_observed_status = nil,
        last_error = nil,
        acquisition_state = nil,
        acquisition_handle = nil,
        ready_revision = 0,
        ready_marker = nil,
        cache_path = nil,
        data = nil,
        variants = {},
        variant_count = 0,
        last_used = self:_next_access(),
        last_used_at = self.now(),
    }
    self.sources[asset_id] = source
    self.source_order[#self.source_order + 1] = asset_id
    self.source_count = self.source_count + 1
    self:_compact_source_order()
    return source
end

function RemoteMesh:_compact_source_order()
    if #self.source_order <= self.max_sources * 2 + 32 then return end
    local compact = {}
    local seen = {}
    for index = 1, #self.source_order do
        local asset_id = self.source_order[index]
        if self.sources[asset_id] and not seen[asset_id] then
            seen[asset_id] = true
            compact[#compact + 1] = asset_id
        end
    end
    self.source_order = compact
    self.source_scan_cursor = 1
end

function RemoteMesh:_new_variant(source, variant_key, asset_type, decode_policy)
    local variant = {
        asset_id = source.asset_id,
        asset_type = asset_type,
        decode_policy = decode_policy,
        variant_key = variant_key,
        source = source,
        status = "waiting_source",
        state = "waiting_source",
        pending = true,
        ready = false,
        revision = 0,
        generation = 0,
        target_source_revision = 0,
        source_revision = 0,
        decode_attempt = 0,
        decode_queued = false,
        decode_inflight = false,
        next_decode_at = 0,
        negative_until = 0,
        result = nil,
        mesh = nil,
        decoded_resident_bytes = 0,
        last_error = nil,
        consumers = setmetatable({}, { __mode = "k" }),
        -- public renderer fanout contract. Values/keys are weak so neither
        -- traversal direction owns the consumer. consumer_order_count is the
        -- highest allocated slot (holes are expected and reusable)
        consumer_order = setmetatable({}, { __mode = "v" }),
        consumer_order_count = 0,
        consumer_bind_revision = {},
        -- result revision visible when this slot acquired its current consumer
        -- Renderer publication fanout can therefore exclude consumers which
        -- bound after that publication and already observed the ready result
        consumer_result_revision = {},
        consumer_slots = setmetatable({}, { __mode = "k" }),
        _consumer_bind_sequence = 0,
        _consumer_free_slots = {},
        _consumer_free_slot_set = {},
        _consumer_reclaim_cursor = 1,
        last_used = self:_next_access(),
    }
    self.variants[variant_key] = variant
    self.variant_order[#self.variant_order + 1] = variant_key
    self.variant_count = self.variant_count + 1
    source.variants[variant_key] = true
    source.variant_count = source.variant_count + 1
    return variant
end

function RemoteMesh:_variant_has_consumers(variant)
    return variant and variant.consumers and next(variant.consumers) ~= nil
end

function RemoteMesh:_remove_variant(variant)
    if not variant or self.variants[variant.variant_key] ~= variant then return false end
    self:_wave_finish(variant, false)
    self:_release_variant_result(variant)
    variant.ready = false
    variant.pending = false
    variant.status = "evicted"
    variant.state = "evicted"
    clear_variant_consumers(variant)
    self.variants[variant.variant_key] = nil
    local source = variant.source
    if source and source.variants[variant.variant_key] then
        source.variants[variant.variant_key] = nil
        source.variant_count = math.max(0, source.variant_count - 1)
    end
    self.variant_count = math.max(0, self.variant_count - 1)
    self.stats.variant_evictions = self.stats.variant_evictions + 1
    return true
end

function RemoteMesh:_source_is_terminal_evictable(source, now, ignore_idle_ttl)
    if not source or (source.status ~= "ready" and source.status ~= "negative") then
        return false
    end
    now = now or self.now()
    if ignore_idle_ttl ~= true
        and now - (tonumber(source.last_used_at) or now)
            < self.source_idle_ttl_seconds then
        return false
    end
    for variant_key in pairs(source.variants) do
        local variant = self.variants[variant_key]
        if variant then
            if self:_variant_has_consumers(variant) or variant.pending
                or variant.decode_queued or variant.decode_inflight
                or variant.wave_token ~= nil then
                return false
            end
            if not variant.ready and variant.status ~= "negative" then return false end
        end
    end
    return true
end

function RemoteMesh:_forget_acquisition_source(source)
    local acquisition = self.acquisition
    if not acquisition or not source then return false end
    local sampler_key = "remote_mesh_source|" .. source.asset_id
    if type(acquisition.forget) == "function" then
        local forgotten = call_method(acquisition, "forget", source.asset_id, sampler_key)
        if forgotten == true then
            self.stats.acquisition_source_evictions =
                self.stats.acquisition_source_evictions + 1
            return true
        end
    end

    -- the default acquisition is a manager-private RemoteTexture instance.  it
    -- intentionally has no general-purpose eviction API, so retire only our
    -- terminal sampler and remove its source when no other sampler references
    -- remain.  persistent encoded bytes stay on disk and are revalidated on a
    -- future request, only in-memory state is forgotten
    local state = type(acquisition.sources) == "table"
        and acquisition.sources[source.asset_id] or nil
    local handle = type(acquisition.sampler_handles) == "table"
        and acquisition.sampler_handles[sampler_key] or nil
    if handle then
        handle.live_bindings = nil
        handle.source = nil
        acquisition.sampler_handles[sampler_key] = nil
    end
    if state and type(state.sampler_keys) == "table" then
        state.sampler_keys[sampler_key] = nil
    end
    if state and (state.status == "ready" or state.status == "negative")
        and (type(state.sampler_keys) ~= "table" or next(state.sampler_keys) == nil) then
        acquisition.sources[source.asset_id] = nil
        self.stats.acquisition_source_evictions =
            self.stats.acquisition_source_evictions + 1
        return true
    end
    return handle ~= nil
end

function RemoteMesh:_remove_source(source)
    if not source or self.sources[source.asset_id] ~= source then return false end
    local variant_keys = {}
    for variant_key in pairs(source.variants) do
        variant_keys[#variant_keys + 1] = variant_key
    end
    for index = 1, #variant_keys do
        self:_remove_variant(self.variants[variant_keys[index]])
    end
    self:_forget_acquisition_source(source)
    self.sources[source.asset_id] = nil
    self.source_count = math.max(0, self.source_count - 1)
    source.acquisition_state = nil
    source.acquisition_handle = nil
    source.cache_path = nil
    source.data = nil
    source.variants = {}
    source.variant_count = 0
    source.status = "evicted"
    self.stats.source_evictions = self.stats.source_evictions + 1
    return true
end

function RemoteMesh:_evict_terminal_source(now, ignore_idle_ttl)
    local candidate = nil
    for _, source in pairs(self.sources) do
        if self:_source_is_terminal_evictable(
                source, now, ignore_idle_ttl)
            and (not candidate or source.last_used < candidate.last_used
                or (source.last_used == candidate.last_used
                    and source.asset_id < candidate.asset_id)) then
            candidate = source
        end
    end
    if not candidate then return false end
    local removed = self:_remove_source(candidate)
    if removed then self:_compact_source_order() end
    return removed
end

function RemoteMesh:_evict_variant(preferred_source)
    local candidate = nil
    for _, variant in pairs(self.variants) do
        local source_matches = preferred_source == nil or variant.source == preferred_source
        if source_matches and not variant.decode_queued and not variant.decode_inflight
            and not variant.pending and not self:_variant_has_consumers(variant)
            and (not candidate or variant.last_used < candidate.last_used) then
            candidate = variant
        end
    end
    return candidate and self:_remove_variant(candidate) or false
end

function RemoteMesh:_compact_variant_order()
    if #self.variant_order <= self.max_variants * 2 + 32 then return end
    local compact = {}
    local seen = {}
    for index = 1, #self.variant_order do
        local key = self.variant_order[index]
        if self.variants[key] and not seen[key] then
            seen[key] = true
            compact[#compact + 1] = key
        end
    end
    self.variant_order = compact
    self.variant_scan_cursor = 1
end

function RemoteMesh:bind(handle, consumer, descriptor)
    if type(handle) ~= "table" or self.variants[handle.variant_key] ~= handle
        or handle.consumers == nil then
        return false, "invalid_handle"
    end
    local consumer_type = type(consumer)
    if consumer_type ~= "table" and consumer_type ~= "userdata"
        and consumer_type ~= "function" and consumer_type ~= "thread" then
        return false, "invalid_consumer"
    end
    local slot = handle.consumer_slots and handle.consumer_slots[consumer] or nil
    local already_bound = type(slot) == "number"
        and handle.consumer_order[slot] == consumer
    if not already_bound then
        slot = allocate_consumer_slot(handle)
        handle.consumer_order[slot] = consumer
        handle.consumer_slots[consumer] = slot
        handle.consumer_bind_revision[slot] =
            next_consumer_bind_revision(handle)
        handle.consumer_result_revision[slot] =
            tonumber(handle.revision) or 0
        self.stats.consumers_bound = self.stats.consumers_bound + 1
        handle.consumers[consumer] = copy_primitive_descriptor(descriptor)
    elseif descriptor ~= nil then
        -- Rebinding the same consumer updates metadata in place.  Slot and
        -- revision stay stable: no occupancy transition occurred, and queued
        -- renderer work for this consumer remains valid
        handle.consumers[consumer] = copy_primitive_descriptor(descriptor)
    end
    handle.last_used = self:_next_access()
    if handle.source then
        handle.source.last_used = handle.last_used
        handle.source.last_used_at = self.now()
    end
    return true
end

function RemoteMesh:unbind(handle, consumer)
    if type(handle) ~= "table" or handle.consumers == nil
        or handle.consumer_slots == nil then return false end
    local slot = handle.consumer_slots[consumer]
    if type(slot) ~= "number" or handle.consumer_order[slot] ~= consumer then
        return false
    end
    handle.consumers[consumer] = nil
    handle.consumer_slots[consumer] = nil
    handle.consumer_order[slot] = nil
    handle.consumer_bind_revision[slot] = next_consumer_bind_revision(handle)
    handle.consumer_result_revision[slot] = nil
    local free_set = handle._consumer_free_slot_set
    if not free_set[slot] then
        free_set[slot] = true
        local free_slots = handle._consumer_free_slots
        free_slots[#free_slots + 1] = slot
    end
    handle.last_used = self:_next_access()
    if handle.source then
        handle.source.last_used = handle.last_used
        handle.source.last_used_at = self.now()
    end
    self.stats.consumers_unbound = self.stats.consumers_unbound + 1
    return true
end

function RemoteMesh:_request_acquisition(source)
    local acquisition = self.acquisition
    if not acquisition then
        source.status = "negative"
        source.last_error = self.acquisition_error or "acquisition_unavailable"
        return false
    end
    local state, handle, status = call_method(acquisition, "request",
        source.asset_id,
        "remote_mesh_source|" .. source.asset_id,
        { role = "mesh_source", asset_id = source.asset_id })
    if state == nil then
        source.status = "negative"
        source.last_error = tostring(status or handle or "acquisition_failed")
        return false
    end
    source.acquisition_state = state
    source.acquisition_handle = handle
    if status then source.status = tostring(status) end
    return true
end

function RemoteMesh:_source_status(source)
    local state = source.acquisition_state
    local handle = source.acquisition_handle
    local status = state and state.status or (handle and (handle.state or handle.status))
    local revision = tonumber(state and state.revision or (handle and handle.revision))
    local cache_path = state and state.cache_path or (handle and handle.cache_path)
    local data = state and state.data or (handle and handle.data)
    local last_error = state and state.last_error or (handle and handle.last_error)
    return tostring(status or source.status or "new"), revision, cache_path, data, last_error
end

function RemoteMesh:_queue_depth()
    return math.max(0, #self.decode_waiting - self.decode_waiting_head + 1)
end

function RemoteMesh:_compact_decode_queue(force)
    local head = self.decode_waiting_head
    if not force and head < 128 and head <= #self.decode_waiting / 2 then return end
    local compact = {}
    for index = head, #self.decode_waiting do
        local entry = self.decode_waiting[index]
        local variant = entry and self.variants[entry.variant_key]
        if variant and variant.generation == entry.generation and variant.decode_queued then
            compact[#compact + 1] = entry
        end
    end
    self.decode_waiting = compact
    self.decode_waiting_head = 1
end

function RemoteMesh:_queue_variant(variant, source, force_new_generation)
    if self.stopped or not variant or not source or source.ready_revision <= 0 then
        return false
    end
    local target_changed = variant.target_source_revision ~= source.ready_revision
    if target_changed then
        variant.target_source_revision = source.ready_revision
        variant.decode_attempt = 0
        variant.generation = self:_next_generation()
        variant.decode_queued = false
        variant.decode_inflight = false
    elseif force_new_generation then
        variant.generation = self:_next_generation()
        variant.decode_queued = false
        variant.decode_inflight = false
    elseif variant.generation == 0 then
        variant.generation = self:_next_generation()
    elseif variant.decode_queued or variant.decode_inflight then
        return true
    end

    self:_compact_decode_queue(false)
    if self:_queue_depth() >= self.max_decode_queue then
        variant.status = variant.result and "refresh_backpressure" or "decode_backpressure"
        variant.state = variant.status
        variant.pending = true
        variant.ready = variant.result ~= nil
        variant.next_decode_at = self.now() + 0.05
        self.stats.decode_queue_backpressure = self.stats.decode_queue_backpressure + 1
        return false
    end
    variant.decode_queued = true
    variant.decode_inflight = false
    variant.pending = true
    variant.ready = variant.result ~= nil
    variant.status = variant.result and "refresh_queued" or "decode_queued"
    variant.state = variant.status
    variant.last_error = nil
    variant.last_used = self:_next_access()
    self.decode_waiting[#self.decode_waiting + 1] = {
        variant_key = variant.variant_key,
        generation = variant.generation,
    }
    self.stats.decode_queued = self.stats.decode_queued + 1
    return true
end

function RemoteMesh:_on_source_retry(source)
    source.status = "pending"
    source.last_error = nil
    for variant_key in pairs(source.variants) do
        local variant = self.variants[variant_key]
        if variant and not variant.ready and not variant.decode_queued
            and not variant.decode_inflight then
            variant.status = "waiting_source"
            variant.state = variant.status
            variant.pending = true
            self:_wave_add(variant)
        end
    end
end

function RemoteMesh:_mark_source_negative(source, reason)
    source.status = "negative"
    source.last_error = tostring(reason or "source_failed")
    for variant_key in pairs(source.variants) do
        local variant = self.variants[variant_key]
        if variant and not variant.ready then
            variant.generation = self:_next_generation()
            variant.decode_queued = false
            variant.decode_inflight = false
            variant.status = "negative"
            variant.state = "negative"
            variant.pending = false
            variant.ready = false
            variant.last_error = source.last_error
            variant.negative_until = self.now() + self.network_negative_ttl_seconds
            self:_wave_finish(variant, false)
        end
    end
end

function RemoteMesh:_accept_source_ready(source, revision, cache_path, data)
    local data_marker = ""
    if type(data) == "string" then
        -- use the acquisition revision to detect changes
        -- for sources without a revision, compare the size and edges without copying the whole payload
        data_marker = string.format("%d:%s:%s", #data,
            data:sub(1, math.min(16, #data)),
            data:sub(math.max(1, #data - 15)))
    elseif data ~= nil then
        data_marker = type(data)
    end
    local marker = table.concat({
        tostring(revision or ""), tostring(cache_path or ""), data_marker
    }, "|")
    if source.ready_marker == marker and source.ready_revision > 0 then return false end
    source.ready_marker = marker
    local numeric_revision = math.floor(tonumber(revision) or 0)
    if numeric_revision <= source.ready_revision then
        numeric_revision = source.ready_revision + 1
    end
    source.ready_revision = numeric_revision
    source.cache_path = cache_path
    source.data = data
    source.status = "ready"
    source.last_error = nil
    for variant_key in pairs(source.variants) do
        local variant = self.variants[variant_key]
        if variant and (variant.source_revision ~= numeric_revision
            or not variant.ready) then
            self:_wave_add(variant)
            self:_queue_variant(variant, source, false)
        end
    end
    return true
end

function RemoteMesh:_sync_source(source)
    if not source then return end
    local status, revision, cache_path, data, last_error = self:_source_status(source)
    local previous = source.last_observed_status
    source.last_observed_status = status
    source.status = status
    source.last_error = last_error
    if status == "ready" then
        self:_accept_source_ready(source, revision, cache_path, data)
    elseif status == "negative" or status == "stopped" then
        if previous ~= status then self:_mark_source_negative(source, last_error or status) end
    elseif previous == "negative" and status ~= "negative" then
        self:_on_source_retry(source)
    end
end

function RemoteMesh:_on_acquisition_ready(state)
    if self.stopped or type(state) ~= "table" then return end
    local asset_id = RemoteTexture.extract_asset_id(state.asset_id)
    local source = asset_id and self.sources[asset_id] or nil
    if not source then return end
    source.acquisition_state = state
    self:_sync_source(source)
end

function RemoteMesh:_ensure_variant_capacity(source)
    if source.variant_count >= self.max_variants_per_source
        and not self:_evict_variant(source) then
        self.stats.variant_limit_rejections = self.stats.variant_limit_rejections + 1
        return false
    end
    if self.variant_count >= self.max_variants and not self:_evict_variant(nil) then
        self.stats.variant_limit_rejections = self.stats.variant_limit_rejections + 1
        return false
    end
    self:_compact_variant_order()
    return true
end

function RemoteMesh:request(reference, asset_type, decode_policy, consumer, binding, asset_context)
    self.stats.requests = self.stats.requests + 1
    if self.stopped or not self.enabled then
        return nil, self.stopped and "stopped" or "disabled"
    end
    local descriptor = nil
    if type(asset_type) == "table" then
        descriptor = asset_type
        asset_type = descriptor.asset_type
        decode_policy = descriptor.decode_policy or descriptor.policy
        consumer = descriptor.consumer
        binding = descriptor.binding
        asset_context = descriptor.asset_context
    end
    local asset_id = RemoteTexture.extract_asset_id(reference)
    if not asset_id then
        self.stats.rejected_references = self.stats.rejected_references + 1
        return nil, "ineligible"
    end
    asset_type = normalized_variant_component(asset_type, "MeshPart")
    decode_policy = normalized_variant_component(decode_policy, "render")
    if not asset_type or not decode_policy then
        self.stats.rejected_variants = self.stats.rejected_variants + 1
        return nil, "invalid_variant"
    end
    local variant_key = RemoteMesh.variant_key(asset_id, asset_type, decode_policy, asset_context)
    local source = self.sources[asset_id]
    if not source then
        if self.source_count >= self.max_sources
            -- the idle TTL is a cache-retention preference, not permission to
            -- reject a replacement at the hard cap. Live/in-flight sources
            -- remain pinned by _source_is_terminal_evictable
            and not self:_evict_terminal_source(self.now(), true) then
            self.stats.source_limit_rejections = self.stats.source_limit_rejections + 1
            return nil, "source_limit"
        end
        source = self:_new_source(asset_id)
    end
    source.last_used = self:_next_access()
    source.last_used_at = self.now()

    local variant = self.variants[variant_key]
    local is_new = variant == nil
    if is_new then
        if not self:_ensure_variant_capacity(source) then
            if source.variant_count == 0 and source.status == "new" then
                self.sources[source.asset_id] = nil
                self.source_count = math.max(0, self.source_count - 1)
                source.status = "discarded"
            end
            return nil, "variant_limit"
        end
        variant = self:_new_variant(source, variant_key, asset_type, decode_policy)
        if type(asset_context) == "table" then
            variant.map_path = asset_context.map_path
            variant.asset_root = asset_context.asset_root
        end
        self:_wave_add(variant)
    else
        self.stats.deduplicated = self.stats.deduplicated + 1
        variant.last_used = self:_next_access()
    end
    if consumer ~= nil then self:bind(variant, consumer, binding) end

    self:_request_acquisition(source)
    self:_sync_source(source)
    if source.status == "ready" and not variant.decode_queued and not variant.decode_inflight
        and (not variant.ready or variant.source_revision ~= source.ready_revision) then
        self:_wave_add(variant)
        self:_queue_variant(variant, source, false)
    end
    return variant, variant.status
end

function RemoteMesh:_decode_pool_config()
    return {
        worker_count = self.decode_worker_count,
        decoder_module = self.decoder_module,
        decoder_method = self.decoder_method,
        decoder = self.decoder,
        filesystem = self.filesystem,
        max_encoded_bytes = self.max_encoded_bytes,
    }
end

function RemoteMesh:_ensure_decode_pool()
    if self.decode_pool then return self.decode_pool end
    if not self.decode_pool_factory then return nil, "decoder_unavailable" end
    local ok, pool, reason = pcall(self.decode_pool_factory, self:_decode_pool_config())
    if not ok then reason, pool = tostring(pool), nil end
    if not pool then
        self.stats.decode_pool_start_failures = self.stats.decode_pool_start_failures + 1
        self:_log_once("decode_pool_unavailable",
            "[rbx] remote mesh decode workers unavailable: " .. tostring(reason or "unknown"))
        return nil, reason or "decode_pool_unavailable"
    end
    self.decode_pool = pool
    return pool
end

function RemoteMesh:_terminal_decode_failure(variant, reason)
    self.stats.decode_failures = self.stats.decode_failures + 1
    self.stats.decode_negative_transitions = self.stats.decode_negative_transitions + 1
    variant.pending = false
    variant.decode_queued = false
    variant.decode_inflight = false
    variant.last_error = tostring(reason or "decode_failed")
    variant.negative_until = self.now() + self.decode_negative_ttl_seconds
    if variant.result then
        variant.status = "ready"
        variant.state = "ready"
        variant.ready = true
    else
        variant.status = "negative"
        variant.state = "negative"
        variant.ready = false
    end
    self:_wave_finish(variant, false)
end

function RemoteMesh:_retry_decode(variant, reason)
    variant.pending = true
    variant.ready = variant.result ~= nil
    variant.decode_queued = false
    variant.decode_inflight = false
    variant.last_error = tostring(reason or "decode_failed")
    local exponent = math.max(0, variant.decode_attempt - 1)
    variant.next_decode_at = self.now()
        + self.decode_retry_backoff_seconds * (2 ^ exponent)
    variant.status = variant.result and "refresh_retry_wait" or "decode_retry_wait"
    variant.state = variant.status
    self.stats.decode_retries = self.stats.decode_retries + 1
end

function RemoteMesh:_dispatch_decodes()
    local pool, pool_error = self:_ensure_decode_pool()
    local dispatched = 0
    while dispatched < self.max_decode_dispatch_per_pump
        and self.decode_outstanding < self.max_decode_outstanding
        and self.decode_waiting_head <= #self.decode_waiting do
        local entry = self.decode_waiting[self.decode_waiting_head]
        self.decode_waiting[self.decode_waiting_head] = false
        self.decode_waiting_head = self.decode_waiting_head + 1
        local variant = entry and self.variants[entry.variant_key]
        if variant and variant.generation == entry.generation and variant.decode_queued then
            variant.decode_queued = false
            local source = variant.source
            if not pool then
                self:_terminal_decode_failure(variant, pool_error)
            elseif not source or source.ready_revision ~= variant.target_source_revision then
                variant.status = "waiting_source"
                variant.state = variant.status
                variant.pending = true
            elseif type(source.cache_path) ~= "string" and type(source.data) ~= "string" then
                self:_terminal_decode_failure(variant, "source_payload_missing")
            else
                variant.decode_attempt = variant.decode_attempt + 1
                local job = {
                    variant_key = variant.variant_key,
                    asset_id = variant.asset_id,
                    asset_type = variant.asset_type,
                    decode_policy = variant.decode_policy,
                    map_path = variant.map_path,
                    asset_root = variant.asset_root,
                    generation = variant.generation,
                    source_revision = variant.target_source_revision,
                    manager_epoch = self.epoch,
                    attempt = variant.decode_attempt,
                    cache_path = source.cache_path,
                    data = source.data,
                    -- worker-side parsers must enforce the same configured
                    -- ceiling as main-thread validation. without propagation,
                    -- every worker silently used its unrelated 1M default
                    max_output_vertices = self.max_decoded_vertices,
                    max_decoded_vertices = self.max_decoded_vertices,
                    max_output_triangles = self.max_decoded_triangles,
                    max_decoded_triangles = self.max_decoded_triangles,
                }
                local accepted, enqueue_error = call_method(pool, "enqueue", job)
                if accepted == true then
                    variant.decode_inflight = true
                    variant.status = variant.result and "refreshing" or "decoding"
                    variant.state = variant.status
                    self.decode_outstanding = self.decode_outstanding + 1
                    self.stats.decode_scheduled = self.stats.decode_scheduled + 1
                    dispatched = dispatched + 1
                else
                    variant.decode_attempt = math.max(0, variant.decode_attempt - 1)
                    self:_retry_decode(variant,
                        "decode_enqueue_failed:" .. tostring(enqueue_error))
                end
            end
        end
    end
    self:_compact_decode_queue(false)
    return dispatched
end

function RemoteMesh:_validate_decode_result(decoded)
    local ok, valid, reason = pcall(self.validate_decoded, decoded)
    if not ok then return false, "decoded_validator_error" end
    if valid ~= true then
        reason = tostring(reason or "decoded_invalid")
        if reason == "decoded_vertex_limit" or reason == "decoded_triangle_limit" then
            self.stats.decoded_limit_rejections = self.stats.decoded_limit_rejections + 1
        end
        return false, reason
    end
    return true
end

function RemoteMesh:_reserve_decoded_result(variant, decoded)
    local decoded_bytes, estimate_reason =
        estimate_decoded_resident_bytes(decoded)
    if decoded_bytes == nil then
        return nil, estimate_reason or "decoded_resident_estimate_failed"
    end
    if decoded_bytes > self.max_decoded_resident_bytes then
        return nil, "decoded_resident_limit", decoded_bytes
    end

    local previous_bytes = math.max(0,
        math.floor(tonumber(variant.decoded_resident_bytes) or 0))
    local projected = math.max(0,
        self.decoded_resident_bytes - previous_bytes) + decoded_bytes
    if projected <= self.max_decoded_resident_bytes then
        return decoded_bytes
    end

    local required = projected - self.max_decoded_resident_bytes
    local reclaimable = 0
    local candidates = {}
    for _, candidate in pairs(self.variants) do
        local bytes = math.max(0,
            math.floor(tonumber(candidate.decoded_resident_bytes) or 0))
        -- removing the whole idle handle preserves the existing safe recovery
        -- contract: a later request recreates the variant and decodes again from
        -- its still-ready source.  Bound renderer consumers are never candidates
        if candidate ~= variant and candidate.ready == true
            and candidate.result ~= nil and bytes > 0
            and not candidate.pending and not candidate.decode_queued
            and not candidate.decode_inflight and candidate.wave_token == nil
            and not self:_variant_has_consumers(candidate) then
            reclaimable = reclaimable + bytes
            candidates[#candidates + 1] = candidate
        end
    end
    if reclaimable < required then
        return nil, "decoded_resident_limit", decoded_bytes
    end

    table.sort(candidates, function(a, b)
        local a_used = tonumber(a.last_used) or 0
        local b_used = tonumber(b.last_used) or 0
        if a_used ~= b_used then return a_used < b_used end
        return tostring(a.variant_key) < tostring(b.variant_key)
    end)
    local reclaimed = 0
    for index = 1, #candidates do
        local candidate = candidates[index]
        local bytes = math.max(0,
            math.floor(tonumber(candidate.decoded_resident_bytes) or 0))
        if self:_remove_variant(candidate) then
            reclaimed = reclaimed + bytes
            self.stats.decoded_resident_evictions =
                self.stats.decoded_resident_evictions + 1
            self.stats.decoded_resident_evicted_bytes =
                self.stats.decoded_resident_evicted_bytes + bytes
        end
        if reclaimed >= required then break end
    end
    projected = math.max(0,
        self.decoded_resident_bytes - previous_bytes) + decoded_bytes
    if projected > self.max_decoded_resident_bytes then
        return nil, "decoded_resident_limit", decoded_bytes
    end
    return decoded_bytes
end

function RemoteMesh:_publish_ready(variant, decoded, source_revision, decoded_bytes)
    local previous = variant.result
    local previous_bytes = math.max(0,
        math.floor(tonumber(variant.decoded_resident_bytes) or 0))
    local next_resident_bytes = math.max(0,
        self.decoded_resident_bytes - previous_bytes)
        + math.max(0, math.floor(tonumber(decoded_bytes) or 0))
    if next_resident_bytes > self.max_decoded_resident_bytes then
        return false, "decoded_resident_limit"
    end
    variant.result = decoded
    variant.mesh = decoded
    variant.decoded_resident_bytes = decoded_bytes
    self:_set_decoded_resident_bytes(next_resident_bytes)
    variant.source_revision = source_revision
    variant.revision = variant.revision + 1
    variant.pending = false
    variant.ready = true
    variant.status = "ready"
    variant.state = "ready"
    variant.last_error = nil
    variant.negative_until = 0
    variant.decode_attempt = 0
    variant.last_used = self:_next_access()
    if previous ~= nil and previous ~= decoded then self:_release_result(previous) end
    self.stats.decode_ready = self.stats.decode_ready + 1
    self:_wave_finish(variant, true)
    local owner = self.owner
    if self.notify_variant_ready and owner
        and type(owner._on_remote_mesh_variant_ready) == "function" then
        self.stats.variant_ready_notifications =
            self.stats.variant_ready_notifications + 1
        pcall(owner._on_remote_mesh_variant_ready, owner, variant)
    end
    return true
end

function RemoteMesh:_process_decode_result(result)
    if type(result) ~= "table" then return false end
    self.stats.decode_completions = self.stats.decode_completions + 1
    self.decode_outstanding = math.max(0, self.decode_outstanding - 1)
    local variant = self.variants[result.variant_key]
    local decoded = result.decoded or result.mesh or result.result
    if not variant or tonumber(result.manager_epoch) ~= self.epoch
        or tonumber(result.generation) ~= variant.generation
        or tonumber(result.source_revision) ~= variant.target_source_revision then
        self.stats.stale_decode_completions =
            self.stats.stale_decode_completions + 1
        self:_release_result(decoded)
        return false
    end
    variant.decode_inflight = false
    if result.ok ~= true then
        if result.retryable ~= false and variant.decode_attempt < self.max_decode_attempts then
            self:_retry_decode(variant, result.error)
        else
            self:_terminal_decode_failure(variant, result.error)
        end
        return false
    end
    local valid, reason = self:_validate_decode_result(decoded)
    if not valid then
        self:_release_result(decoded)
        self:_terminal_decode_failure(variant, reason)
        return false
    end
    local decoded_bytes, resident_reason, rejected_bytes =
        self:_reserve_decoded_result(variant, decoded)
    if decoded_bytes == nil then
        self.stats.decoded_resident_rejections =
            self.stats.decoded_resident_rejections + 1
        self.stats.decoded_resident_rejected_bytes =
            self.stats.decoded_resident_rejected_bytes
                + math.max(0, tonumber(rejected_bytes) or 0)
        if resident_reason ~= "decoded_resident_limit" then
            self.stats.decoded_resident_estimate_failures =
                self.stats.decoded_resident_estimate_failures + 1
        end
        self:_release_result(decoded)
        self:_terminal_decode_failure(variant, resident_reason)
        return false
    end
    local published, publish_reason = self:_publish_ready(
        variant, decoded, tonumber(result.source_revision), decoded_bytes)
    if not published then
        self.stats.decoded_resident_rejections =
            self.stats.decoded_resident_rejections + 1
        self.stats.decoded_resident_rejected_bytes =
            self.stats.decoded_resident_rejected_bytes + decoded_bytes
        self:_release_result(decoded)
        self:_terminal_decode_failure(variant, publish_reason)
        return false
    end
    return true
end

function RemoteMesh:_recover_decode_pool(reason)
    self.stats.decode_pool_runtime_failures = self.stats.decode_pool_runtime_failures + 1
    local failed_pool = self.decode_pool
    self.decode_pool = nil
    if failed_pool then call_method(failed_pool, "stop") end
    self.decode_outstanding = 0
    for _, variant in pairs(self.variants) do
        if variant.decode_inflight then
            variant.decode_inflight = false
            if variant.decode_attempt < self.max_decode_attempts then
                self:_retry_decode(variant, reason or "decode_worker_failed")
            else
                self:_terminal_decode_failure(variant, reason or "decode_worker_failed")
            end
        end
    end
    if self.decode_pool_is_injected then self.decode_pool_factory = nil end
end

function RemoteMesh:_check_decode_pool_health()
    if not self.decode_pool or type(self.decode_pool.health) ~= "function" then return true end
    local healthy, reason = call_method(self.decode_pool, "health")
    if healthy == true then return true end
    self:_recover_decode_pool(reason)
    return false
end

function RemoteMesh:_scan_sources()
    if #self.source_order == 0 then return end
    local scanned = 0
    while scanned < self.max_state_scans_per_pump and #self.source_order > 0 do
        if self.source_scan_cursor > #self.source_order then self.source_scan_cursor = 1 end
        local asset_id = self.source_order[self.source_scan_cursor]
        self.source_scan_cursor = self.source_scan_cursor + 1
        scanned = scanned + 1
        self:_sync_source(self.sources[asset_id])
        if scanned >= #self.source_order then break end
    end
end

function RemoteMesh:_scan_variants(now)
    if #self.variant_order == 0 then return end
    local scanned = 0
    while scanned < self.max_state_scans_per_pump and #self.variant_order > 0 do
        if self.variant_scan_cursor > #self.variant_order then self.variant_scan_cursor = 1 end
        local key = self.variant_order[self.variant_scan_cursor]
        self.variant_scan_cursor = self.variant_scan_cursor + 1
        scanned = scanned + 1
        local variant = self.variants[key]
        if variant and not variant.decode_queued and not variant.decode_inflight then
            local source = variant.source
            if (variant.status == "decode_retry_wait"
                or variant.status == "refresh_retry_wait")
                and now >= variant.next_decode_at and source and source.ready_revision > 0 then
                self:_queue_variant(variant, source, true)
            elseif (variant.status == "decode_backpressure"
                or variant.status == "refresh_backpressure")
                and now >= variant.next_decode_at and source and source.ready_revision > 0 then
                self:_queue_variant(variant, source, false)
            elseif variant.status == "negative" and now >= variant.negative_until
                and source and source.ready_revision > 0 then
                variant.decode_attempt = 0
                self:_wave_add(variant)
                self:_queue_variant(variant, source, true)
            elseif variant.ready and variant.last_error
                and now >= variant.negative_until and source
                and source.ready_revision > variant.source_revision then
                variant.decode_attempt = 0
                self:_wave_add(variant)
                self:_queue_variant(variant, source, true)
            end
        end
        if scanned >= #self.variant_order then break end
    end
end

function RemoteMesh:pump()
    if self.stopped or not self.enabled then return 0, 0, false end
    local started = self.now()
    if self.acquisition then call_method(self.acquisition, "pump") end
    self:_scan_sources()
    self:_scan_variants(started)
    self:_check_decode_pool_health()
    self:_dispatch_decodes()
    local processed, ready = 0, 0
    while processed < self.max_decode_completions_per_pump
        and (self.now() - started) <= self.pump_budget_seconds do
        if not self.decode_pool then break end
        local result = call_method(self.decode_pool, "pop")
        if result == nil then break end
        processed = processed + 1
        if self:_process_decode_result(result) then ready = ready + 1 end
    end
    self:_scan_variants(self.now())
    self:_dispatch_decodes()
    local settled = self:_maybe_settle_wave(self.now())
    local elapsed_ms = math.max(0, (self.now() - started) * 1000)
    self.stats.pump_ms_last = elapsed_ms
    self.stats.pump_ms_max = math.max(self.stats.pump_ms_max, elapsed_ms)
    return processed, ready, settled
end

function RemoteMesh:get_stats()
    local out = {}
    for key, value in pairs(self.stats) do out[key] = value end
    local pending, ready, negative = 0, 0, 0
    local consumers = 0
    for _, variant in pairs(self.variants) do
        if variant.ready then ready = ready + 1
        elseif variant.status == "negative" then negative = negative + 1
        else pending = pending + 1 end
        consumers = consumers + count_keys(variant.consumers)
    end
    out.enabled = self.enabled
    out.stopped = self.stopped
    out.source_count = self.source_count
    out.variant_count = self.variant_count
    out.pending_variants = pending
    out.ready_variants = ready
    out.negative_variants = negative
    out.live_consumers = consumers
    out.decode_queue_depth = self:_queue_depth()
    out.decode_outstanding = self.decode_outstanding
    out.max_sources = self.max_sources
    out.source_idle_ttl_seconds = self.source_idle_ttl_seconds
    out.max_variants = self.max_variants
    out.max_variants_per_source = self.max_variants_per_source
    out.max_decode_queue = self.max_decode_queue
    out.max_encoded_bytes = self.max_encoded_bytes
    out.max_decoded_resident_bytes = self.max_decoded_resident_bytes
    out.wave = self:_wave_snapshot(not self.wave.active)
    if self.acquisition and type(self.acquisition.get_stats) == "function" then
        local acquisition_stats = call_method(self.acquisition, "get_stats")
        if type(acquisition_stats) == "table" then out.acquisition = acquisition_stats end
    end
    return out
end

function RemoteMesh:stop()
    if self.stopped then return false end
    self.stopped = true
    self.enabled = false
    self.epoch = self.epoch + 1
    self.stats.stopped = true
    if self.decode_pool then call_method(self.decode_pool, "stop") end
    self.decode_pool = nil
    self.decode_outstanding = 0
    self.decode_waiting = {}
    self.decode_waiting_head = 1
    if self.acquisition and (self.owns_acquisition or self.stop_injected_acquisition) then
        call_method(self.acquisition, "stop")
    end
    self.acquisition = nil
    for _, variant in pairs(self.variants) do
        self:_release_variant_result(variant)
        variant.ready = false
        variant.pending = false
        variant.decode_queued = false
        variant.decode_inflight = false
        variant.status = "stopped"
        variant.state = "stopped"
        clear_variant_consumers(variant)
    end
    self.variants = {}
    self.variant_order = {}
    self.variant_count = 0
    self.sources = {}
    self.source_order = {}
    self.source_count = 0
    self:_set_decoded_resident_bytes(0)
    self.wave.active = false
    self.wave.pending = 0
    self.wave.tokens = {}
    self.owner = nil
    if self._acquisition_bridge then self._acquisition_bridge.manager = nil end
    return true
end

RemoteMesh.extract_asset_id = RemoteTexture.extract_asset_id
RemoteMesh.endpoint_for_id = RemoteTexture.endpoint_for_id
RemoteMesh.DEFAULT_CACHE_DIR = DEFAULT_CACHE_DIR
RemoteMesh.DEFAULT_DECODER_METHOD = DEFAULT_DECODER_METHOD
RemoteMesh.DEFAULT_MAX_DECODED_RESIDENT_BYTES =
    DEFAULT_MAX_DECODED_RESIDENT_BYTES
RemoteMesh.STOP_TOKEN = STOP_TOKEN
RemoteMesh.ThreadDecodePool = ThreadDecodePool
RemoteMesh.DeferredDecodePool = DeferredDecodePool

return RemoteMesh
