-- The pause screen: the place's own StarterGui/UI/pause, driven the way the
-- Good edition's CharacterScript drives it (pause(), its textbuttons table,
-- the spinning selection marker that glides to the selected button, and
-- directional moves between buttons; see NOTICE.md). Two changes for this
-- project, in the same style: a Settings panel built from the place's own
-- rows, and Quit, which leaves the game (the sandbox has no title screen).
local Settings = require("projects/showcase3d/settings")

local PauseMenu = {}
PauseMenu.__index = PauseMenu

-- CharacterScript `icrt`: the guide's page titles, one per table of the
-- ModuleScript stinky/share/icr (copied below for when its Source is not
-- loaded).
local GUIDE_TITLES = { "Testmap", "Sample Obby" }
local GUIDE_FALLBACK = {
    { c1 = "Icecream 1", c2 = "Icecream Jobb", c3 = "Testmap Eggs" },
    { c4 = "Low Grav Eggs" },
}
local SPIN = "rbxassetid://1442126706"
local SPIN_GRID = "rbxassetid://1447395325"
local NO_HAT = "rbxassetid://2554418665"
-- Roblox draws ScreenGuis under its 36 px top bar; the pause root is
-- authored for that (it starts 10% above the screen), so it keeps the inset.
local INSET = 36
local SETTINGS_ROWS = 6
local FIRST = { pause = "close", icecream = "PLeft1", clothing = "PLeft4", hub = "no", quit = "no", settings = "row1" }
local PANELS = { "pause", "icecream", "clothing", "hub", "quit", "settings" }

local function child(node, name) return node and node:FindFirstChild(name) end
local function udim2(sx, ox, sy, oy) return { X = { Scale = sx, Offset = ox or 0 }, Y = { Scale = sy, Offset = oy or 0 } } end
local function udim(value, axis)
    local item = value and (value[axis] or value[axis:lower()])
    if type(item) ~= "table" then return 0, 0 end
    return item.Scale or item.scale or 0, item.Offset or item.offset or 0
end
local function is_button(node) return node.ClassName == "TextButton" or node.ClassName == "ImageButton" end

-- CharacterScript out(): a label and its drop-shadow copy.
local function out(node, text)
    if not node then return end
    text = tostring(text)
    if node.Text ~= text then node.Text = text end
    local outline = child(node, "outline")
    if outline and outline.Text ~= text then outline.Text = text end
end

-- The guide tables from share/icr when its Source is available; the module
-- only assigns two tables, so it runs with no globals.
local function guide_tables(world)
    local share = child(world.Workspace, "share")
    local module = child(share, "icr")
    local source = module and module.Source
    if type(source) == "string" and source ~= "" then
        local chunk = loadstring(source, "=icr")
        if chunk then
            setfenv(chunk, {})
            local ok, result = pcall(chunk)
            if ok and type(result) == "table" and #result > 0 then return result end
        end
    end
    return GUIDE_FALLBACK
end

-- callbacks: resume(), quit(), hub(), snapshot(active), set_quality(value)
function PauseMenu.new(app, program, callbacks)
    local hud = app.hud
    local root = assert(hud:node("pause"), "StarterGui/UI/pause is missing")
    local bg = assert(child(root, "bg"), "pause/bg is missing")
    local self = setmetatable({ app = app, program = program, callbacks = callbacks, hud = hud, root = root, bg = bg,
        panels = {}, spin = child(child(root, "s"), "spin"), clock = 0, page = 1, guide_page = 1, clothing_page = 1,
        settings_page = 1, open_flag = false }, PauseMenu)
    for _, name in ipairs(PANELS) do self.panels[name] = child(bg, name) end
    -- Under the top bar: Roblox's area starts 36 px down and is 36 px shorter.
    local ps, po = udim(root.Position, "Y")
    local ss, so = udim(root.Size, "Y")
    local pxs, pxo = udim(root.Position, "X")
    local sxs, sxo = udim(root.Size, "X")
    root.Position = udim2(pxs, pxo, ps, po + INSET * (1 - ps))
    root.Size = udim2(sxs, sxo, ss, so - INSET * ss)
    self.guide = guide_tables(app.world)
    self:_build_rows()
    self:_build_settings()
    root.Visible = false
    return self
