-- UI coordinate policy: layout, Canvas dimensions, Quads and scissors are in
-- LÖVE logical graphics units. only readback and raster density use pixels
local Surface = {}
local densities = setmetatable({}, {__mode = "k"})

local function target_contains_canvas(target, canvas)
    if target == canvas then return true end
    if type(target) ~= 'table' then return false end
    for _, entry in pairs(target) do
        if entry == canvas then return true end
        if type(entry) == 'table' and entry[1] == canvas then return true end
    end
    return false
end

---capture the current color target before rendering a cache or project-owned
---pass. LÖVE 11.5's getCanvas intentionally returns only the color Canvas
---when the target was created with temporary depth/stencil attachments
function Surface.capture_render_target()
    return love.graphics.getCanvas()
end

---restore a captured target, preserving the engine's temporary depth/stencil
---attachments for its active presentation pass. a raw setCanvas(getCanvas())
---silently drops those attachments in LÖVE 11.5 and makes later stencil/depth
---draws fail after an Element, Image, Text, or descriptor cache rebuild
function Surface.restore_render_target(target)
    local graphics = love.graphics
    local presentation = G and G._presentation_target
    if presentation and presentation.canvas and target_contains_canvas(target, presentation.canvas) then
        graphics.setCanvas({ presentation.canvas, depth = true, stencil = true })
    elseif target then
        graphics.setCanvas(target)
    else
        graphics.setCanvas()
    end
end

function Surface.density()
    local canvas = love.graphics.getCanvas()
    -- some LÖVE versions expose a render-target descriptor here, while 11.5
    -- returns the color Canvas even when temporary depth/stencil were used
    -- Density only needs that color Canvas, restoration uses the helpers above
    if type(canvas)=='table' then
        canvas=type(canvas[1])=='table' and canvas[1][1] or canvas[1]
    end
    if canvas then return densities[canvas] or canvas:getDPIScale() end
    return love.graphics.getDPIScale()
end

function Surface.new_canvas(w, h, settings)
    local opts = {}
    for k, v in pairs(settings or {}) do opts[k] = v end
    opts.dpiscale = opts.dpiscale or Surface.density()
    local canvas = love.graphics.newCanvas(w, h, opts)
    densities[canvas] = opts.dpiscale
    -- cache surfaces can be translated/scaled. never inherit the game's
    -- global nearest filter for a surface containing smooth UI text
    canvas:setFilter("linear", "linear")
    canvas:setWrap("clamp", "clamp")
    return canvas
end

function Surface.matches(canvas, w, h)
    if not canvas or canvas:getWidth() ~= w or canvas:getHeight() ~= h then return false end
    local dpi = Surface.density()
    return canvas:getPixelWidth() == math.floor(w * dpi + 0.5)
        and canvas:getPixelHeight() == math.floor(h * dpi + 0.5)
end

function Surface.snap(v, dpi)
    dpi = dpi or Surface.density()
    return math.floor(v * dpi + 0.5) / dpi
end

function Surface.scissor(x, y, w, h)
    -- LÖVE 11.x stores scissors as integer logical Rects. Round the edges
    -- outward here, passing fractional values lets its integer conversion
    -- truncate width/height independently and can cut off the last ink row
    local x0, y0 = math.floor(x), math.floor(y)
    return x0, y0, math.max(0, math.ceil(x + w) - x0), math.max(0, math.ceil(y + h) - y0)
end

return Surface
