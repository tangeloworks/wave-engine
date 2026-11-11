-- choose joining forms in logical order while both neighbors are available
-- the Text renderer handles visual order after wrapping
local utf8 = require("utf8")

local HarfBuzzText
do
    local ok, hb = pcall(require, "engine/services/harfbuzz_text")
    if ok and hb then
        HarfBuzzText = hb
    else
        HarfBuzzText = {
            is_available = function() return false end,
            contains_arabic = function() return false end,
            shape_text = function(text) return text end,
            get_joined_word_boundaries = function() return {} end,
        }
    end
end

local ArabicText = {}
ArabicText.REMOVE_DIACRITICS = true
ArabicText.NORMALIZE_TO_PERSIAN = false
ArabicText.USE_HB_POSITIONS = false
ArabicText.AUTO_FARSI_YEH = true
ArabicText.NORMALIZE_ALEF_WASLA = true

local ARABIC_RANGES = {
    { 0x0600, 0x06FF }, -- Arabic
    { 0x0750, 0x077F }, -- Arabic Supplement
    { 0x08A0, 0x08FF }, -- Arabic Extended-A
    { 0xFB50, 0xFDFF }, -- Arabic Presentation Forms-A
    { 0xFE70, 0xFEFF }, -- Arabic Presentation Forms-B
}

local JOINING_TYPES = {
    RIGHT = 1,       -- accepts a connection from the previous logical letter
    LEFT = 2,        -- Connects to the following logical letter
    DUAL = 3,        -- can join to both sides (has all 4 forms)
    NON_JOINING = 4, -- Cannot join (always isolated)
    TRANSPARENT = 5, -- Transparent to joining (diacritics)
}

local LAM_ALIF_LIGATURES = {
    -- Lam + Alef
    [0x0644] = {
        [0x0627] = 0xFEFB, -- Lam + Alef = Lam-Alef isolated
        [0x0622] = 0xFEF5, -- Lam + Alef with Madda = Lam-Alef with Madda isolated
        [0x0623] = 0xFEF7, -- Lam + Alef with Hamza above = Lam-Alef with Hamza above isolated
        [0x0625] = 0xFEF9, -- Lam + Alef with Hamza below = Lam-Alef with Hamza below isolated
    }
}

local LAM_ALIF_LIGATURES_FINAL = {
    [0x0644] = {
        [0x0627] = 0xFEFC, -- Lam + Alef = Lam-Alef final
        [0x0622] = 0xFEF6, -- Lam + Alef with Madda = Lam-Alef with Madda final
        [0x0623] = 0xFEF8, -- Lam + Alef with Hamza above = Lam-Alef with Hamza above final
        [0x0625] = 0xFEFA, -- Lam + Alef with Hamza below = Lam-Alef with Hamza below final
    }
}

