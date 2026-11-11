local render_source = require("engine/graphics/rbx/source")
local viewer_module = require("engine/graphics/rbx/viewer")

if not rawget(_G, "Object") then
    -- wave-engine owns its lightweight base class in the public core.  the
    -- original optional-renderer source referenced an OSS path that is not
    -- part of this checkout, making standalone RBX viewport use fail before
    -- it could create a renderer source
    require("engine/services/object")
end
if not rawget(_G, "Element") then
    require("engine/graphics/element")
end

---@class RBXViewport: Element
---@overload fun(args?: table): RBXViewport
---@type RBXViewport
local RBXViewport = Element:extend()

local function clone_resolution(value)
    if type(value) ~= "table" then
        return nil
    end
    local x = tonumber(value.x or value.width or value.w or value[1])
    local y = tonumber(value.y or value.height or value.h or value[2])
    if not x or not y then
        return nil
    end
    return { x = x, y = y }
end

local function build_source_options(args)
    local options = {}
    local viewer_options = args.viewer_options or {}
    for key, value in pairs(viewer_options) do
        options[key] = value
    end

    if args.map_path ~= nil and options.map_path == nil then
        options.map_path = args.map_path
    end
    if args.async_load ~= nil and options.async_load == nil then
        options.async_load = args.async_load
    end
    if args.load_modern_scene ~= nil and options.load_modern_scene == nil then
        options.load_modern_scene = args.load_modern_scene
    end
    if args.focus_name ~= nil and options.focus_name == nil then
        options.focus_name = args.focus_name
    end
    if args.controls_enabled ~= nil and options.controls_enabled == nil then
        options.controls_enabled = args.controls_enabled
    end
    if options.controls_enabled == nil then
        options.controls_enabled = false
    end

    return options
end

local function source_needs_redraw(source)
    if type(source) == "table" and type(source.needs_redraw) == "function" then
        return source:needs_redraw()
    end
    return true
end

function RBXViewport:init(args)
    args = args or {}

    local source = args.source or args.viewer
    local owns_source = false
    if not source then
        local viewer_instance, viewer_err = viewer_module.new(build_source_options(args))
        if not viewer_instance then
            error("RBX viewport could not create a render source: " .. tostring(viewer_err), 2)
        end
        source = viewer_instance
        owns_source = true
    end

    Element.init(self, args)

    self._owns_source = owns_source
    self.source = nil
    self.viewer = nil
    self.fit_mode = args.fit_mode or "stretch"
    self.show_overlay = args.show_overlay == true
    self.manage_source_update = args.manage_source_update ~= false
    self.controlsEnabled = args.controls_enabled
    self.use_projection_resolution = args.use_projection_resolution
    if self.use_projection_resolution == nil then
        self.use_projection_resolution = self.fit_mode ~= "stretch"
    end
    self.surface_resolution = clone_resolution(args.surface_resolution)
    self.last_canvas = nil
    self.last_surface = nil
    self.last_render_error = nil
    self.max_redraw_hz = tonumber(args.max_redraw_hz) or 120
    self.idle_redraw_interval = math.max(0.05, tonumber(args.idle_redraw_interval) or 0.25)
    self._redraw_cooldown = 0
    self._idle_redraw_elapsed = 0

    self:set_source(source, owns_source)
end

local function destroy_owned_source(source)
    if type(source) ~= "table" then
        return
    end
    local destroy = source.destroy or source.Destroy
    if type(destroy) == "function" then
        pcall(destroy, source)
    end
end

function RBXViewport:set_source(source, owns_source)
    if source ~= nil and not render_source.supports(source) then
        error("RBX viewport source must implement draw_to_rect", 2)
    end

    local previous_source = self.source
    if previous_source ~= nil
        and previous_source ~= source
        and self._owns_source == true then
        destroy_owned_source(previous_source)
    end

    self.source = source
    self.viewer = source
    if owns_source ~= nil then
        self._owns_source = owns_source == true
    elseif previous_source ~= source then
        self._owns_source = false
    end
    if type(source) == "table" and self.controlsEnabled ~= nil and source.controlsEnabled ~= nil then
        source.controlsEnabled = self.controlsEnabled
    end
    self.last_canvas = nil
    self.last_surface = nil
    self.last_render_error = nil
    self:mark_dirty("on_draw")
    return self
end

function RBXViewport:remove()
    if self._owns_source == true then
        destroy_owned_source(self.source)
    end
    self._owns_source = false
    self.source = nil
    self.viewer = nil
    return Element.remove(self)
end

function RBXViewport:get_source()
    return self.source
end

function RBXViewport:set_fit_mode(mode)
    local next_mode = mode or "stretch"
    if self.fit_mode == next_mode then
        return self
    end
    self.fit_mode = next_mode
    self:mark_dirty("on_draw")
    return self
end

function RBXViewport:get_render_canvas(width, height, options)
    return render_source.render_to_canvas(self.source, width, height, options)
end

function RBXViewport:capture_frame(width, height, options)
    return render_source.capture(self.source, width, height, options)
end

function RBXViewport:_build_draw_options(rect)
    local options = {
        fit = self.fit_mode or "stretch",
        show_overlay = self.show_overlay == true,
        use_projection_size = self.use_projection_resolution == true,
    }

    local surface_resolution = self.surface_resolution
    if surface_resolution then
        options.surface_width = surface_resolution.x
        options.surface_height = surface_resolution.y
    elseif self.use_projection_resolution ~= true then
        options.surface_width = rect.size.x
        options.surface_height = rect.size.y
    end

    return options
end

function RBXViewport:update(dt)
    Element.update(self, dt)

    local dt_value = tonumber(dt) or 0
    if self._redraw_cooldown and self._redraw_cooldown > 0 then
        self._redraw_cooldown = math.max(0, self._redraw_cooldown - dt_value)
    end

    if self.manage_source_update and type(self.source) == "table" and type(self.source.update) == "function" then
        self.source:update(dt)
    end

    local needs_redraw = source_needs_redraw(self.source)
    if needs_redraw then
        self._idle_redraw_elapsed = 0
        if self.max_redraw_hz <= 0 or self._redraw_cooldown <= 0 then
            self:mark_dirty("on_draw")
            if self.max_redraw_hz > 0 then
                self._redraw_cooldown = 1 / self.max_redraw_hz
            end
        end
    elseif self.show_overlay == true then
        self._idle_redraw_elapsed = (self._idle_redraw_elapsed or 0) + dt_value
        if self._idle_redraw_elapsed >= self.idle_redraw_interval then
            self:mark_dirty("on_draw")
            self._idle_redraw_elapsed = 0
        end
    else
        self._idle_redraw_elapsed = 0
    end
end

function RBXViewport:draw_self(rect)
    local source = self.source
    if not source then
        return
    end

    local width = rect.size and rect.size.x or 0
    local height = rect.size and rect.size.y or 0
    if width <= 0 or height <= 0 then
        return
    end

    local canvas, surface_or_err = render_source.draw(source, 0, 0, width, height, self:_build_draw_options(rect))
    if type(surface_or_err) == "table" then
        self.last_canvas = canvas
        self.last_surface = surface_or_err
        self.last_render_error = nil
        return
    end

    self.last_canvas = nil
    self.last_render_error = tostring(surface_or_err)
    love.graphics.push("all")
    love.graphics.setColor(1, 0.35, 0.35, 1)
    love.graphics.printf(self.last_render_error, 8, 8, math.max(1, width - 16), "left")
    love.graphics.pop()
end

return RBXViewport
