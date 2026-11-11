if rawget(_G, "WAVE_TEST_MODE") then
    return require("engine/graphics/rbx/tests/run")
end

-- conf.lua picks the project before LÖVE loads this entry point
local project_name = assert(rawget(_G, "WAVE_PROJECT_NAME"),
    "conf.lua must select a project before main.lua runs")

local program = require("engine").start(project_name)
require("engine/runtime/smoke").from_environment()
return program