local ARABIC_CHARS = {
    -- letter Alef
    [0x0627] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0627,
        final = 0xFE8E,
    },
    -- letter Beh
    [0x0628] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0628,
        initial = 0xFE91,
        medial = 0xFE92,
        final = 0xFE90,
    },
    -- letter Teh Marbuta
    [0x0629] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0629,
        final = 0xFE94,
    },
    -- letter Teh
    [0x062A] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x062A,
        initial = 0xFE97,
        medial = 0xFE98,
        final = 0xFE96,
    },
    -- letter Theh
    [0x062B] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x062B,
        initial = 0xFE9B,
        medial = 0xFE9C,
        final = 0xFE9A,
    },
    -- letter Jeem
    [0x062C] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x062C,
        initial = 0xFE9F,
        medial = 0xFEA0,
        final = 0xFE9E,
    },
    -- letter Hah
    [0x062D] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x062D,
        initial = 0xFEA3,
        medial = 0xFEA4,
        final = 0xFEA2,
    },
    -- letter Khah
    [0x062E] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x062E,
        initial = 0xFEA7,
        medial = 0xFEA8,
        final = 0xFEA6,
    },
    -- letter Dal
    [0x062F] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x062F,
        final = 0xFEAA,
    },
    -- letter Thal
    [0x0630] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0630,
        final = 0xFEAC,
    },
    -- letter Reh
    [0x0631] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0631,
        final = 0xFEAE,
    },
    -- letter Zain
    [0x0632] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0632,
        final = 0xFEB0,
    },
    -- letter Seen
    [0x0633] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0633,
        initial = 0xFEB3,
        medial = 0xFEB4,
        final = 0xFEB2,
    },
    -- letter Sheen
    [0x0634] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0634,
        initial = 0xFEB7,
        medial = 0xFEB8,
        final = 0xFEB6,
    },
    -- letter Sad
    [0x0635] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0635,
        initial = 0xFEBB,
        medial = 0xFEBC,
        final = 0xFEBA,
    },
    -- letter Dad
    [0x0636] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0636,
        initial = 0xFEBF,
        medial = 0xFEC0,
        final = 0xFEBE,
    },
    -- letter Tah
    [0x0637] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0637,
        initial = 0xFEC3,
        medial = 0xFEC4,
        final = 0xFEC2,
    },
    -- letter Zah
    [0x0638] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0638,
        initial = 0xFEC7,
        medial = 0xFEC8,
        final = 0xFEC6,
    },
    -- letter Ain
    [0x0639] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0639,
        initial = 0xFECB,
        medial = 0xFECC,
        final = 0xFECA,
    },
    -- letter Ghain
    [0x063A] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x063A,
        initial = 0xFECF,
        medial = 0xFED0,
        final = 0xFECE,
    },
    -- letter Feh
    [0x0641] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0641,
        initial = 0xFED3,
        medial = 0xFED4,
        final = 0xFED2,
    },
    -- letter Qaf
    [0x0642] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0642,
        initial = 0xFED7,
        medial = 0xFED8,
        final = 0xFED6,
    },
    -- letter Kaf
    [0x0643] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0643,
        initial = 0xFEDB,
        medial = 0xFEDC,
        final = 0xFEDA,
    },
    -- letter Lam
    [0x0644] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0644,
        initial = 0xFEDF,
        medial = 0xFEE0,
        final = 0xFEDE,
    },
    -- letter Meem
    [0x0645] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0645,
        initial = 0xFEE3,
        medial = 0xFEE4,
        final = 0xFEE2,
    },
    -- letter Noon
    [0x0646] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0646,
        initial = 0xFEE7,
        medial = 0xFEE8,
        final = 0xFEE6,
    },
    -- letter Heh
    [0x0647] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0647,
        initial = 0xFEEB,
        medial = 0xFEEC,
        final = 0xFEEA,
    },
    -- letter Waw
    [0x0648] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0648,
        final = 0xFEEE,
    },
    -- letter Alef Maqsura (U+0649)
    [0x0649] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0xFBE8,
        final = 0xFBE9,
    },
    -- letter Yeh
    [0x064A] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0xFEF1,
        initial = 0xFEF3,
        medial = 0xFEF4,
        final = 0xFEF2,
    },
    -- letter Alef with Hamza Above
    [0x0623] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0623,
        final = 0xFE84,
    },
    -- letter Waw with Hamza Above.  it is right-joining like Waw, rather
    -- than an isolated punctuation mark.  keeping this in the shared table
    -- lets the deterministic fallback agree with the Arabic font's GSUB
    -- shaping when HarfBuzz is unavailable
    [0x0624] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0xFE85,
        final = 0xFE86,
    },
    -- letter Alef with Hamza Below
    [0x0625] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0625,
        final = 0xFE88,
    },
    -- letter Yeh with Hamza Above (ئ).  this is dual-joining, not a bare
    -- Hamza.  without all four presentation forms here, words such as
    -- "الفائز" split the ئ from the following letter whenever the portable
    -- fallback shaper is used
    [0x0626] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0xFE89,
        final = 0xFE8A,
        initial = 0xFE8B,
        medial = 0xFE8C,
    },
    -- letter Alef with Madda Above
    [0x0622] = {
        type = JOINING_TYPES.RIGHT,
        isolated = 0x0622,
        final = 0xFE82,
    },
    -- letter Hamza
    [0x0621] = {
        type = JOINING_TYPES.NON_JOINING,
        isolated = 0x0621,
    },
    -- letter Tatweel (Arabic Kashida)
    [0x0640] = {
        type = JOINING_TYPES.DUAL,
        isolated = 0x0640,
        initial = 0x0640,
        medial = 0x0640,
        final = 0x0640,
    },

    -- Persian/Farsi specific characters
    [0x067E] = { -- Peh
        type = JOINING_TYPES.DUAL,
        isolated = 0x067E,
        initial = 0xFB58,
        medial = 0xFB59,
        final = 0xFB57,
    },
    [0x0686] = { -- Tcheh
        type = JOINING_TYPES.DUAL,
        isolated = 0x0686,
        initial = 0xFB7C,
        medial = 0xFB7D,
        final = 0xFB7B,
    },
    [0x06AF] = { -- Gaf
        type = JOINING_TYPES.DUAL,
        isolated = 0x06AF,
        initial = 0xFB94,
        medial = 0xFB95,
        final = 0xFB93,
    },
    [0x06A9] = { -- Keheh
        type = JOINING_TYPES.DUAL,
        isolated = 0x06A9,
        initial = 0xFB90,
        medial = 0xFB91,
        final = 0xFB8F,
    },
    [0x06CC] = { -- Farsi Yeh
        type = JOINING_TYPES.DUAL,
        isolated = 0xFBFC,
        initial = 0xFBFE,
        medial = 0xFBFF,
        final = 0xFBFD,
    },
}
-- a lam-alef ligature accepts the preceding letter's stroke on its right,
-- but its alef cannot connect to the following logical letter on its left
local LAM_ALEF_FINAL_RIGHT = JOINING_TYPES.RIGHT

