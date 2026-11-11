-- the runtime modules share one environment so they can refer to each other
-- publish the backend only after every chunk has finished loading
local Prepare = {}
local runtime_directory = require("engine/root") .. "/graphics/rbx/runtime/"
local module_order = {
    "common.lua", "gui.lua", "gui_bridge.lua", "parser.lua", "scene.lua",
    "datamodel.lua", "geometry.lua", "assets.lua", "render.lua", "surface.lua", "lifecycle.lua",
}
local backend, active_owner

local function load_chunk(environment, path)
    local chunk, load_error = love.filesystem.load(runtime_directory .. path)
    assert(chunk, ("failed to load runtime module '%s': %s"):format(path, tostring(load_error)))
    if setfenv then
        setfenv(chunk, environment)
    else
        local index = 1
        while true do
            local name = debug.getupvalue(chunk, index)
            if not name then break end
            if name == "_ENV" then
                debug.upvaluejoin(chunk, index, function() return environment end, 1)
                break
            end
            index = index + 1
        end
    end
    return chunk()
end

function Prepare.build(loading)
    if backend then return backend end
    loading = loading or {}
    assert(loading.checkpoint == nil or type(loading.checkpoint) == "function", "Loading checkpoint must be a function")
    assert(loading.on_owner == nil or type(loading.on_owner) == "function", "Loading owner callback must be a function")
    assert(not active_owner, "Another owner is preparing this runtime")

    local environment = setmetatable({}, { __index = _G })
    local owner = { closed = false, cancelled = false, environment = environment }
    active_owner = owner
    function owner:cancel()
        if self.closed then return false end
        self.closed, self.cancelled, self.environment = true, true, nil
        if active_owner == self then active_owner = nil end
        return true
    end

    -- a chunk can set up shared state and return nil, so cache that case too
    local modules, nil_result = {}, {}
    function environment.runtime_require(path)
        path = tostring(path or "")
        assert(path ~= "", "runtime_require expected a relative runtime path")
        local result = modules[path]
        if result == nil then
            result = load_chunk(environment, path)
            modules[path] = result == nil and nil_result or result
        elseif result == nil_result then
            return nil
        end
        return result
    end

    local function check_owner()
        assert(not owner.cancelled and active_owner == owner, "Runtime preparation owner was canceled or superseded")
    end

    local ok, result = xpcall(function()
        if loading.on_owner then loading.on_owner(owner) end
        check_owner()
        for index, path in ipairs(module_order) do
            if path == "gui_bridge.lua" and (type(environment.Element) ~= "table"
                    or type(environment.Image) ~= "table" or type(environment.Text) ~= "table") then
                environment.RBX._gui_bridge_unavailable_reason = "host Element/Image/Text framework is not initialized"
            else
                environment.runtime_require(path)
            end
            if loading.checkpoint then
                loading.checkpoint("runtime-module:" .. path, index, #module_order)
            end
            check_owner()
        end
        return assert(environment.RBX, "Runtime chunks did not produce RBX")
    end, debug.traceback)
    if not ok then
        owner:cancel()
        error(result, 0)
    end

    backend, active_owner = result, nil
    owner.closed, owner.environment = true, nil
    return backend
end

return Prepare
