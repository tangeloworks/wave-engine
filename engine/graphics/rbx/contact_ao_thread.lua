-- one-shot contact-AO worker. the immutable float64 bounds packet is shared by
-- all workers, this thread owns only its partial result packet
-- resolve engine paths when the engine is mounted below another project
require("love.filesystem")
-- Greedy: a mount folder such as "wave-engine/" also ends in "engine/"
local engine_mount = debug.getinfo(1, "S").source:match("^@(.*)engine/")
if engine_mount and engine_mount ~= "" then
    love.filesystem.load(engine_mount .. "engine/mount.lua")()(engine_mount)
end
local ENGINE_ROOT = require("engine/root")
local response_channel_name, cancel_channel_name, input_data,
    worker_index, worker_count, generation, max_parts,
    max_input_bytes, max_output_bytes, max_grid_references,
    max_pair_evals, max_abs_cell_coordinate = ...

require("love.data")
require("love.thread")
require("love.timer")

local module_chunk, module_error = love.filesystem.load(
    ENGINE_ROOT .. "/graphics/rbx/runtime/contact_ao.lua")
if not module_chunk then error(module_error) end
local ContactAO = module_chunk()

local response = love.thread.getChannel(response_channel_name)
local cancel_channel = love.thread.getChannel(cancel_channel_name)

local function cancelled()
    return cancel_channel:peek() == generation
end

local compute_started = love.timer.getTime()
local ok, packet, compute_error = pcall(ContactAO.compute_packed,
    input_data, worker_index, worker_count, {
        generation = generation,
        max_parts = max_parts,
        max_input_bytes = max_input_bytes,
        max_output_bytes = max_output_bytes,
        max_grid_references = max_grid_references,
        max_pair_evals = max_pair_evals,
        max_abs_cell_coordinate = max_abs_cell_coordinate,
        is_cancelled = cancelled,
    })
local compute_ms = (love.timer.getTime() - compute_started) * 1000

if ok and packet and not cancelled() then
    packet.stats.worker_compute_ms = compute_ms
    response:push({
        ok = true,
        generation = generation,
        worker_index = worker_index,
        data = packet.data,
        stats = packet.stats,
    })
else
    if ok and packet and packet.data then
        ContactAO.safe_release(packet.data)
    end
    local failure = cancelled() and "cancelled"
        or (ok and tostring(compute_error) or tostring(packet))
    if ContactAO.is_work_cap_error(failure)
        and cancel_channel:peek() ~= generation then
        cancel_channel:push(generation)
    end
    response:push({
        ok = false,
        generation = generation,
        worker_index = worker_index,
        error = failure,
    })
end
