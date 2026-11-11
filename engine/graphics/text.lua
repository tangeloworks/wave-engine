-- simple labels can use a single LÖVE Text object
-- styled or animated text keeps a layout record for each glyph
local utf8 = require("utf8")
local ArabicText = nil
do
    local ok, mod = pcall(require, "engine/services/arabic_text")
    if ok then ArabicText = mod end
end

local DEFAULT_FONT_SIZE = 20
local MARKUP_PATTERN = "<([^>]+)>"
local DEFAULT_LINE_HEIGHT = 1.2
local DEFAULT_OUTLINE_THICKNESS = 0
local ITALIC_ANGLE_FACTOR = 14

local NAMED_COLORS = {
    red = { 1, 0, 0, 1 },
    green = { 0, 1, 0, 1 },
    blue = { 0, 0, 1, 1 },
    white = { 1, 1, 1, 1 },
    black = { 0, 0, 0, 1 },
    yellow = { 1, 1, 0, 1 },
    orange = { 1, 0.5, 0, 1 },
    cyan = { 0, 1, 1, 1 },
    magenta = { 1, 0, 1, 1 }
}

local BOLD_OFFSETS = {
    [1] = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    [2] = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 } },
    [3] = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 2, 0 }, { 0, 2 } },
    [4] = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 2, 0 }, { 0, 2 }, { -2, 0 }, { 0, -2 }, { 2, 1 }, { 1, 2 } }
}

local DEFAULT_SHADERS = {
    wave = [[
        extern number time;
        extern number amplitude;
        extern number frequency;
        extern number phase;

        vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
            vec2 wave_offset = vec2(
                sin(time * frequency + screen_coords.y * phase) * amplitude,
                cos(time * frequency + screen_coords.x * phase) * amplitude
            );
            vec2 distorted_coords = texture_coords + wave_offset * 0.01;
            return Texel(tex, distorted_coords) * color;
        }
    ]],

    glitch = [[
        extern number time;
        extern number intensity;
        extern number blockSize;

        vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
            vec2 block_pos = floor(screen_coords / vec2(blockSize, blockSize)) * vec2(blockSize, blockSize);
            float noise = fract(sin(dot(block_pos, vec2(12.9898, 78.233)) + time * 10.0) * 43758.5453);

            if (noise > 1.0 - intensity) {
                float offset = (noise - 0.5) * 0.1;
                vec2 glitch_coords = texture_coords + vec2(offset, 0);
                vec4 glitch_color = Texel(tex, glitch_coords);
                return mix(Texel(tex, texture_coords), glitch_color, intensity) * color;
            }

            return Texel(tex, texture_coords) * color;
        }
    ]],

    distort = [[
        extern number time;
        extern number radius;
        extern number strength;

        vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
            vec2 center = vec2(0.5, 0.5);
            vec2 centered = texture_coords - center;
            float distance = length(centered);

            if (distance < radius * 0.01) {
                float factor = 1.0 - (distance / (radius * 0.01));
                vec2 distortion = centered * sin(time * 5.0 + distance * 10.0) * strength * factor * 0.1;
                vec2 distorted_coords = texture_coords + distortion;
                return Texel(tex, distorted_coords) * color;
            }

            return Texel(tex, texture_coords) * color;
        }
    ]],

    chromatic = [[
        extern number time;
        extern number intensity;

        vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
            vec2 offset = vec2(1.0, 0.0) * intensity * sin(time * 2.0) * 0.01;

            float r = Texel(tex, texture_coords + offset).r;
            float g = Texel(tex, texture_coords).g;
            float b = Texel(tex, texture_coords - offset).b;
            float a = Texel(tex, texture_coords).a;

            return vec4(r, g, b, a) * color;
        }
    ]]
}

local shaderCache = {}
local shader_roots = {}

--[[ the process-wide font caches (font objects, fallback sets, per-font info,
fallback chains) and the render-profile policy live in the font manager now;
Text:obtainFont delegates there. key shapes are unchanged ]]
local FontManager = require("engine/graphics/font_manager")
local Surface = require("engine/graphics/surface")
local GLOBAL_GLYPH_FONT_CACHE = setmetatable({}, { __mode = "k" })
local TEXT_REBUILD_BUDGET_SECONDS = 0.0025
local TEXT_REBUILD_MAX_PER_FRAME = 2
local TEXT_REBUILD_FRAME = -1
local TEXT_REBUILD_TIME = 0
local TEXT_REBUILD_COUNT = 0
local TEXT_FONT_LOAD_BUDGET_SECONDS = 0.0012
local TEXT_FONT_LOAD_MAX_PER_FRAME = 2
local TEXT_FONT_LOAD_FRAME = -1
local TEXT_FONT_LOAD_TIME = 0
local TEXT_FONT_LOAD_COUNT = 0
local _setTextureClamp

local TEXT_CONTENT_KEYS = {
    text = true,
    fontSize = true,
    font = true,
    fontPath = true,
    textAlignX = true,
    textAlignY = true,
    textScaled = true,
    textFits = true,
    clayWrap = true,
    clayPadding = true,
    textScale = true,
    lineHeight = true,
    letterSpacing = true,
    wrapMode = true,
    maxWidth = true,
    textColor = true,
    fastText = true,
    richText = true,
    excerpt = true,
    scaleQuantize = true,
    scaleBakeThreshold = true,
    outlineColor = true,
    outlineThickness = true,
    italic = true,
    bold = true,
    weight = true,
    stretchX = true,
    stretchY = true,
    pixelFont = true
}

local TEXT_FAST_OBJECT_KEYS = {
    text = true,
    font = true,
    fontPath = true,
    fontSize = true,
    pixelFont = true
}

local function _text_new_canvas(w, h, ...)
    return Element._new_canvas(w, h, ...)
end

local FONT_FALLBACK_ARABIC = FontManager.FALLBACK_ARABIC
local FONT_FALLBACK_BROAD = FontManager.FALLBACK_BROAD

local function _font_file_exists(path)
    return type(path) == "string" and love.filesystem.getInfo(path, "file") ~= nil
end

local function _print_char_fill_base(self, char, style)
    if style.bold and style.boldOffsets and #style.boldOffsets > 0 then
        for _, boldOffset in ipairs(style.boldOffsets) do
            self:_printRaster(char, math.floor(boldOffset[1] + 0.5), math.floor(boldOffset[2] + 0.5))
        end
    else
        self:_printRaster(char, 0, 0)
    end
end

local function _print_char_fill_scaled(self, char, style, rs)
    if style.bold and style.boldOffsets and #style.boldOffsets > 0 then
        for _, boldOffset in ipairs(style.boldOffsets) do
            local bx = math.floor(boldOffset[1] + 0.5)
            local by = math.floor(boldOffset[2] + 0.5)
            self:_printRaster(char, bx, by)
        end
    else
        self:_printRaster(char, 0, 0)
    end
end

local function _looks_like_pixel_font(path)
    return FontManager.looks_like_pixel_font(path)
end

local function _reset_text_rebuild_budget_if_needed()
    local frame = G.frame_id or 0
    if frame ~= TEXT_REBUILD_FRAME then
        TEXT_REBUILD_FRAME = frame
        TEXT_REBUILD_TIME = 0
        TEXT_REBUILD_COUNT = 0
    end
end

local function _can_spend_text_rebuild_budget(is_first_build)
    _reset_text_rebuild_budget_if_needed()
    if is_first_build and TEXT_REBUILD_COUNT == 0 then
        return true
    end
    if TEXT_REBUILD_COUNT >= TEXT_REBUILD_MAX_PER_FRAME then
        return false
    end
    if TEXT_REBUILD_TIME >= TEXT_REBUILD_BUDGET_SECONDS then
        return false
    end
    return true
end

local function _spend_text_rebuild_budget(duration)
    _reset_text_rebuild_budget_if_needed()
    TEXT_REBUILD_COUNT = TEXT_REBUILD_COUNT + 1
    TEXT_REBUILD_TIME = TEXT_REBUILD_TIME + (duration or 0)
end

local function _reset_font_load_budget_if_needed()
    local frame = G.frame_id or 0
    if frame ~= TEXT_FONT_LOAD_FRAME then
        TEXT_FONT_LOAD_FRAME = frame
        TEXT_FONT_LOAD_TIME = 0
        TEXT_FONT_LOAD_COUNT = 0
    end
end

local ARABIC_DETECT_CACHE = {}
local ARABIC_DETECT_COUNT = 0
local ARABIC_SHAPE_CACHE = {}
local ARABIC_SHAPE_COUNT = 0

--[[ static text canvases are rendered with alpha blending onto transparent, so
their content is PREMULTIPLIED, compositing them with plain alphamultiply
re-multiplies edge alpha = dark fringes on every antialiased glyph edge (the
dynamic-atlas path already composites premultiplied) ]]
local function _draw_static_canvas(canvas, x, y, opacity, quad)
    local a = opacity or 1
    local bm, am = love.graphics.getBlendMode()
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(a, a, a, a)
    if quad then
        love.graphics.draw(canvas, quad, x, y)
    else
        love.graphics.draw(canvas, x, y)
    end
    love.graphics.setBlendMode(bm, am)
    love.graphics.setColor(1, 1, 1, a)
end

local function _can_spend_font_load_budget()
    _reset_font_load_budget_if_needed()
    if TEXT_FONT_LOAD_COUNT >= TEXT_FONT_LOAD_MAX_PER_FRAME then
        return false
    end
    if TEXT_FONT_LOAD_TIME >= TEXT_FONT_LOAD_BUDGET_SECONDS then
        return false
    end
    return true
end

local function _spend_font_load_budget(duration)
    _reset_font_load_budget_if_needed()
    TEXT_FONT_LOAD_COUNT = TEXT_FONT_LOAD_COUNT + 1
    TEXT_FONT_LOAD_TIME = TEXT_FONT_LOAD_TIME + (duration or 0)
end

-- LÖVE scissors take logical target units, including on the framebuffer
local function _setScissorPixels(x, y, w, h)
    local sx, sy, sw, sh = Surface.scissor(x, y, w, h)
    love.graphics.intersectScissor(sx, sy, sw, sh)
end

_setTextureClamp = function(tex)
    if not tex or not tex.setWrap then return end
    local ok = pcall(tex.setWrap, tex, "clampzero", "clampzero")
    if not ok then
        tex:setWrap("clamp", "clamp")
    end
end

local function getShader(shaderCode)
    if shaderCache[shaderCode] then
        return shaderCache[shaderCode]
    end

    local success, shader = pcall(love.graphics.newShader, shaderCode)
    if success then
        shaderCache[shaderCode] = shader
        return shader
    end

    return nil
end

