-- cache the CPU work shared by static scene chunks
-- a cache entry is usable only while its source and dependencies still match

local ffi = require("ffi")
local Cache = require("engine/graphics/rbx/compiled_scene_cache")
local MapCache = require("engine/graphics/rbx/map_cache")
local ContactAO = runtime_require("contact_ao.lua")

local ANALYSIS_MODE = "render-bounds-contact-ao-v1"
local DEPENDENCY_PREFIX = "local-mesh|"
local MAX_DEPENDENCY_BYTES = 128 * 1024 * 1024
local MAX_TOTAL_DEPENDENCY_BYTES = 512 * 1024 * 1024

-- Hashing the implementation bundle makes a development build fail closed
-- even when somebody forgets to bump a handwritten schema token.  the digest
-- is memoized for the renderer process, these files are immutable after boot
local ENGINE_ROOT = require("engine/root")
local VERSION_FILES = {
    ENGINE_ROOT .. "/graphics/rbx/compiled_scene_cache.lua",
    ENGINE_ROOT .. "/graphics/rbx/map_cache.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/compiled_scene_analysis.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/common.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/contact_ao.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/geometry.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/mesh.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/scene.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/assets.lua",
    ENGINE_ROOT .. "/graphics/rbx/runtime/render.lua",
}

local version_bundle_digest
local version_bundle_error

