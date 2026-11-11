-- classes are callable and inherit through :extend()
-- Element and Text use super to reach their parent implementation
local Object = {}
Object.__index = Object

function Object:init() end

function Object:extend()
    local class = {}
    -- Lua does not inherit metamethods through `__index`, so copy a parent's
    -- explicitly declared metamethods onto subclasses
    for key, value in pairs(self) do
        if key:sub(1, 2) == "__" then class[key] = value end
    end
    class.__index = class
    class.super = self
    return setmetatable(class, {
        __index = self,
        __call = function(class_table, ...)
            local instance = setmetatable({}, class_table)
            instance:init(...)
            return instance
        end,
    })
end

setmetatable(Object, {
    __call = function(class, ...)
        local instance = setmetatable({}, class)
        instance:init(...)
        return instance
    end,
})

_G.Object = Object
return Object
