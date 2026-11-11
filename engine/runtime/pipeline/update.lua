G.pipeline:register('update', 'INIT', function(dt)
    for _, element in ipairs(AllElements) do
        element:update(dt)
    end

    if timers and timers.update then
        timers.update(dt)
    end

    tween.update('unpausable', dt)
    Particle.updateAll('unpausable', dt)

    if not G.paused then
        Particle.updateAll('pausable', dt)
        tween.update('pausable', dt)
    end
end, 2)
G.pipeline:register('update', 'debug', function()
    local memory_usage = math.floor(collectgarbage("count") / 1024) .. "mb"
    local delta = math.roundToDecimal(G.delta, 2)
    local resolution = G.resolution.x .. ', ' .. G.resolution.y
    local input_type = input_mgr.mobile.is_mobile and "mobile"
        or (table.dict_length(input_mgr.sources) > 1 and "gamepad" or "keyboard")

    G.debug:update("delta", delta)
    G.debug:update("mem usage", memory_usage)
    G.debug:update("resolution", resolution)
    G.debug:update("input type", input_type)
end)
G.pipeline:disable('update', 'debug')

G.pipeline:register('update', 'mouse', function(dt)
    input_mgr.mouse.update(dt)
    for _, element in ipairs(AllElements) do
        element.isdrawn = false
    end
end)