local function finite_number(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function hash_bytes_hex(data)
    if type(data) ~= "string" then return nil, "hash_data_required" end
    local ok_hash, digest = pcall(love.data.hash, "sha256", data)
    if not ok_hash or digest == nil then
        return nil, "sha256_failed:" .. tostring(digest)
    end
    if type(digest) == "userdata" and type(digest.getString) == "function" then
        local ok_string, value = pcall(digest.getString, digest)
        if not ok_string then return nil, "sha256_failed:" .. tostring(value) end
        digest = value
    end
    local ok_hex, encoded = pcall(
        love.data.encode, "string", "hex", digest)
    if not ok_hex or type(encoded) ~= "string" then
        return nil, "hex_encode_failed:" .. tostring(encoded)
    end
    return encoded
end

local function implementation_digest()
    if version_bundle_digest ~= nil then return version_bundle_digest end
    if version_bundle_error ~= nil then return nil, version_bundle_error end
    local components = {}
    for index = 1, #VERSION_FILES do
        local path = VERSION_FILES[index]
        local data, read_error = love.filesystem.read(path)
        if type(data) ~= "string" then
            version_bundle_error = "version_source_read_failed:"
                .. path .. ":" .. tostring(read_error)
            return nil, version_bundle_error
        end
        local digest, digest_error = hash_bytes_hex(data)
        if not digest then
            version_bundle_error = "version_source_hash_failed:"
                .. path .. ":" .. tostring(digest_error)
            return nil, version_bundle_error
        end
        components[#components + 1] = path
        components[#components + 1] = "\0"
        components[#components + 1] = digest
        components[#components + 1] = "\0"
    end
    version_bundle_digest, version_bundle_error =
        hash_bytes_hex(table.concat(components))
    return version_bundle_digest, version_bundle_error
end

local function safe_dependency_path(path)
    if type(path) ~= "string" or path == "" or #path > 4096
        or path:find("\0", 1, true) then
        return nil
    end
    path = path:gsub("\\", "/"):gsub("^%./", "")
    if path:sub(1, 1) == "/" or path:match("^%a:") then return nil end
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then return nil end
    end
    return path
end

local function part_cache_key(part, index)
    local referent = type(part) == "table" and rawget(part, "_map_referent")
        or nil
    if referent ~= nil and tostring(referent) ~= "" then
        return "referent:" .. tostring(referent)
    end
    return "loaded-index:" .. tostring(index)
end

local function cache_name_for(map_path, source)
    local basename = tostring(map_path or "map")
        :gsub("\\", "/"):match("([^/]+)$") or "map"
    basename = basename:gsub("[^%w%._%-]", "_")
    if #basename > 72 then basename = basename:sub(1, 72) end
    local hash = type(source) == "table" and tostring(source.hash or "") or ""
    hash = hash:gsub("[^%w]", "")
    if #hash < 8 then return nil end
    return basename .. "-" .. hash:sub(1, 24) .. "-analysis-v1"
end

local function context_options(renderer)
    return {
        coordinate_mode = "rbx-runtime-mirror-conjugation-v1",
        flip_loaded_map_horizontally =
            renderer.flip_loaded_map_horizontally ~= false,
        accurate_face_axes = RBX._accurate_face_axes == true,
        accurate_mesh_normals = renderer.accurate_mesh_normals ~= false,
        independent_decal_transparency =
            renderer.independent_decal_transparency ~= false,
        parse_invisible_parts = RBX._parse_invisible_parts ~= false,
        physics_anchor_loaded_parts =
            renderer.physics_anchor_loaded_parts == true,
        surface_detail_geometry_enabled =
            renderer.surface_detail_geometry_enabled == true,
        sky_occlusion_bake = renderer.sky_occlusion_bake == true,
        material_studs_per_tile =
            tonumber(renderer.material_studs_per_tile) or 8,
        visibility_cell_size = tonumber(renderer.visibility_cell_size) or 64,
        enable_occlusion_culling =
            renderer.enable_occlusion_culling == true,
        use_instancing = renderer.use_instancing == true,
        mesh_instancing = renderer.mesh_instancing == true,
        enable_repeated_mesh_indexing =
            renderer.enable_repeated_mesh_indexing ~= false,
        enable_static_textured_indexing =
            renderer.enable_static_textured_indexing ~= false,
        enable_static_textured_spatial_pages =
            renderer.enable_static_textured_spatial_pages ~= false,
        force_static_textured_spatial_pages =
            renderer.force_static_textured_spatial_pages == true,
        static_textured_spatial_page_max_batches =
            tonumber(renderer.static_textured_spatial_page_max_batches) or 256,
        static_textured_spatial_page_max_draw_amplification =
            tonumber(renderer.static_textured_spatial_page_max_draw_amplification)
                or 2,
        adaptive_mega_batch = renderer.adaptive_mega_batch ~= false,
        shadow_caster_mode = "cascaded-directional-atlas-v2",
        disable_material_maps = renderer.disable_material_maps == true,
        disable_normal_maps = renderer.disable_normal_maps == true,
        constant_fragment_shader =
            renderer.constant_fragment_shader == true,
        textured_shader_quality =
            tostring(renderer.textured_shader_quality or "full"),
        render_backend_name = tostring(renderer.render_backend_name or "love"),
        incremental_static_release =
            renderer.incremental_static_release ~= false,
        static_shape_depth_bias =
            tonumber(renderer.static_shape_depth_bias) or 0,
        material_depth_bias = tonumber(renderer.material_depth_bias) or 0,
        mesh_depth_bias = tonumber(renderer.mesh_depth_bias) or 0,
        decal_depth_bias = tonumber(renderer.decal_depth_bias) or 0,
        decal_surface_offset = tonumber(renderer.decal_surface_offset) or 0,
        surface_detail_depth_bias =
            tonumber(renderer.surface_detail_depth_bias) or 0,

        -- additional conservative dimensions are legal in the canonical
        -- options map and make analysis-only reuse fail closed across local
        -- acquisition or bundle-root policy changes
        analysis_mode = ANALYSIS_MODE,
        allow_remote_mesh_fetch = renderer.allow_remote_mesh_fetch == true,
        asset_root = tostring(renderer.asset_root or ""),
    }
end

local function build_context(renderer, source, dependencies)
    local code_digest, digest_error = implementation_digest()
    if not code_digest then return nil, digest_error end
    if type(source) ~= "table" or type(source.hash) ~= "string"
        or source.hash == "" or not finite_number(source.byte_size)
        or source.byte_size < 0 then
        return nil, "source_metadata_required"
    end
    local versions = {}
    for index = 1, #Cache.REQUIRED_VERSION_DIMENSIONS do
        versions[Cache.REQUIRED_VERSION_DIMENSIONS[index]] =
            "implementation-sha256:" .. code_digest
    end
    versions.contact_ao_format = ContactAO.FORMAT_VERSION
    return Cache.build_context({
        source_hash_algorithm = source.hash_algorithm or "md5",
        source_hash = source.hash,
        source_byte_size = source.byte_size,
        parse_cache_format_version = source.parse_cache_format_version
            or MapCache.FORMAT_VERSION,
        options = context_options(renderer),
        material_schema = {
            analysis_mode = ANALYSIS_MODE,
            implementation_sha256 = code_digest,
        },
        versions = versions,
        dependencies = dependencies or {},
    })
end

local function clone_scalar_stats(source)
    local result = {}
    for key, value in pairs(type(source) == "table" and source or {}) do
        local kind = type(value)
        if kind == "number" and finite_number(value)
            or kind == "string" or kind == "boolean" then
            result[key] = value
        end
    end
    return result
end

local function read_dependency(path, expected_size)
    path = safe_dependency_path(path)
    if not path then return nil, "unsafe_dependency_path" end
    local info = love.filesystem.getInfo(path, "file")
    local size = type(info) == "table" and tonumber(info.size) or nil
    if not size or size < 0 or size > MAX_DEPENDENCY_BYTES then
        return nil, "dependency_missing_or_oversized:" .. path
    end
    if expected_size ~= nil and size ~= tonumber(expected_size) then
        return nil, "dependency_size_changed:" .. path
    end
    local data, read_error = love.filesystem.read(path)
    if type(data) ~= "string" or #data ~= size then
        return nil, "dependency_read_failed:" .. path .. ":"
            .. tostring(read_error)
    end
    local digest, digest_error = hash_bytes_hex(data)
    if not digest then
        return nil, "dependency_hash_failed:" .. path .. ":"
            .. tostring(digest_error)
    end
    return {
        key = DEPENDENCY_PREFIX .. path,
        kind = "local-mesh",
        status = "ready",
        digest_algorithm = "sha256",
        digest = digest,
        byte_size = size,
        remote = false,
    }
end

local function verify_cached_dependencies(cached_context)
    local dependencies = type(cached_context) == "table"
        and cached_context.dependencies or nil
    if type(dependencies) ~= "table" then
        return nil, "cached_dependencies_required"
    end
    local result = {}
    local total_bytes = 0
    for index = 1, #dependencies do
        local source = dependencies[index]
        local key = type(source) == "table" and source.key or nil
        if type(key) ~= "string"
            or key:sub(1, #DEPENDENCY_PREFIX) ~= DEPENDENCY_PREFIX
            or source.kind ~= "local-mesh"
            or source.remote == true then
            return nil, "unsupported_cached_dependency"
        end
        local path = key:sub(#DEPENDENCY_PREFIX + 1)
        local dependency, dependency_error =
            read_dependency(path, source.byte_size)
        if not dependency then return nil, dependency_error end
        total_bytes = total_bytes + dependency.byte_size
        if total_bytes > MAX_TOTAL_DEPENDENCY_BYTES then
            return nil, "dependency_total_cap_exceeded"
        end
        result[#result + 1] = dependency
    end
    return result
end

local function current_part_lookup(renderer)
    local keys = {}
    local by_key = {}
    for index = 1, #(renderer.parts or {}) do
        local part = renderer.parts[index]
        if type(part) ~= "table" or part._destroyed then
            return nil, nil, "invalid_runtime_part"
        end
        local key = part_cache_key(part, index)
        if by_key[key] ~= nil then
            return nil, nil, "duplicate_runtime_part_key:" .. key
        end
        keys[index] = key
        by_key[key] = part
    end
    return keys, by_key
end

local function apply_payload(renderer, payload, load_ms)
    if type(payload) ~= "table" or type(payload.stats) ~= "table"
        or payload.stats.analysis_mode ~= ANALYSIS_MODE
        or #(payload.included_part_keys or {}) ~= 0
        or #(payload.chunks or {}) ~= 0
        or #(payload.instanced_mesh_groups or {}) ~= 0 then
        return false, "analysis_payload_contract_mismatch"
    end
    local keys, by_key, lookup_error = current_part_lookup(renderer)
    if not keys then return false, lookup_error end
    if payload.source_part_count ~= #keys then
        return false, "analysis_part_count_mismatch"
    end

    local bounds = payload.render_bounds
    local ao = payload.contact_ao
    if type(bounds) ~= "table" or type(ao) ~= "table"
        or bounds.rows.count ~= #keys or ao.rows.count ~= #keys then
        return false, "analysis_stream_count_mismatch"
    end
    local bounds_values = ffi.cast("const double*",
        ffi.cast("const uint8_t*", bounds.rows.data))
    local seen_bounds = {}
    for index = 1, #bounds.part_keys do
        local key = bounds.part_keys[index]
        local part = by_key[key]
        if not part or seen_bounds[key] then
            return false, "analysis_bounds_part_mismatch:" .. tostring(key)
        end
        seen_bounds[key] = true
        local offset = (index - 1) * 6
        part._rb_cache = {
            min_x = tonumber(bounds_values[offset]),
            min_y = tonumber(bounds_values[offset + 1]),
            min_z = tonumber(bounds_values[offset + 2]),
            max_x = tonumber(bounds_values[offset + 3]),
            max_y = tonumber(bounds_values[offset + 4]),
            max_z = tonumber(bounds_values[offset + 5]),
            cf = part.CFrame,
            remote_mesh_revision = renderer._remote_mesh_asset_revision or 0,
        }
    end

    local ao_values = ffi.cast("const double*",
        ffi.cast("const uint8_t*", ao.rows.data))
    local seen_ao = {}
    for index = 1, #ao.part_keys do
        local key = ao.part_keys[index]
        local part = by_key[key]
        if not part or seen_ao[key] then
            return false, "analysis_ao_part_mismatch:" .. tostring(key)
        end
        seen_ao[key] = true
        local offset = (index - 1) * 4
        part._contact_ao_top = tonumber(ao_values[offset])
        part._contact_ao_bottom = tonumber(ao_values[offset + 1])
        part._contact_ao_side = tonumber(ao_values[offset + 2])
        part._contact_ao_max = tonumber(ao_values[offset + 3])
    end

    for index = 1, #keys do
        if not seen_bounds[keys[index]] or not seen_ao[keys[index]] then
            return false, "analysis_part_coverage_mismatch:" .. keys[index]
        end
    end

    local stats = clone_scalar_stats(payload.stats.contact_stats)
    stats.contact_revision = (renderer._contact_separation_revision or 0) + 1
    stats.cache_hit = true
    stats.cache_load_ms = load_ms or 0
    stats.build_ms = load_ms or 0
    stats.reset_ms = 0
    stats.entry_collect_ms = 0
    stats.pack_ms = 0
    stats.worker_wall_ms = 0
    stats.worker_cpu_ms = 0
    stats.worker_cpu_max_ms = 0
    stats.worker_count = 0
    stats.sync_kernel_ms = 0
    stats.result_apply_ms = 0
    stats.aggregate_ms = 0
    renderer._contact_separation_revision = stats.contact_revision
    renderer._contact_separation_stats = stats
    renderer._contact_ao_last_error = nil
    return true
end

function RBX:_reset_compiled_scene_analysis_state()
    self._compiled_scene_analysis_state = nil
    self._compiled_scene_analysis_pending = nil
end

function RBX:_begin_compiled_scene_analysis(map_path, source)
    self:_reset_compiled_scene_analysis_state()
    if self.compiled_scene_analysis_cache_enabled == false then
        return false
    end
    local cache_name = cache_name_for(map_path, source)
    if not cache_name then return false end
    self._compiled_scene_analysis_state = {
        active = true,
        map_path = map_path,
        source = source,
        cache_name = cache_name,
        dependencies = {},
        dependency_order = {},
        incomplete = false,
        restored = false,
    }
    return true
end

-- called from the local-mesh resolver.  Supplying the bytes hashes the exact
-- payload that produced the decoded mesh, a later same-process cache hit can
-- pass the digest retained on that decoded value instead
function RBX:_note_compiled_scene_mesh_dependency(
        resolved_path, data, known_digest, known_size)
    local state = self._compiled_scene_analysis_state
    if type(state) ~= "table" or state.active ~= true then return false end
    local path = safe_dependency_path(resolved_path)
    if not path then
        state.incomplete = true
        state.incomplete_reason = "mesh_dependency_unresolved"
        return false
    end
    local key = DEPENDENCY_PREFIX .. path
    local record = state.dependencies[key]
    if not record then
        record = { key = key, path = path }
        state.dependencies[key] = record
        state.dependency_order[#state.dependency_order + 1] = key
    end
    if type(data) == "string" then
        local digest, digest_error = hash_bytes_hex(data)
        if not digest then
            state.incomplete = true
            state.incomplete_reason = digest_error
            return false
        end
        record.digest = digest
        record.byte_size = #data
    elseif type(known_digest) == "string" and known_digest ~= ""
        and finite_number(known_size) and known_size >= 0 then
        record.digest = known_digest
        record.byte_size = known_size
    end
    return true
end

function RBX:_mark_compiled_scene_mesh_dependency_incomplete(reason)
    local state = self._compiled_scene_analysis_state
    if type(state) ~= "table" or state.active ~= true then return false end
    state.incomplete = true
    state.incomplete_reason = reason or "mesh_dependency_incomplete"
    return true
end

function RBX:_try_restore_compiled_scene_analysis()
    local state = self._compiled_scene_analysis_state
    if type(state) ~= "table" or state.active ~= true then return false end
    local started = love.timer.getTime()
    local cached_context, context_info = Cache.load_context(state.cache_name)
    if not cached_context then
        state.miss_reason = context_info or "cache_miss"
        return false
    end
    local source = cached_context.source or {}
    local expected_source = state.source or {}
    if source.hash_algorithm ~= (expected_source.hash_algorithm or "md5")
        or source.hash ~= expected_source.hash
        or source.byte_size ~= expected_source.byte_size
        or cached_context.parse_cache_format_version
            ~= (expected_source.parse_cache_format_version
                or MapCache.FORMAT_VERSION) then
        state.miss_reason = "stale_source"
        return false
    end
    local dependencies, dependency_error =
        verify_cached_dependencies(cached_context)
    if not dependencies then
        state.miss_reason = dependency_error
        return false
    end
    local expected_context, context_error =
        build_context(self, state.source, dependencies)
    if not expected_context then
        state.miss_reason = context_error
        return false
    end
    local payload, load_info = Cache.load(
        state.cache_name, expected_context)
    if not payload then
        state.miss_reason = load_info or "cache_load_failed"
        return false
    end
    local load_ms = (love.timer.getTime() - started) * 1000
    local applied, apply_error = apply_payload(self, payload, load_ms)
    if not applied then
        state.miss_reason = apply_error
        return false
    end
    state.restored = true
    state.load_info = load_info
    state.load_ms = load_ms
    state.dependency_count = #dependencies
    self._compiled_scene_analysis_pending = true
    self._compiled_scene_analysis_stats = {
        hit = true,
        cache_name = state.cache_name,
        dependency_count = #dependencies,
        load_ms = load_ms,
        payload_bytes = load_info.payload_bytes or 0,
        file_bytes = load_info.file_bytes or 0,
    }
    self:_add_load_stage_time(
        "compiled_scene_analysis_load", load_ms / 1000)
    return true
end

function RBX:_consume_compiled_scene_analysis()
    if self._compiled_scene_analysis_pending ~= true then return false end
    self._compiled_scene_analysis_pending = nil
    return true
end

local function build_tracked_dependencies(state)
    if state.incomplete then
        return nil, state.incomplete_reason or "dependency_tracking_incomplete"
    end
    local result = {}
    local total_bytes = 0
    table.sort(state.dependency_order)
    for index = 1, #state.dependency_order do
        local key = state.dependency_order[index]
        local tracked = state.dependencies[key]
        local dependency
        if tracked.digest and tracked.byte_size then
            dependency = {
                key = key,
                kind = "local-mesh",
                status = "ready",
                digest_algorithm = "sha256",
                digest = tracked.digest,
                byte_size = tracked.byte_size,
                remote = false,
            }
        else
            local dependency_error
            dependency, dependency_error =
                read_dependency(tracked.path)
            if not dependency then return nil, dependency_error end
        end
        total_bytes = total_bytes + dependency.byte_size
        if total_bytes > MAX_TOTAL_DEPENDENCY_BYTES then
            return nil, "dependency_total_cap_exceeded"
        end
        result[#result + 1] = dependency
    end
    return result
end

local function build_analysis_payload(renderer)
    local keys, _, key_error = current_part_lookup(renderer)
    if not keys then return nil, key_error end
    local count = #keys
    local bounds_values = ffi.new("double[?]", math.max(1, count * 6))
    local ao_values = ffi.new("double[?]", math.max(1, count * 4))
    local excluded = {}
    for index = 1, count do
        local part = renderer.parts[index]
        if rawget(part, "_remote_mesh_handle") ~= nil then
            return nil, "remote_mesh_dependency"
        end
        local bounds = part._rb_cache
            or renderer:_get_part_render_bounds(part)
        if type(bounds) ~= "table" then
            return nil, "part_bounds_missing:" .. keys[index]
        end
        local bounds_offset = (index - 1) * 6
        local values = {
            bounds.min_x, bounds.min_y, bounds.min_z,
            bounds.max_x, bounds.max_y, bounds.max_z,
        }
        for component = 1, 6 do
            local value = tonumber(values[component])
            if not finite_number(value) then
                return nil, "part_bounds_nonfinite:" .. keys[index]
            end
            bounds_values[bounds_offset + component - 1] = value
        end
        local ao_offset = (index - 1) * 4
        ao_values[ao_offset] = math.max(0, math.min(1,
            tonumber(part._contact_ao_top) or 0))
        ao_values[ao_offset + 1] = math.max(0, math.min(1,
            tonumber(part._contact_ao_bottom) or 0))
        ao_values[ao_offset + 2] = math.max(0, math.min(1,
            tonumber(part._contact_ao_side) or 0))
        ao_values[ao_offset + 3] = math.max(0, math.min(1,
            tonumber(part._contact_ao_max) or 0))
        excluded[index] = {
            part_key = keys[index],
            reasons = { "unsupported" },
        }
    end
    local bounds_stream, bounds_error = Cache.make_stream(
        "f64le", 6, count,
        ffi.string(bounds_values, count * 6 * ffi.sizeof("double")))
    if not bounds_stream then return nil, bounds_error end
    local ao_stream, ao_error = Cache.make_stream(
        "f64le", 4, count,
        ffi.string(ao_values, count * 4 * ffi.sizeof("double")))
    if not ao_stream then return nil, ao_error end
    return {
        schema = Cache.PAYLOAD_SCHEMA,
        schema_version = Cache.PAYLOAD_SCHEMA_VERSION,
        source_part_count = count,
        included_part_keys = {},
        excluded_parts = excluded,
        rebuild_policy = {
            dynamic = "rebuild",
            transparent = "rebuild",
            surface_gui = "rebuild",
            billboard_gui = "rebuild",
            remote_pending = "rebuild",
            constraints = "rebuild",
        },
        render_bounds = { part_keys = keys, rows = bounds_stream },
        contact_ao = { part_keys = keys, rows = ao_stream },
        chunks = {},
        instanced_mesh_groups = {},
        stats = {
            analysis_mode = ANALYSIS_MODE,
            contact_stats = clone_scalar_stats(
                renderer._contact_separation_stats),
        },
    }
end

function RBX:_save_compiled_scene_analysis()
    local state = self._compiled_scene_analysis_state
    if type(state) ~= "table" or state.active ~= true
        or state.restored == true then
        return false
    end
    local started = love.timer.getTime()
    local dependencies, dependency_error =
        build_tracked_dependencies(state)
    if not dependencies then
        state.save_error = dependency_error
        return false
    end
    local context, context_error =
        build_context(self, state.source, dependencies)
    if not context then
        state.save_error = context_error
        return false
    end
    local payload, payload_error = build_analysis_payload(self)
    if not payload then
        state.save_error = payload_error
        return false
    end
    local saved, save_info = Cache.save(
        state.cache_name, payload, context)
    local save_ms = (love.timer.getTime() - started) * 1000
    if not saved then
        state.save_error = save_info
        self._compiled_scene_analysis_stats = {
            hit = false,
            saved = false,
            cache_name = state.cache_name,
            error = tostring(save_info),
            save_ms = save_ms,
        }
        return false
    end
    state.saved = true
    state.save_info = save_info
    state.save_ms = save_ms
    self._compiled_scene_analysis_stats = {
        hit = false,
        saved = true,
        cache_name = state.cache_name,
        dependency_count = #dependencies,
        save_ms = save_ms,
        payload_bytes = save_info.payload_bytes or 0,
        file_bytes = save_info.file_bytes or 0,
    }
    self:_add_load_stage_time(
        "compiled_scene_analysis_save", save_ms / 1000)
    return true
end

RBX._compiled_scene_analysis_mode = ANALYSIS_MODE
RBX._compiled_scene_analysis_part_key = part_cache_key
RBX._compiled_scene_analysis_build_context = build_context

return true
