-- Pause/settings menu panel drawn with love.graphics
--
-- Rows are actions or values (toggle, choice, range). Keyboard and gamepad
-- navigation come from engine/services/menu_navig.lua (up/down to move,
-- left/right to change a value, accept/cancel), the mouse selects on hover
-- and changes values by clicking the left or right half of a value
--
-- the panel never outgrows the window: the title and footer stay fixed and
-- the rows scroll inside a clipped region, with a scrollbar when they do not
-- fit. the wheel scrolls it, and moving the selection with the keyboard or a
-- controller keeps the selected row in view
--
--     local Menu = require("engine/ui/menu")
--     local menu = Menu.new({ title = "Paused", on_cancel = close })
--     menu:set_items({
--         { label = "Resume", on_select = close },
--         { label = "Invert Y", kind = "toggle", get = get_invert, set = set_invert },
--         { label = "Volume", kind = "range", min = 0, max = 10, step = 1, get = get_vol, set = set_vol },
--     })
--     menu:open()
--     -- from a draw stage: menu:draw(width, height, scale)

local MenuNavig = require("engine/services/menu_navig")
local FontManager = require("engine/graphics/font_manager")

local Menu = {}
Menu.__index = Menu

Menu.THEME = {
    font = "Poppins-Regular",
    title_font = "Poppins-Black",
    text = { 0.95, 0.96, 0.98, 1 },
    muted = { 0.62, 0.66, 0.74, 1 },
    panel = { 0.085, 0.095, 0.125, 0.96 },
    outline = { 1, 1, 1, 0.07 },
    row = { 1, 1, 1, 0.035 },
    accent = { 0.98, 0.80, 0.30, 1 },
    accent_text = { 0.12, 0.10, 0.07, 1 },
    dim = { 0.02, 0.025, 0.04, 0.6 },
    scrollbar = { 1, 1, 1, 0.08 },
    thumb = { 1, 1, 1, 0.32 },
}

local fonts = {}
local function font(name, size)
    size = math.max(6, math.floor(size + 0.5))
    local path = name and FontManager.resolve_path(name)
    local key = tostring(path or name) .. ":" .. size
    local cached = fonts[key]
    if cached then return cached end
    local ok, created = false, nil
    if path and path == FontManager.default_path then
        created = FontManager.get(path, size)
        ok = true
    elseif path then
        ok, created = pcall(love.graphics.newFont, path, size)
    end
    if not ok or not created then created = love.graphics.newFont(size) end
    created:setFilter("linear", "linear")
    fonts[key] = created
    return created
end
Menu.font = font

local function clamp(value, lower, upper)
    if value < lower then return lower end
    if value > upper then return upper end
    return value
end

local function set_color(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], (color[4] or 1) * (alpha or 1))
end

local function reduced_motion()
    local setting = CFG and CFG:getSetting("reduced_motion")
    return setting and setting.value == true
end

-- `text` shortened with an ellipsis to fit `width` pixels in `f`
local function fit(f, text, width)
    text = tostring(text)
    if width <= 0 then return "" end
    if f:getWidth(text) <= width then return text end
    local ellipsis = f:hasGlyphs("…") and "…" or "..."
    local low, high = 0, #text
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if f:getWidth(text:sub(1, mid) .. ellipsis) <= width then low = mid else high = mid - 1 end
    end
    -- never cut a UTF-8 sequence in half
    while low > 0 and text:byte(low + 1) and text:byte(low + 1) >= 0x80 and text:byte(low + 1) < 0xC0 do low = low - 1 end
    return text:sub(1, low) .. ellipsis
end

local function format_value(item)
    local value = item.get and item.get()
    if item.format then return item.format(value) end
    if item.kind == "toggle" then return value and "On" or "Off" end
    if item.kind == "choice" then
        for index, choice in ipairs(item.choices or {}) do
            if choice == value then return item.labels and item.labels[index] or tostring(choice) end
        end
        return tostring(value)
    end
    if item.kind == "range" then
        local step = item.step or 1
        if step >= 1 then return ("%d"):format(math.floor(value + 0.5)) end
        return ("%.2f"):format(value)
    end
    return nil
end

