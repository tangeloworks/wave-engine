---@class Debug: Object
Debug = Object:extend()

function Debug:init()
    self.on = false
    self.noclip = false
    self.log = { { key = 'delta', value = '' },
        { key = 'input type', value = '' },
        { key = 'mem usage',  value = '' },
        { key = 'resolution', value = '' }
    }
end

function Debug:get(key)
    for _, pair in ipairs(self.log) do
        if pair.key == key then
            return pair.value
        end
    end
    table.insert(self.log, { key = key, value = '' })
end

function Debug:update(key, newValue)
    if type(newValue) == 'table' then
        newValue = table2str(newValue)
    end
    for _, pair in ipairs(self.log) do
        if pair.key == key then
            pair.value = newValue
            return
        end
    end
    table.insert(self.log, { key = key, value = newValue })
end

local function visualize(element, pos)
    if element.visible then
        local rect = element:get_screen_rect()
        local sw, sh = rect.size.x, rect.size.y
        local cx, cy = rect.position.x + sw / 2, rect.position.y + sh / 2
        local isHit = element:point_in(pos.x, pos.y)

        love.graphics.push()
        love.graphics.translate(cx, cy)
        if rect.rotation and rect.rotation ~= 0 then
            love.graphics.rotate(rect.rotation)
        end
        love.graphics.translate(-sw * 0.5, -sh * 0.5)

        if element.mousecheck then
            love.graphics.setColor(0, isHit and 1 or 0.5, isHit and 0 or 1, 0.8)
        elseif element.selectable then
            love.graphics.setColor(isHit and 1 or 0.5, 1, 0, 0.8)
        else
            love.graphics.setColor(1, isHit and 0 or 1, isHit and 0 or 1, 0.5)
        end

        love.graphics.rectangle("line", 0, 0, sw, sh)

        love.graphics.setColor(1, 1, 1, 0.8)
        love.graphics.pop()
    end
end

--[[ shared empty table: `node.children or {}` allocated a fresh table for
every childless element every frame while the overlay was on ]]
local NO_CHILDREN = {}
local function visualize_tree(node, pos)
    if not node then return end
    visualize(node, pos)
    local ch = node.children or NO_CHILDREN
    for i = 1, #ch do visualize_tree(ch[i], pos) end
end

function Debug:draw()
    local pos = input_mgr.mouse.position
    if G.debug.on then
        for i, element in ipairs(AllElements) do
            visualize_tree(element, pos)
        end
        local target = Element.hitTestAt(pos.x, pos.y)
        if target then
            local r = target:get_screen_rect()
            love.graphics.push("all")
            love.graphics.setColor(1, 0, 0, 0.35)
            love.graphics.rectangle("fill", r.position.x, r.position.y, r.size.x, r.size.y)
            love.graphics.pop()
        end
    end
    love.graphics.origin()
end
