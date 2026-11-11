--[[
drag/resize editor for the registered mobile buttons (engine/input/mobile.lua
layout registry). works with mouse or touch, so layouts can be edited on
desktop too. for every registered button a ghost proxy is shown: drag its body
to move, drag the corner handle to resize. changes apply to the live element
immediately and persist (via input_mgr.bindings) when the drag ends
]]

local editor = {}

local mobile -- set on first open (require cycle guard: mobile requires this module lazily)

local open = false
local built = false
local root, hint_text
local proxies = {} -- id -> { elem, handle, label_text }
local drag = nil   -- { id, mode='move'|'resize', pointer='mouse'|touch id }

local HANDLE = 26
local PANEL_BG = { 0.07, 0.09, 0.11, 0.55 }

local function res()
    return G.resolution.x, G.resolution.y
end

-- current pixel rect of a button from its layout values
local function layout_rect(id)
    local cx, cy, scale = mobile.get_button_layout(id)
    local reg = mobile.layout_buttons[id]
    local rw, rh = res()
    local w, h = reg.base_w * scale, reg.base_h * scale
    return cx * rw - w * 0.5, cy * rh - h * 0.5, w, h, cx, cy, scale
end

local function apply_proxy_rect(id)
    local proxy = proxies[id]
    if not proxy then return end
    local x, y, w, h = layout_rect(id)
    proxy.elem.position = { scale = vec2(0, 0), offset = vec2(x, y) }
    proxy.elem.size = { scale = vec2(0, 0), offset = vec2(w, h) }
end

-- live-move a button without saving (saved on drag end). px/py is the pointer;
-- the grab offset recorded at drag start keeps the button from jumping
local function move_to(id, px, py)
    local reg = mobile.layout_buttons[id]
    if not reg then return end
    local rw, rh = res()
    local cx = (px - (drag.grab_dx or 0)) / rw
    local cy = (py - (drag.grab_dy or 0)) / rh
    if cx < 0 then cx = 0 elseif cx > 1 then cx = 1 end
    if cy < 0 then cy = 0 elseif cy > 1 then cy = 1 end
    local _, _, saved_scale = mobile.get_button_layout(id)
    local entry = input_mgr.bindings and input_mgr.bindings.mobile_layout[id]
    if entry then
        entry.cx, entry.cy = cx, cy
    else
        input_mgr.bindings.mobile_layout[id] = { cx = cx, cy = cy, scale = saved_scale }
    end
    mobile.apply_button_layout(id)
    apply_proxy_rect(id)
end

local function resize_to(id, px, py)
    local reg = mobile.layout_buttons[id]
    if not reg then return end
    local rw, rh = res()
    local cx, cy, _ = mobile.get_button_layout(id)
    local half_dx = math.abs(px - cx * rw)
    local half_dy = math.abs(py - cy * rh)
    local sx = (half_dx * 2) / reg.base_w
    local sy = (half_dy * 2) / reg.base_h
    local scale = math.max(sx, sy)
    if scale < mobile.MIN_BUTTON_SCALE then scale = mobile.MIN_BUTTON_SCALE end
    if scale > mobile.MAX_BUTTON_SCALE then scale = mobile.MAX_BUTTON_SCALE end
    drag.cx, drag.cy, drag.scale = cx, cy, scale
    local entry = input_mgr.bindings and input_mgr.bindings.mobile_layout[id]
    if entry then
        entry.scale = scale
    else
        input_mgr.bindings.mobile_layout[id] = { cx = cx, cy = cy, scale = scale }
    end
    mobile.apply_button_layout(id)
    apply_proxy_rect(id)
end

local function end_drag()
    if not drag then return end
    local id = drag.id
    local cx, cy, scale = mobile.get_button_layout(id)
    drag = nil
    mobile.set_button_layout(id, cx, cy, scale) -- persists
end

local function make_button(parent, name, label, x_off, w, click)
    local btn = parent:add(Element {
        name = name,
        position = { scale = vec2(1, 0), offset = vec2(x_off, 14) },
        size = { offset = vec2(w, 34) },
        zindex = 96,
        mousecheck = true,
        show_fill = true,
        show_outline = true,
        fill_color = { 0.16, 0.20, 0.24, 0.92 },
        outline_color = { 0.65, 0.78, 0.86, 0.8 },
        outline_thickness = 2,
        on_mouse_clicked = function() click() end,
        on_touch_press = function() click() end,
    })
    btn:add(Text {
        name = name .. "_label",
        text = label,
        position = { scale = vec2(0, 0) },
        size = { scale = vec2(1, 1) },
        zindex = 97,
        fontSize = 15,
        textAlignX = "center",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.94, 0.97, 1.0, 1 },
    })
    return btn
end

