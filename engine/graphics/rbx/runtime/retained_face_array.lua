-- bounded opt-in face-array sampler for a fixed local Decal set
--
-- it intentionally owns no geometry and never replaces a normal FaceInstance
-- path on uncertainty. the caller keeps the ordinary sampler/mesh fallback for
-- remote, unknown, altered or unsupported descriptors
local M = {}

local function release(resource)
    if resource and type(resource.release) == "function" then
        pcall(resource.release, resource)
    end
end

local function resource_alive(resource)
    if resource == nil then return false end
    if type(resource.isReleased) ~= "function" then return true end
    local ok, released = pcall(resource.isReleased, resource)
    return ok and released ~= true
end

local function asset_key(core, value)
    if type(value) ~= "string" or value == "" then return nil end
    if type(core._renderer_asset_cache_key) == "function" then
        local ok, key = pcall(core._renderer_asset_cache_key,
            core, value, "texture")
        if ok and type(key) == "string" then return key end
    end
    return value
end

local function matches_name(actual, expected)
    return expected == nil or tostring(actual or "") == tostring(expected)
end

-- this representation is deliberately narrower than generic Decal support
-- its typical consumer is an authored character head: a front-facing,
-- untinted, unrotated, unscaled Decal with the normal Decal z-order.  a change
-- to any appearance/projection lane still receives the ordinary owner rebuild;
-- keep it there until every lane has returned to this exact source contract
local function is_default_public_head_decal(part, descriptor)
    local class_name = part.class_name or part.ClassName
    if class_name ~= "MeshPart" then return false end
    local color = descriptor.color
    return descriptor.face == "Front"
        and descriptor.transparency == 0
        and type(color) == "table"
        and (color[1] or color.r or color.R) == 1
        and (color[2] or color.g or color.G) == 1
        and (color[3] or color.b or color.B) == 1
        and descriptor.zindex == 1
        and descriptor.rotation == 0
        and descriptor.uv_offset_u == 0
        and descriptor.uv_offset_v == 0
        and descriptor.uv_scale_u == 1
        and descriptor.uv_scale_v == 1
        and descriptor.studs_per_tile_u == nil
        and descriptor.studs_per_tile_v == nil
        and descriptor.offset_studs_u == 0
        and descriptor.offset_studs_v == 0
end

local function locate_config(core, part, descriptor)
    if core.retain_face_texture_array ~= true
        or type(part) ~= "table" or type(descriptor) ~= "table"
        or descriptor.class_name ~= "Decal"
        or descriptor.texture_object ~= nil
        or not is_default_public_head_decal(part, descriptor) then
        return nil
    end
    local sets = core.face_texture_array_sets
    if type(sets) ~= "table" then return nil end
    local texture_key = asset_key(core, descriptor.texture)
    if not texture_key then return nil end
    for index = 1, #sets do
        local config = sets[index]
        if type(config) == "table"
            and matches_name(part.Name, config.part_name)
            and matches_name(descriptor.name, config.descriptor_name)
            and type(config.assets) == "table" then
            local layers = config._face_array_layers
            if type(layers) ~= "table" then
                layers = {}
                local valid = true
                for layer, reference in ipairs(config.assets) do
                    local key = asset_key(core, reference)
                    if key == nil or layers[key] ~= nil then
                        valid = false
                        break
                    end
                    layers[key] = layer - 1
                end
                if valid then
                    config._face_array_layers = layers
                else
                    config._face_array_layers = false
                    layers = false
                end
            end
            if layers and layers[texture_key] ~= nil then
                return config, layers[texture_key], texture_key
            end
        end
    end
    return nil
end

local function registry(core)
    local value = rawget(core, "_face_texture_array_sets")
    if type(value) ~= "table" then
        value = {}
        core._face_texture_array_sets = value
    end
    return value
end

local function source_options()
    return {
        wrap_mode = "clamp",
        alpha_bleed = true,
        mipmaps = true,
        remote_pending_placeholder = "transparent",
    }
end

