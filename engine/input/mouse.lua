local mouse = {}
mouse.position = vec2(0, 0)
mouse.wheel_dir = { 0, 0 }
mouse.state = {
    hovering = {},
    clicked = {},
    active = {},
    active_source = {},
    sb_hover_target = nil,
    last_click_target = nil,
    last_click_at = 0,
    last_click_x = 0,
    last_click_y = 0,
}
local function has_system_cursor_support()
    return not input_mgr.mobile.is_mobile
end
mouse.cursor_states = {
    idle = { system = has_system_cursor_support() and love.mouse.getSystemCursor('arrow') or nil },
    hover = { system = has_system_cursor_support() and love.mouse.getSystemCursor('hand') or nil },
    clicked = { system = has_system_cursor_support() and love.mouse.getSystemCursor('arrow') or nil },
    type = { system = has_system_cursor_support() and love.mouse.getSystemCursor('ibeam') or nil },
    resize_we = { system = has_system_cursor_support() and love.mouse.getSystemCursor('sizewe') or nil },
    resize_ns = { system = has_system_cursor_support() and love.mouse.getSystemCursor('sizens') or nil },
    resize_nesw = { system = has_system_cursor_support() and love.mouse.getSystemCursor('sizenesw') or nil },
    resize_nwse = { system = has_system_cursor_support() and love.mouse.getSystemCursor('sizenwse') or nil },
    move = { system = has_system_cursor_support() and love.mouse.getSystemCursor('sizeall') or nil }
}
mouse.cursor_state = 'idle'

mouse._offsetX, mouse._offsetY = 0, 0
mouse._scale = 1
mouse._scaleX, mouse._scaleY = 1, 1
local render_policy = require('engine/graphics/presentation')

local function get_ratio_virtual_resolution()
    return G:get_ratio_resolution()
end

function mouse.update_display_offsets()
    local ratio4by3 = G:getSetting("ratio4by3").value

    local window_w, window_h = love.graphics.getDimensions()

    if ratio4by3 then
        local virtual = get_ratio_virtual_resolution()
        mouse._offsetX, mouse._offsetY, mouse._scaleX, mouse._scaleY =
            render_policy.canvas_transform(virtual.x, virtual.y, window_w, window_h,
                G:getSetting('stretch').value)
        mouse._scale = mouse._scaleX
    else
        mouse._offsetX = 0
        mouse._offsetY = 0
        mouse._scale = 1
        mouse._scaleX, mouse._scaleY = 1, 1
    end
end

local function compute_mousepos(x, y)
    local mx, my = x or ({ love.mouse.getPosition() })[1], y or ({ love.mouse.getPosition() })[2]

    local ratio4by3 = G:getSetting("ratio4by3").value

    if ratio4by3 then
        return vec2((mx - mouse._offsetX) / mouse._scaleX, (my - mouse._offsetY) / mouse._scaleY)
    elseif input_mgr.mobile.is_mobile then
        local ww, wh = love.graphics.getDimensions()
        if ww > 0 and wh > 0 then
            local rw, rh = G.resolution.x, G.resolution.y
            if math.abs(ww - rw) > 1 or math.abs(wh - rh) > 1 then
                return vec2(mx * (rw / ww), my * (rh / wh))
            end
        end
        return vec2(mx, my)
    else
        return vec2(mx, my)
    end
end

function mouse.to_input_position(x, y)
    local pos = compute_mousepos(x, y)
    return pos.x, pos.y
end

local function is_mobile_source(source)
    return source == 'mobile'
end

local function mobile_hit_slop(source)
    if not is_mobile_source(source) then return 0 end
    return input_mgr.mobile.get_tap_slop()
end

local function mobile_release_slop(source)
    if not is_mobile_source(source) then return 0 end
    return input_mgr.mobile.get_tap_release_slop()
end

local function get_visual_rect(elem)
    if not elem then return nil end
    local opts = rawget(elem, "_tmp_visual_opts")
    if not opts then
        opts = { mode = "visual" }
        rawset(elem, "_tmp_visual_opts", opts)
    end
    return Element.get_screen_rect(elem, nil, opts)
end

