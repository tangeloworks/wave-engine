local mobile = {}

mobile.is_mobile = (G.system == 'Android' or G.system == 'iOS')
mobile.touch_points = {}
mobile.touch_captures = {}
mobile.primary_touch_id = nil

function mobile.get_tap_slop()
    return 24
end

function mobile.get_tap_release_slop()
    return 36
end

function mobile.get_drag_slop()
    return 10
end

function mobile.normalize_touch_position(x, y, dx, dy)
    local ww, wh = love.graphics.getDimensions()

    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 and ww > 1 and wh > 1 then
        x, y = x * ww, y * wh
        if dx then dx = dx * ww end
        if dy then dy = dy * wh end
    end

    return x, y, dx, dy
end

local function touch_distance_from_start(pt, x, y)
    if not pt then return 0 end
    local sx, sy = pt.start_x or pt.x or x, pt.start_y or pt.y or y
    local dx, dy = (x or sx) - sx, (y or sy) - sy
    return math.sqrt(dx * dx + dy * dy)
end

local function to_input_position(x, y)
    return input_mgr.mouse.to_input_position(x, y)
end

local function is_point_in_elem(elem, x, y)
    if not elem.visible or elem.isdrawn == false or not elem.point_in then return false end
    if elem._in_visible_viewports and not elem:_in_visible_viewports(x, y) then return false end
    return elem:point_in(x, y)
end

local function touch_handler_for(elem, action)
    if action == 'pressed' then return elem.on_touch_press end
    if action == 'moved' then return elem.on_touch_move end
    if action == 'released' then return elem.on_touch_release end
    return nil
end

local function collect_touch_targets(action, x, y)
    local function scan(elem)
        if not elem or not elem.visible or elem.isdrawn == false then return nil end

        -- only the visually topmost touch target receives the gesture. Sending
        -- one tap to every overlapping registered element was able to trigger
        -- stale menu buttons behind the game
        local children = elem.children or {}
        local sorted = Element.get_sorted_children(children)
        for i = #sorted, 1, -1 do
            local target = scan(sorted[i])
            if target then return target end
        end

        -- mousecheck-only elements still block lower touch controls. the
        -- primary finger is forwarded through the legacy mouse path below so
        -- mouse-only widgets remain clickable without touch-through
        if (touch_handler_for(elem, action) or elem.mousecheck)
            and is_point_in_elem(elem, x, y) then
            return elem
        end
        return nil
    end

    local roots = Element.get_sorted_children(AllElements)
    for i = #roots, 1, -1 do
        local target = scan(roots[i])
        if target then return { target } end
    end
    return {}
end

-- Innermost/topmost scrolling frame under a point. Touches that begin here are
-- deferred until release so a drag can scroll without activating a child row
local function find_scroll_target(x, y)
    local function scan(elem)
        if not elem or not elem.visible or elem.isdrawn == false then return nil end
        if elem._in_visible_viewports and not elem:_in_visible_viewports(x, y) then return nil end

        local children = Element.get_sorted_children(elem.children or {})
        for i = #children, 1, -1 do
            local target = scan(children[i])
            if target then return target end
        end

        local sc = elem.scroll
        if sc and sc.enabled and is_point_in_elem(elem, x, y) then return elem end
        return nil
    end

    local roots = Element.get_sorted_children(AllElements)
    for i = #roots, 1, -1 do
        local target = scan(roots[i])
        if target then return target end
    end
    return nil
end

local function dispatch_to_targets(targets, action, x, y, id, ...)
    local handled = false
    for _, elem in ipairs(targets or {}) do
        if elem and elem.visible then
            local handler = touch_handler_for(elem, action)
            if handler then
                handler(elem, id, x, y, ...)
                handled = true
            end
        end
    end
    return handled
end

local function dispatch_touch_callbacks(action, x, y, id, ...)
    if action == 'pressed' then
        local targets = collect_touch_targets(action, x, y)
        if #targets > 0 then
            mobile.touch_captures[id] = targets
        end
        return dispatch_to_targets(targets, action, x, y, id, ...)
    end

    local captured = mobile.touch_captures[id]
    if captured and #captured > 0 then
        return dispatch_to_targets(captured, action, x, y, id, ...)
    end

    local targets = collect_touch_targets(action, x, y)
    return dispatch_to_targets(targets, action, x, y, id, ...)
end

