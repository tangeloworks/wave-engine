--[[ platform capability layer for console targets

two very different "switch" runtimes exist:
- LovePotion (lovebrew.org): a 2d reimplementation of love. sets
  love._console ("3DS"/"Switch"/"Wii U"). no runtime shaders, no depth or
  instancing api - only 2d projects can target it
- love-nx (github.com/retronx-team/love-nx): real love 11.5 compiled for
  switch homebrew over sdl2/mesa. full graphics api, but luajit runs
  interpreter-only and love._console is nil - detected here through a
  "switch.flag" marker file shipped in the fused game directory

everything else should branch on these capability flags instead of raw
love._console checks so both runtimes are covered ]]

local platform = {}

platform.is_lovepotion = love._console ~= nil
platform.console = love._console
    or (love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo('switch.flag') and 'Switch')
    or nil

platform.is_console = platform.console ~= nil
platform.is_switch = platform.console == 'Switch'
platform.os = love.system and love.system.getOS and love.system.getOS() or 'Unknown'
platform.is_mobile = platform.os == 'iOS' or platform.os == 'Android'

-- desktop windowing (resize / fullscreen modes / desktop dimensions)
platform.has_window_modes = not platform.is_console and not platform.is_mobile

-- pointer & clipboard assume a desktop session
platform.has_mouse = not platform.is_console and not platform.is_mobile
platform.has_clipboard = not platform.is_lovepotion

-- lovepotion has no runtime shader compilation at all
platform.has_shaders = not platform.is_lovepotion
    and love.graphics ~= nil and love.graphics.newShader ~= nil

-- ffi-based networking (curl/wininet) is desktop-only, love-nx has ffi but
-- interpreter-only luajit makes it slow and the system libs are absent
platform.has_native_net = not platform.is_console and not platform.is_mobile

-- horizon forbids w^x jit pages, love-nx ships LUAJIT_DISABLE_JIT
platform.has_jit = (function()
    if not jit or not jit.status then return false end
    local enabled = jit.status()
    return enabled == true
end)()

return platform
