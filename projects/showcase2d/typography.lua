-- the demo setting in config.lua picks the editor, fonts or markup example
local Demo = {}

function Demo.start(program, mode)
    if mode == "editor" then
        local editor = require("engine/ui/editor")
        assert(editor.import([[
            local panel = Element { name = "Welcome card", show_fill = true,
                fill_color = {0.09, 0.14, 0.22, 1},
                position = {scale = vec2(0.1, 0.15)}, size = {scale = vec2(0.8, 0.7)} }
            panel:add(Text { name = "Heading", text = "Make something small.",
                fontSize = 36, position = {scale = vec2(0.08, 0.13)}, size = {scale = vec2(0.84, 0.22)} })
            panel:add(Text { name = "Description", text = "Select a node, edit its properties, then export Lua.",
                fontSize = 22,
                position = {scale = vec2(0.08, 0.38)}, size = {scale = vec2(0.84, 0.22)} })
            panel:add(Text { name = "Button", text = "Start building", fontSize = 24,
                show_fill = true, fill_color = {0.16, 0.50, 0.72, 1},
                position = {scale = vec2(0.25, 0.72)}, size = {scale = vec2(0.5, 0.16)} })
            return {panel}
        ]]))
        return
    end
    assert(mode == "fonts" or mode == "markup", "Unknown showcase demo: " .. tostring(mode))
    local root = Element { size = { scale = vec2(1, 1) }, show_fill = true, fill_color = { 0.045, 0.065, 0.10, 1 } }
    local function label(text, x, y, w, h, size, options)
        local args = {
            text = text,
            fontSize = size,
            position = { scale = vec2(x / 1280, y / 720) },
            size = { scale = vec2(w / 1280, h / 720) },
            textAlignX = "left",
            textColor = { 0.88, 0.92, 0.98, 1 },
            textFits = false
        }
        for k, v in pairs(options or {}) do args[k] = v end
        return root:add(Text(args))
    end
    label("wave-engine / " .. (mode == "fonts" and "font rendering" or "rich text"), 64, 30, 1100, 46, 24,
        { textColor = { 0.4, 0.76, 0.92, 1 } })
    label(mode == "fonts" and "text languages" or "words can move too!!", 64, 86, 1150, 100, 64)
    if mode == "fonts" then
        label("Scrambled Eggs Bold / 18", 66, 214, 530, 48, 18)
        label("Readable at 28", 66, 274, 530, 58, 28)
        label("Heading / 42 px", 66, 344, 560, 82, 42)
        label("Café, mañana, über, déjà vu.", 66, 460, 610, 72, 25)
        label("Arabic / bundled Noto fallback", 690, 214, 520, 44, 20, { textColor = { 0.4, 0.76, 0.92, 1 } })
        label("مرحبا بالعالم", 690, 265, 520, 102, 48, { textAlignX = "right" })
        label("Arabic / 32 px", 690, 390, 520, 44, 20, { textColor = { 0.4, 0.76, 0.92, 1 } })
        label("أهلا وسهلا", 690, 444, 520, 90, 32, { textAlignX = "right" })
        label("Font files, sizes and alignment are project choices. CJK is an optional font pack.", 66, 610, 1150, 48, 21)
    else
        label("<color=#65d6ff>Color</color>  <bold=1.5>bold</bold>  <italic=0.3>italic</italic>", 66, 214, 1140, 74, 42)
        label(
            "<outlineThickness=2><outlineColor=#50bdda>Outlined text</outlineColor></outlineThickness>   <size=24>with a smaller aside</size>",
            66, 306, 1140, 78, 40)
        label("<wave=2,8>wavy text</wave>   <rainbow=0.4,0.7,fill>moving color</rainbow>", 66, 405, 1140, 88, 42)
        label("<float=7,9,y>Floating</float>   <rotate=-5>tilted</rotate>   <opacity=0.45,fill>quiet</opacity>", 66, 514,
            1140, 74, 40)
        label("Angle-bracket tags style real Text elements. Effects animate while the app runs.", 66, 623, 1150, 44, 21)
    end
    program.pipeline:register("draw", "typography", function() root:draw() end, { phase = "content", priority = 50 })
    Demo.root = root
end

return Demo