local function point_in_with_slop(elem, x, y, slop)
    if not elem or not elem.point_in then return false end
    if elem:point_in(x, y) then return true end
    if not slop or slop <= 0 then return false end

    local r = get_visual_rect(elem)
    if not r then return false end

    local clip = r._clip
    if clip and (x < clip.x or x > clip.x + clip.w or y < clip.y or y > clip.y + clip.h) then
        return false
    end
    if elem._in_visible_viewports and not elem:_in_visible_viewports(x, y) then return false end

    local min_target = 56
    local pad_x = 0
    local pad_y = 0
    if r.size.x < min_target then
        pad_x = math.min(slop, (min_target - r.size.x) * 0.5)
    elseif r.size.x < 128 and r.size.y < 72 then
        pad_x = math.min(slop, 8)
    end
    if r.size.y < min_target then
        pad_y = math.min(slop, (min_target - r.size.y) * 0.5)
    elseif r.size.y < 72 and r.size.x < 160 then
        pad_y = math.min(slop, 8)
    end

    return x >= r.position.x - pad_x
        and x <= r.position.x + r.size.x + pad_x
        and y >= r.position.y - pad_y
        and y <= r.position.y + r.size.y + pad_y
end

local function update_cursor_state(new_state)
    if mouse.cursor_state == new_state then return end
    mouse.cursor_state = new_state
    local state = mouse.cursor_states[new_state]
    if state and state.system and has_system_cursor_support() and love.mouse.setCursor then
        love.mouse.setCursor(state.system)
    end
end

local function normalize_cursor_name(s)
    if not s or type(s) ~= 'string' then return nil end
    s = s:lower()
    if mouse.cursor_states[s] then return s end
    local map = {
        sizewe = 'resize_we',
        sizens = 'resize_ns',
        sizenesw = 'resize_nesw',
        sizenwse = 'resize_nwse',
        resize_we = 'resize_we',
        resize_ns = 'resize_ns',
        resize_nesw = 'resize_nesw',
        resize_nwse = 'resize_nwse',
        move = 'move'
    }
    return map[s]
end

local function check_elem_hit(elem, x, y, slop)
    -- only consider elements that are interactable and were actually drawn
    if not elem or not elem.mousecheck or not elem.visible or not elem.isdrawn then return false end
    if not point_in_with_slop(elem, x, y, slop or 0) then return false end
    -- Respect scroll/scissor clipping along ancestor chain
    if elem._in_visible_viewports and not elem:_in_visible_viewports(x, y) then return false end
    return true
end

local function find_visual_topmost(x, y)
    local function visual_hit(node)
        if not node or not node.visible or not node.isdrawn then return nil end
        local ch = Element.get_sorted_children(node.children)
        for i = #ch, 1, -1 do
            local t = visual_hit(ch[i])
            if t then return t end
        end
        if node:point_in(x, y) then
            if node._in_visible_viewports and not node:_in_visible_viewports(x, y) then
                return nil
            end
            return node
        end
        return nil
    end

    local roots = Element.get_sorted_children(AllElements)
    for i = #roots, 1, -1 do
        local r = roots[i]
        if r and r.isdrawn then
            local t = visual_hit(r)
            if t then return t end
        end
    end
    return nil
end

-- return the topmost interactive (mousecheck=true) element under the cursor,
-- but only among elements that were actually drawn this frame (isdrawn=true)
-- this prevents hidden scenes/layers from receiving hover/press
local function find_hovered_elems(x, y, slop)
    -- Deep hit test that respects visibility, viewport clipping and drawn state
    local function hit_test_deep_drawn(node, use_slop)
        if not node or not node.visible or not node.isdrawn then return nil end
        local ch = Element.get_sorted_children(node.children)
        for i = #ch, 1, -1 do
            local t = hit_test_deep_drawn(ch[i], use_slop)
            if t then return t end
        end
        if check_elem_hit(node, x, y, use_slop and slop or 0) then
            return node
        end
        return nil
    end

    local roots = Element.get_sorted_children(AllElements)
    local function scan(use_slop)
        for i = #roots, 1, -1 do
            local r = roots[i]
            if r and r.isdrawn then
                local t = hit_test_deep_drawn(r, use_slop)
                if t then return { t } end
            end
        end
    end

    local exact = scan(false)
    if exact then return exact end
    if slop and slop > 0 then
        local padded = scan(true)
        if padded then return padded end
    end

    return {}
end

