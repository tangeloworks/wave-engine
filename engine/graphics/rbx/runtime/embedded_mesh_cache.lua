-- Renderer-local cache for decoded meshes embedded directly in part payloads
--
-- Parts keep a direct memo of the decoded table they currently draw.  this
-- controller owns only the shared, by-content lookup and its accounting.  a
-- live part pins an admitted lookup entry, but a result that cannot be admitted
-- under an all-pinned budget is still safe to use from that part's memo.  Thus
-- cache pressure can reduce future deduplication, never invalidate geometry

local LocalMeshCache = require("engine/graphics/rbx/runtime/local_mesh_cache")

local EmbeddedMeshCache = {}
EmbeddedMeshCache.__index = EmbeddedMeshCache

EmbeddedMeshCache.DEFAULT_MAX_BYTES = 256 * 1024 * 1024
EmbeddedMeshCache.DEFAULT_MAX_ENTRIES = 1024

local CACHE_NODE_BASE_BYTES = 128
local STRING_BASE_BYTES = 24
local MAX_EXACT_BYTES = 9007199254740991

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

local function add_bytes(a, b)
    b = tonumber(b)
    if b == nil or b ~= b or b < 0 or b == math.huge
        or a > MAX_EXACT_BYTES - b then
        return nil
    end
    return a + b
end

local function new_stats()
    return {
        hits = 0,
        misses = 0,
        negative_hits = 0,
        admissions = 0,
        positive_admissions = 0,
        negative_admissions = 0,
        evictions = 0,
        positive_evictions = 0,
        negative_evictions = 0,
        evicted_bytes = 0,
        oversize_rejections = 0,
        estimate_failures = 0,
        pressure_rejections = 0,
        untracked_bindings = 0,
        pin_acquires = 0,
        pin_releases = 0,
        resident_bytes = 0,
        resident_peak_bytes = 0,
        resident_entries = 0,
        resident_peak_entries = 0,
        resident_negative_entries = 0,
        pinned_bytes = 0,
        pinned_entries = 0,
        pinned_bindings = 0,
        retained_hits = 0,
        retained_entry_hits = 0,
        retirements = 0,
        retirement_fallback_clears = 0,
        retirement_negative_drops = 0,
        retirement_context_drops = 0,
        retirement_ephemeral_clears = 0,
        retirement_reaccounted_entries = 0,
        retirement_reaccount_failures = 0,
        retirement_reaccount_evictions = 0,
        retirement_trim_evictions = 0,
        clears = 0,
    }
end

-- single payloads keep their original interned string as the lookup key. Multi-
-- candidate payload sets need a separately framed key space: arbitrary Roblox
-- binary data can contain NUL, so joining candidates with a delimiter is not
-- injective. keeping the spaces distinct also means a malicious single payload
-- cannot alias the byte representation of a framed multi-candidate set
local CONTENT_KIND_COUNT = 4

local function kind_index(is_csg, is_multi)
    if is_multi then
        return is_csg and 4 or 3
    end
    return is_csg and 2 or 1
end

function EmbeddedMeshCache.new(mesh_values, csg_values, options)
    assert(type(mesh_values) == "table", "embedded mesh cache needs mesh values")
    assert(type(csg_values) == "table", "embedded mesh cache needs CSG values")
    options = options or {}

    local self = setmetatable({}, EmbeddedMeshCache)
    self.max_bytes = clamp_integer(options.max_bytes,
        EmbeddedMeshCache.DEFAULT_MAX_BYTES, 0, MAX_EXACT_BYTES)
    self.max_entries = clamp_integer(options.max_entries,
        EmbeddedMeshCache.DEFAULT_MAX_ENTRIES, 0, 1000000)
    self.values = { mesh_values, csg_values, {}, {} }
    self.nodes = { {}, {}, {}, {} }
    self.head = nil
    self.tail = nil
    self.generation = 1
    self.stats = new_stats()

    -- production constructs this around empty tables.  Adopt a legacy/warm
    -- direct table deterministically so every retained value is charged
    for index = 1, CONTENT_KIND_COUNT do
        local values = self.values[index]
        local keys = {}
        for key in pairs(values) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b)
            local at, bt = tostring(a), tostring(b)
            if at ~= bt then return at < bt end
            return type(a) < type(b)
        end)
        for key_index = 1, #keys do
            local key = keys[key_index]
            local value = values[key]
            values[key] = nil
            self:publish(index == 2 or index == 4, key, value, index >= 3)
        end
    end
    return self
