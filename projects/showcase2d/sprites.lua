-- each sheet is one row of square frames, with the same pivot across poses
local Sprites = {}
Sprites.__index = Sprites

-- ink across the nine player frames spans x 19..99 and y 6..123 in a 128 px cell
-- share one pivot and footprint so changing poses or facing never shifts the hitbox
local player_width = 1.04
local tile_per_pixel = player_width / 128
Sprites.player_box = { half_width = 40 * tile_per_pixel, half_height = 58.5 * tile_per_pixel }

local function load_sheet(path, frame_count)
    local image = love.graphics.newImage("projects/showcase2d/assets/img/" .. path)
    local width, frame_size = image:getDimensions()
    assert(width == frame_size * frame_count, "unexpected sprite sheet dimensions: " .. path)
    image:setFilter("linear", "linear")
    local frames = {}
    for index = 1, frame_count do
        frames[index] = love.graphics.newQuad((index - 1) * frame_size, 0, frame_size, frame_size, width, frame_size)
    end
    return { image = image, frames = frames, size = frame_size }
end

function Sprites.load()
    return setmetatable({
        block = load_sheet("block.png", 1),
        idle = load_sheet("player/idle.png", 3),
        walk = { load_sheet("player/walkpose1.png", 3), load_sheet("player/walkpose2.png", 3) },
        spider = load_sheet("spider.png", 4),
        bullet = load_sheet("player/bullet.png", 7),
    }, Sprites)
end

local function draw(sheet, frame, x, y, width, face_left, pivot_x, pivot_y)
    local scale = width / sheet.size
    love.graphics.draw(sheet.image, sheet.frames[frame], x, y, 0, face_left and -scale or scale, scale,
        sheet.size * (pivot_x or 0.5), sheet.size * (pivot_y or 0.5))
end

function Sprites:draw_block(x, y)
    draw(self.block, 1, x + 0.5, y + 0.5, 1)
end

function Sprites:draw_player(player)
    local tick = math.floor(player.anim_time * (player.moving and 14 or 7))
    local sheet = self.idle
    if player.moving then sheet = self.walk[1 + math.floor(tick / 3) % 2] end
    draw(sheet, 1 + tick % 3, player.x, player.y, player_width, player.face_left, 59 / 128, 64.5 / 128)
end

function Sprites:draw_spider(enemy)
    local tick = math.floor(enemy.anim_time * (enemy.moving and 12 or 6))
    local frame = 1 + tick % (enemy.moving and 4 or 2)
    draw(self.spider, frame, enemy.x, enemy.y, 0.94, enemy.face_left, 0.5, 0.62)
end

function Sprites:draw_bullet(bullet)
    draw(self.bullet, 1 + math.floor(bullet.age * 16) % 3, bullet.x, bullet.y, 0.35)
end

-- impacts stay at the collision point while the last four frames play once
Sprites.pop_duration = 0.25
function Sprites:draw_impact(impact)
    local frame = 4 + math.min(3, math.floor(impact.age * 4 / self.pop_duration))
    draw(self.bullet, frame, impact.x, impact.y, 0.48)
end

return Sprites
