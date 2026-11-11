-- Asynchronous, renderer-lifetime acquisition state for remote Roblox textures
--
-- this module deliberately has no renderer or graphics dependency.  the assets
-- runtime owns GPU upload, this layer only validates references, de-duplicates
-- requests, runs a bounded worker pool, validates encoded image bytes, and
-- publishes revisioned source state backed by LOVE's save-directory cache

local RemoteTexture = {}
RemoteTexture.__index = RemoteTexture

local ThreadPool = {}
ThreadPool.__index = ThreadPool

local ENDPOINT_PREFIX = "https://assetdelivery.roblox.com/v1/asset/?id="
local STOP_TOKEN = "__RBX_REMOTE_TEXTURE_STOP__"
local DEFAULT_CACHE_DIR = "rbx_remote_texture_cache"
local MAX_UINT64_DECIMAL = "18446744073709551615"
local MAX_SAFE_INTEGER = 9007199254740991
local pool_sequence = 0

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

local function normalized_decimal(value)
    if type(value) ~= "string" or not value:match("^%d+$") then
        return nil
    end
    value = value:gsub("^0+", "")
    if value == "" then
        return nil
    end
    if #value > #MAX_UINT64_DECIMAL
        or (#value == #MAX_UINT64_DECIMAL and value > MAX_UINT64_DECIMAL) then
        return nil
    end
    return value
end

local function query_asset_id(query)
    if query == nil or query == "" then return nil end
    local found = nil
    for item in query:gmatch("[^&]+") do
        local key, value = item:match("^([^=]+)=([^=]*)$")
        if not key then return nil end
        key = key:lower()
        if key == "id" or key == "assetid" then
            local candidate = normalized_decimal(value)
            if not candidate or (found and found ~= candidate) then
                return nil
            end
            found = candidate
        end
    end
    return found
end

local function prefixed_path_asset_id(path, prefix)
    if path:sub(1, #prefix) ~= prefix then return nil end
    local id, suffix = path:sub(#prefix + 1):match("^(%d+)(.*)$")
    if not id or (suffix ~= "" and suffix:sub(1, 1) ~= "/") then return nil end
    return normalized_decimal(id)
end

-- Remote eligibility is intentionally stricter than common.lua's local asset-ID
-- extraction.  never turn an arbitrary URL containing digits into a network
-- request.  these are the historical and current Roblox-owned reference forms
-- encountered in place files, every request is still sent to ENDPOINT_PREFIX
function RemoteTexture.extract_asset_id(reference)
    if type(reference) == "number" then
        if reference ~= reference or reference == math.huge or reference == -math.huge
            or reference <= 0 or reference > MAX_SAFE_INTEGER
            or reference ~= math.floor(reference) then
            return nil
        end
        return normalized_decimal(string.format("%.0f", reference))
    end
    if type(reference) ~= "string" then return nil end

    local value = reference:match("^%s*(.-)%s*$")
    local direct = normalized_decimal(value)
    if direct then return direct end

    local scheme_id = value:match("^[Rr][Bb][Xx][Aa][Ss][Ss][Ee][Tt][Ii][Dd]://(%d+)$")
    if scheme_id then return normalized_decimal(scheme_id) end

    local scheme, authority, rest = value:match("^([Hh][Tt][Tt][Pp][Ss]?)://([^/%?#]+)([^#]*)$")
    if not scheme then return nil end
    local host = authority:lower()
    local path, query = rest:match("^([^?]*)%??(.*)$")
    path = (path or ""):lower()
    query = query ~= "" and query or nil

    local query_id = nil
    if (host == "roblox.com" or host == "www.roblox.com")
        and (path == "/asset" or path == "/asset/") then
        query_id = query_asset_id(query)
    elseif host == "assetgame.roblox.com"
        and (path == "/asset" or path == "/asset/") then
        query_id = query_asset_id(query)
    elseif host == "assetdelivery.roblox.com"
        and (path == "/v1/asset" or path == "/v1/asset/") then
        query_id = query_asset_id(query)
    end
    if query_id then return query_id end

    if host == "assetdelivery.roblox.com" then
        local id = path:match("^/v2/assetid/(%d+)/?$")
        if id and query == nil then return normalized_decimal(id) end
    end

    if host == "roblox.com" or host == "www.roblox.com" then
        local id = prefixed_path_asset_id(path, "/library/")
            or prefixed_path_asset_id(path, "/catalog/")
        if id then return id end
    elseif host == "create.roblox.com" then
        local id = prefixed_path_asset_id(path, "/store/asset/")
        if id then return id end
    end

    return nil
end

function RemoteTexture.endpoint_for_id(asset_id)
    asset_id = normalized_decimal(tostring(asset_id or ""))
    if not asset_id then return nil end
    return ENDPOINT_PREFIX .. asset_id
end

local function sanitized_cache_dir(cache_dir)
    cache_dir = tostring(cache_dir or DEFAULT_CACHE_DIR)
    if not cache_dir:match("^[%w_%-/]+$")
        or cache_dir:find("..", 1, true)
        or cache_dir:sub(1, 1) == "/"
        or cache_dir:find("//", 1, true) then
        cache_dir = DEFAULT_CACHE_DIR
    end
    cache_dir = cache_dir:gsub("/+$", "")
    if cache_dir == "" then cache_dir = DEFAULT_CACHE_DIR end
    return cache_dir
end

local function sanitized_pool_token(value)
    value = tostring(value or ""):gsub("[^%w_%-]", "_"):sub(1, 80)
    if value == "" then value = "pool" end
    return value
end

function RemoteTexture.worker_temp_filename(asset_id, pool_token, worker_index, attempt)
    asset_id = normalized_decimal(tostring(asset_id or ""))
    if not asset_id then return nil end
    return string.format("rbx_remote_texture_tmp/%s.%s.%d.%d.part",
        asset_id,
        sanitized_pool_token(pool_token),
        clamp_integer(worker_index, 1, 1, 4),
        clamp_integer(attempt, 1, 1, 1024))
end

function RemoteTexture.classify_download_failure(http_status, curl_code)
    http_status = math.floor(tonumber(http_status) or 0)
    curl_code = math.floor(tonumber(curl_code) or -1)
    -- Lua 5.1/POSIX may expose waitpid's shifted status rather than the direct
    -- process exit code returned by LuaJIT on Windows
    if curl_code > 255 and curl_code % 256 == 0 then
        curl_code = math.floor(curl_code / 256)
    end
    if curl_code == 63 then return "encoded_too_large", false end
    if http_status == 429 or http_status >= 500 or http_status == 0 then
        return http_status > 0 and ("http_" .. http_status)
            or ("curl_" .. curl_code), true
    end
    if http_status >= 400 and http_status < 500 then
        return "http_" .. http_status, false
    end
    return "curl_" .. curl_code, curl_code ~= 0
end

function RemoteTexture.cache_path_for_id(asset_id, cache_dir)
    asset_id = normalized_decimal(tostring(asset_id or ""))
    if not asset_id then return nil end
    cache_dir = sanitized_cache_dir(cache_dir)
    return cache_dir .. "/" .. asset_id .. ".asset"
end

local function default_validate_encoded(data, asset_id, max_dimension, max_pixels)
    if type(data) ~= "string" or data == "" then
        return false, "empty"
    end
    if not (love and love.image and love.image.newImageData) then
        return false, "image_decoder_unavailable"
    end
    local source = data
    local file_data = nil
    if love.filesystem and love.filesystem.newFileData then
        local file_ok, created = pcall(
            love.filesystem.newFileData, data, tostring(asset_id or "texture") .. ".asset")
        if file_ok and created then
            source = created
            file_data = created
        end
    end
    local ok, image_data = pcall(love.image.newImageData, source)
    local width, height = nil, nil
    if ok and image_data and image_data.getDimensions then
        local dimensions_ok
        dimensions_ok, width, height = pcall(image_data.getDimensions, image_data)
        if not dimensions_ok then width, height = nil, nil end
    end
    if image_data and image_data.release then
        pcall(image_data.release, image_data)
    end
    if file_data and file_data.release then
        pcall(file_data.release, file_data)
    end
    if not ok or not image_data then
        return false, "decode_failed"
    end
    if not width or not height or width <= 0 or height <= 0 then
        return false, "decoded_dimensions_invalid"
    end
    if width > max_dimension or height > max_dimension
        or width * height > max_pixels then
        return false, "decoded_dimensions_too_large"
    end
    return true
end

local function call_pool(pool, method, ...)
    local fn = pool and pool[method]
    if type(fn) ~= "function" then return nil, "missing_" .. method end
    local ok, a, b = pcall(fn, pool, ...)
    if not ok then return nil, tostring(a) end
    return a, b
end

local function release_object(object)
    if object and type(object.release) == "function" then
        pcall(object.release, object)
    end
end

function ThreadPool.new(config)
    if not (love and love.thread and love.thread.getChannel and love.thread.newThread) then
        return nil, "love_thread_unavailable"
    end
    pool_sequence = pool_sequence + 1
    local tag = tostring({}):gsub("[^%w]", "")
    local req_name = string.format("rbx_remote_texture_req_%d_%s", pool_sequence, tag)
    local res_name = string.format("rbx_remote_texture_res_%d_%s", pool_sequence, tag)
    local self = setmetatable({
        request = love.thread.getChannel(req_name),
        response = love.thread.getChannel(res_name),
        threads = {},
        stopped = false,
    }, ThreadPool)
    local worker_count = clamp_integer(config.worker_count, 2, 1, 4)
    for index = 1, worker_count do
        local ok_thread, thread = pcall(
            love.thread.newThread, require("engine/root") .. "/graphics/rbx/remote_texture_thread.lua")
        if ok_thread and thread then
            local ok_start = pcall(thread.start, thread,
                req_name, res_name, index,
                config.connect_timeout_seconds,
                config.total_timeout_seconds,
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

function ThreadPool:enqueue(job)
    if self.stopped then return false, "stopped" end
    local ok, pushed = pcall(self.request.push, self.request, job)
    if not ok or pushed == false then return false, tostring(pushed) end
    return true
end

function ThreadPool:pop()
    if self.stopped then return nil end
    local ok, result = pcall(self.response.pop, self.response)
    if not ok then return nil end
    return result
end

function ThreadPool:health()
    if self.stopped then return false, "stopped" end
    for index = 1, #self.threads do
        local thread = self.threads[index]
        if thread then
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
    end
    return true
end

function ThreadPool:stop()
    if self.stopped then return false end
    self.stopped = true
    if self.request and self.request.clear then
        pcall(self.request.clear, self.request)
    end
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

local function production_pool_factory(config)
    return ThreadPool.new(config)
end

function RemoteTexture.new(owner, options)
    options = options or {}
    local self = setmetatable({}, RemoteTexture)
    self.owner = owner
    self.enabled = options.enabled == true
    self.now = type(options.now) == "function" and options.now or default_now
    self.filesystem = options.filesystem or (love and love.filesystem)
    self._uses_default_validator = type(options.validator) ~= "function"
    self.pool_factory = type(options.pool_factory) == "function"
        and options.pool_factory or production_pool_factory
    self.logger = type(options.logger) == "function" and options.logger or print
    self.worker_count = clamp_integer(options.worker_count, 2, 1, 4)
    self.max_queue = clamp_integer(options.max_queue, 256, 1, 4096)
    self.max_sources = clamp_integer(options.max_sources, 2048, 1, 65536)
    self.max_sampler_handles = clamp_integer(
        options.max_sampler_handles, 4096, 1, 131072)
    self.terminal_idle_seconds = math.max(0,
        math.min(3600, tonumber(options.terminal_idle_seconds) or 30))
    self.max_prune_scans_per_pump = clamp_integer(
        options.max_prune_scans_per_pump, 64, 1, 1024)
    self.max_evictions_per_pump = clamp_integer(
        options.max_evictions_per_pump, 16, 1, 256)
    self.max_encoded_bytes = clamp_integer(
        options.max_encoded_bytes, 16 * 1024 * 1024, 1024, 64 * 1024 * 1024)
    self.max_texture_dimension = clamp_integer(
        options.max_texture_dimension, 8192, 1, 32768)
    self.max_decoded_pixels = clamp_integer(
        options.max_decoded_pixels, 8192 * 8192, 1, 32768 * 32768)
    self.validator = type(options.validator) == "function"
        and options.validator or function(data, asset_id)
            return default_validate_encoded(data, asset_id,
                self.max_texture_dimension, self.max_decoded_pixels)
        end
    self.connect_timeout_seconds = math.max(1,
        math.min(15, tonumber(options.connect_timeout_seconds) or 4))
    self.total_timeout_seconds = math.max(self.connect_timeout_seconds,
        math.min(60, tonumber(options.total_timeout_seconds) or 20))
    self.max_attempts = clamp_integer(options.max_attempts, 3, 1, 8)
    self.retry_backoff_seconds = math.max(0.05,
        math.min(30, tonumber(options.retry_backoff_seconds) or 0.5))
    self.negative_ttl_seconds = math.max(1,
        math.min(3600, tonumber(options.negative_ttl_seconds) or 60))
    self.max_completions_per_pump = clamp_integer(
        options.max_completions_per_pump, 4, 1, 64)
    self.max_dispatch_per_pump = clamp_integer(
        options.max_dispatch_per_pump, 8, 1, 128)
    self.pump_budget_seconds = math.max(0.0001,
        math.min(0.02, (tonumber(options.pump_budget_ms) or 2) / 1000))
    -- GPU work remains renderer-owned, but keeping the normalized publication
    -- limits beside the acquisition limits gives injected/test managers one
    -- deterministic configuration surface
    self.max_promotions_per_pump = clamp_integer(
        options.max_promotions_per_pump or options.max_gpu_promotions_per_pump,
        2, 1, 32)
    self.max_ready_handles_per_pump = clamp_integer(
        options.max_ready_handles_per_pump,
        32, 1, 256)
    self.promotion_budget_seconds = math.max(0.0001,
        math.min(0.02, (tonumber(options.promotion_budget_ms) or 2) / 1000))
    self.gpu_retry_backoff_seconds = math.max(0.01,
        math.min(5, tonumber(options.gpu_retry_backoff_seconds) or 0.05))
    self.gpu_retry_max_backoff_seconds = math.max(
        self.gpu_retry_backoff_seconds,
        math.min(30, tonumber(options.gpu_retry_max_backoff_seconds) or 2))
    self.gpu_negative_ttl_seconds = math.max(0.1,
        math.min(300, tonumber(options.gpu_negative_ttl_seconds) or 5))
    self.gpu_attempts_before_negative = clamp_integer(
        options.gpu_attempts_before_negative,
        4, 1, 16)
    -- store only the sanitized value.  both createDirectory and final filename
    -- derive from this same value, so a custom cache path cannot escape LOVE's
    -- save directory or create a different directory from cache_path_for_id
    self.cache_dir = sanitized_cache_dir(options.cache_dir)
    self.sources = {}
    self.sampler_handles = {}
    self.source_count = 0
    self.sampler_handle_count = 0
    self._terminal_lru_head = nil
    self._terminal_lru_tail = nil
    self.pool = nil
    self.outstanding = 0
    self.stopped = false
    self.warned = {}
    self.stats = {
        scheduled = 0,
        deduplicated = 0,
        rejected_references = 0,
        cache_hits = 0,
        cache_misses = 0,
        cache_invalid = 0,
        cache_writes = 0,
        cache_write_failures = 0,
        downloaded_bytes = 0,
        completions = 0,
        ready_completions = 0,
        failed_completions = 0,
        retries = 0,
        negative_transitions = 0,
        queue_backpressure = 0,
        worker_start_failures = 0,
        stale_completions = 0,
        worker_runtime_failures = 0,
        validation_rejections = 0,
        decoded_limit_rejections = 0,
        validation_ms_total = 0,
        validation_ms_max = 0,
        completion_ms_max = 0,
        pump_ms_last = 0,
        pump_ms_max = 0,
        source_ready_notifications = 0,
        ready_handles_queued = 0,
        gpu_promotions = 0,
        gpu_promotion_failures = 0,
        gpu_promotion_retries = 0,
        gpu_negative_transitions = 0,
        gpu_cache_resets = 0,
        ready_handle_fanout = 0,
        terminal_prune_scans = 0,
        terminal_prune_blocked = 0,
        evicted_sources = 0,
        evicted_sampler_handles = 0,
        bound_targets_updated = 0,
        stale_bindings = 0,
        failed_bindings = 0,
        fallback_consumer_count = 0,
        fallback_rebuilds = 0,
        promotion_queue_depth = 0,
        promotion_ms_last = 0,
        promotion_ms_total = 0,
        promotion_ms_max = 0,
        promotion_upload_ms_last = 0,
        promotion_upload_ms_total = 0,
        promotion_upload_ms_max = 0,
        stopped = false,
    }
    return self
end

function RemoteTexture:_terminal_lru_remove(state)
    if not state or state._terminal_lru_linked ~= true then return end
    local previous = state._terminal_lru_previous
    local following = state._terminal_lru_next
    if previous then
        previous._terminal_lru_next = following
    else
        self._terminal_lru_head = following
    end
    if following then
        following._terminal_lru_previous = previous
    else
        self._terminal_lru_tail = previous
    end
    state._terminal_lru_previous = nil
    state._terminal_lru_next = nil
    state._terminal_lru_linked = false
end

function RemoteTexture:_terminal_lru_append(state)
    if not state then return end
    self:_terminal_lru_remove(state)
    local tail = self._terminal_lru_tail
    state._terminal_lru_previous = tail
    state._terminal_lru_next = nil
    state._terminal_lru_linked = true
    if tail then
        tail._terminal_lru_next = state
    else
        self._terminal_lru_head = state
    end
    self._terminal_lru_tail = state
end

function RemoteTexture:_touch_source(state)
    if not state then return end
    state.last_used_at = self.now()
    if state.status == "ready" or state.status == "negative" then
        self:_terminal_lru_append(state)
    end
end

function RemoteTexture:_source_can_retire(state, now)
    if type(state) ~= "table"
        or (state.status ~= "ready" and state.status ~= "negative") then
        return false
    end
    if now - (tonumber(state.last_used_at) or now)
        < self.terminal_idle_seconds then
        return false
    end
    if state._renderer_fanout_queued == true then return false end
    for sampler_key in pairs(state.sampler_keys or {}) do
        local handle = self.sampler_handles[sampler_key]
        if handle and handle.source == state then
            if handle.promotion_queued == true
                or handle.gpu_retry_scheduled == true then
                return false
            end
            local bindings = handle.live_bindings
            if type(bindings) == "table" and next(bindings) ~= nil then
                return false
            end
        end
    end
    return true
end

function RemoteTexture:_retire_source(state)
    if not state or self.sources[state.asset_id] ~= state then return false end
    self:_terminal_lru_remove(state)
    self.sources[state.asset_id] = nil
    self.source_count = math.max(0, self.source_count - 1)
    local retired_handles = 0
    for sampler_key in pairs(state.sampler_keys or {}) do
        local handle = self.sampler_handles[sampler_key]
        if handle and handle.source == state then
            self.sampler_handles[sampler_key] = nil
            self.sampler_handle_count = math.max(
                0, self.sampler_handle_count - 1)
            handle.retired = true
            retired_handles = retired_handles + 1
        end
    end
    state.retired = true
    self.stats.evicted_sources = self.stats.evicted_sources + 1
    self.stats.evicted_sampler_handles =
        self.stats.evicted_sampler_handles + retired_handles
    return true
end

function RemoteTexture:_prune_terminal_sources()
    if self.source_count <= self.max_sources
        and self.sampler_handle_count <= self.max_sampler_handles then
        return 0
    end
    local now = self.now()
    local scanned, evicted = 0, 0
    while self._terminal_lru_head
        and scanned < self.max_prune_scans_per_pump
        and evicted < self.max_evictions_per_pump
        and (self.source_count > self.max_sources
            or self.sampler_handle_count > self.max_sampler_handles) do
        local state = self._terminal_lru_head
        scanned = scanned + 1
        if self:_source_can_retire(state, now) then
            if self:_retire_source(state) then evicted = evicted + 1 end
        else
            -- a live binding or scheduled publication pins the source. move it
            -- to the tail so other terminal sources still get a bounded chance
            self:_terminal_lru_append(state)
            self.stats.terminal_prune_blocked =
                self.stats.terminal_prune_blocked + 1
        end
    end
    self.stats.terminal_prune_scans =
        self.stats.terminal_prune_scans + scanned
    return evicted
end

function RemoteTexture:_log_once(key, message)
    if self.warned[key] then return end
    self.warned[key] = true
    pcall(self.logger, message)
end

function RemoteTexture:_sync_handles(state)
    for sampler_key in pairs(state.sampler_keys) do
        local handle = self.sampler_handles[sampler_key]
        if handle then
            handle.state = state.status
            handle.status_revision = state.status_revision
            handle.revision = state.revision
            handle.pending = state.status ~= "ready"
            handle.ready = state.status == "ready"
            handle.cache_path = state.cache_path
            handle.last_error = state.last_error
        end
    end
end

function RemoteTexture:_set_status(state, status)
    if state.status ~= status then
        local was_terminal = state.status == "ready"
            or state.status == "negative"
        local is_terminal = status == "ready" or status == "negative"
        if was_terminal and not is_terminal then
            self:_terminal_lru_remove(state)
        end
        state.status = status
        state.status_revision = state.status_revision + 1
        if is_terminal then
            state.last_used_at = self.now()
            self:_terminal_lru_append(state)
        end
        self:_sync_handles(state)
    end
end

function RemoteTexture:_new_source(asset_id)
    local state = {
        asset_id = asset_id,
        status = "new",
        status_revision = 0,
        revision = 0,
        attempt = 0,
        next_retry_at = 0,
        negative_until = 0,
        cache_checked = false,
        cache_path = nil,
        last_error = nil,
        sampler_keys = {},
        -- pairs() order is deliberately not part of the publication ABI
        -- Renderer-side fan-out consumes this insertion-ordered list under a
        -- per-pump budget, so one source with many sampler variants cannot
        -- monopolize a completion frame
        sampler_key_order = {},
        last_used_at = self.now(),
    }
    self.sources[asset_id] = state
    self.source_count = self.source_count + 1
    return state
end

local function copy_sampler_descriptor(descriptor)
    local copy = {}
    if type(descriptor) == "table" then
        for key, value in pairs(descriptor) do
            if type(key) == "string"
                and (type(value) == "string" or type(value) == "number"
                    or type(value) == "boolean") then
                copy[key] = value
            end
        end
    end
    return copy
end

function RemoteTexture:_sampler_handle(state, sampler_key, asset_path, descriptor)
    sampler_key = tostring(sampler_key or ("texture|id:" .. state.asset_id))
    local handle = self.sampler_handles[sampler_key]
    if handle and handle.asset_id == state.asset_id then
        self.stats.deduplicated = self.stats.deduplicated + 1
        self:_touch_source(state)
        return handle
    end
    -- a sampler key is expected to include the canonical asset identity, but
    -- injected callers are still contained: replacing a mismatched key must
    -- not inflate the handle count or leave the old source claiming it
    local replaces_mismatched_handle = handle ~= nil
    if replaces_mismatched_handle then
        local old_source = handle.source
        if type(old_source) == "table" and old_source.sampler_keys then
            old_source.sampler_keys[sampler_key] = nil
        end
        handle.retired = true
    end
    handle = {
        asset_id = state.asset_id,
        sampler_key = sampler_key,
        source = state,
        asset_path = tostring(asset_path or state.asset_id),
        options = copy_sampler_descriptor(descriptor),
        state = state.status,
        status_revision = state.status_revision,
        revision = state.revision,
        pending = state.status ~= "ready",
        ready = state.status == "ready",
        cache_path = state.cache_path,
        last_error = state.last_error,
        authored = true,
        -- Renderer bindings are installed lazily.  Weak target keys ensure the
        -- acquisition manager never extends a scene/GUI resource lifetime
        live_bindings = setmetatable({}, { __mode = "k" }),
    }
    self.sampler_handles[sampler_key] = handle
    if not replaces_mismatched_handle then
        self.sampler_handle_count = self.sampler_handle_count + 1
    end
    state.sampler_keys[sampler_key] = true
    state.sampler_key_order[#state.sampler_key_order + 1] = sampler_key
    self:_touch_source(state)
    return handle
end

function RemoteTexture:_validate(data, asset_id)
    if type(data) ~= "string" or data == "" then return false, "empty" end
    if #data > self.max_encoded_bytes then return false, "encoded_too_large" end
    local started = self.now()
    local ok, valid, reason = pcall(self.validator, data, asset_id)
    local elapsed_ms = math.max(0, (self.now() - started) * 1000)
    self.stats.validation_ms_total = self.stats.validation_ms_total + elapsed_ms
    self.stats.validation_ms_max = math.max(self.stats.validation_ms_max, elapsed_ms)
    if not ok then return false, "validator_error" end
    if valid ~= true then
        reason = tostring(reason or "decode_failed")
        self.stats.validation_rejections = self.stats.validation_rejections + 1
        if reason == "decoded_dimensions_too_large" then
            self.stats.decoded_limit_rejections = self.stats.decoded_limit_rejections + 1
        end
        return false, reason
    end
    return true
end

function RemoteTexture:_remove_cache(path)
    local fs = self.filesystem
    if fs and type(fs.remove) == "function" and type(path) == "string" then
        pcall(fs.remove, path)
    end
end

function RemoteTexture:_try_persistent_cache(state)
    if state.cache_checked then return state.status == "ready" end
    state.cache_checked = true
    local fs = self.filesystem
    local path = RemoteTexture.cache_path_for_id(state.asset_id, self.cache_dir)
    if not fs or not path or type(fs.getInfo) ~= "function" or type(fs.read) ~= "function" then
        self.stats.cache_misses = self.stats.cache_misses + 1
        return false
    end
    local info_ok, info = pcall(fs.getInfo, path, "file")
    local size = info_ok and type(info) == "table" and tonumber(info.size) or nil
    if not info or not size or size <= 0 or size > self.max_encoded_bytes then
        if info then
            self.stats.cache_invalid = self.stats.cache_invalid + 1
            self:_remove_cache(path)
        else
            self.stats.cache_misses = self.stats.cache_misses + 1
        end
        return false
    end
    local read_ok, data = pcall(fs.read, path)
    local valid, reason = false, "cache_read_failed"
    if read_ok then valid, reason = self:_validate(data, state.asset_id) end
    if not valid then
        self.stats.cache_invalid = self.stats.cache_invalid + 1
        self:_remove_cache(path)
        self:_log_once("cache_" .. tostring(reason),
            "[rbx] remote texture cache entry rejected: " .. tostring(reason))
        return false
    end
    self.stats.cache_hits = self.stats.cache_hits + 1
    state.cache_path = path
    state.last_error = nil
    state.revision = state.revision + 1
    self:_set_status(state, "ready")
    self:_sync_handles(state)
    return true
end

function RemoteTexture:_ensure_pool()
    if self.pool then return self.pool end
    if self.stopped then return nil, "stopped" end
    local config = {
        worker_count = self.worker_count,
        connect_timeout_seconds = self.connect_timeout_seconds,
        total_timeout_seconds = self.total_timeout_seconds,
        max_encoded_bytes = self.max_encoded_bytes,
        endpoint_prefix = ENDPOINT_PREFIX,
    }
    local ok, pool, reason = pcall(self.pool_factory, config)
    if not ok then
        reason = tostring(pool)
        pool = nil
    end
    if not pool then
        self.stats.worker_start_failures = self.stats.worker_start_failures + 1
        self:_log_once("worker_unavailable",
            "[rbx] remote texture workers unavailable; requests will retry after the negative TTL"
                .. (reason and (" (" .. tostring(reason) .. ")") or ""))
        return nil, reason or "worker_unavailable"
    end
    self.pool = pool
    self:_log_once("enabled", string.format(
        "[rbx] remote textures enabled: %d async worker(s), %.1f MiB encoded cap",
        self.worker_count, self.max_encoded_bytes / (1024 * 1024)))
    return pool
end

function RemoteTexture:_negative(state, reason)
    state.last_error = tostring(reason or "failed")
    state.negative_until = self.now() + self.negative_ttl_seconds
    self.stats.negative_transitions = self.stats.negative_transitions + 1
    self:_set_status(state, "negative")
    self:_sync_handles(state)
    self:_log_once("failure_" .. state.last_error,
        "[rbx] remote texture request failed: " .. state.last_error
            .. "; retrying after finite negative TTL")
end

function RemoteTexture:_enqueue(state, is_retry)
    if self.stopped or not self.enabled then return false end
    if self.outstanding >= self.max_queue then
        self.stats.queue_backpressure = self.stats.queue_backpressure + 1
        state.next_retry_at = self.now() + 0.1
        self:_set_status(state, "retry_wait")
        return false
    end
    local pool, pool_error = self:_ensure_pool()
    if not pool then
        self:_negative(state, pool_error or "worker_unavailable")
        return false
    end
    state.attempt = state.attempt + 1
    local accepted, enqueue_error = call_pool(pool, "enqueue", {
        asset_id = state.asset_id,
        attempt = state.attempt,
    })
    if accepted ~= true then
        state.attempt = math.max(0, state.attempt - 1)
        state.next_retry_at = self.now() + self.retry_backoff_seconds
        state.last_error = "enqueue_failed:" .. tostring(enqueue_error)
        self:_set_status(state, "retry_wait")
        return false
    end
    self.outstanding = self.outstanding + 1
    self.stats.scheduled = self.stats.scheduled + 1
    if is_retry then self.stats.retries = self.stats.retries + 1 end
    self:_set_status(state, "inflight")
    return true
end

function RemoteTexture:request(reference, sampler_key, descriptor)
    self:_prune_terminal_sources()
    local asset_id = RemoteTexture.extract_asset_id(reference)
    if not asset_id then
        self.stats.rejected_references = self.stats.rejected_references + 1
        return nil, nil, "ineligible"
    end
    if not self.enabled or self.stopped then
        return nil, nil, self.stopped and "stopped" or "disabled"
    end
    local state = self.sources[asset_id] or self:_new_source(asset_id)
    self:_touch_source(state)
    local handle = self:_sampler_handle(state, sampler_key, reference, descriptor)
    if state.status == "new" and self:_try_persistent_cache(state) then
        self:_sync_handles(state)
        return state, handle, "ready"
    end
    local now = self.now()
    if state.status == "new"
        or (state.status == "negative" and now >= state.negative_until)
        or (state.status == "retry_wait" and now >= state.next_retry_at) then
        if state.status == "negative" then state.attempt = 0 end
        self:_enqueue(state, state.attempt > 0)
    else
        self.stats.deduplicated = self.stats.deduplicated + 1
    end
    self:_sync_handles(state)
    return state, handle, state.status
end

function RemoteTexture:_write_cache(state, data)
    local fs = self.filesystem
    local path = RemoteTexture.cache_path_for_id(state.asset_id, self.cache_dir)
    if not fs or not path or type(fs.createDirectory) ~= "function" or type(fs.write) ~= "function" then
        return nil, "filesystem_unavailable"
    end
    local dir_ok, made = pcall(fs.createDirectory, self.cache_dir)
    if not dir_ok or made == false then return nil, "cache_directory_failed" end
    local write_ok, written = pcall(fs.write, path, data)
    if not write_ok or written == false then return nil, "cache_write_failed" end
    return path
end

function RemoteTexture:_mark_result_failure(state, reason, retryable)
    self.stats.failed_completions = self.stats.failed_completions + 1
    state.last_error = tostring(reason or "failed")
    if retryable ~= false and state.attempt < self.max_attempts then
        local exponent = math.max(0, state.attempt - 1)
        state.next_retry_at = self.now() + self.retry_backoff_seconds * (2 ^ exponent)
        self:_set_status(state, "retry_wait")
        self:_sync_handles(state)
    else
        self:_negative(state, state.last_error)
    end
end

function RemoteTexture:_process_result(result)
    local completion_started = self.now()
    if type(result) ~= "table" then return false end
    local asset_id = normalized_decimal(tostring(result.asset_id or ""))
    local state = asset_id and self.sources[asset_id] or nil
    if not state or tonumber(result.attempt) ~= state.attempt then
        self.stats.stale_completions = self.stats.stale_completions + 1
        return false
    end
    self.stats.completions = self.stats.completions + 1
    if result.ok ~= true then
        self:_mark_result_failure(state, result.error or "download_failed", result.retryable)
        self.stats.completion_ms_max = math.max(self.stats.completion_ms_max,
            math.max(0, (self.now() - completion_started) * 1000))
        return false
    end
    local valid, reason = self:_validate(result.data, asset_id)
    if not valid then
        self:_mark_result_failure(state, reason, false)
        self.stats.completion_ms_max = math.max(self.stats.completion_ms_max,
            math.max(0, (self.now() - completion_started) * 1000))
        return false
    end
    local path, write_error = self:_write_cache(state, result.data)
    if not path then
        self.stats.cache_write_failures = self.stats.cache_write_failures + 1
        self:_mark_result_failure(state, write_error, true)
        self.stats.completion_ms_max = math.max(self.stats.completion_ms_max,
            math.max(0, (self.now() - completion_started) * 1000))
        return false
    end
    self.stats.cache_writes = self.stats.cache_writes + 1
    self.stats.downloaded_bytes = self.stats.downloaded_bytes + #result.data
    self.stats.ready_completions = self.stats.ready_completions + 1
    state.cache_path = path
    state.last_error = nil
    state.revision = state.revision + 1
    self:_set_status(state, "ready")
    self:_sync_handles(state)
    if self.owner and type(self.owner._on_remote_texture_source_ready) == "function" then
        self.stats.source_ready_notifications =
            self.stats.source_ready_notifications + 1
        pcall(self.owner._on_remote_texture_source_ready, self.owner, state)
    end
    self.stats.completion_ms_max = math.max(self.stats.completion_ms_max,
        math.max(0, (self.now() - completion_started) * 1000))
    return true
end

function RemoteTexture:_recover_failed_pool(reason)
    self.stats.worker_runtime_failures = self.stats.worker_runtime_failures + 1
    self:_log_once("worker_runtime_failure",
        "[rbx] remote texture worker failed; queued sources will retry ("
            .. tostring(reason or "unknown") .. ")")
    local failed_pool = self.pool
    self.pool = nil
    if failed_pool then call_pool(failed_pool, "stop") end
    self.outstanding = 0
    local now = self.now()
    for _, state in pairs(self.sources) do
        if state.status == "inflight" then
            state.last_error = "worker_runtime_failure"
            if state.attempt < self.max_attempts then
                state.next_retry_at = now + self.retry_backoff_seconds
                self:_set_status(state, "retry_wait")
            else
                self:_negative(state, state.last_error)
            end
            self:_sync_handles(state)
        end
    end
end

function RemoteTexture:_check_pool_health()
    if not self.pool or type(self.pool.health) ~= "function" then return true end
    local healthy, reason = call_pool(self.pool, "health")
    if healthy == true then return true end
    self:_recover_failed_pool(reason)
    return false
end

function RemoteTexture:_dispatch_due(now)
    local dispatched = 0
    for _, state in pairs(self.sources) do
        if dispatched >= self.max_dispatch_per_pump then break end
        local due = state.status == "retry_wait" and now >= state.next_retry_at
        if state.status == "negative" and now >= state.negative_until then
            state.attempt = 0
            due = true
        end
        if due then
            if self:_enqueue(state, true) then dispatched = dispatched + 1 end
        end
    end
    return dispatched
end

-- called from renderer update, never draw. result count and polling budget are
-- bounded. Individual validation/cache writes are measured because a platform
-- image decoder or filesystem call cannot be pre-empted from Lua
function RemoteTexture:pump()
    if self.stopped or not self.enabled then return 0, 0 end
    local started = self.now()
    self:_check_pool_health()
    self:_dispatch_due(started)
    local processed, ready = 0, 0
    while processed < self.max_completions_per_pump
        and (self.now() - started) <= self.pump_budget_seconds do
        if not self.pool then break end
        local result = call_pool(self.pool, "pop")
        if result == nil then break end
        self.outstanding = math.max(0, self.outstanding - 1)
        processed = processed + 1
        if self:_process_result(result) then ready = ready + 1 end
    end
    self:_dispatch_due(self.now())
    self:_prune_terminal_sources()
    local elapsed_ms = math.max(0, (self.now() - started) * 1000)
    self.stats.pump_ms_last = elapsed_ms
    self.stats.pump_ms_max = math.max(self.stats.pump_ms_max, elapsed_ms)
    return processed, ready
end

function RemoteTexture:pending_resource_key(handle)
    if type(handle) ~= "table" then return nil end
    local status = handle.state == "negative" and "negative" or "pending"
    return string.format("__remote_%s|%s|%s", status,
        tostring(handle.asset_id), tostring(handle.sampler_key))
end

function RemoteTexture:get_stats()
    local out = {}
    for key, value in pairs(self.stats) do out[key] = value end
    local pending, ready, negative, retry_wait = 0, 0, 0, 0
    for _, state in pairs(self.sources) do
        if state.status == "ready" then ready = ready + 1
        elseif state.status == "negative" then negative = negative + 1
        elseif state.status == "retry_wait" then retry_wait = retry_wait + 1
        else pending = pending + 1 end
    end
    out.enabled = self.enabled
    out.source_count = pending + ready + negative + retry_wait
    out.pending_sources = pending
    out.ready_sources = ready
    out.negative_sources = negative
    out.retry_wait_sources = retry_wait
    out.sampler_handle_count = self.sampler_handle_count
    out.outstanding = self.outstanding
    out.worker_count = self.pool
        and (type(self.pool.threads) == "table" and #self.pool.threads or self.worker_count)
        or 0
    out.max_encoded_bytes = self.max_encoded_bytes
    out.max_texture_dimension = self.max_texture_dimension
    out.max_decoded_pixels = self.max_decoded_pixels
    out.max_queue = self.max_queue
    out.max_sources = self.max_sources
    out.max_sampler_handles = self.max_sampler_handles
    out.max_promotions_per_pump = self.max_promotions_per_pump
    out.max_ready_handles_per_pump = self.max_ready_handles_per_pump
    out.promotion_budget_ms = self.promotion_budget_seconds * 1000
    out.stopped = self.stopped
    return out
end

function RemoteTexture:stop()
    if self.stopped then return false end
    self.stopped = true
    self.stats.stopped = true
    if self.pool then call_pool(self.pool, "stop") end
    self.pool = nil
    self.outstanding = 0
    for _, state in pairs(self.sources) do
        if state.status ~= "ready" then self:_set_status(state, "stopped") end
    end
    for _, handle in pairs(self.sampler_handles) do
        handle.live_bindings = nil
        handle.promotion_queued = false
    end
    self.owner = nil
    return true
end

RemoteTexture.ENDPOINT_PREFIX = ENDPOINT_PREFIX
RemoteTexture.STOP_TOKEN = STOP_TOKEN
RemoteTexture.DEFAULT_CACHE_DIR = DEFAULT_CACHE_DIR

return RemoteTexture
