-- load the local Robot 64 Engine place with the RBX renderer and physics
-- the robot64 folder holds the scene; credits are in robot64/NOTICE.md
local project = require("projects/showcase3d/config")

function project.start(program)
    local Robot = require("projects/showcase3d/robot64")
    require("projects/showcase3d/shell").run(project, program, Robot)
end

return project
