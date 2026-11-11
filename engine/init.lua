-- public entry points for starting a project through the LÖVE launcher

-- the engine is large. With LuaJIT's default limits (1000 traces, 512 KB of
-- machine code) a 3D scene fills the trace cache and LuaJIT flushes it about
-- once a second, every flush runs the game interpreted until it recompiles,
-- which shows up as a burst of slow frames
if type(jit) == "table" and jit.status() then
    require("jit.opt").start("maxtrace=8000", "maxrecord=8000", "maxmcode=16384", "sizemcode=128")
end

local Launcher = require("engine/runtime/launcher")
local Assets = require("engine/assets")

local wave = {
    _VERSION = "0.1.0",
    assets = Assets,
    compat = require("engine/compat"),
}

---Boot a project-owned descriptor as the full compatibility runtime
---@param project table
---@return Program
function wave.run(project)
    return Launcher.run(project)
end

---Boot the selected local workspace project
---@param project_name string
---@return Program
function wave.start(project_name)
    return Launcher.start(project_name)
end

return wave
