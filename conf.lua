-- RBX_TEST=1 runs the engine regression suites headless; RBX_TEST=graphics
-- also runs suites that need a window. see engine/graphics/rbx/tests/README.md
local test_mode = os.getenv("RBX_TEST")
if test_mode and test_mode ~= "" then
    _G.WAVE_TEST_MODE = test_mode
    function love.conf(t)
        t.version = "11.5"
        t.identity = "wave-engine-tests"
        t.console = false
        t.modules.audio = false
        t.modules.sound = false
        t.modules.joystick = false
        if test_mode ~= "graphics" then
            t.window = nil
            t.modules.window = false
            t.modules.graphics = false
        else
            t.window.title = "wave-engine tests"
            t.window.depth = 24
            t.window.stencil = 8
        end
    end
    return
end

-- pick a project by folder name here
-- if it is missing, the launcher picks the first available project in alphabetical order
local selected_project = "showcase2d"

local function project_config_path(name)
    return "projects/" .. name .. "/config.lua"
end

local function project_exists(name)
    if type(name) ~= "string" or not name:match("^[%w_-]+$") then
        return false
    end

    local path = project_config_path(name)
    if not love.filesystem.getInfo(path, "file") then
        return false
    end
    return love.filesystem.getRealDirectory(path) ~= love.filesystem.getSaveDirectory()
end

local function first_project()
    local names = love.filesystem.getDirectoryItems("projects") or {}
    table.sort(names)
    for _, name in ipairs(names) do
        if project_exists(name) then
            return name
        end
    end
end

if not project_exists(selected_project) then
    selected_project = assert(first_project(),
        "No project with a source-owned config.lua was found in projects/")
end

_G.WAVE_PROJECT_NAME = selected_project

local project = require("projects/" .. selected_project .. "/config")
assert(type(project) == "table", "project configuration must return a table")

function love.conf(t)
    local window = project.window or {}
    local assets = project.assets or {}
    local engine_icon = "engine/assets/img/iconimg.png"

    t.version = "11.5"
    t.console = false
    t.identity = project.identity or selected_project
    t.externalstorage = false
    t.gammacorrect = project.gammacorrect ~= false
    t.audio.mic = false

    t.window.title = project.title or selected_project
    -- every project can provide its own icon, while the engine asset pack
    -- supplies a real default instead of leaving platform packaging iconless
    t.window.icon = assets.icon
        or (love.filesystem.getInfo(engine_icon, "file") and engine_icon or nil)
    t.window.width = window.width or 960
    t.window.height = window.height or 600
    t.window.minwidth = window.minwidth or 1
    t.window.minheight = window.minheight or 1
    t.window.resizable = window.resizable ~= false
    t.window.depth = window.depth or 24
    t.window.stencil = window.stencil or 8
    t.window.msaa = window.msaa or 0
    t.window.highdpi = window.highdpi == true
    t.window.usedpiscale = window.usedpiscale ~= false
    t.window.vsync = window.vsync == nil and 1 or window.vsync
end
