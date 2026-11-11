-- resolve `require("engine/...")` and engine file paths when the engine lives
-- below another project. bootstrap.lua calls this on the main thread, worker
-- threads call it with the prefix taken from their own chunk name. `prefix`
-- is the mount folder with a trailing slash, e.g. "vendor/wave-engine/"
return function(prefix)
    if type(prefix) ~= "string" or prefix == "" then return end
    if package.loaded["engine/mount_prefix"] == prefix then return end
    package.loaded["engine/mount_prefix"] = prefix
    package.loaded["engine/root"] = prefix .. "engine"

    local templates = { prefix .. "?.lua", prefix .. "?/init.lua" }
    local loaders = package.loaders or package.searchers
    -- LÖVE's searcher behaves the same for folders and zipped .love files,
    -- so modules are loaded through love.filesystem rather than package.path
    table.insert(loaders, 2, function(name)
        local relative = name:gsub("%.", "/")
        for _, template in ipairs(templates) do
            local path = template:gsub("%?", relative)
            if love.filesystem.getInfo(path, "file") then
                return assert(love.filesystem.load(path)), path
            end
        end
        return ("\n\tno mounted wave-engine module '%s'"):format(name)
    end)
end
