-- The place's own screen UI (StarterGui/UI), driven as the port drives it:
-- source_hud.lua's candy and ice cream counters, equipment_hud.lua's trick
-- panel and timer, the reward caption, the egg counter and the iris wipe of
-- cinematics.lua (all credited to zKevin, see NOTICE.md). Panels the port
-- never shows in play (title, loading, mobile pad, editor, its own cursor)
-- stay hidden; pause_menu.lua drives the place's pause screen.
local Source = require("projects/showcase3d/robot64/source")

local HUD = {}
HUD.__index = HUD

local NORMAL_ICE = "rbxassetid://1374179631"
-- Top-level panels of StarterGui/UI that the sandbox shows; everything else
-- under it starts hidden.
local SCREENS = { UI = true, hawk = true, time = true, BT = true, loop = true }

local function child(node, name) return node and node:FindFirstChild(name) end

local function udim2(sx, ox, sy, oy)
    return { X = { Scale = sx, Offset = ox or 0 }, Y = { Scale = sy, Offset = oy or 0 } }
end

-- Authored UDim2 values may use either key case.
local function udim(value, axis)
    local item = value and (value[axis] or value[axis:lower()])
    if type(item) ~= "table" then return nil end
    return item.Scale or item.scale or 0, item.Offset or item.offset or 0
end

function HUD.new(world, assets, rbx)
    local gui = assert(child(Source.service(world, "StarterGui"), "UI"), "StarterGui/UI is missing")
    local self = setmetatable({ world = world, assets = assets, rbx = rbx, gui = gui, nodes = {}, shown = {} }, HUD)
    for _, node in ipairs(gui:GetChildren()) do
        if node.Visible ~= nil and not SCREENS[node.Name] then node.Visible = false end
        -- The source's fullscreen roots cover Roblox's 36 px top bar; the
        -- port removes that adjustment, and so does this.
        local pxs, pxo = udim(node.Position, "X")
        local pys, pyo = udim(node.Position, "Y")
        local sxs, sxo = udim(node.Size, "X")
        local sys, syo = udim(node.Size, "Y")
        if pyo == -36 and sys then
            node.Position = udim2(pxs, pxo, pys, 0)
            node.Size = udim2(sxs, sxo, sys, math.max(0, syo - 36))
        end
    end
    for name in pairs(SCREENS) do self:screen(name, false) end
    gui.Enabled = true
    return self
end

function HUD:node(path)
    local node = self.nodes[path]
    if node and node.Parent then return node end
    node = self.gui
    for name in path:gmatch("[^/]+") do node = child(node, name) end
    self.nodes[path] = node
    return node
end

function HUD:screen(name, visible)
    local node = self:node(name)
    if node then node.Visible = visible ~= false end
    self.shown[name] = visible ~= false
end

function HUD:text(path, value)
    local node = self:node(path)
    local text = tostring(value)
    if node and node.Text ~= text then
        node.Text = text
        local outline = child(node, "outline")
        if outline then outline.Text = text end
    end
end

function HUD:image(path, reference)
    local node = self:node(path)
    if node and self.assets:resolve(reference, "texture") and node.Image ~= reference then node.Image = reference end
end

---------------------------------------------------------------- source_hud

function HUD:reset(session)
    self.candy = session.state.candy or 0
    self:text("UI/candy/tx", self.candy)
end

function HUD:activate(map, session, onejump)
    if self.candy == nil then self:reset(session) end
    self.active = true
    self:image("UI/icedcream/img", NORMAL_ICE)
    self:screen("UI", true)
    local egg = self:node("UI/egg")
    if egg then egg.Visible = false end
    local jump = self:node("UI/jump")
    if jump then jump.Visible = onejump == true end
end

-- The counter catches up one candy per two 0.06 s ticks, bouncing its icon.
function HUD:cadence(counter, session, paused, on_candy)
    if not self.active or paused then return end
    local target, y = session.state.candy or 0, .1
    if counter % 2 == 0 and self.candy < target then
        self.candy = self.candy + 1; y = 0
        if on_candy then on_candy() end
        self:text("UI/candy/tx", self.candy)
    elseif counter % 2 == 0 and self.candy > target then
        self.candy = self.candy - 1; y = .2
        self:text("UI/candy/tx", self.candy)
    end
    local icon = self:node("UI/candy/img")
    if icon and (self.icon_y ~= y) then
        self.icon_y = y
        icon.Position = udim2(.045, 0, y, 0)
    end
    self:text("UI/icedcream/tx", session.icedcream or 0)
