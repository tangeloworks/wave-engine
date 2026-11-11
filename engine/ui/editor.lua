-- the preview uses real UI elements so the same layout can be exported as Lua
local utf8_ok, utf8 = pcall(require, "utf8")

local Editor = {}

local COLORS = {
    bg = { 0.09, 0.095, 0.11, 1 },
    panel = { 0.125, 0.13, 0.15, 1 },
    panel2 = { 0.16, 0.165, 0.19, 1 },
    panel3 = { 0.20, 0.21, 0.24, 1 },
    stroke = { 0.31, 0.33, 0.38, 1 },
    text = { 0.88, 0.90, 0.94, 1 },
    dim = { 0.55, 0.58, 0.64, 1 },
    accent = { 0.20, 0.55, 1.00, 1 },
    accent_soft = { 0.20, 0.55, 1.00, 0.18 },
    warning = { 1.00, 0.62, 0.16, 1 },
    input = { 0.075, 0.08, 0.095, 1 },
    danger = { 0.74, 0.18, 0.20, 1 },
    surface = { 0.82, 0.84, 0.88, 1 },
    row_stroke = { 0.22, 0.24, 0.28, 1 },
}

local DEFAULT_PRESETS = {
    { name = "800x600",   w = 800,  h = 600 },
    { name = "1024x768",  w = 1024, h = 768 },
    { name = "1280x720",  w = 1280, h = 720 },
    { name = "1366x768",  w = 1366, h = 768 },
    { name = "1920x1080", w = 1920, h = 1080 },
    { name = "Phone",     w = 390,  h = 844 },
}

local MIN_SIZE_PX = 8
local HANDLE_SIZE = 13
local PANEL_LEFT_W = 280
local PANEL_RIGHT_W = 360
local PANEL_COLLAPSED_W = 46
local TOOLBAR_H = 56
local PANEL_PAD = 12
local BUTTON_H = 40
local BUTTON_FONT_SIZE = 15
local ROW_H = 32

local state = {
    next_editor_id = 1,
    selected = {},
    selected_map = {},
    primary = nil,
    hovered = nil,
    clipboard = nil,
    active_op = nil,
    pending_reparent = false,
    grid_sizes = { 0, 4, 8, 16, 32, 64 },
    grid_index = 3,
    preset_index = 1,
    preview_w = DEFAULT_PRESETS[1].w,
    preview_h = DEFAULT_PRESETS[1].h,
    zoom = 1,
    auto_zoom = true,
    pan = vec2(0, 0),
    preview_screen = { x = 0, y = 0, w = 0, h = 0 },
    preview_parent_rect = { position = vec2(0, 0), size = vec2(DEFAULT_PRESETS[1].w, DEFAULT_PRESETS[1].h), _v = 1 },
    explorer_dirty = true,
    properties_dirty = true,
    structure_dirty = true,
    selection_dirty = true,
    property_values_dirty = true,
    explorer_scroll_y = 0,
    properties_scroll_y = 0,
    explorer_content_h = 0,
    properties_content_h = 0,
    explorer_pool = {},
    properties_pool = {},
    explorer_model = {},
    properties_model = {},
    property_value_update_at = 0,
    structure_version = 0,
    open_context = nil,
    explorer_collapsed = false,
    properties_collapsed = false,
    property_sections = { common = true, Text = true, Image = true },
    undo_stack = {},
    redo_stack = {},
    restoring = false,
    explorer_rows = {},
    explorer_drag = nil,
    active_pan = nil,
    text_editing = nil,
    last_click_target = nil,
    last_click_at = 0,
    last_canvas_click_target = nil,
    last_canvas_click_at = 0,
    last_canvas_click_x = 0,
    last_canvas_click_y = 0,
}

local editor_root
local chrome_root
local context_root
local toolbar
local left_panel
local center_panel
local right_panel
local explorer_list
local properties_list
local preview_hit_layer
local preview_root
local design_root
local status_text
local grid_button
local resolution_button
local toolbar_buttons = {}
local record_snapshot
local reparent_selection
local filedialog_loaded = false
local filedialog_ref = nil
local history_depth = 0

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function _fmtn(n)
    return string.format("%.6g", tonumber(n) or 0)
end

local function _quote(s)
    return string.format("%q", tostring(s or ""))
end

local function _sanitize_utf8(s)
    if not utf8_ok or type(s) ~= "string" then return s end
    local guard = 0
    while guard < 1024 do
        local ok, errpos = utf8.len(s)
        if ok then return s end
        if not errpos or errpos < 1 or errpos > #s then return s end
        s = s:sub(1, errpos - 1) .. s:sub(errpos + 1)
        guard = guard + 1
    end
    return s
end

local function copy_color(c, fallback)
    fallback = fallback or { 1, 1, 1, 1 }
    if type(c) ~= "table" then
        return { fallback[1], fallback[2], fallback[3], fallback[4] }
    end
    return { c[1] or c.r or fallback[1], c[2] or c.g or fallback[2], c[3] or c.b or fallback[3], c[4] or c.a or
    fallback[4] }
end

local function vec_copy(v, x, y)
    if type(v) == "table" or type(v) == "userdata" then
        return vec2(v.x or x or 0, v.y or y or 0)
    end
    return vec2(x or 0, y or 0)
end

local function udim_copy(u)
    u = u or {}
    return {
        scale = vec_copy(u.scale),
        offset = vec_copy(u.offset),
    }
end

local function mark_internal(node)
    node.__editor_internal = true
    node.no_export = true
    return node
end

local function is_internal(node)
    return not node or node.__editor_internal or node.no_export or node.toolbar or node.handle or node.__editor_row
end

local function is_descendant_of(node, ancestor)
    local p = node
    while p do
        if p == ancestor then return true end
        p = p.linked
    end
    return false
end

local function is_user_element(node)
    return node and (not is_internal(node)) and is_descendant_of(node, design_root) and node ~= design_root
end

local function class_name(e)
    if not e then return "Element" end
    if e.setImageRect or e.image or e.source ~= nil or e.path ~= nil then
        return "Image"
    end
    if e.text ~= nil then
        return "Text"
    end
    return "Element"
end

local function ctor_for_class(name)
    if name == "Text" then return Text end
    if name == "Image" then return Image end
    return Element
end

local function assign_editor_ids(root)
    if not root then return end
    if root ~= design_root and not is_internal(root) then
        root.__editor_id = root.__editor_id or state.next_editor_id
        state.next_editor_id = math.max(state.next_editor_id, root.__editor_id + 1)
    end
    for _, child in ipairs(root.children or {}) do
        assign_editor_ids(child)
    end
end

local function clear_import_editor_flags(root)
    if not root then return end
    root.__editor_internal = nil
    root.no_export = nil
    root.toolbar = nil
    root.handle = nil
    root.__editor_row = nil
    for _, child in ipairs(root.children or {}) do
        clear_import_editor_flags(child)
    end
end

local function mark_dirty_tree(root)
    if not root then return end
    if root.mark_dirty then root:mark_dirty() end
    for _, child in ipairs(root.children or {}) do
        mark_dirty_tree(child)
    end
end

local function mark_editor_active(reason)
    local now = love.timer.getTime()
    local until_time = now + 0.25
    if (G._ui_editor_active_until or 0) < until_time then
        G._ui_editor_active_until = until_time
    end
    G._ui_editor_active_reason = reason
end

local function request_editor_refresh(kind)
    if kind == "structure" then
        state.structure_dirty = true
        state.selection_dirty = true
        state.property_values_dirty = true
        state.explorer_dirty = true
        state.properties_dirty = true
    elseif kind == "selection" then
        state.selection_dirty = true
        state.property_values_dirty = true
        state.explorer_dirty = true
        state.properties_dirty = true
    elseif kind == "values" then
        state.property_values_dirty = true
        state.properties_dirty = true
    else
        state.explorer_dirty = true
        state.properties_dirty = true
    end
    mark_editor_active(kind or "refresh")
end

local function with_history(label, fn)
    if history_depth == 0 and record_snapshot then
        record_snapshot(label)
    end

    history_depth = history_depth + 1
    local ok, a, b, c, d = pcall(fn)
    history_depth = history_depth - 1
    if not ok then error(a, 0) end
    return a, b, c, d
end

local function with_dirty_batch(elem, fn)
    if elem then
        return Element.with_dirty_batch(elem, fn)
    end
    return fn()
end

local function bump_structure()
    state.structure_version = state.structure_version + 1
    request_editor_refresh("structure")
end

local function grid_size()
    return state.grid_sizes[state.grid_index] or 0
end

local function grid_label()
    local g = grid_size()
    if g == 0 then return "Grid Off" end
    return "Grid " .. tostring(g)
end

local function explorer_width()
    return state.explorer_collapsed and PANEL_COLLAPSED_W or PANEL_LEFT_W
end

local function properties_width()
    return state.properties_collapsed and PANEL_COLLAPSED_W or PANEL_RIGHT_W
end

local function snap(v)
    local g = grid_size()
    if not g or g <= 0 then return v end
    return math.floor(v / g + 0.5) * g
end

local function active_keys()
    return input_mgr.state.active_keys
end

local function ctrl_down()
    local k = active_keys()
    return k.lctrl or k.rctrl or k.lgui or k.rgui
end

local function shift_down()
    local k = active_keys()
    return k.lshift or k.rshift
end

local function q_down()
    local k = active_keys()
    return k.q
end

local function h_down()
    local k = active_keys()
    return k.h
end

local function remove_all_children(parent)
    if not parent or not parent.children then return end
    for i = #parent.children, 1, -1 do
        local child = parent.children[i]
        if child and child.remove then child:remove() end
    end
    parent.children = {}
    parent:mark_dirty()
end

local function make_element(args)
    return mark_internal(Element(args or {}))
end

local function make_text(args)
    args = args or {}
    args.textColor = args.textColor or COLORS.text
    args.fontSize = args.fontSize or 15
    args.textFits = args.textFits == nil and true or args.textFits
    args.textScaled = args.textScaled == nil and false or args.textScaled
    args.textAlignX = args.textAlignX or "left"
    args.textAlignY = args.textAlignY or "center"
    args.show_fill = args.show_fill or false
    args.show_outline = args.show_outline or false
    return mark_internal(Text(args))
end

local function set_udim_offset(node, key, sx, sy, ox, oy)
    if not node then return end
    local ud = node[key]
    if not ud then
        node[key] = { scale = vec2(sx or 0, sy or 0), offset = vec2(ox or 0, oy or 0) }
        return
    end

    local scale = ud.scale
    if not scale then
        scale = vec2()
        ud.scale = scale
    end
    local offset = ud.offset
    if not offset then
        offset = vec2()
        ud.offset = offset
    end

    sx, sy, ox, oy = sx or 0, sy or 0, ox or 0, oy or 0
    local changed = false
    if scale.x ~= sx then
        scale.x = sx; changed = true
    end
    if scale.y ~= sy then
        scale.y = sy; changed = true
    end
    if offset.x ~= ox then
        offset.x = ox; changed = true
    end
    if offset.y ~= oy then
        offset.y = oy; changed = true
    end
    if changed and node.mark_dirty then node:mark_dirty(key) end
end

local function set_node_visible(node, visible)
    if node and node.visible ~= visible then
        node.visible = visible
    end
end

local function make_button(label, on_click, w)
    local btn = make_text {
        text = label,
        show_fill = true,
        fill_color = COLORS.panel2,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        mousecheck = true,
        selectable = false,
        textAlignX = "center",
        fontSize = BUTTON_FONT_SIZE,
        size = { offset = vec2(w or 96, BUTTON_H) },
        on_mouse_enter = function(self)
            self.fill_color = COLORS.panel3
        end,
        on_mouse_leave = function(self)
            self.fill_color = COLORS.panel2
        end,
        on_mouse_clicked = function(self, b)
            if b == 1 and on_click then on_click(self) end
        end,
    }
    btn.toolbar = true
    return btn
end

local function make_label(text, x, y, w, h, parent)
    local t = make_text {
        text = text,
        position = { offset = vec2(x, y) },
        size = { offset = vec2(w, h or 28) },
        textColor = COLORS.dim,
        textAlignX = "left",
        fontSize = 15,
    }
    if parent then parent:add(t) end
    return t
end

local function get_preview_parent_rect()
    --[[ bump the rect version ONLY when the preview size actually changes:
    unconditional writes without a _v bump both served stale rects after a
    preset change AND denied the element rect caches their pointer+version
    stability (every compute_rect_path walk recomputed every level) ]]
    local r = state.preview_parent_rect
    if r.size.x ~= state.preview_w or r.size.y ~= state.preview_h then
        r.position.x = 0
        r.position.y = 0
        r.size.x = state.preview_w
        r.size.y = state.preview_h
        r._v = (r._v or 0) + 1
    end
    return r
end

local function compute_rect_path(elem)
    if elem == preview_root then
        local parent = get_preview_parent_rect()
        return Element.get_screen_rect(preview_root, parent)
    end

    local path = {}
    local node = elem
    while node and node ~= preview_root do
        table.insert(path, 1, node)
        node = node.linked
    end
    if node ~= preview_root then return nil end

    local parent_rect = get_preview_parent_rect()
    local rect
    for _, item in ipairs(path) do
        rect = Element.get_screen_rect(item, parent_rect)
        parent_rect = rect
    end
    return rect
end

local function get_preview_rect(elem)
    return compute_rect_path(elem)
end

local function get_parent_preview_rect(elem)
    local parent = elem and elem.linked
    if not parent or parent == preview_root then
        return Element.get_screen_rect(preview_root, get_preview_parent_rect())
    end
    return get_preview_rect(parent)
