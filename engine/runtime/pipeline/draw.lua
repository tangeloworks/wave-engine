local accessibility_postprocess = require("engine/graphics/accessibility")
local render_policy = require('engine/graphics/presentation')

local function reset_screen_state()
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setScissor()
    love.graphics.setStencilTest()
    love.graphics.setColorMask(true, true, true, true)
    love.graphics.setDepthMode()
    love.graphics.setMeshCullMode('none')
    love.graphics.setBlendMode('alpha', 'alphamultiply')
    love.graphics.setColor(1, 1, 1, 1)
end

local function screen_draw(draw)
    return function()
        love.graphics.push('all')
        local ok, err = pcall(function()
            reset_screen_state()
            draw()
        end)
        love.graphics.pop()
        if not ok then error(err, 0) end
    end
end

---unwind engine-owned presentation passes after a draw-stage error
function G.abort_presentation_frame()
    local _, postfx_aborted = pcall(accessibility_postprocess.abort_frame)
    local _, composite_aborted = pcall(accessibility_postprocess.abort_ratio_composite)
    local ratio_aborted = false

    if G._ratio_frame_active then
        pcall(love.graphics.setShader)
        pcall(love.graphics.pop)
        ratio_aborted = true
    end
    G._ratio_frame_active = false
    G._presentation_target = nil
    pcall(love.graphics.setCanvas)
    pcall(reset_screen_state)
    return postfx_aborted == true or composite_aborted == true or ratio_aborted
end

G.pipeline:register('draw', 'ratioclear', function()
    love.graphics.push('all')
    G._ratio_frame_active = true
    reset_screen_state()
    love.graphics.clear()

    love.graphics.setCanvas({ G.canvas, depth = true, stencil = true })
    G._presentation_target = { kind = 'ratio', canvas = G.canvas }
    love.graphics.clear(0, 0, 0, 0, true, true)

    G.resolution = G:get_ratio_resolution()

    love.graphics.setColor(1, 1, 1)

end)
G.pipeline:disable('draw', 'ratioclear')
love.graphics.setBackgroundColor(150, 150, 150, .5)

postfxShader = nil
function getPostfxShader()
    postfxShader = accessibility_postprocess.get_shader()
    return postfxShader
end

function postfxActive()
    return accessibility_postprocess.active()
end

function sendPostfxUniforms()
    accessibility_postprocess.send_uniforms()
end

G.pipeline:register('draw', 'postfx_start', function()
    accessibility_postprocess.begin_frame()
end, 0)

G.pipeline:disable('draw', 'postfx_start')

G.pipeline:register('draw', 'INIT', function()
    reset_screen_state()
    love.graphics.setColor(unpack(G.background_color))
    love.graphics.rectangle("fill", 0, 0, G.resolution.x, G.resolution.y)
    love.graphics.origin()

    timers.draw(G.delta)

    tween.draw('unpausable')
    tween.draw('pausable')

    Particle.drawAll('unpausable')
    Particle.drawAll('pausable')
end, 2)

if G.use_ui_editor then
    G:init_ui_editor()
end

G.pipeline:register('draw', 'debug', screen_draw(function()
    G.debug:draw()
end))
G.pipeline:disable('draw', 'debug')

G.pipeline:register('draw', 'keyboard_flyout', screen_draw(function()
    if input_mgr.typing and input_mgr.typing.virtual_keyboard and input_mgr.typing.virtual_keyboard.container then
        input_mgr.typing.virtual_keyboard.container:draw()
    end
end))
G.pipeline:disable('draw', 'keyboard_flyout')

G.pipeline:register('draw', 'letterbox', screen_draw(function()
    if G.letterbox.val > 0 then
        love.graphics.setColor(0, 0, 0)
        local barHeight = G.resolution.y * G.letterbox.val
        love.graphics.rectangle("fill", 0, 0, G.resolution.x, barHeight)
        love.graphics.rectangle("fill", 0, G.resolution.y - barHeight,
            G.resolution.x, barHeight)
    end
    love.graphics.origin()
end))

