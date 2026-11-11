--[[
keybind settings overlay (opened with the 'rebind_menu' action, default F6 /
left-stick click, or input_mgr.open_rebind_menu())

per action: click the keyboard or gamepad cell, then press the new key/button
(escape cancels, mouse2+ can be bound, mouse1 stays the ui click). the mode
cell cycles hold -> toggle -> disabled. everything persists immediately via
input_mgr.bindings. the footer opens the mobile button layout editor
]]

local ui = {}

local bindings -- input_mgr.bindings, resolved on build

local built = false
local open = false
local root, panel, list
local rows = {} -- action name -> { kb_label, joy_label, mode_label }
local capturing = nil -- { action, device }

local ROW_H = 34
local PANEL_W = 660

local COL = {
    title = { x = 16, w = 190 },
    kb    = { x = 214, w = 150 },
    joy   = { x = 372, w = 130 },
    mode  = { x = 510, w = 92 },
    reset = { x = 610, w = 34 },
}

local function label_for(action, device)
    if capturing and capturing.action == action and capturing.device == device then
        return "press..."
    end
    return bindings.binding_label(bindings.get_binding(action, device))
end

local function refresh()
    for action, row in pairs(rows) do
        row.kb_label.text = label_for(action, 'keyboard')
        row.joy_label.text = label_for(action, 'joy')
        row.mode_label.text = bindings.mode_of(action)
    end
end

local function start_capture(action, device)
    if bindings.capture_active() then
        bindings.cancel_capture()
    end
    capturing = { action = action, device = device }
    bindings.begin_capture(device, function(key)
        capturing = nil
        if key then
            bindings.rebind(action, device, key)
        end
        refresh()
    end)
    refresh()
end

local function cell(parent, name, x, y, w, h, click)
    return parent:add(Element {
        name = name,
        position = { offset = vec2(x, y) },
        size = { offset = vec2(w, h) },
        zindex = 103,
        mousecheck = click ~= nil,
        show_fill = true,
        show_outline = true,
        fill_color = { 0.15, 0.18, 0.22, 0.95 },
        outline_color = { 0.45, 0.55, 0.64, 0.7 },
        outline_thickness = 1,
        on_mouse_clicked = click and function(_, btn) if btn == 1 then click() end end or nil,
        on_touch_press = click and function() click() end or nil,
    })
end

local function cell_text(parent, name, text, size)
    return parent:add(Text {
        name = name,
        text = text,
        position = { offset = vec2(0, 0) },
        size = { scale = vec2(1, 1) },
        zindex = 104,
        fontSize = size or 14,
        textAlignX = "center",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.93, 0.96, 1.0, 1 },
    })
end

local function build_row(mapping, index)
    local y = (index - 1) * ROW_H
    local action = mapping.name

    list:add(Text {
        name = "rebind_title_" .. action,
        text = mapping.title or action,
        position = { offset = vec2(COL.title.x, y) },
        size = { offset = vec2(COL.title.w, ROW_H) },
        zindex = 103,
        fontSize = 14,
        textAlignX = "left",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.82, 0.87, 0.92, 1 },
    })

    local kb = cell(list, "rebind_kb_" .. action, COL.kb.x, y + 4, COL.kb.w, ROW_H - 8, function()
        start_capture(action, 'keyboard')
    end)
    local joy = cell(list, "rebind_joy_" .. action, COL.joy.x, y + 4, COL.joy.w, ROW_H - 8, function()
        start_capture(action, 'joy')
    end)

    local row = {
        kb_label = cell_text(kb, "rebind_kb_label_" .. action, "", 13),
        joy_label = cell_text(joy, "rebind_joy_label_" .. action, "", 13),
    }

    -- the menu-toggle action keeps 'hold' so the menu can never lock itself out
    if action ~= 'rebind_menu' then
        local mode = cell(list, "rebind_mode_" .. action, COL.mode.x, y + 4, COL.mode.w, ROW_H - 8, function()
            bindings.cycle_mode(action)
            refresh()
        end)
        row.mode_label = cell_text(mode, "rebind_mode_label_" .. action, "hold", 13)
    else
        row.mode_label = cell_text(list, "rebind_mode_label_" .. action, "", 13) -- inert placeholder
        row.mode_label.visible = false
    end

    local reset = cell(list, "rebind_reset_" .. action, COL.reset.x, y + 4, COL.reset.w, ROW_H - 8, function()
        bindings.reset_action(action)
        refresh()
    end)
    cell_text(reset, "rebind_reset_label_" .. action, "R", 13)

    rows[action] = row
