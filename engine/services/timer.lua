---@class Timer
---@field type_ string
---@field timer number
---@field paused boolean
---@field count integer
---@field args table
local Timer = {}
Timer.__index = Timer

---@class TimerManager
---@field timers table<string, Timer[]>
---@field paused boolean
timers = {
    timers = {
        pausable = {},
        unpausable = {},
    },
    paused = false,
}

local typeBool = {
    [true] = 'pausable',
    [false] = 'unpausable',
}

---@param timerType string | table | boolean
---@param args? table
---@return Timer
function timers.new(timerType, args)
    if type(timerType) == 'table' then
        args = timerType
    else
        args = args or { -- template args
            time = 0,
            completed = function()
            end,
            countNum = 0,
        }
    end
    timerType = type(timerType) == 'table' and 'unpausable'
        or type(timerType) == 'boolean' and typeBool[timerType]
        or timerType or 'unpausable'

    local t = setmetatable({
        type_ = timerType,
        timer = 0,
        paused = args.paused ~= nil and args.paused or false,
        count = 0,
        args = args,
    }, Timer)

    local list = timers.timers[timerType]
    list[#list + 1] = t
    return t
end

-- use local variables for known strings to avoid rehashing
local KEY_TD, KEY_MULT, KEY_DEBRIS, KEY_DOUNTIL, KEY_LOOP, KEY_REPEAT = 'delay', 'multiple', 'debris', 'do_until', 'loop',
    'repeat'

local timeFuncs = {
    [KEY_TD] = function(self, args)
        -- execute on delay
        if self.timer >= args.time then
            if args.completed then args.completed() end
            self:destroy()
        end
    end,
    [KEY_MULT] = function(self, args)
        -- repeat execution multiple times until end
        if self.timer > args.time then
            self.count = self.count + 1
            if args.execute and self.count < args.countNum + 1 then
                args.execute(self.count, false)
            end
            self.timer = 0
            if args.countNum > 0 and self.count > args.countNum then
                self.count = 0
                if args.completed then
                    args.completed(self)
                end
                self:destroy()
            end
        end
    end,
    [KEY_DEBRIS] = function(self, args)
        -- destroy on execution
        if args.time > 0 and self.timer >= args.time then
            local obj = args.toDestroy
            if obj then obj:Destroy() end
            self:destroy()
        end
    end,
    [KEY_DOUNTIL] = function(self, args, dt)
        -- execute until end of timer
        if args.time > 0 and self.timer >= args.time then
            if args.completed then args.completed() end
            self:destroy()
        else
            args.loopfunc(dt, self.timer, self)
        end
    end,
    [KEY_REPEAT] = function(self, args, dt)
        -- repeat X until X is true
        if args.statement() then
            if args.completed then args.completed() end
            self:destroy()
        else
            args.loopfunc(dt, self.timer, self)
        end
    end,
    [KEY_LOOP] = function(self, args, dt)
        -- execute until destroyed
        args.loopfunc(dt, self.timer, self)
    end
}

---@param dt number
---@param forcepause boolean?
function Timer:update(dt, forcepause)
    if not forcepause and not self.paused then
        self.timer = self.timer + dt
        local func = timeFuncs[self.args.type]
        if func then
            func(self, self.args, dt)
        end
    end
end

function Timer:draw(dt, forcepause)
    if self.args.drawfunc then
        self.args.drawfunc()
    end
end

function Timer:reset()
    self.timer = 0
end

function Timer:destroy(runexit)
    if runexit then
        if self.args.completed then self.args.completed() end
    end

    local list = timers.timers[self.type_]
    for i = 1, #list do
        if list[i] == self then
            list[i] = list[#list]
            list[#list] = nil
            break
        end
    end
end

function Timer:stop()
    self:destroy(false)
end

function Timer:pause()
    self.paused = true
end

function Timer:resume()
    self.paused = false
end

function Timer:is_active()
    local list = timers.timers[self.type_]
    for i = 1, #list do
        if list[i] == self then
            return true
        end
    end
    return false
end

---@param list Timer[]
---@param dt number
---@param forcepause boolean?
local function updateList(list, dt, forcepause)
    for i = 1, #list do
        if list[i] then
            list[i]:update(dt, forcepause)
        end
    end
end

---@param list Timer[]
---@param dt number
---@param forcepause boolean?
local function drawList(list, dt, forcepause)
    for i = 1, #list do
        if list[i] then
            list[i]:draw(dt, forcepause)
        end
    end
end

---@param dt number
function timers.update(dt)
    updateList(timers.timers.pausable, dt, timers.paused)
    updateList(timers.timers.unpausable, dt)
end

---@param dt number
function timers.draw(dt)
    drawList(timers.timers.pausable, dt, timers.paused)
    drawList(timers.timers.unpausable, dt)
end

-- convenience methods for common timer patterns

---@param delay number
---@param callback function
---@return Timer
function timers.after(delay, callback)
    return timers.new({
        type = 'delay',
        time = delay,
        completed = callback
    })
end

---@param interval number
---@param callback function
---@param count? number
---@return Timer
function timers.every(interval, callback, count)
    return timers.new({
        type = 'multiple',
        time = interval,
        execute = callback,
        countNum = count or -1,
        completed = function(timer)
            timer:destroy()
        end
    })
end

---@param delay number
---@param callback function
---@param loopfunc function
---@return Timer
function timers.do_until(delay, callback, loopfunc)
    return timers.new({
        type = 'do_until',
        time = delay,
        completed = callback,
        loopfunc = loopfunc
    })
end

---@param callback function
---@param loopfunc function
---@return Timer
function timers.repeat_until(callback, loopfunc, completefunc)
    return timers.new({
        type = 'repeat',
        completed = completefunc or function() end,
        loopfunc = loopfunc,
        statement = callback,
    })
end

---@param loopfunc function
---@return Timer
function timers.loop(loopfunc)
    return timers.new({
        type = 'loop',
        loopfunc = loopfunc
    })
end

---@param timerType? string
function timers.clear(timerType)
    if timerType then
        timers.timers[timerType] = {}
    else
        timers.timers.pausable = {}
        timers.timers.unpausable = {}
    end
end
