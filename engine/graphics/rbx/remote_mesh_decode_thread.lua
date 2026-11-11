-- generic remote-mesh decode worker
--
-- the renderer supplies a require-able decoder module and method.  keeping that
-- dependency explicit prevents this worker from loading the renderer or a
-- second mesh parser.  Jobs carry only a cache path (normally) plus immutable
-- variant/generation tokens, results echo those tokens for stale rejection

-- resolve engine paths when the engine is mounted below another project
require("love.filesystem")
-- Greedy: a mount folder such as "wave-engine/" also ends in "engine/"
local engine_mount = debug.getinfo(1, "S").source:match("^@(.*)engine/")
if engine_mount and engine_mount ~= "" then
    love.filesystem.load(engine_mount .. "engine/mount.lua")()(engine_mount)
end
local ENGINE_ROOT = require("engine/root")
require("love.filesystem")

local request_name, response_name, worker_index,
    decoder_module, decoder_method, max_encoded_bytes = ...
local request = love.thread.getChannel(request_name)
local response = love.thread.getChannel(response_name)
local STOP_TOKEN = "__RBX_REMOTE_MESH_DECODE_STOP__"

worker_index = math.max(1, math.floor(tonumber(worker_index) or 1))
decoder_method = tostring(decoder_method or "decode_remote_mesh")
max_encoded_bytes = math.max(1024,
    math.min(64 * 1024 * 1024,
        math.floor(tonumber(max_encoded_bytes) or 32 * 1024 * 1024)))

local decoder = nil
local decoder_error = nil
do
    local ok, module = pcall(require, tostring(decoder_module or ""))
    if not ok then
        decoder_error = "decoder_module_error:" .. tostring(module)
    elseif type(module) == "function" then
        decoder = module
    elseif type(module) == "table" and type(module[decoder_method]) == "function" then
        decoder = module[decoder_method]
    else
        decoder_error = "decoder_method_unavailable"
    end
end

local function failure(job, reason, retryable)
    return {
        variant_key = job and job.variant_key,
        generation = job and job.generation,
        source_revision = job and job.source_revision,
        manager_epoch = job and job.manager_epoch,
        attempt = job and job.attempt,
        worker_index = worker_index,
        ok = false,
        error = tostring(reason or "decode_failed"),
        retryable = retryable == true,
    }
end

local function read_source(job)
    if type(job.data) == "string" then
        if job.data == "" then return nil, "source_payload_missing", true end
        if #job.data > max_encoded_bytes then
            return nil, "encoded_too_large", false
        end
        return job.data
    end
    if type(job.cache_path) ~= "string" or job.cache_path == "" then
        return nil, "source_payload_missing", true
    end
    local info = love.filesystem.getInfo(job.cache_path, "file")
    local size = type(info) == "table" and tonumber(info.size) or nil
    if not size or size <= 0 then return nil, "source_read_failed", true end
    if size > max_encoded_bytes then return nil, "encoded_too_large", false end
    local data = love.filesystem.read(job.cache_path)
    if type(data) ~= "string" or #data ~= size then
        return nil, "source_read_failed", true
    end
    return data
end

local function decode(job)
    if type(job) ~= "table" then return failure(nil, "invalid_job", false) end
    if not decoder then return failure(job, decoder_error, false) end
    local data, read_error, retryable = read_source(job)
    if not data then return failure(job, read_error, retryable) end
    local ok, decoded, reason, decode_retryable = pcall(decoder, data, job)
    if not ok then
        return failure(job, "decoder_error:" .. tostring(decoded), false)
    end
    if decoded == nil then return failure(job, reason, decode_retryable) end
    return {
        variant_key = job.variant_key,
        generation = job.generation,
        source_revision = job.source_revision,
        manager_epoch = job.manager_epoch,
        attempt = job.attempt,
        worker_index = worker_index,
        ok = true,
        decoded = decoded,
    }
end

while true do
    local job = request:demand()
    if job == STOP_TOKEN then break end
    local result = decode(job)
    local ok = pcall(response.push, response, result)
    if not ok then
        -- a decoder returned a channel-incompatible object.  publish a small
        -- diagnostic result instead of terminating the worker silently
        pcall(response.push, response,
            failure(job, "decoded_result_not_transferable", false))
    end
end
