task = {}
local threadCounter = 0

local function serializeFunction(fn)
    return string.dump(fn)
end

function task.spawn(fn)
    assert(type(fn) == "function", "task.spawn expects a function")

    threadCounter = threadCounter + 1
    local threadName = "thread_" .. threadCounter
    local threadFile = require("engine/root") .. "/services/thread_worker.lua"
    local thread = love.thread.newThread(threadFile)
    local channelName = "channel_" .. threadName

    local safeEnv = {}
    for k, v in pairs(_G) do
        if type(v) ~= "table" or (k ~= "love" and k ~= "io") then
            safeEnv[k] = v
        elseif k == "love" then
            safeEnv.love = {
                timer = love.timer,
                math = love.math,
                filesystem = love.filesystem,
                thread = love.thread
                -- add more safe modules here
            }
        end
    end

    local channel = love.thread.getChannel(channelName)
    channel:push(serializeFunction(fn))

    thread:start(channelName)
end

function task.delay(seconds, fn)
    assert(type(seconds) == "number", "task.delay expects seconds as number")
    assert(type(fn) == "function", "task.delay expects a function")

    task.spawn(function()
        wait(seconds)
        fn()
    end)
end
