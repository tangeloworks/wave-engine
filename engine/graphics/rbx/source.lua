local render_source = {}

local function call_method(source, method_name, ...)
    if type(source) ~= "table" or type(source[method_name]) ~= "function" then
        return nil, string.format("render source is missing '%s'", tostring(method_name))
    end
    return source[method_name](source, ...)
end

function render_source.supports(source)
    return type(source) == "table" and type(source.draw_to_rect) == "function"
end

function render_source.draw(source, x, y, width, height, options)
    return call_method(source, "draw_to_rect", x, y, width, height, options)
end

function render_source.render_to_canvas(source, width, height, options)
    return call_method(source, "render_to_canvas", width, height, options)
end

function render_source.capture(source, width, height, options)
    return call_method(source, "capture_frame", width, height, options)
end

return render_source
