-- thread_worker.lua
-- resolve engine paths when the engine is mounted below another project
require("love.filesystem")
-- Greedy: a mount folder such as "wave-engine/" also ends in "engine/"
local engine_mount = debug.getinfo(1, "S").source:match("^@(.*)engine/")
if engine_mount and engine_mount ~= "" then
    love.filesystem.load(engine_mount .. "engine/mount.lua")()(engine_mount)
end
local ENGINE_ROOT = require("engine/root")
local channelName = ...
local channel = love.thread.getChannel(channelName)
local fnString = channel:demand()

local fn = loadstring(fnString)
if not fn then
    print("[thread] could not load function")
    return
end

local love_timer = require("love.timer")
local love_math = require("love.math")
local love_fs = require("love.filesystem")

local env = {
    wait = function(seconds)
        love_timer.sleep(seconds)
    end,
    print = print,
    math = math,
    string = string,
    table = table,
    tonumber = tonumber,
    tostring = tostring,
    ipairs = ipairs,
    pairs = pairs,
    love = {
        timer = love_timer,
        math = love_math,
        filesystem = love_fs,
    }
}

setfenv(fn, env)

local ok, err = pcall(fn)
if not ok then
    print("[thread] error:", err)
end