end

-- The main panel gains a Settings row; Quit leaves the game. The rows keep
-- their authored size and are spread over the same span.
function PauseMenu:_build_rows()
    local panel = self.panels.pause
    local template = child(panel, "camera")
    local settings = template:Clone()
    settings.Name = "settings"
    settings.Parent = panel
    out(settings, "Settings")
    local icon = child(settings, "icon")
    if icon then icon.Visible = false end
    local order = { "close", "icecream", "snap", "clothing", "camera", "settings", "hub", "quit" }
    local first, last = 0.24, 0.84
    local step = (last - first) / (#order - 1)
    for index, name in ipairs(order) do
        local row = child(panel, name)
        local xs, xo = udim(row.Position, "X")
        local ws = udim(row.Size, "X")
        local hs = udim(row.Size, "Y")
        row.Position = udim2(xs, xo, first + step * (index - 1), 0)
        row.Size = udim2(ws, 0, math.min(hs, step * 0.95), 0)
    end
    out(child(panel, "quit"), "Quit Game")
    out(child(self.panels.quit, "quit2"), "Quit Game")
end

-- The Settings panel: the main panel's frame and title with one row per
-- setting, the guide's page arrows and its close button.
function PauseMenu:_build_settings()
    local source = self.panels.pause
    local panel = source:Clone()
    panel.Name = "settings"
    for _, node in ipairs(panel:GetChildren()) do
        if is_button(node) then node:Destroy() end
    end
    panel.Parent = self.bg
    self.panels.settings = panel
    -- Title and page line laid out as the guide's.
    local title = child(panel, "title")
    local guide_title = child(self.panels.icecream, "title")
    title.Position, title.Size = guide_title.Position, guide_title.Size
    out(title, "Settings")
    local page = child(self.panels.icecream, "page"):Clone()
    page.Parent = panel
    self.settings_label = page
    local template = child(source, "close")
    self.settings_rows = {}
    for index = 1, SETTINGS_ROWS do
        local row = template:Clone()
        row.Name = "row" .. index
        local icon = child(row, "icon")
        if icon then icon.Visible = false end
        row.Position = udim2(0, 0, 0.21 + (index - 1) * 0.1, 0)
        row.Size = udim2(1, 0, 0.085, 0)
        row.Parent = panel
        self.settings_rows[index] = row
    end
    for _, name in ipairs({ "PLeft1", "PRight1", "no" }) do
        local button = child(self.panels.icecream, name):Clone()
        button.Name = name == "PLeft1" and "PLeftS" or name == "PRight1" and "PRightS" or "no"
        button.Parent = panel
    end
    panel.Visible = false
end

function PauseMenu:is_open() return self.open_flag end

function PauseMenu:open(panel_name, page)
    self.open_flag = true
    self.root.Visible = true
    self.bg.Visible = true
    if page then self.settings_page = page end
    self:panel(panel_name or "pause")
    local icon = child(child(self.panels.pause, "camera"), "icon")
    if icon then icon.ImageRectOffset = { X = self.program:getCustomSetting("s3d_still_camera") and 128 or 0, Y = 128 } end
end

function PauseMenu:close()
    self.open_flag = false
    self.root.Visible = false
    self.selected = nil
end

-- Show one panel and select its first button, as each textbuttons entry does.
function PauseMenu:panel(name)
    for _, other in ipairs(PANELS) do
        local node = self.panels[other]
        if node then node.Visible = other == name end
    end
    self.panel_name = name
    if name == "icecream" then self:_guide()
    elseif name == "clothing" then self:_clothing()
    elseif name == "settings" then self:_settings() end
    self.selected = child(self.panels[name], FIRST[name])
end

---------------------------------------------------------------- panels

function PauseMenu:_guide()
    local panel = self.panels.icecream
    local it = math.max(1, math.min(#self.guide, self.guide_page))
    self.guide_page = it
    out(child(panel, "title"), GUIDE_TITLES[it] or ("Page " .. it))
    out(child(panel, "page"), "Page " .. it .. "/" .. #self.guide)
    for x = 1, 7 do
        local row = child(panel, "bt" .. x)
        out(row, "")
        local icon = child(row, "icon")
        if icon then icon.Visible = false end
    end
    local names = {}
    for name in pairs(self.guide[it] or {}) do names[#names + 1] = name end
    table.sort(names, function(a, b) return (tonumber(a:sub(2)) or 0) < (tonumber(b:sub(2)) or 0) end)
    for x, name in ipairs(names) do
        local row = child(panel, "bt" .. x)
        if not row then break end
        local found = self.app.session:has_collectible(tonumber(name:sub(2)))
        out(row, self.guide[it][name])
        local icon = child(row, "icon")
        if icon then
            icon.Visible = true
            icon.ImageRectOffset = { X = found and 0 or 128, Y = 0 }
            icon.ImageColor3 = found and self.app.rbx.Color3.new(.4, 1, .4) or self.app.rbx.Color3.new(1, .4, .4)
        end
    end
end

-- CharacterScript hatpage(): owned hats, then skins, then antennas, sixteen
-- to a page, and the three worn slots.
function PauseMenu:_clothing()
    local panel = self.panels.clothing
    local wardrobe = self.app.wardrobe
    local list = wardrobe and wardrobe:owned_list() or {}
    out(child(panel, "page"), "Page " .. self.clothing_page .. "/4")
    local load = child(panel, "load")
    if load then load.Visible = false end
    for _, node in ipairs(panel:GetChildren()) do
        if node.Name == "hatm" then
            local slot = child(node, "nob")
            local entry = slot and list[slot.Value + (self.clothing_page - 1) * 16]
            node.Image = entry and entry.icon or ""
            local item = child(node, "item")
            if item then item.Value = entry and entry.key or "" end
        elseif node.Name == "wearing" then
            local slot = child(node, "nob")
            local icon = wardrobe and slot and wardrobe:worn_icon(slot.Value)
            if slot and slot.Value == 1 and not icon then icon = NO_HAT end
            node.Image = icon or ""
        end
    end
end

function PauseMenu:_settings()
    local pages = self:_settings_pages()
    local page = math.max(1, math.min(#pages, self.settings_page))
    self.settings_page = page
    local current = pages[page]
    out(self.settings_label, current.title .. "  " .. page .. "/" .. #pages)
    for index, row in ipairs(self.settings_rows) do
        local item = current.items[index]
        row.Visible = item ~= nil
        if item then out(row, item.label .. ": " .. Settings.value_text(item)) end
    end
end

function PauseMenu:_settings_pages()
    if not self.pages then
        self.pages = Settings.pages(self.program, { set_quality = self.callbacks.set_quality })
    end
    return self.pages
end

function PauseMenu:_setting_for(button)
    local index = button and tonumber(tostring(button.Name):match("^row(%d+)$"))
    local page = index and self:_settings_pages()[self.settings_page]
    return page and page.items[index]
end

---------------------------------------------------------------- buttons

-- The textbuttons table, with Settings and the game-quitting Quit.
function PauseMenu:activate(button, direction)
    if not button then return end
    local name = button.Name
    local app, callbacks = self.app, self.callbacks
    if name == "close" then callbacks.resume()
    elseif name == "icecream" then
        local settings = child(app.content.active, "settings")
        local title = child(settings, "title")
        for index, page_title in ipairs(GUIDE_TITLES) do
            if title and title.Value == page_title then self.guide_page = index end
        end
        self:panel("icecream")
    elseif name == "snap" then callbacks.snapshot(true)
    elseif name == "clothing" then self:panel("clothing")
    elseif name == "camera" then
        local still = not self.program:getCustomSetting("s3d_still_camera")
        self.program:setCustomSetting("s3d_still_camera", still)
        local icon = child(button, "icon")
        if icon then icon.ImageRectOffset = { X = still and 128 or 0, Y = 128 } end
    elseif name == "settings" then self.settings_page = 1; self:panel("settings")
    elseif name == "hub" then self:panel("hub")
    elseif name == "hub2" then callbacks.hub()
    elseif name == "quit" then self:panel("quit")
    elseif name == "quit2" then callbacks.quit()
    elseif name == "no" then
        self:panel("pause")
        self.selected = child(self.panels.pause, "close")
    elseif name == "PLeft1" or name == "PRight1" then
        self.guide_page = math.max(1, math.min(#self.guide, self.guide_page + (name == "PLeft1" and -1 or 1)))
        self:_guide()
    elseif name == "PLeft4" or name == "PRight4" then
        self.clothing_page = math.max(1, math.min(4, self.clothing_page + (name == "PLeft4" and -1 or 1)))
        self:_clothing()
    elseif name == "PLeftS" or name == "PRightS" then
        local count = #self:_settings_pages()
        self.settings_page = (self.settings_page - 1 + (name == "PLeftS" and -1 or 1)) % count + 1
        self:_settings()
    elseif name == "hatm" then
        local item = child(button, "item")
        if app.wardrobe and item and item.Value ~= "" then app.wardrobe:equip(item.Value) end
        self:_clothing()
    elseif name == "wearing" then
        local slot = child(button, "nob")
        if app.wardrobe and slot and slot.Value == 1 then app.wardrobe:equip_hat(0) end
        self:_clothing()
    elseif name:match("^row%d+$") then
        local item = self:_setting_for(button)
        if item then
            Settings.adjust(item, direction or 1, direction == nil)
            -- A quality change rebuilds the world, and this menu with it.
            if not self.destroyed and self.open_flag and self.panel_name == "settings" then self:_settings() end
        end
    end
    return true
end

-- Escape or B: out of Snapshot Mode or a sub-panel, or resume from the
-- main one.
function PauseMenu:back()
    if self.snapshot_active then self.callbacks.snapshot(false); return "panel" end
    if self.panel_name == "pause" then self.callbacks.resume(); return "closed" end
    self:panel("pause")
    return "panel"
end

function PauseMenu:destroy()
    self.destroyed, self.open_flag = true, false
end

---------------------------------------------------------------- selection

function PauseMenu:_buttons()
    local out_list = {}
    local panel = self.panels[self.panel_name]
    for _, node in ipairs(panel and panel:GetChildren() or {}) do
        if is_button(node) and node.Visible ~= false then out_list[#out_list + 1] = node end
    end
    return out_list
end

local function rect_of(node)
    local element = rawget(node, "_gui_element")
    local rect = element and rawget(element, "_screen_rect")
    if not rect or rect.size.x <= 0 then return nil end
    return rect
end

-- The nearest button in `direction` ("up", "down", "left", "right"),
-- wrapping around a column, as the authored NextSelection links do.
function PauseMenu:move(direction)
    local buttons = self:_buttons()
    local current = self.selected
    local from = current and rect_of(current)
    if not from then self.selected = buttons[1]; return end
    local cx, cy = from.position.x + from.size.x / 2, from.position.y + from.size.y / 2
    local dx, dy = 0, 0
    if direction == "up" then dy = -1 elseif direction == "down" then dy = 1
    elseif direction == "left" then dx = -1 else dx = 1 end
    local best, best_score, wrap, wrap_score
    for _, button in ipairs(buttons) do
        local rect = button ~= current and rect_of(button)
        if rect then
            local bx, by = rect.position.x + rect.size.x / 2, rect.position.y + rect.size.y / 2
            local along = (bx - cx) * dx + (by - cy) * dy
            local across = math.abs((bx - cx) * dy) + math.abs((by - cy) * dx)
            if along > 1 then
                local score = along + across * 2
                if not best_score or score < best_score then best, best_score = button, score end
            elseif along < -1 and across < math.max(rect.size.x, rect.size.y) then
                local score = along
                if not wrap_score or score < wrap_score then wrap, wrap_score = button, score end
            end
        end
    end
    self.selected = best or (dy ~= 0 and wrap) or current
end

-- Keyboard, gamepad or stick: "up", "down", "left", "right", "accept", "back".
function PauseMenu:input(action)
    if not self.open_flag then return end
    if action == "accept" then return self:activate(self.selected) end
    if action == "back" then return self:back() end
    if (action == "left" or action == "right") and self.panel_name == "settings"
        and self:_setting_for(self.selected) then
        return self:activate(self.selected, action == "left" and -1 or 1)
    end
    self:move(action)
end

local function hit(node, x, y)
    local rect = rect_of(node)
    return rect and x >= rect.position.x and y >= rect.position.y
        and x <= rect.position.x + rect.size.x and y <= rect.position.y + rect.size.y
end

local function canvas_point(x, y)
    local scale = (love.graphics.getPixelWidth and love.graphics.getPixelWidth() or love.graphics.getWidth())
        / love.graphics.getWidth()
    return x * scale, y * scale
end

function PauseMenu:button_at(x, y)
    x, y = canvas_point(x, y)
    for _, button in ipairs(self:_buttons()) do
        if hit(button, x, y) then return button end
    end
end

-- A click activates the button under the cursor; in Snapshot Mode the
-- skip button closes it, and the HUD's pause button resumes from anywhere.
function PauseMenu:click(x, y, button)
    if self.snapshot_active then
        local skip = self.hud:node("skip")
        local cx, cy = canvas_point(x, y)
        if skip and hit(skip, cx, cy) then self.callbacks.snapshot(false) end
        return true
    end
    if not self.open_flag then return false end
    if self.hud:pause_hit(x, y) then self.callbacks.resume(); return true end
    local target = self:button_at(x, y)
    if not target then return true end
    self.selected = target
    self:activate(target, button == 2 and -1 or nil)
    return true
end

-- Hovering selects (InputChanged sets textsel); the marker then glides to
-- the selected button and spins, as in the source's paused RenderStepped.
function PauseMenu:update(dt, mouse_x, mouse_y)
    if not self.open_flag then return end
    self.clock = self.clock + dt
    if mouse_x and (mouse_x ~= self.mouse_x or mouse_y ~= self.mouse_y) then
        self.mouse_x, self.mouse_y = mouse_x, mouse_y
        local target = self:button_at(mouse_x, mouse_y)
        if target then self.selected = target end
    end
    local spin, selected = self.spin, self.selected
    if not spin then return end
    if not selected or not selected.Parent or selected.Parent.Visible == false then
        spin.Visible = false
        return
    end
    local grid = child(selected.Parent, "2B") ~= nil
    spin.Visible = true
    spin.Image = grid and SPIN_GRID or SPIN
    local size = grid and 0.15 or 0.1
    spin.Size = udim2(size, 0, size, 0)
    local px = select(1, udim(selected.Position, "X"))
    local py = select(1, udim(selected.Position, "Y"))
    local sx = select(1, udim(selected.Size, "X"))
    local sy = select(1, udim(selected.Size, "Y"))
    local target_x = grid and px + sx / 2 - size / 2 or .1
    local target_y = py + sy / 2 - size / 2
    local blend = math.min(1, dt * 20)
    self.spin_x = (self.spin_x or target_x) + (target_x - (self.spin_x or target_x)) * blend
    self.spin_y = (self.spin_y or target_y) + (target_y - (self.spin_y or target_y)) * blend
    spin.Position = udim2(self.spin_x, 0, self.spin_y, 0)
    spin.Rotation = self.clock * 80
end

return PauseMenu