end

function HUD:eggs(count, max)
    local egg = self:node("UI/egg")
    if egg then egg.Visible = true end
    self:text("UI/egg/tx", count .. "/" .. max)
end

function HUD:caption(title, sub)
    self:screen("BT", title ~= nil)
    if title then
        self:text("BT", title)
        self:text("BT/sub", sub or "")
    end
end

------------------------------------------------------------- equipment_hud

function HUD:equipment(equipment, rewarding)
    local status = equipment:trick_status()
    self:screen("hawk", status.visible and not rewarding)
    local trick = self:node("hawk/trick")
    local gap = status.gap == true
    if trick and self.trick_gap ~= gap then
        self.trick_gap = gap
        trick.TextColor3 = gap and self.rbx.Color3.new(0, .7, 1) or self.rbx.Color3.new(1, 1, 1)
    end
    self:text("hawk/trick", status.name)
    self:text("hawk/pts", status.points ~= 0 and (status.points .. " x " .. status.multiplier) or "")
    self:text("hawk/score", "Score: " .. status.score)
    self:screen("time", equipment.timer_visible == true)
    if equipment.timer_visible and status.time ~= "" then self:text("time", status.time or "") end
end

---------------------------------------------------------------- the iris

-- A square of the screen's longer side, with a circular hole that closes
-- or opens with `fraction`.
function HUD:iris(closing, fraction)
    local loop = self:node("loop")
    if not loop then return end
    self:screen("loop", true)
    local width, height = love.graphics.getDimensions()
    local side = math.max(width, height)
    local sx, sy = side / width, side / height
    loop.Position = udim2((1 - sx) / 2, 0, (1 - sy) / 2, 0)
    loop.Size = udim2(sx, 0, sy, 0)
    fraction = math.max(0, math.min(1, fraction))
    local hole = (closing and 1 - fraction or fraction) * 2
    loop.BackgroundColor3 = self.rbx.Color3.new(0, 0, 0)
    loop.BackgroundTransparency = closing and fraction >= 1 and 0 or 1
    -- Rectangles from signed endpoints, in square-relative scale plus pixels.
    local function rect(name, px, py, w, h, ow, oh)
        local node = child(loop, name)
        if not node then return end
        local x0, y0, x1, y1 = px, py, px + w, py + h
        ow, oh = ow or 0, oh or 0
        local x, xo, wide, wo = x0, 0, x1 - x0, ow
        if wide < 0 or (wide == 0 and ow < 0) then x, xo, wide, wo = x1, ow, x0 - x1, -ow end
        local y, yo, tall, ho = y0, 0, y1 - y0, oh
        if tall < 0 or (tall == 0 and oh < 0) then y, yo, tall, ho = y1, oh, y0 - y1, -oh end
        node.Position = udim2(x, xo, y, yo)
        node.Size = udim2(wide, wo, tall, ho)
    end
    rect("center", .5 - hole / 2, .5 - hole / 2, hole, hole)
    rect("l", 0, 0, .5 - hole / 2, 1, 1, 1)
    rect("r", 1, 0, -.5 + hole / 2, 1, -1, -1)
    rect("u", 0, 0, 1, .5 - hole / 2, 1, 1)
    rect("d", 0, 1, 1, -.5 + hole / 2, -1, -1)
end

function HUD:hide_iris() self:screen("loop", false) end

---------------------------------------------------------------- input

-- The HUD's pause button opens the engine menu, as it opens the source's.
function HUD:pause_hit(x, y)
    local button = self.shown.UI and self:node("UI/pause")
    local element = button and button.Visible and rawget(button, "_gui_element")
    local rect = element and rawget(element, "_screen_rect")
    if not rect or rect.size.x <= 0 then return false end
    local canvas_width = love.graphics.getPixelWidth and love.graphics.getPixelWidth() or love.graphics.getWidth()
    local scale = canvas_width / love.graphics.getWidth()
    x, y = x * scale, y * scale
    return x >= rect.position.x and y >= rect.position.y
        and x <= rect.position.x + rect.size.x and y <= rect.position.y + rect.size.y
end

function HUD:set_visible(visible)
    self.gui.Enabled = visible ~= false
end

function HUD:destroy()
    self.active = false
    self.gui.Enabled = false
end

return HUD