local fps_font, fps_font_size, fps_text, fps_next_refresh
G.pipeline:register('draw', 'fpsdraw', function()
    love.graphics.push('all')
    reset_screen_state()
    local size = math.max(12, math.floor(18 * (G.resScaleFactor or 1) + 0.5)) * 2
    if not fps_font or fps_font_size ~= size then
        fps_font = require("engine/graphics/font_manager").get(nil, size)
        fps_font_size = size
    end
    local now = love.timer.getTime()
    if not fps_text or now >= (fps_next_refresh or 0) then
        fps_text = 'FPS: ' .. love.timer.getFPS()
        fps_next_refresh = now + .25
    end
    local counter = fps_text
    local pad = math.floor(size * 0.4 + 0.5)
    love.graphics.origin()
    love.graphics.setColor(1, 0, 0)
    love.graphics.print(counter, fps_font,
        math.floor(love.graphics.getWidth() - fps_font:getWidth(counter) - pad + 0.5), pad)
    love.graphics.pop()
end)

G.pipeline:disable('draw', 'fpsdraw')

local perf_font, perf_font_size, perf_text, perf_next_refresh
G.pipeline:register('draw', 'perfstats', function()
    love.graphics.push('all')
    reset_screen_state()
    local size = math.max(10, math.floor(13 * (G.resScaleFactor or 1) + 0.5)) * 2
    if not perf_font or perf_font_size ~= size then
        perf_font = require("engine/graphics/font_manager").get(nil, size)
        perf_font_size = size
    end
    local now = love.timer.getTime()
    if not perf_text or now >= (perf_next_refresh or 0) then
        perf_text = ('frame: %.2f ms\nmem: %.1f MiB'):format(
            math.max(0, (G.delta or 0) * 1000), collectgarbage('count') / 1024)
        perf_next_refresh = now + 0.25
    end
    local pad = math.floor(size * 0.45 + 0.5)
    local y = pad
    local fps_setting = CFG:getSetting('fps')
    if fps_setting and fps_setting.value then y = y + size * 1.9 end
    love.graphics.setColor(0.85, 0.95, 1, 1)
    love.graphics.print(perf_text, perf_font, pad, y)
    love.graphics.pop()
end)

G.pipeline:disable('draw', 'perfstats')

G.pipeline:register('draw', 'ratiofin', function()
    G._presentation_target = nil
    love.graphics.setCanvas()
    reset_screen_state()

    local cW, cH             = G.canvas:getWidth(), G.canvas:getHeight()
    local sW, sH             = love.graphics.getWidth(), love.graphics.getHeight()

    local dx, dy, sx, sy = render_policy.canvas_transform(cW, cH, sW, sH,
        G:getSetting('stretch').value)
    input_mgr.mouse._scale, input_mgr.mouse._scaleX, input_mgr.mouse._scaleY = sx, sx, sy
    input_mgr.mouse._offsetX, input_mgr.mouse._offsetY = dx, dy


    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", 0, 0, sW, sH)

    love.graphics.setColor(1, 1, 1)
    local is_integer_scale = sx >= 1 and sy >= 1
        and math.abs(sx - math.floor(sx + 0.5)) <= 1e-4
        and math.abs(sy - math.floor(sy + 0.5)) <= 1e-4
    local canvasFilter = is_integer_scale and "nearest" or "linear"
    if G._canvas_filter_mode ~= canvasFilter then
        G._canvas_filter_mode = canvasFilter
        G.canvas:setFilter(canvasFilter, canvasFilter)
        if G.postfxCanvas then
            accessibility_postprocess.set_canvas_filter(canvasFilter)
        end
    end

    if postfxActive() then
        accessibility_postprocess.apply_to_canvas(G.canvas, dx, dy, sx, sy)
    else
        -- draw with explicit tiling clamp to avoid sampling past edges
        G.canvas:setWrap('clampzero', 'clampzero')
        -- Canvas pixels are premultiplied. the regular screen reset uses
        -- alphamultiply for source primitives, which would multiply edge alpha
        -- a second time here and create dark fringes in ratio mode
        love.graphics.setBlendMode('alpha', 'premultiplied')
        love.graphics.draw(G.canvas, dx, dy, 0, sx, sy)
    end
    love.graphics.pop()
    G._ratio_frame_active = false
end, { priority = -1000 })

G.pipeline:disable('draw', 'ratiofin')

G.pipeline:register('draw', 'postfx_end', function()
    accessibility_postprocess.end_frame()
end, { priority = -1000 })

G.pipeline:disable('draw', 'postfx_end')