end

function EmbeddedMeshCache:is_bound_to(mesh_values, csg_values)
    return self.values[1] == mesh_values and self.values[2] == csg_values
end

function EmbeddedMeshCache:_detach(node)
    local previous, following = node.previous, node.following
    if previous then previous.following = following else self.head = following end
    if following then following.previous = previous else self.tail = previous end
    node.previous = nil
    node.following = nil
end

function EmbeddedMeshCache:_append_mru(node)
    node.previous = self.tail
    node.following = nil
    if self.tail then self.tail.following = node else self.head = node end
    self.tail = node
end

function EmbeddedMeshCache:_touch(node)
    if self.tail == node then return end
    self:_detach(node)
    self:_append_mru(node)
end

function EmbeddedMeshCache:_set_resident(bytes, entries, negatives)
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

function EmbeddedMeshCache:_remove_node(node, evicted)
    if not node or node.pin_count > 0 then return false end
    local nodes = self.nodes[node.kind]
    if nodes[node.key] ~= node then return false end

    self:_detach(node)
    nodes[node.key] = nil
    self.values[node.kind][node.key] = nil
    local stats = self.stats
    self:_set_resident(
        stats.resident_bytes - node.bytes,
        stats.resident_entries - 1,
        stats.resident_negative_entries - (node.negative and 1 or 0))
    if evicted then
        stats.evictions = stats.evictions + 1
        stats.evicted_bytes = stats.evicted_bytes + node.bytes
        if node.negative then
            stats.negative_evictions = stats.negative_evictions + 1
        else
            stats.positive_evictions = stats.positive_evictions + 1
        end
    end
    return true
end

local function estimate_entry_bytes(key, value, context_token)
    local payload_bytes = 0
    if value ~= nil and value ~= false then
        local reason
        payload_bytes, reason = LocalMeshCache.estimate_decoded_bytes(value)
        if payload_bytes == nil then return nil, reason or "estimate_failed" end
    end
    local key_bytes = type(key) == "string" and #key or #tostring(key)
    local total = add_bytes(CACHE_NODE_BASE_BYTES + STRING_BASE_BYTES + key_bytes,
        payload_bytes)
    if total == nil then return nil, "entry_byte_overflow" end
    if context_token ~= nil then
        local context_bytes = type(context_token) == "string"
            and #context_token or #tostring(context_token)
        total = add_bytes(total, STRING_BASE_BYTES + context_bytes)
        if total == nil then return nil, "entry_byte_overflow" end
    end
    return math.floor(total)
end

function EmbeddedMeshCache:get(is_csg, key, is_multi, context_token)
    local kind = kind_index(is_csg, is_multi)
    local node = self.nodes[kind][key]
    local value = node and self.values[kind][key]
    if node and node.context_token ~= nil
        and node.context_token ~= context_token then
        -- the key's bytes are identical, but ChildData may have resolved a
        -- relative MeshId beside a different map. never replay that geometry
        if node.pin_count == 0 then self:_remove_node(node, false) end
        self.stats.misses = self.stats.misses + 1
        return nil, false
    end
    if not node or value == nil then
        if node and node.pin_count == 0 then self:_remove_node(node, false) end
        self.stats.misses = self.stats.misses + 1
        return nil, false
    end
    self.stats.hits = self.stats.hits + 1
    if node.negative then self.stats.negative_hits = self.stats.negative_hits + 1 end
    if (tonumber(node.generation) or self.generation) < self.generation then
        self.stats.retained_hits = self.stats.retained_hits + 1
        if node.last_retained_hit_generation ~= self.generation then
            node.last_retained_hit_generation = self.generation
            self.stats.retained_entry_hits = self.stats.retained_entry_hits + 1
        end
    end
    self:_touch(node)
    return value, true