local function make_proxy(id)
    local reg = mobile.layout_buttons[id]
    local proxy = { }
    proxy.elem = root:add(Element {
        name = "layout_proxy_" .. id,
        zindex = 92,
        mousecheck = true,
        show_fill = false,
        show_outline = false,
        cursor = 'move',
        on_draw = function(self, size)
            local editing = drag and drag.id == id
            love.graphics.setColor(0.30, 0.75, 0.95, editing and 0.30 or 0.16)
            love.graphics.rectangle("fill", 0, 0, size.x, size.y, 8, 8)
            love.graphics.setColor(0.55, 0.90, 1.0, editing and 1.0 or 0.75)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 1, 1, size.x - 2, size.y - 2, 8, 8)
            -- corner resize handle
            love.graphics.setColor(0.95, 0.85, 0.35, 0.95)
            love.graphics.rectangle("fill", size.x - HANDLE, size.y - HANDLE, HANDLE, HANDLE, 4, 4)
            love.graphics.setColor(0.25, 0.2, 0.05, 1)
            love.graphics.setLineWidth(1)
            love.graphics.line(size.x - HANDLE * 0.65, size.y - 6, size.x - 6, size.y - HANDLE * 0.65)
            love.graphics.line(size.x - HANDLE * 0.4, size.y - 6, size.x - 6, size.y - HANDLE * 0.4)
            love.graphics.setColor(1, 1, 1, 1)
        end,
        on_mouse_click = function(self, btn, x, y)
            if btn ~= 1 then return end
            local rect = self:get_screen_rect()
            local mode = (x >= rect.position.x + rect.size.x - HANDLE
                and y >= rect.position.y + rect.size.y - HANDLE) and 'resize' or 'move'
            local ccx = rect.position.x + rect.size.x * 0.5
            local ccy = rect.position.y + rect.size.y * 0.5
            drag = { id = id, mode = mode, pointer = 'mouse', grab_dx = x - ccx, grab_dy = y - ccy }
        end,
        on_mouse_move = function(self, x, y)
            if drag and drag.id == id and drag.pointer == 'mouse' then
                if drag.mode == 'move' then move_to(id, x, y) else resize_to(id, x, y) end
            end
        end,
        on_mouse_release = function()
            if drag and drag.id == id and drag.pointer == 'mouse' then end_drag() end
        end,
        on_touch_press = function(self, tid, x, y)
            if drag then return end
            local rect = self:get_screen_rect()
            local mode = (x >= rect.position.x + rect.size.x - HANDLE
                and y >= rect.position.y + rect.size.y - HANDLE) and 'resize' or 'move'
            local ccx = rect.position.x + rect.size.x * 0.5
            local ccy = rect.position.y + rect.size.y * 0.5
            drag = { id = id, mode = mode, pointer = tid, grab_dx = x - ccx, grab_dy = y - ccy }
        end,
        on_touch_move = function(self, tid, x, y)
            if drag and drag.id == id and drag.pointer == tid then
                if drag.mode == 'move' then move_to(id, x, y) else resize_to(id, x, y) end
            end
        end,
        on_touch_release = function(self, tid)
            if drag and drag.id == id and drag.pointer == tid then end_drag() end
        end,
    })
    proxy.elem:add(Text {
        name = "layout_proxy_label_" .. id,
        text = mobile.layout_buttons[id].label,
        position = { scale = vec2(0, 0) },
        size = { scale = vec2(1, 1) },
        zindex = 93,
        fontSize = 14,
        textAlignX = "center",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.95, 0.99, 1.0, 0.9 },
    })
    proxies[id] = proxy
    apply_proxy_rect(id)
end

local function build()
    root = Element {
        name = "mobile_layout_editor",
        visible = false,
        position = { offset = vec2(0, 0) },
        size = { scale = vec2(1, 1) },
        zindex = 90,
        mousecheck = true, -- backdrop swallows stray clicks
        show_fill = true,
        fill_color = PANEL_BG,
    }
    hint_text = root:add(Text {
        name = "layout_editor_hint",
        text = "MOBILE BUTTON LAYOUT  --  drag a button to move it, drag the yellow corner to resize",
        position = { offset = vec2(18, 18) },
        size = { scale = vec2(1, 0), offset = vec2(-320, 40) },
        zindex = 95,
        fontSize = 16,
        textAlignX = "left",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.95, 0.97, 1.0, 1 },
    })
    make_button(root, "layout_editor_reset", "Reset", -300, 120, function()
        mobile.reset_button_layouts()
        for id in pairs(proxies) do apply_proxy_rect(id) end
    end)
    make_button(root, "layout_editor_done", "Done", -160, 120, function()
        editor.close()
    end)

    G.pipeline:register('draw', 'mobile_layout_editor', function()
        if open and root then
            love.graphics.push("all")
            love.graphics.origin()
            love.graphics.setShader()
            root:draw()
            love.graphics.pop()
        end
    end, { priority = 1, after = 'letterbox' })

    built = true
end

function editor.open()
    mobile = input_mgr.mobile
    if not built then build() end
    -- (re)create proxies so late-registered buttons appear
    for id, proxy in pairs(proxies) do
        proxy.elem:remove()
        proxies[id] = nil
    end
    for id in pairs(mobile.layout_buttons) do
        make_proxy(id)
    end
    open = true
    root.visible = true
end

function editor.close()
    end_drag()
    open = false
    if root then root.visible = false end
end

function editor.is_open()
    return open
end

return editor
