-- Texture-decode worker: decodes PNGs to ImageData off the main thread so the CPU decode
-- overlaps the (main-thread) classify pass during map load. GPU upload stays on the main
-- thread (single GL context). every failure is benign: a missing/undecoded path is reported
-- back as data=false and the main thread just decodes it synchronously as it does today
--
-- Args: request_channel_name, response_channel_name (love.thread channel names)
-- Request messages: a backward-compatible string path, a table carrying path
-- and exact alpha-bleed role, or the sentinel "__TEXPREFETCH_STOP__" to exit
-- Response ImageData remains owned by the main-thread load cache until stop
-- resolve engine paths when the engine is mounted below another project
require("love.filesystem")
-- Greedy: a mount folder such as "wave-engine/" also ends in "engine/"
local engine_mount = debug.getinfo(1, "S").source:match("^@(.*)engine/")
if engine_mount and engine_mount ~= "" then
    love.filesystem.load(engine_mount .. "engine/mount.lua")()(engine_mount)
end
local ENGINE_ROOT = require("engine/root")
local request_channel_name, response_channel_name = ...

require("love.image")
require("love.filesystem")

local alpha_bleed_chunk = assert(love.filesystem.load(
    ENGINE_ROOT .. "/graphics/rbx/runtime/alpha_bleed.lua"))
local AlphaBleed = alpha_bleed_chunk()

local request_channel = love.thread.getChannel(request_channel_name)
local response_channel = love.thread.getChannel(response_channel_name)

local STOP = "__TEXPREFETCH_STOP__"

while true do
    local job = request_channel:demand()
    if job == nil or job == STOP then
        break
    end
    local path = type(job) == "table" and job.path or job
    local alpha_bleed = type(job) == "table"
        and job.alpha_bleed == true or false
    if type(path) == "string" then
        local profile = type(job) == "table" and job.profile == true
        if profile and not love.timer then pcall(require, "love.timer") end
        local now = profile and love.timer and love.timer.getTime
        local decode_start = now and now() or nil
        local ok, data = pcall(love.image.newImageData, path)
        local decode_seconds = decode_start and math.max(0, now() - decode_start) or 0
        local decoded_bytes = 0
        if ok and data and data.getSize then
            local size_ok, size = pcall(data.getSize, data)
            if size_ok then decoded_bytes = math.max(0, tonumber(size) or 0) end
        end
        local max_decoded_bytes = type(job) == "table"
            and tonumber(job.max_decoded_bytes) or nil
        if ok and data and max_decoded_bytes then
            if decoded_bytes > max_decoded_bytes then
                data:release()
                data = false
                ok = false
            end
        end
        if ok and data then
            local bled = false
            local bleed_seconds = 0
            if alpha_bleed then
                local bleed_start = now and now() or nil
                local bleed_ok = pcall(AlphaBleed.bleed, data)
                bleed_seconds = bleed_start
                    and math.max(0, now() - bleed_start) or 0
                if not bleed_ok then
                    data:release()
                    data = false
                else
                    bled = true
                end
            end
            response_channel:push({
                path = path,
                alpha_bleed = alpha_bleed,
                data = data,
                bled = bled,
                decode_seconds = decode_seconds,
                alpha_bleed_seconds = bleed_seconds,
                decoded_bytes = decoded_bytes,
            })
        else
            response_channel:push({
                path = path,
                alpha_bleed = alpha_bleed,
                data = false,
                bled = false,
                decode_seconds = decode_seconds,
                alpha_bleed_seconds = 0,
                decoded_bytes = decoded_bytes,
            })
        end
    end
end
