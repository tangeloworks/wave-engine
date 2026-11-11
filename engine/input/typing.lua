local typing = {}

local utf8 = require("utf8")
typing.active = false
typing.text = ""
typing.captured_element = nil
typing.virtual_keyboard = nil
typing.key_repeat_timer = nil
typing.active_key = false
typing.cursor_visible = true
typing.cursor_blink_timer = 0
typing.cursor_blink_rate = 0.5
typing.cursor_index = 0
typing.selection_anchor = nil
typing.preferred_col = nil
typing.keyboard_visible = false
typing.keyboard_layout = {
    { "preview" },
    { "1",      "2",     "3",   "4",    "5",     "6",     "7", "8", "9", "0" },
    { "Q",      "W",     "E",   "R",    "T",     "Y",     "U", "I", "O", "P" },
    { "A",      "S",     "D",   "F",    "G",     "H",     "J", "K", "L", ";" },
    { "Z",      "X",     "C",   "V",    "B",     "N",     "M", ",", ".", "/" },
    { "=",      "-",     "+",   "(",    ")",     "[",     "]", "{", "}", "\\" },
    { "<",      ">",     "!",   "?",    "@",     "#",     "$", "%", "^", "&" },
    { "lower",  "SPACE", "DEL", "CTRL", "SHIFT", "RETURN" }
}
local kb_state = {
    uppercase = true,
    shift_toggle = false,
    ctrl_toggle = false,
    position = { x = 0.5, y = 1.5 }
}
local key_dims = {
    ['preview'] = { width = 300, height = 30 },
    ["lower"] = { width = 50, height = 50 },
    ["SPACE"] = { width = 50, height = 30 },
    ["DEL"] = { width = 30, height = 30 },
    ["CTRL"] = { width = 40, height = 40 },
    ["SHIFT"] = { width = 40, height = 40 },
    ["RETURN"] = { width = 50, height = 50 },
}

typing.using_native_text_input = false

local function update_captured_element()
    if typing.captured_element then
        local prefix = typing.captured_element.text_prefix or ""
        local clean_text = typing.text
        clean_text = clean_text:gsub("|", "")
        if prefix ~= "" then
            clean_text = prefix .. clean_text
        end
        local final_text
        local sel_active = (typing.selection_anchor ~= nil and typing.selection_anchor ~= typing.cursor_index)
        if typing.active and typing.cursor_visible and not sel_active then
            local adjusted_position = typing.cursor_index + #prefix
            final_text = clean_text:sub(1, adjusted_position) .. "|" .. clean_text:sub(adjusted_position + 1)
        else
            final_text = clean_text
        end
        typing.captured_element.text = final_text
    end
    if typing.virtual_keyboard and typing.virtual_keyboard.elements then
        local preview = typing.virtual_keyboard.elements['preview']
        if preview then
            if preview.setText then
                preview:setText(typing.text)
            else
                preview.text = typing.text
                if preview.mark_dirty then preview:mark_dirty() end
            end
        end
    end
    if typing.captured_element then
        local a, b = typing.cursor_index, typing.cursor_index
        if typing.selection_anchor and typing.selection_anchor ~= typing.cursor_index then
            a = math.min(typing.selection_anchor, typing.cursor_index)
            b = math.max(typing.selection_anchor, typing.cursor_index)
        end
        typing.captured_element._selection = {
            active = (a ~= b),
            a = a,
            b = b,
            text = typing.text,
            prefix = typing.captured_element.text_prefix or ""
        }
        if typing.captured_element.mark_dirty then typing.captured_element:mark_dirty() end
    end
end

local function update_cursor_blink(dt)
    if not typing.active then return end
    typing.cursor_blink_timer = typing.cursor_blink_timer + dt
    if typing.cursor_blink_timer >= typing.cursor_blink_rate then
        typing.cursor_visible = not typing.cursor_visible
        typing.cursor_blink_timer = 0
        update_captured_element()
    end
end

local function show_cursor()
    typing.cursor_visible = true
    typing.cursor_blink_timer = 0
    update_captured_element()
