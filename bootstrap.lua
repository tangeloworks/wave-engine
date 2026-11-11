-- load wave-engine when this repository is a subfolder of another LÖVE
-- project, for example a Git submodule at vendor/wave-engine:
--
--     local wave = require("vendor/wave-engine/bootstrap")
--
-- the slash-style module name matches the engine's own module convention
local module_name = ... or "bootstrap"
local mount = (module_name:match("^(.*)/bootstrap$") or ""):gsub("\\", "/"):gsub("/+", "/")
if mount ~= "" then
    assert(love.filesystem.load(mount .. "/engine/mount.lua"))()(mount .. "/")
end

return require("engine")
