-- Presentation helpers shared by the render pipeline and pointer conversion
local Policy = {}
function Policy.hide_overlays()
    return false
end

function Policy.setting(name)
    local setting = CFG and CFG:getSetting(name)
    if not setting then return false end
    if setting.value ~= nil then return setting.value end
    return setting.default
end

-- shared by compositing and pointer conversion, including rounded offsets
function Policy.canvas_transform(width, height, window_w, window_h, stretch)
    local sx, sy = math.max(0.01, window_w / width), math.max(0.01, window_h / height)
    if not stretch then sx = math.min(sx, sy); sy = sx end
    local x = math.floor((window_w - width * sx) * 0.5 + 0.5)
    local y = math.floor((window_h - height * sy) * 0.5 + 0.5)
    return x, y, sx, sy
end

return Policy