end

local function hide_cursor()
    typing.cursor_visible = false
    update_captured_element()
end

-- Selection helpers (module scope so they are usable in text input and key actions)
local function has_selection()
    return typing.selection_anchor ~= nil and typing.selection_anchor ~= typing.cursor_index
end

local function selection_range()
    if not typing.selection_anchor or typing.selection_anchor == typing.cursor_index then
        return typing.cursor_index,
            typing.cursor_index
    end
    if typing.selection_anchor < typing.cursor_index then
        return typing.selection_anchor, typing.cursor_index
    else
        return
            typing.cursor_index, typing.selection_anchor
    end
end

local function clear_selection()
    typing.selection_anchor = typing.cursor_index
end

local function delete_range(a, b)
    typing.text = typing.text:sub(1, a) .. typing.text:sub(b + 1)
    typing.cursor_index = a
    clear_selection()
end

local function delete_selection_if_any()
    if has_selection() then
        local a, b = selection_range()
        delete_range(a, b)
        return true
    end
    return false
end

local function insert_text_at_cursor(text)
    text = tostring(text or "")
    if text == "" then return end
    delete_selection_if_any()
    typing.text = typing.text:sub(1, typing.cursor_index) .. text .. typing.text:sub(typing.cursor_index + 1)
    typing.cursor_index = typing.cursor_index + #text
    typing.selection_anchor = typing.cursor_index
    typing.preferred_col = nil
    update_captured_element()
    show_cursor()
end

