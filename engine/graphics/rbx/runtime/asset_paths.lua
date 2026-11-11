-- pure path policy shared by renderer lookups and remote mesh workers
-- a place owns its downloaded copies, including when two places share an ID
-- Lookups stay inside the place's sidecar directory and the project's
-- configured asset root, nothing outside them is searched
local AssetPaths = {}

local function normalize(value)
    return type(value) == "string"
        and value:match("^%s*(.-)%s*$"):gsub("\\", "/") or ""
end

function AssetPaths.map_directory(map_path)
    map_path = normalize(map_path)
    return map_path ~= "" and (map_path .. ".assets") or ""
end

function AssetPaths.context_key(map_path, asset_root)
    return AssetPaths.map_directory(map_path) .. "\0" .. normalize(asset_root)
end

function AssetPaths.candidates(reference, asset_type, options)
    options = options or {}
    reference = normalize(reference)
    local root = normalize(options.asset_root)
    local folders = options.asset_folders or {}
    local scoped = AssetPaths.map_directory(options.map_path)
    local candidates, seen = {}, {}
    local function add(path)
        path = normalize(path)
        if path ~= "" and not seen[path] then
            seen[path] = true
            candidates[#candidates + 1] = path
        end
    end
    local function folder(name)
        if folders[name] then return folders[name] end
        if root ~= "" then return root .. "/" .. name end
        return nil
    end
    local function add_in(directory, relative)
        if directory then add(directory .. "/" .. relative) end
    end
    local lower = reference:lower()
    local id = options.asset_id or reference:match("^%d+$")
        or lower:match("^rbxassetid:/+(%d+)")
        or lower:match("[?&]id=(%d+)")
        or lower:match("[?&]assetid=(%d+)")
        or lower:match("/asset/(%d+)")
    if id then
        -- Scraped filenames use decimal IDs without leading zeroes. keep
        -- IDs as strings so 64-bit identifiers never pass through a float
        id = tostring(id):gsub("^0+", "")
        if id == "" then id = "0" end
        local extensions
        if asset_type == "csg_mesh" then
            extensions = { ".meshdata", ".mesh", ".rbxm", ".rbxmx", ".rbxl", ".rbxlx", ".xml", ".bin", "" }
        elseif asset_type == "mesh" then
            extensions = { ".mesh", ".meshdata", ".rbxm", ".rbxmx", ".xml", ".bin", "" }
        elseif asset_type == "font" then
            extensions = { ".ttf", ".otf", ".ttc" }
        elseif asset_type == "sound" then
            extensions = { ".ogg", ".mp3", ".wav" }
        else
            extensions = { ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".gif", ".dds", ".webp" }
            local extension = reference:match("(%.[%w]+)$")
            if extension and extension:lower() ~= ".mesh" then
                table.insert(extensions, 1, extension)
            end
        end
        local roots = {}
        if scoped ~= "" then roots[#roots + 1] = scoped .. "/asset" end
        roots[#roots + 1] = folder("asset")
        if root ~= "" then roots[#roots + 1] = root .. "/builtin/asset" end
        for _, directory in ipairs(roots) do
            for _, extension in ipairs(extensions) do
                add(directory .. "/" .. id .. extension)
            end
        end
    end

    local relative = reference:match("^[Rr][Bb][Xx][Aa][Ss][Ss][Ee][Tt]://(.*)$")
        or reference:match("^[Rr][Bb][Xx][Gg][Aa][Mm][Ee][Aa][Ss][Ss][Ee][Tt]://(.*)$")
    if relative then
        relative = relative:gsub("^/+", "")
        local name, suffix = relative:match("^([^/]+)/(.*)$")
        local known_folder = name
            and ({ asset = true, textures = true, sky = true, icons = true, sounds = true, fonts = true })[name:lower()]
        local canonical_relative = known_folder and (name:lower() .. "/" .. suffix) or relative
        if scoped ~= "" then
            add(scoped .. "/" .. relative)
            -- preserve authored casing first, while shared directory names
            -- remain portable to case-sensitive filesystems
            add(scoped .. "/" .. canonical_relative)
            for _, folder_name in ipairs({ "asset", "textures", "sky" }) do
                add(scoped .. "/" .. folder_name .. "/" .. relative)
            end
        end
        if known_folder then
            add_in(folder(name:lower()), suffix)
        else
            for _, fallback in ipairs({ "textures", "sky", "asset" }) do
                add_in(folder(fallback), relative)
            end
        end
        if root ~= "" then
            add(root .. "/builtin/" .. relative)
            add(root .. "/builtin/" .. canonical_relative)
            add(root .. "/" .. relative)
            add(root .. "/" .. canonical_relative)
        end
    elseif not lower:match("^[%w+.-]+://") then
        relative = reference:gsub("^%./", ""):gsub("^/+", "")
        add(reference)
        add(relative)
        if scoped ~= "" then
            add(scoped .. "/" .. relative)
            add(scoped .. "/asset/" .. relative)
            local parent = normalize(options.map_path):match("^(.*)/[^/]+$")
            if parent then add(parent .. "/" .. relative) end
        end
        add_in(folder("asset"), relative)
        if root ~= "" then
            add(root .. "/" .. relative)
            add(root .. "/builtin/" .. relative)
        end
    end
    return candidates
end

return AssetPaths
