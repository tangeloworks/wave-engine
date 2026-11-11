local logging = {}

function logging.warn(target, code, message, context)
    if type(target) ~= "table" then
        return
    end

    target.warnings = target.warnings or {}
    target.warnings[#target.warnings + 1] = {
        code = code,
        message = message,
        context = context,
    }
end

function logging.extend(target, items)
    if type(target) ~= "table" or type(items) ~= "table" then
        return
    end

    target.warnings = target.warnings or {}
    for index = 1, #items do
        target.warnings[#target.warnings + 1] = items[index]
    end
end

return logging
