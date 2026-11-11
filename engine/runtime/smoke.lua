-- run a project for a fixed number of frames and exit, for scripted checks
-- such as CI. set WAVE_SMOKE_FRAMES=<n> before starting LÖVE; an error at any
-- point prints a traceback and exits with status 1 instead of showing the
-- interactive error screen
local Smoke = {}

---wrap the current love.run so it stops after `frames` frames
---@param frames number
function Smoke.install(frames)
    frames = math.max(1, math.floor(tonumber(frames) or 1))
    local run = assert(love.run, "start the project before installing the smoke runner")

    function love.errorhandler(message)
        io.stderr:write("wave smoke: ", debug.traceback(tostring(message), 2), "\n")
        io.stderr:flush()
        os.exit(1)
    end

    function love.run()
        local step = run()
        local count = 0
        return function()
            local result = step()
            if result ~= nil then return result end
            count = count + 1
            if count >= frames then
                print(("wave smoke: %d frames completed"):format(count))
                return 0
            end
        end
    end
end

---install the runner when WAVE_SMOKE_FRAMES is set, otherwise do nothing
function Smoke.from_environment()
    local frames = os.getenv("WAVE_SMOKE_FRAMES")
    if frames and frames ~= "" then Smoke.install(frames) end
end

return Smoke