end

---Admit one decoded result atomically.  if every candidate needed to make room
---is pinned, no old entry is discarded and the caller keeps the result only in
---its part memo
function EmbeddedMeshCache:publish(
        is_csg, key, value, is_multi, context_token)
    if key == nil then return false, "invalid_key" end
    local kind = kind_index(is_csg, is_multi)
    local existing = self.nodes[kind][key]
    local entry_context = type(value) == "table"
        and value.source_kind == "csg_child_parts" and context_token or nil
    if existing and existing.context_token ~= nil
        and existing.context_token ~= entry_context then
        if existing.pin_count > 0 then
            self.stats.pressure_rejections = self.stats.pressure_rejections + 1
            return false, "context_conflict_pinned"
        end
        self:_remove_node(existing, false)
        existing = nil
    end
    if existing then
        self:_touch(existing)
        return true
    end

    local entry_bytes, estimate_reason = estimate_entry_bytes(
        key, value, entry_context)
    if entry_bytes == nil then
        self.stats.estimate_failures = self.stats.estimate_failures + 1
        return false, estimate_reason
    end
    if self.max_entries < 1 or entry_bytes > self.max_bytes then
        self.stats.oversize_rejections = self.stats.oversize_rejections + 1
        return false, "entry_exceeds_budget"
    end

    local projected_bytes = self.stats.resident_bytes + entry_bytes
    local projected_entries = self.stats.resident_entries + 1
    local removals = {}
    local candidate = self.head
    while projected_bytes > self.max_bytes or projected_entries > self.max_entries do
        while candidate and candidate.pin_count > 0 do
            candidate = candidate.following
        end
        if not candidate then
            self.stats.pressure_rejections = self.stats.pressure_rejections + 1
            return false, "all_candidates_pinned"
        end
        removals[#removals + 1] = candidate
        projected_bytes = projected_bytes - candidate.bytes
        projected_entries = projected_entries - 1
        candidate = candidate.following
    end
    for index = 1, #removals do self:_remove_node(removals[index], true) end

    local negative = value == nil or value == false
    local node = {
        key = key,
        kind = kind,
        bytes = entry_bytes,
        negative = negative,
        pin_count = 0,
        generation = self.generation,
        context_token = entry_context,
    }
    self.nodes[kind][key] = node
    self.values[kind][key] = negative and false or value
    self:_append_mru(node)
    local stats = self.stats
    stats.admissions = stats.admissions + 1
    if negative then
        stats.negative_admissions = stats.negative_admissions + 1
    else
        stats.positive_admissions = stats.positive_admissions + 1
    end
    self:_set_resident(
        stats.resident_bytes + entry_bytes,
        stats.resident_entries + 1,
        stats.resident_negative_entries + (negative and 1 or 0))
    return true
end

function EmbeddedMeshCache:pin(is_csg, key, generation, is_multi)
    if generation ~= nil and generation ~= self.generation then return false end
    local node = self.nodes[kind_index(is_csg, is_multi)][key]
    if not node or node.negative then return false end
    if node.pin_count == 0 then
        self.stats.pinned_entries = self.stats.pinned_entries + 1
        self.stats.pinned_bytes = self.stats.pinned_bytes + node.bytes
    end
    node.pin_count = node.pin_count + 1
    self.stats.pinned_bindings = self.stats.pinned_bindings + 1
    self.stats.pin_acquires = self.stats.pin_acquires + 1
    return true
end

function EmbeddedMeshCache:unpin(is_csg, key, generation, is_multi)
    if generation ~= nil and generation ~= self.generation then return false end
    local node = self.nodes[kind_index(is_csg, is_multi)][key]
    if not node or node.pin_count < 1 then return false end
    node.pin_count = node.pin_count - 1
    self.stats.pinned_bindings = math.max(0, self.stats.pinned_bindings - 1)
    self.stats.pin_releases = self.stats.pin_releases + 1
    if node.pin_count == 0 then
        self.stats.pinned_entries = math.max(0, self.stats.pinned_entries - 1)
        self.stats.pinned_bytes = math.max(0, self.stats.pinned_bytes - node.bytes)
    end
    return true
end

function EmbeddedMeshCache:note_untracked_binding()
    self.stats.untracked_bindings = self.stats.untracked_bindings + 1
end

function EmbeddedMeshCache:_trim_unpinned()
    local candidate = self.head
    while self.stats.resident_bytes > self.max_bytes
        or self.stats.resident_entries > self.max_entries do
        while candidate and candidate.pin_count > 0 do candidate = candidate.following end
        if not candidate then return false end
        local following = candidate.following
        self:_remove_node(candidate, true)
        candidate = following
    end
    return true
end

local RETIREMENT_STREAM_FIELDS = {
    positions = true,
    normals = true,
    uvs = true,
    colors = true,
    _gpu_colors = true,
    normal_ids = true,
    tangents = true,
    indices = true,
    faces = true,
    face_ids = true,
    vertices = true,
    weights = true,
    bone_indices = true,
}

-- Projection face ids are derived from a particular part-scale/projection
-- context and can contain one number per vertex for up to eight contexts. they
-- are deliberately not part of the immutable decoded payload. Scene GPU
-- resources have already been released before generation retirement, so drop
-- these recomputable arrays throughout the decoded LOD graph before charging a
-- retained entry for the next map
local function strip_retirement_ephemera(root)
    if type(root) ~= "table" then return 0 end
    local seen = { [root] = true }
    local stack = { root }
    local stripped = 0
    local visited = 0
    while #stack > 0 and visited < 16384 do
        local current = stack[#stack]
        stack[#stack] = nil
        visited = visited + 1
        if rawget(current, "_proj_face_ids_cache") ~= nil then
            rawset(current, "_proj_face_ids_cache", nil)
            stripped = stripped + 1
        end
        for key, value in pairs(current) do
            if type(value) == "table"
                and not RETIREMENT_STREAM_FIELDS[key]
                and not seen[value] then
                seen[value] = true
                stack[#stack + 1] = value
            end
        end
    end
    return stripped
end

---Advance the map-generation token while retaining immutable, content-keyed
---decoded results. the renderer must sever every old part memo and release all
---pins before calling this. if that ownership invariant is ever violated, fail
---closed by clearing the whole cache rather than carrying a live old-map edge
---into the next generation
function EmbeddedMeshCache:retire_generation()
    local node = self.head
    while node do
        if (tonumber(node.pin_count) or 0) > 0 then
            self.stats.retirement_fallback_clears =
                self.stats.retirement_fallback_clears + 1
            self:clear()
            return false, "pinned_bindings_remain"
        end
        node = node.following
    end

    -- a failed decode is not safe to retain forever: nested CSG resolution can
    -- depend on map-relative assets, and allocation/decompression failures may
    -- be transient. csg_child_parts is retained only when it carries the exact
    -- map-directory/asset-policy context that produced it, legacy contextless
    -- entries are dropped. Direct positive geometry is context-independent
    local retained_bytes = 0
    local retained_entries = 0
    node = self.head
    while node do
        local following = node.following
        local value = self.values[node.kind][node.key]
        local remove_reason = nil
        local entry_bytes = nil
        if node.negative or value == false or value == nil then
            remove_reason = "negative"
        elseif type(value) == "table" and value.source_kind == "csg_child_parts"
            and node.context_token == nil then
            remove_reason = "context"
        else
            self.stats.retirement_ephemeral_clears =
                self.stats.retirement_ephemeral_clears
                + strip_retirement_ephemera(value)
            entry_bytes = estimate_entry_bytes(
                node.key, value, node.context_token)
            if entry_bytes == nil then
                remove_reason = "reaccount_failure"
            elseif entry_bytes > self.max_bytes then
                remove_reason = "reaccount_oversize"
            end
        end

        if remove_reason ~= nil then
            self:_remove_node(node, false)
            if remove_reason == "negative" then
                self.stats.retirement_negative_drops =
                    self.stats.retirement_negative_drops + 1
            elseif remove_reason == "context" then
                self.stats.retirement_context_drops =
                    self.stats.retirement_context_drops + 1
            elseif remove_reason == "reaccount_failure" then
                self.stats.retirement_reaccount_failures =
                    self.stats.retirement_reaccount_failures + 1
            else
                self.stats.retirement_reaccount_evictions =
                    self.stats.retirement_reaccount_evictions + 1
            end
        else
            node.bytes = entry_bytes
            retained_bytes = retained_bytes + entry_bytes
            retained_entries = retained_entries + 1
            self.stats.retirement_reaccounted_entries =
                self.stats.retirement_reaccounted_entries + 1
        end
        node = following
    end

    -- _remove_node adjusted the old accounting along the way, replace it with
    -- the freshly measured post-derivation total before enforcing the current
    -- ceiling. this closes the gap where a limit was lowered while all entries
    -- were pinned and only became evictable during map reset
    self:_set_resident(retained_bytes, retained_entries, 0)
    self.generation = self.generation + 1
    self.stats.retirements = self.stats.retirements + 1
    self.stats.pinned_bytes = 0
    self.stats.pinned_entries = 0
    self.stats.pinned_bindings = 0
    local evictions_before = self.stats.evictions
    self:_trim_unpinned()
    self.stats.retirement_trim_evictions =
        self.stats.retirement_trim_evictions
        + (self.stats.evictions - evictions_before)
    return true
end

function EmbeddedMeshCache:reconfigure(options)
    options = options or {}
    if options.max_bytes ~= nil then
        self.max_bytes = clamp_integer(options.max_bytes,
            self.max_bytes, 0, MAX_EXACT_BYTES)
    end
    if options.max_entries ~= nil then
        self.max_entries = clamp_integer(options.max_entries,
            self.max_entries, 0, 1000000)
    end
    return self:_trim_unpinned()
end

---Fully purge renderer-owned decoded content. map reloads use
---retire_generation, renderer destruction uses this terminal clear
function EmbeddedMeshCache:clear()
    for kind = 1, CONTENT_KIND_COUNT do
        local values = self.values[kind]
        for key in pairs(values) do values[key] = nil end
        self.nodes[kind] = {}
    end
    self.head = nil
    self.tail = nil
    self.generation = self.generation + 1
    self.stats.clears = self.stats.clears + 1
    self.stats.resident_bytes = 0
    self.stats.resident_entries = 0
    self.stats.resident_negative_entries = 0
    self.stats.pinned_bytes = 0
    self.stats.pinned_entries = 0
    self.stats.pinned_bindings = 0
end

function EmbeddedMeshCache:snapshot()
    local out = {}
    for key, value in pairs(self.stats) do out[key] = value end
    out.max_bytes = self.max_bytes
    out.max_entries = self.max_entries
    out.generation = self.generation
    out.over_budget = out.resident_bytes > self.max_bytes
        or out.resident_entries > self.max_entries
    out.oldest_key = self.head and self.head.key or nil
    out.newest_key = self.tail and self.tail.key or nil
    return out
end

return EmbeddedMeshCache