local function find_topmost_scrollbar_hit_at(x, y)
    local top = nil
    local function scan_list(list)
        if not list then return end
        local sorted = Element.get_sorted_children(list)
        for i = 1, #sorted do
            local e = sorted[i]
            if e and e.visible and e.isdrawn then
                scan_list(e.children)
                if e.mousecheck and e.scroll and e.scroll.enabled and e.hit_scrollbar and e:hit_scrollbar(x, y) then
                    top = e
                end
            end
        end
    end
    scan_list(AllElements)
    return top
end

local function is_descendant(root, node)
    local p = node and node.linked
    while p do
        if p == root then return true end
        p = p.linked
    end
    return false
end

local function compute_hover_list_at(x, y, source)
    local elems = find_hovered_elems(x, y, mobile_hit_slop(source))

    local sb_target = find_topmost_scrollbar_hit_at(x, y)
    if sb_target and sb_target.no_hover and #elems > 0 then
        if is_descendant(sb_target, elems[1]) then
            elems = {}
        end
    end

    return elems, sb_target
end

local function handle_elem_hover(elems)
    for i = #mouse.state.hovering, 1, -1 do
        local elem = mouse.state.hovering[i]
        local still_hovered = false
        for _, hovered in ipairs(elems) do
            if hovered == elem then
                still_hovered = true
                break
            end
        end
        if not still_hovered then
            elem:handleInput("mouseleave")
            table.remove(mouse.state.hovering, i)
        end
    end
    for _, elem in ipairs(elems) do
        local already_hovered = false
        for _, hovered in ipairs(mouse.state.hovering) do
            if hovered == elem then
                already_hovered = true
                break
            end
        end
        if not already_hovered and not elem.no_hover then
            elem:handleInput("mouseenter")
            table.insert(mouse.state.hovering, elem)
        end
    end

    local function is_actionable(elem)
        if not elem or not elem.mousecheck or not elem.visible or not elem.isdrawn then return false end
        if elem.on_mouse_click or elem.on_mouse_clicked or elem.on_mouse_release or elem.selectable or elem.editable or elem.doubleClickEditable then
            return true
        end
        if elem.scroll and elem.scroll.enabled and elem:hit_scrollbar(mouse.position.x, mouse.position.y) then
            return true
        end
        return false
    end
    local meaningful_hover = false
    for _, elem in ipairs(mouse.state.hovering) do
        if is_actionable(elem) then
            meaningful_hover = elem; break
        end
    end
    if meaningful_hover then
        local cur = normalize_cursor_name(meaningful_hover.cursor)
        if cur then
            update_cursor_state(cur)
        else
            update_cursor_state(mouse.state.active[1] and 'clicked' or
                ((meaningful_hover.editable or meaningful_hover.doubleClickEditable) and 'type' or 'hover'))
        end
    else
        update_cursor_state(mouse.state.active[1] and 'clicked' or 'idle')
    end
end

local function handle_double_click_edit(elem, btn, x, y)
    if btn ~= 1 or not elem or not elem.doubleClickEditable then return false end
    if not elem.font then return false end

    local now = love.timer.getTime()
    local dx = (x or 0) - (mouse.state.last_click_x or 0)
    local dy = (y or 0) - (mouse.state.last_click_y or 0)
    local is_double = mouse.state.last_click_target == elem
        and (now - (mouse.state.last_click_at or 0)) >= 0.05
        and (now - (mouse.state.last_click_at or 0)) < 0.32
        and (dx * dx + dy * dy) <= 36

    mouse.state.last_click_target = elem
    mouse.state.last_click_at = now
    mouse.state.last_click_x = x or 0
    mouse.state.last_click_y = y or 0

    if not is_double then return false end

    local text = tostring(elem.text or ""):gsub("|", "")
    local idx = input_mgr.typing.compute_index_from_click(elem, x or 0, y or 0)
    input_mgr.typing.start_typing_at(elem, text, idx)
    return true
end