local function build_set(core, config, set_key)
    local images, temporary = {}, {}
    local array
    local started = love.timer.getTime()
    local ok, result = xpcall(function()
        local first_meta
        for index, reference in ipairs(config.assets) do
            local image, _, remote_handle = core:_get_or_load_texture(
                reference, source_options())
            if remote_handle ~= nil or image == nil then
                error("face-array source is remote or unavailable")
            end
            local metadata = core._texture_sampler_debug_by_texture
                and core._texture_sampler_debug_by_texture[image] or nil
            if type(metadata) ~= "table"
                or type(metadata.resolved) ~= "string"
                or metadata.resolved == ""
                or metadata.wrap_mode ~= "clamp"
                or metadata.color_space ~= "srgb_color"
                or metadata.alpha_bleed ~= true
                or metadata.mipmaps ~= true then
                error("face-array source sampler mismatch")
            end
            local data = assert(love.image.newImageData(metadata.resolved))
            temporary[#temporary + 1] = data
            if data:getFormat() ~= "rgba8" then
                error("face-array source format is not rgba8")
            end
            assert(type(core._bleed_image_data_alpha) == "function",
                "face-array alpha bleed helper unavailable")
            core._bleed_image_data_alpha(data)
            if first_meta == nil then
                first_meta = metadata
            elseif data:getWidth() ~= images[1]:getWidth()
                or data:getHeight() ~= images[1]:getHeight()
                or metadata.wrap_mode ~= first_meta.wrap_mode
                or metadata.min_filter ~= first_meta.min_filter
                or metadata.mag_filter ~= first_meta.mag_filter
                or metadata.mipmap_filter ~= first_meta.mipmap_filter
                or metadata.anisotropy ~= first_meta.anisotropy
                or metadata.color_space ~= first_meta.color_space
                or metadata.alpha_bleed ~= first_meta.alpha_bleed
                or metadata.mipmaps ~= first_meta.mipmaps then
                error("face-array source dimensions or sampler differ")
            end
            images[index] = data
        end
        if #images < 1 or not love.graphics.getTextureTypes().array then
            error("ArrayImage unavailable")
        end
        array = assert(love.graphics.newArrayImage(images, {
            mipmaps = true,
            linear = false,
        }))
        array:setFilter(first_meta.min_filter, first_meta.mag_filter,
            first_meta.anisotropy)
        array:setWrap("clamp", "clamp")
        if array.setMipmapFilter then
            if first_meta.mipmap_filter == "none" then
                array:setMipmapFilter(nil)
            else
                array:setMipmapFilter(first_meta.mipmap_filter,
                    tonumber(core.texture_mipmap_sharpness) or 0)
            end
        end
        local width, height = images[1]:getDimensions()
        return {
            config = config,
            key = set_key,
            texture = array,
            layers = config._face_array_layers,
            width = width,
            height = height,
            layer_count = #images,
            bytes = width * height * 4 * #images * (4 / 3),
            build_seconds = love.timer.getTime() - started,
        }
    end, debug.traceback)
    for index = 1, #temporary do release(temporary[index]) end
    if not ok then
        release(array)
        return nil, result
    end
    return result
end

function M.prepare(core, part, descriptor, face_count)
    if face_count ~= 1 or type(core) ~= "table" then return nil end
    local config, layer, texture_key = locate_config(core, part, descriptor)
    if not config then return nil end
    if type(core._ensure_face_array_overlay_shader) ~= "function"
        or not core:_ensure_face_array_overlay_shader() then
        return nil
    end
    local set_key = tostring(config.key or ("face-array-set-" .. texture_key))
    local sets = registry(core)
    local entry = sets[set_key]
    if entry and entry.config ~= config then
        release(entry.texture)
        entry = nil
        sets[set_key] = nil
    end
    if entry and entry.failed then return nil end
    if not entry or not resource_alive(entry.texture) then
        local built, build_error = build_set(core, config, set_key)
        if not built then
            sets[set_key] = { config = config, failed = true,
                error = tostring(build_error) }
            core._retained_face_array_build_failure_count =
                (core._retained_face_array_build_failure_count or 0) + 1
            core._retained_face_array_last_error = tostring(build_error)
            return nil
        end
        entry = built
        sets[set_key] = entry
        core._retained_face_array_build_count =
            (core._retained_face_array_build_count or 0) + 1
        core._retained_face_array_bytes =
            (core._retained_face_array_bytes or 0) + entry.bytes
        core._retained_face_array_build_seconds =
            (core._retained_face_array_build_seconds or 0)
                + entry.build_seconds
    end
    if entry.layers[texture_key] ~= layer then return nil end
    return {
        entry = entry,
        texture = entry.texture,
        layer = layer,
        key = entry.key,
    }
end

function M.update_layer(core, binding)
    if type(core) ~= "table" or type(binding) ~= "table" then
        return false
    end
    local item, descriptor, entry = binding.item, binding.descriptor,
        binding.entry
    if type(item) ~= "table" or type(descriptor) ~= "table"
        or type(entry) ~= "table" or not resource_alive(entry.texture)
        or item._face_array_binding_descriptor ~= descriptor
        or item.face_array_texture ~= entry.texture
        or item.remote_texture_handle ~= nil
        or item.remote_normal_texture_handle ~= nil
        or not item.mesh then
        return false
    end
    local config, layer = locate_config(core, binding.part, descriptor)
    if config ~= entry.config or layer == nil then return false end
    item.face_array_layer = layer
    core._retained_face_array_layer_update_count =
        (core._retained_face_array_layer_update_count or 0) + 1
    return true
end

return M