local function execute_type_action(action, key)
    local function modifiers()
        local st = input_mgr.state.active_keys
        local isMac = love.system.getOS() == 'OS X'
        local ctrl = st['lctrl'] or st['rctrl'] or false
        local alt = st['lalt'] or st['ralt'] or false
        local gui = st['lgui'] or st['rgui'] or false
        local shift = st['lshift'] or st['rshift'] or kb_state.shift_toggle or false
        local word = (isMac and alt) or (not isMac and ctrl) or kb_state.ctrl_toggle
        local doc = gui or (not isMac and ctrl)
        return { ctrl = ctrl, alt = alt, gui = gui, shift = shift, word = word, doc = doc, meta = ctrl or gui }
    end

    local function clamp_index(i)
        i = tonumber(i) or 0
        if i < 0 then return 0 end
        local n = #typing.text
        if i > n then return n end
        return i
    end

    local function utf8_offset(s, n, i)
        local ok, off = pcall(utf8.offset, s, n, i)
        if ok then return off end
        return nil
    end

    local function next_char_index(idx)
        idx = clamp_index(idx)
        if idx >= #typing.text then return #typing.text end
        local off = utf8_offset(typing.text, 2, idx + 1)
        return clamp_index(off and (off - 1) or #typing.text)
    end

    local function prev_char_index(idx)
        idx = clamp_index(idx)
        if idx <= 0 then return 0 end
        local off = utf8_offset(typing.text, -1, idx + 1)
        return clamp_index(off and (off - 1) or 0)
    end

    local function char_after_index(idx)
        idx = clamp_index(idx)
        if idx >= #typing.text then return nil end
        local start = idx + 1
        local finish = next_char_index(idx)
        if finish < start then return nil end
        return start, finish, typing.text:sub(start, finish)
    end

    local function char_before_index(idx)
        idx = clamp_index(idx)
        if idx <= 0 then return nil end
        local start = utf8_offset(typing.text, -1, idx + 1) or idx
        start = math.max(1, start)
        return start, idx, typing.text:sub(start, idx)
    end

    local function char_kind(ch)
        if not ch or ch == "" then return nil end
        if ch:match("^%s+$") then return "space" end
        if ch:match("^[%w_]+$") then return "word" end
        return "punct"
    end

    local function byte_index_from_line_col(lines, line_idx, col_cp)
        line_idx = math.max(1, math.min(#lines, line_idx))
        local before = 0
        for i = 1, line_idx - 1 do
            before = before + #lines[i] + 1 -- include newline
        end
        local line = lines[line_idx]
        local pos = 0
        local cp = 0
        for p, _ in utf8.codes(line) do
            cp = cp + 1
            local next_start = utf8_offset(line, 2, p)
            pos = next_start and (next_start - 1) or #line
            if cp >= col_cp then
                break
            end
        end
        if col_cp <= 0 then pos = 0 elseif col_cp > cp then pos = #line end
        return clamp_index(before + pos)
    end

    local function get_line_col_from_index(idx)
        idx = clamp_index(idx)
        local lines = {}
        for s in (typing.text .. "\n"):gmatch("(.-)\n") do table.insert(lines, s) end
        if #lines == 0 then lines = { "" } end
        local line_idx = 1
        local acc = 0
        for i = 1, #lines do
            local ln = lines[i]
            local len = #ln
            if idx <= acc + len then
                line_idx = i
                break
            end
            acc = acc + len + 1
            line_idx = i + 1
        end
        local line_start = 0
        for i = 1, line_idx - 1 do line_start = line_start + #lines[i] + 1 end
        local col_bytes = idx - line_start
        local col_cp = 0
        for _p, _c in utf8.codes(typing.text:sub(line_start + 1, idx)) do col_cp = col_cp + 1 end
        return lines, line_idx, col_cp
    end

    local function prev_word_index(idx)
        idx = clamp_index(idx)
        if idx <= 0 then return 0 end
        local i = idx
        while i > 0 do
            local start, _, ch = char_before_index(i)
            if char_kind(ch) == "space" then i = start - 1 else break end
        end
        local _, _, ch = char_before_index(i)
        local wanted = char_kind(ch)
        if not wanted then return 0 end
        while i > 0 do
            local start, _, current = char_before_index(i)
            if char_kind(current) == wanted then i = start - 1 else break end
        end
        return clamp_index(i)
    end

    local function next_word_index(idx)
        idx = clamp_index(idx)
        if idx >= #typing.text then return #typing.text end
        local i = idx
        local _, finish, ch = char_after_index(i)
        local wanted = char_kind(ch)
        if wanted == "space" then
            while i < #typing.text do
                local _, e, current = char_after_index(i)
                if char_kind(current) == "space" then i = e else break end
            end
            return clamp_index(i)
        end
        while i < #typing.text do
            local _, e, current = char_after_index(i)
            if char_kind(current) == wanted then i = e else break end
        end
        while i < #typing.text do
            local _, e, current = char_after_index(i)
            if char_kind(current) == "space" then i = e else break end
        end
        return clamp_index(i)
    end

    local function move_cursor_to(new_idx, keep_anchor, preserve_col)
        local old_idx = typing.cursor_index
        new_idx = clamp_index(new_idx)
        if keep_anchor and typing.selection_anchor == nil then
            typing.selection_anchor = old_idx
        end
        typing.cursor_index = new_idx
        if not keep_anchor then typing.selection_anchor = typing.cursor_index end
        if not preserve_col then typing.preferred_col = nil end
        update_captured_element(); show_cursor()
    end

    local function move_horizontal(dir)
        local m = modifiers()
        if m.word then
            if dir < 0 then
                move_cursor_to(prev_word_index(typing.cursor_index), m.shift)
            else
                move_cursor_to(next_word_index(typing.cursor_index), m.shift)
            end
        else
            if dir < 0 then
                move_cursor_to(prev_char_index(typing.cursor_index), m.shift)
            else
                move_cursor_to(next_char_index(typing.cursor_index), m.shift)
            end
        end
    end

    local function move_vertical(dir)
        local m = modifiers()
        local lines, line_idx, col_cp = get_line_col_from_index(typing.cursor_index)
        typing.preferred_col = typing.preferred_col or col_cp
        local new_line = line_idx + dir
        new_line = math.max(1, math.min(#lines, new_line))
        local target_col = typing.preferred_col
        -- clamp to line length
        local line_cp_len = 0
        for _p, _c in utf8.codes(lines[new_line]) do line_cp_len = line_cp_len + 1 end
        target_col = math.max(0, math.min(line_cp_len, target_col))
        local new_idx = byte_index_from_line_col(lines, new_line, target_col)
        move_cursor_to(new_idx, m.shift, true)
    end

    local function move_home_end(to_end)
        local m = modifiers()
        local lines, line_idx, _col = get_line_col_from_index(typing.cursor_index)
        local new_idx
        if m.doc then
            new_idx = to_end and #typing.text or 0
        else
            -- start/end of current line
            local before = 0
            for i = 1, line_idx - 1 do before = before + #lines[i] + 1 end
            if to_end then
                new_idx = before + #lines[line_idx]
            else
                new_idx = before
            end
        end
        move_cursor_to(new_idx, m.shift)
    end

    local function select_all()
        typing.selection_anchor = 0
        typing.cursor_index = #typing.text
        typing.preferred_col = nil
        update_captured_element(); show_cursor()
    end

    local actions = {
        backspace = function()
            local m = modifiers()
            if delete_selection_if_any() then
                update_captured_element(); show_cursor(); return
            end
            if typing.cursor_index <= 0 then return end
            local new_idx = m.word and prev_word_index(typing.cursor_index) or prev_char_index(typing.cursor_index)
            delete_range(new_idx, typing.cursor_index)
            update_captured_element(); show_cursor()
        end,
        delete = function()
            local m = modifiers()
            if delete_selection_if_any() then
                update_captured_element(); show_cursor(); return
            end
            if typing.cursor_index >= #typing.text then return end
            local new_idx = m.word and next_word_index(typing.cursor_index) or next_char_index(typing.cursor_index)
            delete_range(typing.cursor_index, new_idx)
            update_captured_element(); show_cursor()
        end,
        del = function()
            return actions.delete()
        end,
        left = function() move_horizontal(-1) end,
        right = function() move_horizontal(1) end,
        up = function() move_vertical(-1) end,
        down = function() move_vertical(1) end,
        home = function() move_home_end(false) end,
        ['end'] = function() move_home_end(true) end,
        a = function()
            local m = modifiers()
            if m.meta then
                select_all()
            end
        end,
        c = function()
            local m = modifiers()
            if not m.meta then return end
            if has_selection() then
                local a, b = selection_range()
                local selected = typing.text:sub(a + 1, b)
                love.system.setClipboardText(selected or "")
            end
        end,
        x = function()
            local m = modifiers()
            if not m.meta then return end
            if has_selection() then
                local a, b = selection_range()
                local selected = typing.text:sub(a + 1, b)
                love.system.setClipboardText(selected or "")
                delete_range(a, b)
                update_captured_element(); show_cursor()
            end
        end,
        v = function()
            local m = modifiers()
            if not m.meta then return end
            local clip = love.system.getClipboardText() or ""
            if clip ~= "" then
                insert_text_at_cursor(clip)
            end
        end,
        ['return'] = function()
            if typing.captured_element then
                local return_type = typing.captured_element.type_return or 'exit'
                local m = modifiers()
                if return_type == 'line' or m.shift then
                    insert_text_at_cursor('\n')
                elseif return_type == 'exit' then
                    local element = typing.captured_element
                    local text = typing.text
                    if element.on_text_changed then
                        element.on_text_changed(text)
                    end
                    if element.on_text_input_complete then
                        element.on_text_input_complete(text)
                    end
                    typing.stop_typing()
                    local callback = element.type_return_func or element.on_return
                    if callback then callback(element, text) end
                elseif return_type == 'stay' then
                    if typing.captured_element.on_text_changed then
                        typing.captured_element.on_text_changed(typing.text)
                    end
                    if typing.captured_element.on_text_input_complete then
                        typing.captured_element.on_text_input_complete(typing.text)
                    end
                    local callback = typing.captured_element.type_return_func or typing.captured_element.on_return
                    if callback then callback(typing.captured_element, typing.text) end
                    update_captured_element()
                end
            else
                typing.stop_typing()
            end
        end,
        kpenter = function()
            return actions['return']()
        end,
        enter = function()
            return actions['return']()
        end,
        space = function()
            insert_text_at_cursor(' ')
        end,
        lower = function()
            kb_state.uppercase = not kb_state.uppercase
            typing.update_virtual_keyboard()
        end,
        ctrl = function()
            kb_state.ctrl_toggle = not kb_state.ctrl_toggle
            typing.update_virtual_keyboard()
        end,
        shift = function()
            kb_state.shift_toggle = not kb_state.shift_toggle
            typing.update_virtual_keyboard()
        end
    }
    actions.del = actions.delete
    actions.kpenter = actions['return']
    actions.enter = actions['return']
    local action_key = action:lower()
    local action_func = actions[action_key]
    if action_func then
        action_func()
        return true
    end
    return false
end

typing.key_repeat_timer = timers.new({
    type = 'do_until',
    time = -1,
    loopfunc = function(dt, t)
        if t > 0.5 then
            typing.active_key = false
            typing.key_repeat_timer:reset()
            typing.key_repeat_timer.paused = true
        end
    end,
    paused = true
})

function typing.start_typing(element, initial_text)
    if typing.active then typing.stop_typing() end
    if element and element.doubleClickEditable and element.editable ~= true and not element._typing_restore_editable_active then
        element._typing_restore_editable_active = true
        element._typing_restore_editable_value = element.editable
        element.editable = true
    end
    typing.active = true
    typing.captured_element = element
    typing.text = initial_text or (element and (element.text or "")) or ""
    -- strip any '|' caret from incoming text
    typing.text = typing.text:gsub("|", "")
    typing.cursor_index = #typing.text
    typing.selection_anchor = typing.cursor_index
    typing.preferred_col = nil
    typing.cursor_visible = true
    typing.cursor_blink_timer = 0
    input_mgr.state.typing = true
    input_mgr.state.captured_element = element
    love.keyboard.setKeyRepeat(true)
    local is_mobile = input_mgr.mobile.is_mobile
    local force_virtual = element and element.force_virtual_keyboard
    typing.using_native_text_input = not (is_mobile and force_virtual)
    love.keyboard.setTextInput(typing.using_native_text_input == true)
    if force_virtual then
        typing.show_virtual_keyboard()
    end
    update_captured_element()
    show_cursor()
end

-- compute byte index in element text from click position
function typing.compute_index_from_click(elem, mx, my)
    if not elem or not elem.get_screen_rect or not elem.font then return #typing.text end
    local rect = elem:get_screen_rect()
    local rx, ry, rw, rh = rect.position.x, rect.position.y, rect.size.x, rect.size.y
    local text = (typing.active and (typing.captured_element == elem)) and typing.text or (elem.text or "")
    text = tostring(text):gsub("|", "")
    local lines = {}
    for s in (text .. "\n"):gmatch("(.-)\n") do table.insert(lines, s) end
    if #lines == 0 then lines = { text } end
    local font = elem.font
    local scale = elem.textScale or 1
    local lh = font:getHeight() * (elem.lineHeight or 1.2) * scale
    local total_h = #lines * lh
    local top_y = ry
    if elem.textAlignY == 'center' then
        top_y = ry + (rh - total_h) * 0.5
    elseif elem.textAlignY == 'bottom' then
        top_y = ry + (rh - total_h)
    end
    local ly = math.floor((my - top_y) / lh) + 1
    if ly < 1 then ly = 1 elseif ly > #lines then ly = #lines end
    local line = lines[ly]
    local line_w = font:getWidth(line) * scale
    local left_x = rx
    if elem.textAlignX == 'center' then
        left_x = rx + (rw - line_w) * 0.5
    elseif elem.textAlignX == 'right' then
        left_x = rx + (rw - line_w)
    end
    local relx = mx - left_x
    -- if element is in excerpt (horizontal scroll) mode, account for scroll offset
    if elem.excerpt and elem._excerpt_offset and elem._excerpt_offset > 0 then
        relx = relx + elem._excerpt_offset * scale
    end
    if relx <= 0 then
        local before = 0; for i = 1, ly - 1 do before = before + #lines[i] + 1 end
        return before
    end
    local best_idx = #line
    for p, _ in utf8.codes(line) do
        local substr = line:sub(1, p - 1)
        local w = font:getWidth(substr) * scale
        if w >= relx then
            best_idx = p - 1
            break
        end
    end
    if relx >= line_w then best_idx = #line end
    local before = 0; for i = 1, ly - 1 do before = before + #lines[i] + 1 end
    return before + best_idx
end

function typing.start_typing_at(element, initial_text, cursor_index)
    typing.start_typing(element, initial_text)
    cursor_index = cursor_index or #typing.text
    if cursor_index < 0 then cursor_index = 0 end
    if cursor_index > #typing.text then cursor_index = #typing.text end
    typing.cursor_index = cursor_index
    typing.selection_anchor = typing.cursor_index
    typing.preferred_col = nil
    update_captured_element()
    show_cursor()
end

function typing.stop_typing(keep_text)
    if not typing.active then return end
    local element = typing.captured_element
    typing.active = false
    typing.active_key = false
    if element then
        local prefix = element.text_prefix or ""
        local clean_text = typing.text
        clean_text = clean_text:gsub("|", "")
        if prefix ~= "" then
            clean_text = prefix .. clean_text
        end
        element.text = clean_text
        if element.on_text_changed then
            pcall(function() element.on_text_changed(typing.text) end)
        end
        if element.on_text_input_complete then
            pcall(function() element.on_text_input_complete(typing.text) end)
        end
        element._selection = nil
        if element._typing_restore_editable_active then
            element.editable = element._typing_restore_editable_value
            element._typing_restore_editable_active = nil
            element._typing_restore_editable_value = nil
        end
    end
    input_mgr.state.typing = false
    input_mgr.state.captured_element = nil
    love.keyboard.setKeyRepeat(false)
    love.keyboard.setTextInput(false)
    typing.using_native_text_input = false
    typing.hide_virtual_keyboard()
    if typing.key_repeat_timer then
        typing.key_repeat_timer:reset()
        typing.key_repeat_timer.paused = true
    end
    typing.captured_element = nil
    hide_cursor()
    typing.selection_anchor = nil
    typing.preferred_col = nil
    if not keep_text then
        typing.text = ""
    end
end

function typing.handle_text_input(text)
    if not typing.active then return end
    insert_text_at_cursor(text)
end

function typing.handle_key_press(key)
    if not typing.active then return end
    if execute_type_action(key, key) then
        if key:lower() ~= 'return' and key:lower() ~= 'kpenter' and key:lower() ~= 'enter' then
            typing.active_key = true
            if typing.key_repeat_timer then
                typing.key_repeat_timer:reset()
                typing.key_repeat_timer.paused = false
            end
        end
        return
    end
    typing.active_key = true
    if typing.key_repeat_timer then
        typing.key_repeat_timer:reset()
        typing.key_repeat_timer.paused = false
    end
end

function typing.show_virtual_keyboard()
    if typing.keyboard_visible then return end
    typing.keyboard_visible = true
    if not typing.virtual_keyboard then
        typing.create_virtual_keyboard()
    end
    if typing.virtual_keyboard and typing.virtual_keyboard.container then
        typing.virtual_keyboard.container.visible = true
        kb_state.position.y = 1.5
        tween.new(0.15, kb_state.position, { y = 0.5 }, "linear", {
            unpause = true,
            const_func = function()
                typing.update_virtual_keyboard()
            end,
            complete_func = function()
                kb_state.position.y = 0.5
            end
        })
    end
end

function typing.hide_virtual_keyboard()
    if not typing.keyboard_visible then return end
    typing.keyboard_visible = false
    if typing.virtual_keyboard and typing.virtual_keyboard.container then
        tween.new(0.15, kb_state.position, { y = 1.5 }, "linear", {
            unpause = true,
            const_func = function()
                typing.update_virtual_keyboard()
            end,
            complete_func = function()
                typing.virtual_keyboard.container.visible = false
                G.pipeline:disable('draw', 'virt_kb')
            end
        })
    end
end

function typing.create_virtual_keyboard()
    typing.virtual_keyboard = {
        elements = {},
        visible = false,
        navigation_enabled = true
    }
    local keyboard_container = Element {
        position = { scale = vec2(0.5, kb_state.position.y) },
        size = { scale = vec2(0.9, 0.4) },
        show_fill = true,
        fill_color = { 0.1, 0.1, 0.1, 0.95 },
        show_outline = true,
        outline_color = { 0.5, 0.5, 0.5, 1.0 },
        outline_thickness = 2,
        visible = false
    }
    typing.virtual_keyboard.container = keyboard_container
    if AllElements then
        table.insert(AllElements, keyboard_container)
    end
    G.pipeline:register('draw', 'virt_kb', function()
        if typing.virtual_keyboard and typing.virtual_keyboard.container and typing.virtual_keyboard.container.visible then
            typing.virtual_keyboard.container:draw()
        end
    end, 2)
    G.pipeline:enable('draw', 'virt_kb')
    for row_index, row in ipairs(typing.keyboard_layout) do
        for col_index, key in ipairs(row) do
            local element = nil
            if row_index == 1 then
                element = Text {
                    text = typing.text,
                    font_size = 18,
                    text_align = "center",
                    visible = true,
                    position = { scale = vec2(0.5, 0.2) },
                    size = { scale = vec2(0.6, 0.1) },
                    text_color = { 1, 1, 1, 1 }
                }
            else
                local click_func = function()
                    typing.handle_virtual_key_press(key)
                end
                local key_size = key_dims[key] and
                    { offset = vec2(key_dims[key].width, key_dims[key].height) } or
                    { offset = vec2(40, 40) }
                element = Element {
                    text = key,
                    font_size = 16,
                    text_align = "center",
                    visible = true,
                    mousecheck = true,
                    on_mouse_clicked = click_func,
                    size = key_size,
                    show_fill = true,
                    fill_color = { 0.3, 0.3, 0.3, 0.8 },
                    show_outline = true,
                    outline_color = { 0.6, 0.6, 0.6, 1.0 },
                    text_color = { 1, 1, 1, 1 }
                }
            end
            if element then
                typing.virtual_keyboard.elements[key] = element
                keyboard_container:add(element)
            end
        end
    end
    typing.update_virtual_keyboard()
end

function typing.update_virtual_keyboard()
    if not typing.virtual_keyboard then return end
    typing.position_virtual_keyboard()
    if typing.virtual_keyboard.container then
        typing.virtual_keyboard.container:mark_dirty()
    end
    local lower_key = typing.virtual_keyboard.elements['lower']
    if lower_key then
        local label = kb_state.uppercase and 'lower' or 'UPPER'
        if lower_key.setText then
            lower_key:setText(label)
        else
            lower_key.text = label
            if lower_key.mark_dirty then lower_key:mark_dirty() end
        end
    end
    local ctrl_key = typing.virtual_keyboard.elements['CTRL']
    if ctrl_key then
        ctrl_key.text_color = kb_state.ctrl_toggle and { 0, 0, 1, 1 } or { 1, 1, 1, 1 }
    end
    local shift_key = typing.virtual_keyboard.elements['SHIFT']
    if shift_key then
        shift_key.text_color = kb_state.shift_toggle and { 0, 0, 1, 1 } or { 1, 1, 1, 1 }
    end
    for row_index = 2, #typing.keyboard_layout - 2 do
        for _, key in ipairs(typing.keyboard_layout[row_index]) do
            local element = typing.virtual_keyboard.elements[key]
            if element and key:match("%a") then
                local new_text = kb_state.uppercase and key:upper() or key:lower()
                if element.setText then
                    element:setText(new_text)
                else
                    element.text = new_text
                    if element.mark_dirty then element:mark_dirty() end
                end
            end
        end
    end
end

function typing.position_virtual_keyboard()
    if not typing.virtual_keyboard then return end
    if typing.virtual_keyboard.container then
        typing.virtual_keyboard.container.position.scale.y = kb_state.position.y
    end
    local total_width = 0.8
    local row_height = 0.06
    local base_x = 0.5
    local base_y = kb_state.position.y
    for row_index, row in ipairs(typing.keyboard_layout) do
        local num_keys = #row
        local cell_width = total_width / num_keys
        local y = base_y + (row_index - 1) * row_height - 0.3
        for col_index, key in ipairs(row) do
            local x = base_x - (total_width / 2) + (col_index - 0.5) * cell_width
            local element = typing.virtual_keyboard.elements[key]
            if element then
                element.position = { scale = vec2(x, y) }
            end
        end
    end
end

function typing.handle_virtual_key_press(key)
    if not execute_type_action(key, key) then
        local char = kb_state.uppercase and key:upper() or key:lower()
        insert_text_at_cursor(char)
    end
end

function typing.update(dt)
    update_cursor_blink(dt)
end

function typing.show_virtual_keyboard_for_element(element)
    if element and element.editable then
        local previous_force = element.force_virtual_keyboard
        element.force_virtual_keyboard = true
        typing.start_typing(element, element.text or "")
        element.force_virtual_keyboard = previous_force
        typing.show_virtual_keyboard()
    end
end

function typing.hide_virtual_keyboard_for_element()
    typing.hide_virtual_keyboard()
    typing.stop_typing()
end

function typing.set_virtual_keyboard_focus(row, col)
    if not typing.virtual_keyboard then return end
    typing.virtual_keyboard.current_row = row
    typing.virtual_keyboard.current_col = col
    for key_name, element in pairs(typing.virtual_keyboard.elements) do
        if element.fill_color then
            element.fill_color = { 0.3, 0.3, 0.3, 0.8 }
        end
    end
    local focused_key = typing.keyboard_layout[row] and typing.keyboard_layout[row][col]
    if focused_key and typing.virtual_keyboard.elements[focused_key] then
        local element = typing.virtual_keyboard.elements[focused_key]
        if element.fill_color then
            element.fill_color = { 0.6, 0.6, 0.6, 0.9 }
        end
    end
end

function typing.make_element_editable(element, options)
    options = options or {}
    element.editable = true
    element.mousecheck = true
    element.text_prefix = options.prefix
    element.type_return = options.return_type or 'exit'
    element.type_return_func = options.on_return
    element.force_virtual_keyboard = options.force_virtual_keyboard
    local original_on_click = element.on_mouse_clicked
    element.on_mouse_clicked = function(self, button, x, y)
        if original_on_click then
            original_on_click(self, button, x, y)
        end
        if button == 1 and self.editable then
            -- a prefix (for example an input's leading search icon gutter)
            -- is rendered inside the element but is not part of its editable
            -- value. measure against the visible text, then store a raw
            -- caret index. Re-clicking the already focused field must also
            -- avoid stop/start: stopping commits the field and may rebuild
            -- its UI before the intended caret is installed
            local prefix = tostring(self.text_prefix or "")
            local active_here = typing.active and typing.captured_element == self
            local raw_text = active_here and tostring(typing.text or "") or tostring(self.text or "")
            raw_text = raw_text:gsub("|", "")
            if prefix ~= "" and raw_text:sub(1, #prefix) == prefix then
                raw_text = raw_text:sub(#prefix + 1)
            end
            local saved_text = typing.text
            if active_here and prefix ~= "" then typing.text = prefix .. raw_text end
            local visual_index = typing.compute_index_from_click(self, x, y)
            if active_here then typing.text = saved_text end
            local new_index = math.max(0, math.min(#raw_text, visual_index - #prefix))
            if active_here then
                typing.text = raw_text
                typing.cursor_index = new_index
                typing.selection_anchor = new_index
                typing.preferred_col = nil
                typing.cursor_visible = true
                typing.cursor_blink_timer = 0
                update_captured_element()
                show_cursor()
            else
                typing.start_typing_at(self, raw_text, new_index)
            end
        end
    end
    return element
end

return typing
