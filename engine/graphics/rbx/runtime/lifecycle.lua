-- Deterministic renderer and map-resource lifecycle
--
-- LÖVE eventually releases unreachable GPU objects, but relying on a later GC
-- makes map reloads and renderer replacement retain large VRAM generations
-- this module is loaded last so every runtime subsystem can call the methods it
-- installs without creating module-order dependencies

local MAP_RESOURCE_FIELDS = {
    "_scene_chunks",
    "_scene_static_chunks",
    "_scene_dynamic_chunks",
    "_dormant_dynamic_scene_chunk_map",
    "_scene_dynamic_chunks_drawn",
    "_settled_merge_chunk",
    "_settled_merge_pending",
    "_opaque_static_draw_items",
    "_mega_static_draw_items",
    "_textured_batches",
    "_mega_textured_batches",
    "_mega_overlay_textured_batches",
    "_transparent_draw_items",
    "_transparent_textured_range_groups",
    "_instanced_mesh_groups",
    "_directional_shadow_commands",
    "_directional_shadow_static_commands",
    "_directional_shadow_owned_resources",
    "_directional_shadow_array_cache",
    "_static_local_light_clusters",
    "_surface_gui_entries",
    "_visible_surface_gui_batches",
    "_billboard_entries",
    "_billboard_draw_items",
    "_sprite_billboard_draw_items",
    "_sprite_batches",
    "_screen_guis",
    "_mesh_texture_atlas",
    "_mesh_atlas",
    "_mesh_atlas_pages",
    "_surface_detail_geometry_cache",
    "_mega_cube_batch",
    "_mega_dynamic_cube_batch",
    "_mega_instance_mesh",
    "_mega_cube_draw_mesh",
    "_mega_dynamic_instance_mesh",
    "_mega_dynamic_cube_draw_mesh",
    "_instance_mesh",
    "_instance_draw_mesh",
    "_static_mesh",
    "_constraint_visual_mesh",
    "_constraint_visual_state",
    "_world_mesh_items",
    "_world_mesh_draw_items",
    "_world_mesh_list_state",
}

local RENDERER_RESOURCE_FIELDS = {
    "_cube_mesh",
    "_white_texture",
    "_black_texture",
    "_transparent_texture",
    "_flat_normal_texture",
    "_roughness_half_texture",
    "_instanced_shader",
    "_static_shader",
    "_atmosphere_receiver_shader_fields",
    "_atmosphere_receiver_sources",
    "_atmosphere_full_receiver_programs",
    "_atmosphere_no_receiver_programs",
    "_world_mesh_shader",
    "_world_mesh_lit_shader",
    "_textured_shader",
    "_fast_textured_shader",
    "_opaque_fast_textured_shader",
    "_alpha_fast_textured_shader",
    "_surface_overlay_fast_textured_shader",
    "_overlay_textured_shader",
    "_face_array_overlay_shader",
    "_constant_textured_shader",
    "_instanced_depth_shader",
    "_static_depth_shader",
    "_textured_depth_shader",
    "_instanced_mesh_fast_shader",
    "_instanced_mesh_depth_shader",
    "_instanced_mesh_material_shader",
    "_instanced_mesh_shared_pose_fast_shader",
    "_instanced_mesh_shared_pose_depth_shader",
    "_directional_shadow_static_shader",
    "_directional_shadow_instanced_shader",
    "_directional_shadow_textured_shader",
    "_directional_shadow_array_shader",
    "_directional_shadow_instanced_mesh_shader",
    "_directional_shadow_shared_pose_instanced_mesh_shader",
    "_directional_shadow_atlas",
    "_directional_shadow_depth",
    "_sky_shader",
    "_sky_celestial_shader",
    "_sky_starfield_shader",
    "_sky_meshes",
    "_sky_textures",
    "_sky_default_sun_texture",
    "_sky_default_moon_texture",
    "_sky_celestial_quad_mesh",
    "_sky_starfield_mesh",
    "_sky_starfield_texture",
    "_sky_atlas",
    "_sky_atlas_texture",
    "_sky_atlas_mesh",
    "_sprite_premultiply_shader",
    "_sprite_sheets",
    "_gui_placeholder_texture",
    "_render_canvas",
    "_render_depth_canvas",
    "_dbg_static_overlay",
    "_debug_wire_mesh",
    "_debug_wire_shader",
    "_last_canvas",
    "_last_fullscreen_canvas",
    "_last_render_to_canvas",
    "_texture_cache",
    "_face_texture_array_sets",
    "_material_cache",
    "_mesh_cache",
    "_remote_mesh_asset_cache",
    "_local_light_uniform_packet_scratch",
}