end

local function footer_button(name, label, x_off, w, click)
    local btn = cell(panel, name, 0, 0, w, 34, click)
    btn.position = { scale = vec2(1, 1), offset = vec2(x_off, -46) }
    cell_text(btn, name .. "_label", label, 15)
    return btn
end

local function build()
    bindings = input_mgr.bindings

    root = Element {
        name = "rebind_ui",
        visible = false,
        position = { offset = vec2(0, 0) },
        size = { scale = vec2(1, 1) },
        zindex = 100,
        mousecheck = true, -- swallow clicks under the overlay
        show_fill = true,
        fill_color = { 0.03, 0.04, 0.05, 0.55 },
    }

    local row_count = #input_mgr.key_mappings
    panel = root:add(Element {
        name = "rebind_panel",
        position = { scale = vec2(0.5, 0.5) },
        anchor = { scale = vec2(0.5, 0.5) },
        size = { scale = vec2(0, 0.9), offset = vec2(PANEL_W, 0) },
        zindex = 101,
        show_fill = true,
        show_outline = true,
        fill_color = { 0.09, 0.11, 0.14, 0.97 },
        outline_color = { 0.55, 0.68, 0.78, 0.75 },
        outline_thickness = 2,
    })

    panel:add(Text {
        name = "rebind_heading",
        text = "KEYBINDS",
        position = { offset = vec2(0, 10) },
        size = { scale = vec2(1, 0), offset = vec2(0, 30) },
        zindex = 102,
        fontSize = 22,
        textAlignX = "center",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.95, 0.97, 1.0, 1 },
    })
    panel:add(Text {
        name = "rebind_columns",
        text = "action                              keyboard              gamepad          mode        reset",
        position = { offset = vec2(16, 44) },
        size = { scale = vec2(1, 0), offset = vec2(-32, 18) },
        zindex = 102,
        fontSize = 12,
        textAlignX = "left",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.6, 0.68, 0.75, 1 },
    })

    list = panel:add(Element {
        name = "rebind_list",
        position = { offset = vec2(0, 66) },
        size = { scale = vec2(1, 1), offset = vec2(0, -66 - 56) },
        zindex = 102,
        mousecheck = true,
        scissor = true,
        -- force the scissor clip path: the auto cached-canvas promotion draws
        -- scroll children double-offset (parent-rect version collision)
        clip_mode = 'scissor',
        scroll = {
            enabled = true,
            vertical = true,
            canvasSize = { offset = vec2(PANEL_W, row_count * ROW_H + 8) },
        },
    })

    for index, mapping in ipairs(input_mgr.key_mappings) do
        build_row(mapping, index)
    end

    footer_button("rebind_mobile_layout", "Mobile Layout...", -640, 170, function()
        ui.close()
        input_mgr.mobile.open_layout_editor()
    end)
    footer_button("rebind_reset_all", "Reset All", -460, 120, function()
        bindings.reset_all()
        refresh()
    end)
    footer_button("rebind_close", "Close", -330, 120, function()
        ui.close()
    end)
    panel:add(Text {
        name = "rebind_hint",
        text = "click a cell, then press the new key/button. esc cancels. mode: hold / toggle / disabled.",
        position = { scale = vec2(0, 1), offset = vec2(16, -70) },
        size = { scale = vec2(1, 0), offset = vec2(-32, 16) },
        zindex = 102,
        fontSize = 11,
        textAlignX = "left",
        textAlignY = "center",
        textScaled = false,
        clayWrap = false,
        textColor = { 0.6, 0.68, 0.75, 1 },
    })

    G.pipeline:register('draw', 'rebind_ui', function()
        if open and root then
            love.graphics.push("all")
            love.graphics.origin()
            love.graphics.setShader()
            root:draw()
            love.graphics.pop()
        end
    end, { priority = 1, after = 'letterbox' })
    G.pipeline:register('update', 'rebind_ui', function(dt)
        if open and root then
            root:update(dt)
        end
    end, 1)

    built = true
end

function ui.open()
    if not built then build() end
    open = true
    root.visible = true
    refresh()
end

function ui.close()
    if bindings and bindings.capture_active() then
        bindings.cancel_capture()
    end
    capturing = nil
    open = false
    if root then root.visible = false end
end

function ui.toggle()
    if open then ui.close() else ui.open() end
end

function ui.is_open()
    return open
end

return ui
