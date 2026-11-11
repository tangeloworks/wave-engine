local MenuScroll = {}
local ScrollMT = {}
ScrollMT.__index = ScrollMT

local tick = function() return love.timer.getTime() end

local function make_default_funcs(isPause)
    return {
        disconnect = function() end,
        reconnect = function() end,
        render = function() end,
        next = function() end,
        back = function() end,
        clicked = function(_, choice)
            if isPause and choice == 'decline' then
                G:setPause(false)
            end
        end,
    }
end

local function elem_name(e)
    if not e then return nil end
    return e.name or e.Name or tostring(e)
end

local function is_element(e)
    return Element.isElement(e)
end

local function call_enter(self, elem)
    if not elem then return end
    local name = elem_name(elem)
    if self.connectTree and self.connectTree.connections then
        local c = self.connectTree.connections[name .. '_enter']
        if c and c.f then return c.f() end
    end
    if is_element(elem) then
        elem:handleInput('mouseenter')
    end
end

local function call_leave(self, elem)
    if not elem then return end
    local name = elem_name(elem)
    if self.connectTree and self.connectTree.connections then
        local c = self.connectTree.connections[name .. '_leave']
        if c and c.f then return c.f() end
    end
    if is_element(elem) then
        elem:handleInput('mouseleave')
    end
end

local function call_click(self, elem)
    if not elem then return end
    local name = elem_name(elem)
    if self.connectTree and self.connectTree.connections then
        local c = self.connectTree.connections[name .. '_click']
        if c and c.f then return c.f() end
    end
    if is_element(elem) then
        local r = elem:get_screen_rect(nil, { mode = 'visual' })
        local cx = r.position.x + r.size.x * 0.5
        local cy = r.position.y + r.size.y * 0.5
        elem:handleInput('mouseclicked', 1, cx, cy)
    end
end

local function to_axis_key(axis)
    local a = tostring(axis or 'y')
    a = a:lower()
    return (a == 'x' or a == 'y') and a or 'y'
end

-- axis: 'x' or 'y'
-- args: {
--   stick        = 1|2 (optional, currently unused, we derive sticks from controller.get_active_direction)
--   funcs        = { disconnect,reconnect,render,next,back,clicked }
--   objects      = array of Element (order of navigation)
--   connectTree  = { connections = { [name..'_enter']={f=...}, [name..'_leave']={f=...}, [name..'_click']={f=...} } }
--   isPause      = boolean (optional: default clicked('decline') unpauses)
--   dontload     = boolean (if true, caller must call :load())
-- }
function MenuScroll.new(axis, args)
    args = args or {}
    local self = setmetatable({
        axis = to_axis_key(axis),
        stick = args.stick or 1,
        funcs = args.funcs or make_default_funcs(args.isPause),
        active = false,
        selecting = 1,
        selectObj = nil,
        objects = args.objects or {},
        connectTree = args.connectTree,
        timers = {
            deb = false,
            holdt = tick(),
            holdw = tick(),
        },
        dontregister = false,
        _frame = 0,
        _pipe_names = {},
    }, ScrollMT)

    if not args.dontload then
        self:load()
    end
    return self
end

local NAV_KEYS = {
    w = true,
    a = true,
    s = true,
    d = true,
    up = true,
    down = true,
    left = true,
    right = true,
    dpup = true,
    dpdown = true,
    dpleft = true,
    dpright = true,
}