-- these renderer-lifetime caches contain only decoded Lua tables or raw source
-- strings. Walking every numeric vertex stream merely to discover that there
-- are no LÖVE resources dominated large-map teardown. they are still walked
-- by terminal Destroy through RENDERER_RESOURCE_FIELDS, map replacement only
-- needs to protect actual renderer-lifetime native resources
local MAP_PROTECT_SKIP_FIELDS = {
    _mesh_cache = true,
    _remote_mesh_asset_cache = true,
}

local SKIP_TREE_KEYS = {
    _shadow_array_sources = true, -- non-owning geometry/texture identity snapshots
    _core = true,
    _renderer = true,
    -- UI bridge nodes point back to their renderer for event/property routing
    -- this is a non-owning edge. Following it while retiring one map generation
    -- reaches load-scoped worker channels and renderer-lifetime GPU resources
    _rbx_renderer = true,
    -- GUI elements belong to the UI layer. their images and fonts come from
    -- engine-wide caches shared by every renderer (the image placeholder,
    -- loaded fonts), so a renderer's teardown must not release them. a
    -- ScreenGui reaches its element tree through _gui_element
    _gui_element = true,
    _bridge_root = true,
    _bridge_element = true,
    _datamodel = true,
    _parent = true,
    _children = true,
    Parent = true,
    Children = true,
    part = true,
    source_part = true,
    source_part_ref = true,
    dynamic_part = true,
    -- non-owning eligibility identities, scene collections own these parts and
    -- their resources. Command retirement must not traverse the referenced world
    eligibility_dynamic_owners = true,
    shadow_source_group = true, -- non-owning imported shadow descriptor edge
    surface_gui_ref = true,
    surface_gui_part_ref = true,
    instance = true,
    backend = true,
    menori = true,
}

-- map draw packets retain large CPU mirrors so runtime mutations can update
-- their GPU buffers without rebuilding the entire scene.  these branches are
-- plain Lua numbers/strings and cannot own a LÖVE graphics resource. the one
-- exception, cpu_vertices.vdata, is inspected directly without scanning its
-- numeric mirror
-- Skipping them here keeps map replacement proportional to the number of GPU
-- objects rather than to the number of vertices and instances.  this table is
-- intentionally used only for map-generation release, terminal Destroy still
-- performs the exhaustive renderer-cache walk above
local MAP_RESOURCE_TREE_SKIP_KEYS = {
    base_vertices = true,
    source_vertices = true,
    vertices = true,
    indices = true,
    positions = true,
    normals = true,
    uvs = true,
    colors = true,
    tangents = true,
    bone_indices = true,
    weights = true,
    cpu_vertices = true,
    rows = true,
    instance_rows = true,
    instance_bounds = true,
    cube_instances = true,
    opaque_static_shape_instances = true,
    transparent_static_shape_instances = true,
    transparent_static_shape_groups = true,
    cube_instance_part_ids = true,
    opaque_static_shape_instance_part_ids = true,
    source_transparent_part_ids = true,
    source_glass_part_ids = true,
    part_ranges = true,
    occluder_candidates = true,
    mesh_data = true,
    bounds = true,
    local_bounds = true,

    -- the wrapped descriptor and Menori GUI bridge are non-owning CPU graphs
    -- SurfaceGui-owned canvases remain reachable through _runtime_state, while
    -- bridge images come from the renderer texture cache and are protected by
    -- RENDERER_RESOURCE_FIELDS
    _surface_gui_data = true,
    _bridge_root = true,
    _bridge_element = true,
    _surface_gui_owner = true,
    _rbx_gui_owner = true,
    _rbx_node = true,
    content_signature_nodes = true,

    -- Async asset handles are renderer-lifetime acquisition state. draw
    -- packets only borrow them so publication can rebind a texture in place;
    -- their manager/source/binding graphs are not part of scene GPU ownership
    remote_texture_handle = true,
    remote_normal_texture_handle = true,
    remote_metalness_texture_handle = true,
    remote_roughness_texture_handle = true,
}

