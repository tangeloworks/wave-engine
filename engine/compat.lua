-- older projects can use this table to reach the globals created by their launcher
-- each call builds a fresh table with the same underlying objects

local compat = {}

function compat.is_legacy_bootstrapped()
    return rawget(_G, "G") ~= nil and rawget(_G, "Program") ~= nil
end

function compat.legacy_globals()
    return {
        G = rawget(_G, "G"),
        Program = rawget(_G, "Program"),
        Pipeline = rawget(_G, "Pipeline"),
        CFG = rawget(_G, "CFG"),
        Element = rawget(_G, "Element"),
        Image = rawget(_G, "Image"),
        Text = rawget(_G, "Text"),
        input_mgr = rawget(_G, "input_mgr"),
        audio = rawget(_G, "audio"),
    }
end

return compat
