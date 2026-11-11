---@class Particle: Object
---@overload fun(args?: table): Particle
---@type Particle
Particle = Object:extend()

Particle.all = {
    pausable = {},
    unpausable = {},
}

function Particle:init(args)
    args = args or {}
    self.x = args.x or 0
    self.y = args.y or 0
    self.vx = args.vx or 0
    self.vy = args.vy or 0
    self.timer = args.life or args.timer or 1
    self.shape = args.shape or "circle"
    self.size = args.size or args.radius or 8
    self.color = args.color and args.color or { 1, 1, 1, 1 }
    self.img = args.img
    self.autoDestroy = args.autoDestroy == nil and true or args.autoDestroy
    self.drawmethod = args.drawmethod
    self.drawmode = args.drawmode or "fill"
    self.category = args.pausable and "pausable" or "unpausable"
    self.respectworld = args.respectworld
    self.respectratio = args.respectratio

    self.rotation = args.rotation or 0
    self.angularVelocity = args.angularVelocity or 0
    self.element = args.element
    self.onUpdate = args.onUpdate
    self.onDraw = args.onDraw
    self.onDestroy = args.onDestroy

    if self.element then
        self.element.position = self.element.position or { scale = vec2(0, 0), offset = vec2(0, 0) }
        self.element.position.scale = vec2(0, 0)
        self.shape = "element"
    end

    table.insert(Particle.all[self.category], self)
end

function Particle:tween(duration, target, doDestroy, easing, args)
    local giveargs = args or {}
    if doDestroy then
        local oldFunc = giveargs['completeFunc']
        giveargs.completeFunc = function()
            if oldFunc then
                oldFunc()
            end
            self:destroy()
        end
    end
    return tween.new(duration, self, target, easing or "linear", giveargs)
end

function Particle:update(dt)
    self.x = self.x + self.vx * dt
    self.y = self.y + self.vy * dt

    self.rotation = self.rotation + self.angularVelocity * dt

    local element = self.element
    local elementData = element and rawget(element, "__data")
    local position = elementData and elementData.position
    if position then
        position.offset.x = self.x
        position.offset.y = self.y
        elementData.rotation = self.rotation
        Element.mark_dirty(element, 'position')
    end

    self.timer = self.timer - dt

    local updateCallback = self.onUpdate
    if updateCallback then updateCallback(self, dt) end
    if element and element.update then element:update(dt) end

    if self.autoDestroy and self.timer <= 0 then self:destroy() end
end

function Particle:draw()
    -- Custom particle callbacks can bind shaders, fonts or render targets
    -- their state must not poison a subsequent text/Canvas bake
    love.graphics.push("all")
    local goalx, goaly, goalsize = self.x, self.y, self.size
    local rotation = self.rotation

    if self.respectworld then
        goalx, goaly = (goalx * world.camzoom - world.campos.x), (goaly * world.camzoom - world.campos.y)
        goalsize = goalsize * world.camzoom
    elseif self.respectratio then
        goalx = goalx * G.resolution.x
        goaly = goaly * G.resolution.y
    end

    love.graphics.origin()

    if self.drawmethod then
        self:drawmethod(self)
    elseif self.shape == "element" and self.element then
        local rect = self._element_draw_rect
        if not rect then
            rect = { position = vec2(), size = vec2(), _v = 1 }
            self._element_draw_rect = rect
        end
        rect.position.x = goalx
        rect.position.y = goaly
        local elementRect = Element.get_screen_rect(self.element)
        local elementSize = elementRect and elementRect.size
        rect.size.x = (elementSize and elementSize.x) or goalsize
        rect.size.y = (elementSize and elementSize.y) or goalsize
        rect._v = (rect._v or 0) + 1
        Element.draw(self.element, rect)
    elseif self.shape == "circle" then
        love.graphics.setColor(self.color)
        love.graphics.push()
        love.graphics.translate(goalx, goaly)
        love.graphics.rotate(rotation)
        love.graphics.circle(self.drawmode, 0, 0, goalsize)
        love.graphics.pop()
    elseif self.shape == "rect" then
        love.graphics.setColor(self.color)
        love.graphics.push()
        love.graphics.translate(goalx, goaly)
        love.graphics.rotate(rotation)
        love.graphics.rectangle(self.drawmode, -goalsize / 2, -goalsize / 2, goalsize, goalsize)
        love.graphics.pop()
    elseif self.shape == "image" and self.img then
        love.graphics.setColor(self.color)
        love.graphics.draw(self.img, goalx, goaly, rotation, 1, 1, goalsize / 2, goalsize / 2)
    end

    local drawCallback = self.onDraw
    if drawCallback then drawCallback(self) end

    love.graphics.pop()
end

function Particle:destroy()
    local destroyCallback = self.onDestroy
    if destroyCallback then destroyCallback(self) end

    if self.element then
        self.element = nil
    end

    local pool = Particle.all[self.category]
    for i = #pool, 1, -1 do
        if pool[i] == self then
            table.remove(pool, i)
            break
        end
    end
end

function Particle.updateAll(category, dt)
    for i = #Particle.all[category], 1, -1 do
        local p = Particle.all[category][i]
        p:update(dt)
    end
end

function Particle.drawAll(category)
    for i = 1, #Particle.all[category] do
        Particle.all[category][i]:draw()
    end
end
