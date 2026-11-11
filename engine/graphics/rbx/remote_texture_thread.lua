-- bounded Roblox texture download worker
-- Arguments: request channel, response channel, worker index, connect timeout,
-- total timeout, maximum encoded bytes.  the endpoint is fixed here on purpose:
-- a renderer asset string can never select a host or output path

-- resolve engine paths when the engine is mounted below another project
require("love.filesystem")
-- Greedy: a mount folder such as "wave-engine/" also ends in "engine/"
local engine_mount = debug.getinfo(1, "S").source:match("^@(.*)engine/")
if engine_mount and engine_mount ~= "" then
    love.filesystem.load(engine_mount .. "engine/mount.lua")()(engine_mount)
end
local ENGINE_ROOT = require("engine/root")
require("love.timer")
require("love.filesystem")

local RemoteTexture = require("engine/graphics/rbx/runtime/remote_texture")

local request_name, response_name, worker_index,
    connect_timeout, total_timeout, max_encoded_bytes = ...
local request = love.thread.getChannel(request_name)
local response = love.thread.getChannel(response_name)
local STOP_TOKEN = "__RBX_REMOTE_TEXTURE_STOP__"
local ENDPOINT_PREFIX = "https://assetdelivery.roblox.com/v1/asset/?id="
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

connect_timeout = math.max(1, math.min(15, tonumber(connect_timeout) or 4))
total_timeout = math.max(connect_timeout, math.min(60, tonumber(total_timeout) or 20))
max_encoded_bytes = math.max(1024,
    math.min(64 * 1024 * 1024, math.floor(tonumber(max_encoded_bytes) or 16 * 1024 * 1024)))
worker_index = math.max(1, math.floor(tonumber(worker_index) or 1))

local function decimal_id(value)
    value = tostring(value or "")
    if not value:match("^%d+$") then return nil end
    value = value:gsub("^0+", "")
    if value == "" or #value > 20 then return nil end
    return value
end

local function quote_argument(value)
    value = tostring(value or "")
    if IS_WINDOWS then
        return '"' .. value:gsub('"', '\\"') .. '"'
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function remove_file(path)
    if path then pcall(os.remove, path) end
end

local function read_bounded(path)
    local handle = io.open(path, "rb")
    if not handle then return nil, "temp_read_failed" end
    local size = handle:seek("end")
    if not size or size <= 0 then
        handle:close()
        return nil, "empty"
    end
    if size > max_encoded_bytes then
        handle:close()
        return nil, "encoded_too_large"
    end
    handle:seek("set", 0)
    local data = handle:read("*a")
    handle:close()
    if type(data) ~= "string" or #data ~= size then return nil, "temp_read_failed" end
    return data
end

local function fetch(job)
    local asset_id = decimal_id(job and job.asset_id)
    local attempt = math.max(1, math.floor(tonumber(job and job.attempt) or 1))
    if not asset_id then
        return { asset_id = tostring(job and job.asset_id), attempt = attempt,
            ok = false, retryable = false, error = "invalid_asset_id" }
    end

    love.filesystem.createDirectory("rbx_remote_texture_tmp")
    local save_dir = love.filesystem.getSaveDirectory():gsub("\\", "/")
    local relative = RemoteTexture.worker_temp_filename(
        asset_id, request_name, worker_index, attempt)
    local absolute = save_dir .. "/" .. relative
    remove_file(absolute)

    local null_redirect = IS_WINDOWS and " 2>NUL" or " 2>/dev/null"
    local command = table.concat({
        IS_WINDOWS and "curl.exe" or "curl",
        "--location", "--compressed", "--fail", "--silent", "--show-error",
        "--proto", quote_argument("=https"),
        "--proto-redir", quote_argument("=https"),
        "--max-redirs", "4",
        "--connect-timeout", tostring(connect_timeout),
        "--max-time", tostring(total_timeout),
        "--max-filesize", tostring(max_encoded_bytes),
        "--output", quote_argument(absolute),
        "--write-out", quote_argument("%{http_code}"),
        quote_argument(ENDPOINT_PREFIX .. asset_id),
    }, " ") .. null_redirect

    local pipe = io.popen(command, "r")
    if not pipe then
        return { asset_id = asset_id, attempt = attempt,
            ok = false, retryable = true, error = "curl_unavailable" }
    end
    local output = pipe:read("*a") or ""
    local close_ok, _, close_code = pipe:close()
    local curl_code = close_ok == true and 0 or (tonumber(close_code) or -1)
    local http_status = tonumber(output:match("(%d%d%d)%s*$")) or 0

    if curl_code ~= 0 or http_status < 200 or http_status >= 300 then
        remove_file(absolute)
        local error_code, retryable = RemoteTexture.classify_download_failure(
            http_status, curl_code)
        return { asset_id = asset_id, attempt = attempt, ok = false,
            retryable = retryable, error = error_code }
    end
    local data, read_error = read_bounded(absolute)
    remove_file(absolute)
    if not data then
        return { asset_id = asset_id, attempt = attempt, ok = false,
            retryable = read_error ~= "encoded_too_large", error = read_error }
    end
    return { asset_id = asset_id, attempt = attempt, ok = true,
        data = data, encoded_bytes = #data }
end

while true do
    local job = request:demand()
    if job == STOP_TOKEN then break end
    response:push(fetch(job))
end
