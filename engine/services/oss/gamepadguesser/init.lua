-- GamepadGuesser
--
-- Guess the platform of your lua Joysticks from their names.
--
-- https://github.com/idbrii/love-gamepadguesser
--
-- Copyright © 2022 idbrii.
-- Released under the MIT License.


local gamepadguesser = {}

gamepadguesser.CONSOLES = {
    "nintendo",
    "playstation",
    "xbox",
}

local all_patterns = {
    playstation = {
        "%f[%w]PS%d%f[%D]", "Sony%f[%W]", "Play[Ss]tation",
    },
    nintendo = {
        "Wii%f[%L]", "%f[%u]S?NES%f[%U]", "%f[%l]s?nes%f[%L]", "%f[%u]Switch%f[%L]", "Joy[- ]Cons?%f[%L]",
    },
    -- Our art doesn't have sega and I don't have a sega gamepad to test with,
    -- so don't include it.
    --~ sega = {
    --~     -- Be very cautious since sega gamepads are rare.
    --~     "%f[%a]Sega%f[%W]",
    --~ },
}

local function getNameFromMapping(mapping)
    return mapping:match("^%x*,(.-),")
end

function gamepadguesser.test_printAllGuesses(db_fpath)
    local f = io.open(db_fpath, "r")
    for line in f:lines() do
        if line:match('^%x') then
            local name = getNameFromMapping(line)
            assert(name, line)
            local console = gamepadguesser.joystickNameToConsole(name)
            if name then
                print(console, '<-', name)
            end
        end
    end
    f:close()
end

-- Load gamepad db to get support for more gamepads.
--
-- Call from love.load.
function gamepadguesser.loadMappings(path_to_gamepadguesser)
    local fpath = path_to_gamepadguesser .. "/assets/db/gamecontrollerdb.txt"
    love.joystick.loadGamepadMappings(fpath)
end

-- Map a joystick name (e.g., from gamecontrollerdb) to a console.
function gamepadguesser.joystickNameToConsole(name)
    for console, patterns in pairs(all_patterns) do
        for _, pat in ipairs(patterns) do
            if name:match(pat) then
                return console
            end
        end
    end
    -- Xbox button layout is ubiquitous
    return "xbox"
end

-- Get a specific name for a gamepad.
--
-- Generally more descriptive than Joystick:getName because we use the
-- community-provided name instead of the driver name.
function gamepadguesser.getJoystickName(joystick)
    local name
    local mapping = joystick:getGamepadMappingString()
    -- lovejs doesn't support mapping strings.
    if mapping then
        name = getNameFromMapping(mapping)
    end
    if not name or name:len() < 3 then
        name = joystick:getName()
    end
    return name
end

-- Map a love2d Joystick to a console.
--
-- Returns:
--  One value from gamepadguesser.CONSOLES.
function gamepadguesser.joystickToConsole(joystick)
    local name = gamepadguesser.getJoystickName(joystick)
    return gamepadguesser.joystickNameToConsole(name)
end

local function Class()
    local cls = {}
    cls.__index = cls
    setmetatable(cls, {
        __call = function(cls_, ...)
            local obj = setmetatable({}, cls)
            obj:ctor(...)
            return obj
        end
    })
    return cls
end
local JoystickData = Class()

function JoystickData:ctor()
    self.joysticks = {}
end

function JoystickData:addJoystick(joystick)
    if not self.joysticks[joystick] then
        self.joysticks[joystick] = gamepadguesser.joystickToConsole(joystick)
    end
end

-- Force input joystick to return a specific console instead of autodetecting.
-- Useful to allow users to customize their button prompts when gamepads are
-- incorrectly configured.
--
-- console: should be an element in gamepadguesser.CONSOLES or nil. Resumes
--      autodetection if console is nil.
function JoystickData:overrideConsole(joystick, console)
    self.joysticks[joystick] = console
    self:addJoystick(joystick)
end

function gamepadguesser.createJoystickData(path_to_gamepadguesser, skip_loading_db)
    if not skip_loading_db then
        gamepadguesser.loadMappings(path_to_gamepadguesser)
    end
    return JoystickData(path_to_gamepadguesser)
end

return gamepadguesser