end

local function point_in_preview_rect(rect, px, py)
    if not rect then return false end
    local cx = rect.position.x + rect.size.x * 0.5
    local cy = rect.position.y + rect.size.y * 0.5
    local dx, dy = px - cx, py - cy
    local c, s = math.cos(-(rect.rotation or 0)), math.sin(-(rect.rotation or 0))
    local lx = dx * c - dy * s + rect.size.x * 0.5
    local ly = dx * s + dy * c + rect.size.y * 0.5
    return lx >= 0 and lx <= rect.size.x and ly >= 0 and ly <= rect.size.y
end

local function screen_to_preview(px, py)
    local ps = state.preview_screen
    local z = math.max(0.01, state.zoom or 1)
    return (px - ps.x) / z, (py - ps.y) / z
end

local function preview_to_screen_rect(rect)
    local ps = state.preview_screen
    local z = state.zoom or 1
    return {
        x = ps.x + rect.position.x * z,
        y = ps.y + rect.position.y * z,
        w = rect.size.x * z,
        h = rect.size.y * z,
    }
end

function Editor.begin_pan(x, y)
    state.active_pan = {
        start_x = x,
        start_y = y,
        pan_x = state.pan.x,
        pan_y = state.pan.y,
    }
    state.auto_zoom = false
    mark_editor_active("pan")
end

function Editor.end_pan()
    state.active_pan = nil
end

local function update_pan()
    local pan = state.active_pan
    if not pan then return end
    local mouse = input_mgr.mouse
    local active = mouse.state.active
    local middle_active = active[3]
    local left_hand_active = active[1] and h_down()
    if not middle_active and not left_hand_active then
        Editor.end_pan()
        return
    end
    local mp = mouse.position
    state.pan.x = pan.pan_x + (mp.x - pan.start_x)
    state.pan.y = pan.pan_y + (mp.y - pan.start_y)
    mark_editor_active("pan")
end

local function hit_test_design(px, py)
    local function scan(node, parent_rect)
        local rect = Element.get_screen_rect(node, parent_rect)
        local sorted = Element._get_sorted_children_cached(node)
        for i = #sorted, 1, -1 do
            local child = sorted[i]
            if child and not is_internal(child) then
                local hit = scan(child, rect)
                if hit then return hit end
            end
        end

        if node ~= design_root and is_user_element(node) and point_in_preview_rect(rect, px, py) then
            return node
        end
        return nil
    end
    return scan(design_root, Element.get_screen_rect(preview_root, get_preview_parent_rect()))
end

local function selection_contains(elem)
    return elem and state.selected_map[elem] == true
end

