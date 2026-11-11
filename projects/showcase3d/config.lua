-- loaded by conf.lua before LÖVE modules start: keep this a plain table
return {
    id = "showcase3d",
    title = "wave-engine robot64 port",
    identity = "wave-engine-showcase3d",

    window = {
        width = 1280,
        height = 720,
        minwidth = 640,
        minheight = 360,
        resizable = true,
        depth = 24,
        stencil = 8,
        highdpi = true,
        usedpiscale = true,
        vsync = 1,
    },

    settings = {
        fps = false,
        rate = -1,
        vsync = true,
        fullscreen = "windowed",
        resolution = "1280x720",
        reduced_motion = false,
        deadzone = 0.2,
        rumble = 65,
    },

    -- Saved per player in this project's settings.cfg
    custom_settings = {
        s3d_mouse_sensitivity = {
            title = "Mouse Sensitivity", default = 1.0, min = 0.25, max = 3.0, decimal = true,
        },
        s3d_stick_speed = {
            title = "Controller Camera Speed", default = 1.0, min = 0.4, max = 2.5, decimal = true,
        },
        s3d_invert_y = { title = "Invert Camera Y", default = false },
        s3d_show_controls = { title = "Show Controls", default = true },
        s3d_quality = {
            title = "Graphics Quality",
            default = "balanced",
            choices = { "performance", "balanced", "quality" },
        },
        s3d_show_stats = { title = "Show Stats", default = false },
        -- Developer view: collision hulls, contacts and moving bounds
        s3d_collision_debug = { title = "Collision Debug", default = false },
        s3d_still_camera = { title = "Still Camera", default = false },
    },

    -- project actions, players can rebind them (F6 opens the rebind menu)
    actions = {
        -- WASD and the left stick move. the arrow keys turn the camera, so
        -- the engine's aim actions are renamed for this project
        up = { title = "Forward", keyboard = "w" },
        down = { title = "Backward", keyboard = "s" },
        left = { title = "Left", keyboard = "a" },
        right = { title = "Right", keyboard = "d" },
        aimup = { title = "Camera Up", keyboard = "up" },
        aimdown = { title = "Camera Down", keyboard = "down" },
        aimleft = { title = "Camera Left", keyboard = "left" },
        aimright = { title = "Camera Right", keyboard = "right" },
        jump = { title = "Jump", keyboard = "space", joy = "a" },
        dive = { title = "Dive", keyboard = "e", joy = "x" },
        crouch = { title = "Crouch / Ground Pound", keyboard = { "lshift", "c" }, joy = "r2" },
        twirl = { title = "Twirl", keyboard = { "mouse1", "rshift" }, joy = "b" },
        dance = { title = "Dance", keyboard = "lctrl", joy = "dpleft" },
        snap_camera = { title = "Camera Behind", keyboard = { "q", "mouse3" }, joy = { "leftshoulder", "rightshoulder" } },
        zoom_in = { title = "Zoom In", joy = "dpup" },
        zoom_out = { title = "Zoom Out", joy = "dpdown" },
        camera_look = { title = "Rotate Camera (hold)", keyboard = "mouse2" },
        menu = { title = "Pause", keyboard = { "escape", "p" }, joy = "start" },
        accept = { title = "Accept (menus)", keyboard = "return" },
        controls_help = { title = "Show/Hide Controls", keyboard = "h", joy = "back" },
        respawn = { title = "Respawn", keyboard = "r", joy = "y" },
    },

    gammacorrect = true,
    background_color = { 0.07, 0.08, 0.1, 1 },
    --[[
    splash = {
        duration = 1.0,
        hold = 0.4,
    },
 ]]
    assets = {
        font_roots = { "projects/showcase3d/assets/fonts" },
        audio = nil,
    },
}
