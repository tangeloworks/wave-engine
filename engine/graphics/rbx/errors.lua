local errors = {}

local function merge_context(context, extra)
    local merged = {}
    if type(context) == "table" then
        for key, value in pairs(context) do
            merged[key] = value
        end
    end
    if type(extra) == "table" then
        for key, value in pairs(extra) do
            merged[key] = value
        end
    end
    return merged
end

function errors.new(kind, message, context)
    local err = {
        kind = kind or "Error",
        message = message or "",
        context = merge_context(context),
    }

    function err:with(extra)
        return errors.new(self.kind, self.message, merge_context(self.context, extra))
    end

    return err
end

function errors.format(err)
    if type(err) ~= "table" then
        return tostring(err)
    end

    local parts = {
        ("[%s] %s"):format(tostring(err.kind or "Error"), tostring(err.message or "")),
    }

    local context = err.context or {}
    if context.path then
        parts[#parts + 1] = ("path=%s"):format(tostring(context.path))
    end
    if context.chunk then
        parts[#parts + 1] = ("chunk=%s"):format(tostring(context.chunk))
    end
    if context.property then
        parts[#parts + 1] = ("property=%s"):format(tostring(context.property))
    end
    if context.type_id ~= nil then
        parts[#parts + 1] = ("type=%s"):format(tostring(context.type_id))
    end
    if context.offset ~= nil then
        parts[#parts + 1] = ("offset=%s"):format(tostring(context.offset))
    end
    if context.line ~= nil and context.column ~= nil then
        parts[#parts + 1] = ("line=%s col=%s"):format(tostring(context.line), tostring(context.column))
    end

    return table.concat(parts, " ")
end

function errors.raise(kind, message, context, level)
    error(errors.format(errors.new(kind, message, context)), (level or 1) + 1)
end

return errors