local function handle_elem_click(elems, btn, x, y, source)
    local function find_topmost_scrollbar_hit()
        local top = nil
        local function scan_list(list)
            if not list then return end
            local sorted = Element.get_sorted_children(list)
            for i = 1, #sorted do
                local e = sorted[i]
                if e and e.visible and e.isdrawn then
                    scan_list(e.children)
                    if e.mousecheck and e.scroll and e.scroll.enabled and e.hit_scrollbar and e:hit_scrollbar(x, y) then
                        top = e
                    end
                end
            end
        end
        scan_list(AllElements)
        return top
    end

    local target = find_topmost_scrollbar_hit()
    if not target then
        -- prefer interactive target among drawn elements
        local hovered = find_hovered_elems(x, y, mobile_hit_slop(source))
        target = hovered[1]
        if not target and #elems > 0 then target = elems[1] end
    end

    local visual_top = find_visual_topmost(x, y)
    local function is_descendant_local(root, node)
        local p = node and node.linked
        while p do
            if p == root then return true end
            p = p.linked
        end
        return false
    end
    if visual_top and target and visual_top ~= target then
        if not is_descendant_local(target, visual_top) then
            -- if the visual topmost element is interactive, prefer it
            -- if it's non-interactive, do not block clicking the underlying interactive target
            if visual_top.mousecheck then
                target = visual_top
            end
        end
    end

    local function is_interactive(e)
        return e and e.mousecheck and e.visible and e.isdrawn
            and (e.on_mouse_click or e.on_mouse_clicked or e.on_mouse_release
                or e.editable or e.selectable or e.doubleClickEditable)
    end
    local function is_descendant_local(root, node)
        return is_descendant(root, node)
    end
    if target and target.scroll and target.no_hover and not (target.hit_scrollbar and target:hit_scrollbar(x, y)) then
        for _, e in ipairs(elems) do
            if e ~= target and is_interactive(e) and is_descendant_local(target, e) then
                target = e
                break
            end
        end
        if not target or (target.scroll and target.no_hover) then
            local function hit_in_subtree(node)
                if not node or not node.visible or not node.isdrawn then return nil end
                local ch = node.children or {}
                local sorted = Element.get_sorted_children(ch)
                for i = #sorted, 1, -1 do
                    local t = hit_in_subtree(sorted[i])
                    if t then return t end
                end
                if is_interactive(node) and node:point_in(x, y) and (not node._in_visible_viewports or node:_in_visible_viewports(x, y)) then
                    return
                        node
                end
                return nil
            end
            local subpick = hit_in_subtree(target)
            if subpick then target = subpick end
        end
    end

    if target then
        target:handleInput("mouseclick", btn, x, y)
        mouse.state.clicked[target] = { button = btn, x = x, y = y, source = source }
    end

    if btn == 1 then
        local cur = target and normalize_cursor_name(target.cursor)
        if cur then
            update_cursor_state(cur)
        else
            update_cursor_state('clicked')
        end
    end
end

local function handle_elem_release(btn, x, y, source)
    for elem, click_data in pairs(mouse.state.clicked) do
        if click_data.button == btn then
            elem:handleInput("mouserelease", btn, x, y)
            local click_source = click_data.source or source
            local release_slop = mobile_release_slop(click_source)
            local dx, dy = x - (click_data.x or x), y - (click_data.y or y)
            local moved_too_far = release_slop > 0 and ((dx * dx + dy * dy) > (release_slop * release_slop))
            if not moved_too_far and check_elem_hit(elem, x, y, mobile_hit_slop(click_source)) then
                elem:handleInput("mouseclicked", btn, x, y)
                handle_double_click_edit(elem, btn, x, y)
            end
            mouse.state.clicked[elem] = nil
        end
    end
    if btn == 1 then
        local function is_actionable(elem)
            if not elem or not elem.mousecheck or not elem.visible or not elem.isdrawn then return false end
            if elem.on_mouse_click or elem.on_mouse_clicked or elem.on_mouse_release or elem.selectable or elem.editable or elem.doubleClickEditable then
                return true
            end
            if elem.scroll and elem.scroll.enabled and elem.hit_scrollbar and elem:hit_scrollbar(mouse.position.x, mouse.position.y) then
                return true
            end
            return false
        end
        local meaningful_hover = nil
        for _, elem in ipairs(mouse.state.hovering) do
            if is_actionable(elem) then
                meaningful_hover = elem; break
            end
        end
        if meaningful_hover then
            local cur = normalize_cursor_name(meaningful_hover.cursor)
            if cur then
                update_cursor_state(cur)
            else
                update_cursor_state(mouse.state.active[1] and 'clicked' or
                    ((meaningful_hover.editable or meaningful_hover.doubleClickEditable) and 'type' or 'hover'))
            end
        else
            update_cursor_state('idle')
        end
    end
end

