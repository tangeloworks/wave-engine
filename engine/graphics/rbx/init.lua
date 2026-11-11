local import = require("engine/graphics/rbx/import")
local love_loader = require("engine/graphics/rbx/love/loader")
local public_options = require("engine/graphics/rbx/public_options")

local viewer_module = nil
---@class RBXModule
---@field CFrame RBXLXCFrameApi
---@field Vector3 RBXLXVector3Api
---@field Color3 RBXLXColor3Api
---@field Instance RBXLXInstanceApi
---@field Enum RBXEnum
---@field PhysicalProperties { new: fun(material:RBXEnumItem):RBXLXPhysicalProperties, new: fun(density?:number, friction?:number, elasticity?:number, frictionWeight?:number, elasticityWeight?:number, acousticAbsorption?:number):RBXLXPhysicalProperties }
---@field Ray { new: fun(origin:RBXLXVector3, direction:RBXLXVector3):RBXLXRay }
---@field Region3 { new: fun(min:RBXLXVector3, max:RBXLXVector3):RBXLXRegion3 }
---@field RaycastParams { new: fun():RBXLXRaycastParams }
---@field RaycastResult table
---@field OverlapParams { new: fun():RBXLXRaycastParams }
---@field load_bytes fun(data:string, format_hint?:string, opts?:table):table
---@field load_file fun(path:string, opts?:table):table
---@field import_scene fun(file:table, opts?:table):table
---@field import_renderables fun(file_or_scene:table, opts?:table):table
---@field load_scene fun(path:string, opts?:table):table
---@field new fun(options?:RBXOptions, loading?:RBXLoadingContext):RBXDataModel?, string?
---@field prepare_runtime fun(loading?:RBXLoadingContext):boolean?, string?
---@field new_viewer fun(options?:table):table?, string?
---@field debug_report fun(game?:RBXDataModel):table?, string?
---@field viewer table
---@field debug_deprecation_warnings boolean

---@type RBXModule
local rbx = {}

-- game.cframe/vector3/instance/part are deprecated compat shims, debug_deprecation_warnings surfaces them

local runtime_backend = nil
local runtime_backend_error = nil
-- resolve these public types on demand so a 2D project can skip loading the renderer
local runtime_export_keys = {
    CFrame = true,
    Vector3 = true,
    Color3 = true,
    Instance = true,
    Enum = true,
    PhysicalProperties = true,
    Ray = true,
    Region3 = true,
    RaycastParams = true,
    RaycastResult = true,
    OverlapParams = true,
}

local function get_runtime_backend()
    if runtime_backend ~= nil then
        return runtime_backend
    end
    local ok, loaded = pcall(require, "engine/graphics/rbx/runtime")
    if ok then
        runtime_backend = loaded
        runtime_backend_error = nil
    else
        runtime_backend = false
        runtime_backend_error = tostring(loaded)
    end
    return runtime_backend
end

---@class RBXLoadingContext
---@field checkpoint? fun(stage:string, index?:integer, total?:integer)
---@field on_owner? fun(owner:table) Receives a cancelable operation before work begins
local function loading_context_error(loading)
    if loading==nil then return nil end
    if type(loading)~='table'then return 'RBX loading context must be a table or nil' end
    for key,value in pairs(loading)do
        if key~='checkpoint'and key~='on_owner'then return 'Unknown RBX loading field '..tostring(key)end
        if type(value)~='function'then return 'RBX loading '..key..' must be a function'end
    end
end
-- Execute private module assembly outside require's loading sentinel. Canceling
-- this owner can retry without invalidating an already-loaded sibling backend
function rbx.prepare_runtime(loading)
    local invalid=loading_context_error(loading);if invalid then return nil,invalid end
    if type(runtime_backend)=='table'then return true end
    local existing=package.loaded['engine/graphics/rbx/runtime']
    if type(existing)=='table'then runtime_backend=existing;runtime_backend_error=nil;return true end
    local ok,backend=pcall(function()
        return require('engine/graphics/rbx/runtime/prepare').build(loading)
    end)
    if not ok then return nil,tostring(backend)end
    runtime_backend=backend;runtime_backend_error=nil
    package.loaded['engine/graphics/rbx/runtime']=backend
    return true
end

local function runtime_backend_unavailable_message()
    if runtime_backend_error and runtime_backend_error ~= "" then
        return "RBX renderer backend unavailable: " .. runtime_backend_error
    end
    return "RBX renderer backend unavailable"
end

---@param data string
---@param format_hint string|nil
---@param opts table|nil
---@return table
function rbx.load_bytes(data, format_hint, opts)
    return love_loader.load_bytes(data, format_hint, opts)
end

---@param path string
---@param opts table|nil
---@return table
function rbx.load_file(path, opts)
    return love_loader.load_file(path, opts)
end

---@param file table
---@param opts table|nil
---@return table
function rbx.import_scene(file, opts)
    return import.import_scene(file, opts)
end

---@param file_or_scene table
---@param opts table|nil
---@return table
function rbx.import_renderables(file_or_scene, opts)
    return import.import_renderables(file_or_scene, opts)
end

---@param path string
---@param opts table|nil
---@return table
function rbx.load_scene(path, opts)
    local file = rbx.load_file(path, opts)
    return rbx.import_scene(file, opts)
end

---@param options? RBXOptions
---@param loading? RBXLoadingContext
---@return RBXDataModel? game
---@return string? error
function rbx.new(options, loading)
    local invalid=loading_context_error(loading);if invalid then return nil,invalid end
    if loading then
        local ready,err=rbx.prepare_runtime(loading);if not ready then return nil,err end
    end
    local backend = get_runtime_backend()
    if not backend or type(backend.new) ~= "function" then
        return nil, runtime_backend_unavailable_message()
    end
    local runtime_options, options_error = public_options.build(options, {
        debug_deprecation_warnings = rbx.debug_deprecation_warnings == true,
    })
    if not runtime_options then
        return nil, options_error
    end
    return backend.new(runtime_options, loading)
end

---@param game RBXDataModel|nil
---@return table? report
---@return string? error
function rbx.debug_report(game)
    if game and type(game.get_debug_report) == "function" then
        return game:get_debug_report()
    end
    local backend = get_runtime_backend()
    local active_game = backend and backend._active_datamodel or nil
    if active_game and type(active_game.get_debug_report) == "function" then
        return active_game:get_debug_report()
    end
    return nil, "No active RBX DataModel"
end

local function get_viewer_module()
    if viewer_module ~= nil then
        return viewer_module
    end
    local ok, loaded = pcall(require, "engine/graphics/rbx/viewer")
    viewer_module = ok and loaded or false
    return viewer_module
end

---@param options table|nil
---@return table? viewer
---@return string? error
function rbx.new_viewer(options)
    local module = get_viewer_module()
    if not module or type(module.new) ~= "function" then
        return nil, "RBX viewer module unavailable"
    end
    return module.new(options)
end

rbx.viewer = setmetatable({}, {
    __index = function(_, key)
        local module = get_viewer_module()
        if not module then
            error("RBX viewer module unavailable", 2)
        end
        return module[key]
    end,
})

setmetatable(rbx, {
    __index = function(_, key)
        if runtime_export_keys[key] then
            local backend = get_runtime_backend()
            if not backend then
                error(runtime_backend_unavailable_message(), 2)
            end
            local value = backend[key]
            rawset(rbx, key, value)
            return value
        end
        return nil
    end,
})

return rbx
