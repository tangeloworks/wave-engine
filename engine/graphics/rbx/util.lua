local base64 = require("engine/services/oss/base64")
local cpml = require("engine/services/oss/cpml")

local vec3 = cpml.vec3

local util = {}

function util.clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

function util.trim(text)
    if type(text) ~= "string" then
        return ""
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.starts_with(text, prefix)
    return type(text) == "string" and text:sub(1, #prefix) == prefix
end

function util.file_extension(path)
    if type(path) ~= "string" then
        return ""
    end
    return (path:match("(%.[^./\\]+)$") or ""):lower()
end

function util.shallow_copy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = item
    end
    return copy
end

function util.deep_copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[util.deep_copy(key, seen)] = util.deep_copy(item, seen)
    end
    return copy
end

function util.table_append(out, items)
    if type(out) ~= "table" or type(items) ~= "table" then
        return out
    end
    for index = 1, #items do
        out[#out + 1] = items[index]
    end
    return out
end

function util.arrayify(value)
    if type(value) ~= "table" then
        return {}
    end
    if #value > 0 then
        return value
    end
    return { value }
end

util.as_array = util.arrayify

function util.file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    if not path:match("^[A-Za-z]:[\\/]") then
        return love.filesystem.getInfo(path) ~= nil
    end

    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

function util.read_file(path)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid path"
    end

    local data, err = love.filesystem.read(path)
    if type(data) == "string" then
        return data
    end
    if data ~= nil then
        return data, err
    end

    local handle = io.open(path, "rb")
    if not handle then
        return nil, ("failed to open %s"):format(path)
    end

    local ok, data = pcall(handle.read, handle, "*a")
    handle:close()
    if not ok then
        return nil, tostring(data)
    end
    return data
end

function util.write_file(path, data)
    if not path:match("^[A-Za-z]:[\\/]" ) then
        return love.filesystem.write(path, data)
    end

    local handle, err = io.open(path, "wb")
    if not handle then
        return nil, err
    end
    handle:write(data)
    handle:close()
    return true
end

function util.decode_base64(text)
    if type(text) ~= "string" then
        return ""
    end
    return base64.decode(text)
end

function util.encode_base64(text)
    if type(text) ~= "string" then
        return ""
    end
    return base64.encode(text)
end

function util.xml_escape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    text = text:gsub("'", "&apos;")
    return text
end

function util.xml_unescape(text)
    if type(text) ~= "string" then
        return ""
    end
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&apos;", "'")
    text = text:gsub("&amp;", "&")
    return text
end

function util.round(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

function util.empty_bounds()
    return {
        min = vec3.new(math.huge, math.huge, math.huge),
        max = vec3.new(-math.huge, -math.huge, -math.huge),
    }
end

function util.bounds_valid(bounds)
    return bounds
        and bounds.min
        and bounds.max
        and bounds.min.x <= bounds.max.x
        and bounds.min.y <= bounds.max.y
        and bounds.min.z <= bounds.max.z
end

function util.expand_bounds(bounds, value)
    if not bounds or not value then
        return bounds
    end

    if type(value) == "table" and value.min and value.max then
        util.expand_bounds(bounds, value.min)
        util.expand_bounds(bounds, value.max)
        return bounds
    end

    bounds.min = vec3.component_min(bounds.min, value)
    bounds.max = vec3.component_max(bounds.max, value)
    return bounds
end

function util.ensure_bounds(bounds, fallback_radius)
    if util.bounds_valid(bounds) then
        return bounds
    end

    fallback_radius = fallback_radius or 16
    return {
        min = vec3.new(-fallback_radius, -fallback_radius, -fallback_radius),
        max = vec3.new(fallback_radius, fallback_radius, fallback_radius),
    }
end

function util.bounds_center(bounds)
    bounds = util.ensure_bounds(bounds)
    return (bounds.min + bounds.max) * 0.5
end

function util.bounds_size(bounds)
    bounds = util.ensure_bounds(bounds)
    return bounds.max - bounds.min
end

function util.normalize_path(path)
    if type(path) ~= "string" then
        return nil
    end
    return (path:gsub("\\", "/"))
end

function util.detect_format(path, data)
    local extension = util.file_extension(path)
    if extension == ".rbxl" or extension == ".rbxm" then
        return extension
    end
    if extension == ".rbxlx" or extension == ".rbxmx" then
        return extension
    end
    if extension == ".mesh" or extension == ".rbxmesh" or extension == ".meshdata" or extension == ".data" then
        return extension
    end
    if type(data) == "string" then
        -- BINARY MUST BE TESTED FIRST. a binary place file's signature is
        -- "<roblox!\137\255\r\n\26\n", so its first seven bytes are literally
        -- "<roblox" -- identical to the XML root tag. Sniffing for "<roblox" alone
        -- therefore reported every binary file as XML whenever the extension was
        -- absent or unrecognised, which is exactly the public rbx.load_bytes(data)
        -- path with no format hint
        --
        -- constants.lua is required lazily: it requires this module, so requiring it
        -- at the top of the file would be circular
        local ok, constants = pcall(require, "engine/graphics/rbx/constants")
        if ok and constants and constants.BINARY_SIGNATURE
            and util.starts_with(data, constants.BINARY_SIGNATURE) then
            -- Place vs model cannot be told apart from the signature alone, both use
            -- the same one. prefer the extension when it disagrees, else assume place
            if extension == ".rbxm" or extension == ".rbxmx" then
                return ".rbxm"
            end
            return ".rbxl"
        end
        if util.starts_with(data, "<roblox") or util.starts_with(util.trim(data), "<?xml") then
            return ".rbxlx"
        end
    end
    return extension
end

function util.make_bitops()
    local bitops = bit or bit32
    if not bitops then
        error("rbx module requires bit or bit32")
    end
    return bitops
end

return util