--[[
mouse-button press bind. gameplay code registers a listener via
input_mgr.mouse.add_press_listener(fn), fn(button, x, y) fires once per press
edge (button: 1=left, 2=right, 3=middle). used e.g. to re-orient the camera on a
middle-click. errors in a listener are isolated so one bad handler can't break input
]]
mouse.press_listeners = mouse.press_listeners or {}

function mouse.add_press_listener(fn)
    if type(fn) == "function" then
        mouse.press_listeners[#mouse.press_listeners + 1] = fn
    end
    return fn
end

function mouse.remove_press_listener(fn)
    for i = #mouse.press_listeners, 1, -1 do
        if mouse.press_listeners[i] == fn then
            table.remove(mouse.press_listeners, i)
        end
    end
end

--[[
input_mgr.mouse.add_wheel_listener(fn), fn(dx, dy, x, y) fires for every wheel
event before gameplay sees it. returning true consumes the event: it is not added
to the consume_wheel accumulator or passed to scrollable elements (an open menu
scrolls instead of the camera zooming behind it)
]]
mouse.wheel_listeners = mouse.wheel_listeners or {}

function mouse.add_wheel_listener(fn)
    if type(fn) == "function" then
        mouse.wheel_listeners[#mouse.wheel_listeners + 1] = fn
    end
    return fn
end

function mouse.remove_wheel_listener(fn)
    for i = #mouse.wheel_listeners, 1, -1 do
        if mouse.wheel_listeners[i] == fn then
            table.remove(mouse.wheel_listeners, i)
        end
    end
end

--[[
mouse-look: for free-look / camera panning. uses love.mouse.setRelativeMode, which
locks the cursor in place and delivers pure relative motion through love.mousemoved
(no getPosition/setPosition round-trip, so no jitter). while active, handle_move
accumulates the raw (dx,dy) deltas and skips UI hover work (the cursor is captured)
consume_look_delta returns the accumulated motion since the last call and resets it
the OS restores the cursor to its pre-lock position when relative mode is turned off
]]
mouse.look_active = false
mouse._look_dx, mouse._look_dy = 0, 0

function mouse.set_look_active(active)
    active = active and true or false
    if active == mouse.look_active then return end
    mouse.look_active = active
    mouse._look_dx, mouse._look_dy = 0, 0

    -- Relative mode is the camera's sole pointer owner. the native cursor is
    -- hidden only while captured and immediately restored for normal UI use
    if love.mouse and love.mouse.setRelativeMode then love.mouse.setRelativeMode(active) end
    if love.mouse and love.mouse.setVisible then love.mouse.setVisible(not active) end
    if not active then
        mouse.cursor_state = nil
        update_cursor_state('idle')
    end
end

function mouse.consume_look_delta()
    local dx, dy = mouse._look_dx, mouse._look_dy
    mouse._look_dx, mouse._look_dy = 0, 0
    return dx, dy
end

--[[
per-event wheel accumulation for gameplay (e.g. camera zoom). handle_wheel adds the
vertical scroll here, consume_wheel returns the accumulated notches since the last
call and resets. separate from the UI scroll handling below
]]
mouse._wheel_accum = 0

function mouse.consume_wheel()
    local w = mouse._wheel_accum
    mouse._wheel_accum = 0
    return w
end

function mouse.handle_press(x, y, btn, source)
    mouse.state.active[btn] = true
    mouse.state.active_source[btn] = source
    mouse.position = compute_mousepos(x, y)
    input_mgr.set_input_source(source or 'keyboard')

    -- fire registered press-edge listeners (isolated so one can't break input)
    for i = 1, #mouse.press_listeners do
        local ok, err = pcall(mouse.press_listeners[i], btn, mouse.position.x, mouse.position.y)
        if not ok then
            print("mouse press listener error: " .. tostring(err))
        end
    end

    local elems = compute_hover_list_at(mouse.position.x, mouse.position.y, source)

    if input_mgr.state.typing and not input_mgr.is_flyout then
        local clicking_editable = false
        for _, elem in ipairs(elems) do
            if elem.editable and btn == 1 then
                clicking_editable = true
                break
            end
        end
        if not clicking_editable then input_mgr.typing.stop_typing() end
    end

    handle_elem_click(elems, btn, mouse.position.x, mouse.position.y, source)
    do
        local new_elems = compute_hover_list_at(mouse.position.x, mouse.position.y, source)
        handle_elem_hover(new_elems)
    end
    -- a synthetic mobile mouse event exists only for legacy mouse-driven UI
    -- Gameplay gets explicit touch controls, mapping every camera tap to mouse1
    -- caused accidental attacks and other desktop actions
    if source ~= 'mobile' then
        input_mgr.controller.handle_key_press('mouse' .. btn)
    end
end

function mouse.handle_release(x, y, btn, source)
    source = source or mouse.state.active_source[btn]
    mouse.state.active[btn] = nil
    mouse.state.active_source[btn] = nil
    mouse.position = compute_mousepos(x, y)
    do
        local new_elems = compute_hover_list_at(mouse.position.x, mouse.position.y, source)
        handle_elem_hover(new_elems)
    end
    handle_elem_release(btn, mouse.position.x, mouse.position.y, source)
    if source ~= 'mobile' then
        input_mgr.controller.handle_key_release('mouse' .. btn)
    end
end

function mouse.handle_move(x, y, dx, dy, source)
    dx, dy = dx or 0, dy or 0
    -- while looking (relative mode) the cursor is captured: accumulate the raw delta and
    -- skip UI hover hit-testing entirely (nothing is hoverable and it is not cheap)
    if mouse.look_active then
        mouse._look_dx = mouse._look_dx + dx
        mouse._look_dy = mouse._look_dy + dy
        return
    end
    mouse.position = compute_mousepos(x, y)
    if (math.abs(dx) > 2 or math.abs(dy) > 2) then input_mgr.set_input_source(source or 'keyboard') end
    local elems, sb_target = compute_hover_list_at(mouse.position.x, mouse.position.y, source)

    handle_elem_hover(elems)
    local dispatched = {}
    for _, elem in ipairs(elems) do
        if elem.mousecheck and (elem.on_mouse_move or (elem.scroll and elem.scroll.enabled)) then
            dispatched[elem] = true
            elem:handleInput("mousemove", mouse.position.x, mouse.position.y, dx, dy)
        end
    end

    if sb_target and not dispatched[sb_target] then
        sb_target:handleInput("mousemove", mouse.position.x, mouse.position.y, dx, dy)
        dispatched[sb_target] = true
    end

    do
        local prev = mouse.state.sb_hover_target
        if prev and prev ~= sb_target and not dispatched[prev] and not mouse.state.clicked[prev] then
            local sc = prev.scroll
            if sc and sc.enabled and (sc._hover_vert or sc._hover_horz) then
                sc._hover_vert = nil
                sc._hover_horz = nil
                if prev.mark_dirty then prev:mark_dirty() end
            end
        end
        mouse.state.sb_hover_target = sb_target
    end

    for elem, click_data in pairs(mouse.state.clicked) do
        if elem.isdrawn and (elem.on_mouse_move or (elem.scroll and elem.scroll.enabled)) and not dispatched[elem] then
            elem:handleInput("mousemove", mouse.position.x, mouse.position.y, dx, dy)
        end
    end
end

function mouse.handle_wheel(x, y)
    mouse.wheel_dir = { x, y }
    for i = #mouse.wheel_listeners, 1, -1 do
        local ok, consumed = pcall(mouse.wheel_listeners[i], x, y, mouse.position and mouse.position.x, mouse.position and mouse.position.y)
        if not ok then
            print("mouse wheel listener error: " .. tostring(consumed))
        elseif consumed then
            return
        end
    end
    mouse._wheel_accum = mouse._wheel_accum + (y or 0)
    local visual_top = find_visual_topmost(mouse.position.x, mouse.position.y)
    local p = visual_top
    while p do
        if p.scroll and p.scroll.enabled then
            p:scrollBy(0, -y * 40)
            return
        end
        p = p.linked
    end
    local hovered = find_hovered_elems(mouse.position.x, mouse.position.y)
    for _, elem in ipairs(hovered) do
        if elem.scroll and elem.scroll.enabled then
            elem:scrollBy(0, -y * 40)
            break
        end
    end
end

function mouse.is_hovering_elem(elem)
    for _, hovered in ipairs(mouse.state.hovering) do
        if hovered == elem then return true end
    end
    return false
end

function mouse.update()
    if mouse.look_active then return end
    mouse.position = compute_mousepos()
    local elems = compute_hover_list_at(mouse.position.x, mouse.position.y)
    handle_elem_hover(elems)
end

return mouse
