-- the viewer and rbx.new share these defaults and option checks
local PublicOptions = {}

local PASSTHROUGH_OPTIONS = {
    map_path = true,
    fov_degrees = true,
    follow_display_settings = true,
    asset_root = true,
    virtual_resolution = true,
    letterbox_resolution = true,
    debug_deprecation_warnings = true,
    retain_mesh_transforms = true,
    no_atmosphere_receiver_variant = true,
    physics_budget_ms = true,
    dynamic_render_distance = true,
    dynamic_render_hysteresis = true,
    use_authored_gui_fonts = true,
    materials = true,
    material_roots = true,
}

local QUALITY_PRESETS = {
    performance = { msaa = 0, anisotropy = 1 },
    balanced = { msaa = 2, anisotropy = 2 },
    quality = { msaa = 4, anisotropy = 4 },
}

local RECOGNIZED_POLICY_OPTIONS = {
    experimental_rendering = true,
    quality = true,
    graphics_quality = true,
    allow_remote_assets = true,
    async_loading = true,
    simulate_physics = true,
    physics_rate = true,
    -- Undocumented migration aliases, retained for one cycle
    allow_remote_asset_fetch = true,
    allow_remote_mesh_fetch = true,
    async_map_load = true,
    physics_enabled = true,
    target_fps_mode = true,
    debug_api_warnings = true,
}

function PublicOptions.build(options, defaults)
    if options ~= nil and type(options) ~= "table" then
        return nil, "RBX options must be a table or nil"
    end
    options = options or {}
    defaults = defaults or {}
    if options.retain_mesh_transforms ~= nil and type(options.retain_mesh_transforms) ~= 'boolean' then
        return nil, 'retain_mesh_transforms must be boolean'
    end
    if options.no_atmosphere_receiver_variant ~= nil
        and type(options.no_atmosphere_receiver_variant) ~= "boolean" then
        return nil, "no_atmosphere_receiver_variant must be boolean"
    end
    if options.use_authored_gui_fonts ~= nil and type(options.use_authored_gui_fonts) ~= "boolean" then
        return nil, "use_authored_gui_fonts must be boolean"
    end

    local materials = options.materials
    if materials ~= nil then
        if type(materials) ~= "table" then return nil, "materials must be a table keyed by material name" end
        for name, entry in pairs(materials) do
            if type(name) ~= "string" then return nil, "materials keys must be material names" end
            local kind = type(entry)
            if kind ~= "string" and kind ~= "table" and entry ~= false then
                return nil, "materials." .. name .. " must be a directory, a table of map paths, or false"
            end
            if kind == "table" then
                for key, value in pairs(entry) do
                    if key == "tiling" or key == "studs_per_tile" then
                        if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
                            return nil, "materials." .. name .. "." .. key .. " must be a positive number"
                        end
                    elseif key == "color" or key == "normal" or key == "roughness" or key == "metalness" then
                        if type(value) ~= "string" or value == "" then
                            return nil, "materials." .. name .. "." .. key .. " must be a file path"
                        end
                    else
                        return nil, "materials." .. name .. " has unknown field '" .. tostring(key) .. "'"
                    end
                end
            end
        end
    end
    local material_roots = options.material_roots
    if material_roots ~= nil then
        if type(material_roots) ~= "table" then return nil, "material_roots must be an array of directories" end
        for index, root in ipairs(material_roots) do
            if type(root) ~= "string" or root == "" then
                return nil, "material_roots[" .. index .. "] must be a directory path"
            end
        end
    end
    local physics_rate = options.physics_rate
    if physics_rate ~= nil and (type(physics_rate) ~= "number" or physics_rate ~= physics_rate
        or physics_rate < 15 or physics_rate > 240) then
        return nil, "physics_rate must be a number of steps per second between 15 and 240"
    end

    local budget = options.physics_budget_ms
    if budget ~= nil and (type(budget) ~= "number" or budget ~= budget or budget < 0 or budget == math.huge) then
        return nil, "physics_budget_ms must be a finite nonnegative number (0 disables the CPU cutoff)"
    end
    for _, name in ipairs({"dynamic_render_distance", "dynamic_render_hysteresis"}) do
        local value = options[name]
        if value ~= nil and (type(value) ~= "number" or value ~= value or value < 0 or value == math.huge) then
            return nil, name .. " must be a finite nonnegative number"
        end
    end
    local copied = {}
    for key, value in pairs(options) do
        if PASSTHROUGH_OPTIONS[key] then
            copied[key] = value
        elseif not RECOGNIZED_POLICY_OPTIONS[key] then
            return nil, "Unknown public RBX option '" .. tostring(key) .. "'"
        end
    end

    local requested_quality = options.quality or options.graphics_quality
    if requested_quality == nil and options.target_fps_mode == true then
        requested_quality = "performance"
    end
    local quality = tostring(requested_quality or "balanced"):lower()
    local preset = QUALITY_PRESETS[quality]
    if not preset then
        return nil, "RBX quality must be 'performance', 'balanced', or 'quality'"
    end

    local experimental = options.experimental_rendering
    if experimental ~= nil then
        if experimental ~= "precision" and experimental ~= "precision-enumeration" then
            return nil, "experimental_rendering must be precision or precision-enumeration"
        end
        if quality ~= "balanced" then
            return nil, "experimental_rendering requires balanced quality (scene MSAA2)"
        end
        copied.experimental_shadow_enumeration = experimental == "precision-enumeration"
        copied._post_process_internal = {
            _force_scene_format = "rgba32f",
            _required_scene_format = "rgba32f",
            _required_samples = 2,
        }
    end

    -- Network fetching is opt-in: an offline scene never makes requests
    local remote_assets = options.allow_remote_assets
    if remote_assets == nil then remote_assets = options.allow_remote_asset_fetch end
    if remote_assets == nil then remote_assets = false end
    local remote_meshes = options.allow_remote_mesh_fetch
    if remote_meshes == nil then remote_meshes = remote_assets end

    local async_loading = options.async_loading
    if async_loading == nil then async_loading = options.async_map_load end
    if async_loading == nil then async_loading = true end
    local simulate_physics = options.simulate_physics
    if simulate_physics == nil then simulate_physics = options.physics_enabled end

    copied.render_backend = "menori"
    copied.async_map_load = async_loading ~= false
    copied.allow_remote_asset_fetch = remote_assets ~= false
    copied.allow_remote_mesh_fetch = remote_meshes ~= false
    copied.physics_enabled = simulate_physics == true
    if physics_rate then
        copied.physics_fixed_dt = 1 / physics_rate
        copied.physics_max_substep = 1 / physics_rate
    end
    copied.msaa = preset.msaa
    copied.texture_anisotropy = preset.anisotropy
    copied.texture_min_filter = "linear"
    copied.texture_mag_filter = "linear"
    copied.texture_mipmap_filter = "linear"
    copied.texture_filter_profile = quality
    -- full material semantics are a correctness baseline, not a quality knob
    copied.target_fps_mode = false
    copied.textured_shader_quality = "full"

    if copied.debug_deprecation_warnings == nil then
        copied.debug_deprecation_warnings = options.debug_api_warnings == true
            or defaults.debug_deprecation_warnings == true
    end
    return copied, nil
end

return PublicOptions
