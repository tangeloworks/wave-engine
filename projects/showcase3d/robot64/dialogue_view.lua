-- The dialogue textbox, ported from the port's dialogue_view.lua (see
-- NOTICE.md). The source parents ReplicatedFirst/textbox in front of the
-- camera (vcf * CFrame.new(0,-3,-7)) and fills its SurfaceGui with one
-- CharacterScript/tx clone per letter; this projects that surface to the
-- screen and draws the same layout, colours, effects, name and spinner with
-- the place's own art. The scene calls draw() from its 2D overlay.
local Dialogue = require('projects/showcase3d/robot64/dialogue')
local View = {}; View.__index = View
local function hsv(h)
    local sector = h * 6; local x = 1 - math.abs(sector % 2 - 1)
    if sector < 1 then return 1, x, 0 elseif sector < 2 then return x, 1, 0
    elseif sector < 3 then return 0, 1, x elseif sector < 4 then return 0, x, 1
    elseif sector < 5 then return x, 0, 1 else return 1, 0, x end
end
function View.project(width, height, physical_size, fov)
    if not physical_size then return nil, 'Authored textbox physical Size is required for projection.' end
    local x, y, z = physical_size.X or physical_size.x or physical_size[1],
        physical_size.Y or physical_size.y or physical_size[2],physical_size.Z or physical_size.z or physical_size[3]
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' or x <= 0 or y <= 0 then return nil, 'Invalid authored textbox Size.' end
    fov = fov or 70
    if type(fov) ~= 'number' or fov <= 0 or fov >= 180 then return nil, 'Invalid dialogue projection FOV.' end
    -- Source sets textbox.CFrame = vcf * CFrame.new(0,-3,-7).
    -- SurfaceGui Face2 is the back face, at local +Size.Z/2.
    local depth = 7 - z / 2
    if depth <= 0 then return nil, 'Textbox back face is behind the view plane.' end
    local factor = height / (2 * math.tan(math.rad(fov) / 2)) / depth
    local w, h = x * factor, y * factor
    return { x = width / 2 - w / 2, y = height / 2 + 3 * factor - h / 2, width = w, height = h }
end
local function resource(self, reference)
    if self.images[reference] ~= nil then return self.images[reference] or nil end
    local path = self.assets:resolve(reference, 'texture')
    if not path then
        self.images[reference] = false
        if self.on_error then self.on_error('Missing authored dialogue image: ' .. tostring(reference)) end
        return nil
    end
    local ok, image = pcall(love.graphics.newImage, path)
    if not ok then
        self.images[reference] = false
        if self.on_error then self.on_error('Dialogue image could not be decoded: ' .. reference .. ': ' .. tostring(image)) end
        return nil
    end
    image:setFilter('linear', 'linear')
    self.images[reference] = image; return image
end
-- templates: the place's CharacterScript/tx (FontFace, TextSize),
-- CharacterScript/im (Image) and textbox/SurfaceGui/spin (Image).
function View.new(assets, dialogue, options)
    options = options or {}
    local templates = assert(options.templates, 'Dialogue templates are required')
    local text, icon, spin = templates.text, templates.icon, templates.spin
    local self = setmetatable({ assets = assets, dialogue = dialogue,
        physical_size = options.physical_size, fov = options.fov, game_time = options.game_time,
        on_error = options.on_error, text_properties = text, icon_properties = icon, spin_image = spin.Image,
        images = {}, quads = {}, characters = {}, resources = 0, layout_count = 0,
        clock = 0, accumulator = 0, presentation_step = 0, effect_cadence = options.effect_cadence or 1 / 60 }, View)
    local path, err = assets:font(text.FontFace); if not path then return nil, err end
    -- Glyphs are laid out in the surface's 900 x 280 units at TextSize; they
    -- are rasterised at the on-screen scale (`density`) and drawn scaled back.
    self.font_path, self.text_size = path, text.TextSize
    self.font = love.graphics.newFont(path, text.TextSize)
    self.density = 1
    self.draw_font = self.font
    self.random = options.random or love.math.newRandomGenerator(options.visual_seed or 194739)
    self.random_int = function(a, b) return self.random:random(a, b) end
    resource(self, 'rbxassetid://1442127057'); resource(self, 'rbxassetid://1442126894')
    resource(self, icon.Image); resource(self, self.spin_image)
    return self