function mobile.handle_touch_press(id, x, y, dx, dy, pressure)
    x, y, dx, dy = mobile.normalize_touch_position(x, y, dx, dy)
    local ix, iy = to_input_position(x, y)
    local pt = {
        x = x,
        y = y,
        input_x = ix,
        input_y = iy,
        start_x = x,
        start_y = y,
        start_input_x = ix,
        start_input_y = iy,
        start_time = love.timer.getTime(),
        sent_mouse_move = false,
        handled_by_touch = false,
    }
    mobile.touch_points[id] = pt

    local targets = collect_touch_targets('pressed', ix, iy)
    local scroll_target = find_scroll_target(ix, iy)
    local touch_dispatched = false
    local claimed
    if scroll_target then
        pt.scroll_capture = {
            target = scroll_target,
            targets = targets,
            last_x = ix,
            last_y = iy,
            dragged = false,
        }
        mobile.touch_captures[id] = targets
        claimed = true
    else
        if #targets > 0 then mobile.touch_captures[id] = targets end
        touch_dispatched = dispatch_to_targets(targets, 'pressed', ix, iy, id, dx, dy, pressure)
        claimed = #targets > 0
    end
    pt.handled_by_touch = claimed

    -- Blank camera space and mouse-only legacy widgets use one synthetic mouse
    -- stream. explicit touch controls and scroll captures never do
    if mobile.primary_touch_id == nil then
        mobile.primary_touch_id = id
        if not scroll_target and not touch_dispatched then
            pt.synthetic_mouse = true
            input_mgr.mouse.handle_press(x, y, 1, 'mobile')
        end
    end
end

function mobile.handle_touch_move(id, x, y, dx, dy, pressure)
    x, y, dx, dy = mobile.normalize_touch_position(x, y, dx, dy)
    local ix, iy = to_input_position(x, y)
    local pt = mobile.touch_points[id]
    if pt then
        dx = x - pt.x
        dy = y - pt.y
        pt.x = x
        pt.y = y
        pt.input_x = ix
        pt.input_y = iy
    end
    if G:halted() and not (pt and pt.handled_by_touch) then
        mobile.handle_touch_release(id, x, y, dx, dy, pressure)
        return
    end

    local scroll_capture = pt and pt.scroll_capture
    if scroll_capture then
        local sx, sy = pt.start_input_x or ix, pt.start_input_y or iy
        local ox, oy = ix - sx, iy - sy
        if not scroll_capture.dragged
            and math.sqrt(ox * ox + oy * oy) >= mobile.get_drag_slop() then
            scroll_capture.dragged = true
        end
        if scroll_capture.dragged then
            local ddx = ix - (scroll_capture.last_x or ix)
            local ddy = iy - (scroll_capture.last_y or iy)
            local target = scroll_capture.target
            if target and target.visible and target.scrollBy then
                target:scrollBy(-ddx, -ddy, true)
            end
        end
        scroll_capture.last_x, scroll_capture.last_y = ix, iy
        return
    end

    dispatch_touch_callbacks('moved', ix, iy, id, dx, dy, pressure)

    if id == mobile.primary_touch_id and pt and pt.synthetic_mouse then
        local moved = touch_distance_from_start(pt, x, y)
        if moved >= mobile.get_drag_slop() or (pt and pt.sent_mouse_move) then
            if pt then pt.sent_mouse_move = true end
            input_mgr.mouse.handle_move(x, y, dx, dy, 'mobile')
        end
    end
end

function mobile.handle_touch_release(id, x, y, dx, dy, pressure)
    x, y, dx, dy = mobile.normalize_touch_position(x, y, dx, dy)
    local ix, iy = to_input_position(x, y)
    local pt = mobile.touch_points[id]

    local scroll_capture = pt and pt.scroll_capture
    if scroll_capture then
        if not scroll_capture.dragged then
            dispatch_to_targets(scroll_capture.targets, 'pressed', ix, iy, id, dx, dy, pressure)
            dispatch_to_targets(scroll_capture.targets, 'released', ix, iy, id, dx, dy, pressure)
        end
    else
        dispatch_touch_callbacks('released', ix, iy, id, dx, dy, pressure)
    end

    if id == mobile.primary_touch_id then
        if pt and pt.synthetic_mouse then
            local release_x, release_y = x, y
            if pt and touch_distance_from_start(pt, x, y) <= mobile.get_tap_release_slop() then
                release_x = pt.start_x or x
                release_y = pt.start_y or y
            end
            input_mgr.mouse.handle_release(release_x, release_y, 1, 'mobile')
        end
        mobile.primary_touch_id = nil
    end

    mobile.touch_points[id] = nil
    mobile.touch_captures[id] = nil
end

--[[
===================== editable button layout =====================

projects register their on-screen buttons (thumbstick pad, jump button, ...)
here, the registry applies the user's saved position/size on top of the
project's defaults and the layout editor (engine/input/mobile_layout_editor)
lets the user drag/resize them. layout entries are stored per button id as
{ cx, cy, scale }: normalized screen center (0..1 of the root resolution, so
they survive resolution changes) plus a size multiplier on the button's base
size. persistence rides input_mgr.bindings (input_bindings.cfg)
]]

