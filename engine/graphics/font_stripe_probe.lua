--[[ look for gaps or faint bands inside a rasterized glyph
probe(font, size) returns a hole count, or nil if the check could not run ]]

local Probe = {}
local Lattice = require("engine/graphics/font_lattice_probe")

Probe.ROW_STRING = "HIMNLEBbdklt1078"
Probe.COL_GLYPHS = { "M", "H", "E", "8" }

local DIP_RATIO = 0.45
local MINIMA_RATIO = 0.72
local INK_ALPHA = 0.1

--[[ coverage -> PERCEIVED ink. the engine renders gamma-correct: dark text on
a light background displays a pixel of coverage a at luminance ~(1-a)^(1/2.2),
so an alpha dip to 0.55, invisible in linear mass (ratio ~0.85), reads as a
~70%-white line through the glyph (Bubbly@28's lattice). measuring perceived
ink makes the detector see what the eye sees in the worst case ]]
local function perceived_ink(a)
    return 1 - math.pow(1 - a, 0.4545)
end

local PROBE_W, PROBE_H = 768, 288
local canvas = nil

--[[ zero-lines + dim dips + aggregated mild minima over a mass band ]]
local function band_holes(mass, i0, i1)
    local maxMass = 0
    for i = i0, i1 do
        local m = mass[i] or 0
        if m > maxMass then maxMass = m end
    end
    if maxMass <= 0 then return 0 end
    --[[ the ink extent is anchored on SUBSTANTIAL lines (>=5% of peak): a few
    dust/fringe pixels far from the glyphs must not stretch the extent across
    a legitimately empty region (e.g. the ascent gap between a ramp row's
    print origin and its glyph tops) and turn it into "interior holes" ]]
    local floor_mass = maxMass * 0.05
    local minI, maxI
    for i = i0, i1 do
        if (mass[i] or 0) > floor_mass then
            if not minI then minI = i end
            maxI = i
        end
    end
    if not minI then return 0 end
    local strong = maxMass * 0.25
    local holes, minima = 0, 0
    for i = minI + 1, maxI - 1 do
        local m = mass[i] or 0
        local up, dn = mass[i - 1] or 0, mass[i + 1] or 0
        if m == 0 then
            holes = holes + 1
        elseif up > strong and dn > strong and m < DIP_RATIO * math.min(up, dn) then
            holes = holes + 1
        elseif up > m and dn > m and m < MINIMA_RATIO * math.min(up, dn) then
            minima = minima + 1
        end
    end
    --[[ checker dither oscillates every other line (~half the band is a
    minimum), smooth AA rasters wobble by 2-3 mild minima at large sizes ,
    scale the trigger with band height so those never count ]]
    if minima >= math.max(3, math.floor((maxI - minI) * 0.12)) then
        holes = holes + minima
    end
    return holes
end

Probe.band_holes = band_holes

function Probe.probe(font, size)
    if not font or type(size) ~= "number" then return nil end
    if not canvas then
        -- this is a pixel-readback instrument, not a UI surface. its ranges
        -- index ImageData pixels, so one probe unit MUST be one backing texel
        local ok, cv = pcall(love.graphics.newCanvas, PROBE_W, PROBE_H, {dpiscale = 1})
        if not ok or not cv then return nil end
        canvas = cv
    end

    local band2_y = math.min(PROBE_H - 8, math.floor(size * 1.45) + 6)
    local row_w = PROBE_W
    local glyph_ranges = {}
    love.graphics.push("all")
    local ok = pcall(function()
        love.graphics.origin()
        love.graphics.setScissor()
        love.graphics.setCanvas(canvas)
        love.graphics.setShader()
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setBlendMode("alpha", "alphamultiply")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setFont(font)
        love.graphics.print(Probe.ROW_STRING, 2, 2)
        row_w = math.min(PROBE_W, font:getWidth(Probe.ROW_STRING) + 8)
        local x = 2
        for _, g in ipairs(Probe.COL_GLYPHS) do
            local gw = font:getWidth(g)
            glyph_ranges[#glyph_ranges + 1] = { x0 = math.max(0, x - 1), x1 = math.min(PROBE_W - 1, x + gw + 1) }
            love.graphics.print(g, x, band2_y)
            x = x + gw + 16
        end
        love.graphics.setCanvas()
    end)
    -- also restore the stack after a rasterization error
    love.graphics.pop()
    if not ok then return nil end

    local ok2, idata = pcall(canvas.newImageData, canvas)
    if not ok2 or not idata then return nil end

    local holes = 0
    do
        --[[ rows over the probe string, the ink map doubles as input for the
        checkerboard detector below ]]
        local ink = {}
        local mass = {}
        for y = 0, band2_y - 2 do
            local m = 0
            local row = {}
            for x = 0, row_w - 1 do
                local _, _, _, a = idata:getPixel(x, y)
                if a > INK_ALPHA then
                    m = m + perceived_ink(a)
                    row[x] = true
                end
            end
            ink[y] = row
            mass[y] = m
        end
        holes = holes + band_holes(mass, 0, band2_y - 2)

        --[[ checkerboard dither is INVISIBLE to row/column mass profiles
        (every line is ~50% filled, masses are flat): detect it structurally
        in a checkered raster nearly every ink pixel has 3-4 empty orthogonal
        neighbours, in solid glyphs only rare AA corners do ]]
        local ink_count, isolated = 0, 0
        for y = 1, band2_y - 3 do
            local row = ink[y]
            if row then
                for x = 1, row_w - 2 do
                    if row[x] then
                        ink_count = ink_count + 1
                        local empty = 0
                        if not row[x - 1] then empty = empty + 1 end
                        if not row[x + 1] then empty = empty + 1 end
                        if not (ink[y - 1] and ink[y - 1][x]) then empty = empty + 1 end
                        if not (ink[y + 1] and ink[y + 1][x]) then empty = empty + 1 end
                        if empty >= 3 then isolated = isolated + 1 end
                    end
                end
            end
        end
        if ink_count >= 50 and isolated / ink_count > 0.3 then
            holes = holes + math.max(10, math.floor(isolated / 10))
        end
    end
    do
        --[[ per-glyph column masses: a hairline inside one glyph must not be
        diluted by the others ]]
        local y1 = math.min(PROBE_H - 1, band2_y + math.floor(size * 1.4))
        for _, r in ipairs(glyph_ranges) do
            local mass = {}
            for x = r.x0, r.x1 do
                local m = 0
                for y = band2_y, y1 do
                    local _, _, _, a = idata:getPixel(x, y)
                    if a > INK_ALPHA then m = m + perceived_ink(a) end
                end
                mass[x] = m
            end
            holes = holes + band_holes(mass, r.x0, r.x1)
            -- local seams can be sparse (every 5-8 pixels) and only dim one
            -- stroke. Word mass / a 12%-of-width minima threshold miss them
            holes = holes + Lattice.scan(idata,r.x0,band2_y,r.x1-r.x0+1,y1-band2_y+1)
        end
    end
    return holes
end

return Probe