ARABIC_CHARS[0xFEFC] = {                       -- ل + ا
    type = LAM_ALEF_FINAL_RIGHT,
    isolated = 0xFEFC,                         -- we never re-shape it further
}

ARABIC_CHARS[0xFEF6] = { type = LAM_ALEF_FINAL_RIGHT, isolated = 0xFEF6 } -- ل + آ
ARABIC_CHARS[0xFEF8] = { type = LAM_ALEF_FINAL_RIGHT, isolated = 0xFEF8 } -- ل + أ
ARABIC_CHARS[0xFEFA] = { type = LAM_ALEF_FINAL_RIGHT, isolated = 0xFEFA } -- ل + إ


local ARABIC_DIACRITICS = {
    [0x064B] = true, -- Fathatan
    [0x064C] = true, -- Dammatan
    [0x064D] = true, -- Kasratan
    [0x064E] = true, -- Fatha
    [0x064F] = true, -- Damma
    [0x0650] = true, -- Kasra
    [0x0651] = true, -- Shadda
    [0x0652] = true, -- Sukun
    [0x0653] = true, -- Maddah
    [0x0654] = true, -- Hamza Above
    [0x0655] = true, -- Hamza Below
    [0x0656] = true, -- Subscript Alef
    [0x0657] = true, -- Inverted Damma
    [0x0658] = true, -- mark Noon Ghunna
    [0x0659] = true, -- Zwarakay
    [0x065A] = true, -- Vowel Sign Small V Above
    [0x065B] = true, -- Vowel Sign Inverted Small V Above
    [0x065C] = true, -- Vowel Sign Dot Below
    [0x065D] = true, -- Reversed Damma
    [0x065E] = true, -- Fatha With Two Dots
    [0x065F] = true, -- Wavy Hamza Below
    [0x0670] = true, -- Superscript Alef
}

----------------------------------------------------------------
-- helpers -----------------------------------------------------
----------------------------------------------------------------
local function is_whitespace(cp)
    return cp == 0x20 or cp == 0x09 or cp == 0x0A or cp == 0x0D
end

local function is_arabic(cp)
    for _, r in ipairs(ARABIC_RANGES) do
        if cp >= r[1] and cp <= r[2] then return true end
    end
    return false
end

local function is_arabic_presentation_form(cp)
    return (cp >= 0xFB50 and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF)