mobile.layout_buttons = {}      -- id -> { elem, base_w, base_h, def_cx, def_cy, label }
mobile.MIN_BUTTON_SCALE = 0.5
mobile.MAX_BUTTON_SCALE = 2.5

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- effective layout of a registered button: saved entry or the project default
function mobile.get_button_layout(id)
    local reg = mobile.layout_buttons[id]
    if not reg then return nil end
    local saved = input_mgr.bindings and input_mgr.bindings.get_button_layout(id)
    local cx = saved and saved.cx or reg.def_cx
    local cy = saved and saved.cy or reg.def_cy
    local scale = clamp(saved and saved.scale or 1, mobile.MIN_BUTTON_SCALE, mobile.MAX_BUTTON_SCALE)
    return cx, cy, scale
end

-- write the layout onto the element as centered scale-position + pixel size
function mobile.apply_button_layout(id)
    local reg = mobile.layout_buttons[id]
    if not reg or not reg.elem then return end
    local cx, cy, scale = mobile.get_button_layout(id)
    local w, h = reg.base_w * scale, reg.base_h * scale
    reg.elem.position = { scale = vec2(cx, cy), offset = vec2(-w * 0.5, -h * 0.5) }
    reg.elem.size = { scale = vec2(0, 0), offset = vec2(w, h) }
end

--[[
register a button for layout editing. opts:
  base_size = {x=w, y=h}   unscaled pixel size (required)
  default_center = {x, y}  normalized 0..1 default center (required)
  label                    editor caption (defaults to id)
registering immediately applies the saved/default layout to the element
]]
function mobile.register_layout_button(id, elem, opts)
    mobile.layout_buttons[id] = {
        elem = elem,
        base_w = opts.base_size.x,
        base_h = opts.base_size.y,
        def_cx = opts.default_center.x,
        def_cy = opts.default_center.y,
        label = opts.label or id,
    }
    mobile.apply_button_layout(id)
end

function mobile.unregister_layout_button(id)
    mobile.layout_buttons[id] = nil
end

-- move/resize a button (from the editor) and persist
function mobile.set_button_layout(id, cx, cy, scale)
    local reg = mobile.layout_buttons[id]
    if not reg then return end
    scale = clamp(scale or 1, mobile.MIN_BUTTON_SCALE, mobile.MAX_BUTTON_SCALE)
    cx = clamp(cx, 0, 1)
    cy = clamp(cy, 0, 1)
    if input_mgr.bindings then
        input_mgr.bindings.set_button_layout(id, cx, cy, scale)
    end
    mobile.apply_button_layout(id)
end

function mobile.reset_button_layouts()
    if input_mgr.bindings then
        input_mgr.bindings.clear_button_layout(nil)
    end
    for id in pairs(mobile.layout_buttons) do
        mobile.apply_button_layout(id)
    end
end

-- layout editor overlay (lazy: ui built on first open). works with mouse or touch
function mobile.open_layout_editor()
    if not mobile.layout_editor then
        mobile.layout_editor = require "engine/input/mobile_layout_editor"
    end
    mobile.layout_editor.open()
end

function mobile.is_point_touched(x, y, radius)
    radius = radius or 50
    for id, pt in pairs(mobile.touch_points) do
        local dist = math.sqrt((pt.x - x) ^ 2 + (pt.y - y) ^ 2)
        if dist <= radius then return true, id, pt end
    end
    return false
end

function mobile.detect_swipe(id, min_dist, max_time)
    local pt = mobile.touch_points[id]
    if not pt then return nil end
    local now = love.timer.getTime()
    local tdiff = now - pt.start_time
    if tdiff > (max_time or 1.0) then return nil end
    local sx, sy = pt.start_x or pt.x, pt.start_y or pt.y
    local dx, dy = pt.x - sx, pt.y - sy
    local dist = math.sqrt(dx ^ 2 + dy ^ 2)
    if dist < (min_dist or 100) then return nil end
    local angle = math.atan2(dy, dx)
    local dir = ""
    if angle >= -math.pi / 4 and angle < math.pi / 4 then
        dir = "right"
    elseif angle >= math.pi / 4 and angle < 3 * math.pi / 4 then
        dir = "down"
    elseif angle >= -3 * math.pi / 4 and angle < -math.pi / 4 then
        dir = "up"
    else
        dir = "left"
    end
    return {
        direction = dir,
        distance = dist,
        duration = tdiff,
        velocity = dist / tdiff
    }
end

return mobile
