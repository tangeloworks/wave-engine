-- look up project assets first, then try the shared engine roots
-- this also works before graphics starts

local Resolver = {}
Resolver.__index = Resolver

local function normalize(path, label)
    assert(type(path) == "string" and path ~= "", (label or "path") .. " must be a non-empty string")
    path = path:gsub("\\", "/"):gsub("/+", "/")
    path = path:gsub("^%./", "")
    assert(not path:match("^/") and not path:match("^%a:[/]"),
        (label or "path") .. " must be a LÖVE virtual filesystem path, not an absolute path")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "..", (label or "path") .. " must not escape an asset root")
    end
    return path
end

local function join(root, path)
    if not root or root == "" then return path end
    return root .. "/" .. path
end

local function append_unique(list, value)
    for _, current in ipairs(list) do
        if current == value then return end
    end
    list[#list + 1] = value
end

---create an ordered asset resolver
---@param options table|nil
---@field filesystem table|nil a filesystem with the same interface as `love.filesystem`
---@field project_root string|false|nil Optional project asset directory
---@field engine_root string|false|nil Optional framework asset directory
---@return WaveAssetResolver
function Resolver.new(options)
    options = options or {}
    local filesystem = options.filesystem or (love and love.filesystem)
    assert(filesystem and type(filesystem.getInfo) == "function" and type(filesystem.read) == "function",
        "wave asset resolver requires love.filesystem (or a compatible filesystem)")

    local self = setmetatable({
        filesystem = filesystem,
        roots = {},
    }, Resolver)

    if options.project_root and options.project_root ~= false then
        self:add_root("project", options.project_root)
    end
    if options.engine_root and options.engine_root ~= false then
        self:add_root("engine", options.engine_root)
    end
    assert(options.additional_roots == nil or type(options.additional_roots) == "table",
        "additional_roots must be an array of virtual filesystem paths")
    for _, root in ipairs(options.additional_roots or {}) do
        self:add_root("additional", root)
    end
    return self
end

---@param kind string
---@param root string|false|nil
---@param prepend boolean|nil
function Resolver:add_root(kind, root, prepend)
    if root == nil or root == false or root == "" then return self end
    root = normalize(root, "asset root"):gsub("/$", "")
    local entry = { kind = kind or "additional", path = root }
    for _, current in ipairs(self.roots) do
        if current.path == entry.path then return self end
    end
    if prepend then
        table.insert(self.roots, 1, entry)
    else
        self.roots[#self.roots + 1] = entry
    end
    return self
end

function Resolver:list_roots()
    local copy = {}
    for i, root in ipairs(self.roots) do
        copy[i] = { kind = root.kind, path = root.path }
    end
    return copy
end

function Resolver:attempts(path, options)
    options = options or {}
    path = normalize(path)
    local attempts = {}
    if options.explicit ~= false then append_unique(attempts, path) end
    for _, root in ipairs(self.roots) do
        append_unique(attempts, join(root.path, path))
    end
    return attempts
end

---return the first matching virtual path, its info, and all paths considered
---@return string|nil, table|nil, string[]
function Resolver:find(path, options)
    local attempts = self:attempts(path, options)
    for _, candidate in ipairs(attempts) do
        local info = self.filesystem.getInfo(candidate)
        if info and (not options or not options.file_only or info.type == nil or info.type == "file") then
            return candidate, info, attempts
        end
    end
    return nil, nil, attempts
end

---resolve a required asset or raise an actionable error
---@return string, table
function Resolver:resolve(path, options)
    local candidate, info, attempts = self:find(path, options)
    if candidate then return candidate, info end
    error(("Missing required asset '%s'. Searched: %s")
        :format(tostring(path), table.concat(attempts, ", ")), 2)
end

function Resolver:read(path, options)
    local read_options = {}
    for key, value in pairs(options or {}) do read_options[key] = value end
    read_options.file_only = true
    local candidate = self:resolve(path, read_options)
    local data, err = self.filesystem.read(candidate)
    if not data then
        error(("Could not read required asset '%s': %s"):format(candidate, tostring(err)), 2)
    end
    return data, candidate
end

function Resolver:image(path, settings)
    local candidate = self:resolve(path, { file_only = true })
    assert(love and love.graphics and love.graphics.newImage,
        "wave.assets:image requires love.graphics.newImage")
    local ok, image_or_error = pcall(love.graphics.newImage, candidate, settings)
    if not ok then
        error(("Could not load image '%s': %s"):format(candidate, tostring(image_or_error)), 2)
    end
    return image_or_error, candidate
end

function Resolver:font(path, size, hinting)
    local candidate = self:resolve(path, { file_only = true })
    assert(love and love.graphics and love.graphics.newFont,
        "wave.assets:font requires love.graphics.newFont")
    local ok, font_or_error = pcall(love.graphics.newFont, candidate, size, hinting)
    if not ok then
        error(("Could not load font '%s': %s"):format(candidate, tostring(font_or_error)), 2)
    end
    return font_or_error, candidate
end

function Resolver:source(path, source_type)
    local candidate = self:resolve(path, { file_only = true })
    assert(love and love.audio and love.audio.newSource,
        "wave.assets:source requires love.audio.newSource")
    local ok, source_or_error = pcall(love.audio.newSource, candidate, source_type)
    if not ok then
        error(("Could not load audio source '%s': %s"):format(candidate, tostring(source_or_error)), 2)
    end
    return source_or_error, candidate
end

return Resolver