local function set_selection(list, primary)
    state.selected = {}
    state.selected_map = {}
    for _, elem in ipairs(list or {}) do
        if is_user_element(elem) and not state.selected_map[elem] then
            state.selected[#state.selected + 1] = elem
            state.selected_map[elem] = true
        end
    end
    state.primary = primary and state.selected_map[primary] and primary or state.selected[#state.selected]
    request_editor_refresh("selection")
end

local function clear_selection()
    set_selection({})
end

local function select_one(elem)
    if elem and is_user_element(elem) then
        set_selection({ elem }, elem)
    else
        clear_selection()
    end
end

local function toggle_selection(elem)
    if not is_user_element(elem) then return end
    local next_list = {}
    for _, selected in ipairs(state.selected) do
        if selected ~= elem then next_list[#next_list + 1] = selected end
    end
    if not state.selected_map[elem] then
        next_list[#next_list + 1] = elem
    end
    set_selection(next_list, elem)
end

local function selected_roots()
    local out = {}
    for _, elem in ipairs(state.selected) do
        local p = elem.linked
        local covered = false
        while p and p ~= design_root do
            if state.selected_map[p] then
                covered = true
                break
            end
            p = p.linked
        end
        if not covered then out[#out + 1] = elem end
    end
    return out
end

local function normalize_sibling_z(parent)
    if not parent or not parent.children then return end
    local changed = false
    for i, child in ipairs(parent.children) do
        if child and not is_internal(child) then
            if child.zindex ~= i then
                child.zindex = i
                changed = true
            end
        end
    end
end

local function detach_from_parent(elem)
    local parent = elem and elem.linked
    if not parent or not parent.children then return nil end
    for i, child in ipairs(parent.children) do
        if child == elem then
            table.remove(parent.children, i)
            rawset(parent, "__child_name_map", nil)
            rawset(parent, "__neg_child_key", nil)
            parent._child_order_dirty = true
            parent._dynamic_tree_dirty = true
            parent:mark_dirty("linked")
            break
        end
    end
    elem:set_linked(nil)
    return parent
end

local function insert_child_at(parent, child, index)
    if not parent or not child then return end
    if child.linked then detach_from_parent(child) end
    parent.children = parent.children or {}
    index = clamp(index or (#parent.children + 1), 1, #parent.children + 1)
    table.insert(parent.children, index, child)
    child:set_linked(parent)
    rawset(parent, "__child_name_map", nil)
    rawset(parent, "__neg_child_key", nil)
    parent._child_order_dirty = true
    parent._dynamic_tree_dirty = true
    parent:mark_dirty("linked")
end

local function ensure_udim(e, key)
    e[key] = e[key] or { scale = vec2(), offset = vec2() }
    e[key].scale = e[key].scale or vec2()
    e[key].offset = e[key].offset or vec2()
    return e[key]
end

local function parse_bool(text)
    if type(text) == "boolean" then return text end
    local s = tostring(text or ""):lower()
    return s == "true" or s == "1" or s == "yes" or s == "on"
end

local function parse_num(text, old)
    if type(text) == "number" then return text end
    local s = tostring(text or ""):gsub("%s+", "")
    if s:match("^%.%d+$") then s = "0" .. s end
    local n = tonumber(s)
    if n == nil then return old or 0 end
    return n
end

local function parse_color(text, old)
    if type(text) == "table" then return copy_color(text, old) end
    local s = tostring(text or ""):gsub("[{}()%[%]]", " ")
    local hex = s:match("#([%x]+)")
    if hex and (#hex == 6 or #hex == 8) then
        local r = tonumber(hex:sub(1, 2), 16) or 255
        local g = tonumber(hex:sub(3, 4), 16) or 255
        local b = tonumber(hex:sub(5, 6), 16) or 255
        local a = (#hex == 8) and (tonumber(hex:sub(7, 8), 16) or 255) or 255
        return { r / 255, g / 255, b / 255, a / 255 }
    end
    local nums = {}
    for token in s:gmatch("[^,%s]+") do
        local n = tonumber(token)
        if n ~= nil then nums[#nums + 1] = n end
    end
    local fallback = copy_color(old)
    local r, g, b, a = nums[1], nums[2], nums[3], nums[4]
    if r == nil or g == nil or b == nil then return fallback end
    a = a == nil and 1 or a
    if r > 1 or g > 1 or b > 1 or a > 1 then
        r, g, b, a = r / 255, g / 255, b / 255, a / 255
    end
    return { r, g, b, a }
end

local function color_to_text(c)
    c = copy_color(c)
    return _fmtn(c[1]) .. ", " .. _fmtn(c[2]) .. ", " .. _fmtn(c[3]) .. ", " .. _fmtn(c[4])
end

local function get_property(elem, path)
    if not elem then return nil end
    if path == "source" then
        return elem.source or elem._resolved_source or elem.path or ""
    end
    local cur = elem
    for part in tostring(path):gmatch("[^%.]+") do
        if cur == nil then return nil end
        local idx = tonumber(part)
        cur = cur[idx or part]
    end
    return cur
end

local function set_property_no_history(elem, path, value)
    if not is_user_element(elem) then return end
    path = tostring(path)
    if path == "source" then
        local source = tostring(value or "")
        with_dirty_batch(elem, function()
            elem.source = source
            elem.path = source
        end)
        return
    end

    local parts = {}
    for part in path:gmatch("[^%.]+") do parts[#parts + 1] = part end
    if #parts == 0 then return end

    if (parts[1] == "position" or parts[1] == "size" or parts[1] == "anchor") and #parts == 3 then
        local ud = ensure_udim(elem, parts[1])
        local vec = ud[parts[2]]
        if vec then
            vec[parts[3]] = value
            elem:mark_dirty(parts[1])
        end
        return
    end

    if (parts[1] == "imageRectOffset" or parts[1] == "imageRectSize") and #parts == 2 then
        local off = vec_copy(elem.imageRectOffset)
        local sz = vec_copy(elem.imageRectSize, elem._srcW or 1, elem._srcH or 1)
        if parts[1] == "imageRectOffset" then
            off[parts[2]] = value
        else
            sz[parts[2]] = math.max(1, value)
        end
        if elem.setImageRect then
            elem:setImageRect(off, sz)
        else
            elem[parts[1]] = (parts[1] == "imageRectOffset") and off or sz
        end
        return
    end

    if #parts == 1 then
        elem[parts[1]] = value
        return
    end

    local cur = elem
    for i = 1, #parts - 1 do
        local part = tonumber(parts[i]) or parts[i]
        cur[part] = cur[part] or {}
        cur = cur[part]
    end
    local last = tonumber(parts[#parts]) or parts[#parts]
    local mt = type(cur) == "table" and getmetatable(cur) or nil
    local assignment_autodirties = mt and mt.__owner == elem
    cur[last] = value
    if not assignment_autodirties and elem.mark_dirty then elem:mark_dirty(parts[1]) end
end

local function set_property(elem, path, value)
    with_dirty_batch(elem, function()
        set_property_no_history(elem, path, value)
    end)
    request_editor_refresh((path == "name" or path == "visible") and "selection" or "values")
end

local function begin_text_edit(elem)
    if not is_user_element(elem) or class_name(elem) ~= "Text" then return false end
    if record_snapshot then record_snapshot() end
    local old_editable = elem.editable
    elem.editable = true
    elem._editor_text_editing = true
    state.text_editing = { elem = elem, old_editable = old_editable }
    input_mgr.typing.start_typing(elem, tostring(elem.text or ""))
    elem:mark_dirty("text")
    return true
end

local function get_filedialog()
    if filedialog_loaded then return filedialog_ref end
    filedialog_loaded = true
    local ok, result = pcall(require, "engine/services/filedialog")
    if ok then
        filedialog_ref = (type(result) == "table" and result) or rawget(_G, "filedialog")
    else
        print("[ui editor] file dialog unavailable: " .. tostring(result))
    end
    return filedialog_ref
end

local function image_dialog_filter()
    local os_name = love.system.getOS()
    if os_name == "Windows" then
        return "Image Files\0*.png;*.jpg;*.jpeg;*.bmp;*.tga;*.gif;*.webp\0All Files\0*.*\0"
    end
    return {
        { name = "Image Files", pattern = "*.png *.jpg *.jpeg *.bmp *.tga *.gif *.webp" },
        { name = "All Files",   pattern = "*.*" },
    }
end

local function slash_path(path)
    return tostring(path or ""):gsub("\\", "/")
end

local function source_roots()
    return {
        love.filesystem.getWorkingDirectory(),
        love.filesystem.getSourceBaseDirectory(),
        love.filesystem.getSource(),
    }
end

local function normalize_image_source_path(path)
    local p = slash_path(path)
    local lower = p:lower()
    for _, root in ipairs(source_roots()) do
        local r = slash_path(root):gsub("/+$", "")
        if r ~= "" then
            local rl = r:lower()
            if lower == rl then
                return p:match("[^/]+$") or p
            elseif lower:sub(1, #rl + 1) == rl .. "/" then
                return p:sub(#r + 2)
            end
        end
    end
    return p
end

local function apply_external_image_preview(elem, path)
    if type(path) ~= "string" or path == "" or not (io and io.open) then return false end
    local f = io.open(path, "rb")
    if not f then return false end
    local bytes = f:read("*a")
    f:close()
    if not bytes or bytes == "" then return false end

    local name = slash_path(path):match("[^/]+$") or "selected-image"
    local ok_data, file_data = pcall(love.filesystem.newFileData, bytes, name)
    if not ok_data then return false end
    local ok_imgdata, img_data = pcall(love.image.newImageData, file_data)
    if not ok_imgdata then return false end
    local ok_image, image = pcall(love.graphics.newImage, img_data)
    if not ok_image then return false end

    with_dirty_batch(elem, function()
        elem.image = image
        elem._srcW, elem._srcH = image:getDimensions()
        elem.quad = nil
        elem.imageRectOffset = vec2(0, 0)
        elem.imageRectSize = vec2(elem._srcW, elem._srcH)
        if elem.resample_mode and elem.setFilter then elem:setFilter(elem.resample_mode) end
    end)
    return true
end

local function apply_image_source_no_history(elem, path)
    if not is_user_element(elem) or class_name(elem) ~= "Image" or type(path) ~= "string" or path == "" then
        return false
    end
    local source = normalize_image_source_path(path)
    set_property_no_history(elem, "source", source)
    apply_external_image_preview(elem, path)
    request_editor_refresh("values")
    return true
end

local function pick_image_path()
    local fd = get_filedialog()
    if not fd or not fd.open then
        print("[ui editor] image picker unavailable")
        return nil
    end
    local path, err = fd.open("Select UI Image", image_dialog_filter(), false)
    if type(path) == "string" and path ~= "" then return path end
    if err and err ~= 0 then
        print("[ui editor] image picker cancelled or failed: " .. tostring(err))
    end
    return nil
end

local function pick_image_for_elements(elements)
    local path = pick_image_path()
    if not path then return false end
    if record_snapshot then record_snapshot() end
    local changed = false
    for _, elem in ipairs(elements or {}) do
        changed = apply_image_source_no_history(elem, path) or changed
    end
    return changed
end

local function pick_image_for_element(elem)
    return pick_image_for_elements({ elem })
end

local function serialize_vec(v)
    return ("vec2(%s, %s)"):format(_fmtn(v and v.x or 0), _fmtn(v and v.y or 0))
end

local function serialize_color(c)
    c = copy_color(c)
    return ("{ %s, %s, %s, %s }"):format(_fmtn(c[1]), _fmtn(c[2]), _fmtn(c[3]), _fmtn(c[4]))
end

local function add_line(lines, indent, text)
    lines[#lines + 1] = string.rep("    ", indent) .. text
end

local COMMON_EXPORT_PROPS = {
    { "name",              "string" },
    { "visible",           "bool" },
    { "zindex",            "number" },
    { "rotation",          "number" },
    { "show_fill",         "bool" },
    { "fill_color",        "color" },
    { "show_outline",      "bool" },
    { "outline_color",     "color" },
    { "outline_thickness", "number" },
}

local OPTIONAL_COMMON_EXPORT_PROPS = {
    { "mousecheck", "bool" },
    { "selectable", "bool" },
}

local TEXT_EXPORT_PROPS = {
    { "text",       "string" },
    { "fontSize",   "number" },
    { "textColor",  "color" },
    { "textAlignX", "string" },
    { "textAlignY", "string" },
    { "textScaled", "bool" },
    { "textFits",   "bool" },
    { "textScale",  "number" },
    { "lineHeight", "number" },
    { "opacity",    "number" },
    { "outlineThickness", "number" },
    { "outlineColor", "color" },
    { "wrapMode", "string" },
    { "letterSpacing", "number" },
    { "richText", "bool" },
    { "pixelFont", "bool" },
    { "bold", "bool" },
    { "italic", "bool" },
}

local IMAGE_EXPORT_PROPS = {
    { "source",          "string" },
    { "resample_mode",   "string" },
    { "scale_type",      "string" },
    { "imageRectOffset", "vec2" },
    { "imageRectSize",   "vec2" },
    { "flip_x",          "bool" },
    { "flip_y",          "bool" },
    { "color",           "color" },
    { "opacity",         "number" },
}

local LUA_RESERVED = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
    Element = true,
    Text = true,
    Image = true,
    vec2 = true,
    canvas = true,
}

local function nearly_equal(a, b)
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= 0.000001
end

local function vec_equal(v, x, y)
    return nearly_equal(v and v.x or 0, x or 0) and nearly_equal(v and v.y or 0, y or 0)
end

local function vec_is_zero(v)
    return vec_equal(v, 0, 0)
end

local function color_equal(a, b)
    a = copy_color(a)
    b = copy_color(b)
    return nearly_equal(a[1], b[1]) and nearly_equal(a[2], b[2]) and nearly_equal(a[3], b[3]) and
        nearly_equal(a[4], b[4])
end

local COMMON_DEFAULTS = {
    visible = true,
    zindex = 0,
    rotation = 0,
    show_fill = false,
    fill_color = { 0.1, 0.3, 0.9, 0.3 },
    show_outline = false,
    outline_color = { 1, 0.3, 0.1, 1 },
    outline_thickness = 2,
}

local TEXT_DEFAULTS = {
    text = "",
    fontSize = 20,
    textColor = { 1, 1, 1, 1 },
    textAlignX = "center",
    textAlignY = "center",
    textScaled = false,
    textFits = true,
    textScale = 1,
    lineHeight = 1.2,
    opacity = 1,
}

local IMAGE_DEFAULTS = {
    resample_mode = "nearest",
    scale_type = "stretch",
    flip_x = false,
    flip_y = false,
    color = { 1, 1, 1, 1 },
    opacity = 1,
}

local function serialize_prop_value(elem, key, kind)
    local v = get_property(elem, key)
    if kind == "string" then return _quote(v or "") end
    if kind == "bool" then return tostring(v == true) end
    if kind == "number" then return _fmtn(v or 0) end
    if kind == "color" then return serialize_color(v) end
    if kind == "vec2" then return serialize_vec(v) end
    return "nil"
end

local function should_emit_prop(elem, spec, defaults)
    local key, kind = spec[1], spec[2]
    local value = get_property(elem, key)
    if key == "name" then
        return value ~= nil and value ~= "" and value ~= "NULL"
    end
    if value == nil then return false end
    if key == "mousecheck" or key == "selectable" then
        return value == true
    end
    if key == "imageRectOffset" then
        return not vec_is_zero(value)
    end
    if key == "imageRectSize" then
        return not vec_equal(value, elem._srcW or 0, elem._srcH or 0)
    end
    -- Image() defaults to a transparent placeholder, not the editor icon
    -- a basename comparison would also lose a project's override of that icon
    if key == "source" then return type(value) == "string" and value ~= "" end

    local default = defaults and defaults[key]
    if default == nil then return true end
    if kind == "number" then return not nearly_equal(value, default) end
    if kind == "bool" then return (value == true) ~= (default == true) end
    if kind == "color" then return not color_equal(value, default) end
    if kind == "vec2" then return not vec_equal(value, default.x or 0, default.y or 0) end
    if kind == "string" then
        return tostring(value) ~= tostring(default)
    end
    return true
end

local function serialize_udim(elem, key, lines, indent)
    local u = elem[key] or {}
    local scale = u.scale or vec2(0, 0)
    local offset = u.offset or vec2(0, 0)
    local default_offset_x, default_offset_y = 0, 0
    if key == "size" then
        default_offset_x, default_offset_y = 100, 100
    end

    local scale_changed = not vec_is_zero(scale)
    local offset_changed = not vec_equal(offset, default_offset_x, default_offset_y)
    local offset_nonzero = not vec_is_zero(offset)
    local parts = {}

    -- a zero-size UDim2 differs from Element's default 100x100 size. emit a
    -- scale-only table so we preserve it without writing an all-zero offset
    if key == "size" and offset_changed and not offset_nonzero and not scale_changed then
        scale_changed = true
    end

    if scale_changed then parts[#parts + 1] = "scale = " .. serialize_vec(scale) end
    if offset_changed and offset_nonzero then parts[#parts + 1] = "offset = " .. serialize_vec(offset) end
    if #parts > 0 then
        add_line(lines, indent, ("%s = { %s },"):format(key, table.concat(parts, ", ")))
    end
end

local function serialize_node_literal(elem, indent)
    local cls = class_name(elem)
    local lines = {}
    add_line(lines, indent, cls .. " {")
    for _, spec in ipairs(COMMON_EXPORT_PROPS) do
        if should_emit_prop(elem, spec, COMMON_DEFAULTS) then
            add_line(lines, indent + 1, ("%s = %s,"):format(spec[1], serialize_prop_value(elem, spec[1], spec[2])))
        end
    end
    for _, spec in ipairs(OPTIONAL_COMMON_EXPORT_PROPS) do
        if should_emit_prop(elem, spec, COMMON_DEFAULTS) then
            add_line(lines, indent + 1, ("%s = %s,"):format(spec[1], serialize_prop_value(elem, spec[1], spec[2])))
        end
    end
    serialize_udim(elem, "position", lines, indent + 1)
    serialize_udim(elem, "size", lines, indent + 1)
    serialize_udim(elem, "anchor", lines, indent + 1)
    if cls == "Text" then
        if type(elem.fontPath) == "string" then
            add_line(lines, indent + 1, "font = " .. _quote(elem.fontPath) .. ",")
        end
        for _, spec in ipairs(TEXT_EXPORT_PROPS) do
            if should_emit_prop(elem, spec, TEXT_DEFAULTS) then
                add_line(lines, indent + 1, ("%s = %s,"):format(spec[1], serialize_prop_value(elem, spec[1], spec[2])))
            end
        end
    elseif cls == "Image" then
        for _, spec in ipairs(IMAGE_EXPORT_PROPS) do
            if should_emit_prop(elem, spec, IMAGE_DEFAULTS) then
                add_line(lines, indent + 1, ("%s = %s,"):format(spec[1], serialize_prop_value(elem, spec[1], spec[2])))
            end
        end
    end
    add_line(lines, indent, "}")
    return table.concat(lines, "\n")
end

local function should_export(elem)
    return is_user_element(elem)
end

local function sanitize_var_name(name, fallback)
    local s = tostring(name or ""):gsub("[^%w_]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if s == "" then s = fallback or "Element" end
    if s:match("^%d") then s = "_" .. s end
    if LUA_RESERVED[s] then s = s .. "_ui" end
    return s
end

local function unique_var_name(elem, used)
    local base = sanitize_var_name(elem.name, class_name(elem))
    local candidate = base
    local i = 2
    while used[candidate] do
        candidate = base .. tostring(i)
        i = i + 1
    end
    used[candidate] = true
    return candidate
end

local function add_assignment(lines, indent, var, elem)
    local literal = serialize_node_literal(elem, indent):gsub("^%s*", "")
    add_line(lines, indent, "local " .. var .. " = " .. literal)
end

local function export_children(parent, parent_var, used, lines, root_vars, indent)
    for _, child in ipairs(parent.children or {}) do
        if should_export(child) then
            local var = unique_var_name(child, used)
            add_assignment(lines, indent, var, child)
            if parent_var then
                add_line(lines, indent, parent_var .. ":add(" .. var .. ")")
            else
                root_vars[#root_vars + 1] = var
            end
            export_children(child, var, used, lines, root_vars, indent)
        end
    end
end

local function export_design_to_lua()
    local lines = {
        "-- UI Editor export",
    }
    local root_vars = {}
    export_children(design_root, nil, {}, lines, root_vars, 0)
    lines[#lines + 1] = "return { " .. table.concat(root_vars, ", ") .. " }"
    return table.concat(lines, "\n")
end

local function snapshot_node(elem)
    local cls = class_name(elem)
    local snap = {
        class = cls,
        props = {},
        children = {},
    }
    for _, spec in ipairs(COMMON_EXPORT_PROPS) do
        snap.props[spec[1]] = get_property(elem, spec[1])
    end
    for _, spec in ipairs(OPTIONAL_COMMON_EXPORT_PROPS) do
        local v = get_property(elem, spec[1])
        if v ~= nil then snap.props[spec[1]] = v end
    end
    snap.props.position = udim_copy(elem.position)
    snap.props.size = udim_copy(elem.size)
    snap.props.anchor = udim_copy(elem.anchor)
    if cls == "Text" then
        snap.props.font = elem.fontPath
        for _, spec in ipairs(TEXT_EXPORT_PROPS) do
            snap.props[spec[1]] = get_property(elem, spec[1])
        end
    elseif cls == "Image" then
        for _, spec in ipairs(IMAGE_EXPORT_PROPS) do
            local key = spec[1]
            snap.props[key] = get_property(elem, key)
        end
    end
    for _, child in ipairs(elem.children or {}) do
        if should_export(child) then
            snap.children[#snap.children + 1] = snapshot_node(child)
        end
    end
    return snap
end

local function snapshot_selection()
    local snaps = {}
    for _, elem in ipairs(selected_roots()) do
        snaps[#snaps + 1] = snapshot_node(elem)
    end
    return snaps
end

local function restore_node(snap)
    local ctor = ctor_for_class(snap.class)
    local props = {}
    for k, v in pairs(snap.props or {}) do
        if k == "position" or k == "size" or k == "anchor" then
            props[k] = udim_copy(v)
        elseif type(v) == "table" and (v.x ~= nil or v.y ~= nil) then
            props[k] = vec_copy(v)
        elseif type(v) == "table" then
            props[k] = copy_color(v)
        else
            props[k] = v
        end
    end
    local node = ctor(props)
    clear_import_editor_flags(node)
    for _, child_snap in ipairs(snap.children or {}) do
        node:add(restore_node(child_snap))
    end
    return node
end

local function import_lua_string(src)
    local imported_roots = {}
    local import_canvas = {
        add = function(_, child)
            imported_roots[#imported_roots + 1] = child
            return child
        end
    }
    local env = {
        Element = Element,
        Text = Text,
        Image = Image,
        vec2 = vec2,
        canvas = import_canvas,
    }

    local fn, err
    if loadstring then
        fn, err = loadstring(src or "", "ui_editor_import")
        if fn and setfenv then setfenv(fn, env) end
    else
        fn, err = load(src or "", "ui_editor_import", "t", env)
    end
    if not fn then return nil, err end
    local ok, result = pcall(fn)
    if not ok then return nil, result end

    local function collect_root(value)
        if Element.isElement(value) then
            for _, existing in ipairs(imported_roots) do
                if existing == value then return end
            end
            imported_roots[#imported_roots + 1] = value
        end
    end
    if result ~= nil then
        if Element.isElement(result) then
            collect_root(result)
        elseif type(result) == "table" then
            for _, value in ipairs(result) do
                collect_root(value)
            end
        end
    end
    return imported_roots
end

local function replace_design_with_roots(roots)
    remove_all_children(design_root)
    local added = {}
    for _, root in ipairs(roots or {}) do
        clear_import_editor_flags(root)
        design_root:add(root)
        assign_editor_ids(root)
        added[#added + 1] = root
    end
    normalize_sibling_z(design_root)
    bump_structure()
    set_selection(added, added[1])
    mark_dirty_tree(design_root)
end

local function import_from_clipboard()
    local text = love.system.getClipboardText() or ""
    local roots, err = import_lua_string(text)
    if not roots then
        print("[ui editor] import failed: " .. tostring(err))
        return false
    end
    replace_design_with_roots(roots)
    print(("[ui editor] imported %d root elements"):format(#roots))
    return true
end

local function export_to_clipboard()
    local out = export_design_to_lua()
    love.system.setClipboardText(out)
    print(("[ui editor] exported %d characters to the clipboard"):format(#out))
end

local function add_user_element(parent, cls)
    parent = (is_user_element(parent) and parent) or design_root
    local base = {
        name = cls,
        show_fill = cls == "Element",
        fill_color = { 1, 1, 1, 0.45 },
        show_outline = true,
        outline_color = { 0.18, 0.40, 0.90, 1 },
        outline_thickness = 1,
        visible = true,
        zindex = #(parent.children or {}) + 1,
        position = { scale = vec2(0.1, 0.1), offset = vec2(0, 0) },
        size = { scale = vec2(0.25, 0.18), offset = vec2(0, 0) },
        anchor = { scale = vec2(0, 0), offset = vec2(0, 0) },
    }
    if cls == "Text" then
        base.text = "Text"
        base.show_fill = false
        base.textColor = { 1, 1, 1, 1 }
        base.fontSize = 24
        base.textScaled = false
    elseif cls == "Image" then
        base.source = G.icon_path
        base.show_fill = false
        base.size = { scale = vec2(0.16, 0.16), offset = vec2(0, 0) }
    end
    local node = ctor_for_class(cls)(base)
    clear_import_editor_flags(node)
    parent:add(node)
    assign_editor_ids(node)
    bump_structure()
    select_one(node)
    return node
end

local function copy_selection()
    state.clipboard = snapshot_selection()
    print(("[ui editor] copied %d elements"):format(#state.clipboard))
end

local function cut_selection()
    copy_selection()
    for _, elem in ipairs(selected_roots()) do
        if elem.remove then elem:remove() end
    end
    clear_selection()
    bump_structure()
end

local function paste_clipboard(parent)
    if not state.clipboard or #state.clipboard == 0 then return end
    parent = is_user_element(parent) and parent or (state.primary or design_root)
    if not is_user_element(parent) then parent = design_root end
    local added = {}
    for _, snap in ipairs(state.clipboard) do
        local node = restore_node(snap)
        parent:add(node)
        assign_editor_ids(node)
        if node.position and node.position.offset then
            with_dirty_batch(node, function()
                node.position.offset.x = (node.position.offset.x or 0) + 16
                node.position.offset.y = (node.position.offset.y or 0) + 16
                node:mark_dirty("position")
            end)
        end
        added[#added + 1] = node
    end
    normalize_sibling_z(parent)
    bump_structure()
    set_selection(added, added[1])
end

local function duplicate_selection()
    copy_selection()
    paste_clipboard(state.primary and state.primary.linked or design_root)
end

local function delete_selection()
    for _, elem in ipairs(selected_roots()) do
        if elem and elem.remove then elem:remove() end
    end
    clear_selection()
    bump_structure()
end

local function move_in_parent(elem, delta)
    if not is_user_element(elem) or not elem.linked then return end
    local parent = elem.linked
    local idx
    for i, child in ipairs(parent.children or {}) do
        if child == elem then
            idx = i; break
        end
    end
    if not idx then return end
    local new_idx = clamp(idx + delta, 1, #parent.children)
    if new_idx == idx then return end
    table.remove(parent.children, idx)
    table.insert(parent.children, new_idx, elem)
    rawset(parent, "__child_name_map", nil)
    rawset(parent, "__neg_child_key", nil)
    parent._child_order_dirty = true
    parent._dynamic_tree_dirty = true
    normalize_sibling_z(parent)
    bump_structure()
end

local function explorer_row_at(x, y)
    local pr = left_panel:get_screen_rect()
    if x < pr.position.x or x > pr.position.x + pr.size.x or y < pr.position.y or y > pr.position.y + pr.size.y then
        return nil
    end
    local local_y = y - pr.position.y
    for _, row in ipairs(state.explorer_rows or {}) do
        if local_y >= row.y and local_y <= row.y + row.h then
            return row
        end
    end
    return nil
end

local function finish_explorer_drag(x, y)
    local drag = state.explorer_drag
    state.explorer_drag = nil
    if not drag or not drag.active or not is_user_element(drag.elem) then return end
    local target_row = explorer_row_at(x, y)
    if not target_row or not is_user_element(target_row.elem) or target_row.elem == drag.elem then return end

    local dragged = drag.elem
    local target = target_row.elem
    if is_descendant_of(target, dragged) then return end

    local pr = left_panel:get_screen_rect()
    local reparent_zone_x = pr.position.x + target_row.depth * 14 + 76
    if x > reparent_zone_x then
        reparent_selection(target)
    else
        record_snapshot()
        local parent = target.linked or design_root
        local target_index = 1
        for i, child in ipairs(parent.children or {}) do
            if child == target then
                target_index = i; break
            end
        end
        if y > pr.position.y + target_row.y + target_row.h * 0.5 then
            target_index = target_index + 1
        end
        insert_child_at(parent, dragged, target_index)
        normalize_sibling_z(parent)
        bump_structure()
        select_one(dragged)
    end
end

local function can_reparent(elem, new_parent)
    if not is_user_element(elem) then return false end
    if new_parent ~= design_root and not is_user_element(new_parent) then return false end
    if elem == new_parent then return false end
    return not is_descendant_of(new_parent, elem)
end

reparent_selection = function(new_parent)
    if new_parent ~= design_root and not is_user_element(new_parent) then return end
    for _, elem in ipairs(selected_roots()) do
        if can_reparent(elem, new_parent) then
            local old_parent = elem.linked
            local old_rect = get_preview_rect(elem)
            local new_parent_rect = (new_parent == design_root)
                and get_preview_rect(design_root)
                or get_preview_rect(new_parent)
            detach_from_parent(elem)
            new_parent:add(elem)
            if old_rect and new_parent_rect then
                local width, height = old_rect.size.x, old_rect.size.y
                local tlx = old_rect.position.x - new_parent_rect.position.x
                local tly = old_rect.position.y - new_parent_rect.position.y
                local anch = elem.anchor or { scale = vec2(), offset = vec2() }
                local ax = tlx + width * (anch.scale and anch.scale.x or 0) + (anch.offset and anch.offset.x or 0)
                local ay = tly + height * (anch.scale and anch.scale.y or 0) + (anch.offset and anch.offset.y or 0)
                local pos = ensure_udim(elem, "position")
                local size = ensure_udim(elem, "size")
                with_dirty_batch(elem, function()
                    pos.scale.x = new_parent_rect.size.x ~= 0 and (ax - pos.offset.x) / new_parent_rect.size.x or 0
                    pos.scale.y = new_parent_rect.size.y ~= 0 and (ay - pos.offset.y) / new_parent_rect.size.y or 0
                    size.scale.x = new_parent_rect.size.x ~= 0 and (width - size.offset.x) / new_parent_rect.size.x or 0
                    size.scale.y = new_parent_rect.size.y ~= 0 and (height - size.offset.y) / new_parent_rect.size.y or 0
                    elem:mark_dirty("position")
                    elem:mark_dirty("size")
                end)
            end
            if old_parent then normalize_sibling_z(old_parent) end
            normalize_sibling_z(new_parent)
        end
    end
    bump_structure()
end

local function make_panel(name, x, w)
    local panel = make_element {
        name = name,
        show_fill = true,
        fill_color = COLORS.panel,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        position = { offset = vec2(x, TOOLBAR_H) },
        size = { scale = vec2(0, 1), offset = vec2(w, -TOOLBAR_H) },
    }
    chrome_root:add(panel)
    return panel
end

local function create_roots()
    editor_root = mark_internal(Element {
        name = "UIEditorRoot",
        show_fill = true,
        fill_color = COLORS.bg,
        size = { scale = vec2(1, 1) },
        zindex = 10000,
        no_hover = true,
    })

    chrome_root = make_element {
        name = "ChromeRoot",
        size = { scale = vec2(1, 1) },
    }
    editor_root:add(chrome_root)

    toolbar = make_element {
        name = "Toolbar",
        show_fill = true,
        fill_color = { 0.105, 0.11, 0.13, 1 },
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        size = { scale = vec2(1, 0), offset = vec2(0, TOOLBAR_H) },
    }
    chrome_root:add(toolbar)

    left_panel = make_panel("ExplorerPanel", 0, PANEL_LEFT_W)
    right_panel = make_panel("PropertiesPanel", -PANEL_RIGHT_W, PANEL_RIGHT_W)
    right_panel.anchor = { scale = vec2(1, 0), offset = vec2(0, 0) }
    right_panel.position = { scale = vec2(1, 0), offset = vec2(0, TOOLBAR_H) }

    center_panel = make_element {
        name = "PreviewPanel",
        show_fill = true,
        fill_color = { 0.075, 0.08, 0.095, 1 },
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        position = { offset = vec2(PANEL_LEFT_W, TOOLBAR_H) },
        size = { scale = vec2(1, 1), offset = vec2(-(PANEL_LEFT_W + PANEL_RIGHT_W), -TOOLBAR_H) },
    }
    chrome_root:add(center_panel)

    preview_hit_layer = make_element {
        name = "PreviewHitLayer",
        size = { scale = vec2(1, 1) },
        mousecheck = true,
        zindex = 500,
        on_mouse_click = function(_, button, x, y)
            if button == 3 or (button == 1 and h_down()) then
                Editor.begin_pan(x, y)
                return
            end
            if button == 2 then
                local px, py = screen_to_preview(x, y)
                local target = hit_test_design(px, py)
                if target then select_one(target) end
                Editor.open_context(x, y, target, "canvas")
                return
            end
            if button ~= 1 then return end
            if state.open_context then
                Editor.close_context()
                return
            end
            if state.pending_reparent then
                local px, py = screen_to_preview(x, y)
                reparent_selection(hit_test_design(px, py) or design_root)
                state.pending_reparent = false
                return
            end
            local handle = Editor.hit_resize_handle(x, y)
            if handle then
                Editor.begin_resize(handle, x, y)
                return
            end
            local px, py = screen_to_preview(x, y)
            local target = hit_test_design(px, py)
            if target then
                if ctrl_down() then toggle_selection(target) else select_one(target) end
                local now = love.timer.getTime()
                local ddx = (x or 0) - (state.last_canvas_click_x or 0)
                local ddy = (y or 0) - (state.last_canvas_click_y or 0)
                local is_double = (not ctrl_down())
                    and state.last_canvas_click_target == target
                    and (now - state.last_canvas_click_at) >= 0.05
                    and (now - state.last_canvas_click_at) < 0.28
                    and (ddx * ddx + ddy * ddy) <= 36
                state.last_canvas_click_target = target
                state.last_canvas_click_at = now
                state.last_canvas_click_x = x or 0
                state.last_canvas_click_y = y or 0
                if is_double and class_name(target) == "Text" then
                    begin_text_edit(target)
                elseif is_double and class_name(target) == "Image" then
                    pick_image_for_element(target)
                else
                    Editor.begin_move(x, y)
                end
            else
                clear_selection()
            end
        end,
        on_mouse_release = function(_, button)
            if button == 1 then Editor.end_transform() end
            if button == 3 then Editor.end_pan() end
        end,
    }
    center_panel:add(preview_hit_layer)

    preview_root = mark_internal(Element {
        name = "PreviewRoot",
        show_fill = true,
        fill_color = COLORS.surface,
        show_outline = true,
        outline_color = { 0.50, 0.53, 0.60, 1 },
        outline_thickness = 1,
        position = { scale = vec2(0, 0), offset = vec2(0, 0) },
        size = { scale = vec2(1, 1), offset = vec2(0, 0) },
        zindex = 1,
    })

    design_root = mark_internal(Element {
        name = "Canvas",
        size = { scale = vec2(1, 1), offset = vec2(0, 0) },
        position = { scale = vec2(0, 0), offset = vec2(0, 0) },
    })
    preview_root:add(design_root)

    context_root = mark_internal(Element {
        name = "ContextMenu",
        show_fill = true,
        fill_color = COLORS.panel2,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        visible = false,
        mousecheck = true,
        zindex = 20000,
        size = { offset = vec2(190, 200) },
    })
end

local function add_toolbar_buttons()
    local x = 10
    local function add(label, fn, w)
        local btn = make_button(label, fn, w)
        btn.position = { offset = vec2(x, 8) }
        toolbar:add(btn)
        toolbar_buttons[#toolbar_buttons + 1] = { node = btn, width = w or 96 }
        x = x + (w or 96) + 7
        return btn
    end

    add("Element", function() add_user_element(state.primary, "Element") end, 86)
    add("Text", function() add_user_element(state.primary, "Text") end, 68)
    add("Image", function() add_user_element(state.primary, "Image") end, 76)
    add("Import", function() import_from_clipboard() end, 80)
    add("Export", function() export_to_clipboard() end, 82)
    add("Copy", function() copy_selection() end, 70)
    add("Paste", function() paste_clipboard(state.primary) end, 72)
    add("Delete", function() delete_selection() end, 78)
    grid_button = add(grid_label(), function(self)
        state.grid_index = state.grid_index + 1
        if state.grid_index > #state.grid_sizes then state.grid_index = 1 end
        self:setText(grid_label(), true)
    end, 86)
    resolution_button = add(DEFAULT_PRESETS[state.preset_index].name, function(self)
        state.preset_index = state.preset_index + 1
        if state.preset_index > #DEFAULT_PRESETS then state.preset_index = 1 end
        local preset = DEFAULT_PRESETS[state.preset_index]
        state.preview_w, state.preview_h = preset.w, preset.h
        state.preview_parent_rect._v = state.preview_parent_rect._v + 1
        state.auto_zoom = true
        preview_root:mark_dirty("size")
        self:setText(preset.name, true)
        request_editor_refresh("values")
    end, 104)

    status_text = make_text {
        text = "",
        textColor = COLORS.dim,
        textAlignX = "right",
        position = { scale = vec2(1, 0), offset = vec2(-250, 15) },
        size = { offset = vec2(240, 28) },
    }
    toolbar:add(status_text)
end

local function row_text(text, color)
    return make_text {
        text = text,
        textColor = color or COLORS.text,
        textAlignX = "left",
        fontSize = 14,
        size = { scale = vec2(1, 1), offset = vec2(0, 0) },
    }
end

local function panel_scroll_max(panel, content_h)
    if not panel then return 0 end
    local rect = panel:get_screen_rect()
    local body_h = math.max(0, (rect.size and rect.size.y or 0) - 50)
    return math.max(0, (content_h or 0) - body_h)
end

local rebuild_explorer
do
    local function ensure_explorer_header()
        local pool = state.explorer_pool
        if pool.header then return pool.header end

        local header = make_element {
            show_fill = true,
            fill_color = COLORS.panel2,
            show_outline = true,
            outline_color = COLORS.stroke,
            outline_thickness = 1,
            mousecheck = true,
            position = { offset = vec2(6, 8) },
            size = { scale = vec2(1, 0), offset = vec2(-12, 34) },
            on_mouse_clicked = function(_, button)
                if button == 1 then
                    state.explorer_collapsed = not state.explorer_collapsed
                    state.structure_dirty = true
                    state.explorer_dirty = true
                    mark_editor_active("explorer_toggle")
                end
            end,
        }
        explorer_list:add(header)

        local toggle = make_text {
            text = ">",
            show_fill = true,
            fill_color = COLORS.input,
            show_outline = true,
            outline_color = COLORS.stroke,
            outline_thickness = 1,
            textAlignX = "center",
            fontSize = 16,
            position = { offset = vec2(5, 5) },
            size = { offset = vec2(24, 24) },
        }
        header:add(toggle)

        local label = row_text("Explorer", COLORS.text)
        set_udim_offset(label, "position", 0, 0, 36, 0)
        set_udim_offset(label, "size", 1, 1, -40, 0)
        header:add(label)

        pool.header = { root = header, toggle = toggle, label = label }
        return pool.header
    end

    local function build_explorer_model()
        local model = state.explorer_model
        for i = #model, 1, -1 do model[i] = nil end

        local y = 50
        if not state.explorer_collapsed then
            local function add_row(elem, depth)
                if not elem then return end
                model[#model + 1] = { type = "row", elem = elem, depth = depth, y = y, h = ROW_H }
                y = y + ROW_H

                if elem.__editor_expanded ~= false then
                    local children = elem.children or {}
                    for i = 1, #children do
                        local child = children[i]
                        if is_user_element(child) then add_row(child, depth + 1) end
                    end
                end
            end

            local roots = design_root.children or {}
            for i = 1, #roots do
                local child = roots[i]
                if is_user_element(child) then add_row(child, 0) end
            end
        end

        if not state.explorer_collapsed and #model == 0 then
            model[1] = { type = "empty", y = 50, h = 54 }
            y = 104
        end

        state.explorer_content_h = math.max(0, y - 50)
        state.structure_dirty = false
    end

    local function ensure_explorer_row(index)
        local rows = state.explorer_pool.rows
        if not rows then
            rows = {}
            state.explorer_pool.rows = rows
        end
        if rows[index] then return rows[index] end

        local row
        local function row_click(_, button, x, yy)
            local model = row.__model
            local elem = model and model.elem
            if not is_user_element(elem) then return end

            mark_editor_active("explorer_click")
            if button == 2 then
                if not selection_contains(elem) then select_one(elem) end
                Editor.open_context(x, yy, elem, "explorer")
                return
            end
            if button ~= 1 then return end

            if state.pending_reparent then
                reparent_selection(elem)
                state.pending_reparent = false
                return
            end

            local now = love.timer.getTime()
            local double = state.last_click_target == elem and (now - state.last_click_at) < 0.35
            state.last_click_target = elem
            state.last_click_at = now
            if ctrl_down() then toggle_selection(elem) else select_one(elem) end
            state.explorer_drag = { elem = elem, start_x = x, start_y = yy, active = false }
            if double then
                with_history("rename", function()
                    input_mgr.typing.start_typing(row.__pool_item.name_field, elem.name or "")
                end)
            end
        end

        row = make_element {
            name = "ExplorerRow",
            __editor_row = true,
            show_fill = true,
            fill_color = COLORS.panel,
            show_outline = true,
            outline_color = COLORS.row_stroke,
            outline_thickness = 1,
            mousecheck = true,
            position = { offset = vec2(6, 50) },
            size = { scale = vec2(1, 0), offset = vec2(-12, ROW_H) },
            on_mouse_click = row_click,
            on_mouse_release = function(_, button, x, yy)
                if button == 1 then finish_explorer_drag(x, yy) end
            end,
        }
        row.__editor_row = true
        explorer_list:add(row)

        local arrow = row_text("", COLORS.dim)
        set_udim_offset(arrow, "size", 0.1, 1, 0, 0)
        arrow.textAlignX = "center"
        arrow.show_fill = true
        arrow.fill_color = COLORS.input
        arrow.show_outline = true
        arrow.outline_color = COLORS.stroke
        arrow.outline_thickness = 1
        arrow.mousecheck = true
        arrow.on_mouse_clicked = function(self, button)
            local model = self.__model
            local elem = model and model.elem
            if button == 1 and elem and elem.children and #elem.children > 0 then
                elem.__editor_expanded = elem.__editor_expanded == false and true or false
                state.structure_dirty = true
                state.explorer_dirty = true
                mark_editor_active("explorer_expand")
            end
        end
        row:add(arrow)

        local icon = row_text("", COLORS.accent)
        set_udim_offset(icon, "position", 0.1, 0, 0, 0)
        set_udim_offset(icon, "size", 0.9, 1, 0, 0)
        icon.textAlignX = "right"
        icon.show_fill = true
        icon.fill_color = { 0.11, 0.12, 0.14, 1 }
        icon.show_outline = true
        icon.outline_color = COLORS.stroke
        icon.outline_thickness = 1
        icon.mousecheck = true
        icon.on_mouse_click = row_click
        row:add(icon)

        local name_field = row_text("", COLORS.text)
        name_field.name = "NameField"
        name_field.editable = false
        name_field.mousecheck = false
        set_udim_offset(name_field, "position", 0.1, 0, 0, 0)
        name_field.on_text_changed = function(self_text)
            local model = name_field.__model
            local elem = model and model.elem
            if not is_user_element(elem) then return end
            local cls = model.class
            local clean = _sanitize_utf8((self_text or ""):gsub("|", ""))
            clean = clean:gsub("%s+%[[^%]]+%]$", "")
            if clean == "" then clean = cls end
            set_property(elem, "name", clean)
        end
        name_field.on_mouse_click = row_click
        row:add(name_field)

        local item = { row = row, arrow = arrow, icon = icon, name_field = name_field }
        row.__pool_item = item
        rows[index] = item
        return item
    end

    local function bind_explorer_row(item, model, visual_y, visual_index)
        local elem = model.elem
        local cls = class_name(elem)
        local selected = selection_contains(elem)
        local elem_visible = elem.visible ~= false

        item.row.__model = model
        item.arrow.__model = model
        item.icon.__model = model
        item.name_field.__model = model
        model.class = cls

        set_node_visible(item.row, true)
        set_udim_offset(item.row, "position", 0, 0, 6, visual_y)
        item.row.fill_color = selected and COLORS.accent_soft or
        ((visual_index % 2 == 0) and COLORS.panel2 or COLORS.panel)
        item.row.outline_color = selected and COLORS.accent or COLORS.row_stroke

        item.arrow:setText((elem.children and #elem.children > 0) and ((elem.__editor_expanded == false) and ">" or "v") or
        "")
        item.icon:setText(cls:sub(1, 1))
        item.icon.textColor = elem_visible and COLORS.accent or COLORS.warning
        item.icon.outline_color = elem_visible and COLORS.stroke or COLORS.warning

        item.name_field:setText((elem.name or cls) .. "  [" .. cls .. "]")
        item.name_field.textColor = elem_visible and COLORS.text or COLORS.dim
        set_udim_offset(item.name_field, "size", 0.9, 1, -(model.depth * 16 + 72), 0)
    end

    local function ensure_explorer_empty()
        local pool = state.explorer_pool
        if pool.empty then return pool.empty end
        local empty = row_text("No elements. Use the toolbar to insert UI.", COLORS.dim)
        set_udim_offset(empty, "position", 0, 0, PANEL_PAD, 50)
        set_udim_offset(empty, "size", 1, 0, -PANEL_PAD * 2, 54)
        empty.textAlignY = "top"
        explorer_list:add(empty)
        pool.empty = empty
        return empty
    end

    rebuild_explorer = function()
        local header = ensure_explorer_header()
        header.toggle:setText(state.explorer_collapsed and ">" or "<")
        set_node_visible(header.label, not state.explorer_collapsed)

        if state.structure_dirty then
            build_explorer_model()
        end

        local rows = state.explorer_pool.rows or {}
        for i = 1, #rows do set_node_visible(rows[i].row, false) end
        if state.explorer_pool.empty then set_node_visible(state.explorer_pool.empty, false) end
        state.explorer_rows = {}

        if state.explorer_collapsed then
            state.explorer_scroll_y = 0
            state.explorer_dirty = false
            return
        end

        state.explorer_scroll_y = clamp(state.explorer_scroll_y, 0,
            panel_scroll_max(left_panel, state.explorer_content_h))
        local panel_rect = left_panel:get_screen_rect()
        local panel_h = panel_rect.size.y
        local scroll_y = state.explorer_scroll_y
        local visible_index = 0

        for i = 1, #state.explorer_model do
            local model = state.explorer_model[i]
            local visual_y = model.y - scroll_y
            if visual_y + model.h >= 46 and visual_y <= panel_h then
                if model.type == "row" then
                    visible_index = visible_index + 1
                    local item = ensure_explorer_row(visible_index)
                    bind_explorer_row(item, model, visual_y, i)
                    state.explorer_rows[#state.explorer_rows + 1] = {
                        elem = model.elem,
                        y = visual_y,
                        h = model.h,
                        depth = model.depth,
                    }
                elseif model.type == "empty" then
                    local empty = ensure_explorer_empty()
                    set_node_visible(empty, true)
                    set_udim_offset(empty, "position", 0, 0, PANEL_PAD, visual_y)
                end
            end
        end

        for i = visible_index + 1, #rows do
            set_node_visible(rows[i].row, false)
        end
        state.explorer_dirty = false
    end
end

local PROPERTY_SPECS = {
    { label = "Name",            path = "name",              type = "string", group = "common" },
    { label = "Visible",         path = "visible",           type = "bool",   group = "common" },
    { label = "ZIndex",          path = "zindex",            type = "number", group = "common" },
    { label = "Rotation",        path = "rotation",          type = "number", group = "common" },
    { label = "Pos Scale X",     path = "position.scale.x",  type = "number", group = "common" },
    { label = "Pos Scale Y",     path = "position.scale.y",  type = "number", group = "common" },
    { label = "Pos Offset X",    path = "position.offset.x", type = "number", group = "common" },
    { label = "Pos Offset Y",    path = "position.offset.y", type = "number", group = "common" },
    { label = "Size Scale X",    path = "size.scale.x",      type = "number", group = "common" },
    { label = "Size Scale Y",    path = "size.scale.y",      type = "number", group = "common" },
    { label = "Size Offset X",   path = "size.offset.x",     type = "number", group = "common" },
    { label = "Size Offset Y",   path = "size.offset.y",     type = "number", group = "common" },
    { label = "Anchor Scale X",  path = "anchor.scale.x",    type = "number", group = "common" },
    { label = "Anchor Scale Y",  path = "anchor.scale.y",    type = "number", group = "common" },
    { label = "Anchor Offset X", path = "anchor.offset.x",   type = "number", group = "common" },
    { label = "Anchor Offset Y", path = "anchor.offset.y",   type = "number", group = "common" },
    { label = "Fill",            path = "show_fill",         type = "bool",   group = "common" },
    { label = "Fill Color",      path = "fill_color",        type = "color",  group = "common" },
    { label = "Outline",         path = "show_outline",      type = "bool",   group = "common" },
    { label = "Outline Color",   path = "outline_color",     type = "color",  group = "common" },
    { label = "Outline Size",    path = "outline_thickness", type = "number", group = "common" },
    { label = "Text",            path = "text",              type = "string", group = "Text" },
    { label = "Font Size",       path = "fontSize",          type = "number", group = "Text" },
    { label = "Text Color",      path = "textColor",         type = "color",  group = "Text" },
    { label = "Align X",         path = "textAlignX",        type = "string", group = "Text" },
    { label = "Align Y",         path = "textAlignY",        type = "string", group = "Text" },
    { label = "Scaled",          path = "textScaled",        type = "bool",   group = "Text" },
    { label = "Fits",            path = "textFits",          type = "bool",   group = "Text" },
    { label = "Text Scale",      path = "textScale",         type = "number", group = "Text" },
    { label = "Line Height",     path = "lineHeight",        type = "number", group = "Text" },
    { label = "Text Opacity",    path = "opacity",           type = "number", group = "Text" },
    { label = "Source",          path = "source",            type = "string", group = "Image" },
    { label = "Resample",        path = "resample_mode",     type = "string", group = "Image" },
    { label = "Scale Type",      path = "scale_type",        type = "string", group = "Image" },
    { label = "Rect X",          path = "imageRectOffset.x", type = "number", group = "Image" },
    { label = "Rect Y",          path = "imageRectOffset.y", type = "number", group = "Image" },
    { label = "Rect W",          path = "imageRectSize.x",   type = "number", group = "Image" },
    { label = "Rect H",          path = "imageRectSize.y",   type = "number", group = "Image" },
    { label = "Flip X",          path = "flip_x",            type = "bool",   group = "Image" },
    { label = "Flip Y",          path = "flip_y",            type = "bool",   group = "Image" },
    { label = "Image Color",     path = "color",             type = "color",  group = "Image" },
    { label = "Image Opacity",   path = "opacity",           type = "number", group = "Image" },
}

local function value_to_display(value, kind)
    if value == nil then return "" end
    if kind == "bool" then return tostring(value == true) end
    if kind == "number" then return _fmtn(value) end
    if kind == "color" then return color_to_text(value) end
    return tostring(value)
end

local function parse_property_value(kind, text, old)
    if kind == "bool" then return parse_bool(text) end
    if kind == "number" then return parse_num(text, old) end
    if kind == "color" then return parse_color(text, old) end
    return _sanitize_utf8(tostring(text or ""):gsub("|", ""))
end

local function mixed_value_for_selection(path, kind)
    local first = nil
    local mixed = false
    for i, elem in ipairs(state.selected) do
        local value = get_property(elem, path)
        local display = value_to_display(value, kind)
        if i == 1 then
            first = display
        elseif display ~= first then
            mixed = true
            break
        end
    end
    if mixed then return "<mixed>", true end
    return first or "", false
end

local function spec_applies(spec)
    if #state.selected == 0 then return false end
    if spec.group == "common" then return true end
    for _, elem in ipairs(state.selected) do
        if class_name(elem) ~= spec.group then return false end
    end
    return true
end

local rebuild_properties

local function ensure_properties_header()
    local pool = state.properties_pool
    if pool.header then return pool.header end

    local header = make_element {
        show_fill = true,
        fill_color = COLORS.panel2,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        mousecheck = true,
        position = { offset = vec2(6, 8) },
        size = { scale = vec2(1, 0), offset = vec2(-12, 34) },
        on_mouse_clicked = function(_, button)
            if button == 1 then
                state.properties_collapsed = not state.properties_collapsed
                state.selection_dirty = true
                state.properties_dirty = true
                mark_editor_active("properties_toggle")
            end
        end,
    }
    properties_list:add(header)

    local toggle = make_text {
        text = "<",
        show_fill = true,
        fill_color = COLORS.input,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        textAlignX = "center",
        fontSize = 16,
        position = { offset = vec2(5, 5) },
        size = { offset = vec2(24, 24) },
    }
    header:add(toggle)

    local label = row_text("Properties", COLORS.text)
    set_udim_offset(label, "position", 0, 0, 36, 0)
    set_udim_offset(label, "size", 1, 1, -40, 0)
    header:add(label)

    pool.header = { root = header, toggle = toggle, label = label }
    return pool.header
end

local function build_properties_model()
    local model = state.properties_model
    for i = #model, 1, -1 do model[i] = nil end

    local y = 50
    if not state.properties_collapsed then
        if #state.selected == 0 then
            model[#model + 1] = { type = "empty", y = y, h = 34, text = "No element selected" }
            y = y + 34
        else
            local title_text = #state.selected == 1
                and ((state.primary.name or class_name(state.primary)) .. "  [" .. class_name(state.primary) .. "]")
                or (#state.selected .. " elements selected")
            model[#model + 1] = { type = "title", y = y, h = 30, text = title_text }
            y = y + 36

            local function add_section(group, label)
                local any = false
                for i = 1, #PROPERTY_SPECS do
                    local spec = PROPERTY_SPECS[i]
                    if spec.group == group and spec_applies(spec) then
                        any = true
                        break
                    end
                end
                if not any then return end

                local open = state.property_sections[group] ~= false
                model[#model + 1] = { type = "section", key = group, label = label, open = open, y = y, h = 30 }
                y = y + 33
                if not open then return end

                for i = 1, #PROPERTY_SPECS do
                    local spec = PROPERTY_SPECS[i]
                    if spec.group == group and spec_applies(spec) then
                        model[#model + 1] = { type = "property", spec = spec, y = y, h = 34 }
                        y = y + 36
                    end
                end
            end

            add_section("common", "Element")
            add_section("Text", "Text")
            add_section("Image", "Image")
        end
    end

    state.properties_content_h = math.max(0, y - 50)
    state.selection_dirty = false
end

local function ensure_property_title()
    local pool = state.properties_pool
    if pool.title then return pool.title end
    local title = row_text("", COLORS.text)
    set_udim_offset(title, "position", 0, 0, PANEL_PAD, 50)
    set_udim_offset(title, "size", 1, 0, -PANEL_PAD * 2, 30)
    properties_list:add(title)
    pool.title = title
    return title
end

local function ensure_property_empty()
    local pool = state.properties_pool
    if pool.empty then return pool.empty end
    local empty = row_text("", COLORS.dim)
    set_udim_offset(empty, "position", 0, 0, PANEL_PAD, 50)
    set_udim_offset(empty, "size", 1, 0, -PANEL_PAD * 2, 34)
    properties_list:add(empty)
    pool.empty = empty
    return empty
end

local function ensure_property_section(index)
    local sections = state.properties_pool.sections
    if not sections then
        sections = {}
        state.properties_pool.sections = sections
    end
    if sections[index] then return sections[index] end

    local section = make_element {
        show_fill = true,
        fill_color = COLORS.panel3,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        mousecheck = true,
        position = { offset = vec2(6, 50) },
        size = { scale = vec2(1, 0), offset = vec2(-12, 30) },
        on_mouse_clicked = function(self, button)
            local model = self.__model
            if button == 1 and model then
                state.property_sections[model.key] = not model.open
                state.selection_dirty = true
                state.properties_dirty = true
                mark_editor_active("property_section")
            end
        end,
    }
    properties_list:add(section)

    local caret = row_text("", COLORS.text)
    caret.textAlignX = "center"
    set_udim_offset(caret, "position", 0, 0, 5, 4)
    set_udim_offset(caret, "size", 0, 0, 22, 22)
    caret.show_fill = true
    caret.fill_color = COLORS.input
    caret.show_outline = true
    caret.outline_color = COLORS.stroke
    caret.outline_thickness = 1
    section:add(caret)

    local label = row_text("", COLORS.text)
    set_udim_offset(label, "position", 0, 0, 34, 0)
    set_udim_offset(label, "size", 1, 1, -38, 0)
    section:add(label)

    local item = { row = section, caret = caret, label = label }
    sections[index] = item
    return item
end

local function ensure_property_row(index)
    local rows = state.properties_pool.rows
    if not rows then
        rows = {}
        state.properties_pool.rows = rows
    end
    if rows[index] then return rows[index] end

    local row = make_element {
        show_fill = true,
        fill_color = COLORS.panel,
        show_outline = true,
        outline_color = COLORS.row_stroke,
        outline_thickness = 1,
        position = { offset = vec2(10, 50) },
        size = { scale = vec2(1, 0), offset = vec2(-20, 34) },
    }
    properties_list:add(row)

    local label = row_text("", COLORS.dim)
    set_udim_offset(label, "position", 0, 0, 7, 0)
    set_udim_offset(label, "size", 0, 1, 132, 0)
    row:add(label)

    local field
    field = make_text {
        name = "PropertyValue",
        text = "",
        textColor = COLORS.text,
        textAlignX = "left",
        show_fill = true,
        fill_color = COLORS.input,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        editable = true,
        mousecheck = true,
        position = { offset = vec2(142, 4) },
        size = { scale = vec2(1, 0), offset = vec2(-148, 26) },
        on_mouse_click = function(self, button, x, yy)
            if button ~= 1 then return end
            local model = self.__model
            local spec = model and model.spec
            if not spec then return end

            mark_editor_active("property_click")
            if spec.path == "source" and spec.group == "Image" then
                pick_image_for_elements(state.selected)
                return
            end

            local display, mixed = mixed_value_for_selection(spec.path, spec.type)
            if spec.type == "bool" then
                with_history("property", function()
                    local new_value = not parse_bool(display ~= "<mixed>" and display or "false")
                    for _, elem in ipairs(state.selected) do
                        set_property(elem, spec.path, new_value)
                    end
                end)
                request_editor_refresh("values")
                return
            end

            with_history("property", function()
                local start_text = mixed and "" or display
                input_mgr.typing.start_typing(self, start_text)
                input_mgr.typing.cursor_index = input_mgr.typing.compute_index_from_click(self, x or 0, yy or 0)
            end)
        end,
        on_text_changed = function(text)
            local model = field.__model
            local spec = model and model.spec
            if not spec then return end
            local clean = tostring(text or ""):gsub("|", "")
            if clean == "" and spec.type ~= "string" then return end
            for _, elem in ipairs(state.selected) do
                local old = get_property(elem, spec.path)
                local value = parse_property_value(spec.type, clean, old)
                set_property(elem, spec.path, value)
            end
            request_editor_refresh(spec.path == "name" and "selection" or "values")
        end,
    }
    row:add(field)

    local item = { row = row, label = label, field = field }
    rows[index] = item
    return item
end

local function bind_property_row(item, model, visual_y)
    local spec = model.spec
    local display, mixed = mixed_value_for_selection(spec.path, spec.type)
    item.field.__model = model

    set_node_visible(item.row, true)
    set_udim_offset(item.row, "position", 0, 0, 10, visual_y)
    item.label:setText(spec.label)
    item.field:setText(display)
    item.field.textColor = mixed and COLORS.warning or COLORS.text
end

local function update_visible_property_values()
    local rows = state.properties_pool.rows or {}
    local updated = false
    for i = 1, #rows do
        local item = rows[i]
        local model = item.field and item.field.__model
        local spec = model and model.spec
        if spec and item.row.visible ~= false then
            local display, mixed = mixed_value_for_selection(spec.path, spec.type)
            item.field:setText(display)
            item.field.textColor = mixed and COLORS.warning or COLORS.text
            updated = true
        end
    end
    return updated
end

rebuild_properties = function()
    local header = ensure_properties_header()
    header.toggle:setText(state.properties_collapsed and "<" or ">")
    set_node_visible(header.label, not state.properties_collapsed)

    if state.property_values_dirty and not state.selection_dirty and not state.properties_collapsed then
        if update_visible_property_values() then
            state.properties_dirty = false
            state.property_values_dirty = false
            return
        end
    end

    if state.selection_dirty then
        build_properties_model()
    end

    local pool = state.properties_pool
    if pool.title then set_node_visible(pool.title, false) end
    if pool.empty then set_node_visible(pool.empty, false) end
    local sections = pool.sections or {}
    local rows = pool.rows or {}
    for i = 1, #sections do set_node_visible(sections[i].row, false) end
    for i = 1, #rows do set_node_visible(rows[i].row, false) end

    if state.properties_collapsed then
        state.properties_scroll_y = 0
        state.properties_dirty = false
        state.property_values_dirty = false
        return
    end

    state.properties_scroll_y = clamp(state.properties_scroll_y, 0,
        panel_scroll_max(right_panel, state.properties_content_h))
    local panel_rect = right_panel:get_screen_rect()
    local panel_h = panel_rect.size.y
    local scroll_y = state.properties_scroll_y
    local section_count, row_count = 0, 0

    for i = 1, #state.properties_model do
        local model = state.properties_model[i]
        local visual_y = model.y - scroll_y
        if visual_y + model.h >= 46 and visual_y <= panel_h then
            if model.type == "title" then
                local title = ensure_property_title()
                set_node_visible(title, true)
                set_udim_offset(title, "position", 0, 0, PANEL_PAD, visual_y)
                title:setText(model.text)
            elseif model.type == "empty" then
                local empty = ensure_property_empty()
                set_node_visible(empty, true)
                set_udim_offset(empty, "position", 0, 0, PANEL_PAD, visual_y)
                empty:setText(model.text)
            elseif model.type == "section" then
                section_count = section_count + 1
                local item = ensure_property_section(section_count)
                item.row.__model = model
                set_node_visible(item.row, true)
                set_udim_offset(item.row, "position", 0, 0, 6, visual_y)
                item.caret:setText(model.open and "v" or ">")
                item.label:setText(model.label)
            elseif model.type == "property" then
                row_count = row_count + 1
                bind_property_row(ensure_property_row(row_count), model, visual_y)
            end
        end
    end

    for i = section_count + 1, #sections do set_node_visible(sections[i].row, false) end
    for i = row_count + 1, #rows do set_node_visible(rows[i].row, false) end
    state.properties_dirty = false
    state.property_values_dirty = false
end

function Editor.close_context()
    context_root.visible = false
    state.open_context = nil
    remove_all_children(context_root)
    mark_editor_active("context")
end

local function add_context_action(label, y, fn)
    local item = make_text {
        text = label,
        textAlignX = "left",
        show_fill = true,
        fill_color = COLORS.panel2,
        show_outline = true,
        outline_color = COLORS.stroke,
        outline_thickness = 1,
        mousecheck = true,
        position = { offset = vec2(4, y) },
        size = { scale = vec2(1, 0), offset = vec2(-8, 30) },
        on_mouse_enter = function(self) self.fill_color = COLORS.panel3 end,
        on_mouse_leave = function(self) self.fill_color = COLORS.panel2 end,
        on_mouse_clicked = function(_, button)
            if button == 1 then
                Editor.close_context()
                if fn then fn() end
            end
        end,
    }
    context_root:add(item)
end

function Editor.open_context(x, y, target, source)
    remove_all_children(context_root)
    state.open_context = { x = x, y = y, target = target, source = source }
    mark_editor_active("context")
    local menu_w, menu_h = 240, 430
    context_root.position = {
        offset = vec2(clamp(x, 0, G.resolution.x - menu_w),
            clamp(y, TOOLBAR_H, G.resolution.y - menu_h))
    }
    context_root.size = { offset = vec2(menu_w, menu_h) }
    context_root.visible = true

    local parent = is_user_element(target) and target or (state.primary or design_root)
    if not is_user_element(parent) then parent = design_root end

    local cy = 5
    add_context_action("Insert Element", cy, function() add_user_element(parent, "Element") end); cy = cy + 32
    add_context_action("Insert Text", cy, function() add_user_element(parent, "Text") end); cy = cy + 32
    add_context_action("Insert Image", cy, function() add_user_element(parent, "Image") end); cy = cy + 34
    add_context_action("Copy", cy, copy_selection); cy = cy + 32
    add_context_action("Cut", cy, cut_selection); cy = cy + 32
    add_context_action("Paste", cy, function() paste_clipboard(parent) end); cy = cy + 32
    add_context_action("Duplicate", cy, duplicate_selection); cy = cy + 32
    add_context_action("Delete", cy, delete_selection); cy = cy + 32
    add_context_action("Toggle Visible", cy, function()
        with_history("visibility", function()
            for _, elem in ipairs(state.selected) do set_property(elem, "visible", elem.visible == false) end
        end)
    end); cy = cy + 32
    add_context_action("Move Up", cy, function() if state.primary then move_in_parent(state.primary, -1) end end); cy =
        cy + 32
    add_context_action("Move Down", cy, function() if state.primary then move_in_parent(state.primary, 1) end end); cy =
        cy + 32
    add_context_action("Attach/Reparent...", cy, function() state.pending_reparent = true end); cy = cy + 32
    add_context_action("Clear Selection", cy, clear_selection)
end

local function update_layout()
    local w, h = G.resolution.x, G.resolution.y
    -- wrap tools instead of losing Import/Export and preview controls at
    -- narrow window widths. leave the canvas usable when panels are expanded
    local tx, ty = 10, 8
    for _, item in ipairs(toolbar_buttons) do
        if tx > 10 and tx + item.width > w - 10 then tx, ty = 10, ty + 48 end
        set_udim_offset(item.node, "position", 0, 0, tx, ty)
        tx = tx + item.width + 7
    end
    TOOLBAR_H = ty + 48
    set_udim_offset(toolbar, "size", 1, 0, 0, TOOLBAR_H)
    local lw = explorer_width()
    local rw = properties_width()
    if w < 900 then
        lw = state.explorer_collapsed and PANEL_COLLAPSED_W or math.floor(w * 0.22)
        rw = state.properties_collapsed and PANEL_COLLAPSED_W or math.floor(w * 0.30)
    end
    set_udim_offset(left_panel, "position", 0, 0, 0, TOOLBAR_H)
    set_udim_offset(left_panel, "size", 0, 1, lw, -TOOLBAR_H)
    set_udim_offset(right_panel, "position", 1, 0, 0, TOOLBAR_H)
    set_udim_offset(right_panel, "size", 0, 1, rw, -TOOLBAR_H)
    set_udim_offset(center_panel, "position", 0, 0, lw, TOOLBAR_H)
    set_udim_offset(center_panel, "size", 1, 1, -(lw + rw), -TOOLBAR_H)

    local cr = center_panel:get_screen_rect()
    local pad = 26
    local fit = math.min((cr.size.x - pad * 2) / state.preview_w, (cr.size.y - pad * 2) / state.preview_h)
    fit = math.max(0.05, math.min(1, fit))
    if state.auto_zoom then state.zoom = fit end

    local zw = state.preview_w * state.zoom
    local zh = state.preview_h * state.zoom
    state.preview_screen.x = cr.position.x + (cr.size.x - zw) * 0.5 + state.pan.x
    state.preview_screen.y = cr.position.y + (cr.size.y - zh) * 0.5 + state.pan.y
    state.preview_screen.w = zw
    state.preview_screen.h = zh

    status_text.visible = w >= 1180
    status_text:setText(("%dx%d  %.0f%%  %s"):format(state.preview_w, state.preview_h, state.zoom * 100, grid_label()))
    if grid_button then grid_button:setText(grid_label()) end
    if resolution_button then
        local preset = DEFAULT_PRESETS[state.preset_index]
        resolution_button:setText(preset.name)
    end
end

local function draw_grid()
    local g = grid_size()
    if not g or g <= 0 then return end
    local ps = state.preview_screen
    local cr = center_panel:get_screen_rect()
    local z = state.zoom
    love.graphics.push("all")
    love.graphics.setScissor(math.floor(cr.position.x + 0.5), math.floor(cr.position.y + 0.5),
        math.floor(cr.size.x + 0.5), math.floor(cr.size.y + 0.5))
    love.graphics.setColor(0, 0, 0, 0.16)
    love.graphics.setLineWidth(1)
    for x = 0, state.preview_w, g do
        local sx = ps.x + x * z
        love.graphics.line(sx, ps.y, sx, ps.y + ps.h)
    end
    for y = 0, state.preview_h, g do
        local sy = ps.y + y * z
        love.graphics.line(ps.x, sy, ps.x + ps.w, sy)
    end
    love.graphics.pop()
end


local function get_safe_scissor(rect)
    local x1     = rect.position.x
    local y1     = rect.position.y
    local x2     = rect.position.x + rect.size.x
    local y2     = rect.position.y + rect.size.y

    -- normalize in case size.x or size.y is negative
    local left   = math.floor(math.min(x1, x2) + 0.5)
    local top    = math.floor(math.min(y1, y2) + 0.5)
    local right  = math.floor(math.max(x1, x2) + 0.5)
    local bottom = math.floor(math.max(y1, y2) + 0.5)

    local w      = right - left
    local h      = bottom - top

    -- do not call setScissor with zero/negative dimensions
    if w <= 0 or h <= 0 then
        return nil
    end

    return left, top, w, h
end

local function with_center_scissor(fn)
    local cr = center_panel:get_screen_rect()
    local sx, sy, sw, sh = get_safe_scissor(cr)

    if not sx then
        return
    end

    love.graphics.push("all")
    love.graphics.setScissor(sx, sy, sw, sh)
    fn()
    love.graphics.pop()
end

local function draw_design_surface()
    local ps = state.preview_screen

    with_center_scissor(function()
        love.graphics.setColor(0, 0, 0, 0.45)
        love.graphics.rectangle("fill", ps.x + 6, ps.y + 8, ps.w, ps.h)
    end)

    --[[ the grid draws UNDER the design tree so grid lines never cut through
    text/font previews ]]
    draw_grid()

    with_center_scissor(function()
        love.graphics.translate(ps.x, ps.y)
        love.graphics.scale(state.zoom, state.zoom)

        Element._draw_child(preview_root, get_preview_parent_rect())
    end)

    with_center_scissor(function()
        love.graphics.setLineWidth(2)
        love.graphics.setColor(COLORS.stroke)
        love.graphics.rectangle("line", ps.x, ps.y, ps.w, ps.h)

        love.graphics.setColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.22)
        love.graphics.rectangle("line", ps.x - 2, ps.y - 2, ps.w + 4, ps.h + 4)
    end)
end

local shortcut_font
local shortcut_text = table.concat({
    "Middle drag / H+drag: Pan",
    "Wheel: Scroll canvas   Ctrl+Wheel: Zoom",
    "Ctrl+Z/Y: Undo/Redo",
    "Ctrl+C/X/V/D: Copy/Cut/Paste/Dupe",
    "Delete: Delete   Esc: Clear/Close",
    "Q while transform: Offset mode",
    "Double-click Text: Edit text",
}, "\n")
local shortcut_layout
local function draw_shortcuts()
    local cr = center_panel:get_screen_rect()
    shortcut_font = shortcut_font or require("engine/graphics/font_manager").get(nil, 13)
    local pad = 10
    local available = math.floor(cr.size.x - 24 - 2 * pad)
    if available < 1 then return end
    if not shortcut_layout or shortcut_layout.available ~= available then
        local width, lines = shortcut_font:getWrap(shortcut_text, available)
        shortcut_layout = { available = available, width = width, lines = lines }
    end
    local lines = shortcut_layout.lines
    local line_h = shortcut_font:getHeight() + 3
    local w = shortcut_layout.width + 2 * pad
    local h = #lines * line_h + pad * 2
    local x = cr.position.x + cr.size.x - w - 12
    local y = cr.position.y + cr.size.y - h - 12
    love.graphics.push("all")
    love.graphics.setFont(shortcut_font)
    love.graphics.setColor(0.04, 0.045, 0.055, 0.86)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setLineWidth(1)
    love.graphics.setColor(COLORS.stroke)
    love.graphics.rectangle("line", x, y, w, h)
    love.graphics.setColor(COLORS.text)
    for i, line in ipairs(lines) do
        love.graphics.print(line, x + pad, y + pad + (i - 1) * line_h)
    end
    love.graphics.pop()
end

local function draw_selection_overlay()
    if #state.selected == 0 then return end
    local cr = center_panel:get_screen_rect()
    love.graphics.push("all")
    love.graphics.setScissor(math.floor(cr.position.x + 0.5), math.floor(cr.position.y + 0.5),
        math.floor(cr.size.x + 0.5), math.floor(cr.size.y + 0.5))
    love.graphics.setLineWidth(2)
    for _, elem in ipairs(state.selected) do
        if is_user_element(elem) then
            local rect = get_preview_rect(elem)
            if rect then
                local sr = preview_to_screen_rect(rect)
                local ghost = elem.visible == false
                love.graphics.setColor(ghost and COLORS.warning[1] or COLORS.accent[1],
                    ghost and COLORS.warning[2] or COLORS.accent[2],
                    ghost and COLORS.warning[3] or COLORS.accent[3],
                    ghost and 0.85 or 0.95)
                love.graphics.rectangle("line", sr.x, sr.y, sr.w, sr.h)
                if ghost then
                    love.graphics.setColor(COLORS.warning[1], COLORS.warning[2], COLORS.warning[3], 0.12)
                    love.graphics.rectangle("fill", sr.x, sr.y, sr.w, sr.h)
                end
            end
        end
    end
    if state.primary then
        local rect = get_preview_rect(state.primary)
        if rect then
            local sr = preview_to_screen_rect(rect)
            love.graphics.setColor(COLORS.accent)
            local handles = Editor.resize_handles_for_screen_rect(sr)
            for _, h in pairs(handles) do
                love.graphics.rectangle("fill", h.x - HANDLE_SIZE * 0.5, h.y - HANDLE_SIZE * 0.5, HANDLE_SIZE,
                    HANDLE_SIZE)
            end
        end
    end
    love.graphics.pop()
end

function Editor.resize_handles_for_screen_rect(sr)
    local x1, y1, x2, y2 = sr.x, sr.y, sr.x + sr.w, sr.y + sr.h
    local cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
    return {
        tl = { x = x1, y = y1 },
        top = { x = cx, y = y1 },
        tr = { x = x2, y = y1 },
        right = { x = x2, y = cy },
        br = { x = x2, y = y2 },
        bottom = { x = cx, y = y2 },
        bl = { x = x1, y = y2 },
        left = { x = x1, y = cy },
    }
end

function Editor.hit_resize_handle(x, y)
    if not state.primary then return nil end
    local rect = get_preview_rect(state.primary)
    if not rect then return nil end
    local sr = preview_to_screen_rect(rect)
    for name, h in pairs(Editor.resize_handles_for_screen_rect(sr)) do
        if x >= h.x - HANDLE_SIZE and x <= h.x + HANDLE_SIZE and y >= h.y - HANDLE_SIZE and y <= h.y + HANDLE_SIZE then
            return name
        end
    end
    return nil
end

local function rect_in_parent(elem)
    local rect = get_preview_rect(elem)
    local parent_rect = get_parent_preview_rect(elem)
    if not rect or not parent_rect then return nil end
    return {
        tlx = rect.position.x - parent_rect.position.x,
        tly = rect.position.y - parent_rect.position.y,
        brx = rect.position.x - parent_rect.position.x + rect.size.x,
        bry = rect.position.y - parent_rect.position.y + rect.size.y,
        parent_w = parent_rect.size.x,
        parent_h = parent_rect.size.y,
        position = udim_copy(elem.position),
        size = udim_copy(elem.size),
        anchor = udim_copy(elem.anchor),
    }
end

function Editor.begin_move(x, y)
    if #state.selected == 0 then return end
    mark_editor_active("move")
    local px, py = screen_to_preview(x, y)
    local items = {}
    for _, elem in ipairs(selected_roots()) do
        local data = rect_in_parent(elem)
        if data then
            data.elem = elem
            items[#items + 1] = data
        end
    end
    state.active_op = {
        kind = "move",
        start_x = px,
        start_y = py,
        items = items,
    }
end

function Editor.begin_resize(handle, x, y)
    if not state.primary then return end
    mark_editor_active("resize")
    local px, py = screen_to_preview(x, y)
    local data = rect_in_parent(state.primary)
    if not data then return end
    data.elem = state.primary
    state.active_op = {
        kind = "resize",
        handle = handle,
        start_x = px,
        start_y = py,
        items = { data },
    }
end

local function apply_rect(elem, data, tlx, tly, brx, bry, offset_mode)
    local width = math.max(MIN_SIZE_PX, brx - tlx)
    local height = math.max(MIN_SIZE_PX, bry - tly)
    local pos = ensure_udim(elem, "position")
    local size = ensure_udim(elem, "size")
    local anch = elem.anchor or { scale = vec2(), offset = vec2() }
    local ax = tlx + width * ((anch.scale and anch.scale.x) or 0) + ((anch.offset and anch.offset.x) or 0)
    local ay = tly + height * ((anch.scale and anch.scale.y) or 0) + ((anch.offset and anch.offset.y) or 0)
    with_dirty_batch(elem, function()
        if offset_mode then
            pos.offset.x = ax - data.parent_w * (pos.scale.x or 0)
            pos.offset.y = ay - data.parent_h * (pos.scale.y or 0)
            size.offset.x = width - data.parent_w * (size.scale.x or 0)
            size.offset.y = height - data.parent_h * (size.scale.y or 0)
        else
            pos.scale.x = data.parent_w ~= 0 and (ax - (pos.offset.x or 0)) / data.parent_w or 0
            pos.scale.y = data.parent_h ~= 0 and (ay - (pos.offset.y or 0)) / data.parent_h or 0
            size.scale.x = data.parent_w ~= 0 and (width - (size.offset.x or 0)) / data.parent_w or 0
            size.scale.y = data.parent_h ~= 0 and (height - (size.offset.y or 0)) / data.parent_h or 0
        end
        elem:mark_dirty("position")
        elem:mark_dirty("size")
    end)
end

local function update_transform()
    local op = state.active_op
    if not op then return end
    local mx, my = input_mgr.mouse.position.x, input_mgr.mouse.position.y
    local px, py = screen_to_preview(mx, my)
    local dx, dy = px - op.start_x, py - op.start_y
    local offset_mode = q_down()

    --[[ nothing moved since the last application: skip the whole apply pass
    (rect math + dirty marks used to run every frame of a stationary drag) ]]
    if dx == op._last_dx and dy == op._last_dy and offset_mode == op._last_offset_mode then
        return
    end
    op._last_dx, op._last_dy, op._last_offset_mode = dx, dy, offset_mode

    if state.pending_snapshot then
        state.pending_snapshot = nil
        record_snapshot()
    end

    if op.kind == "move" then
        for _, item in ipairs(op.items) do
            local width = item.brx - item.tlx
            local height = item.bry - item.tly
            local tlx = clamp(snap(item.tlx + dx), -width, item.parent_w)
            local tly = clamp(snap(item.tly + dy), -height, item.parent_h)
            apply_rect(item.elem, item, tlx, tly, tlx + width, tly + height, offset_mode)
        end
    elseif op.kind == "resize" then
        local item = op.items[1]
        local tlx, tly, brx, bry = item.tlx, item.tly, item.brx, item.bry
        local h = op.handle
        if h == "left" or h == "tl" or h == "bl" then tlx = snap(clamp(item.tlx + dx, 0, brx - MIN_SIZE_PX)) end
        if h == "right" or h == "tr" or h == "br" then brx = snap(math.max(tlx + MIN_SIZE_PX, item.brx + dx)) end
        if h == "top" or h == "tl" or h == "tr" then tly = snap(clamp(item.tly + dy, 0, bry - MIN_SIZE_PX)) end
        if h == "bottom" or h == "bl" or h == "br" then bry = snap(math.max(tly + MIN_SIZE_PX, item.bry + dy)) end
        apply_rect(item.elem, item, tlx, tly, brx, bry, offset_mode)
    end
    local now = love.timer.getTime()
    if now - (state.property_value_update_at or 0) >= 0.05 then
        state.property_value_update_at = now
        request_editor_refresh("values")
    else
        mark_editor_active("transform")
    end
end

function Editor.end_transform()
    state.pending_snapshot = nil
    if state.active_op then
        state.active_op = nil
        state.property_value_update_at = 0
        request_editor_refresh("values")
    end
end

local function snapshot_design_lua()
    return export_design_to_lua()
end

local function restore_design_lua(src)
    state.restoring = true
    local roots, err = import_lua_string(src or "")
    if roots then
        replace_design_with_roots(roots)
    else
        print("[ui editor] undo failed: " .. tostring(err))
    end
    state.restoring = false
end

record_snapshot = function()
    if state.restoring or state.history_suppressed then return end
    state.undo_stack[#state.undo_stack + 1] = snapshot_design_lua()
    state.redo_stack = {}
    if #state.undo_stack > 64 then table.remove(state.undo_stack, 1) end
end

local mutating_wrappers_installed = false
local function install_mutating_wrappers()
    if mutating_wrappers_installed then return end
    mutating_wrappers_installed = true

    local raw_add_user_element = add_user_element
    add_user_element = function(...)
        record_snapshot()
        return raw_add_user_element(...)
    end

    local raw_delete_selection = delete_selection
    delete_selection = function(...)
        record_snapshot()
        return raw_delete_selection(...)
    end

    local raw_cut_selection = cut_selection
    cut_selection = function(...)
        record_snapshot()
        return raw_cut_selection(...)
    end

    local raw_paste_clipboard = paste_clipboard
    paste_clipboard = function(...)
        record_snapshot()
        return raw_paste_clipboard(...)
    end

    local raw_duplicate_selection = duplicate_selection
    duplicate_selection = function(...)
        record_snapshot()
        return raw_duplicate_selection(...)
    end

    local raw_import_from_clipboard = import_from_clipboard
    import_from_clipboard = function(...)
        record_snapshot()
        return raw_import_from_clipboard(...)
    end

    local raw_move_in_parent = move_in_parent
    move_in_parent = function(...)
        record_snapshot()
        return raw_move_in_parent(...)
    end

    local raw_reparent_selection = reparent_selection
    reparent_selection = function(...)
        record_snapshot()
        return raw_reparent_selection(...)
    end

    --[[ lazy capture: the undo snapshot serializes the whole design tree
    (36-43ms at 1000 elements) and used to run on every mouse-down ,
    click-to-select paid it without any mutation. the flag arms here and the
    capture happens on the first ACTUAL apply in update_transform ]]
    local raw_begin_move = Editor.begin_move
    Editor.begin_move = function(...)
        if #state.selected > 0 then state.pending_snapshot = true end
        return raw_begin_move(...)
    end

    local raw_begin_resize = Editor.begin_resize
    Editor.begin_resize = function(...)
        if state.primary then state.pending_snapshot = true end
        return raw_begin_resize(...)
    end
end

local function undo()
    local prev = table.remove(state.undo_stack)
    if not prev then return end
    state.redo_stack[#state.redo_stack + 1] = snapshot_design_lua()
    restore_design_lua(prev)
end

local function redo()
    local next_snapshot = table.remove(state.redo_stack)
    if not next_snapshot then return end
    state.undo_stack[#state.undo_stack + 1] = snapshot_design_lua()
    restore_design_lua(next_snapshot)
end

local function select_all()
    local list = {}
    local function scan(node)
        for _, child in ipairs(node.children or {}) do
            if is_user_element(child) then
                list[#list + 1] = child
                scan(child)
            end
        end
    end
    scan(design_root)
    set_selection(list, list[1])
end

local function on_key_pressed(key)
    if input_mgr.state.typing then return end
    if key == "escape" then
        if state.open_context then Editor.close_context() else clear_selection() end
        state.pending_reparent = false
        return
    end
    if key == "delete" or key == "backspace" then
        delete_selection(); return
    end
    if not ctrl_down() then return end
    if key == "z" then
        if shift_down() then redo() else undo() end
    elseif key == "y" then
        redo()
    elseif key == "c" then
        copy_selection()
    elseif key == "x" then
        cut_selection()
    elseif key == "v" then
        paste_clipboard(state.primary)
    elseif key == "d" then
        duplicate_selection()
    elseif key == "a" then
        select_all()
    end
end

local function on_wheel(x, y)
    local mp = input_mgr.mouse.position
    local lr = left_panel:get_screen_rect()
    if mp.x >= lr.position.x and mp.y >= lr.position.y
        and mp.x <= lr.position.x + lr.size.x and mp.y <= lr.position.y + lr.size.y then
        if not state.explorer_collapsed then
            state.explorer_scroll_y = clamp(
                state.explorer_scroll_y - y * 48 - x * 24,
                0,
                panel_scroll_max(left_panel, state.explorer_content_h)
            )
            state.explorer_dirty = true
            mark_editor_active("explorer_scroll")
        end
        return
    end

    local rr = right_panel:get_screen_rect()
    if mp.x >= rr.position.x and mp.y >= rr.position.y
        and mp.x <= rr.position.x + rr.size.x and mp.y <= rr.position.y + rr.size.y then
        if not state.properties_collapsed then
            state.properties_scroll_y = clamp(
                state.properties_scroll_y - y * 48 - x * 24,
                0,
                panel_scroll_max(right_panel, state.properties_content_h)
            )
            state.properties_dirty = true
            mark_editor_active("properties_scroll")
        end
        return
    end

    local cr = center_panel:get_screen_rect()
    if mp.x < cr.position.x or mp.y < cr.position.y or mp.x > cr.position.x + cr.size.x or mp.y > cr.position.y + cr.size.y then
        return
    end
    if ctrl_down() then
        state.auto_zoom = false
        local old = state.zoom
        state.zoom = clamp(state.zoom * (1 + y * 0.08), 0.05, 4)
        local factor = state.zoom / old
        state.pan.x = (state.pan.x - (mp.x - cr.position.x - cr.size.x * 0.5)) * factor +
            (mp.x - cr.position.x - cr.size.x * 0.5)
        state.pan.y = (state.pan.y - (mp.y - cr.position.y - cr.size.y * 0.5)) * factor +
            (mp.y - cr.position.y - cr.size.y * 0.5)
    else
        state.pan.x = state.pan.x + x * 24
        state.pan.y = state.pan.y + y * 48
        state.auto_zoom = false
    end
    mark_editor_active("canvas_wheel")
end

local function install_input_hooks()
    G.pipeline:register("input_start", "ui_editor_shortcuts", function(key)
        mark_editor_active("key")
        on_key_pressed(key)
    end, 100)

    input_mgr.add_observer("keypressed", function() mark_editor_active("key") end)
    input_mgr.add_observer("textinput", function() mark_editor_active("text") end)
    input_mgr.add_observer("mousepressed", function() mark_editor_active("mouse") end)
    input_mgr.add_observer("mousereleased", function() mark_editor_active("mouse") end)
    input_mgr.add_observer("mousemoved", function() mark_editor_active("mouse") end)
    input_mgr.add_observer("wheelmoved", function(x, y)
        mark_editor_active("wheel")
        on_wheel(x, y)
    end)
end

local function create_lists()
    explorer_list = make_element {
        name = "ExplorerList",
        position = { offset = vec2(0, 0) },
        size = { scale = vec2(1, 1) },
    }
    left_panel:add(explorer_list)

    properties_list = make_element {
        name = "PropertiesList",
        position = { offset = vec2(0, 0) },
        size = { scale = vec2(1, 1) },
    }
    right_panel:add(properties_list)
end

local function initialize()
    create_roots()
    create_lists()
    add_toolbar_buttons()
    install_mutating_wrappers()
    install_input_hooks()
    assign_editor_ids(design_root)
    bump_structure()
    rebuild_explorer()
    rebuild_properties()
end

initialize()

G.pipeline:register('update', 'ui_editor', function()
    update_layout()
    update_pan()
    update_transform()
    if state.text_editing then
        local captured = input_mgr.state.captured_element
        if captured ~= state.text_editing.elem then
            local elem = state.text_editing.elem
            if elem then
                elem._editor_text_editing = nil
                elem.editable = state.text_editing.old_editable
            end
            state.text_editing = nil
        end
    end
    if state.explorer_drag then
        local active = input_mgr.mouse.state.active[1]
        if active then
            local mp = input_mgr.mouse.position
            local dx = mp.x - (state.explorer_drag.start_x or mp.x)
            local dy = mp.y - (state.explorer_drag.start_y or mp.y)
            if math.abs(dx) + math.abs(dy) > 7 then
                state.explorer_drag.active = true
            end
        else
            state.explorer_drag = nil
        end
    end
    if state.primary and not is_user_element(state.primary) then
        clear_selection()
    end
    for i = #state.selected, 1, -1 do
        if not is_user_element(state.selected[i]) then
            table.remove(state.selected, i)
            request_editor_refresh("selection")
        end
    end

    local captured = input_mgr.state.captured_element
    if state.explorer_dirty and not captured then rebuild_explorer() end
    if state.properties_dirty and not captured then rebuild_properties() end
end, 2)

-- Clipboard buttons and application code share the same serialization path
-- imported Lua is executable code, only import designs you trust
function Editor.import(source)
    local roots, err = import_lua_string(source)
    if not roots then return nil, err end
    record_snapshot()
    replace_design_with_roots(roots)
    return roots
end

Editor.export = export_design_to_lua
Editor.undo = undo
Editor.redo = redo

G.pipeline:register('draw', 'ui_editor', function()
    editor_root:draw()
    draw_design_surface()
    draw_selection_overlay()
    draw_shortcuts()
    context_root:draw()
end, 2)

return Editor