-- Change a value item by one step in `direction` (-1 or 1)
local function adjust(item, direction)
    if not item.set then return false end
    local value = item.get and item.get()
    if item.kind == "toggle" then
        item.set(not value)
    elseif item.kind == "choice" then
        local choices = item.choices or {}
        local index = 1
        for position, choice in ipairs(choices) do
            if choice == value then index = position end
        end
        index = ((index - 1 + direction) % #choices) + 1
        item.set(choices[index])
    elseif item.kind == "range" then
        local step = item.step or 1
        local next_value = clamp((tonumber(value) or item.min or 0) + step * direction, item.min or -math.huge, item.max or math.huge)
        next_value = math.floor(next_value / step + 0.5) * step
        if next_value == value then return false end
        item.set(next_value)
    else
        return false
    end
    return true
end

function Menu.new(options)
    options = options or {}
    local self = setmetatable({
        title = options.title or "",
        subtitle = options.subtitle,
        footer = options.footer,
        width = options.width or 460,
        theme = setmetatable(options.theme or {}, { __index = Menu.THEME }),
        on_change = options.on_change,
        on_activate = options.on_activate,
        on_cancel = options.on_cancel,
        items = {},
        rows = {},
        open_t = 0,
        visible = false,
        last_mouse = nil,
        -- Scroll offsets are in unscaled units, so a resize keeps the place
        scroll = 0,
        scroll_target = 0,
    }, Menu)
    self.navig = MenuNavig.new({
        id = options.id,
        axis = "y",
        wrap = true,
        active = false,
        items = {},
        on_change = function(_, index)
            if self.visible then
                -- Keyboard and controller moves bring the row into view;
                -- hovering a half-visible row does not scroll under the mouse
                if not self.hovering then self.reveal = index end
                if self.on_change then self.on_change(self.items[index]) end
            end
        end,
        on_cancel = function()
            if self.on_cancel then self.on_cancel() end
        end,
    })
    self.press_listener = function(button, x, y) return self:_mouse_pressed(button, x, y) end
    input_mgr.mouse.add_press_listener(self.press_listener)
    self.wheel_listener = function(_, dy) return self:_wheel(dy) end
    input_mgr.mouse.add_wheel_listener(self.wheel_listener)
    return self
end

function Menu:set_items(items, keep_index)
    self.items = items
    local navig_items = {}
    for index, item in ipairs(items) do
        local menu = self
        navig_items[index] = {
            label = item.label,
            on_select = function() menu:_activate(item, 1) end,
            on_adjust = item.kind and item.kind ~= "action" and function(_, direction)
                if adjust(item, direction) and menu.on_activate then menu.on_activate(item) end
            end or nil,
        }
    end
    if not keep_index then self.scroll, self.scroll_target = 0, 0 end
    self.navig:set_items(navig_items, keep_index)
end

function Menu:set_title(title, subtitle)
    self.title, self.subtitle = title, subtitle
end

function Menu:_activate(item, direction)
    if not item then return end
    if item.kind and item.kind ~= "action" then
        if adjust(item, direction or 1) and self.on_activate then self.on_activate(item) end
    elseif item.on_select then
        if self.on_activate then self.on_activate(item) end
        item.on_select(item)
    end
end

function Menu:open(index)
    self.visible = true
    self.open_t = reduced_motion() and 1 or 0
    self.last_mouse = nil
    self.scroll, self.scroll_target = 0, 0
    self.reveal = index or 1
    self.navig:open(index or 1)
end

function Menu:close()
    self.visible = false
    self.navig:close()
end

function Menu:is_open()
    return self.visible
end

function Menu:selected_index()
    return self.navig.index
end

function Menu:_select(index)
    if index ~= self.navig.index then
        local old = self.navig.index
        self.navig.index = index
        self.navig:_sync_selection(old)
    end
end

-- Panel geometry for a `width` x `height` window. the panel keeps a margin
-- from every edge, when the rows do not fit, they scroll inside `view`
function Menu:_layout(width, height, scale)
    local margin = math.max(12 * scale, math.min(width, height) * 0.04)
    local panel_w = math.min(self.width * scale, width - margin * 2)
    local row_h, gap = 46 * scale, 6 * scale
    local header = (self.subtitle and 92 or 76) * scale
    local footer = self.footer and 40 * scale or 18 * scale
    local content = math.max(0, #self.items * (row_h + gap) - gap)
    local max_h = math.max(header + footer + row_h, height - margin * 2)
    local panel_h = math.min(header + content + footer, max_h)
    local view_h = math.max(row_h, panel_h - header - footer)
    local x = math.floor((width - panel_w) * 0.5)
    local y = math.floor(math.max(margin, (height - panel_h) * 0.5))
    local max_scroll = math.max(0, content - view_h) / scale
    self.max_scroll = max_scroll
    self.scroll = clamp(self.scroll, 0, max_scroll)
    self.scroll_target = clamp(self.scroll_target, 0, max_scroll)
    local scrolling = max_scroll > 0
    local bar = scrolling and 6 * scale or 0
    local view = { x = x + 20 * scale, y = y + header, w = panel_w - 40 * scale, h = view_h }
    local rows = self.rows
    for index = 1, #self.items do
        local row = rows[index] or {}
        rows[index] = row
        row.x = view.x
        row.y = view.y + (index - 1) * (row_h + gap) - self.scroll * scale
        row.w = view.w - (scrolling and bar + 6 * scale or 0)
        row.h = row_h
        row.visible = row.y + row.h > view.y and row.y < view.y + view.h
    end
    for index = #self.items + 1, #rows do rows[index] = nil end
    self.panel = { x = x, y = y, w = panel_w, h = panel_h, header = header, footer = footer, scale = scale,
        view = view, row_h = row_h, gap = gap, content = content, bar = bar }
    return self.panel
end

-- Bring row `index` fully into view
function Menu:_reveal(index)
    local panel = self.panel
    if not panel or not index then return end
    local scale = panel.scale
    local top = (index - 1) * (panel.row_h + panel.gap) / scale
    local bottom = top + panel.row_h / scale
    local view_h = panel.view.h / scale
    if top < self.scroll_target then self.scroll_target = top
    elseif bottom > self.scroll_target + view_h then self.scroll_target = bottom - view_h end
    self.scroll_target = clamp(self.scroll_target, 0, self.max_scroll or 0)
end

function Menu:_wheel(dy)
    if not self.visible then return false end
    if self.max_scroll and self.max_scroll > 0 then
        self.scroll_target = clamp(self.scroll_target - (dy or 0) * 52, 0, self.max_scroll)
    end
    -- an open menu owns the wheel either way, so nothing behind it zooms
    return true
end

function Menu:_row_at(x, y)
    local view = self.panel and self.panel.view
    if not view or x < view.x or x > view.x + view.w or y < view.y or y > view.y + view.h then return end
    for index, row in ipairs(self.rows) do
        if x >= row.x and x <= row.x + row.w and y >= row.y and y <= row.y + row.h then
            return index, row
        end
    end
end

function Menu:_mouse_pressed(button, x, y)
    if not self.visible or button ~= 1 then return end
    local panel = self.panel
    if panel and panel.bar > 0 and x >= panel.view.x + panel.view.w - panel.bar and x <= panel.view.x + panel.view.w
        and y >= panel.view.y and y <= panel.view.y + panel.view.h then
        -- a click on the scrollbar track jumps there
        local fraction = (y - panel.view.y) / panel.view.h
        self.scroll_target = clamp(fraction * (self.max_scroll or 0), 0, self.max_scroll or 0)
        return
    end
    local index, row = self:_row_at(x, y)
    if not index then return end
    self:_select(index)
    local item = self.items[index]
    local direction = 1
    if item.kind == "range" or item.kind == "choice" then
        -- the value sits on the right half, its left side steps down
        local value_center = row.x + row.w * 0.75
        direction = x < value_center and -1 or 1
    end
    self:_activate(item, direction)
end

function Menu:update(dt)
    if not self.visible then return end
    self.open_t = math.min(1, self.open_t + dt / 0.16)
    local position = input_mgr.mouse.position
    if position and not input_mgr.mouse.look_active then
        local moved = not self.last_mouse
            or self.last_mouse.x ~= position.x or self.last_mouse.y ~= position.y
        if moved then
            if self.last_mouse then
                local index = self:_row_at(position.x, position.y)
                if index then
                    self.hovering = true
                    self:_select(index)
                    self.hovering = false
                end
            end
            self.last_mouse = { x = position.x, y = position.y }
        end
    end
    if self.reveal then self:_reveal(self.reveal); self.reveal = nil end
    if reduced_motion() then
        self.scroll = self.scroll_target
    else
        self.scroll = self.scroll + (self.scroll_target - self.scroll) * math.min(1, dt * 18)
        if math.abs(self.scroll_target - self.scroll) < 0.25 then self.scroll = self.scroll_target end
    end
end

---draw the dimmed backdrop and panel. `scale` is the UI scale factor
function Menu:draw(width, height, scale)
    if not self.visible then return end
    scale = scale or 1
    local theme = self.theme
    local t = self.open_t
    local ease = 1 - (1 - t) ^ 3
    local panel = self:_layout(width, height, scale)
    -- a selection made before the first layout is revealed now
    if self.reveal then self:_reveal(self.reveal); self.reveal = nil; self.scroll = self.scroll_target; panel = self:_layout(width, height, scale) end
    local lift = (1 - ease) * 18 * scale
    love.graphics.push("all")
    love.graphics.origin()
    set_color(theme.dim, ease)
    love.graphics.rectangle("fill", 0, 0, width, height)
    love.graphics.translate(0, lift)

    local radius = 14 * scale
    set_color({ 0, 0, 0, 0.28 }, ease)
    love.graphics.rectangle("fill", panel.x, panel.y + 6 * scale, panel.w, panel.h, radius, radius)
    set_color(theme.panel, ease)
    love.graphics.rectangle("fill", panel.x, panel.y, panel.w, panel.h, radius, radius)
    set_color(theme.outline, ease)
    love.graphics.setLineWidth(math.max(1, scale))
    love.graphics.rectangle("line", panel.x + 0.5, panel.y + 0.5, panel.w - 1, panel.h - 1, radius, radius)

    local inner_w = panel.w - 48 * scale
    local title_font = font(theme.title_font, 30 * scale)
    love.graphics.setFont(title_font)
    set_color(theme.text, ease)
    love.graphics.print(fit(title_font, self.title, inner_w), math.floor(panel.x + 24 * scale), math.floor(panel.y + 18 * scale))
    if self.subtitle then
        local small = font(theme.font, 15 * scale)
        love.graphics.setFont(small)
        set_color(theme.muted, ease)
        love.graphics.print(fit(small, self.subtitle, inner_w), math.floor(panel.x + 24 * scale), math.floor(panel.y + 58 * scale))
    end

    -- Rows, clipped to the scrolling region. the scissor ignores transforms,
    -- so the opening lift is added by hand
    local view = panel.view
    love.graphics.intersectScissor(view.x, view.y + lift, view.w, view.h)
    local label_font = font(theme.font, 18 * scale)
    local selected = self.navig.index
    for index, item in ipairs(self.items) do
        local row = self.rows[index]
        if row.visible then
            local is_selected = index == selected
            set_color(is_selected and theme.accent or theme.row, ease)
            love.graphics.rectangle("fill", row.x, row.y, row.w, row.h, 9 * scale, 9 * scale)
            local text_color = is_selected and theme.accent_text or theme.text
            love.graphics.setFont(label_font)
            local text_y = math.floor(row.y + (row.h - label_font:getHeight()) * 0.5)
            local value = format_value(item)
            local shown, value_w = nil, 0
            if value then
                local arrows = item.kind ~= "toggle"
                local left, right = "‹", "›"
                if arrows and not label_font:hasGlyphs("‹›") then left, right = "<", ">" end
                shown = fit(label_font, arrows and (left .. "  " .. value .. "  " .. right) or value, row.w * 0.5)
                value_w = label_font:getWidth(shown)
            end
            set_color(text_color, ease)
            local label_space = row.w - 32 * scale - (value and value_w + 16 * scale or 0)
            love.graphics.print(fit(label_font, item.label, label_space), math.floor(row.x + 16 * scale), text_y)
            if shown then
                set_color(is_selected and theme.accent_text or theme.muted, ease)
                love.graphics.print(shown, math.floor(row.x + row.w - 16 * scale - value_w), text_y)
            end
        end
    end
    love.graphics.setScissor()

    if panel.bar > 0 then
        local track_x = view.x + view.w - panel.bar
        set_color(theme.scrollbar, ease)
        love.graphics.rectangle("fill", track_x, view.y, panel.bar, view.h, panel.bar / 2, panel.bar / 2)
        local visible = view.h / math.max(view.h, panel.content)
        local thumb_h = math.max(24 * scale, view.h * visible)
        local fraction = (self.max_scroll > 0) and (self.scroll / self.max_scroll) or 0
        set_color(theme.thumb, ease)
        love.graphics.rectangle("fill", track_x, view.y + (view.h - thumb_h) * fraction, panel.bar, thumb_h, panel.bar / 2, panel.bar / 2)
    end

    if self.footer then
        local small = font(theme.font, 14 * scale)
        love.graphics.setFont(small)
        set_color(theme.muted, ease * 0.9)
        love.graphics.printf(fit(small, self.footer, inner_w), panel.x, math.floor(panel.y + panel.h - 30 * scale), panel.w, "center")
    end
    love.graphics.pop()
end

function Menu:destroy()
    self:close()
    input_mgr.mouse.remove_press_listener(self.press_listener)
    input_mgr.mouse.remove_wheel_listener(self.wheel_listener)
    self.navig:destroy()
end

return Menu
