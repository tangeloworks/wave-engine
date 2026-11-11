local utf8 = require("utf8")

local M = {}

local hb_ok, hb = pcall(require, "harfbuzz")
if not hb_ok or not hb then
    hb_ok, hb = pcall(require, "hb")
end
if not hb_ok or not hb then
    hb_ok, hb = pcall(require, "luaharfbuzz")
end

local function has_harfbuzz()
    return hb_ok and hb ~= nil
end

function M.is_available()
    return has_harfbuzz()
end

local RTL_RANGES = {
    { 0x0600, 0x06FF }, -- Arabic
    { 0x0750, 0x077F }, -- Arabic Supplement
    { 0x08A0, 0x08FF }, -- Arabic Extended-A
    { 0xFB50, 0xFDFF }, -- Arabic Presentation Forms-A
    { 0xFE70, 0xFEFF }, -- Arabic Presentation Forms-B
}

local function is_rtl_cp(cp)
    for _, r in ipairs(RTL_RANGES) do
        if cp >= r[1] and cp <= r[2] then return true end
    end
    return false
end

function M.contains_arabic(text)
    for _, cp in utf8.codes(text or "") do
        if (cp >= 0x0600 and cp <= 0x06FF) or (cp >= 0x0750 and cp <= 0x077F) or (cp >= 0x08A0 and cp <= 0x08FF)
            or (cp >= 0xFB50 and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF) then
            return true
        end
    end
    return false
end

function M.get_joined_word_boundaries(text)
    local bounds, start, pos, inWord = {}, nil, 1, false
    for _, cp in utf8.codes(text or "") do
        local joining = is_rtl_cp(cp)
        if joining and not inWord then start, inWord = pos, true end
        local isSpace = (cp == 0x20 or cp == 0x09 or cp == 0x0A or cp == 0x0D)
        if (not joining or isSpace) and inWord then
            bounds[#bounds + 1] = { start = start, stop = pos - 1 }
            inWord, start = false, nil
        end
        pos = pos + utf8.len(utf8.char(cp))
    end
    if inWord then bounds[#bounds + 1] = { start = start, stop = pos - 1 } end
    return bounds
end

function M.shape_text(text, font_path, font_size, opts)
    if not has_harfbuzz() then return text end

    local ok, blob = pcall(hb.Blob.from_file, font_path or "")
    if not ok or not blob then return text end
    local face = hb.Face.new(blob, 0)
    local font = hb.Font.new(face)
    if font_size and font.set_scale then
        font:set_scale(font_size * 64, font_size * 64)
    end

    local buf = hb.Buffer.new()
    buf:add_utf8(text)
    buf:guess_segment_properties()

    hb.shape(font, buf, {})

    local infos = buf:get_glyph_infos()
    local out = {}
    local all_ok = true
    for i = 1, #infos do
        local g = infos[i]
        local name = font.get_glyph_name and font:get_glyph_name(g.codepoint) or nil
        local cp
        if name and name:match("^uni[%x][%x][%x][%x]") then
            local hex = name:match("^uni([%x][%x][%x][%x])")
            if hex then cp = tonumber(hex, 16) end
        elseif name and name:match("^u[%x]+$") then
            local hex = name:match("^u([%x]+)$")
            if hex then cp = tonumber(hex, 16) end
        end
        if cp then
            out[#out + 1] = utf8.char(cp)
        else
            all_ok = false
            break
        end
    end

    if all_ok and #out > 0 then
        return table.concat(out)
    end
    return text
end

function M.shape_positions(text, font_path, font_size)
    if not has_harfbuzz() then return nil end
    if not text or text == "" then return {} end

    local ok, blob = pcall(hb.Blob.from_file, font_path or "")
    if not ok or not blob then return nil end
    local face = hb.Face.new(blob, 0)
    local font = hb.Font.new(face)
    if font_size and font.set_scale then
        font:set_scale(font_size * 64, font_size * 64)
    end

    local buf = hb.Buffer.new()
    buf:add_utf8(text)
    buf:guess_segment_properties()

    hb.shape(font, buf, {})

    local infos = buf:get_glyph_infos()
    local poss = buf:get_glyph_positions()
    if not infos or not poss or #infos ~= #poss then return nil end

    local function name_to_cp(name)
        if not name then return nil end
        local hex = name:match("^uni([%x][%x][%x][%x])$")
        if not hex then hex = name:match("^u([%x]+)$") end
        if hex then return tonumber(hex, 16) end
        return nil
    end

    local function cp_at_byte(str, byte_index)
        local i = 1
        for _, cp in utf8.codes(str) do
            if i - 1 == byte_index then return cp end
            i = i + #utf8.char(cp)
        end
        return nil
    end

    local out = {}
    for i = 1, #infos do
        local info = infos[i]
        local pos = poss[i]
        local name = font.get_glyph_name and font:get_glyph_name(info.codepoint) or nil
        local cp = name_to_cp(name)
        if not cp then
            cp = cp_at_byte(text, info.cluster) or 0x20 -- fallback to space
        end
        local ch = utf8.char(cp)
        out[#out + 1] = {
            char = ch,
            x_advance = (pos.x_advance or 0) / 64.0,
            y_advance = (pos.y_advance or 0) / 64.0,
            x_offset = (pos.x_offset or 0) / 64.0,
            y_offset = -((pos.y_offset or 0) / 64.0), -- invert to screen coords
        }
    end

    return out
end

return M