local function releasable(value)
    if type(value) ~= "userdata" then
        return false
    end
    local ok, release = pcall(function()
        return value.release
    end)
    return ok and type(release) == "function"
end

local function resource_is_released(resource)
    local ok, is_released = pcall(function()
        return resource.isReleased
    end)
    if not ok or type(is_released) ~= "function" then
        return false
    end
    local state_ok, state = pcall(is_released, resource)
    return state_ok and state == true
end

local function collect_resource_tree(
    value, resources, seen_tables, protected, depth, extra_skip_keys)
    if releasable(value) then
        if not protected[value] then
            resources[value] = true
        end
        return
    end
    if type(value) ~= "table" or seen_tables[value] or depth > 12 then
        return
    end
    seen_tables[value] = true
    for key, child in pairs(value) do
        local extra_skipped = extra_skip_keys and extra_skip_keys[key]
        if key == "cpu_vertices" and extra_skipped
            and type(child) == "table" then
            -- Dynamic textured packets can keep a ByteData mirror under
            -- cpu_vertices.vdata. do not scan the numeric mirror, but retain
            -- deterministic release of that native allocation
            collect_resource_tree(
                rawget(child, "vdata"), resources, seen_tables, protected,
                depth + 1, extra_skip_keys)
        elseif not SKIP_TREE_KEYS[key]
            and not extra_skipped
            and type(child) ~= "function" then
            collect_resource_tree(
                child, resources, seen_tables, protected, depth + 1,
                extra_skip_keys)
        end
    end
end

local function resource_priority(resource)
    local function is_type(name)
        local ok, result = pcall(resource.typeOf, resource, name)
        return ok and result == true
    end
    if is_type("Mesh") or is_type("SpriteBatch") then
        return 1
    end
    if is_type("Canvas") then
        return 2
    end
    if is_type("Image") or is_type("Texture") then
        return 3
    end
    if is_type("Shader") then
        return 4
    end
    return 5
end

