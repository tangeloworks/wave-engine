-- Loads pieces of the RBX runtime for testing.
--
-- WHY THIS EXISTS: engine/graphics/rbx/runtime/init.lua does not use require().
-- It loads its ten modules with love.filesystem.load() into ONE shared setfenv
-- environment where they all mutate a single `RBX` table (runtime/init.lua:33-77).
-- Consequences that shape this file:
--   * runtime modules never appear in package.loaded, so require() cannot reach them;
--   * a module cannot be loaded in isolation without recreating that environment;
--   * later modules can silently REDEFINE functions defined by earlier ones
--     (datamodel.lua:1995 overrides RBX:_get_or_create_part_proxy from scene.lua),
--     so load order is semantically significant.
-- This harness recreates the same environment so tests observe exactly what the
-- real app observes, load-order shadowing included.
--
-- Headless note: several runtime modules (render/assets/gui/surface) touch
-- love.graphics at load time. Under RBX_TEST the graphics module is disabled, so
-- only the graphics-free subset can load. load_runtime_subset() is the headless
-- entry point; load_full_runtime() is available when graphics is present.

local harness = {}

local RUNTIME_PREFIX = "engine/graphics/rbx/runtime/"

local env = setmetatable({}, { __index = _G })
local module_cache = {}
local NIL_SENTINEL = {}

local function load_runtime_chunk(relative_path)
    local chunk, err = love.filesystem.load(RUNTIME_PREFIX .. relative_path)
    if not chunk then
        error(string.format("failed to load runtime module '%s': %s", relative_path, tostring(err)), 0)
    end
    if setfenv then
        setfenv(chunk, env)
    else
        local i = 1
        while true do
            local name = debug.getupvalue(chunk, i)
            if name == nil then break end
            if name == "_ENV" then
                debug.upvaluejoin(chunk, i, function() return env end, 1)
                break
            end
            i = i + 1
        end
    end
    return chunk()
end

function env.runtime_require(relative_path)
    local key = tostring(relative_path or "")
    if key == "" then
        error("runtime_require expected a relative runtime path", 0)
    end
    local cached = module_cache[key]
    if cached ~= nil then
        if cached == NIL_SENTINEL then return nil end
        return cached
    end
    local result = load_runtime_chunk(key)
    if result == nil then
        module_cache[key] = NIL_SENTINEL
        return nil
    end
    module_cache[key] = result
    return result
end

harness.env = env
harness.runtime_require = env.runtime_require

-- Modules that load with the graphics module disabled. Verified individually.
harness.HEADLESS_MODULES = {
    "math/vec3.lua",
    "math/mat3.lua",
    "math/quat.lua",
    "physics/shape.lua",
    "physics/materials.lua",
    "physics/collision_groups.lua",
    "physics/cframe_math.lua",
    "physics/integrate.lua",
    "physics/broadphase.lua",
    "physics/narrowphase.lua",
    "physics/manifold.lua",
    "physics/solver.lua",
    "physics/assembly.lua",
    "physics/joint_frames.lua",
    "physics/surface_welds.lua",
    "physics/dynamic_rotate.lua",
    "physics/body.lua",
    "physics/movers.lua",
    "physics/queries.lua",
    "physics/world.lua",
}

---Loads every graphics-free runtime module.
---@return table loaded  map of relative path -> module (or false when it failed)
---@return table errors  map of relative path -> error string
function harness.load_runtime_subset()
    local loaded, errors = {}, {}
    for _, path in ipairs(harness.HEADLESS_MODULES) do
        local ok, result = pcall(harness.runtime_require, path)
        if ok then
            loaded[path] = result == nil and false or result
        else
            loaded[path] = false
            errors[path] = tostring(result)
        end
    end
    return loaded, errors
end

---Loads the full runtime in the real load order. Requires love.graphics.
function harness.load_full_runtime()
    if not love.graphics then
        error("load_full_runtime() needs the graphics module; run without RBX_TEST=headless", 0)
    end
    local order = {
        "common.lua", "gui.lua", "gui_bridge.lua", "parser.lua", "scene.lua",
        "datamodel.lua", "geometry.lua", "assets.lua", "render.lua", "surface.lua",
    }
    for _, path in ipairs(order) do
        load_runtime_chunk(path)
    end
    return env.RBX
end

---Convenience accessor with a clear failure when a module is unavailable.
function harness.need(relative_path)
    local ok, result = pcall(harness.runtime_require, relative_path)
    if not ok or result == nil then
        error(string.format("runtime module '%s' unavailable: %s",
            relative_path, ok and "returned nil" or tostring(result)), 2)
    end
    return result
end

---------------------------------------------------------------- map corpus

-- place files for optional local corpus checks; none ship with the engine
harness.MAPS = {}

function harness.map_exists(path)
    return love.filesystem.getInfo(path) ~= nil
end

-- Parsing gord.rbxl costs ~2.2 s and the XML Crossroads ~1.9 s, and several
-- suites want the same file. Memoised so a full run parses each map once.
local parse_cache = {}

---Parses a place file through the public loader (no renderer, no GPU).
---@param fresh boolean|nil  bypass the cache (for timing measurements)
---@return table|nil file, string|nil err, number elapsed_ms
function harness.load_map(path, fresh)
    if not fresh then
        local hit = parse_cache[path]
        if hit then return hit.file, hit.err, hit.elapsed end
    end

    local loader = require("engine/graphics/rbx/love/loader")
    local t0 = love.timer.getTime()
    local ok, file = pcall(loader.load_file, path)
    local elapsed = (love.timer.getTime() - t0) * 1000

    local result
    if not ok then
        result = { file = nil, err = tostring(file), elapsed = elapsed }
    else
        result = { file = file, err = nil, elapsed = elapsed }
    end
    if not fresh then parse_cache[path] = result end
    return result.file, result.err, result.elapsed
end

function harness.clear_parse_cache()
    parse_cache = {}
end

---Counts instances by ClassName in a parsed file, for parity comparisons.
function harness.class_histogram(file)
    local hist = {}
    local list = file and file.instances
    if not list then return hist end
    for i = 1, #list do
        local class = list[i].className or list[i].class_name or list[i].ClassName or "<unknown>"
        hist[class] = (hist[class] or 0) + 1
    end
    return hist
end

return harness
