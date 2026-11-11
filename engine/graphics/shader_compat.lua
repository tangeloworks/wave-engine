--[[ mobile/gles shader compatibility

desktop gl ignores precision qualifiers, but gles requires uniforms and
varyings declared in BOTH shader stages to have MATCHING precision. love's
es preamble defaults fragment floats to mediump while vertex floats are
highp, so any unqualified shared uniform (e.g. "uniform vec3 uCameraPos;")
links on desktop and fails on mobile with "uniform precision mismatch"

this wraps love.graphics.newShader and qualifies unadorned uniform/extern/
varying declarations with an explicit highp. love defines lowp/mediump/highp
as empty macros on desktop gl, so the rewrite is portable and exercised on
every desktop run. samplers (Image/sampler types) and bools are skipped -
precision on those is driver-fussy and never the mismatch source here ]]

local QUALIFIABLE = {
    float = true, number = true, int = true,
    vec2 = true, vec3 = true, vec4 = true,
    ivec2 = true, ivec3 = true, ivec4 = true,
    mat2 = true, mat3 = true, mat4 = true,
}

local KEYWORDS = { "uniform", "extern", "varying" }

local function qualify_source(src)
    for _, kw in ipairs(KEYWORDS) do
        src = src:gsub("(%f[%w]" .. kw .. "%s+)([%w_]+)", function(pre, ty)
            if QUALIFIABLE[ty] then
                return pre .. "highp " .. ty
            end
            return pre .. ty
        end)
    end
    return src
end

local function looks_like_source(arg)
    -- love also accepts file paths / FileData, only rewrite inline code
    return type(arg) == "string" and arg:find("\n") ~= nil
end

local original_new_shader = love.graphics.newShader

function love.graphics.newShader(a, b, ...)
    if looks_like_source(a) then a = qualify_source(a) end
    if looks_like_source(b) then b = qualify_source(b) end
    return original_new_shader(a, b, ...)
end

return { qualify_source = qualify_source }
