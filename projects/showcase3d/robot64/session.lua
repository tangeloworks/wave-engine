-- The player's run state, from the port's session.lua (credited to zKevin,
-- see NOTICE.md): health, candy, ice cream, gate progress and the gameplay
-- clock. The sandbox keeps it in memory only; nothing is saved.
local Session = {}
Session.__index = Session

local function key(id)
    if type(id) == "number" then
        if id ~= math.floor(id) or id == 0 then return nil end
        id = tostring(id)
    end
    return type(id) == "string" and id ~= "" and id or nil
end

local function count(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

function Session.new()
    return setmetatable({
        state = { candy = 0, progress = 0, collectibles = {} },
        health = 4, icedcream = 0, nightmode = false, paused = false, epoch = 1,
        clocks = { gameplay = 0, presentation = 0 },
    }, Session)
end

function Session:update(dt)
    self.clocks.presentation = self.clocks.presentation + dt
    if not self.paused and not self.loading then self.clocks.gameplay = self.clocks.gameplay + dt end
end

function Session:has_collectible(id)
    local k = key(id)
    return k ~= nil and self.state.collectibles[k] == true
end

-- A repeat collection pays 10 candy instead, as the source's notcream does.
function Session:collect(id)
    local k = key(id)
    if not k then return false, "Invalid collectible ID." end
    local duplicate = self.state.collectibles[k] == true
    if duplicate then self.state.candy = self.state.candy + 10 else self.state.collectibles[k] = true end
    self.health, self.icedcream = 4, count(self.state.collectibles)
    return true, { duplicate = duplicate, candy = duplicate and 10 or 0, id = k }
end

function Session:add_candy(amount)
    self.state.candy = self.state.candy + amount
    return true
end

function Session:set_progress(value)
    self.state.progress, self.nightmode = value, value >= 6
    return true
end

function Session:set_loading(value) self.loading = value == true end

return Session
