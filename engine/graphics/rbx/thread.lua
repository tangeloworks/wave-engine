-- resolve engine paths when the engine is mounted below another project
require("love.filesystem")
-- Greedy: a mount folder such as "wave-engine/" also ends in "engine/"
local engine_mount = debug.getinfo(1, "S").source:match("^@(.*)engine/")
if engine_mount and engine_mount ~= "" then
    love.filesystem.load(engine_mount .. "engine/mount.lua")()(engine_mount)
end
local ENGINE_ROOT = require("engine/root")
local request_channel_name, response_channel_name = ...
-- worker threads dont auto-load love.timer, without this, stage-time calls hang the async load
require("love.timer")
local request_channel = love.thread.getChannel(request_channel_name)
local response_channel = love.thread.getChannel(response_channel_name)

local ok, runtime_or_err = pcall(require, "engine/graphics/rbx/runtime")
if not ok then
    response_channel:push({
        ok = false,
        error = "Failed to load RBX runtime parser in map loader thread: " .. tostring(runtime_or_err),
    })
    return
end

local runtime_backend = runtime_or_err

local function read_map_bytes(path)
    local handle, err = io.open(path, "rb")
    if not handle then
        return nil, err
    end

    local data = handle:read("*a")
    handle:close()
    if type(data) ~= "string" then
        return nil, "failed to read map bytes"
    end
    return data
end

local message = request_channel:demand()
if type(message) ~= "table" or type(message.map_path) ~= "string" or message.map_path == "" then
    response_channel:push({
        ok = false,
        error = "Async loader expected a non-empty map path",
    })
    return
end

local function time_seconds()
    return love.timer.getTime()
end

local stage_times = {}
local read_start = time_seconds()
local map_data, read_err = read_map_bytes(message.map_path)
stage_times.rbxl_file_read = math.max(0, time_seconds() - read_start)
if not map_data then
    response_channel:push({
        ok = false,
        error = string.format("Failed to read RBX map '%s': %s", tostring(message.map_path), tostring(read_err)),
    })
    return
end

-- include_instance_roots=false: thread channels reject the cyclic tree -- flattens to parts-under-workspace
-- full datamodel needs parse_on_main in load_map_async
local parsed_ok, parsed_or_err = pcall(runtime_backend._parse_map_data, message.map_path, map_data, {
    include_instance_roots = false,
    load_stage_times = stage_times,
    skip_workspace_subtrees = message.skip_workspace_subtrees,
})
if not parsed_ok then
    response_channel:push({
        ok = false,
        error = tostring(parsed_or_err),
    })
    return
end

response_channel:push({
    ok = parsed_or_err ~= nil,
    result = parsed_or_err,
    error = parsed_or_err and nil or "RBX map parser returned nil",
})