end
function View:_set_density(density)
    if density == self.density then return end
    self.density = density
    for _, retained in pairs(self.characters) do retained:release() end
    self.characters, self.resources = {}, 0
    if self.draw_font ~= self.font then self.draw_font:release() end
    self.draw_font = density == 1 and self.font or love.graphics.newFont(self.font_path, math.floor(self.text_size * density + .5))
    self.draw_font:setFilter('linear', 'linear')
    if self.name_drawable then self.name_drawable:release(); self.name_drawable = nil; self.speaker_name = nil end
    if self.layout then
        for _, item in ipairs(self.layout.glyphs) do
            if item.glyph.kind == 'text' then item.drawable = self:_character(item.glyph.text) end
        end
    end
end
function View:_character(text)
    local retained = self.characters[text]
    if not retained then
        retained = love.graphics.newText(self.draw_font, text); self.characters[text] = retained
        self.resources = self.resources + 1
    end
    return retained
end
function View:_layout(parsed)
    self.parsed, self.layout = parsed, Dialogue.layout(parsed, function(c) return self.font:getWidth(c) end)
    self.layout_count = self.layout_count + 1
    self.animated, self.last_visible = {}, 0
    for _, item in ipairs(self.layout.glyphs) do
        item.effect = {}; item.born_step = self.presentation_step
        if item.glyph.kind == 'text' then
            item.drawable = self:_character(item.glyph.text)
            if item.glyph.beebo or item.glyph.wave or item.glyph.shake then self.animated[#self.animated + 1] = item end
        end
    end
    if self.resources > 512 then
        local used = {}; for _, glyph in ipairs(parsed.glyphs) do if glyph.kind == 'text' then used[glyph.text] = true end end
        for c, retained in pairs(self.characters) do
            if not used[c] then retained:release(); self.characters[c] = nil; self.resources = self.resources - 1 end
        end
    end
end
function View:_name()
    local name = self.parsed.beebo and 'Beebo' or (self.dialogue.speaker and self.dialogue.speaker.Name) or ''
    if name ~= self.speaker_name or not self.name_drawable then
        self.speaker_name = name
        if self.name_drawable then self.name_drawable:set(name)
        else self.name_drawable = love.graphics.newText(self.draw_font, name) end
    end
end
function View:update(dt)
    if self.closed then return end
    self.clock = self.clock + dt
    local active = self.dialogue.active and self.dialogue.current and self.dialogue.current.raw ~= 'SKIP'
    self.visible = active == true
    if not active then return end
    if self.dialogue.parsed ~= self.parsed then self:_layout(self.dialogue.parsed) end
    self:_name()
    local visible = self.dialogue.visible
    if visible > self.last_visible then
        for _, item in ipairs(self.layout.glyphs) do if item.index > self.last_visible and item.index <= visible then item.born_step = self.presentation_step end end
        self.last_visible = visible
    end
    self.accumulator = self.accumulator + dt
    local time = type(self.game_time) == 'function' and self.game_time() or self.clock
    -- The public visual random draws occurred per RenderStepped. They are owned
    -- by this separate 60Hz presentation stream here; cadence parity is unmeasured.
    while self.accumulator >= self.effect_cadence do
        self.accumulator = self.accumulator - self.effect_cadence; self.presentation_step = self.presentation_step + 1
        for _, item in ipairs(self.animated) do
            if item.index <= visible then Dialogue.effect(item.glyph, item.index, time,
                self.presentation_step - item.born_step, self.random_int, item.effect) end
        end
    end
end
function View:_quad(image, x, y, w, h)
    local key = tostring(image) .. ':' .. x .. ':' .. y .. ':' .. w .. ':' .. h
    if not self.quads[key] then self.quads[key] = love.graphics.newQuad(x, y, w, h, image:getDimensions()) end
    return self.quads[key]
end
function View:_sprite(reference, rect, atlas, rotation)
    local image = resource(self, reference); if not image then return end
    local w, h = image:getDimensions(); local quad
    if atlas then w, h = atlas[3], atlas[4]; quad = self:_quad(image, atlas[1], atlas[2], w, h) end
    love.graphics.setColor(1, 1, 1, 1)
    if rotation then
        if quad then love.graphics.draw(image, quad, rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, rotation, rect[3] / w, rect[4] / h, w / 2, h / 2)
        else love.graphics.draw(image, rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, rotation, rect[3] / w, rect[4] / h, w / 2, h / 2) end
    elseif quad then love.graphics.draw(image, quad, rect[1], rect[2], 0, rect[3] / w, rect[4] / h)
    else love.graphics.draw(image, rect[1], rect[2], 0, rect[3] / w, rect[4] / h) end
end
function View:draw(width, height)
    if self.closed or not self.visible or not self.dialogue.active or not self.layout then return end
    local fov = type(self.fov) == 'function' and self.fov() or self.fov
    local rect, err = View.project(width, height, self.physical_size, fov)
    if not rect then
        if err ~= self.last_projection_error then self.last_projection_error = err; if self.on_error then self.on_error(err) end end
        return
    end
    self:_set_density(math.max(1, math.min(4, math.ceil(rect.width / 900 * 2) / 2)))
    self:_name()
    local inverse = 1 / self.density
    love.graphics.push('all')
    love.graphics.translate(rect.x, rect.y); love.graphics.scale(rect.width / 900, rect.height / 280)
    self:_sprite(self.dialogue.background_asset, { 0, 50, 900, 230 }, { 0, 0, 475, 128 })
    local nx = self.parsed.beebo and 880 - self.name_drawable:getWidth() * inverse or 20
    love.graphics.setColor(0, 0, 0, 0.2); love.graphics.draw(self.name_drawable, nx, 1.12, 0, inverse, inverse)
    love.graphics.setColor(1, 1, 1, 1); love.graphics.draw(self.name_drawable, nx, 0, 0, inverse, inverse)
    local visible = self.dialogue.visible
    for _, item in ipairs(self.layout.glyphs) do
        if item.index > visible then break end
        local glyph = item.glyph
        if glyph.kind == 'icon' then self:_sprite(self.icon_properties.Image, { 20 + item.x, 80 + item.y, 50, 50 }, { glyph.icon * 32, 0, 32, 32 })
        else
            local effect = item.effect
            if effect.hue then love.graphics.setColor(hsv(effect.hue))
            elseif glyph.color == 'silent' then love.graphics.setColor(0.5, 0.5, 0.5, 1)
            elseif glyph.color == 'highlight' then love.graphics.setColor(0.2, 0.5, 1, 1)
            else love.graphics.setColor(0, 0, 0, 1) end
            love.graphics.draw(item.drawable, 20 + item.x + (effect.x or 0), 80 + item.y + (effect.y or 0), math.rad(effect.rotation or 0), inverse, inverse)
        end
    end
    if self.dialogue.status == 'awaiting' then self:_sprite(self.spin_image,
        { 830, 220, 35, 36 }, nil, math.rad((type(self.game_time) == 'function' and self.game_time() or self.clock) * 80)) end
    love.graphics.pop()
end
function View:destroy()
    if self.closed then return end; self.closed = true
    if self.name_drawable then self.name_drawable:release() end
    for _, text in pairs(self.characters) do text:release() end
    for _, quad in pairs(self.quads) do quad:release() end
    for _, image in pairs(self.images) do if image then image:release() end end
    if self.draw_font ~= self.font then self.draw_font:release() end
    self.font:release()
    self.layout, self.parsed, self.characters, self.quads, self.images = nil, nil, {}, {}, {}
end
return View