local function release_resources(resources)
    local ordered = {}
    for resource in pairs(resources) do
        ordered[#ordered + 1] = resource
    end
    table.sort(ordered, function(a, b)
        local a_priority = resource_priority(a)
        local b_priority = resource_priority(b)
        if a_priority ~= b_priority then
            return a_priority < b_priority
        end
        return tostring(a) < tostring(b)
    end)

    local released = 0
    local errors = 0
    for index = 1, #ordered do
        local resource = ordered[index]
        if not resource_is_released(resource) then
            local ok, did_release = pcall(resource.release, resource)
            if ok and did_release ~= false then
                released = released + 1
            elseif not ok then
                errors = errors + 1
            end
        end
    end
    return released, errors
end

local function collect_fields(
    renderer, fields, resources, protected, extra_skip_keys)
    local seen_tables = {}
    for index = 1, #fields do
        collect_resource_tree(
            rawget(renderer, fields[index]), resources, seen_tables, protected,
            0, extra_skip_keys)
    end
end

local function protect_fields(renderer, fields, protected, skip_fields)
    local ignored = {}
    local seen_tables = {}
    for index = 1, #fields do
        local field = fields[index]
        if not (skip_fields and skip_fields[field]) then
            collect_resource_tree(
                rawget(renderer, field), ignored, seen_tables, {}, 0, nil)
        end
    end
    for resource in pairs(ignored) do
        protected[resource] = true
    end
end

local function protect_backend_resources(renderer, protected)
    local backend = rawget(renderer, "_render_backend")
    local batches = backend and rawget(backend, "_batches") or nil
    if type(batches) ~= "table" then
        return
    end
    for batch in pairs(batches) do
        local draw_mesh = type(batch) == "table" and rawget(batch, "draw_mesh") or nil
        local instance_mesh = type(batch) == "table" and rawget(batch, "instance_mesh") or nil
        if releasable(draw_mesh) then
            protected[draw_mesh] = true
        end
        if releasable(instance_mesh) then
            protected[instance_mesh] = true
        end
    end
end

function RBX:_release_scene_gpu_resources()
    local effects = self._world_mesh_items
    if effects then for i=#effects,1,-1 do effects[i]:destroy() end end
    self._debug_wire = nil -- scalar snapshots belong to the current map, never retained handles
    local phase_started = love.timer.getTime()
    if self._invalidate_scene_frame_packet_state then
        self:_invalidate_scene_frame_packet_state()
    end
    if self._release_transparent_textured_range_cpu_vertices then
        self:_release_transparent_textured_range_cpu_vertices()
    end
    local protected = {}
    -- map draw packets alias renderer-lifetime fallback textures and persistent
    -- asset-cache images. keep those alive across a map reload
    protect_fields(
        self, RENDERER_RESOURCE_FIELDS, protected, MAP_PROTECT_SKIP_FIELDS)
    protect_backend_resources(self, protected)
    if self._load_stage_times and self._add_load_stage_time then
        self:_add_load_stage_time(
            "runtime_reset_scene_protect", love.timer.getTime() - phase_started)
    end

    phase_started = love.timer.getTime()
    local resources = {}
    collect_fields(
        self, MAP_RESOURCE_FIELDS, resources, protected,
        MAP_RESOURCE_TREE_SKIP_KEYS)
    if self._load_stage_times and self._add_load_stage_time then
        self:_add_load_stage_time(
            "runtime_reset_scene_collect", love.timer.getTime() - phase_started)
    end

    phase_started = love.timer.getTime()
    local backend = self._render_backend
    if backend and backend.reset then
        local ok, reset_error = pcall(backend.reset, backend)
        if not ok and self._note_render_backend_error then
            self:_note_render_backend_error("release map generation", reset_error)
        end
    end
    if self._load_stage_times and self._add_load_stage_time then
        self:_add_load_stage_time(
            "runtime_reset_scene_backend", love.timer.getTime() - phase_started)
    end

    phase_started = love.timer.getTime()
    local released, errors = release_resources(resources)
    if self._sever_transparent_textured_range_groups then
        self:_sever_transparent_textured_range_groups()
    end
    self._lifecycle_map_release_count =
        (self._lifecycle_map_release_count or 0) + released
    self._lifecycle_release_error_count =
        (self._lifecycle_release_error_count or 0) + errors
    if self._load_stage_times and self._add_load_stage_time then
        self:_add_load_stage_time(
            "runtime_reset_scene_release_objects",
            love.timer.getTime() - phase_started)
    end

    for index = 1, #MAP_RESOURCE_FIELDS do
        self[MAP_RESOURCE_FIELDS[index]] = nil
    end
    self._mega_instance_count = 0
    self._mega_dynamic_instance_count = 0
    self._mega_dynamic_instance_capacity = 0
    self._directional_shadow_command_key = nil
    self._directional_shadow_atlas_key = nil
    self._directional_shadow_active = false
    self._directional_shadow_uniform_revision =
        (self._directional_shadow_uniform_revision or 0) + 1
    return released, errors
end

function RBX:_dispose_async_map_load_state(state)
    if type(state) ~= "table" then
        return false
    end
    state.build_checkpoint = nil
    state.initial_classify_timing = nil
    state.initial_promotion_timing = nil
    -- a real LOVE Thread cannot be killed. on cancellation wait for its
    -- bounded parse to finish, on normal completion this is already a no-op
    -- either way, release channel/native ownership deterministically instead
    -- of waiting for a later Lua/LOVE garbage collection cycle
    local thread = state.thread
    if thread and thread.wait then
        pcall(thread.wait, thread)
    end
    for _, field in ipairs({
        "request_channel", "response_channel", "progress_channel",
        "thread", "worker",
    }) do
        local object = state[field]
        if object and object.clear then
            pcall(object.clear, object)
        end
        if releasable(object) and not resource_is_released(object) then
            pcall(object.release, object)
        end
        state[field] = nil
    end
    return true
end

function RBX:_cancel_async_map_load()
    local state = self._async_map_load
    local collision_policy_owner = self._collision_group_load
    if type(state) == "table" and not self._tearing_down then
        collision_policy_owner = rawget(state, "collision_policy_owner")
    end
    local collision_policy_error
    if type(state) == "table" then
        state.initial_promotion_timing = nil
    end
    self._async_map_load = nil
    self._async_map_load_resuming = false
    self:_notify_async_map_ready()
    if self._clear_full_build_mesh_resolution_memo then
        self:_clear_full_build_mesh_resolution_memo(nil, "async_cancel")
    end
    if type(state) == "table" and state.apply_started == true
        and not self._tearing_down
        and self._recover_failed_map_apply then
        local recovered, reason = self:_recover_failed_map_apply(state.map_path, collision_policy_owner, true)
        if not recovered then collision_policy_error = "Map cancellation recovery failed: " .. tostring(reason) end
    elseif self._tearing_down and collision_policy_owner then
        local retired, reason = pcall(RBX._collision_group_policy.retire, self, collision_policy_owner)
        if not retired then collision_policy_error = "Policy teardown retirement failed: " .. tostring(reason) end
    elseif not (type(self._remote_mesh_full_build_seen) == "table"
            and self._remote_mesh_full_build_seen.recovery_failed == true) then
        self._remote_mesh_full_build_seen = nil
        self._map_load_preflight_local_light_count = nil
    end
    -- parse_on_main raises the same GC pause as application. Cancellation can
    -- abandon the coroutine before its normal epilogue, so always close the
    -- window even when no worker/thread object exists
    if self._end_load_gc_window then
        self:_end_load_gc_window()
    end
    -- parse-on-main installs this shared checkpoint callback while its
    -- coroutine is suspended. Abandoning the coroutine must not leak the
    -- renderer into later synchronous or asynchronous parses
    parse_progress_hook = nil
    local disposed, result = pcall(self._dispose_async_map_load_state, self, state)
    if not disposed then
        if collision_policy_error then result = collision_policy_error .. "; load disposal: " .. tostring(result) end
        error(result, 0)
    end
    if collision_policy_error then error(collision_policy_error, 0) end
    return result
end

local function restore_previous_active(renderer, datamodel)
    if RBX._active_datamodel ~= datamodel then
        return false
    end
    local candidate = rawget(renderer, "_previous_active_datamodel")
    local visited = {}
    local dead_chain = {}
    while type(candidate) == "table"
        and rawget(candidate, "_destroyed") == true do
        if visited[candidate] then
            candidate = nil
            break
        end
        visited[candidate] = true
        dead_chain[#dead_chain + 1] = candidate
        local core = rawget(candidate, "_core")
        candidate = rawget(candidate, "_previous_active_datamodel")
            or (core and rawget(core, "_previous_active_datamodel"))
    end
    RBX._active_datamodel = candidate
    -- the restored active game now owns the only link that matters. Sever the
    -- retired chain so externally retained destroyed facades cannot retain every
    -- older renderer indefinitely
    rawset(datamodel, "_previous_active_datamodel", nil)
    renderer._previous_active_datamodel = nil
    for index = 1, #dead_chain do
        local dead = dead_chain[index]
        local core = rawget(dead, "_core")
        rawset(dead, "_previous_active_datamodel", nil)
        if core then
            core._previous_active_datamodel = nil
        end
    end
    return true
end

function RBX:Destroy(datamodel)
    if self._destroyed then
        return false
    end
    self._tearing_down = true
    datamodel = datamodel or self._datamodel

    if self._clear_full_build_mesh_resolution_memo then
        self:_clear_full_build_mesh_resolution_memo(nil, "renderer_destroy")
    end

    self:_cancel_async_map_load()
    if self._stop_texture_prefetch then
        -- Teardown may interrupt the very first load, before self.map_path is
        -- committed. a partial manifest is neither useful nor safe to persist
        pcall(self._stop_texture_prefetch, self, self.map_path, false)
    end
    if self._stop_remote_mesh_assets then
        -- stop acquisition/decode workers before releasing scene/backend state;
        -- no late completion may retain or call into a destroyed renderer
        pcall(self._stop_remote_mesh_assets, self)
    end
    if self._stop_remote_texture_assets then
        -- Clears queued work before STOP tokens, waits for the bounded in-flight
        -- transfers, drains result channels, and releases worker/channel owners
        pcall(self._stop_remote_texture_assets, self)
    end

    self:_release_scene_gpu_resources()

    -- the frame-post owner contains resizable HDR/depth/bloom targets plus its
    -- programs. release it explicitly: traversing the owner table would also
    -- walk its reference to love.graphics, which is global rather than an RBX
    -- renderer resource tree
    if self._post_process and self._post_process.release then
        pcall(self._post_process.release, self._post_process)
    end
    self._post_process = nil

    local renderer_resources = {}
    collect_fields(self, RENDERER_RESOURCE_FIELDS, renderer_resources, {})
    local released, errors = release_resources(renderer_resources)
    self._lifecycle_renderer_release_count = released
    self._lifecycle_release_error_count =
        (self._lifecycle_release_error_count or 0) + errors
    for index = 1, #RENDERER_RESOURCE_FIELDS do
        self[RENDERER_RESOURCE_FIELDS[index]] = nil
    end
    -- these tables use shader objects as keys.  Renderer teardown releases
    -- every shader above, so sever the keys at the same ownership boundary
    self._local_light_uniform_support = {}
    self._local_light_uniform_state = {}
    self._local_light_uniform_uploaded_counts = {}
    self._local_light_uniform_packet_shader_support = {}
    self._local_light_uniform_packet_available = false
    self._local_light_uniform_packet_last_shader_error = nil
    self._directional_shadow_uniform_send_state = {}
    self._common_camera_uniform_send_state = {}
    self._common_lighting_uniform_send_state = {}
    self._depth_common_uniform_send_state = {}
    self._lighting_debug_uniform_send_state = {}

    local backend = self._render_backend
    if backend and backend.release then
        pcall(backend.release, backend)
    end
    self._render_backend = nil

    restore_previous_active(self, datamodel)
    if datamodel and rawget(datamodel, "_core") == self then
        rawset(datamodel, "_core", nil)
    end
    self._datamodel = nil
    -- Sever per-part lifetime owners before dropping the renderer's primary
    -- array. External Instance/facade references may outlive the renderer, an
    -- intrusive creation-order edge on one such part must not retain every
    -- other runtime-created part or its decoded LOD graph
    local live_parts = self.parts or {}
    for index = 1, #live_parts do
        local part = live_parts[index]
        if type(part) == "table" then
            if self._release_part_embedded_mesh_cache then
                self:_release_part_embedded_mesh_cache(part)
            end
            part._runtime_part_order_prev = nil
            part._runtime_part_order_next = nil
            part._runtime_part_slot = nil
            part._mesh_lod_base_mesh = nil
            part._mesh_lod_count = nil
            part._mesh_lod_index = nil
            part._mesh_lod_fidelity = nil
            -- the manager has already stopped and released its results above;
            -- do not leave externally retained facades pointing at a terminal
            -- variant handle from the destroyed renderer
            rawset(part, "_remote_mesh_handle", nil)
            rawset(part, "_remote_mesh_variant_key", nil)
        end
    end
    if self._clear_embedded_mesh_content_cache then
        self:_clear_embedded_mesh_content_cache()
    end
    self.parts = {}
    -- Runtime-created parts are linked for creation-order explorer semantics in
    -- addition to living in the dense `parts` suffix.  a retained destroyed
    -- renderer must not keep that intrusive chain (and therefore every former
    -- runtime part) alive after the primary array is cleared
    self._loaded_part_count = 0
    self._runtime_part_order_head = nil
    self._runtime_part_order_tail = nil
    self._runtime_live_part_count = 0
    self._runtime_part_storage_initialized = true
    self.constraints = {}
    self._scene_chunks = {}
    self._scene_chunk_map = {}
    self._scene_static_chunks = {}
    self._scene_dynamic_chunks = {}
    self._dormant_dynamic_scene_chunk_map = nil
    self._debug_wire = nil
    self._physics_world = nil
    self._physics_dynamic_parts = {}
    self._physics_assemblies = {}
    self._physics_constraints = {}
    self._physics_movers = {}
    self._destroyed = true
    self._tearing_down = false
    return true
end

return {
    map_resource_fields = MAP_RESOURCE_FIELDS,
    renderer_resource_fields = RENDERER_RESOURCE_FIELDS,
}
