---@class Pipeline: Object
Pipeline = Object:extend()
local cwd = (...):gsub('%.init$', '') .. "."
local path = cwd:gsub("[.]", "/")
local policy = require('engine/graphics/presentation')
local noop = function() end
local phases = { prepare = 0, background = 10, content = 20, letterbox = 30,
    overlay = 40, interface = 50, composite = 60, capture = 70 }
local core_phases = { ratioclear = 0, postfx_start = 0, INIT = 10,
    letterbox = 30, debug = 40, perfstats = 64, fpsdraw = 65,
    keyboard_flyout = 50, ratiofin = 70, postfx_end = 70 }
local settings = { fpsdraw = 'fps', perfstats = 'perfstats' }

function Pipeline:init()
    self.buckets = { update = {}, draw = {}, input_start = {}, input_change = {}, input_end = {} }
    self._seq = 0
    self.hide_overlays = policy.hide_overlays()
end

function Pipeline:register_all()
    require(path .. 'draw')
    require(path .. 'update')
end

-- draw phases keep late project registrations inside the screen pass. Within
-- a phase, higher priorities run first and `after` is a dependency
function Pipeline:sort_draw()
    local bucket, by_name, visiting = self.buckets.draw, {}, {}
    for _, item in ipairs(bucket) do by_name[item.name] = item; item._phase = nil end
    local function phase(item)
        if item._phase then return item._phase end
        local explicit = item.phase
        local result = core_phases[item.name] or (type(explicit) == 'number' and explicit)
            or phases[explicit] or (item.overlay and phases.overlay)
        if not result and not visiting[item] then
            visiting[item] = true
            local anchor = by_name[item.after]
            if anchor and anchor.name ~= 'INIT' and anchor.name ~= 'postfx_start' and anchor.name ~= 'ratioclear' then
                result = phase(anchor)
            end
            visiting[item] = nil
        end
        item._phase = result or phases.content
        return item._phase
    end
    for _, item in ipairs(bucket) do phase(item) end
    table.sort(bucket, function(a, b)
        if a._phase ~= b._phase then return a._phase < b._phase end
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a._seq < b._seq
    end)
    local pending, ordered, done = {}, {}, {}
    for i, item in ipairs(bucket) do pending[i] = item end
    while #pending > 0 do
        local index
        for i, item in ipairs(pending) do
            local anchor = by_name[item.after]
            if not anchor or anchor._phase ~= item._phase or done[anchor] then index = i; break end
            if pending[i + 1] and pending[i + 1]._phase ~= item._phase then break end
        end
        local item = table.remove(pending, index or 1) -- cycles retain stable order
        ordered[#ordered + 1] = item; done[item] = true
    end
    for i, item in ipairs(ordered) do bucket[i] = item end
end

function Pipeline:_effective(sector, item)
    local setting = sector == 'draw' and settings[item.name]
    local overlay = setting or item.overlay or item.name == 'debug'
    if overlay and self.hide_overlays then return false end
    -- Setting-bound stages reflect today's value, even if registered after
    -- settings load. enable/disable cannot replace the user's preference
    if setting then return policy.setting(setting) == true end
    return item._enabled
end

function Pipeline:register(sector, nickname, func, priority)
    local bucket = assert(self.buckets[sector], 'Unknown pipeline sector: ' .. tostring(sector))
    for _, item in ipairs(bucket) do if item.name == nickname then return end end
    local opts = type(priority) == 'table' and priority or { priority = priority }
    self._seq = self._seq + 1
    local item = { name = nickname, backup_func = func, priority = opts.priority or 1,
        _seq = self._seq, _enabled = true, after = opts.after, phase = opts.phase, overlay = opts.overlay }
    if (sector == 'draw' and settings[nickname]) or nickname == 'debug' or opts.overlay then
        item._dispatch = function(...)
            if self:_effective(sector, item) then return func(...) end
        end
    else
        item._dispatch = func
    end
    item.current_func = item._dispatch
    if sector == 'draw' then
        if opts.after and opts.priority == nil then
            for _, anchor in ipairs(bucket) do
                if anchor.name == opts.after then item.priority = anchor.priority; break end
            end
        end
        bucket[#bucket + 1] = item
        self:sort_draw()
        return
    end
    -- preserve update/input scheduling, presentation phases are draw-only
    local pos
    if opts.after then
        for i, anchor in ipairs(bucket) do
            if anchor.name == opts.after then
                if opts.priority == nil then item.priority = anchor.priority end
                pos = i + 1; break
            end
        end
    end
    if not pos then
        pos = #bucket + 1
        for i, anchor in ipairs(bucket) do if anchor.priority >= item.priority then pos = i + 1 end end
    end
    table.insert(bucket, pos, item)
end

function Pipeline:disable(sector, nickname)
    for _, item in ipairs(self.buckets[sector]) do
        if item.name == nickname then
            item._enabled = false
            item.current_func = sector == 'draw' and settings[nickname] and item._dispatch or noop
            return
        end
    end
end

function Pipeline:enable(sector, nickname)
    for _, item in ipairs(self.buckets[sector]) do
        if item.name == nickname then item._enabled = true; item.current_func = item._dispatch; return end
    end
end

function Pipeline:is_enabled(sector, nickname)
    for _, item in ipairs(self.buckets[sector] or {}) do
        if item.name == nickname then return self:_effective(sector, item) end
    end
    return false
end

function Pipeline:remove(sector, nickname)
    for i, item in ipairs(self.buckets[sector]) do
        if item.name == nickname then
            table.remove(self.buckets[sector], i)
            if sector == 'draw' then self:sort_draw() end
            return
        end
    end
end