function ScrollMT:_register_pipeline()
    local uid = tostring(self):gsub('table: ', 'ms:')
    local pn = self._pipe_names
    pn.update = 'menuscroll:update:' .. uid
    pn.start = 'menuscroll:start:' .. uid
    pn.change = 'menuscroll:change:' .. uid

    G.pipeline:register('input_start', pn.start, function(key_or_btn, prompt)
        if self.dontregister then return end

        if key_or_btn == 'mouse1' or key_or_btn == 'mouse2' or key_or_btn == 'mouse3' then
            if self.active then
                self.active = false; self:deactivate()
            end
            return
        end

        if NAV_KEYS[key_or_btn] then
            local was_inactive = not self.active
            self.active = true
            if was_inactive then self.funcs.reconnect() end
        end

        if prompt == 'accept' or prompt == 'decline' then
            local choice = prompt
            if choice == 'accept' and self.selectObj then
                call_click(self, self.selectObj)
            end
            self.funcs.clicked(key_or_btn, choice)
        end
    end)

    G.pipeline:register('input_change', pn.change, function(axis, value)
        if self.dontregister then return end
        if math.abs(value or 0) > 0.3 and not self.active then
            self.active = true
            self.funcs.reconnect()
        end
    end)

    G.pipeline:register('update', pn.update, function(dt)
        if G:halted() then
            self.timers.deb = false
            return
        end

        if not self.active or self.dontregister then
            self.timers.deb = false
            return
        end

        do
            local mx = (input_mgr.mouse.wheel_dir or {0,0})[1]
            local my = (input_mgr.mouse.wheel_dir or {0,0})[2]
            if (mx ~= 0 or my ~= 0) then
                self.active = false
                self:deactivate()
                return
            end
            if input_mgr.mouse.state and (input_mgr.mouse.state.active[1] or input_mgr.mouse.state.active[2] or input_mgr.mouse.state.active[3]) then
                self.active = false
                self:deactivate()
                return
            end
        end

        local dirv = input_mgr.controller.get_active_direction()
        local sx, sy = dirv[1] or 0, dirv[2] or 0

        local DEADZONE = (self.axis == 'y') and 0.75 or 0.3
        local dir = math.abs((self.axis == 'y') and sy or sx)
        local dirAxis = (self.axis == 'y') and sy or sx
        local moving = dir > DEADZONE

        if moving then
            if not self.timers.deb then
                self.timers.holdt, self.timers.deb = tick(), true
                local adjust = (dirAxis > DEADZONE) and -1 or ((dirAxis < -DEADZONE) and 1 or 0)
                self.selecting = math.max(1, math.min(#self.objects, self.selecting + adjust))
                if adjust < 0 then
                    self.funcs.next()
                elseif adjust > 0 then
                    self.funcs.back()
                end
            else
                if (tick() - self.timers.holdw) > 0.4 and (tick() - self.timers.holdt) > 0.1 then
                    self.timers.deb = false
                    self.timers.holdt = tick()
                end
            end
        else
            self.timers.deb = false
            self.timers.holdt = tick()
            self.timers.holdw = tick()
        end

        self._frame = (self._frame + 1) % 2
        if self._frame == 0 then
            local prev = self.selectObj
            self.selectObj = self.objects[self.selecting]
            if prev ~= self.selectObj then
                if prev then call_leave(self, prev) end
                if self.selectObj then call_enter(self, self.selectObj) end
            end
        end

        self.funcs.render(dt, self.active)
    end, { priority = 1, after = 'INIT' })
end

function ScrollMT:load()
    if self._loaded then return end
    self._loaded = true
    self:_register_pipeline()
end

function ScrollMT:deactivate()
    self:leaveConnect()
    self.funcs.disconnect()
end

function ScrollMT:leaveConnect()
    for _, v in ipairs(self.objects or {}) do
        call_leave(self, v)
    end
end

function ScrollMT:setRegister(b)
    self.dontregister = not not b
end

function ScrollMT:destroy()
    self.active = false
    self:leaveConnect()
    if self._pipe_names then
        if self._pipe_names.update then G.pipeline:remove('update', self._pipe_names.update) end
        if self._pipe_names.start then G.pipeline:remove('input_start', self._pipe_names.start) end
        if self._pipe_names.change then G.pipeline:remove('input_change', self._pipe_names.change) end
        self._pipe_names = nil
    end
end

return MenuScroll
