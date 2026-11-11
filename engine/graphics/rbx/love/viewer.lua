local cpml = require("engine/services/oss/cpml")
local camera_controller = require("engine/graphics/rbx/love/camera_controller")
local util = require("engine/graphics/rbx/util")
local public_options = require("engine/graphics/rbx/public_options")

local vec3 = cpml.vec3

local viewer = {}
viewer.__index = viewer

local function destroy_renderer(renderer)
    if type(renderer) ~= "table" then
        return false
    end
    local destroy = renderer.Destroy or renderer.destroy
    if type(destroy) ~= "function" then
        return false
    end
    local ok = pcall(destroy, renderer)
    return ok
end

local function destroy_controller(controller)
    if type(controller) == "table" and type(controller.destroy) == "function" then
        pcall(controller.destroy, controller)
    end
end

local VIEWER_ONLY_OPTIONS = {
    async_load = true,
    controls_enabled = true,
    focus_name = true,
    load_modern_scene = true,
    map_path = true,
    show_overlay = true,
}

local function load_runtime_backend()
    local ok, module = pcall(require, "engine/graphics/rbx/runtime")
    if ok and type(module) == "table" then
        return module
    end
    error("RBX runtime backend is unavailable: " .. tostring(module))
end

local function renderer_bounds_to_scene(bounds)
    if type(bounds) ~= "table" or bounds.min_x == nil or bounds.max_x == nil then
        return nil
    end

    return {
        min = vec3.new(bounds.min_x, bounds.min_y, bounds.min_z),
        max = vec3.new(bounds.max_x, bounds.max_y, bounds.max_z),
    }
end

local function build_runtime_options(opts)
    local public = {}
    for key, value in pairs(opts) do
        if not VIEWER_ONLY_OPTIONS[key] then
            public[key] = value
        end
    end
    return public_options.build(public)
end

function viewer.new(opts)
    opts = opts or {}

    local runtime_options, options_error = build_runtime_options(opts)
    if not runtime_options then
        return nil, options_error
    end

    local self = setmetatable({
        path = opts.map_path,
        renderer = nil,
        runtime_backend = load_runtime_backend(),
        controller = nil,
        bounds = util.ensure_bounds(nil, 32),
        loadError = nil,
        asyncLoad = opts.async_load == true,
        controlsEnabled = opts.controls_enabled ~= false,
        runtimeOptions = runtime_options,
        _reloadGeneration = 0,
    }, viewer)

    self:reload(self.path)
    return self
end

function viewer:get_renderer()
    return self.renderer
end

function viewer:_update_bounds()
    local renderer = self:get_renderer()
    local bounds = renderer_bounds_to_scene(renderer and renderer._scene_bounds)
    self.bounds = util.ensure_bounds(bounds or self.bounds, 32)
    return self.bounds
end

function viewer:_focus_camera()
    self:_update_bounds()
    if not self.controller then
        self.controller = camera_controller.new(self)
    end

    self.controller:focus_bounds(self.bounds, {
        direction = vec3.new(1, 0.14, 0.58),
        distance_scale = 1.1,
        min_distance = 16,
        lift = math.max(util.bounds_size(self.bounds).y * 0.1, 3),
    })
end

function viewer:_finish_reload(load_err)
    if load_err then
        self.loadError = tostring(load_err)
        return nil, load_err
    end

    self:_focus_camera()
    return true
end

function viewer:reload(path, opts)
    if opts then
        local runtime_options, options_error = build_runtime_options(opts)
        if not runtime_options then
            return nil, options_error
        end
        self.runtimeOptions = runtime_options
    end

    self.path = path or self.path
    self.loadError = nil
    destroy_controller(self.controller)
    self.controller = nil
    self.bounds = util.ensure_bounds(nil, 32)
    self._reloadGeneration = (self._reloadGeneration or 0) + 1
    local reload_generation = self._reloadGeneration

    local renderer, render_err = self.runtime_backend.new(self.runtimeOptions)
    if not renderer then
        self.loadError = tostring(render_err)
        return nil, render_err
    end
    local previous_renderer = self.renderer
    self.renderer = renderer
    if previous_renderer and previous_renderer ~= renderer then
        destroy_renderer(previous_renderer)
    end

    if type(self.path) ~= "string" or util.trim(self.path) == "" then
        self:_focus_camera()
        return self
    end

    if self.asyncLoad and renderer.load_map_async then
        local started = renderer:load_map_async(self.path, {
            on_complete = function(ok, payload)
                if self._reloadGeneration ~= reload_generation
                    or self.renderer ~= renderer then
                    return
                end
                self:_finish_reload(ok and nil or payload)
            end,
        })
        if started then
            return self
        end
    end

    local ok, load_err = renderer:load_map(self.path)
    if not ok then
        self.loadError = tostring(load_err)
        return nil, load_err
    end

    self:_finish_reload(nil)
    return self
end

function viewer:destroy()
    self._reloadGeneration = (self._reloadGeneration or 0) + 1
    local renderer = self.renderer
    self.renderer = nil
    destroy_controller(self.controller)
    self.controller = nil
    self.bounds = util.ensure_bounds(nil, 32)
    return destroy_renderer(renderer)
end

viewer.Destroy = viewer.destroy

function viewer:set_camera_pose(position, forward, up)
    local renderer = self:get_renderer()
    if not renderer then
        return
    end

    renderer:set_camera_cframe(self.runtime_backend.CFrame.from_look_vector(
        position.x, position.y, position.z,
        forward.x, forward.y, forward.z,
        up.x, up.y, up.z
    ))
end

function viewer:update(dt)
    self:_update_bounds()
    if self.controlsEnabled and self.controller then
        self.controller:update(dt)
    end

    local renderer = self:get_renderer()
    if renderer and renderer.update then
        renderer:update(dt)
    end
end

function viewer:is_ready_for_capture()
    if self.loadError then
        return true
    end

    local renderer = self:get_renderer()
    return not (renderer and renderer.is_map_loading and renderer:is_map_loading())
end

function viewer:render_to_canvas(width, height, opts)
    local renderer = self:get_renderer()
    if not renderer or type(renderer.render_to_canvas) ~= "function" then
        return nil, "RBX renderer surface API unavailable"
    end
    return renderer:render_to_canvas(width, height, opts)
end

function viewer:needs_redraw()
    local renderer = self:get_renderer()
    return renderer and type(renderer.needs_redraw) == "function" and renderer:needs_redraw() or false
end

function viewer:capture_frame(width, height, opts)
    local renderer = self:get_renderer()
    if not renderer or type(renderer.capture_frame) ~= "function" then
        return nil, "RBX renderer capture API unavailable"
    end
    return renderer:capture_frame(width, height, opts)
end

function viewer:draw_to_rect(x, y, width, height, opts)
    local renderer = self:get_renderer()
    if not renderer or type(renderer.draw_to_rect) ~= "function" then
        return nil, "RBX renderer surface API unavailable"
    end
    return renderer:draw_to_rect(x, y, width, height, opts)
end

function viewer:draw_renderer_only()
    local renderer = self:get_renderer()
    if renderer and renderer.draw then
        renderer:draw()
    end
end

function viewer:draw()
    self:draw_renderer_only()
end

return viewer