end

local function text_contains_arabic(text)
    if type(text) ~= "string" or text == "" then return false end
    for _, cp in utf8.codes(text) do
        if is_arabic(cp) or is_arabic_presentation_form(cp) or ARABIC_DIACRITICS[cp] then return true end
    end
    return false
end

local function is_rtl_codepoint(cp)
    return is_arabic(cp) or ARABIC_DIACRITICS[cp] or is_arabic_presentation_form(cp)
end

local function to_codepoints(text)
    local arr = {}
    for _, cp in utf8.codes(text) do arr[#arr + 1] = cp end
    return arr
end

local function from_codepoints(arr)
    local t = {}
    for i = 1, #arr do t[i] = utf8.char(arr[i]) end
    return table.concat(t)
end

local function map_maksura_to_farsi(text)
    if type(text) ~= 'string' or text == '' then return text end
    local out = {}
    for _, cp in utf8.codes(text) do
        if cp == 0x0649 then
            out[#out + 1] = utf8.char(0x06CC)
        else
            out[#out + 1] = utf8.char(cp)
        end
    end
    return table.concat(out)
end

local function map_maksura_pf_to_farsi_pf(text)
    if type(text) ~= 'string' or text == '' then return text end
    local out = {}
    for _, cp in utf8.codes(text) do
        if cp == 0xFBE8 then                  -- isolated Alef Maqsura
            out[#out + 1] = utf8.char(0xFBFC) -- isolated Farsi Yeh
        elseif cp == 0xFBE9 then              -- final Alef Maqsura
            out[#out + 1] = utf8.char(0xFBFD) -- final Farsi Yeh
        else
            out[#out + 1] = utf8.char(cp)
        end
    end
    return table.concat(out)
end

local function build_clusters(codepoints)
    local clusters = {}
    local current = nil
    for i = 1, #codepoints do
        local cp = codepoints[i]
        if ARABIC_DIACRITICS[cp] then
            if current then
                current[#current + 1] = cp
            else
                -- orphan mark, start its own cluster
                current = { cp }
                clusters[#clusters + 1] = current
            end
        else
            current = { cp }
            clusters[#clusters + 1] = current
        end
    end
    return clusters
end

local function flatten_clusters(clusters)
    local out = {}
    for _, cl in ipairs(clusters) do
        for i = 1, #cl do out[#out + 1] = cl[i] end
    end
    return out
end

local function reorder_visual_light(shaped_text)
    local cps = to_codepoints(shaped_text)
    if #cps == 0 then return shaped_text end

    local clusters = build_clusters(cps)
    local tokens = {}
    local token = { clusters = {}, rtl = false, is_space = false }
    local function start_token(is_space, rtl)
        token = { clusters = {}, rtl = rtl, is_space = is_space }
        tokens[#tokens + 1] = token
    end

    local function cluster_dir(cl)
        local base = cl[1] or 0
        return is_rtl_codepoint(base)
    end

    for _, cl in ipairs(clusters) do
        local base = cl[1] or 0
        local sp = is_whitespace(base)
        local rtl = cluster_dir(cl)
        if #tokens == 0 then
            start_token(sp, rtl)
        end
        local cur = tokens[#tokens]
        if sp ~= cur.is_space then
            start_token(sp, rtl)
            cur = tokens[#tokens]
        end
        if not sp and cur.rtl ~= rtl then
            start_token(false, rtl)
            cur = tokens[#tokens]
        end
        cur.clusters[#cur.clusters + 1] = cl
    end

    local hasRTL, hasLatin = false, false
    for _, t in ipairs(tokens) do
        if not t.is_space then
            if t.rtl then hasRTL = true else hasLatin = true end
        end
    end
    local rtlLine = hasRTL and not hasLatin

    local MIRROR = {
        [0x0028] = 0x0029,
        [0x0029] = 0x0028, -- ()
        [0x005B] = 0x005D,
        [0x005D] = 0x005B, -- []
        [0x007B] = 0x007D,
        [0x007D] = 0x007B, -- {}
        [0x003C] = 0x003E,
        [0x003E] = 0x003C, -- <>
        [0x00AB] = 0x00BB,
        [0x00BB] = 0x00AB, -- « »
        [0x2039] = 0x203A,
        [0x203A] = 0x2039, -- ‹ ›
        [0x2018] = 0x2019,
        [0x2019] = 0x2018, -- ‘ ’
        [0x201C] = 0x201D,
        [0x201D] = 0x201C, -- “ ”
    }
    local function mirror_cp(cp) return MIRROR[cp] or cp end

    for _, t in ipairs(tokens) do
        if t.rtl then
            local i, j = 1, #t.clusters
            while i < j do
                t.clusters[i], t.clusters[j] = t.clusters[j], t.clusters[i]
                i = i + 1; j = j - 1
            end
            -- also mirror punctuation inside RTL tokens
            for _, cl in ipairs(t.clusters) do
                for idx = 1, #cl do cl[idx] = mirror_cp(cl[idx]) end
            end
        end
    end

    -- if RTL line, reverse token order entirely (spaces included)
    if rtlLine then
        local i, j = 1, #tokens
        while i < j do
            tokens[i], tokens[j] = tokens[j], tokens[i]; i = i + 1; j = j - 1
        end
    end

    -- Flatten back to codepoints
    local out_clusters = {}
    for _, t in ipairs(tokens) do
        for _, cl in ipairs(t.clusters) do out_clusters[#out_clusters + 1] = cl end
    end
    local out_cps = flatten_clusters(out_clusters)
    return from_codepoints(out_cps)
end

--[[ Opt-in run-level bidi (`opts.bidi = "runs"`), a compact single-line
subset of UAX #9. reorder_visual_light treats any non-Arabic character as
Latin, so one trailing "." or digit made a whole Arabic sentence "mixed" and
left its words in logical (wrong) visual order, Arabic phrases inside an
English line were never reversed either. this resolves a paragraph direction
(explicit, or the first strong letter), keeps numbers and Latin runs
internally left-to-right, resolves spaces/punctuation from their neighbours,
then reverses runs by embedding level ]]
local function is_number_cp(cp)
    return (cp >= 0x30 and cp <= 0x39) or (cp >= 0x0660 and cp <= 0x0669) or (cp >= 0x06F0 and cp <= 0x06F9)
end

local ARABIC_NEUTRAL = { [0x060C] = true, [0x061B] = true, [0x061F] = true, [0x06D4] = true, [0x066A] = true }

local function is_ltr_letter(cp)
    return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) or cp == 0xAA or cp == 0xB5 or cp == 0xBA
        or (cp >= 0xC0 and cp <= 0x2AF and cp ~= 0xD7 and cp ~= 0xF7) or (cp >= 0x0370 and cp <= 0x058F)
        or (cp >= 0x0900 and cp <= 0x1FFF) or (cp >= 0x3040 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7AF)
end

-- "R", "L", "N" (number) or "O" (whitespace/other neutral) for a cluster base
local function bidi_class(cp)
    if is_number_cp(cp) then return "N" end
    if ARABIC_NEUTRAL[cp] then return "O" end
    if is_rtl_codepoint(cp) then return "R" end
    if is_ltr_letter(cp) then return "L" end
    return "O"
end

-- first strong letter decides (UAX #9 P2/P3), no strong letter means LTR
function ArabicText.paragraph_direction(text)
    for _, cp in utf8.codes(tostring(text or "")) do
        local class = bidi_class(cp)
        if class == "R" then return "rtl" end
        if class == "L" then return "ltr" end
    end
    return "ltr"
end

local MIRRORED = {
    [0x0028] = 0x0029, [0x0029] = 0x0028, [0x005B] = 0x005D, [0x005D] = 0x005B,
    [0x007B] = 0x007D, [0x007D] = 0x007B, [0x003C] = 0x003E, [0x003E] = 0x003C,
    [0x00AB] = 0x00BB, [0x00BB] = 0x00AB, [0x2039] = 0x203A, [0x203A] = 0x2039,
}

local function reorder_visual_runs(shaped_text, direction)
    local cps = to_codepoints(shaped_text)
    if #cps == 0 then return shaped_text end
    local clusters = build_clusters(cps)
    local classes = {}
    for i, cl in ipairs(clusters) do classes[i] = bidi_class(cl[1] or 0) end

    local paragraph = direction == "rtl" and 1 or direction == "ltr" and 0 or nil
    if not paragraph then
        paragraph = 0
        for _, class in ipairs(classes) do
            if class == "R" then paragraph = 1 break elseif class == "L" then paragraph = 0 break end
        end
    end

    -- Units: R letter runs, L/N runs that also absorb non-space punctuation
    -- directly followed by another L/N cluster ("4:00", "DRBK-1A", "1,000");
    -- and neutral runs (spaces and other punctuation)
    local units, i = {}, 1
    while i <= #clusters do
        local class = classes[i]
        local unit = { first = i, last = i }
        if class == "R" then
            unit.kind = "R"
            while unit.last < #clusters and classes[unit.last + 1] == "R" do unit.last = unit.last + 1 end
        elseif class == "L" or class == "N" then
            local letters = class == "L"
            local j = i
            while j < #clusters do
                local next_class = classes[j + 1]
                if next_class == "L" or next_class == "N" then
                    j = j + 1; letters = letters or next_class == "L"
                elseif next_class == "O" and not is_whitespace(clusters[j + 1][1]) and j + 2 <= #clusters
                    and (classes[j + 2] == "L" or classes[j + 2] == "N") then
                    j = j + 2; letters = letters or classes[j] == "L"
                else break end
            end
            unit.last, unit.kind = j, letters and "L" or "N"
        else
            unit.kind = "O"
            while unit.last < #clusters and classes[unit.last + 1] == "O" do unit.last = unit.last + 1 end
        end
        units[#units + 1] = unit
        i = unit.last + 1
    end

    local strong_level = paragraph == 1 and 2 or 0
    local function influence(unit)
        if not unit then return paragraph == 1 and "R" or "L" end
        if unit.kind == "R" then return "R" end
        if unit.kind == "N" then return paragraph == 1 and "R" or "L" end
        return "L"
    end
    local max_level = 0
    for index, unit in ipairs(units) do
        if unit.kind == "R" then unit.level = 1
        elseif unit.kind == "L" or unit.kind == "N" then unit.level = strong_level
        else
            local before, after
            for k = index - 1, 1, -1 do if units[k].kind ~= "O" then before = units[k] break end end
            for k = index + 1, #units do if units[k].kind ~= "O" then after = units[k] break end end
            local left, right = influence(before), influence(after)
            if left == right then unit.level = left == "R" and 1 or strong_level
            else unit.level = paragraph end
        end
        max_level = math.max(max_level, unit.level)
    end

    for level = max_level, 1, -1 do
        local start = nil
        for index = 1, #units + 1 do
            local inside = units[index] and units[index].level >= level
            if inside and not start then start = index
            elseif not inside and start then
                local a, b = start, index - 1
                while a < b do units[a], units[b] = units[b], units[a]; a = a + 1; b = b - 1 end
                start = nil
            end
        end
    end

    local out = {}
    for _, unit in ipairs(units) do
        local odd = unit.level % 2 == 1
        local from, to, step = unit.first, unit.last, 1
        if odd then from, to, step = unit.last, unit.first, -1 end
        for index = from, to, step do
            for _, cp in ipairs(clusters[index]) do out[#out + 1] = odd and (MIRRORED[cp] or cp) or cp end
        end
    end
    return from_codepoints(out)
end

local function joining_type(cp)
    if ARABIC_DIACRITICS[cp] then return JOINING_TYPES.TRANSPARENT end
    local c = ARABIC_CHARS[cp]
    return c and c.type or JOINING_TYPES.NON_JOINING
end

-- public helpers for other modules
function ArabicText.is_diacritic_cp(cp)
    return ARABIC_DIACRITICS[cp] == true
end

function ArabicText.is_arabic_cp(cp)
    return is_arabic(cp)
end

function ArabicText.joining_type(cp)
    return joining_type(cp)
end

local function can_join(codepoints, i)
    local tp_this = joining_type(codepoints[i])
    if tp_this == JOINING_TYPES.TRANSPARENT or tp_this == JOINING_TYPES.NON_JOINING then
        return false, false
    end

    local join_left, join_right = false, false

    -- find previous non-transparent
    local tp_prev
    for j = i - 1, 1, -1 do
        local jt = joining_type(codepoints[j])
        if jt ~= JOINING_TYPES.TRANSPARENT then
            tp_prev = jt; break
        end
    end
    -- find next non-transparent
    local tp_next
    for j = i + 1, #codepoints do
        local jt = joining_type(codepoints[j])
        if jt ~= JOINING_TYPES.TRANSPARENT then
            tp_next = jt; break
        end
    end

    if tp_prev and (tp_prev == JOINING_TYPES.LEFT or tp_prev == JOINING_TYPES.DUAL)
        and (tp_this == JOINING_TYPES.RIGHT or tp_this == JOINING_TYPES.DUAL) then
        join_left = true
    end

    if tp_next and (tp_next == JOINING_TYPES.RIGHT or tp_next == JOINING_TYPES.DUAL)
        and (tp_this == JOINING_TYPES.LEFT or tp_this == JOINING_TYPES.DUAL) then
        join_right = true
    end

    return join_left, join_right
end

function ArabicText.form(cp, joinL, joinR)
    local ch = ARABIC_CHARS[cp]; if not ch then return cp end
    local jt = ch.type

    if jt == JOINING_TYPES.DUAL then
        if joinL and joinR then
            return ch.medial or ch.isolated
        elseif joinL then
            return ch.final or ch.isolated
        elseif joinR then
            return ch.initial or ch.isolated
        else
            return ch.isolated
        end
    elseif jt == JOINING_TYPES.RIGHT then
        return joinL and (ch.final or ch.isolated) or ch.isolated
    elseif jt == JOINING_TYPES.LEFT then
        return joinR and (ch.initial or ch.isolated) or ch.isolated
    end
    return ch.isolated or cp
end

local function apply_ligatures(seq)
    local out, i = {}, 1
    while i <= #seq do
        local cur, nxt = seq[i], seq[i + 1]
        if cur == 0x0644 and nxt then -- Lam
            local lt = LAM_ALIF_LIGATURES[cur]
            if lt and lt[nxt] then
                local prev_join = false
                for j = #out, 1, -1 do
                    local tp = joining_type(out[j])
                    if tp ~= JOINING_TYPES.TRANSPARENT then
                        prev_join = (tp == JOINING_TYPES.LEFT or tp == JOINING_TYPES.DUAL)
                        break
                    end
                end
                local lig = (prev_join and LAM_ALIF_LIGATURES_FINAL[cur][nxt])
                    or lt[nxt]
                out[#out + 1] = lig
                i = i + 2
            else
                out[#out + 1] = cur; i = i + 1
            end
        else
            out[#out + 1] = cur; i = i + 1
        end
    end
    return out
end

local function normalize_to_persian(text)
    local map = {
        [0x064A] = 0x06CC, -- Arabic Yeh -> Farsi Yeh
        [0x0649] = 0x06CC, -- Alef Maqsura -> Farsi Yeh
        [0x0643] = 0x06A9, -- Kaf -> Keheh
    }
    local function map_digit(cp)
        if cp >= 0x0660 and cp <= 0x0669 then
            return 0x06F0 + (cp - 0x0660)
        end
        return nil
    end
    local out = {}
    for _, cp in utf8.codes(text or "") do
        out[#out + 1] = utf8.char(map[cp] or map_digit(cp) or cp)
    end
    return table.concat(out)
end

function ArabicText.shape_text(text, font_path, font_size, opts)
    if ArabicText.NORMALIZE_TO_PERSIAN and text and text ~= "" then
        text = normalize_to_persian(text)
    end
    if ArabicText.AUTO_FARSI_YEH and text and text ~= '' then
        text = map_maksura_to_farsi(text)
    end
    if ArabicText.REMOVE_DIACRITICS and ArabicText.NORMALIZE_ALEF_WASLA and text and text ~= '' then
        local out = {}
        for _, cp in utf8.codes(text) do
            if cp == 0x0671 then out[#out + 1] = utf8.char(0x0627) else out[#out + 1] = utf8.char(cp) end
        end
        text = table.concat(out)
    end
    local function has_presentation_forms(str)
        for _, cp in utf8.codes(str or "") do
            if (cp >= 0xFB50 and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF) then
                return true
            end
        end
        return false
    end

    if HarfBuzzText.is_available() then
        -- Projects that use HarfBuzz supply their own font path. the shaping
        -- fallback below remains available when no project font is configured
        local hb_out = font_path and HarfBuzzText.shape_text(text, font_path, font_size, opts) or nil
        if type(hb_out) == "string" and hb_out ~= "" then
            if ArabicText.REMOVE_DIACRITICS then
                local filtered = {}
                for _, cp in utf8.codes(hb_out) do
                    if not ARABIC_DIACRITICS[cp] then filtered[#filtered + 1] = utf8.char(cp) end
                end
                hb_out = table.concat(filtered)
            end
            if ArabicText.AUTO_FARSI_YEH then
                hb_out = map_maksura_pf_to_farsi_pf(hb_out)
            end
            if not text_contains_arabic(text) then
                return hb_out
            end
            if has_presentation_forms(hb_out) then
                return hb_out
            end
        end
    end

    if text == "" then return text end

    local cps = {}
    for _, cp in utf8.codes(text) do cps[#cps + 1] = cp end

    if ArabicText.REMOVE_DIACRITICS then
        local t = {}
        for _, cp in ipairs(cps) do
            if not ARABIC_DIACRITICS[cp] then t[#t + 1] = cp end
        end
        cps = t
    end

    cps = apply_ligatures(cps)

    local shaped = {}
    for i, cp in ipairs(cps) do
        if joining_type(cp) == JOINING_TYPES.TRANSPARENT then
            shaped[#shaped + 1] = cp
        else
            local L, R = can_join(cps, i)
            shaped[#shaped + 1] = ArabicText.form(cp, L, R)
        end
    end

    if not (opts and opts.skip_bidi_reorder) then
        if opts and opts.bidi == "runs" then
            shaped = reorder_visual_runs(from_codepoints(shaped), opts.direction)
        else
            shaped = reorder_visual_light(from_codepoints(shaped))
        end
        shaped = to_codepoints(shaped)
    end

    local s = {}
    for _, cp in ipairs(shaped) do s[#s + 1] = utf8.char(cp) end
    return table.concat(s)
end

function ArabicText.shape_text_no_reorder(text, font_path, font_size)
    return ArabicText.shape_text(text, font_path, font_size, { skip_bidi_reorder = true })
end

function ArabicText.shape_positions(text, font_path, font_size)
    if HarfBuzzText.is_available() and HarfBuzzText.shape_positions then
        return HarfBuzzText.shape_positions(text, font_path, font_size)
    end
    return nil
end

ArabicText.contains_arabic = function(text)
    if HarfBuzzText.is_available() then
        return HarfBuzzText.contains_arabic(text)
    else
        return text_contains_arabic(text)
    end
end

function ArabicText.get_joined_word_boundaries(text)
    if HarfBuzzText.is_available() then
        return HarfBuzzText.get_joined_word_boundaries(text)
    else
        local bounds, start, pos, inWord = {}, nil, 1, false
        for _, cp in utf8.codes(text) do
            local joining = is_arabic(cp) and (joining_type(cp) ~= JOINING_TYPES.NON_JOINING)
            if joining and not inWord then start, inWord = pos, true end
            if (not joining or is_whitespace(cp)) and inWord then
                bounds[#bounds + 1] = { start = start, stop = pos - 1 }
                inWord, start = false, nil
            end
            pos = pos + utf8.len(utf8.char(cp))
        end
        if inWord then bounds[#bounds + 1] = { start = start, stop = pos - 1 } end
        return bounds
    end
end

return ArabicText
