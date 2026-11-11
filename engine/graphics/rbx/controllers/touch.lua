-- Touched/TouchEnded helper for interactive parts
--
-- Physics contacts can begin and end several times while a body rests or
-- rolls across a part. this wrapper adds the bookkeeping most triggers need:
-- a filter for who may trigger it, per-toucher contact tracking, a cooldown
-- before the same toucher can trigger again, and one call to disconnect
--
--     local Touch = require("engine/graphics/rbx/controllers/touch")
--     local trigger = Touch.connect(pad, {
--         filter = function(other) return other == player_body end,
--         cooldown = 0.5,
--         on_touch = function(other, part) print("stepped on", part.Name) end,
--     })
--     trigger:disconnect()

local Touch = {}
Touch.__index = Touch

local function now()
    return love.timer.getTime()
end

---@param part RBXLXPart a part with CanTouch enabled
---@param options { filter?: fun(other):boolean, on_touch?: fun(other, part), on_leave?: fun(other, part), cooldown?: number, once?: boolean }
function Touch.connect(part, options)
    assert(part and part.Touched, "Touch.connect needs an RBX part")
    options = options or {}
    local self = setmetatable({
        part = part,
        filter = options.filter,
        on_touch = options.on_touch,
        on_leave = options.on_leave,
        cooldown = tonumber(options.cooldown) or 0,
        once = options.once == true,
        enabled = true,
        fired = false,
        -- other part -> number of open contacts, last trigger times
        contacts = {},
        last_fired = {},
    }, Touch)

    self.touched_connection = part.Touched:Connect(function(other)
        self:_begin(other)
    end)
    if part.TouchEnded then
        self.ended_connection = part.TouchEnded:Connect(function(other)
            self:_end(other)
        end)
    end
    return self
end

function Touch:_begin(other)
    if not self.enabled or other == nil then return end
    if self.filter and not self.filter(other) then return end
    local open = self.contacts[other] or 0
    self.contacts[other] = open + 1
    if open > 0 then return end
    if self.once and self.fired then return end
    local last = self.last_fired[other]
    local time = now()
    if last and time - last < self.cooldown then return end
    self.last_fired[other] = time
    self.fired = true
    if self.on_touch then self.on_touch(other, self.part) end
end

function Touch:_end(other)
    local open = self.contacts[other]
    if not open then return end
    if open > 1 then
        self.contacts[other] = open - 1
        return
    end
    self.contacts[other] = nil
    if self.enabled and self.on_leave then self.on_leave(other, self.part) end
end

---true while the given part is in contact (after filtering)
function Touch:is_touching(other)
    return self.contacts[other] ~= nil
end

---Allow a `once` trigger to fire again and forget previous cooldowns
function Touch:reset()
    self.fired = false
    self.last_fired = {}
end

function Touch:set_enabled(enabled)
    self.enabled = enabled == true
end

function Touch:disconnect()
    if self.touched_connection then self.touched_connection:Disconnect() end
    if self.ended_connection then self.ended_connection:Disconnect() end
    self.touched_connection, self.ended_connection = nil, nil
    self.contacts = {}
    self.enabled = false
end

return Touch