local function parseBackdrop(value)
    local parts = {}
    for part in value:gmatch("([^,]+)") do
        table.insert(parts, part)
    end

    local result = {
        color = { 0, 0, 0, 0.5 },
        offset = { 2, 2 },
        blur = 0
    }

    if parts[1] then
        result.color = NAMED_COLORS[parts[1]] or result.color
        if parts[1]:match("^#%x+$") then
            local hex = parts[1]:sub(2)
            local r = tonumber(hex:sub(1, 2), 16) / 255
            local g = tonumber(hex:sub(3, 4), 16) / 255
            local b = tonumber(hex:sub(5, 6), 16) / 255
            local a = (#hex >= 8) and (tonumber(hex:sub(7, 8), 16) / 255) or 0.5
            result.color = { r, g, b, a }
        elseif parts[1]:match("^%d") then
            local r, g, b, a = parts[1]:match("(%d*%.?%d+):(%d*%.?%d+):(%d*%.?%d+):?(%d*%.?%d*)")
            if r and g and b then
                result.color = {
                    tonumber(r) or 0,
                    tonumber(g) or 0,
                    tonumber(b) or 0,
                    tonumber(a) or 0.5
                }
            end
        end
    end

    if parts[2] and parts[3] then
        result.offset = { tonumber(parts[2]) or 2, tonumber(parts[3]) or 2 }
    elseif parts[2] then
        local offset = tonumber(parts[2]) or 2
        result.offset = { offset, offset }
    end

    if parts[4] or (#parts >= 4 and parts[4]) then
        result.blur = tonumber(parts[4]) or 0
    end

    return result
end

---@class Text: Element
---@overload fun(args?: TextArgs): Text
---@type Text
Text = Element:extend()

local function normalize_shader_root(path)
    assert(type(path) == "string" and path ~= "", "shader asset root must be a non-empty virtual path")
    path = path:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
    assert(not path:match("^/") and not path:match("^%a:[/]"),
        "shader asset root must be a LÖVE virtual path")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "..", "shader asset root must not escape its project")
    end
    return path
end

---set ordered, project-owned roots for custom rich-text shader files
function Text.set_shader_roots(roots)
    assert(type(roots) == "table", "shader asset roots must be an array")
    shader_roots = {}
    for _, root in ipairs(roots) do
        root = normalize_shader_root(root)
        local duplicate = false
        for _, current in ipairs(shader_roots) do
            if current == root then duplicate = true; break end
        end
        if not duplicate then shader_roots[#shader_roots + 1] = root end
    end
    return Text
end

function Text.get_shader_roots()
    local roots = {}
    for index, root in ipairs(shader_roots) do roots[index] = root end
    return roots
end

local function load_custom_shader(shader_name)
    if not shader_name:match("^[%w_-]+$") then return nil end
    for _, root in ipairs(shader_roots) do
        local path = root .. "/" .. shader_name .. ".frag"
        if love.filesystem.getInfo(path, "file") then
            local ok, source = pcall(love.filesystem.read, path)
            if ok and source then return source end
        end
    end
    return nil
end

--[[ lab/tooling hook: override a font's render profile at runtime. entries take
effect for fonts obtained AFTER the call (cached font objects keep their
creation-time filter) ]]
function Text.set_font_render_profile(basename, profile)
    FontManager.set_render_profile(basename, profile)
end

function Text.get_font_render_profile(basename)
    return FontManager.get_render_profile(basename)
end

--[[ call when arabic shaper module flags change (diacritics/normalization
toggles in the fonts lab): shaped output is keyed by input only ]]
function Text._flush_arabic_caches()
    ARABIC_DETECT_CACHE = {}
    ARABIC_DETECT_COUNT = 0
    ARABIC_SHAPE_CACHE = {}
    ARABIC_SHAPE_COUNT = 0
end

local function copyShallow(tbl)
    if type(tbl) ~= "table" then return tbl end
    local result = {}
    for k, v in pairs(tbl) do
        result[k] = v
    end
    return result
end

local function getBoldOffsets(amount)
    local clampedAmount = math.min(4, math.max(1, math.floor(amount + 0.5)))
    return BOLD_OFFSETS[clampedAmount] or BOLD_OFFSETS[1]
end

local MarkupProcessor = {}

function MarkupProcessor.parseScopeValue(val, defaultScope)
    -- Color values themselves may contain commas. only a recognized final
    -- scope is syntax, leave all numeric components for parseColor
    local v, scope = val:match("^(.*),(%a+)$")
    if scope == "fill" or scope == "stroke" or scope == "both" then return v, scope end
    return val, defaultScope or "both"
end

function MarkupProcessor.parseAmplitudeFrequency(v)
    local a, f = v:match("^(%d*%.?%d+),?(%d*%.?%d*)$")
    if a then
        return { amplitude = tonumber(a) or 5, frequency = tonumber(f) or 1 }
    end
    return { amplitude = 5, frequency = 1 }
end

local StyleProcessor = {}

function StyleProcessor.isDynamic(style)
    return style and (style.wave or style.shake or style.wavy or style.float or
        style.jingle or style.fillRainbow or style.strokeRainbow or style.rotate or
        style.loop or style.worm or style.tremble or style.image or style.shader)
end

local cache = {}

function getOutlineOffsets(t)
    local hit = cache[t]
    if hit then return hit end

    local offsets = {}
    for dx = -t, t do
        for dy = -t, t do
            if dx * dx + dy * dy <= t * t and (dx ~= 0 or dy ~= 0) then
                offsets[#offsets + 1] = { dx, dy }
            end
        end
    end
    cache[t] = offsets
    return offsets
end

function StyleProcessor.processStyle(text, style)
    local boldAmount = style.boldAmount or (style.bold and 1) or 0

    if style.bold then
        style.boldOffsets = getBoldOffsets(boldAmount)
    else
        style.boldOffsets = { { 0, 0 } }
    end

    local isDynamicEffect = StyleProcessor.isDynamic(style)
    style._isDynamic = isDynamicEffect or text:isTypewriterActive()

    local outlineThickness = style.outlineThickness or text.outlineThickness
    if style.blockOutline then
        style.outlineOffsets = getBlockyOutlineOffsets(outlineThickness)
    else
        style.outlineOffsets = getOutlineOffsets(math.floor(outlineThickness + 0.5))
    end

    if style.wavy then
        style.wavy.radAmp = math.rad(style.wavy.amplitude)
    end
    if style.jingle then
        style.jingle.radAmp = math.rad(style.jingle.amplitude)
    end
    if style.italic then
        style.italicRad = math.rad((style.italicAmount or 1) * ITALIC_ANGLE_FACTOR)
    end

    if style.fillOpacity then
        style.fillOpacity = math.max(0, math.min(1, style.fillOpacity.value or 1))
    end
    if style.strokeOpacity then
        style.strokeOpacity = math.max(0, math.min(1, style.strokeOpacity.value or 1))
    end

    if style.image then
        style.imageTexture = text:loadImageTexture(style.image)
    end

    return style
end

local markupHandlers = {
    color = function(text, v)
        local col, scope = MarkupProcessor.parseScopeValue(v, "both")
        local c = text:parseColor(col)
        if scope == "fill" then return { fillColor = c } end
        if scope == "stroke" then return { strokeColor = c } end
        return { fillColor = c, strokeColor = c }
    end,

    outlineColor = function(text, v)
        return { strokeColor = text:parseColor(v) }
    end,

    outlineThickness = function(_, v)
        return { outlineThickness = tonumber(v) or 0 }
    end,

    blockOutline = function(_, v)
        local useBlockOutline = v == "true" or v == "1" or v == ""
        return { blockOutline = useBlockOutline }
    end,

    backdrop = function(text, v)
        local params = parseBackdrop(v)
        return { backdrop = params }
    end,

    dropshadow = function(text, v)
        local params = parseBackdrop(v)
        return { backdrop = params }
    end,

    shader = function(text, v)
        local parts = {}
        for part in v:gmatch("([^,]+)") do
            table.insert(parts, part)
        end

        local shaderName = parts[1]
        local params = {}

        for i = 2, #parts do
            local param = parts[i]
            local key, value = param:match("([^=]+)=([^=]+)")
            if key and value then
                params[key] = tonumber(value) or value
            end
        end

        if shaderName == "wave" then
            params.amplitude = params.amplitude or 5
            params.frequency = params.frequency or 2
            params.phase = params.phase or 0
        elseif shaderName == "glitch" then
            params.intensity = params.intensity or 0.3
            params.blockSize = params.blockSize or 8
        elseif shaderName == "distort" then
            params.radius = params.radius or 20
            params.strength = params.strength or 5
        elseif shaderName == "pixelate" then
            params.pixelSize = params.pixelSize or 2
        elseif shaderName == "chromatic" then
            params.intensity = params.intensity or 2
        end

        local shaderCode = DEFAULT_SHADERS[shaderName]
        if not shaderCode then shaderCode = load_custom_shader(shaderName) end

        if shaderCode then
            return {
                shader = {
                    name = shaderName,
                    code = shaderCode,
                    params = params
                }
            }
        end

        return {}
    end,

    opacity = function(_, v)
        local o, scope = MarkupProcessor.parseScopeValue(v, "both")
        local val = tonumber(o) or 1
        local out = {}
        if scope == "fill" then out.fillOpacity = { value = val } end
        if scope == "stroke" then out.strokeOpacity = { value = val } end
        if scope == "both" then
            out.fillOpacity = { value = val }
            out.strokeOpacity = { value = val }
        end
        return out
    end,

    rainbow = function(_, v)
        local speed, sat, scope, offset = v:match("([%d%.]+),([%d%.]+),?(%a*),?(%d*%.?%d*)")
        speed, sat, offset = tonumber(speed) or 1, tonumber(sat) or 1, tonumber(offset) or 0
        local out = {}
        if not scope then scope = "stroke" end
        if scope == "fill" or scope == "" or not scope then
            out.fillRainbow = { speed = speed, saturation = sat, offset = offset }
        end
        if scope == "stroke" or scope == "" or not scope then
            out.strokeRainbow = { speed = speed, saturation = sat, offset = offset }
        end
        return out
    end,

    bold = function(_, v)
        local amount = tonumber(v) or 1
        return { bold = true, boldAmount = amount }
    end,
    italic = function(_, v) return { italic = true, italicAmount = tonumber(v) or 1 } end,
    wave = function(_, v) return { wave = MarkupProcessor.parseAmplitudeFrequency(v) } end,
    shake = function(_, v) return { shake = MarkupProcessor.parseAmplitudeFrequency(v) } end,
    wavy = function(_, v)
        local parsed = MarkupProcessor.parseAmplitudeFrequency(v)
        if v == "" then
            parsed.amplitude = 15
            parsed.frequency = 2
        end
        return { wavy = parsed }
    end,
    jingle = function(_, v)
        local parsed = MarkupProcessor.parseAmplitudeFrequency(v)
        if v == "" then
            parsed.amplitude = 5
            parsed.frequency = 1
        end
        return { jingle = parsed }
    end,

    loop = function(_, v)
        local parsed = MarkupProcessor.parseAmplitudeFrequency(v)
        if v == "" then
            parsed.amplitude = 5
            parsed.frequency = 1
        end
        return { loop = parsed }
    end,

    worm = function(_, v)
        local parsed = MarkupProcessor.parseAmplitudeFrequency(v)
        if v == "" then
            parsed.amplitude = 5
            parsed.frequency = 1
        end
        return { worm = parsed }
    end,

    tremble = function(_, v)
        local amplitude = tonumber(v) or 2
        return { tremble = { amplitude = amplitude } }
    end,

    float = function(_, v)
        local a, f, dir = v:match("([%d%.]+),([%d%.]+),?(%a*)")
        return {
            float = {
                amplitude = tonumber(a) or 5,
                frequency = tonumber(f) or 1,
                direction = (dir ~= "" and dir) or "y"
            }
        }
    end,

    rotate = function(_, v)
        local angle, speed = v:match("([%d%.%-]+),?([%d%.]*)")
        return {
            rotate = {
                angle = tonumber(angle) or 0,
                speed = tonumber(speed) or 0
            }
        }
    end,

    scale = function(_, v)
        local x, y = v:match("([%d%.]+),([%d%.]+)")
        if x and y then return { stretchX = tonumber(x), stretchY = tonumber(y) } end
        local s = tonumber(v)
        if s then return { stretchX = s, stretchY = s } end
        return {}
    end,

    size = function(text, v)
        local sz = tonumber(v) or DEFAULT_FONT_SIZE
        return { fontSize = sz, font = text:obtainFont(nil, sz) }
    end,

    font = function(text, v)
        return { font = text:obtainFont(v, text.fontSize) }
    end,

    pixelFont = function(text, v)
        local usePixelFont = v == "true" or v == "1" or v == ""
        local sz = text.fontSize
        return {
            pixelFont = usePixelFont,
            font = text:obtainFont(nil, sz, usePixelFont)
        }
    end,

    img = function(text, v)
        local parts = {}
        for part in v:gmatch("([^,]+)") do
            table.insert(parts, part)
        end

        local imagePath = parts[1]
        local quad = nil
        local width = tonumber(parts[6]) or 100
        local height = tonumber(parts[7]) or 100

        if #parts >= 5 then
            local x, y, w, h = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
            if x and y and w and h then
                quad = { x = x, y = y, w = w, h = h }
                width = tonumber(parts[6]) or 100
                height = tonumber(parts[7]) or 100
            else
                width = tonumber(parts[2]) or 100
                height = tonumber(parts[3]) or 100
            end
        elseif #parts >= 2 then
            width = tonumber(parts[2]) or 100
            height = tonumber(parts[3]) or width
        end

        return {
            insertImage = {
                path = imagePath,
                quad = quad,
                width = width,
                height = height
            }
        }
    end,
}

local function getCircularOutlineOffsets(thickness)
    local offsets = {}
    if thickness <= 0 then return offsets end

    if thickness <= 2 then
        local d = thickness
        return {
            { d,       0 }, { -d, 0 }, { 0, d }, { 0, -d },
            { d * 0.7, d * 0.7 }, { -d * 0.7, d * 0.7 },
            { d * 0.7, -d * 0.7 }, { -d * 0.7, -d * 0.7 }
        }
    end

    local filled = {}
    local r = thickness
    local r2 = r * r

    for y = -r, r do
        for x = -r, r do
            local dist2 = x * x + y * y
            if dist2 <= r2 then
                local isEdge = false
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        if dx ~= 0 or dy ~= 0 then
                            local nx, ny = x + dx, y + dy
                            if nx * nx + ny * ny > r2 then
                                isEdge = true
                                break
                            end
                        end
                    end
                    if isEdge then break end
                end

                if isEdge then
                    table.insert(filled, { x, y })
                end
            end
        end
    end

    if #filled >= 8 then
        return filled
    end

    local samples = math.max(12, math.min(24, math.ceil(thickness * 4)))
    for i = 0, samples - 1 do
        local angle = (i / samples) * math.pi * 2
        local x = math.cos(angle) * thickness
        local y = math.sin(angle) * thickness
        table.insert(offsets, { math.floor(x + 0.5), math.floor(y + 0.5) })
    end

    return offsets
end

local function getBlockyOutlineOffsets(thickness)
    local offsets = {}
    if thickness <= 0 then return offsets end

    local t = math.floor(thickness + 0.5)

    if thickness <= 2 then
        for y = -t, t do
            for x = -t, t do
                local isEdge = (x == -t or x == t or y == -t or y == t)
                if isEdge then
                    table.insert(offsets, { x, y })
                end
            end
        end
    else
        for y = -t, t do
            for x = -t, t do
                table.insert(offsets, { x, y })
            end
        end
    end

    return offsets
end

function Text:_computePadding()
    if (not self._paddingDirty) and self._cachedPadding ~= nil then
        return self._cachedPadding
    end

    local override = rawget(self, "_textPaddingOverride")
    if type(override) == "number" then
        local padding = math.max(0, math.floor(override + 0.5))
        self._cachedPadding = padding
        self._paddingDirty = false
        return padding
    end

    if self._needsReparse then
        self:parseText()
    end

    local maxOutlineThickness = self.outlineThickness or 0
    local maxBoldAmount = 0
    local maxBackdropOffset = 0

    for _, segment in ipairs(self._parsedSegments) do
        local st = segment.style or {}
        if st.outlineThickness then
            maxOutlineThickness = math.max(maxOutlineThickness, st.outlineThickness)
        end
        if st.bold and st.boldAmount then
            local clampedBold = math.min(4, math.max(1, st.boldAmount))
            maxBoldAmount = math.max(maxBoldAmount, clampedBold)
        end
        if st.backdrop then
            local b = st.backdrop
            local extent = math.max(math.abs(b.offset[1] or 0), math.abs(b.offset[2] or 0)) + (b.blur or 0)
            maxBackdropOffset = math.max(maxBackdropOffset, extent)
        end
    end

    local basePadding = math.max(maxOutlineThickness * 2.5, maxBoldAmount + 2, maxBackdropOffset * 1.2)
    -- keep padding sane so it doesn't shrink text excessively in narrow rects, but enforce
    -- a meaningful minimum tied to font size to avoid descender clipping
    local minDim = math.max(1, math.min(self._textBounds.width or 1, self._textBounds.height or 1))
    local ratioCap = math.floor(minDim * 0.08 + 0.5) -- at most 8% of min dimension
    local pixelCap = 32                              -- and at most 32px total padding each side
    local cap = math.max(8, math.min(ratioCap, pixelCap))
    local padding = math.ceil(math.min(basePadding + 4, cap))
    -- Enforce a minimum based on the current font metrics (roughly 1/4 of font height, at least 8px)
    local f = self.font
    local fh = (f and f.getHeight and f:getHeight()) or (self.fontSize or DEFAULT_FONT_SIZE)
    local minPad = math.max(10, math.floor(fh * 0.30 + 0.5))
    if padding < minPad then padding = minPad end
    --[[ the caps above trim COSMETIC headroom only, effects have a hard
    physical extent (stroke offsets reach ±outlineThickness, bold offsets
    ±boldAmount, backdrop reaches offset+blur). clamping below that slices the
    effect flat at the canvas edge ]]
    local effectRequirement = math.max(maxOutlineThickness, maxBoldAmount, maxBackdropOffset)
    local hardMin = math.ceil(effectRequirement) + 2
    if padding < hardMin then padding = hardMin end
    if padding < 0 or padding ~= padding then padding = 0 end
    self._cachedPadding = padding
    self._paddingDirty = false
    return padding
end

function Text:getPixelFontSetting(style)
    if style and style.pixelFont ~= nil then return style.pixelFont end
    return self.pixelFont
end

local function font_content_changed(self, font)
    GLOBAL_GLYPH_FONT_CACHE[font] = nil
    -- during a bake we attach scaled fallbacks BEFORE printing any glyph
    -- Invalidating this owner's layout here would replace its glyph records
    -- on the next frame without rebuilding the just-published atlas
    if rawget(self, "_buildingCanvases") then return end
    rawset(self, "_fastTextDirty", true)
    rawset(self, "_fastRenderObject", nil)
    rawset(self, "_needsReparse", true)
    rawset(self, "_rebuildNeeded", true)
    rawset(self, "_contentDirty", true)
    rawset(self, "_glyphTextures", {})
    Element._refresh_ancestor_canvases(self, false)
    Element.mark_dirty(self, "text")
end

function Text:obtainFont(font, size, pixelFont, dpi)
    --[[ thin delegate into the font manager, the instance keeps its weak
    per-font info map for scaled rendering. Names resolve from project-configured
    font roots, explicit virtual paths remain valid ]]
    local filter = pixelFont
    if filter == nil then filter = self.pixelFont end
    local obtained, meta = FontManager.get(font, size, filter, dpi)
    FontManager.watch(obtained, self, font_content_changed)
    if not self._fontInfo then
        self._fontInfo = setmetatable({}, { __mode = "k" })
    end
    if meta then
        self._fontInfo[obtained] = meta
    end
    return obtained
end

function Text:_getFontInfo(font)
    if not font then return nil end
    if self._fontInfo and self._fontInfo[font] then
        return self._fontInfo[font]
    end
    local info = FontManager.get_info(font)
    if info then
        self._fontInfo = self._fontInfo or setmetatable({}, { __mode = "k" })
        self._fontInfo[font] = info
    end
    return info
end

function Text:_getGlyphFallbackChain(baseFont, style)
    if not baseFont then return {} end
    local chain = FontManager.get_chain(baseFont)
    if chain then return chain end

    local info = self:_getFontInfo(baseFont)
    if not info then
        chain = { baseFont }
        FontManager.set_chain(baseFont, chain)
        return chain
    end

    local sourceFont = info.path or info.fontRef
    local rebuilt = self:obtainFont(sourceFont, info.size or self.fontSize or DEFAULT_FONT_SIZE,
        self:getPixelFontSetting(style))
    FontManager.ensure_fallbacks(rebuilt)
    chain = FontManager.get_chain(rebuilt) or { rebuilt }
    FontManager.set_chain(baseFont, chain)
    return chain
end

function Text:_resolveFontForGlyph(baseFont, style, char)
    if not baseFont or not char or char == "" then return baseFont end
    if type(baseFont.hasGlyphs) ~= "function" then return baseFont end

    local byChar = GLOBAL_GLYPH_FONT_CACHE[baseFont]
    if not byChar then
        byChar = {}
        GLOBAL_GLYPH_FONT_CACHE[baseFont] = byChar
    else
        local cached = byChar[char]
        if cached ~= nil then
            return cached or baseFont
        end
    end

    if baseFont:hasGlyphs(char) then
        byChar[char] = baseFont
        return baseFont
    end

    --[[ lazy fallbacks: love's hasGlyphs consults ATTACHED fallbacks, so a
    font created without them must attach before we conclude it cannot serve
    the glyph, otherwise the glyph would resolve to a chain font and raster
    on a different baseline than the eager path. runs at layout (parse) time,
    never mid-draw ]]
    if FontManager.ensure_fallbacks(baseFont) and baseFont:hasGlyphs(char) then
        byChar[char] = baseFont
        return baseFont
    end

    local chain = self:_getGlyphFallbackChain(baseFont, style)
    for i = 2, #chain do
        local fb = chain[i]
        if fb and type(fb.hasGlyphs) == "function" and fb:hasGlyphs(char) then
            byChar[char] = fb
            return fb
        end
    end

    byChar[char] = false
    return baseFont
end

-- return a font sized for the current render scale to avoid additional GPU scaling
function Text:_fontForRender(baseFont, style)
    local rs = self._renderScale or 1
    local dpi = self._renderDPI or Surface.density()
    if not baseFont then return baseFont end
    if math.abs(rs - 1) < 1e-3 and math.abs(dpi - 1) < 1e-3 then return baseFont end
    local info = self:_getFontInfo(baseFont)
    -- a supplied Font has no reloadable source. never overwrite its base
    -- metrics / fallback metadata by requesting new sizes of the same userdata
    if info and info.fontRef then return baseFont, rs end
    local baseSize = (info and info.size) or (style and style.fontSize) or self.fontSize or DEFAULT_FONT_SIZE
    local targetSize = math.max(1, math.floor(baseSize * rs + 0.5))

    local pathKey = (info and info.sourceKey) or "__default__"
    local pixel = self:getPixelFontSetting(style)
    local cacheKey = pathKey .. ":" .. tostring(targetSize) .. ":" .. tostring(pixel) .. ":" .. tostring(dpi)
    self._scaledFontCache = self._scaledFontCache or {}
    local sourceFont = info and (info.path or info.fontRef) or nil
    local scaled = self._scaledFontCache[cacheKey] or self:obtainFont(sourceFont, targetSize, pixel, dpi)
    -- a scaled clone owns a different fallback chain, attaching only to the
    -- layout font leaves non-ASCII glyphs missing in both baked text paths
    if info and info.fallbacks_attached then FontManager.ensure_fallbacks(scaled) end
    self._scaledFontCache[cacheKey] = scaled
    return scaled
end

-- File fonts are rerasterized above. Supplied Font/ImageFont objects cannot
-- be resized, so scale their glyphs without changing shared font metadata
function Text:_printRaster(char, x, y)
    local scale = rawget(self, "_rasterPrintScale") or 1
    love.graphics.print(char, x, y, 0, scale, scale)
end

function Text:loadImageTexture(imageData)
    local path = imageData.path

    if not self._imageCache then
        self._imageCache = {}
    end

    local cacheKey = path
    if imageData.quad then
        cacheKey = path ..
            "_" .. imageData.quad.x .. "_" .. imageData.quad.y .. "_" .. imageData.quad.w .. "_" .. imageData.quad.h
    end
    cacheKey = cacheKey .. "_" .. imageData.width .. "_" .. imageData.height

    if self._imageCache[cacheKey] then
        return self._imageCache[cacheKey]
    end

    local success, image = pcall(love.graphics.newImage, path)
    if not success then
        return nil
    end

    local result = {
        texture = image,
        quad = nil,
        width = imageData.width,
        height = imageData.height
    }

    if imageData.quad then
        local q = imageData.quad
        result.quad = love.graphics.newQuad(q.x, q.y, q.w, q.h, image:getDimensions())
    end

    self._imageCache[cacheKey] = result
    return result
end

---@param args? TextArgs
function Text:init(args)
    Text.super.init(self, args)
    args = args or {}

    self.text = args.text or ""
    self.fontSize = args.fontSize or DEFAULT_FONT_SIZE
    self.doubleClickEditable = args.doubleClickEditable == true
    if self.doubleClickEditable and self.mousecheck ~= true then
        self._double_click_auto_mousecheck = true
        self.mousecheck = true
    end

    self.fontPath = args.font
    self.pixelFont = args.pixelFont
    if self.pixelFont == nil then
        self.pixelFont = _looks_like_pixel_font(args.font)
    end
    self.deferFont = args.deferFont or false
    -- Interfaces with a small, bounded label tree can require immediate text
    -- publication. other clients retain the normal per-frame rebuild budget
    self.deferBuild = args.deferBuild ~= false
    rawset(self, "_textPaddingOverride", args.glyphPadding)
    self.loadFontInDraw = args.loadFontInDraw ~= false
    self._deferredFontPath = self.deferFont and args.font or nil
    if self._deferredFontPath then
        -- use a shared default font until the real one is needed
        self.font = self:obtainFont(nil, self.fontSize, self.pixelFont)
    else
        self.font = self:obtainFont(args.font, self.fontSize, self.pixelFont)
    end

    self.textAlignX = args.textAlignX or "center"
    self.textAlignY = args.textAlignY or "center"
    self.textScaled = args.textScaled == nil and false or args.textScaled
    self.textFits = args.textFits == nil and true or args.textFits
    self.clayWrap = args.clayWrap == nil and (not input_mgr.mobile.is_mobile) or args.clayWrap
    self.clayPadding = args.clayPadding or 0

    self.textScale = args.textScale or 1
    self.lineHeight = args.lineHeight or DEFAULT_LINE_HEIGHT
    self.letterSpacing = args.letterSpacing or 0
    self.wrapMode = args.wrapMode or "word"
    self.maxWidth = args.maxWidth
    self.isdrawn = false

    self.textColor = args.textColor or { 1, 1, 1, 1 }
    self.fastText = args.fastText
    self.fastUnicode = args.fastUnicode == true
    self.exactAdvances = args.exactAdvances == true
    self.richText = args.richText
    self.outlineColor = args.outlineColor or { 0, 0, 0, 1 }
    self.outlineThickness = args.outlineThickness or DEFAULT_OUTLINE_THICKNESS
    self.opacity = args.opacity or 1
    self.italic = args.italic or false
    self.bold = args.bold or false
    self.weight = args.weight or 400
    self.stretchX = args.stretchX or 1
    self.stretchY = args.stretchY or 1
    self._parsedSegments = {}
    self._lines = {}
    self._needsReparse = true
    self._textBounds = { x = 0, y = 0, width = 0, height = 0 }
    self._fitScale = 1
    self._staticCanvas = nil
    self._dynamicCanvas = nil
    self._dynamicGlyphs = {}
    self._hasDynamicContent = false
    self._typewriterState = nil
    self._glyphTextures = {}
    self._renderScale = 1
    self.scaleQuantize = args.scaleQuantize or 0.0            -- keep disabled for accuracy
    self.scaleBakeThreshold = args.scaleBakeThreshold or 0.08 -- snap near 1.0 to avoid rebuild churn
    self._rebuildNeeded = true
    self._layoutWidth = nil
    self.deferRebuild = args.deferRebuild == true
    self.rebuildThrottle = args.rebuildThrottle or 0.05
    self._lastRebuildTime = 0
    self._pendingRenderScale = nil
    self._contentDirty = false
    self._cachedPadding = nil
    self._paddingDirty = true
    self._appliedLineHeightOverride = nil

    -- Excerpt/overflow handling: keep font at normal size and show a horizontal window into the text
    -- when enabled, text will not auto-shrink, instead, drawing is clipped to the element rect and
    -- horizontally scrolled to keep the caret visible while typing or moving with arrow keys
    self.excerpt = args.excerpt or false
    self._excerpt_offset = 0 -- in base text logical units (pre-scale)
    rawset(self, "_fastTextDirty", true)
    Text._warmFastText(self)
end

function Text:_ensureFont(force)
    force = force == true
    if self._deferredFontPath then
        if not force and (not _can_spend_font_load_budget()) then
            return false
        end
        local t0 = love.timer.getTime()
        local path = self._deferredFontPath
        self._deferredFontPath = nil
        self.fontPath = path
        self.font = self:obtainFont(path, self.fontSize, self.pixelFont)
        self._needsReparse = true
        self._rebuildNeeded = true
        self._contentDirty = true
        self._paddingDirty = true
        Text._invalidateFastText(self, "font")
        Text._warmFastText(self)
        if not force then
            _spend_font_load_budget(love.timer.getTime() - t0)
        end
        return true
    elseif type(self.font) == "string" then
        local path = self.font
        self.fontPath = path
        self.font = self:obtainFont(path, self.fontSize, self.pixelFont)
        self._needsReparse = true
        self._rebuildNeeded = true
        self._contentDirty = true
        self._paddingDirty = true
        Text._invalidateFastText(self, "font")
        Text._warmFastText(self)
        return true
    end
    return false
end

function Text:addSegment(part, style)
    if part == "" then return end
    --[[ arabic detection and shaping are pure functions of (string, font,
    size, shaper flags): both memoized. flush via Text._flush_arabic_caches()
    when shaper module flags are toggled (fonts lab). caches wipe wholesale at
    a size cap, cheaper than true LRU for interned strings ]]
    local shaped = part
    local is_arabic = ARABIC_DETECT_CACHE[part]
    if is_arabic == nil then
        is_arabic = (ArabicText and ArabicText.contains_arabic and ArabicText.contains_arabic(part)) or false
        if ARABIC_DETECT_COUNT > 4096 then
            ARABIC_DETECT_CACHE = {}
            ARABIC_DETECT_COUNT = 0
        end
        ARABIC_DETECT_CACHE[part] = is_arabic
        ARABIC_DETECT_COUNT = ARABIC_DETECT_COUNT + 1
    end
    if is_arabic then
        -- prefer shaping with an Arabic-capable font path so HarfBuzz (if present)
        -- can apply proper GSUB features. fall back to internal shaper if needed
        local arabicFontPath = _font_file_exists(FONT_FALLBACK_ARABIC) and FONT_FALLBACK_ARABIC or nil
        local shape_key = part .. "\1" .. tostring(arabicFontPath) .. "\1" .. tostring(self.fontSize)
        local hit = ARABIC_SHAPE_CACHE[shape_key]
        if hit ~= nil then
            shaped = hit
            shape_key = nil
        end
        if shape_key then
            local ok, res = pcall(ArabicText.shape_text, part, arabicFontPath, self.fontSize,
                { skip_bidi_reorder = true })
            if ok and type(res) == "string" and res ~= "" then
                shaped = res
            end
            if ARABIC_SHAPE_COUNT > 2048 then
                ARABIC_SHAPE_CACHE = {}
                ARABIC_SHAPE_COUNT = 0
            end
            ARABIC_SHAPE_CACHE[shape_key] = shaped
            ARABIC_SHAPE_COUNT = ARABIC_SHAPE_COUNT + 1
        end
    end
    local segStyle = copyShallow(style)
    local function contains_cjk(s)
        for _, cp in utf8.codes(s or "") do
            if (cp >= 0x4E00 and cp <= 0x9FFF)       -- CJK Unified Ideographs
                or (cp >= 0x3400 and cp <= 0x4DBF)   -- CJK Extension A
                or (cp >= 0x3040 and cp <= 0x309F)   -- Hiragana
                or (cp >= 0x30A0 and cp <= 0x30FF)   -- Katakana
                or (cp >= 0x31F0 and cp <= 0x31FF)   -- Katakana Phonetic Extensions
                or (cp >= 0xFF66 and cp <= 0xFF9D)   -- Halfwidth Katakana
                or (cp >= 0xAC00 and cp <= 0xD7AF)   -- Hangul Syllables
                or (cp >= 0x1100 and cp <= 0x11FF)   -- Hangul Jamo
                or (cp >= 0x3130 and cp <= 0x318F)   -- Hangul Compatibility Jamo
                or (cp >= 0x20000 and cp <= 0x2FA1F) -- CJK Extensions B..F (BMP+)
            then
                return true
            end
        end
        return false
    end

    if ArabicText and ArabicText.contains_arabic and ArabicText.contains_arabic(shaped) then
        segStyle.font = self:obtainFont(FONT_FALLBACK_ARABIC, segStyle.fontSize or self.fontSize, segStyle.pixelFont)
        FontManager.ensure_fallbacks(segStyle.font)
    elseif contains_cjk(shaped) then
        segStyle.font = self:obtainFont(FONT_FALLBACK_BROAD, segStyle.fontSize or self.fontSize, segStyle.pixelFont)
        FontManager.ensure_fallbacks(segStyle.font)
    end
    self._parsedSegments[#self._parsedSegments + 1] = { text = shaped, style = segStyle }
end

function Text:applyMarkup(style, raw)
    local tag, val = raw:match("([^=]+)=?(.*)")
    local handler = markupHandlers[tag]
    if not handler then return end

    local assigns = handler(self, val)

    if assigns.insertImage then
        local imageChar = "\u{E000}"
        local imageStyle = copyShallow(style)
        imageStyle.image = assigns.insertImage
        imageStyle._isDynamic = true

        self:addSegment(imageChar, imageStyle)
        return
    end

    for k, v in pairs(assigns) do
        style[k] = v
    end
end

function Text:parseColor(str)
    if not str then return { 1, 1, 1, 1 } end
    if NAMED_COLORS[str] then return NAMED_COLORS[str] end

    if str:match("^#%x+$") and (#str == 7 or #str == 9) then
        local hex = str:sub(2)
        local r = tonumber(hex:sub(1, 2), 16) / 255
        local g = tonumber(hex:sub(3, 4), 16) / 255
        local b = tonumber(hex:sub(5, 6), 16) / 255
        local a = (#hex >= 8) and (tonumber(hex:sub(7, 8), 16) / 255) or 1
        return { r, g, b, a }
    end

    local r, g, b, a = str:match("(%d*%.?%d+),(%d*%.?%d+),(%d*%.?%d+),?(%d*%.?%d*)")
    if r then
        return {
            tonumber(r) or 1,
            tonumber(g) or 1,
            tonumber(b) or 1,
            tonumber(a) or 1
        }
    end

    return { 1, 1, 1, 1 }
end

function Text:parseText()
    self:_ensureFont()
    self._parsedSegments = {}

    local baseStyle = {
        fillColor = self.textColor,
        strokeColor = self.outlineColor,
        outlineThickness = self.outlineThickness,
        font = self.font,
        fontSize = self.fontSize,
        italic = self.italic,
        bold = self.bold,
        boldAmount = self.bold and 1 or 0,
        stretchX = self.stretchX,
        stretchY = self.stretchY,
        pixelFont = self.pixelFont,
    }

    StyleProcessor.processStyle(self, baseStyle)

    local currentStyle = copyShallow(baseStyle)
    local stack = {}
    local pos = 1
    local text = self.text or ""

    while pos <= #text do
        local markupStart, markupEnd
        if self.richText ~= false then markupStart, markupEnd = text:find(MARKUP_PATTERN, pos) end
        if markupStart then
            if markupStart > pos then
                self:addSegment(text:sub(pos, markupStart - 1), copyShallow(currentStyle))
            end

            local tag = text:sub(markupStart + 1, markupEnd - 1)
            if tag:sub(1, 1) == "/" then
                currentStyle = table.remove(stack) or copyShallow(baseStyle)
            else
                stack[#stack + 1] = copyShallow(currentStyle)
                self:applyMarkup(currentStyle, tag)
            end
            pos = markupEnd + 1
        else
            self:addSegment(text:sub(pos), copyShallow(currentStyle))
            break
        end
    end

    self._hasDynamicContent = false
    for _, segment in ipairs(self._parsedSegments) do
        StyleProcessor.processStyle(self, segment.style)
        if segment.style._isDynamic then
            self._hasDynamicContent = true
        end
    end

    self:layoutText()
    self._needsReparse = false
end

--[[ keep glyphs in logical order for editing and wrapping
use their x positions for visual order, keeping numbers left to right inside RTL lines
recompute positions after wrapping and mirror brackets only once ]]

local function _bidi_is_rtl_cp(cp)
    return (cp >= 0x0590 and cp <= 0x05FF) or (cp >= 0xFB1D and cp <= 0xFB4F) or
        (cp >= 0x0600 and cp <= 0x06FF) or (cp >= 0x0750 and cp <= 0x077F) or
        (cp >= 0x08A0 and cp <= 0x08FF) or (cp >= 0xFB50 and cp <= 0xFDFF) or
        (cp >= 0xFE70 and cp <= 0xFEFF)
end

local BIDI_MIRROR = {
    [0x0028] = 0x0029,
    [0x0029] = 0x0028,
    [0x005B] = 0x005D,
    [0x005D] = 0x005B,
    [0x007B] = 0x007D,
    [0x007D] = 0x007B,
    [0x003C] = 0x003E,
    [0x003E] = 0x003C,
    [0x00AB] = 0x00BB,
    [0x00BB] = 0x00AB,
    [0x2039] = 0x203A,
    [0x203A] = 0x2039,
    [0x2018] = 0x2019,
    [0x2019] = 0x2018,
    [0x201C] = 0x201D,
    [0x201D] = 0x201C,
}

--[[ classes: "R" strong right-to-left, "L" strong left-to-right, "EN" digit
(weak), "N" neutral (whitespace/punctuation/symbols/inline images) ]]
local function _bidi_class(cp)
    if not cp then return "N" end
    if _bidi_is_rtl_cp(cp) then return "R" end
    if (cp >= 0x30 and cp <= 0x39) or (cp >= 0x0660 and cp <= 0x0669)
        or (cp >= 0x06F0 and cp <= 0x06F9) then
        return "EN"
    end
    if cp <= 0x40 then return "N" end
    if (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0xBF) then return "N" end
    if (cp >= 0x2000 and cp <= 0x2BFF) or (cp >= 0x3000 and cp <= 0x303F) then return "N" end
    return "L"
end

local function _bidi_position_line(line)
    local glyphs = line.glyphs
    local n = #glyphs
    if n == 0 then return end

    local classes = {}
    local base, anyR
    for i = 1, n do
        local g = glyphs[i]
        local cp
        if not g.isImage and g.char and g.char ~= "" then
            cp = utf8.codepoint(g.char)
        end
        local c = _bidi_class(cp)
        classes[i] = c
        if c == "R" then anyR = true end
        if not base and (c == "R" or c == "L") then base = c end
    end
    base = base or "L"

    if not anyR then
        --[[ pure LTR: (re)assign sequential positions, restoring any chars a
        previous positioning mirrored ]]
        local cursor = 0
        for i = 1, n do
            local g = glyphs[i]
            if g._bidiOrigChar then g.char = g._bidiOrigChar end
            g.x = cursor
            cursor = cursor + (g.advance or g.width)
        end
        return
    end

    for i = 1, n do
        if classes[i] == "EN" then classes[i] = "L" end
    end

    --[[ neutral resolution (UAX#9 N1/N2 light): a neutral stretch between two
    equal strong classes takes that class, otherwise the base direction ]]
    local i = 1
    while i <= n do
        if classes[i] == "N" then
            local j = i
            while j < n and classes[j + 1] == "N" do j = j + 1 end
            local left = (i > 1) and classes[i - 1] or nil
            local right = (j < n) and classes[j + 1] or nil
            local resolved = (left == right and left) or base
            for k = i, j do classes[k] = resolved end
            i = j + 1
        else
            i = i + 1
        end
    end

    local runs = {}
    local runStart = 1
    for k = 2, n + 1 do
        if k > n or classes[k] ~= classes[runStart] then
            runs[#runs + 1] = { dir = classes[runStart], s = runStart, e = k - 1 }
            runStart = k
        end
    end

    local cursor = 0
    local function place(run)
        if run.dir == "R" then
            for gi = run.e, run.s, -1 do
                local g = glyphs[gi]
                g.x = cursor
                cursor = cursor + (g.advance or g.width)
            end
        else
            for gi = run.s, run.e do
                local g = glyphs[gi]
                g.x = cursor
                cursor = cursor + (g.advance or g.width)
            end
        end
    end
    if base == "R" then
        for r = #runs, 1, -1 do place(runs[r]) end
    else
        for r = 1, #runs do place(runs[r]) end
    end

    for k = 1, n do
        local g = glyphs[k]
        local orig = g._bidiOrigChar or g.char
        if orig and orig ~= "" and utf8.len(orig) == 1 then
            local cp = utf8.codepoint(orig)
            local m = BIDI_MIRROR[cp]
            if m then
                if not g._bidiOrigChar then g._bidiOrigChar = orig end
                g.char = (classes[k] == "R") and utf8.char(m) or orig
            end
        end
    end
end

-- Opt-in (exactAdvances): at a fractional display density LÖVE reports each
-- glyph's advance rounded to whole logical pixels, so per-glyph layout loses
-- up to a pixel per glyph (word spaces visibly collapse at 125%). measure at
-- the physical pixel size instead and convert back to logical units
function Text._advance(self, font, char)
    local d = rawget(self, "__data")
    if not (d and d.exactAdvances) then return font:getWidth(char) end
    local dpi = Surface.density()
    if math.abs(dpi - 1) < 1e-3 then return font:getWidth(char) end
    local info = self:_getFontInfo(font)
    if not info or not info.path or info.pixel or not info.size then return font:getWidth(char) end
    local physical = FontManager.get(info.path, info.size * dpi, false, 1)
    return physical:getWidth(char) / dpi
end

function Text:layoutText()
    local segments = self._parsedSegments
    local letterSpacing = self.letterSpacing
    local lineHFactor = self._lineHeightOverride or self.lineHeight

    local lines = {}
    local function newLine()
        return { glyphs = {}, width = 0, height = 0, ascent = 0, descent = 0, hasRTL = false, hasLatinOrDigit = false }
    end
    local currentLine = newLine()
    local is_rtl_cp = _bidi_is_rtl_cp
    local maxWidth = 0
    local totalHeight = 0
    local globalIndex = 0

    self._dynamicGlyphs = {}

    for segmentIndex = 1, #segments do
        local segment = segments[segmentIndex]
        local segmentText = segment.text
        local font = segment.style.font
        local style = segment.style
        local stretchX = style.stretchX or 1
        local stretchY = style.stretchY or 1

        local baseAscent, baseDescent = FontManager.metrics(font)
        baseAscent, baseDescent = baseAscent * stretchY, baseDescent * stretchY

        -- try HarfBuzz positions for Arabic segments only if they yield presentation-forms characters
        local useHB = false
        local hbGlyphs = nil
        if ArabicText and ArabicText.USE_HB_POSITIONS and ArabicText.shape_positions and ArabicText.contains_arabic and ArabicText.contains_arabic(segmentText) then
            local arabicFontPath = _font_file_exists(FONT_FALLBACK_ARABIC) and FONT_FALLBACK_ARABIC or nil
            local ok, res = pcall(ArabicText.shape_positions, segmentText, arabicFontPath,
                (segment.style.fontSize or self.fontSize))
            if ok and type(res) == "table" then
                -- validate glyph chars are presentation forms, otherwise drawing per-char breaks shaping
                local hasPF = false
                for _, g in ipairs(res) do
                    if g.char and g.char ~= "" then
                        local cp = utf8.codepoint(g.char)
                        if cp and ((cp >= 0xFB50 and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF)) then
                            hasPF = true; break
                        end
                    end
                end
                if hasPF then
                    hbGlyphs = res
                    useHB = true
                end
            end
        end

        if useHB then
            for _, g in ipairs(hbGlyphs) do
                if g.char == "\n" then
                    currentLine.height = currentLine.ascent + currentLine.descent
                    if currentLine.hasRTL then
                        _bidi_position_line(currentLine)
                    end
                    lines[#lines + 1] = currentLine

                    maxWidth = math.max(maxWidth, currentLine.width)
                    totalHeight = totalHeight + currentLine.height * lineHFactor

                    currentLine = newLine()
                else
                    local char = g.char or ""
                    local charWidth = math.abs(g.x_advance or 0)
                    local charHeight = font:getHeight() * stretchY

                    local glyphAscent = baseAscent
                    local glyphDescent = baseDescent

                    currentLine.ascent = math.max(currentLine.ascent, glyphAscent)
                    currentLine.descent = math.max(currentLine.descent, glyphDescent)

                    globalIndex = globalIndex + 1

                    local glyph = {
                        char = char,
                        x = currentLine.width,
                        font = font,
                        style = style,
                        width = charWidth,
                        height = charHeight,
                        ascent = glyphAscent,
                        descent = glyphDescent,
                        globalIndex = globalIndex,
                        isImage = false,
                        hbXOffset = g.x_offset or 0,
                        hbYOffset = g.y_offset or 0,
                    }

                    if style._isDynamic then
                        self._dynamicGlyphs[#self._dynamicGlyphs + 1] = glyph
                    end

                    currentLine.hasRTL = true
                    glyph.advance = charWidth + letterSpacing
                    currentLine.glyphs[#currentLine.glyphs + 1] = glyph
                    currentLine.width = currentLine.width + glyph.advance
                end
            end
        else
            for _, codepoint in utf8.codes(segmentText) do
                if codepoint == 10 then
                    currentLine.height = currentLine.ascent + currentLine.descent
                    if currentLine.hasRTL then
                        _bidi_position_line(currentLine)
                    end
                    lines[#lines + 1] = currentLine

                    maxWidth = math.max(maxWidth, currentLine.width)
                    totalHeight = totalHeight + currentLine.height * lineHFactor

                    currentLine = newLine()
                else
                    local char = utf8.char(codepoint)
                    local isArabicMark = false
                    local isArabicBase = false
                    if ArabicText and ArabicText.is_diacritic_cp then
                        isArabicMark = ArabicText.is_diacritic_cp(codepoint)
                    end
                    if ArabicText and ArabicText.is_arabic_cp then
                        isArabicBase = ArabicText.is_arabic_cp(codepoint)
                    end
                    local charWidth, charHeight
                    local glyphFont = font
                    local isImage = false

                    if char == "\u{E000}" and style.image then
                        isImage = true
                        if not style.imageTexture then
                            style.imageTexture = self:loadImageTexture(style.image)
                        end
                        if style.imageTexture then
                            charWidth = style.imageTexture.width * stretchX
                            charHeight = style.imageTexture.height * stretchY
                        else
                            charWidth = glyphFont:getWidth("?") * stretchX
                            charHeight = glyphFont:getHeight() * stretchY
                        end
                        char = ""
                    else
                        glyphFont = self:_resolveFontForGlyph(font, style, char)
                        charWidth = Text._advance(self, glyphFont, char) * stretchX
                        charHeight = glyphFont:getHeight() * stretchY
                    end

                    local extraSpacing = 0
                    if style.bold and style.boldAmount then
                        local clampedBoldAmount = math.min(4, math.max(1, style.boldAmount))
                        extraSpacing = math.max(clampedBoldAmount * 1.0, 0)
                    end

                    local outlineThickness = style.outlineThickness or self.outlineThickness
                    local outlineSpacing = 0
                    if outlineThickness > 0 then
                        if style.blockOutline then
                            outlineSpacing = outlineThickness * 1.0
                        else
                            outlineSpacing = outlineThickness * 0.5
                        end
                    end

                    -- for Arabic letters and combining marks, avoid injecting extra spacing
                    -- so cursive connections are not broken. Diacritics should not advance
                    if isArabicBase or isArabicMark then
                        extraSpacing = 0
                        outlineSpacing = 0
                    end

                    local imageSpacing = 0
                    if isImage then
                        imageSpacing = 4
                    end

                    local backdropSpacing = 0
                    if style.backdrop then
                        backdropSpacing = math.max(math.abs(style.backdrop.offset[1]), math.abs(style.backdrop.offset[2])) +
                            style.backdrop.blur
                    end

                    local glyphAscent, glyphDescent
                    local glyphFontAscent, glyphFontDescent = FontManager.metrics(glyphFont)
                    glyphFontAscent, glyphFontDescent = glyphFontAscent * stretchY, glyphFontDescent * stretchY
                    --[[ inline images center on the MIDDLE of the font's line box
                    (ascent above baseline, descent below), not on the baseline
                    itself, baseline-centering hangs half the image below the
                    surrounding text ]]
                    local imageCenterAbove = (glyphFontAscent - glyphFontDescent) * 0.5
                    if isImage then
                        local imageHalfHeight = charHeight * 0.5

                        glyphAscent = math.max(glyphFontAscent, imageHalfHeight + imageCenterAbove)
                        glyphDescent = math.max(glyphFontDescent, imageHalfHeight - imageCenterAbove)
                    else
                        glyphAscent = glyphFontAscent
                        glyphDescent = glyphFontDescent
                    end

                    currentLine.ascent = math.max(currentLine.ascent, glyphAscent)
                    currentLine.descent = math.max(currentLine.descent, glyphDescent)

                    globalIndex = globalIndex + 1

                    local glyph = {
                        char = char,
                        x = currentLine.width,
                        font = glyphFont,
                        style = style,
                        width = charWidth,
                        height = charHeight,
                        ascent = glyphAscent,
                        descent = glyphDescent,
                        globalIndex = globalIndex,
                        isImage = isImage
                    }

                    if isImage then
                        glyph.imageTexture = style.imageTexture
                        --[[ draw sites compute image top as screenY - baselineOffset*rs;
                        this puts the image center at (line-box middle) ]]
                        glyph.baselineOffset = (charHeight * 0.5 + imageCenterAbove) - glyphAscent
                    end

                    -- merge Arabic diacritics into the previous base glyph so GPOS anchors apply
                    if isArabicMark and #currentLine.glyphs > 0 then
                        local prev = currentLine.glyphs[#currentLine.glyphs]
                        prev.char = prev.char .. char
                        -- Diacritic has zero advance and its own styling isn't supported separately
                        goto continue_layout_loop
                    end

                    if style._isDynamic then
                        self._dynamicGlyphs[#self._dynamicGlyphs + 1] = glyph
                    end

                    -- Basic direction hints to decide if we treat the line as RTL
                    if is_rtl_cp(codepoint) then
                        currentLine.hasRTL = true
                    end
                    local b = string.byte(char)
                    if b and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)) then
                        currentLine.hasLatinOrDigit = true
                    end

                    glyph.advance = charWidth + letterSpacing + extraSpacing + outlineSpacing + imageSpacing +
                        backdropSpacing

                    currentLine.glyphs[#currentLine.glyphs + 1] = glyph
                    currentLine.width = currentLine.width + glyph.advance
                    ::continue_layout_loop::
                end
            end
        end
    end

    if #currentLine.glyphs > 0 then
        currentLine.height = currentLine.ascent + currentLine.descent
        if currentLine.hasRTL then
            _bidi_position_line(currentLine)
        end
        lines[#lines + 1] = currentLine
        maxWidth = math.max(maxWidth, currentLine.width)
        totalHeight = totalHeight + currentLine.height * lineHFactor
    end

    -- apply optional word wrapping based on current layout width (clay-style)
    local wrapLimit = nil
    if self.clayWrap and self._layoutWidth and self._layoutWidth > 0 then
        wrapLimit = self._layoutWidth
    elseif type(self.maxWidth) == "number" and self.maxWidth > 0 then
        wrapLimit = self.maxWidth
    end

    if wrapLimit and (self.wrapMode == "word") then
        local function rebuild_line_from_range(srcGlyphs, s, e, hasRTL, hasLatin)
            local L = {
                glyphs = {},
                width = 0,
                height = 0,
                ascent = 0,
                descent = 0,
                hasRTL = hasRTL,
                hasLatinOrDigit =
                    hasLatin
            }
            local x = 0
            for i = s, e do
                local g = srcGlyphs[i]
                g.x = x
                table.insert(L.glyphs, g)
                x = x + (g.advance or g.width)
                L.ascent = math.max(L.ascent, g.ascent or 0)
                L.descent = math.max(L.descent, g.descent or 0)
            end
            L.width = x
            L.height = L.ascent + L.descent
            --[[ re-run bidi positioning per wrapped line (the source line's
            visual order does not survive a split) ]]
            if L.hasRTL then
                _bidi_position_line(L)
            end
            return L
        end

        local wrapped = {}
        local newMaxW = 0
        local newTotalH = 0

        for _, srcLine in ipairs(lines) do
            local accGlyphs = {}
            local accWidth = 0
            local accAscent, accDescent = 0, 0
            local lastSpaceIdx = nil

            local function flush_acc()
                if #accGlyphs == 0 then return end
                local L = rebuild_line_from_range(accGlyphs, 1, #accGlyphs, srcLine.hasRTL, srcLine.hasLatinOrDigit)
                wrapped[#wrapped + 1] = L
                newMaxW = math.max(newMaxW, L.width)
                newTotalH = newTotalH + L.height * self.lineHeight
                accGlyphs, accWidth, accAscent, accDescent, lastSpaceIdx = {}, 0, 0, 0, nil
            end

            for i = 1, #srcLine.glyphs do
                local g = srcLine.glyphs[i]
                local adv = g.advance or g.width

                -- track last word break (space or tab)
                if g.char == " " or g.char == "\t" then
                    lastSpaceIdx = #accGlyphs + 1
                end

                accGlyphs[#accGlyphs + 1] = g
                accWidth = accWidth + adv
                accAscent = math.max(accAscent, g.ascent or 0)
                accDescent = math.max(accDescent, g.descent or 0)

                if accWidth > wrapLimit and lastSpaceIdx then
                    -- Break before the last space (drop the space at line end)
                    local preCount = lastSpaceIdx - 1
                    if preCount <= 0 then
                        -- no content before space, do not wrap here
                    else
                        local preLine = rebuild_line_from_range(accGlyphs, 1, preCount, srcLine.hasRTL,
                            srcLine.hasLatinOrDigit)
                        wrapped[#wrapped + 1] = preLine
                        newMaxW = math.max(newMaxW, preLine.width)
                        newTotalH = newTotalH + preLine.height * self.lineHeight

                        -- Remainder becomes the new accumulator (skip the space itself)
                        local rem = {}
                        for j = lastSpaceIdx + 1, #accGlyphs do rem[#rem + 1] = accGlyphs[j] end
                        accGlyphs = rem
                        accWidth, accAscent, accDescent, lastSpaceIdx = 0, 0, 0, nil
                        for j = 1, #accGlyphs do
                            local gg = accGlyphs[j]
                            accWidth = accWidth + (gg.advance or gg.width)
                            accAscent = math.max(accAscent, gg.ascent or 0)
                            accDescent = math.max(accDescent, gg.descent or 0)
                            if gg.char == " " or gg.char == "\t" then lastSpaceIdx = j end
                        end
                    end
                end
            end

            -- flush the last partial line for this source line
            flush_acc()
        end

        lines = wrapped
        maxWidth = newMaxW
        totalHeight = newTotalH
    end

    self._lines = lines
    self._textBounds = { width = maxWidth, height = totalHeight }
    self._paddingDirty = true
end

function Text:createGlyphTexture(char, font, style)
    local pixelFont = self:getPixelFontSetting(style)
    local key = char ..
        tostring(font) ..
        (style.bold and "b" or "") ..
        (style.italic and "i" or "") .. (pixelFont and "p" or "") .. (style.blockOutline and "block" or "round")
        .. ":dpi=" .. tostring(Surface.density()) .. ":gen=" .. tostring(FontManager.generation(font))
    if self._glyphTextures[key] then
        return self._glyphTextures[key]
    end

    local width = font:getWidth(char) + 8
    local height = font:getHeight() + 8

    local canvas = _text_new_canvas(width, height)
    _setTextureClamp(canvas)
    local minFilter = pixelFont and "nearest" or "linear"
    local magFilter = pixelFont and "nearest" or "linear"
    canvas:setFilter(minFilter, magFilter)

    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.setFont(font)
    rawset(self, "_rasterPrintScale", 1)
    love.graphics.clear(0, 0, 0, 0)

    local oldMinFilter, oldMagFilter = love.graphics.getDefaultFilter()
    love.graphics.setDefaultFilter(minFilter, magFilter)

    love.graphics.push()
    love.graphics.translate(4, 4)

    if style.italic and style.italicRad then
        love.graphics.shear(-math.tan(style.italicRad), 0)
    end

    love.graphics.setColor(1, 1, 1, 1)
    if style.bold then
        for _, offset in ipairs(style.boldOffsets) do
            self:_printRaster(char, offset[1], offset[2])
        end
    else
        self:_printRaster(char, 0, 0)
    end

    love.graphics.pop()
    love.graphics.pop()

    self._glyphTextures[key] = canvas
    return canvas
end

function Text:buildCanvases(renderScale)
    -- one protected state boundary per bake (never per glyph). Font loading
    -- can invoke the probe, and failed rasters must not leak a target/stack
    local depth = love.graphics.getStackDepth()
    love.graphics.push("all")
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha", "alphamultiply")
    local dpi = Surface.density()
    self._renderDPI = dpi
    rawset(self, "_buildingCanvases", true)
    local ok, err = xpcall(function() self:_buildCanvases(renderScale) end, debug.traceback)
    rawset(self, "_buildingCanvases", nil)
    while love.graphics.getStackDepth() > depth do love.graphics.pop() end
    if not ok then error(err, 0) end
end

function Text:_buildCanvases(renderScale)
    local scale = math.max(0.01, renderScale or 1)
    self._renderScale = scale
    if self._needsReparse then
        self:parseText()
    end

    local maxOutlineThickness = self.outlineThickness
    local maxBoldAmount = 0
    local maxBackdropOffset = 0

    for _, segment in ipairs(self._parsedSegments) do
        if segment.style.outlineThickness then
            maxOutlineThickness = math.max(maxOutlineThickness, segment.style.outlineThickness)
        end
        if segment.style.bold and segment.style.boldAmount then
            local clampedBoldAmount = math.min(4, math.max(1, segment.style.boldAmount))
            maxBoldAmount = math.max(maxBoldAmount, clampedBoldAmount)
        end
        if segment.style.backdrop then
            local backdropExtent = math.max(
                math.abs(segment.style.backdrop.offset[1]),
                math.abs(segment.style.backdrop.offset[2])
            ) + segment.style.backdrop.blur
            maxBackdropOffset = math.max(maxBackdropOffset, backdropExtent)
        end
    end

    local padding = self:_computePadding()

    local baseCanvasWidth = math.ceil(self._textBounds.width + padding * 2)
    local baseCanvasHeight = math.ceil(self._textBounds.height + padding * 2)

    local canvasWidth = math.max(1, math.ceil(baseCanvasWidth * scale) + 2)
    local canvasHeight = math.max(1, math.ceil(baseCanvasHeight * scale) + 2)

    if canvasWidth <= 0 or canvasHeight <= 0 then return end

    local needsPixelFont = true
    for _, segment in ipairs(self._parsedSegments) do
        if not self:getPixelFontSetting(segment.style) then
            needsPixelFont = false
            break
        end
    end

    local minFilter = needsPixelFont and "nearest" or "linear"
    local magFilter = needsPixelFont and "nearest" or "linear"

    self._staticCanvas = _text_new_canvas(canvasWidth, canvasHeight)
    _setTextureClamp(self._staticCanvas)
    self._staticCanvas:setFilter(minFilter, magFilter)

    self._canvasPadding = padding

    if self._hasDynamicContent then
        self._glyphAtlas = {}
        self._spriteBatch = nil

        local fontsUsed = {}
        for _, glyph in ipairs(self._dynamicGlyphs) do
            local font = glyph.font
            if not fontsUsed[font] then
                fontsUsed[font] = true
            end
        end

        local firstFont = next(fontsUsed)
        if firstFont then
            local atlasBase = 2048
            local atlasSize = math.max(512, math.floor(atlasBase * math.min(self._renderScale or 1, 2) + 0.5))
            local atlasLimit = math.floor(love.graphics.getSystemLimits().texturesize / (self._renderDPI or 1))
            atlasSize = math.min(atlasSize, atlasLimit)
            self._glyphAtlasCanvas = _text_new_canvas(atlasSize, atlasSize)
            _setTextureClamp(self._glyphAtlasCanvas)
            self._glyphAtlasCanvas:setFilter(minFilter, magFilter)

            local prevCanvas2 = Surface.capture_render_target()
            love.graphics.setCanvas(self._glyphAtlasCanvas)
            -- reset transforms and disable any active scissor inherited from parents
            love.graphics.push("all")
            love.graphics.origin()
            love.graphics.setScissor()
            love.graphics.clear(0, 0, 0, 0)

            local atlasX, atlasY = 0, 0
            local rowHeight = 0
            local gutter = 2 / (self._renderDPI or 1)
            local atlasCanvas = self._glyphAtlasCanvas
            self._glyphAtlasPages = {atlasCanvas}

            for _, glyph in ipairs(self._dynamicGlyphs) do
                if glyph.isImage then
                    goto continue_atlas
                end

                local fillColor = glyph.style.fillColor or self.textColor or { 1, 1, 1, 1 }
                local strokeColor = glyph.style.strokeColor or self.outlineColor or { 0, 0, 0, 1 }
                local outlineThickness = glyph.style.outlineThickness or self.outlineThickness or 0
                local pixelFont = self:getPixelFontSetting(glyph.style)
                local renderFont, rasterPrintScale = self:_fontForRender(glyph.font, glyph.style)
                renderFont = renderFont or glyph.font
                rasterPrintScale = rasterPrintScale or 1

                if type(fillColor) ~= "table" or #fillColor < 3 then
                    fillColor = { 1, 1, 1, 1 }
                end
                if type(strokeColor) ~= "table" or #strokeColor < 3 then
                    strokeColor = { 0, 0, 0, 1 }
                end

                local key = glyph.char ..
                    tostring(glyph.font) ..
                    (glyph.style.bold and ("b" .. (glyph.style.boldAmount or 1)) or "") ..
                    (glyph.style.italic and ("i" .. (glyph.style.italicAmount or 1)) or "") ..
                    (glyph.style.rotate and glyph.style.rotate.speed == 0 and ("r" .. tostring(glyph.style.rotate.angle)) or "") ..
                    (glyph.style.image and ("img" .. glyph.style.image.path .. (glyph.style.image.quad and ("_" .. glyph.style.image.quad.x .. "_" .. glyph.style.image.quad.y) or "")) or "") ..
                    (not glyph.style.fillRainbow and ("f" .. table.concat(fillColor, ",", 1, 4)) or "rainbow") ..
                    (glyph.style.strokeRainbow and "srainbow" or ("s" .. table.concat(strokeColor, ",", 1, 4))) ..
                    ("o" .. tostring(outlineThickness)) ..
                    ("p" .. tostring(pixelFont)) ..
                    (glyph.style.blockOutline and "block" or "round") ..
                    (glyph.style.backdrop and ("backdrop" .. table.concat(glyph.style.backdrop.color, ",", 1, 4) .. "_" .. glyph.style.backdrop.offset[1] .. "_" .. glyph.style.backdrop.offset[2]) or "")

                if not self._glyphAtlas[key] then
                    love.graphics.setFont(renderFont)
                    rawset(self, "_rasterPrintScale", rasterPrintScale)

                    local boldAmount = (glyph.style.bold and glyph.style.boldAmount) or 0
                    local backdropExtent = 0
                    if glyph.style.backdrop then
                        backdropExtent = math.max(
                            math.abs(glyph.style.backdrop.offset[1]),
                            math.abs(glyph.style.backdrop.offset[2])
                        ) + glyph.style.backdrop.blur
                    end
                    local glyphPadding = math.ceil(math.max(
                        outlineThickness * 2,
                        boldAmount + 2,
                        backdropExtent * 2
                    )) + 6

                    local italicExtraWidth = 0
                    if glyph.style.italic and glyph.style.italicRad then
                        italicExtraWidth = math.ceil(renderFont:getHeight() * rasterPrintScale * math.tan(glyph.style.italicRad))
                    end

                    local glyphWidthUnscaled = renderFont:getWidth(glyph.char) * rasterPrintScale + glyphPadding * 2 + italicExtraWidth
                    local ascentH, descentH = FontManager.metrics(renderFont)
                    local glyphHeightUnscaled = math.max(ascentH + descentH, renderFont:getHeight())
                        * rasterPrintScale + glyphPadding * 2 + 2
                    local dpi = self._renderDPI or 1
                    glyphPadding = math.ceil(glyphPadding * dpi) / dpi
                    local glyphWidth = math.max(1, math.ceil(glyphWidthUnscaled * dpi) / dpi)
                    local glyphHeight = math.max(1, math.ceil(glyphHeightUnscaled * dpi) / dpi)

                    local cellW = glyphWidth + gutter * 2
                    local cellH = glyphHeight + gutter * 2

                    if atlasX + cellW > atlasSize then
                        atlasX = 0
                        atlasY = atlasY + rowHeight
                        rowHeight = 0
                    end
                    if atlasY + cellH > atlasSize or cellW > atlasSize then
                        -- Spill to another page, never publish Quads outside
                        -- the texture (previously silently clipped late glyphs)
                        atlasSize = math.max(atlasSize, math.ceil(cellW), math.ceil(cellH))
                        assert(atlasSize <= atlasLimit, "Text glyph exceeds GPU texture size limit")
                        atlasCanvas = _text_new_canvas(atlasSize, atlasSize)
                        atlasCanvas:setFilter(minFilter, magFilter)
                        _setTextureClamp(atlasCanvas)
                        self._glyphAtlasPages[#self._glyphAtlasPages + 1] = atlasCanvas
                        love.graphics.setCanvas(atlasCanvas)
                        love.graphics.clear(0, 0, 0, 0)
                        atlasX, atlasY, rowHeight = 0, 0, 0
                    end

                    love.graphics.push()
                    love.graphics.translate(atlasX + gutter, atlasY + gutter)
                    love.graphics.translate(glyphPadding, glyphPadding)

                    local oldMinFilter, oldMagFilter = love.graphics.getDefaultFilter()
                    if pixelFont then
                        love.graphics.setDefaultFilter("nearest", "nearest")
                    else
                        love.graphics.setDefaultFilter("linear", "linear")
                    end

                    if glyph.style.backdrop then
                        local backdrop = glyph.style.backdrop
                        love.graphics.push()
                        love.graphics.translate(backdrop.offset[1], backdrop.offset[2])

                        if glyph.style.rotate and glyph.style.rotate.speed == 0 then
                            local centerX = renderFont:getWidth(glyph.char) * 0.5
                            local centerY = renderFont:getHeight() * 0.5
                            love.graphics.translate(centerX, centerY)
                            love.graphics.rotate(math.rad(glyph.style.rotate.angle))
                            love.graphics.translate(-centerX, -centerY)
                        end

                        if glyph.style.italic and glyph.style.italicRad then
                            love.graphics.shear(-math.tan(glyph.style.italicRad), 0)
                        end

                        if outlineThickness > 0 then
                            love.graphics.setColor(backdrop.color)
                            local offsets = glyph.style.blockOutline and
                                getBlockyOutlineOffsets(outlineThickness) or
                                getCircularOutlineOffsets(outlineThickness)
                            for _, offset in ipairs(offsets) do
                                if glyph.style.bold and glyph.style.boldOffsets then
                                    for _, boldOffset in ipairs(glyph.style.boldOffsets) do
                                        self:_printRaster(glyph.char, boldOffset[1] + offset[1],
                                            boldOffset[2] + offset[2])
                                    end
                                else
                                    self:_printRaster(glyph.char, offset[1], offset[2])
                                end
                            end
                        end

                        love.graphics.setColor(backdrop.color)
                        if glyph.style.bold and glyph.style.boldOffsets then
                            for _, boldOffset in ipairs(glyph.style.boldOffsets) do
                                self:_printRaster(glyph.char, boldOffset[1], boldOffset[2])
                            end
                        else
                            self:_printRaster(glyph.char, 0, 0)
                        end

                        love.graphics.pop()
                    end

                    if glyph.style.rotate and glyph.style.rotate.speed == 0 then
                        local centerX = renderFont:getWidth(glyph.char) * 0.5
                        local centerY = renderFont:getHeight() * 0.5
                        love.graphics.translate(centerX, centerY)
                        love.graphics.rotate(math.rad(glyph.style.rotate.angle))
                        love.graphics.translate(-centerX, -centerY)
                    end

                    if glyph.style.italic and glyph.style.italicRad then
                        love.graphics.shear(-math.tan(glyph.style.italicRad), 0)
                    end

                    local actualFillColor = glyph.style.fillRainbow and { 1, 1, 1, 1 } or fillColor
                    local actualStrokeColor = glyph.style.strokeRainbow and { 1, 1, 1, 1 } or strokeColor

                    if outlineThickness > 0 then
                        love.graphics.setColor(actualStrokeColor)
                        local offsets = glyph.style.blockOutline and
                            getBlockyOutlineOffsets(outlineThickness) or
                            getCircularOutlineOffsets(outlineThickness)
                        for _, offset in ipairs(offsets) do
                            local ox = math.floor(offset[1] + 0.5)
                            local oy = math.floor(offset[2] + 0.5)
                            if glyph.style.bold and glyph.style.boldOffsets then
                                for _, boldOffset in ipairs(glyph.style.boldOffsets) do
                                    local bx = math.floor(boldOffset[1] + 0.5)
                                    local by = math.floor(boldOffset[2] + 0.5)
                                    self:_printRaster(glyph.char, bx + ox, by + oy)
                                end
                            else
                                self:_printRaster(glyph.char, ox, oy)
                            end
                        end
                    end

                    -- Fill
                    love.graphics.setColor(actualFillColor)
                    _print_char_fill_base(self, glyph.char, glyph.style)
                    -- back to whatever blend mode the caller had (we didn't change it)

                    love.graphics.pop()

                    love.graphics.setDefaultFilter(oldMinFilter, oldMagFilter)

                    self._glyphAtlas[key] = {
                        canvas = atlasCanvas,
                        quad = love.graphics.newQuad(atlasX + gutter, atlasY + gutter, glyphWidth, glyphHeight,
                            atlasSize, atlasSize),
                        width = glyphWidth,
                        height = glyphHeight,
                        offsetX = glyphPadding,
                        offsetY = glyphPadding
                    }

                    atlasX = atlasX + cellW
                    rowHeight = math.max(rowHeight, cellH)
                end

                glyph.atlasData = self._glyphAtlas[key]

                ::continue_atlas::
            end

            love.graphics.pop()
            Surface.restore_render_target(prevCanvas2)

            local maxGlyphs = #self._dynamicGlyphs
            self._spriteBatch = love.graphics.newSpriteBatch(self._glyphAtlasCanvas, math.max(maxGlyphs * 2, 100))
        end

        --[[ the shader/no-shader group cache filters on glyph.atlasData, and a
        budget-deferred first build can run _drawDynamicGlyphs BEFORE this bake:
        the cache then holds empty groups keyed by a glyph list whose identity
        never changes again -> animated glyphs invisible forever. the bake just
        (re)assigned atlasData, so the grouping must be recomputed ]]
        rawset(self, "_dynGroups", nil)
    end

    local prevCanvas3 = Surface.capture_render_target()
    love.graphics.setCanvas(self._staticCanvas)
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.clear(0, 0, 0, 0)

    local oldMinFilter, oldMagFilter = love.graphics.getDefaultFilter()
    if needsPixelFont then
        love.graphics.setDefaultFilter("nearest", "nearest")
    else
        love.graphics.setDefaultFilter("linear", "linear")
    end

    love.graphics.push()
    local rs = self._renderScale or 1
    local y_base = padding

    for _, line in ipairs(self._lines) do
        local lineX_base = padding

        local staticGlyphs = {}
        for _, glyph in ipairs(line.glyphs) do
            local gx_base = lineX_base + glyph.x
            local gy_base = y_base + line.ascent - (glyph.ascent or 0)
            glyph.screenX = Surface.snap(gx_base * rs, self._renderDPI)
            glyph.screenY = Surface.snap(gy_base * rs, self._renderDPI)

            if not glyph.style._isDynamic then
                table.insert(staticGlyphs, glyph)
            end
        end

        if line.hasRTL and ArabicText and ArabicText.contains_arabic then
            local consumed = {}
            local groups = {}
            local function is_space(g)
                return g.char == " " or g.char == "\t"
            end
            local function is_arabic_glyph(g)
                return g.char and g.char ~= "" and ArabicText.contains_arabic(g.char)
            end
            local function same_style(a, b)
                return a.style == b.style
            end
            local function add_group(glyphs)
                if #glyphs == 0 then return end
                local style = glyphs[1].style
                local outline = style.outlineThickness or self.outlineThickness or 0
                if outline <= 0 then return end
                local minX, minY = math.huge, math.huge
                local maxX, maxY = -math.huge, -math.huge
                for _, g in ipairs(glyphs) do
                    local gx = g.screenX + (g.hbXOffset or 0)
                    local gy = g.screenY + (g.hbYOffset or 0)
                    minX = math.min(minX, gx)
                    minY = math.min(minY, gy)
                    maxX = math.max(maxX, gx + math.floor(g.width * rs + 0.5))
                    -- use ascent + |descent| to ensure descenders are included
                    local descentAbs = g.descent or (g.font and select(2, FontManager.metrics(g.font)) or 0)
                    local bottom = gy + math.floor(((g.ascent or 0) + descentAbs) * rs + 0.5)
                    maxY = math.max(maxY, bottom)
                end
                groups[#groups + 1] = {
                    glyphs = glyphs,
                    style = style,
                    minX = minX,
                    minY = minY,
                    maxX = maxX,
                    maxY =
                        maxY
                }
            end

            local i = 1
            while i <= #staticGlyphs do
                if consumed[i] then
                    i = i + 1
                    goto continue_i
                end
                local g = staticGlyphs[i]
                if is_arabic_glyph(g) and not is_space(g) then
                    local run = { g }
                    consumed[i] = true
                    local j = i + 1
                    while j <= #staticGlyphs do
                        local h = staticGlyphs[j]
                        if consumed[j] or not is_arabic_glyph(h) or is_space(h) or not same_style(g, h) then break end
                        run[#run + 1] = h
                        consumed[j] = true
                        j = j + 1
                    end
                    add_group(run)
                    i = j
                else
                    i = i + 1
                end
                ::continue_i::
            end

            local rs = self._renderScale or 1
            for _, grp in ipairs(groups) do
                local style = grp.style
                local strokeColor = style.strokeColor or self.outlineColor
                local outlineThickness = style.outlineThickness or self.outlineThickness or 0
                -- Opacity is applied when the cached canvas is drawn, baking it
                -- here as well applied it twice and froze mid-fade values
                local strokeOpacity = style.strokeOpacity or 1
                local pad = math.ceil(outlineThickness * 2 + 3)
                local w = math.max(1, math.floor(((grp.maxX - grp.minX) + pad * 2) + 0.5))
                local h = math.max(1, math.floor(((grp.maxY - grp.minY) + pad * 2) + 0.5))

                local tmp = _text_new_canvas(w, h)
                _setTextureClamp(tmp)
                local prevC = Surface.capture_render_target()
                love.graphics.setCanvas(tmp)
                love.graphics.push("all")
                love.graphics.origin()
                love.graphics.setScissor()
                love.graphics.clear(0, 0, 0, 0)
                for _, gg in ipairs(grp.glyphs) do
                    local rf, printScale = self:_fontForRender(gg.font, gg.style)
                    love.graphics.setFont(rf)
                    rawset(self, "_rasterPrintScale", printScale or 1)
                    love.graphics.push()
                    love.graphics.translate((gg.screenX + (gg.hbXOffset or 0) - grp.minX) + pad,
                        (gg.screenY + (gg.hbYOffset or 0) - grp.minY) + pad)
                    local gsx, gsy = gg.style.stretchX or 1, gg.style.stretchY or 1
                    if gsx ~= 1 or gsy ~= 1 then
                        love.graphics.scale(gsx, gsy)
                    end
                    if gg.style.italic and gg.style.italicRad then
                        love.graphics.shear(-math.tan(gg.style.italicRad), 0)
                    end
                    love.graphics.setColor(1, 1, 1, 1)
                    if gg.style.bold and gg.style.boldOffsets and #gg.style.boldOffsets > 0 then
                        for _, bo in ipairs(gg.style.boldOffsets) do
                            local bx = math.floor(bo[1] * rs + 0.5)
                            local by = math.floor(bo[2] * rs + 0.5)
                            self:_printRaster(gg.char, bx, by)
                        end
                    else
                        self:_printRaster(gg.char, 0, 0)
                    end
                    love.graphics.pop()
                    gg._skipOutline = true
                end
                love.graphics.pop()
                Surface.restore_render_target(prevC)

                local offsets = style.blockOutline and getBlockyOutlineOffsets(outlineThickness)
                    or getCircularOutlineOffsets(outlineThickness)
                love.graphics.setColor(strokeColor[1], strokeColor[2], strokeColor[3], strokeOpacity)
                local baseX = grp.minX - pad
                local baseY = grp.minY - pad
                for _, off in ipairs(offsets) do
                    local ox = math.floor(off[1] * rs + 0.5)
                    local oy = math.floor(off[2] * rs + 0.5)
                    -- draw in the same (already scaled) coordinate system
                    love.graphics.draw(tmp, baseX + ox, baseY + oy)
                end
            end
        end

        for _, glyph in ipairs(staticGlyphs) do
            if glyph.isImage then
                local style = glyph.style

                if not self:isGlyphVisible(glyph) then
                    goto continue_glyph
                end

                love.graphics.push()
                local imageY = glyph.screenY - math.floor((glyph.baselineOffset or 0) * rs + 0.5)
                love.graphics.translate(glyph.screenX, imageY)

                local opacity = style.fillOpacity or 1
                love.graphics.setColor(1, 1, 1, opacity)

                local pixelFont = self:getPixelFontSetting(style)
                if pixelFont then
                    glyph.imageTexture.texture:setFilter("nearest", "nearest")
                else
                    glyph.imageTexture.texture:setFilter("linear", "linear")
                end

                local scaleX = (glyph.width * rs) /
                    (glyph.imageTexture.quad and glyph.style.image.quad.w or glyph.imageTexture.texture:getWidth())
                local scaleY = (glyph.height * rs) /
                    (glyph.imageTexture.quad and glyph.style.image.quad.h or glyph.imageTexture.texture:getHeight())
                love.graphics.scale(scaleX, scaleY)

                if glyph.imageTexture.quad then
                    love.graphics.draw(glyph.imageTexture.texture, glyph.imageTexture.quad, 0, 0)
                else
                    love.graphics.draw(glyph.imageTexture.texture, 0, 0)
                end

                love.graphics.pop()
            elseif glyph.char and glyph.char ~= "" then
                local style = glyph.style
                local font = glyph.font

                if not self:isGlyphVisible(glyph) then
                    goto continue_glyph
                end

                local drawFont, printScale = self:_fontForRender(font, style)
                love.graphics.setFont(drawFont)
                rawset(self, "_rasterPrintScale", printScale or 1)

                --[[ layout advances/metrics already include <scale=x,y> stretch;
                the glyph raster must stretch to match or the extra advance shows
                as blank gaps and the glyph rides above the shared baseline
                scaling around the glyph box top-left keeps screenX/screenY (the
                stretched-box corner) and the baseline (ascent*stretchY below it)
                exactly where layout placed them ]]
                local stretchX = style.stretchX or 1
                local stretchY = style.stretchY or 1
                local stretched = stretchX ~= 1 or stretchY ~= 1

                local fillColor = style.fillColor or self.textColor
                local strokeColor = style.strokeColor or self.outlineColor
                local outlineThickness = (glyph._skipOutline and 0) or (style.outlineThickness or self.outlineThickness)

                local fillOpacity = style.fillOpacity or 1
                local strokeOpacity = style.strokeOpacity or 1

                if style.backdrop then
                    local backdrop = style.backdrop
                    love.graphics.setColor(backdrop.color[1], backdrop.color[2], backdrop.color[3],
                        backdrop.color[4] * strokeOpacity)

                    love.graphics.push()
                    local bx = math.floor(backdrop.offset[1] * rs + 0.5)
                    local by = math.floor(backdrop.offset[2] * rs + 0.5)
                    love.graphics.translate(glyph.screenX + (glyph.hbXOffset or 0) + bx,
                        glyph.screenY + (glyph.hbYOffset or 0) + by)

                    if stretched then
                        love.graphics.scale(stretchX, stretchY)
                    end

                    if style.italic and style.italicRad then
                        love.graphics.shear(-math.tan(style.italicRad), 0)
                    end

                    if style.bold and style.boldOffsets and #style.boldOffsets > 0 then
                        for _, boldOffset in ipairs(style.boldOffsets) do
                            local bx2 = math.floor(boldOffset[1] * rs + 0.5)
                            local by2 = math.floor(boldOffset[2] * rs + 0.5)
                            self:_printRaster(glyph.char, bx2, by2)
                        end
                    else
                        self:_printRaster(glyph.char, 0, 0)
                    end

                    love.graphics.pop()
                end

                if outlineThickness > 0 then
                    love.graphics.setColor(strokeColor[1], strokeColor[2], strokeColor[3], strokeOpacity)

                    local cacheKey = tostring(math.floor(outlineThickness + 0.5)) ..
                        (style.blockOutline and "_block" or "_round")
                    if not self._outlineCache then
                        self._outlineCache = {}
                    end

                    local offsets = self._outlineCache[cacheKey]
                    if not offsets then
                        offsets = style.blockOutline and
                            getBlockyOutlineOffsets(outlineThickness) or
                            getCircularOutlineOffsets(outlineThickness)
                        self._outlineCache[cacheKey] = offsets
                    end

                    love.graphics.push()
                    love.graphics.translate(glyph.screenX + (glyph.hbXOffset or 0),
                        glyph.screenY + (glyph.hbYOffset or 0))

                    if stretched then
                        love.graphics.scale(stretchX, stretchY)
                    end

                    if style.italic and style.italicRad then
                        love.graphics.shear(-math.tan(style.italicRad), 0)
                    end

                    for _, offset in ipairs(offsets) do
                        local ox = math.floor(offset[1] * rs + 0.5)
                        local oy = math.floor(offset[2] * rs + 0.5)
                        if style.bold and style.boldOffsets and #style.boldOffsets > 0 then
                            for _, boldOffset in ipairs(style.boldOffsets) do
                                local bx = math.floor(boldOffset[1] * rs + 0.5)
                                local by = math.floor(boldOffset[2] * rs + 0.5)
                                self:_printRaster(glyph.char, bx + ox, by + oy)
                            end
                        else
                            self:_printRaster(glyph.char, ox, oy)
                        end
                    end

                    love.graphics.pop()
                end

                -- Fill with normal alpha so edges remain antialiased correctly
                love.graphics.setColor(fillColor[1], fillColor[2], fillColor[3], fillOpacity)
                love.graphics.push()
                love.graphics.translate(glyph.screenX + (glyph.hbXOffset or 0), glyph.screenY + (glyph.hbYOffset or 0))

                if stretched then
                    love.graphics.scale(stretchX, stretchY)
                end

                if style.italic and style.italicRad then
                    love.graphics.shear(-math.tan(style.italicRad), 0)
                end

                _print_char_fill_scaled(self, glyph.char, style, rs)

                love.graphics.pop()
            end

            ::continue_glyph::
        end

        -- clear any group outline flags
        for _, g in ipairs(staticGlyphs) do g._skipOutline = nil end

        local lineGap = self._lineHeightForRender or self.lineHeight or DEFAULT_LINE_HEIGHT
        y_base = y_base + line.height * lineGap
    end

    -- Pop drawing push
    love.graphics.pop()
    -- Pop the earlier push("all") that reset state for the canvas
    love.graphics.pop()
    Surface.restore_render_target(prevCanvas3)
    love.graphics.setColor(1, 1, 1, 1)

    love.graphics.setDefaultFilter(oldMinFilter, oldMagFilter)
end

function Text:prewarm(targetScale, forceFontLoad)
    local shouldForce = forceFontLoad
    if shouldForce == nil then
        shouldForce = true
    end
    self:_ensureFont(shouldForce)
    if rawget(self, "_deferredFontPath") then
        return false
    end

    local d = rawget(self, "__data")
    if Text._canUseFastLabel and Text._canUseFastLabel(self, d) then
        local needsFastBuild = rawget(self, "_fastTextDirty")
            or not rawget(self, "_fastTextObject")
        Text._warmFastText(self)
        return needsFastBuild
    end

    if self._needsReparse then
        Text.parseText(self)
        self._needsReparse = false
    end

    local scale = tonumber(targetScale) or 1
    if scale < 0.01 then scale = 0.01 end

    local needsRebuild = (not self._staticCanvas)
        or self._renderDPI ~= Surface.density()
        or (math.abs((self._renderScale or 0) - scale) > 1e-3)
        or self._rebuildNeeded
        or self._contentDirty

    if not needsRebuild then
        return false
    end

    local isFirstBuild = not self._staticCanvas
    if self.deferBuild ~= false and not _can_spend_text_rebuild_budget(isFirstBuild) then
        return false
    end

    local t0 = love.timer.getTime()
    Text.buildCanvases(self, scale)
    _spend_text_rebuild_budget(love.timer.getTime() - t0)
    rawset(self, "_lastRebuildTime", love.timer.getTime())
    rawset(self, "_rebuildNeeded", false)
    rawset(self, "_contentDirty", false)
    rawset(self, "_pendingRenderScale", nil)
    return true
end

local function _hsv_to_rgb(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then
        return v, t, p
    elseif i == 1 then
        return q, v, p
    elseif i == 2 then
        return p, v, t
    elseif i == 3 then
        return p, q, v
    elseif i == 4 then
        return t, p, v
    else
        return v, p, q
    end
end


function Text:_computeGlyphTransform(glyph, time)
    local style = glyph.style
    local fx, fy, fa, sx, sy = 0, 0, 0, 1, 1
    local originX, originY = 0, 0

    if style.wave then
        fx = math.sin(time * style.wave.frequency + glyph.x * 0.05) * style.wave.amplitude
    end
    if style.jingle then
        fa = fa + math.sin(time * style.jingle.frequency + glyph.x * 0.01) * math.rad(style.jingle.amplitude or 5)
    end
    if style.shake then
        fx = fx + math.sin(time * style.shake.frequency + glyph.x) * style.shake.amplitude
        fy = fy + math.cos(time * style.shake.frequency + glyph.x) * style.shake.amplitude
    end
    if style.loop then
        fx = fx + math.sin(time * style.loop.frequency) * style.loop.amplitude
        fy = fy + math.cos(time * style.loop.frequency) * style.loop.amplitude
    end
    if style.worm then
        fx = fx + math.sin(time * style.worm.frequency + glyph.globalIndex) * style.worm.amplitude
        fy = fy + math.cos(time * style.worm.frequency + glyph.globalIndex) * style.worm.amplitude
    end
    if style.tremble then
        local amplitude = style.tremble.amplitude or 2
        fx = fx + ((math.random() * 2) - 1) * amplitude
        fy = fy + ((math.random() * 2) - 1) * amplitude
    end
    if style.wavy then
        fa = fa + math.rad(math.sin(time * style.wavy.frequency + glyph.x * 0.1) * style.wavy.amplitude)
    end
    if style.float then
        if style.float.direction == "x" then
            fx = fx + math.sin(time * style.float.frequency) * style.float.amplitude
        else
            fy = fy + math.sin(time * style.float.frequency) * style.float.amplitude
        end
    end
    if style.rotate then
        local baseAngle = 0
        local timeAngle = 0

        if style.rotate.speed > 0 then
            baseAngle = math.rad(style.rotate.angle)
            timeAngle = time * style.rotate.speed
        elseif style.rotate.speed ~= 0 then
            baseAngle = math.rad(style.rotate.angle)
        end

        fa = fa + baseAngle + timeAngle
    end

    --[[ <scale=x,y> stretch: atlas cells are baked unstretched and shared across
    stretch values, so the stretch rides the draw transform. images are excluded:
    their layout dims (glyph.width/height) already include the stretch and the
    image draw derives its scale from those ]]
    if not glyph.isImage then
        sx = sx * (style.stretchX or 1)
        sy = sy * (style.stretchY or 1)
    end

    if fa ~= 0 then
        if glyph.atlasData then
            originX = glyph.atlasData.width * 0.5
            originY = glyph.atlasData.height * 0.5
        elseif glyph.isImage then
            originX = glyph.width * 0.5
            originY = glyph.height * 0.5
        else
            originX = glyph.width * 0.5
            originY = glyph.font and glyph.font:getHeight() * 0.5 or 0
        end
    end

    local x = (glyph.screenX or 0) + fx
    local y = (glyph.screenY or 0) + fy

    -- glyph.screenX / screenY are already in canvas pixel coordinates

    if glyph.atlasData then
        --[[ the atlas padding offset is in quad-local logical units, it scales with the
        draw so the glyph's paint origin still lands on screenX/screenY ]]
        x = x - glyph.atlasData.offsetX * sx
        y = y - glyph.atlasData.offsetY * sy
    end

    if fa ~= 0 then
        x = x + originX * sx
        y = y + originY * sy
    else
        -- for non-rotated glyphs, snap to integer device pixels in canvas space
        x = Surface.snap(x, self._renderDPI)
        y = Surface.snap(y, self._renderDPI)
    end

    return x, y, fa, sx, sy, originX, originY
end

function Text:_drawDynamicGlyphs(time)
    local glyphs = self._dynamicGlyphs
    if not glyphs or #glyphs == 0 then return end

    --[[ the shader/no-shader grouping is a pure function of the glyph list
    unless a typewriter animates visibility, cache it per glyph-list identity
    instead of reallocating both tables every animated frame ]]
    local shaderGroups, noShaderGlyphs
    local typewriter = rawget(self, "_typewriterState")
    local groups = rawget(self, "_dynGroups")
    if not typewriter and groups and groups.source == glyphs then
        shaderGroups = groups.shaderGroups
        noShaderGlyphs = groups.noShader
    else
        shaderGroups = {}
        noShaderGlyphs = {}

        for _, glyph in ipairs(glyphs) do
            if glyph and (glyph.atlasData or glyph.isImage) then
                if not self:isGlyphVisible(glyph) then
                    goto continue_grouping
                end

                if glyph.style.shader then
                    local shaderName = glyph.style.shader.name
                    if not shaderGroups[shaderName] then
                        shaderGroups[shaderName] = {}
                    end
                    table.insert(shaderGroups[shaderName], glyph)
                else
                    table.insert(noShaderGlyphs, glyph)
                end

                ::continue_grouping::
            end
        end

        if not typewriter then
            rawset(self, "_dynGroups", {
                source = glyphs,
                shaderGroups = shaderGroups,
                noShader = noShaderGlyphs,
            })
        else
            rawset(self, "_dynGroups", nil)
        end
    end

    local blendMode, alphaMode = love.graphics.getBlendMode()
    local previousShader = love.graphics.getShader()
    local currentAlphaMode = alphaMode
    local function setCanvasAlpha(usePremultiplied)
        local desired = usePremultiplied and "premultiplied" or alphaMode
        if currentAlphaMode ~= desired then
            love.graphics.setBlendMode(blendMode, desired)
            currentAlphaMode = desired
        end
    end

    for _, glyph in ipairs(noShaderGlyphs) do
        local x, y, a, sx, sy, originX, originY = self:_computeGlyphTransform(glyph, time)

        if glyph.isImage and glyph.imageTexture then
            setCanvasAlpha(false)
            local opacity = (glyph.style.fillOpacity or 1)
            love.graphics.setColor(1, 1, 1, opacity)

            local pixelFont = self:getPixelFontSetting(glyph.style)
            if pixelFont then
                glyph.imageTexture.texture:setFilter("nearest", "nearest")
            else
                glyph.imageTexture.texture:setFilter("linear", "linear")
            end

            --[[ baselineOffset is in layout units, x/y are scaled Canvas logical units ]]
            local rs = self._renderScale or 1
            love.graphics.push()
            love.graphics.translate(x, y - (glyph.baselineOffset or 0) * rs)

            if a ~= 0 then
                local centerX = glyph.width * 0.5
                local centerY = glyph.height * 0.5
                love.graphics.translate(centerX, centerY)
                love.graphics.rotate(a)
                love.graphics.translate(-centerX, -centerY)
            end
            love.graphics.scale(sx, sy)

            local scaleX = glyph.width /
                (glyph.imageTexture.quad and glyph.style.image.quad.w or glyph.imageTexture.texture:getWidth())
            local scaleY = glyph.height /
                (glyph.imageTexture.quad and glyph.style.image.quad.h or glyph.imageTexture.texture:getHeight())
            scaleX = scaleX * rs
            scaleY = scaleY * rs
            love.graphics.scale(scaleX, scaleY)

            if glyph.imageTexture.quad then
                love.graphics.draw(glyph.imageTexture.texture, glyph.imageTexture.quad, 0, 0)
            else
                love.graphics.draw(glyph.imageTexture.texture, 0, 0)
            end

            love.graphics.pop()
        elseif glyph.atlasData and self._glyphAtlasCanvas then
            setCanvasAlpha(true)
            if glyph.style.fillRainbow or glyph.style.strokeRainbow then
                local speed = (glyph.style.fillRainbow and glyph.style.fillRainbow.speed) or
                    (glyph.style.strokeRainbow and glyph.style.strokeRainbow.speed) or 1
                local hue = (time * speed + glyph.x * 0.003) % 1
                local r, g, b = _hsv_to_rgb(hue, 0.8, 1)
                local opacity = (glyph.style.fillOpacity or 1)
                love.graphics.setColor(r, g, b, opacity)
            else
                local opacity = (glyph.style.fillOpacity or 1)
                love.graphics.setColor(1, 1, 1, opacity)
            end

            love.graphics.draw(glyph.atlasData.canvas or self._glyphAtlasCanvas, glyph.atlasData.quad, x, y, a, sx, sy, originX, originY)
        end
    end

    for shaderName, shaderGlyphs in pairs(shaderGroups) do
        if #shaderGlyphs > 0 then
            local shaderData = shaderGlyphs[1].style.shader
            local shader = getShader(shaderData.code)

            if shader then
                if shaderData.params then
                    for param, value in pairs(shaderData.params) do
                        shader:send(param, value)
                    end
                end

                shader:send("time", time)

                love.graphics.setShader(shader)

                for _, glyph in ipairs(shaderGlyphs) do
                    local x, y, a, sx, sy, originX, originY = self:_computeGlyphTransform(glyph, time)

                    if glyph.isImage and glyph.imageTexture then
                        setCanvasAlpha(false)
                        local opacity = (glyph.style.fillOpacity or 1)
                        love.graphics.setColor(1, 1, 1, opacity)

                        --[[ baselineOffset is in layout units, x/y are scaled Canvas logical units ]]
                        local rs = self._renderScale or 1
                        love.graphics.push()
                        love.graphics.translate(x, y - (glyph.baselineOffset or 0) * rs)

                        if a ~= 0 then
                            local centerX = glyph.width * 0.5
                            local centerY = glyph.height * 0.5
                            love.graphics.translate(centerX, centerY)
                            love.graphics.rotate(a)
                            love.graphics.translate(-centerX, -centerY)
                        end
                        love.graphics.scale(sx, sy)

                        local scaleX = glyph.width /
                            (glyph.imageTexture.quad and glyph.style.image.quad.w or glyph.imageTexture.texture:getWidth())
                        local scaleY = glyph.height /
                            (glyph.imageTexture.quad and glyph.style.image.quad.h or glyph.imageTexture.texture:getHeight())
                        scaleX = scaleX * rs
                        scaleY = scaleY * rs
                        love.graphics.scale(scaleX, scaleY)

                        if glyph.imageTexture.quad then
                            love.graphics.draw(glyph.imageTexture.texture, glyph.imageTexture.quad, 0, 0)
                        else
                            love.graphics.draw(glyph.imageTexture.texture, 0, 0)
                        end

                        love.graphics.pop()
                    elseif glyph.atlasData then
                        setCanvasAlpha(true)
                        if glyph.style.fillRainbow or glyph.style.strokeRainbow then
                            local speed = (glyph.style.fillRainbow and glyph.style.fillRainbow.speed) or
                                (glyph.style.strokeRainbow and glyph.style.strokeRainbow.speed) or 1
                            local hue = (time * speed + glyph.x * 0.003) % 1
                            local r, g, b = _hsv_to_rgb(hue, 0.8, 1)
                            local opacity = (glyph.style.fillOpacity or 1)
                            love.graphics.setColor(r, g, b, opacity)
                        else
                            local opacity = (glyph.style.fillOpacity or 1)
                            love.graphics.setColor(1, 1, 1, opacity)
                        end

                        love.graphics.draw(glyph.atlasData.canvas or self._glyphAtlasCanvas, glyph.atlasData.quad, x, y, a, sx, sy, originX,
                            originY)
                    end
                end

                love.graphics.setShader()
            end
        end
    end

    setCanvasAlpha(false)
    love.graphics.setShader(previousShader)
end

local alignmentChart = {
    ['left'] = 0,
    ['center'] = 0.5,
    ['right'] = 1,
    ['top'] = 0,
    ['bottom'] = 1,
}

local function _text_has_markup(text)
    return type(text) == "string" and text:find(MARKUP_PATTERN) ~= nil
end

local function _text_has_non_ascii(text)
    return type(text) == "string" and text:find("[\128-\255]") ~= nil
end

-- Codepoints below U+0590 plus General Punctuation through
-- Mathematical Operators need no bidi or shaping. every glyph must come from
-- the primary font: fallback fonts can have a different baseline
local _coverage_probes = {}
local function _text_is_simple_unicode(text, font)
    if type(font) == "string" or not font or not font.hasGlyphs then return false end
    local valid = pcall(function()
        for _, codepoint in utf8.codes(text) do
            if codepoint >= 0x0590 and not (codepoint >= 0x2000 and codepoint <= 0x22FF) then error("complex") end
        end
    end)
    if not valid then return false end
    -- Font:hasGlyphs also consults attached fallbacks, so ask a
    -- fallback-free copy of the same file whether it covers the text
    local info = FontManager.get_info(font)
    local probe = font
    if info and info.fallbacks_attached then
        if not info.path then return false end
        probe = _coverage_probes[info.path]
        if probe == nil then
            local ok, created = pcall(love.graphics.newFont, info.path, 12)
            probe = ok and created or false
            _coverage_probes[info.path] = probe
        end
        if not probe then return false end
    end
    local ok, covered = pcall(probe.hasGlyphs, probe, text)
    return ok and covered == true
end

local function _text_has_line_break(text)
    return type(text) == "string" and text:find("[\r\n]") ~= nil
end

local function _text_has_word_break(text)
    return type(text) == "string" and text:find("%s") ~= nil
end

local function _font_is_ready(font)
    return font and type(font) ~= "string" and font.getWidth and font.getHeight
end

local function _fast_text_padding(self, font, width, height)
    local override = rawget(self, "_textPaddingOverride")
    if type(override) == "number" then
        return math.max(0, math.floor(override + 0.5))
    end

    local minDim = math.max(1, math.min(width or 1, height or 1))
    local ratioCap = math.floor(minDim * 0.08 + 0.5)
    local pixelCap = 32
    local cap = math.max(8, math.min(ratioCap, pixelCap))
    local padding = math.ceil(math.min(6, cap))
    local fh = (font and font.getHeight and font:getHeight()) or DEFAULT_FONT_SIZE
    local minPad = math.max(10, math.floor(fh * 0.30 + 0.5))
    if padding < minPad then padding = minPad end
    return padding
end

function Text:_invalidateFastText(key)
    if key == nil or TEXT_FAST_OBJECT_KEYS[key] then
        rawset(self, "_fastTextDirty", true)
    end
end

function Text:_canUseFastLabel(d, selection)
    d = d or rawget(self, "__data")
    if not d or d.fastText == false or d.richText == true then return false end
    if rawget(self, "_deferredFontPath") then return false end
    if rawget(self, "_typewriterState") then return false end
    if d.excerpt then return false end

    selection = selection or rawget(self, "_selection")
    if selection and selection.active then return false end

    --[[ the three feature scans are pure functions of the string, cache by
    string identity (lua interns strings, so unchanged text is one compare) ]]
    local text = tostring(d.text or "")
    local clean
    -- the flag is part of the key: the first scan can run during the base
    -- Element init, before Text:init has assigned fastUnicode
    if rawget(self, "_scanValue") == text and rawget(self, "_scanFont") == d.font and
        rawget(self, "_scanUnicode") == (d.fastUnicode == true) then
        clean = rawget(self, "_scanClean")
    else
        local non_ascii = _text_has_non_ascii(text)
        -- Opt-in (fastUnicode): simple left-to-right punctuation and Latin
        -- text the font itself covers (·, –, ×, é) needs no shaping, so it
        -- can stay on the native path instead of baking a canvas
        if non_ascii and d.fastUnicode == true and _text_is_simple_unicode(text, d.font) then non_ascii = false end
        clean = not (_text_has_markup(text) or _text_has_line_break(text) or non_ascii)
        rawset(self, "_scanValue", text)
        rawset(self, "_scanFont", d.font)
        rawset(self, "_scanUnicode", d.fastUnicode == true)
        rawset(self, "_scanClean", clean)
    end
    if not clean then return false end

    if (d.outlineThickness or 0) > 0 then return false end
    if d.bold or d.italic then return false end
    if d.weight and d.weight ~= 400 then return false end
    if (d.letterSpacing or 0) ~= 0 then return false end
    if (d.stretchX or 1) ~= 1 or (d.stretchY or 1) ~= 1 then return false end

    return _font_is_ready(d.font)
end

function Text:_ensureFastTextObject(d, eligibility_known)
    d = d or rawget(self, "__data")
    if not d or (not eligibility_known and not self:_canUseFastLabel(d)) then return nil end

    local text = tostring(d.text or "")
    local font = d.font
    local obj = rawget(self, "_fastTextObject")
    -- Fallback content generation, LÖVE itself handles native atlas growth
    local font_gen = FontManager.generation(font)
    local dirty = rawget(self, "_fastTextDirty")
        or rawget(self, "_fastTextFont") ~= font
        or rawget(self, "_fastTextValue") ~= text
        or rawget(self, "_fastTextGen") ~= font_gen

    if dirty then
        if obj and rawget(self, "_fastTextFont") == font and obj.set then
            local ok = pcall(obj.set, obj, text)
            if not ok then obj = nil end
        else
            obj = nil
        end
        if not obj then
            local ok, newObj = pcall(love.graphics.newText, font, text)
            if not ok or not newObj then return nil end
            obj = newObj
            rawset(self, "_fastTextObject", obj)
        end

        local width = (obj.getWidth and obj:getWidth()) or font:getWidth(text)
        local height = (obj.getHeight and obj:getHeight()) or ((text ~= "") and font:getHeight() or 0)
        rawset(self, "_fastTextFont", font)
        rawset(self, "_fastTextGen", font_gen)
        rawset(self, "_fastTextValue", text)
        rawset(self, "_fastTextWidth", width)
        rawset(self, "_fastTextHeight", height)
        rawset(self, "_fastTextDirty", false)
        rawset(self, "_fastTextFormattedWidth", nil)
    end

    return obj, rawget(self, "_fastTextWidth") or 0, rawget(self, "_fastTextHeight") or 0, font, text
end

function Text:_warmFastText()
    if rawget(self, "_deferredFontPath") then return false end
    return self:_ensureFastTextObject() ~= nil
end

-- Wrapping at the reference font before fitting can create extra rows that
-- remain after shrinking. Fit the font and wrapped layout together instead
local function fit_scaled_plain_text(font, text, width, height, padding, base_size)
    local font_height = font:getHeight()
    local high = math.max(1, math.floor(base_size * height / (font_height + padding * 2)))
    local function measure(size)
        local scale = size / base_size
        local available = math.max(1, width / scale - padding * 2)
        local measured, lines = font:getWrap(text, available)
        local rows = math.max(1, #lines)
        local h = font_height * (1 + (rows - 1) * font:getLineHeight())
        return (h + padding * 2) * scale <= height
            and (measured + padding * 2) * scale <= width, measured, h, rows > 1 and available or nil
    end
    local low, best = 1, 1
    while low <= high do
        local mid = math.floor((low + high) * .5)
        if measure(mid) then best = mid;low = mid + 1 else high = mid - 1 end
    end
    local _, w, h, wrap_width = measure(best)
    return best / base_size, w, h, wrap_width
end

function Text:_buildFastLabelCommand(rect, rt, d, reuse)
    d = d or rawget(self, "__data")
    local selection = rawget(self, "_selection")
    local command_version = rawget(self, "_fast_command_version") or 0
    local rect_version = rect and (rect._v or 0) or 0
    local deferred_font = rawget(self, "_deferredFontPath")
    local typewriter_state = rawget(self, "_typewriterState")
    local selection_active = selection and selection.active == true or false
    local color_r, color_g, color_b, color_a, opacity
    local dpi = Surface.density()

    if reuse
        and reuse._cache_version == command_version
        and reuse._cache_rect == rect
        and reuse._cache_rect_version == rect_version
        and reuse._cache_text == (d and d.text)
        and reuse._cache_font == (d and d.font)
        and reuse._cache_font_size == (d and d.fontSize)
        and reuse._cache_deferred_font == deferred_font
        and reuse._cache_typewriter_state == typewriter_state
        and reuse._cache_selection_active == selection_active
        and reuse._cache_dpi == dpi
        and not rawget(self, "_fastTextDirty") then
        local color = d and d.textColor
        local color_is_table = type(color) == "table"
        color_r = color_is_table and (color[1] or 1) or 1
        color_g = color_is_table and (color[2] or 1) or 1
        color_b = color_is_table and (color[3] or 1) or 1
        color_a = color_is_table and (color[4] or 1) or 1
        opacity = (rt and rt.opacity) or (d and d.opacity) or 1
        local font = d and d.font
        if reuse._cache_opacity == opacity
            and reuse._cache_color_r == color_r
            and reuse._cache_color_g == color_g
            and reuse._cache_color_b == color_b
            and reuse._cache_color_a == color_a
            and reuse._cache_font_generation == FontManager.generation(font) then
            return reuse
        end
    end

    if not self:_canUseFastLabel(d, selection) then return false end

    local obj, textW, textH, font, text = self:_ensureFastTextObject(d, true)
    if not obj then return false end

    local clayWrap = (d and d.clayWrap) or false
    local margin = clayWrap and ((d and d.clayPadding) or 0) or 0
    local contentW = math.max(1, rect.size.x - margin * 2)
    local contentH = math.max(1, rect.size.y - margin * 2)
    --[[ overflow only forces the rich path when the text could actually WRAP;
    wrapMode "none" renders single-line either way, so the fast label stays
    valid (clayWrap defaults true on desktop, which silently pushed every
    slightly-overflowing no-wrap label onto the rich path) ]]
    local scaled_wrap = d.textScaled == true and clayWrap and d.wrapMode ~= "none"
    if not scaled_wrap and (d.clayWrap or false) and d.wrapMode ~= "none" and textW > contentW and _text_has_word_break(text) then
        return false
    end
    if type(d.maxWidth) == "number" and d.maxWidth > 0 and textW > d.maxWidth and _text_has_word_break(text) then
        return false
    end

    local pad = _fast_text_padding(self, font, textW, textH)
    local scaled_fit, formatted_width
    if scaled_wrap then
        scaled_fit, textW, textH, formatted_width = fit_scaled_plain_text(font, text,
            contentW, contentH, pad, d.fontSize or DEFAULT_FONT_SIZE)
    end
    if rawget(self, "_fastTextFormattedWidth") ~= formatted_width
        or formatted_width and rawget(self, "_fastTextFormattedAlign") ~= d.textAlignX then
        if formatted_width then obj:setf(text, formatted_width, d.textAlignX or "center") else obj:set(text) end
        rawset(self, "_fastTextFormattedWidth", formatted_width)
    end
    rawset(self, "_fastTextFormattedAlign", d.textAlignX)
    if formatted_width then textW = formatted_width end
    rawset(self, "_canvasPadding", pad)
    local bounds = rawget(self, "_textBounds") or {}
    bounds.width, bounds.height = textW, textH
    rawset(self, "_textBounds", bounds)

    local baseW = math.max(1, textW + pad * 2)
    local baseH = math.max(1, textH + pad * 2)
    local fitScale = math.min(contentW / baseW, contentH / baseH)
    local textScale = (d and d.textScale) or 1
    local renderScale = scaled_fit and scaled_fit * textScale
        or (((d and d.textScaled) or false) and (fitScale * textScale) or textScale)
    local textFits = d and d.textFits
    if textFits == nil then textFits = true end
    if textFits ~= false then
        renderScale = math.min(renderScale, fitScale)
    else
        renderScale = math.min(renderScale, 1)
    end
    renderScale = math.max(0.01, renderScale)

    local scaleQuantize = d.scaleQuantize or 0
    if scaleQuantize > 0 then
        renderScale = math.max(0.01, math.floor(renderScale / scaleQuantize + 0.5) * scaleQuantize)
    end
    local scaleBakeThreshold = d.scaleBakeThreshold or 0
    if scaleBakeThreshold > 0 and math.abs(renderScale - 1) < scaleBakeThreshold then
        renderScale = 1
    end

    local fontSize = d.fontSize or DEFAULT_FONT_SIZE
    if fontSize and fontSize > 0 then
        local target = renderScale * fontSize
        local snapped = math.floor(target + 1e-6)
        if snapped < 1 then snapped = 1 end
        renderScale = snapped / fontSize
    end

    local drawW = baseW * renderScale
    local drawH = baseH * renderScale
    local alignX = alignmentChart[(d and d.textAlignX) or "center"] or 0.5
    local alignY = alignmentChart[(d and d.textAlignY) or "center"] or 0.5
    local boxX = rect.position.x + margin + (contentW - drawW) * alignX
    local boxY = rect.position.y + margin + (contentH - drawH) * alignY
    local textX = boxX + pad * renderScale
    local textY = boxY + pad * renderScale

    if color_r == nil then
        local color = d.textColor
        local color_is_table = type(color) == "table"
        color_r = color_is_table and (color[1] or 1) or 1
        color_g = color_is_table and (color[2] or 1) or 1
        color_b = color_is_table and (color[3] or 1) or 1
        color_a = color_is_table and (color[4] or 1) or 1
        opacity = (rt and rt.opacity) or (d and d.opacity) or 1
    end
    local rotation = (rt and rt.screen_rotation) or rect.rotation or 0

    --[[ reuse: the direct-draw path passes a per-element scratch table so a
    per-frame label costs zero allocations. compiled callers pass nil, their
    command tables live inside cached render lists and must stay unique ]]
    local cmd = reuse
    if cmd then
        local ccol = cmd.color
        if not ccol then
            ccol = {}
            cmd.color = ccol
        end
        ccol[1] = color_r
        ccol[2] = color_g
        ccol[3] = color_b
        ccol[4] = color_a * opacity
    else
        cmd = {
            color = {
                color_r,
                color_g,
                color_b,
                color_a * opacity
            }
        }
    end
    cmd.op = "text"
    cmd.element = self
    cmd.textObject = obj
    cmd.x = textX
    cmd.y = textY
    cmd.boxX = boxX
    cmd.boxY = boxY
    cmd.drawW = drawW
    cmd.drawH = drawH
    cmd.pad = pad
    cmd.scale = renderScale
    -- keep layout metrics on the shared base font, but rasterize the native
    -- draw at its target ppem. never repeatedly enlarge the base-size atlas
    local info = self:_getFontInfo(font)
    local baseSize = (info and info.size) or fontSize
    local renderFont = font
    local drawScale = renderScale
    if info and not info.fontRef and not info.pixel then
        local ppem = math.max(1, math.floor(baseSize * renderScale * dpi + 0.5))
        renderFont = self:obtainFont(info.path, ppem, false, 1)
        local renderInfo = self:_getFontInfo(renderFont)
        drawScale = renderScale * baseSize / (renderInfo and renderInfo.size or ppem)
    end
    if renderFont ~= font then
        local render_width = formatted_width and formatted_width * renderScale / drawScale or nil
        if rawget(self, "_fastRenderFont") ~= renderFont or rawget(self, "_fastRenderValue") ~= text
            or rawget(self, "_fastRenderWidth") ~= render_width
            or render_width and rawget(self, "_fastRenderAlign") ~= d.textAlignX
            or not rawget(self, "_fastRenderObject") then
            local render_object = love.graphics.newText(renderFont)
            if render_width then render_object:setf(text, render_width, d.textAlignX or "center") else render_object:set(text) end
            rawset(self, "_fastRenderObject", render_object)
            rawset(self, "_fastRenderFont", renderFont)
            rawset(self, "_fastRenderValue", text)
            rawset(self, "_fastRenderWidth", render_width)
            rawset(self, "_fastRenderAlign", d.textAlignX)
        end
        cmd.textObject = rawget(self, "_fastRenderObject")
    end
    cmd.drawScale = drawScale
    cmd.dpi = dpi
    cmd.rotation = rotation
    if reuse then
        reuse._cache_version = command_version
        reuse._cache_dpi = dpi
        reuse._cache_rect = rect
        reuse._cache_rect_version = rect_version
        reuse._cache_text = d.text
        reuse._cache_font = d.font
        reuse._cache_font_size = d.fontSize
        reuse._cache_font_generation = rawget(self, "_fastTextGen") or FontManager.generation(font)
        reuse._cache_deferred_font = deferred_font
        reuse._cache_typewriter_state = typewriter_state
        reuse._cache_selection_active = selection_active
        reuse._cache_opacity = opacity
        reuse._cache_color_r = color_r
        reuse._cache_color_g = color_g
        reuse._cache_color_b = color_b
        reuse._cache_color_a = color_a
    end
    return cmd
end

function Text._drawFastLabelCommand(cmd)
    if not cmd or not cmd.textObject then return false end
    local color = cmd.color or { 1, 1, 1, 1 }
    love.graphics.setColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
    local rotation = cmd.rotation or 0
    if math.abs(rotation or 0) < 1e-6 then
        love.graphics.draw(cmd.textObject, Surface.snap(cmd.x, cmd.dpi), Surface.snap(cmd.y, cmd.dpi),
            0, cmd.drawScale or cmd.scale, cmd.drawScale or cmd.scale)
    else
        local pivotX = cmd.boxX + cmd.drawW * 0.5
        local pivotY = cmd.boxY + cmd.drawH * 0.5
        love.graphics.push()
        love.graphics.translate(pivotX, pivotY)
        love.graphics.rotate(rotation)
        love.graphics.draw(cmd.textObject, -cmd.drawW * 0.5 + cmd.pad * cmd.scale,
            -cmd.drawH * 0.5 + cmd.pad * cmd.scale, 0, cmd.drawScale or cmd.scale, cmd.drawScale or cmd.scale)
        love.graphics.pop()
    end
    love.graphics.setColor(1, 1, 1, 1)
    return true
end

function Text:_drawFastLabel(rect, rt, d, content_only)
    local scratch = rawget(self, "_fastCmdScratch")
    if not scratch then
        scratch = {}
        rawset(self, "_fastCmdScratch", scratch)
    end
    local cmd = Text._buildFastLabelCommand(self, rect, rt, d, scratch)
    if not cmd then return false end
    Text._drawFastLabelCommand(cmd)

    local ch = (rt and rt.children) or (d and d.children) or {}
    for i = 1, content_only and 0 or #ch do
        Element._draw_child(ch[i], rect)
    end
    return true
end

function Text:draw(parentRect, content_only)
    local d = rawget(self, "__data")
    local rt = rawget(self, "__rt")
    if not rt then
        rt = Element._sync_runtime_all(self)
    end
    if rt and (rt.visible == false or (rt.opacity or 1) <= 0) then return end
    rawset(self, "isdrawn", true)

    local loadFontInDraw = d and d.loadFontInDraw
    if loadFontInDraw == nil then
        loadFontInDraw = true
    end
    if rawget(self, "_deferredFontPath") and loadFontInDraw then
        Text._ensureFont(self, false)
    end

    local rect = Element.get_screen_rect(self, parentRect)
    Element.draw_box(self, rect, rt, d)
    if rawget(self, "_deferredFontPath") and (not loadFontInDraw) and (not rawget(self, "_staticCanvas")) then
        --[[ nothing rendered yet (font arrives via external prewarm): keep any
        cached-canvas ancestor live so this draw runs again once it does ]]
        Element._refresh_ancestor_canvases(self, true)
        love.graphics.setColor(1, 1, 1, 1)
        local ch = (rt and rt.children) or (d and d.children) or {}
        for i = 1, content_only and 0 or #ch do
            Element._draw_child(ch[i], rect)
        end
        return
    end
    if Text._drawFastLabel(self, rect, rt, d, content_only) then
        return
    end

    -- fast labels derive these values directly from their cached data. keep
    -- the richer layout state below the early return so the common path does
    -- not allocate an unused options table or read slow-path-only fields
    local clayWrap = (d and d.clayWrap) or false
    local clayPadding = (d and d.clayPadding) or 0
    local textScaled = (d and d.textScaled) or false
    local textFits = (d and d.textFits)
    if textFits == nil then textFits = true end
    local textScale = (d and d.textScale) or 1
    local lineHeight = (d and d.lineHeight) or DEFAULT_LINE_HEIGHT
    local textAlignX = (d and d.textAlignX) or "center"
    local textAlignY = (d and d.textAlignY) or "center"
    local alignX = alignmentChart[textAlignX] or 0.5
    local alignY = alignmentChart[textAlignY] or 0.5
    local opacity = (rt and rt.opacity) or (d and d.opacity) or 1
    local excerpt = (d and d.excerpt) or false
    local fontSize = (rt and rt.fontSize) or (d and d.fontSize) or DEFAULT_FONT_SIZE
    local size     = rect.size
    local margin   = (clayWrap and clayPadding) or 0
    local contentW = math.max(1, size.x - margin * 2)
    local contentH = math.max(1, size.y - margin * 2)

    -- update layout width for clay wrapping and relayout if it changed
    if clayWrap then
        local wanted = math.max(1, math.floor(contentW + 0.5))
        if rawget(self, "_layoutWidth") ~= wanted then
            rawset(self, "_layoutWidth", wanted)
            if self._needsReparse then
                Text.parseText(self)
            else
                Text.layoutText(self)
            end
            rawset(self, "_rebuildNeeded", true)
            rawset(self, "_contentDirty", true)
            rawset(self, "_paddingDirty", true)
            Element.mark_dirty(self, "size")
        end
    else
        rawset(self, "_layoutWidth", nil)
    end

    -- ensure layout and padding are up to date for measuring
    if self._needsReparse then
        Text.parseText(self)
        self._needsReparse = false
    end
    local pad = self._canvasPadding or Text._computePadding(self)
    rawset(self, "_canvasPadding", pad)

    local safeW              = math.max(1, (self._textBounds.width or 1) + pad * 2)
    local safeH              = math.max(1, (self._textBounds.height or 1) + pad * 2)
    local widthScale         = contentW / safeW
    local heightScale        = contentH / safeH
    local fitScale           = math.min(widthScale, heightScale)

    -- compute scale and optional line height compaction in clay mode
    local renderScale
    local lineHeightOverride = nil
    rawset(self, "_lineHeightForRender", lineHeight)
    if clayWrap then
        if textScaled == false or excerpt then
            renderScale = textScale
        else
            local desired = widthScale * textScale
            local limited = heightScale * textScale
            if heightScale < widthScale then
                local comp = heightScale / widthScale
                local minLH = 0.9 -- do not over-compress for readability
                if comp >= minLH then
                    lineHeightOverride = lineHeight * comp
                    rawset(self, "_lineHeightForRender", lineHeightOverride)
                    renderScale = desired
                else
                    renderScale = limited
                end
            else
                renderScale = desired
            end

            -- if textFits is false, allow only downscaling (no upscaling beyond 1x)
            if textFits == false then
                renderScale = math.min(renderScale, 1)
            end
        end
    else
        renderScale = textScaled and (fitScale * textScale) or textScale
        -- Respect textFits in non-clay mode as well
        if textFits == false then
            renderScale = math.min(renderScale, 1)
        end
    end

    if textFits ~= false and excerpt ~= true then
        if fitScale < renderScale then
            renderScale = fitScale
        end
    end
    local appliedLineHeightOverride = rawget(self, "_appliedLineHeightOverride")
    if appliedLineHeightOverride ~= lineHeightOverride then
        rawset(self, "_lineHeightOverride", lineHeightOverride)
        rawset(self, "_lineHeightForRender", lineHeightOverride or lineHeight)
        Text.layoutText(self)
        rawset(self, "_appliedLineHeightOverride", lineHeightOverride)
        rawset(self, "_paddingDirty", true)
        rawset(self, "_canvasPadding", Text._computePadding(self))
        rawset(self, "_rebuildNeeded", true)
    end

    if self.scaleQuantize and self.scaleQuantize > 0 then
        local step = self.scaleQuantize
        renderScale = math.max(0.01, math.floor(renderScale / step + 0.5) * step)
    end
    if self.scaleBakeThreshold and self.scaleBakeThreshold > 0 then
        if math.abs(renderScale - 1) < self.scaleBakeThreshold then
            renderScale = 1
        end
    end

    -- Quantize so the effective font size (base size * scale) lands on an integer
    -- this avoids fractional raster sizes that can introduce subtle coverage patterns
    do
        local baseSize = fontSize
        if baseSize and baseSize > 0 then
            local target = renderScale * baseSize
            local snapped = math.floor(target + 1e-6)
            if snapped < 1 then snapped = 1 end
            renderScale = snapped / baseSize
        end
    end

    local targetScale = renderScale
    local staticCanvas = rawget(self, "_staticCanvas")
    local selection = rawget(self, "_selection")
    local contentDirty = rawget(self, "_contentDirty")
    local needsRebuild = (not staticCanvas)
        or rawget(self, "_renderDPI") ~= Surface.density()
        or (math.abs((rawget(self, "_renderScale") or 0) - targetScale) > 1e-3)
        or rawget(self, "_rebuildNeeded")
        or contentDirty
    local deferred = false
    if needsRebuild then
        local canDefer = d and d.deferBuild ~= false and d.deferRebuild and staticCanvas and (not contentDirty) and
            (not rawget(self, "_needsReparse"))
            and (not excerpt)
            and not (selection and selection.active)
        if canDefer then
            local now = love.timer.getTime()
            local throttle = (d and d.rebuildThrottle) or 0
            if throttle > 0 and (now - (rawget(self, "_lastRebuildTime") or 0)) < throttle then
                deferred = true
                rawset(self, "_pendingRenderScale", targetScale)
            end
        end
        if not deferred then
            local isFirstBuild = not staticCanvas
            if d.deferBuild == false or _can_spend_text_rebuild_budget(isFirstBuild) then
                local t0 = love.timer.getTime()
                Text.buildCanvases(self, targetScale)
                staticCanvas = rawget(self, "_staticCanvas")
                _spend_text_rebuild_budget(love.timer.getTime() - t0)
                rawset(self, "_lastRebuildTime", love.timer.getTime())
                rawset(self, "_rebuildNeeded", false)
                rawset(self, "_contentDirty", false)
                rawset(self, "_pendingRenderScale", nil)
                contentDirty = false
                --[[ the fresh content must reach any ancestor cached canvas
                that composites this text (it may have cached the pre-build
                emptiness) ]]
                Element._refresh_ancestor_canvases(self, false)
            else
                deferred = true
                rawset(self, "_pendingRenderScale", targetScale)
            end
        end
        if deferred then
            --[[ a deferred build only completes on a future draw, inside a
            cached-canvas ancestor this draw never runs again, so an unbuilt
            text would stay missing FOREVER. keep ancestors live until built ]]
            Element._refresh_ancestor_canvases(self, true)
        end
    end

    local textBounds = rawget(self, "_textBounds")
    local padding = rawget(self, "_canvasPadding") or 0
    local baseCanvasW = textBounds.width + padding * 2
    local baseCanvasH = textBounds.height + padding * 2

    local actualScale = rawget(self, "_renderScale") or 1
    -- Composite in Canvas logical units at matching target density. its actual
    -- logical size is the truth. Re-deriving from bounds*scale drifts when bounds or
    -- padding changed without a rebuild yet (alignment/pivot jitter)
    local canvasW, canvasH
    if staticCanvas then
        canvasW, canvasH = staticCanvas:getWidth(), staticCanvas:getHeight()
    else
        canvasW = math.max(1, math.ceil(baseCanvasW * actualScale) + 2)
        canvasH = math.max(1, math.ceil(baseCanvasH * actualScale) + 2)
    end

    local offsetX = rect.position.x + margin + (contentW - canvasW) * alignX
    local offsetY = rect.position.y + margin + (contentH - canvasH) * alignY

    offsetX = Surface.snap(offsetX)
    offsetY = Surface.snap(offsetY)
    if Text.diagnostics_enabled then
        rawset(self, "_diagnosticDrawX", offsetX)
        rawset(self, "_diagnosticDrawY", offsetY)
    end

    local pivotX = offsetX + canvasW * 0.5
    local pivotY = offsetY + canvasH * 0.5

    local rotation = (rt and rt.screen_rotation) or rect.rotation or 0

    --[[ rotated excerpts must clip in the TEXT'S local space: a screen-space
    scissor is axis-aligned, so it slices rotated glyph runs diagonally
    mid-glyph. clipping via a Quad over the static canvas is exact and rotates
    with the draw. dynamic markup / active selection keep the legacy scissor
    (their sub-draws are not quad-clippable) ]]
    local excerpt_quad = excerpt
        and math.abs(rotation or 0) >= 1e-6
        and staticCanvas ~= nil
        and not rawget(self, "_hasDynamicContent")
    if excerpt_quad then
        local sel_check = rawget(self, "_selection")
        if sel_check and sel_check.text and sel_check.active then
            excerpt_quad = false
        end
    end

    -- if excerpt mode is enabled, we clip drawing to the text's content rect
    local scissorWasSet
    local prevScissor
    if excerpt and not excerpt_quad then
        prevScissor = { love.graphics.getScissor() }
        scissorWasSet = prevScissor[1] ~= nil
        -- Clip to the interior content area in logical graphics units
        _setScissorPixels(rect.position.x + margin, rect.position.y + margin, contentW, contentH)
    end
    local drawX = -canvasW * 0.5
    local drawY = -canvasH * 0.5

    -- if there is no rotation, avoid the pivot-based path to guarantee exact pixel alignment
    if math.abs(rotation or 0) < 1e-6 then
        local dx = offsetX
        local dy = offsetY

        selection = rawget(self, "_selection")
        if selection and selection.text and selection.active then
            -- Selection painting uses the transform path, fall back to full path in that rare case
        else
            -- Simple integer-aligned draw path
            love.graphics.setColor(1, 1, 1, opacity)
            if staticCanvas then
                _draw_static_canvas(staticCanvas, dx, dy, opacity)
            end
            if rawget(self, "_hasDynamicContent") then
                love.graphics.push()
                love.graphics.translate(dx, dy)
                Text._drawDynamicGlyphs(self, love.timer.getTime())
                love.graphics.pop()
            end

            -- draw children and restore scissor if excerpt
            if excerpt then
                if scissorWasSet then
                    love.graphics.setScissor(prevScissor[1], prevScissor[2], prevScissor[3], prevScissor[4])
                else
                    love.graphics.setScissor()
                end
            end

            love.graphics.setColor(1, 1, 1, 1)
            local ch = (rt and rt.children) or (d and d.children) or {}
            for i = 1, content_only and 0 or #ch do
                Element._draw_child(ch[i], rect)
            end
            return
        end
    end

    love.graphics.push()
    love.graphics.translate(pivotX, pivotY)
    love.graphics.rotate(rotation)

    -- Maintain a horizontal view window in excerpt mode to keep caret visible
    if excerpt then
        local rs = rawget(self, "_renderScale") or 1
        local pad = rawget(self, "_canvasPadding") or 0
        local baseCanvasW = ((rawget(self, "_textBounds") or {}).width or 0) + pad * 2
        local viewWBase = contentW / rs
        local maxScroll = math.max(0, baseCanvasW - viewWBase)

        -- try to keep caret visible based on selection state from typing
        selection = rawget(self, "_selection")
        if selection and selection.text then
            local sel = selection
            -- compute caret position for no-selection case (a == b)
            local a = sel.a or 0
            local text_raw = tostring(sel.text):gsub("|", "")
            local prefix = sel.prefix or ""
            -- measure width up to caret (first line only)
            local before = text_raw:sub(1, a)
            local caretBaseX = pad + self.font:getWidth(prefix .. before)
            local marginPx = 8 -- left/right margin in base logical units
            local excerptOffset = rawget(self, "_excerpt_offset") or 0
            if caretBaseX < excerptOffset + marginPx then
                rawset(self, "_excerpt_offset", math.max(0, caretBaseX - marginPx))
            elseif caretBaseX > (excerptOffset + viewWBase - marginPx) then
                rawset(self, "_excerpt_offset", math.min(maxScroll, caretBaseX - (viewWBase - marginPx)))
            end
        end

        -- apply horizontal translation by the current scroll offset (scaled)
        -- the quad-clip path folds the offset into the quad window instead
        local scrollScaled = (rawget(self, "_excerpt_offset") or 0) * rs
        if excerpt_quad then
            rawset(self, "_excerpt_scroll_scaled", scrollScaled)
        else
            love.graphics.translate(-scrollScaled, 0)
        end
    end

    selection = rawget(self, "_selection")
    if selection and selection.text and selection.active then
        local sel = selection
        local rawText = tostring(sel.text):gsub("|", "")
        if not rawText:find("<[^>]+>") then
            local lines = {}
            for s in (rawText .. "\n"):gmatch("(.-)\n") do table.insert(lines, s) end
            if #lines == 0 then lines = { rawText } end
            local font = self.font
            local lineH = font:getHeight() * lineHeight
            local padding = rawget(self, "_canvasPadding") or 0
            local prefix = sel.prefix or ""

            love.graphics.push("all")
            love.graphics.translate(drawX, drawY)
            love.graphics.scale(rawget(self, "_renderScale") or 1, rawget(self, "_renderScale") or 1)
            love.graphics.setColor(0.2, 0.55, 1.0, 0.35)

            local offset = 0
            for i = 1, #lines do
                local line = lines[i]
                local ls = offset
                local le = offset + #line
                local sidx = math.max(ls, sel.a or 0)
                local eidx = math.max(sidx, math.min(le, sel.b or 0))
                if eidx > sidx then
                    local sb = sidx - ls -- bytes before selection in this line
                    local eb = eidx - ls -- bytes into line for end (exclusive)
                    local baseX = padding + (i == 1 and font:getWidth(prefix) or 0)
                    local x1 = baseX + (sb > 0 and font:getWidth(line:sub(1, sb)) or 0)
                    local x2 = baseX + (eb > 0 and font:getWidth(line:sub(1, eb)) or 0)
                    local w = math.max(1, x2 - x1)
                    local y = padding + (i - 1) * lineH
                    love.graphics.rectangle("fill", x1, y, w, lineH)
                end
                offset = le + 1
            end

            love.graphics.pop()
        end
    end

    love.graphics.setColor(1, 1, 1, opacity)

    staticCanvas = rawget(self, "_staticCanvas")
    if staticCanvas and excerpt_quad then
        --[[ visible window in Canvas logical units, q0x includes the
        excerpt view-window scroll, and clamping keeps the quad inside the
        texture (the clamped remainder shifts the draw position instead) ]]
        local scroll = rawget(self, "_excerpt_scroll_scaled") or 0
        local q0x = (rect.position.x + margin) - offsetX + scroll
        local q0y = (rect.position.y + margin) - offsetY
        local qx = math.max(0, q0x)
        local qy = math.max(0, q0y)
        local qw = math.min(contentW - (qx - q0x), canvasW - qx)
        local qh = math.min(contentH - (qy - q0y), canvasH - qy)
        if qw > 0 and qh > 0 then
            local quad = rawget(self, "_excerptQuad")
            if not quad
                or rawget(self, "_excerptQuadX") ~= qx or rawget(self, "_excerptQuadY") ~= qy
                or rawget(self, "_excerptQuadW") ~= qw or rawget(self, "_excerptQuadH") ~= qh
                or rawget(self, "_excerptQuadCW") ~= canvasW or rawget(self, "_excerptQuadCH") ~= canvasH then
                quad = love.graphics.newQuad(qx, qy, qw, qh, canvasW, canvasH)
                rawset(self, "_excerptQuad", quad)
                rawset(self, "_excerptQuadX", qx)
                rawset(self, "_excerptQuadY", qy)
                rawset(self, "_excerptQuadW", qw)
                rawset(self, "_excerptQuadH", qh)
                rawset(self, "_excerptQuadCW", canvasW)
                rawset(self, "_excerptQuadCH", canvasH)
            end
            local wx = drawX + (rect.position.x + margin - offsetX) + (qx - q0x)
            local wy = drawY + (rect.position.y + margin - offsetY) + (qy - q0y)
            _draw_static_canvas(staticCanvas, wx, wy, opacity, quad)
        end
    elseif staticCanvas then
        _draw_static_canvas(staticCanvas, drawX, drawY, opacity)
    end

    if rawget(self, "_hasDynamicContent") then
        love.graphics.push()
        love.graphics.translate(drawX, drawY)
        Text._drawDynamicGlyphs(self, love.timer.getTime())
        love.graphics.pop()
    end

    love.graphics.pop()
    love.graphics.setColor(1, 1, 1, 1)

    if excerpt then
        -- restore previous scissor state
        if scissorWasSet then
            love.graphics.setScissor(prevScissor[1], prevScissor[2], prevScissor[3], prevScissor[4])
        else
            love.graphics.setScissor()
        end
    end

    local ch = (rt and rt.children) or (d and d.children) or {}
    for i = 1, content_only and 0 or #ch do
        Element._draw_child(ch[i], rect)
    end
end

function Text:getScaleToFit(size)
    if self._cachedFitScale and self._lastFitSize and
        self._lastFitSize.x == size.x and self._lastFitSize.y == size.y then
        return self._cachedFitScale
    end

    local d = rawget(self, "__data")
    if Text._canUseFastLabel(self, d) then
        local obj, textWidth, textHeight, font = Text._ensureFastTextObject(self, d, true)
        if obj then
            local padding = _fast_text_padding(self, font, textWidth, textHeight)
            local safeCanvasW = math.max(textWidth + padding * 2, 1)
            local safeCanvasH = math.max(textHeight + padding * 2, 1)
            local scale = math.min(size.x / safeCanvasW, size.y / safeCanvasH)
            self._cachedFitScale = math.max(scale, 0.01)
            self._lastFitSize = { x = size.x, y = size.y }
            return self._cachedFitScale
        end
    end

    if self._needsReparse then
        self:parseText()
        self._needsReparse = false
    end

    local textWidth = self._textBounds.width
    local textHeight = self._textBounds.height
    if textWidth == 0 or textHeight == 0 then
        return 1
    end

    local padding = self._canvasPadding
    if not padding then
        padding = self:_computePadding()
        self._canvasPadding = padding
    end

    local canvasW = textWidth + padding * 2
    local canvasH = textHeight + padding * 2

    local safeCanvasW = math.max(canvasW, 1)
    local safeCanvasH = math.max(canvasH, 1)

    local scaleX = size.x / safeCanvasW
    local scaleY = size.y / safeCanvasH

    local scale = math.min(scaleX, scaleY)
    scale = math.max(scale, 0.01)

    self._cachedFitScale = scale
    self._lastFitSize = { x = size.x, y = size.y }
    return self._cachedFitScale
end

function Text:update(dt)
    Text.super.update(self, dt)

    if self._typewriterState then
        local state = self._typewriterState
        state.timer = state.timer + dt

        if state.timer >= state.speed then
            local oldGlyph = state.currentGlyph
            state.currentGlyph = math.min(state.currentGlyph + state.rate, self:getTotalGlyphCount())
            state.timer = 0

            if state.onCharacter then
                for i = oldGlyph + 1, state.currentGlyph do
                    local glyph = self:getGlyphByIndex(i)
                    if glyph then
                        state.onCharacter(glyph, i)
                    end
                end
            end

            if state.currentGlyph >= self:getTotalGlyphCount() then
                if state.onComplete then state.onComplete() end
                self._typewriterState = nil
            end
        end
    end
end

function Text:mark_dirty(key)
    rawset(self, "_fast_command_version", (rawget(self, "_fast_command_version") or 0) + 1)
    local content_key = key and TEXT_CONTENT_KEYS[key]
    local was_content_dirty = rawget(self, "_contentDirty")
    local needs_base = true
    Text._invalidateFastText(self, key)
    if content_key and was_content_dirty and rawget(self, "_rebuildNeeded") then
        needs_base = false
    end

    if needs_base then
        Element.mark_dirty(self, key)
    else
        rawset(self, "isdrawn", false)
    end

    if content_key then
        if not was_content_dirty then
            rawset(self, "_contentDirty", true)
            rawset(self, "_needsReparse", true)
            rawset(self, "_cachedFitScale", nil)
            rawset(self, "_lastFitSize", nil)
            rawset(self, "_rebuildNeeded", true)
            rawset(self, "_paddingDirty", true)
        end
        if key == "font" or key == "fontPath" or key == "fontSize" then
            rawset(self, "_scaledFontCache", nil)
        end
        Text._warmFastText(self)
    end
end

-- Graphics-reset override: updateMode wipes every Canvas's GPU contents, and Text draws from
-- its OWN baked canvases (separate from Element._canvas and not governed by _canvas_dirty), so
-- on a display/resolution change those must be dropped and the rebuild forced -- else the
-- wiped _staticCanvas draws blank/stale. Dropping _staticCanvas + setting _rebuildNeeded/
-- _contentDirty makes needsRebuild (the draw-time gate) true so it repaints next draw, the
-- secondary caches are wiped too. Element base handles _canvas + child recursion
function Text:invalidate_graphics_reset()
    rawset(self, "_staticCanvas", nil)
    rawset(self, "_glyphAtlasCanvas", nil)
    rawset(self, "_spriteBatch", nil)
    rawset(self, "_dynGroups", nil)
    rawset(self, "_glyphAtlas", nil)
    rawset(self, "_glyphAtlasPages", nil)
    for _, glyph in ipairs(rawget(self, "_dynamicGlyphs") or {}) do glyph.atlasData = nil end
    rawset(self, "_glyphTextures", {})
    rawset(self, "_fastTextObject", nil)
    rawset(self, "_fastTextDirty", true)
    rawset(self, "_fastRenderObject", nil)
    rawset(self, "_excerptQuad", nil)
    rawset(self, "_renderDPI", nil)
    rawset(self, "_renderScale", nil)
    rawset(self, "_rebuildNeeded", true)
    rawset(self, "_contentDirty", true)
    Element.invalidate_graphics_reset(self)
end

function Text:setText(text, overwrite)
    if self.text == text then
        if overwrite then self:mark_dirty("text") end
        return
    end
    self.text = text
end

function Text:on_property_changed(k, old, v)
    if k == "doubleClickEditable" then
        if v == true and self.mousecheck ~= true then
            self._double_click_auto_mousecheck = true
            self.mousecheck = true
        elseif v ~= true and self._double_click_auto_mousecheck then
            self._double_click_auto_mousecheck = nil
            self.mousecheck = false
        end
    end
    if TEXT_CONTENT_KEYS[k] then
        Text._invalidateFastText(self, k)
        rawset(self, "_needsReparse", true)
        rawset(self, "_rebuildNeeded", true)
        rawset(self, "_contentDirty", true)
        rawset(self, "_paddingDirty", true)
    end
end

function Text:getTextBounds()
    local d = rawget(self, "__data")
    if Text._canUseFastLabel(self, d) then
        local obj, textWidth, textHeight = Text._ensureFastTextObject(self, d, true)
        if obj then
            return vec2(textWidth, textHeight)
        end
    end

    if self._needsReparse then
        self:parseText()
    end
    return vec2(self._textBounds.width, self._textBounds.height)
end

-- development-only inspection: no allocations/readback in normal draw calls
function Text:getRenderDiagnostics()
    local lg = love.graphics
    local function texture(t)
        if not t then return nil end
        return {logical = {t:getDimensions()}, pixels = {t:getPixelDimensions()},
            dpi = t:getDPIScale(), filter = {t:getFilter()}}
    end
    local cmd = rawget(self, "_fastCmdScratch")
    local f = (cmd and cmd.textObject and cmd.textObject:getFont()) or self:_fontForRender(self.font)
    local info = FontManager.get_info(f) or {}
    local quads = {}
    for _, g in ipairs(rawget(self, "_dynamicGlyphs") or {}) do
        if g.atlasData then
            quads[#quads + 1] = {char = g.char, viewport = {g.atlasData.quad:getViewport()},
                textureDimensions = {g.atlasData.quad:getTextureDimensions()},
                position = {g.screenX, g.screenY}}
        end
    end
    return {windowLogical = {lg.getDimensions()}, framebufferPixels = {lg.getPixelDimensions()},
        graphicsDPI = lg.getDPIScale(), windowDPI = love.window.getDPIScale(),
        target = texture(lg.getCanvas()), static = texture(self._staticCanvas),
        atlas = texture(self._glyphAtlasCanvas), quads = quads,
        font = {layoutRequestedSize = self.fontSize, requestedSize = info.requested_size, actualSize = info.size,
            dpi = f:getDPIScale(), filter = {f:getFilter()}, generation = FontManager.generation(f),
            remediation = info.stripe_verdict}, requestedScale = self.textScale,
        bakedScale = cmd and cmd.textObject and cmd.scale or self._renderScale,
        bakedDPI = cmd and cmd.textObject and cmd.dpi or self._renderDPI,
        finalPosition = cmd and cmd.textObject and {Surface.snap(cmd.x,cmd.dpi), Surface.snap(cmd.y,cmd.dpi)}
            or {rawget(self, "_diagnosticDrawX"), rawget(self, "_diagnosticDrawY")},
        finalScale = cmd and cmd.drawScale or 1}
end

function Text:play(animationType, options)
    options = options or {}

    if animationType == "typewriter" then
        self._typewriterState = {
            currentGlyph = 0,
            speed = options.speed or 0.05,
            timer = 0,
            onComplete = options.onComplete,
            onCharacter = options.onCharacter,
            rate = options.rate or 1
        }

        self:mark_dirty()
    end
end

function Text:isGlyphVisible(glyph)
    if not self._typewriterState then return true end
    return glyph.globalIndex <= self._typewriterState.currentGlyph
end

function Text:getTotalGlyphCount()
    local total = 0
    for _, line in ipairs(self._lines) do
        total = total + #line.glyphs
    end
    return total
end

function Text:getGlyphByIndex(index)
    for _, line in ipairs(self._lines) do
        for _, glyph in ipairs(line.glyphs) do
            if glyph.globalIndex == index then
                return glyph
            end
        end
    end
    return nil
end

function Text:reset()
    self._typewriterState = nil
    self:mark_dirty()
end

function Text:isTypewriterActive()
    return self._typewriterState ~= nil
end
