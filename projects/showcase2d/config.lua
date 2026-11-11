-- conf.lua reads this table before LÖVE starts
-- choose "game", "fonts", "markup" or "editor" and restart to switch examples
local demo = "game"

return {
    id = "showcase2d",
    title = "2d showcase",
    identity = "showcase2d",
    demo = demo,
    use_ui_editor = demo == "editor",

    window = {
        width = 1280,
        height = 720,
        minwidth = 480,
        minheight = 320,
        resizable = true,
        depth = 24,
        stencil = 8,
        highdpi = true,
        usedpiscale = true,
        vsync = 1,
    },

    -- Defaults for engine settings. a player's saved settings.cfg overwrites
    settings = {
        fps = false,
        vsync = true,
        resolution = "1280x720",
        musicvol = 5,
        sfxvol = 6,
        rumble = 65,
    },

    -- Settings owned by this project, saved next to the engine settings
    custom_settings = {
        showcase_screen_shake = { default = true, title = "Screen Shake" },
        showcase_enemy_speed = { default = 1.0, min = 0.5, max = 2.0, decimal = true, title = "Enemy Speed" },
    },

    -- WASD, the d-pad and the left stick move. the arrow keys aim and fire,
    -- like the right stick, so they are left out of the movement actions
    actions = {
        up = { title = "Up", keyboard = "w", joy = "dpup" },
        down = { title = "Down", keyboard = "s", joy = "dpdown" },
        left = { title = "Left", keyboard = "a", joy = "dpleft" },
        right = { title = "Right", keyboard = "d", joy = "dpright" },
    },

    gammacorrect = true,
    background_color = { 0.075, 0.082, 0.102, 1 },
    --[[
    splash = {
        duration = 1.0,
        hold = 0.4,
    },
 ]]
    preferred_orientation = "landscape",

    services = {
        shake = true,
    },

    assets = {
        font_roots = { "projects/showcase2d/assets/fonts" },
        default_font = "Scrambled_Eggs_Bold.ttf",
        -- optional local music/SFX folders (music/, sfx/), see the README
        audio = "projects/showcase2d/assets/audio",
    },
}
