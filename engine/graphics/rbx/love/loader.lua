local binary = require("engine/graphics/rbx/binary")
local import = require("engine/graphics/rbx/import")
local mesh = require("engine/graphics/rbx/mesh")
local util = require("engine/graphics/rbx/util")
local xml = require("engine/graphics/rbx/xml")

local loader = {}

function loader.load_bytes(data, format_hint, opts)
    opts = util.shallow_copy(opts or {})
    opts.formatKind = format_hint or opts.formatKind or util.detect_format(opts.source_name or "", data)
    if opts.formatKind == ".rbxl" or opts.formatKind == ".rbxm" then
        return binary.read(data, opts)
    end
    return xml.read(data, opts)
end

function loader.load_file(path, opts)
    local data, err = util.read_file(path)
    if type(data) ~= "string" then
        return nil, err or "failed to read file"
    end
    opts = util.shallow_copy(opts or {})
    opts.source_name = path
    return loader.load_bytes(data, opts.formatKind or util.detect_format(path, data), opts)
end

function loader.import_scene(file, opts)
    return import.import_scene(file, opts)
end

function loader.import_renderables(file_or_scene, opts)
    return import.import_renderables(file_or_scene, opts)
end

function loader.mesh_to_vertex_rows(parsed)
    if type(parsed) ~= "table" or type(parsed.positions) ~= "table" then
        return {}
    end
    local rows = {}
    for index = 1, #parsed.positions, 3 do
        local vertex_index = math.floor((index - 1) / 3)
        local uv_index = vertex_index * 2 + 1
        local color_index = vertex_index * 4 + 1
        rows[#rows + 1] = {
            x = parsed.positions[index] or 0,
            y = parsed.positions[index + 1] or 0,
            z = parsed.positions[index + 2] or 0,
            nx = parsed.normals and parsed.normals[index] or 0,
            ny = parsed.normals and parsed.normals[index + 1] or 1,
            nz = parsed.normals and parsed.normals[index + 2] or 0,
            u = parsed.uvs and parsed.uvs[uv_index] or 0,
            v = parsed.uvs and parsed.uvs[uv_index + 1] or 0,
            r = parsed.colors and parsed.colors[color_index] or 1,
            g = parsed.colors and parsed.colors[color_index + 1] or 1,
            b = parsed.colors and parsed.colors[color_index + 2] or 1,
            a = parsed.colors and parsed.colors[color_index + 3] or 1,
        }
    end
    return rows
end

loader.mesh = mesh

return loader
