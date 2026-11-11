-- two-dimensional vectors for layout, input and drawing
local Vector = {}
Vector.__index = Vector

function Vector.new(x, y)
    return setmetatable({ x = x or 0, y = y or 0 }, Vector)
end

function Vector.fromAngle(theta)
    return Vector.new(math.cos(theta), -math.sin(theta))
end

function Vector.random()
    local random = love and love.math and love.math.random or math.random
    return Vector.fromAngle(random() * math.pi * 2)
end

function Vector.isVector(value)
    return getmetatable(value) == Vector
end

function Vector:set(x, y)
    if Vector.isVector(x) then
        self.x, self.y = x.x, x.y
    else
        self.x, self.y = x or self.x, y or self.y
    end
    return self
end

function Vector:clone() return Vector.new(self.x, self.y) end
function Vector:unpack() return self.x, self.y end
function Vector:array() return { self.x, self.y } end

function Vector:replace(value)
    assert(Vector.isVector(value), "replace expects a wave vector")
    self.x, self.y = value.x, value.y
    return self
end

function Vector:magnitudeSq() return self.x * self.x + self.y * self.y end
function Vector:magnitude() return math.sqrt(self:magnitudeSq()) end

function Vector:setMagnitude(magnitude)
    local current = self:magnitude()
    if current > 0 then self:scale(magnitude / current) end
    return self
end

function Vector:normalize()
    local current = self:magnitude()
    if current > 0 then self:scale(1 / current) end
    return self
end

function Vector:scale(value)
    self.x, self.y = self.x * value, self.y * value
    return self
end

function Vector:limit(maximum)
    if self:magnitudeSq() > maximum * maximum then self:setMagnitude(maximum) end
    return self
end

function Vector:clamp(minimum, maximum)
    self.x = math.max(minimum.x, math.min(self.x, maximum.x))
    self.y = math.max(minimum.y, math.min(self.y, maximum.y))
    return self
end

function Vector:dot(value) return self.x * value.x + self.y * value.y end
function Vector:heading() return -math.atan2(self.y, self.x) end

function Vector:rotate(theta)
    local cosine, sine = math.cos(theta), math.sin(theta)
    local x, y = self.x, self.y
    self.x, self.y = cosine * x + sine * y, -sine * x + cosine * y
    return self
end

function Vector:perpendicular() return Vector.new(-self.y, self.x) end
function Vector:angleTo(value) return math.atan2(value.y - self.y, value.x - self.x) end

function Vector:lerp(value, amount)
    self.x = self.x + (value.x - self.x) * amount
    self.y = self.y + (value.y - self.y) * amount
    return self
end

function Vector:__tostring() return ("(%.3f, %.3f)"):format(self.x, self.y) end
function Vector.__add(a, b) return Vector.new(a.x + b.x, a.y + b.y) end
function Vector.__sub(a, b) return Vector.new(a.x - b.x, a.y - b.y) end
function Vector.__unm(a) return Vector.new(-a.x, -a.y) end
function Vector.__eq(a, b) return a.x == b.x and a.y == b.y end

function Vector.__mul(a, b)
    if type(a) == "number" then return Vector.new(a * b.x, a * b.y) end
    if type(b) == "number" then return Vector.new(a.x * b, a.y * b) end
    return Vector.new(a.x * b.x, a.y * b.y)
end

function Vector.__div(a, b)
    if type(b) == "number" then return Vector.new(a.x / b, a.y / b) end
    return Vector.new(a.x / b.x, a.y / b.y)
end

function Vector.distance(a, b)
    return (a - b):magnitude()
end

function Vector.angleBetween(a, b)
    local divisor = a:magnitude() * b:magnitude()
    if divisor == 0 then return 0 end
    return math.acos(math.max(-1, math.min(1, a:dot(b) / divisor)))
end

local vec2 = setmetatable({
    new = Vector.new,
    fromAngle = Vector.fromAngle,
    random = Vector.random,
    isVector = Vector.isVector,
    distance = Vector.distance,
    angleBetween = Vector.angleBetween,
}, { __call = function(_, ...) return Vector.new(...) end })

_G.vec2 = vec2
return vec2
