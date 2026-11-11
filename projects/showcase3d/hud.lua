-- on-screen text for the showcase: a controls card with key and button
-- prompts for the active device, and short toast messages
local Menu = require("engine/ui/menu")

local Hud = {}
Hud.__index = Hud

function Hud.new()
    return setmetatable({ toasts = {}, controls_alpha = 1, rows = { keyboard = {}, gamepad = {} } }, Hud)
end

---set the controls card. `rows.keyboard` and `rows.gamepad` are lists of
---rows, each row holds one or more { prompt icon names, label } pairs
---Prompt names come from the engine sprite sheet, "key:Label" draws a keycap
function Hud:set_rows(rows)
    self.rows = rows or { keyboard = {}, gamepad = {} }
end

function Hud:notify(text)
    for index = #self.toasts, 1, -1 do
        if self.toasts[index].text == text then table.remove(self.toasts, index) end
    end
    self.toasts[#self.toasts + 1] = { text = text, age = 0, life = 2.4 }
    while #self.toasts > 3 do table.remove(self.toasts, 1) end
end

function Hud:update(dt, show_controls)
    for index = #self.toasts, 1, -1 do
        local toast = self.toasts[index]
        toast.age = toast.age + dt
        if toast.age >= toast.life then table.remove(self.toasts, index) end
    end
    local goal = show_controls and 1 or 0
    self.controls_alpha = self.controls_alpha + (goal - self.controls_alpha) * math.min(1, dt * 10)
end

-- Wide keys read better as text keycaps than as square prompt sprites
function Hud:_keycap(label, x, y, size, alpha)
    local font = Menu.font("Poppins-Regular", size * 0.5)
    local width = math.floor(font:getWidth(label) + size * 0.6)
    love.graphics.setColor(0.95, 0.96, 0.98, alpha)
    love.graphics.rectangle("fill", x + 1, y + 2, width - 2, size - 4, size * 0.18, size * 0.18)
    love.graphics.setColor(0.08, 0.09, 0.11, alpha)
    love.graphics.setFont(font)
    love.graphics.print(label, math.floor(x + (width - font:getWidth(label)) * 0.5),
        math.floor(y + (size - font:getHeight()) * 0.5))
    return width
end

function Hud:_icon(name, x, y, size, alpha)
    local label = name:match("^key:(.+)$")
    if label then return self:_keycap(label, x, y, size, alpha) end
    local sheet, quad, w, h = input_mgr.controller.prompt_sprite(name)
    if not sheet then return 0 end
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.draw(sheet, quad, x, y, 0, size / w, size / h)
    return size
end

local function device()
    return input_mgr.state.primary_input_device == "controller" and "gamepad" or "keyboard"
end

function Hud:draw(width, height, scale)
    love.graphics.push("all")
    love.graphics.origin()
    local alpha = self.controls_alpha
    if alpha > 0.01 and #(self.rows.keyboard or {}) > 0 then
        local rows = device() == "gamepad" and self.rows.gamepad or self.rows.keyboard
        local font = Menu.font("Poppins-Regular", 13 * scale)
        local icon = 22 * scale
        local row_h = 27 * scale
        local pad = 12 * scale
        local gap = 14 * scale
        local card_w = 0
        for _, row in ipairs(rows) do
            local w = 0
            for index, pair in ipairs(row) do
                for _, name in ipairs(pair[1]) do
                    local label = name:match("^key:(.+)$")
                    w = w + (label and math.floor(Menu.font("Poppins-Regular", icon * 0.5):getWidth(label) + icon * 0.6) or icon)
                end
                w = w + 6 * scale + font:getWidth(pair[2]) + (index > 1 and gap or 0)
            end
            card_w = math.max(card_w, w)
        end
        card_w = card_w + pad * 2
        local card_h = pad * 2 + #rows * row_h
        local x, y = 16 * scale, height - card_h - 16 * scale
        love.graphics.setColor(0.05, 0.06, 0.08, 0.55 * alpha)
        love.graphics.rectangle("fill", x, y, card_w, card_h, 10 * scale, 10 * scale)
        love.graphics.setFont(font)
        local row_y = y + pad
        for _, row in ipairs(rows) do
            local cursor = x + pad
            for index, pair in ipairs(row) do
                if index > 1 then cursor = cursor + gap end
                for _, name in ipairs(pair[1]) do
                    cursor = cursor + self:_icon(name, cursor, row_y + (row_h - icon) * 0.5, icon, alpha)
                end
                cursor = cursor + 6 * scale
                love.graphics.setFont(font)
                love.graphics.setColor(0.94, 0.95, 0.97, alpha)
                love.graphics.print(pair[2], math.floor(cursor), math.floor(row_y + (row_h - font:getHeight()) * 0.5))
                cursor = cursor + font:getWidth(pair[2])
            end
            row_y = row_y + row_h
        end
    end

    local font = Menu.font("Poppins-Regular", 17 * scale)
    love.graphics.setFont(font)
    local y = 22 * scale
    for _, toast in ipairs(self.toasts) do
        local t = toast.age
        local a = math.min(1, t / 0.15) * math.min(1, (toast.life - t) / 0.4)
        local w = font:getWidth(toast.text) + 36 * scale
        local h = font:getHeight() + 16 * scale
        local x = (width - w) * 0.5
        love.graphics.setColor(0.06, 0.07, 0.09, 0.7 * a)
        love.graphics.rectangle("fill", x, y, w, h, h * 0.5, h * 0.5)
        love.graphics.setColor(0.98, 0.98, 1, a)
        love.graphics.print(toast.text, math.floor(x + 18 * scale), math.floor(y + 8 * scale))
        y = y + h + 8 * scale
    end
    love.graphics.pop()
end

return Hud
